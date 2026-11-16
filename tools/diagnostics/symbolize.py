#!/usr/bin/env python3
"""Resolve matching-binary addresses offline, checking capture SHA-256 before symbolication."""
import argparse
import json
import os
import pathlib
import shlex
import shutil
from common import directory, execute, identity, manifest, write_json


def run(binary,output,capture=None,addresses=None,slide=0,expected_hash=None):
    info=identity(binary)
    requested=list(addresses or [])
    if capture:
        recorded=json.loads(pathlib.Path(capture).read_text())
        expected_hash=recorded['binary']['sha256']
        if not recorded.get('capture',{}).get('passed'): raise ValueError('Capture did not succeed')
        for thread in recorded['capture']['threads']:
            for frame in thread['frames']:
                if frame.get('module')==recorded['binary']['path'] and 0<=frame['file_address']<2**64-1:
                    requested.append(frame['file_address'])
    if expected_hash and info['sha256']!=expected_hash: raise ValueError('Binary SHA-256 does not match capture')
    requested=list(dict.fromkeys(address-slide for address in requested))
    if not requested or len(requested)>4096 or any(address<0 or address>=2**64-1 for address in requested):
        raise ValueError('Supply 1..4096 valid file addresses; runtime addresses require their ASLR slide')
    tool=shutil.which('lldb')
    if not tool: raise RuntimeError('LLDB is unavailable')
    output=directory(output)
    write_json(output/'config.json',dict(binary=info['path'],addresses=requested,output=str(output/'symbols.json')))
    env=dict(os.environ,ZIGFS_SYMBOLIZE_CONFIG=str(output/'config.json'))
    process=execute([tool,'--batch','--no-lldbinit','-o','command script import '+shlex.quote(str(pathlib.Path(__file__).with_name('lldb_symbolize.py')))],output/'symbolizer.log',timeout=60,env=env)
    rows=json.loads((output/'symbols.json').read_text()) if (output/'symbols.json').exists() else []
    report=manifest('symbolication',binary=info,passed=process['exit_code']==0 and bool(rows) and all(r['resolved'] for r in rows),
                    verified_binary=bool(expected_hash),symbols=rows,tool=process,
                    scope='Offline executable file addresses; external modules require their own matching symbols. Source lines may be unavailable for some compiler/runtime frames.')
    write_json(output/'report.json',report)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True)
    parser.add_argument('--output',required=True)
    inputs=parser.add_mutually_exclusive_group(required=True)
    inputs.add_argument('--capture',help='dump.py report.json, with binary hash and file addresses')
    inputs.add_argument('--address',action='append',type=lambda value:int(value,0))
    parser.add_argument('--slide',type=lambda value:int(value,0),default=0,help='ASLR runtime load minus file image base; raw addresses only')
    parser.add_argument('--sha256',help='Expected binary hash for raw address input')
    args=parser.parse_args()
    if args.capture and args.slide: parser.error('Capture already contains file addresses; no slide allowed')
    try:
        report=run(args.binary,args.output,args.capture,args.address,args.slide,args.sha256)
        print(json.dumps({'passed':report['passed'],'resolved':sum(r['resolved'] for r in report['symbols'])}))
        raise SystemExit(0 if report['passed'] else 1)
    except (OSError,ValueError,RuntimeError,KeyError) as error:parser.exit(1,str(error)+'\n')
