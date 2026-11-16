#!/usr/bin/env python3
"""Capture a live process or a launched reproducer at crash into an LLDB core and stacks."""
import argparse
import json
import os
import pathlib
import resource
import shlex
import shutil
from common import directory, execute, identity, manifest, write_json, verify_process


def run(binary, output, pid=None, arguments=None, timeout=30, style='stack', max_mib=1024):
    binary_info=identity(binary)
    if pid is not None: verify_process(pid,binary)
    tool=shutil.which('lldb')
    if not tool: raise RuntimeError('LLDB is required; no synthetic dump will be produced')
    output=directory(output)
    config=dict(binary=binary_info['path'],output=str(output),pid=pid,arguments=arguments or [],timeout=timeout,style=style)
    write_json(output/'capture-config.json',config)
    script=pathlib.Path(__file__).with_name('lldb_capture.py')
    env=dict(os.environ,ZIGFS_CAPTURE_CONFIG=str(output/'capture-config.json'))
    # Cap output files for this tool and its debugger child. Existing hard limits are respected.
    soft,hard=resource.getrlimit(resource.RLIMIT_FSIZE)
    budget=max_mib*1024*1024
    resource.setrlimit(resource.RLIMIT_FSIZE,(min(budget,hard) if hard!=resource.RLIM_INFINITY else budget,hard))
    try:
        process=execute([tool,'--batch','--no-lldbinit','-o','command script import '+shlex.quote(str(script))],output/'debugger.log',timeout=timeout+45,env=env)
    finally:
        resource.setrlimit(resource.RLIMIT_FSIZE,(soft,hard))
    captured=json.loads((output/'capture.json').read_text()) if (output/'capture.json').exists() else {'passed':False,'error':'Debugger produced no capture manifest'}
    if not captured['passed'] and (output/'process.core').exists():
        captured['discarded_partial_bytes']=(output/'process.core').stat().st_size
        (output/'process.core').unlink()
    result=manifest('dump',binary=binary_info,passed=process['exit_code']==0 and captured['passed'],debugger=process,capture=captured,max_core_bytes=budget,
                    scope='Native core and thread frames. Stack style omits most heap memory; full style includes sensitive process memory. Attached process is briefly paused.')
    for file in output.iterdir():
        if file.is_file(): file.chmod(0o600)
    write_json(output/'report.json',result)
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True)
    parser.add_argument('--output',required=True)
    parser.add_argument('--pid',type=int,help='Attach, save and detach; omit to launch a crash reproducer')
    parser.add_argument('--timeout',type=int,default=30)
    parser.add_argument('--style',choices=['stack','modified-memory','full'],default='stack')
    parser.add_argument('--max-mib',type=int,default=1024)
    parser.add_argument('arguments',nargs=argparse.REMAINDER)
    args=parser.parse_args()
    if not 1<=args.timeout<=3600 or not 1<=args.max_mib<=16384: parser.error('Invalid timeout/file budget')
    arguments=args.arguments[1:] if args.arguments[:1]==['--'] else args.arguments
    if args.pid and arguments: parser.error('Arguments apply only to launch mode')
    try:
        report=run(args.binary,args.output,args.pid,arguments,args.timeout,args.style,args.max_mib)
        print(json.dumps({'passed':report['passed'],'output':args.output}))
        raise SystemExit(0 if report['passed'] else 1)
    except (OSError,RuntimeError,ValueError) as error: parser.exit(1,str(error)+'\n')
