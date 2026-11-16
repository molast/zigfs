#!/usr/bin/env python3
"""Save an OS memory-map snapshot and optional real ZigFS allocator telemetry."""
import argparse
import json
import os
import pathlib
import platform
import shutil
import urllib.request
from common import directory, execute, identity, manifest, write_json, verify_process


def compare(previous, current):
    a=previous.get('telemetry',{}).get('latest') or {}
    b=current.get('telemetry',{}).get('latest') or {}
    if not a or not b or a.get('run_id')!=b.get('run_id') or b.get('timestamp',0)<=a.get('timestamp',0):
        return {'comparable':False,'reason':'Missing observations, different run or non-increasing timestamp'}
    fields=['rss','heap','allocations','frees','allocated_bytes','freed_bytes','descriptors','threads']
    return dict(comparable=True,seconds=b['timestamp']-a['timestamp'],
                deltas={k:b[k]-a[k] for k in fields if a.get(k) is not None and b.get(k) is not None},
                interpretation='Resource delta, not proof of a leak')


def run(pid,binary,output,monitor=None,cookie=None,previous=None):
    if pid<=1: raise ValueError('PID must exceed 1')
    verify_process(pid,binary)
    binary_info=identity(binary)
    output=directory(output)
    result=manifest('memory-snapshot',pid=pid,binary=binary_info,passed=False,
                    scope='OS virtual-memory map/summary and optional allocator aggregates; not an object graph or raw heap dump. Use dump.py --style full for native memory contents.')
    system=platform.system()
    try:
        if system=='Darwin':
            tool=shutil.which('vmmap')
            if not tool: raise RuntimeError('vmmap unavailable')
            result['tool']=execute([tool,'-summary',str(pid)],output/'memory-map.txt',timeout=30)
            if result['tool']['exit_code']!=0: raise RuntimeError('vmmap failed')
        elif system=='Linux':
            # These proc files contain region metadata, not arbitrary process memory.
            for name in ['status','maps','smaps_rollup']:
                source=pathlib.Path(f'/proc/{pid}/{name}')
                data=source.read_bytes()
                if len(data)>16*1024*1024: raise RuntimeError('Memory-map size budget exceeded')
                (output/f'{name}.txt').write_bytes(data)
        else: raise RuntimeError('Unsupported memory snapshot platform')
        if monitor:
            request=urllib.request.Request(monitor,headers={'Cookie':'zigfs_admin_session='+cookie} if cookie else {})
            with urllib.request.urlopen(request,timeout=10) as response: payload=json.load(response)
            result['telemetry']={key:payload.get(key) for key in ['latest','analysis','locks','version','started_at']}
            if not result['telemetry']['latest']: raise RuntimeError('No telemetry sample available')
        result['passed']=True
        if previous: result['comparison']=compare(json.loads(pathlib.Path(previous).read_text()),result)
    except Exception as error:
        result['passed']=False
        result['error']=str(getattr(error,'code',type(error).__name__))
    for file in output.iterdir():
        if file.is_file():file.chmod(0o600)
    write_json(output/'report.json',result)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid',type=int,required=True)
    parser.add_argument('--binary',required=True)
    parser.add_argument('--output',required=True)
    parser.add_argument('--monitor',help='BFF monitoring endpoint; uses cookie from environment')
    parser.add_argument('--cookie-env',default='ZIGFS_DIAGNOSTIC_COOKIE')
    parser.add_argument('--compare',help='Earlier memory-snapshot report.json')
    args=parser.parse_args()
    try:
        report=run(args.pid,args.binary,args.output,args.monitor,os.environ.get(args.cookie_env),args.compare)
        print(json.dumps({'passed':report['passed'],'output':args.output}))
        raise SystemExit(0 if report['passed'] else 1)
    except (OSError,ValueError) as error:parser.exit(1,str(error)+'\n')
