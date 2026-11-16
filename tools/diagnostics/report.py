#!/usr/bin/env python3
"""Assemble local diagnostic evidence without copying raw memory dumps or credentials."""
import argparse
import hashlib
import json
import pathlib
import shutil
from common import directory, manifest, write_json

REQUIRED={'memory-probes','sanitizers','memory-snapshot','dump','symbolication','stress','zig-tsan'}


def kind_of(value):
    return value.get('kind') or ('memory-probes' if 'cases' in value and 'all_passed' in value else 'unknown')


def resource_summary(path):
    if not path.exists(): return None
    count=0; errors=0; runs=set(); gauges={}; first=None; last=None
    with path.open() as stream:
        for line in stream:
            value=json.loads(line); point=value.get('latest')
            if not point: errors+=1; continue
            count+=1; runs.add(point.get('run_id'))
            if first is None: first=point
            last=point
            for key in ['rss','heap','descriptors','threads','allocations','frees']:
                if point.get(key) is not None:
                    entry=gauges.setdefault(key,{'first':point[key],'min':point[key],'max':point[key]})
                    entry.update(last=point[key],min=min(entry['min'],point[key]),max=max(entry['max'],point[key]))
    comparable=count>1 and len(runs)==1 and last['timestamp']>first['timestamp']
    for entry in gauges.values(): entry['delta']=entry['last']-entry['first'] if comparable else None
    return dict(samples=count,errors=errors,comparable=comparable,runs=len(runs),gauges=gauges,
                note='End values depend on in-flight work and allocator caches; growth is not a leak diagnosis.')


def build(inputs,output,required=REQUIRED):
    parsed=[]
    for item in inputs:
        source=pathlib.Path(item).resolve(strict=True)
        if source.stat().st_size>16*1024*1024: raise ValueError('Report exceeds 16 MiB')
        value=json.loads(source.read_text())
        if kind_of(value)=='unknown': raise ValueError(f'Unknown diagnostic report: {source.name}')
        parsed.append((source,value))
    output=directory(output)
    evidence=[]
    for index,(source,value) in enumerate(parsed):
        kind=kind_of(value)
        filename=f'{index+1:02d}-{kind}.json'
        shutil.copyfile(source,output/filename)
        (output/filename).chmod(0o600)
        passed=value.get('passed',value.get('all_passed',False)) is True
        row=dict(kind=kind,passed=passed,file=filename,source=str(source),sha256=hashlib.sha256(source.read_bytes()).hexdigest(),
                 scope=value.get('scope'),platform=value.get('platform'))
        if kind=='stress':
            row.update(requested_seconds=value['requested_seconds'],elapsed_seconds=value['elapsed_seconds'],
                       operations=value['operations'],resources=resource_summary(source.parent/'samples.jsonl'),
                       cleanup_errors=value['cleanup_errors'],sample_errors=value['sample_errors'])
        if kind=='sanitizers': row['suites']=[{'name':s['name'],'status':s['status']} for s in value['suites']]
        if kind=='symbolication': row['resolved']=sum(v['resolved'] for v in value['symbols'])
        if kind=='dump': row['core']=dict(path=str(source.parent/'process.core'),bytes=value['capture'].get('core_bytes'),style=value['capture'].get('style'))
        evidence.append(row)
    missing=sorted(set(required)-{row['kind'] for row in evidence})
    result=manifest('diagnostic-report',passed=not missing and all(row['passed'] for row in evidence),evidence=evidence,missing=missing,
                    scope='Local diagnostic evidence, not a security certification or proof of leak/race absence. Platform results apply only to recorded runs. Raw core files remain at their original private paths.')
    write_json(output/'report.json',result)
    lines=['# ZigFS diagnostic report','',f"Overall: **{'PASS' if result['passed'] else 'INCOMPLETE / FAILED'}**",'',result['scope'],'',
           '| Evidence | Result | Platform | Report |','| --- | --- | --- | --- |']
    for row in evidence:
        lines.append(f"| {row['kind']} | {'PASS' if row['passed'] else 'FAIL'} | {row.get('platform') or 'not recorded'} | [{row['file']}]({row['file']}) |")
    if missing: lines+=['','Missing required evidence: '+', '.join(missing)]
    for row in evidence:
        if row['kind']=='stress':
            lines+=['','## Sustained workload','',f"Requested {row['requested_seconds']} s; observed {row['elapsed_seconds']:.2f} s. Telemetry errors: {row['sample_errors']}. Cleanup errors: {len(row['cleanup_errors'])}.",'',
                    '| Operation | Success | Errors | P50 / P95 / P99 (ms, upper bounds) |','| --- | --- | --- | --- |']
            for op,data in row['operations'].items(): lines.append(f"| {op} | {data['successes']} | {data['errors']} | {data['p50_ms']} / {data['p95_ms']} / {data['p99_ms']} |")
            if row['resources']:
                lines+=['','### Resource observations','',row['resources']['note'],'',
                        '| Resource | First | Last | Min | Max | Delta |','| --- | --- | --- | --- | --- | --- |']
                for key,data in row['resources']['gauges'].items(): lines.append(f"| {key} | {data['first']} | {data['last']} | {data['min']} | {data['max']} | {data['delta']} |")
        if row['kind']=='sanitizers':
            lines+=['','## Sanitizer scope','',row['scope']]
            lines += ['',', '.join(s['name']+': '+s['status'] for s in row['suites'])]
        if row['kind']=='dump': lines+=['','## Native memory artifact','',f"Style: `{row['core']['style']}`. Bytes: {row['core']['bytes']}. Core remains outside this bundle."]
    (output/'report.md').write_text('\n'.join(lines)+'\n')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input',action='append',required=True)
    parser.add_argument('--output',required=True)
    parser.add_argument('--require',default=','.join(sorted(REQUIRED)),help='Comma-separated required evidence kinds')
    args=parser.parse_args()
    try:
        result=build(args.input,args.output,set(filter(None,args.require.split(','))))
        print(json.dumps({'passed':result['passed'],'missing':result['missing'],'output':args.output}))
        raise SystemExit(0 if result['passed'] else 1)
    except (OSError,ValueError,KeyError) as error:parser.exit(1,str(error)+'\n')
