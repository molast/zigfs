#!/usr/bin/env python3
"""Validate Zig TSan clean/racy probes independently of the C bridge controls."""
import argparse
import os
import resource
from common import directory, execute, identity, manifest, write_json


def run(binary,output):
    binary_info=identity(binary)
    output=directory(output)
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    cases=[]
    for mode in ['clean','race']:
        result=execute([binary_info['path'],mode],output/f'{mode}.log',timeout=60,
                       env=dict(os.environ,TSAN_OPTIONS='halt_on_error=1:exitcode=66'))
        log=(output/result['log']).read_text(errors='replace')
        result.update(case=mode,passed=not result['timed_out'] and (result['exit_code']==0 if mode=='clean' else result['exit_code'] not in (0,None) and 'ThreadSanitizer: data race' in log))
        cases.append(result)
    report=manifest('zig-tsan',binary=binary_info,cases=cases,passed=all(case['passed'] for case in cases),
                    scope='Zig concurrent locked counter and deliberately racy counter. A passing control does not establish whole-program race freedom.')
    write_json(output/'report.json',report)
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary',required=True)
    parser.add_argument('--output',required=True)
    args=parser.parse_args()
    try:
        report=run(args.binary,args.output)
        print({'passed':report['passed'],'output':args.output})
        raise SystemExit(0 if report['passed'] else 1)
    except (OSError,ValueError) as error:parser.exit(1,str(error)+'\n')
