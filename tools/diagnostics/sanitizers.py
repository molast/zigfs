#!/usr/bin/env python3
"""Build/run separate ASan, UBSan and TSan controls plus real ZigFS C telemetry bridges."""
import argparse
import os
import pathlib
import resource
import shutil
from common import directory, execute, manifest, write_json

SUITES = {
    'asan': ('address', {'use-after-free':'heap-use-after-free','buffer-overflow':'heap-buffer-overflow','double-free':'double-free'}),
    'ubsan': ('undefined', {'overflow':'signed integer overflow'}),
    'tsan': ('thread', {'race':'data race'}),
}


def run(output, compiler='clang'):
    output=directory(output)
    compiler=shutil.which(compiler)
    if not compiler: raise RuntimeError('C compiler unavailable')
    resource.setrlimit(resource.RLIMIT_CORE,(0,0))
    source=pathlib.Path(__file__).resolve().parents[2]/'zigfs/src/testing/sanitizer_probe.c'
    version=execute([compiler,'--version'],output/'compiler.log')
    suites=[]
    for name,(flag,cases) in SUITES.items():
        binary=output/name
        build=execute([compiler,'-std=c11','-g','-O1','-fno-omit-frame-pointer',f'-fsanitize={flag}',
                       '-fno-sanitize-recover=all','-pthread',str(source),'-o',str(binary)],output/f'{name}-build.log',timeout=120)
        suite=dict(name=name,build=build,cases=[],status='unavailable')
        if build['exit_code']==0:
            env=dict(os.environ,ASAN_OPTIONS='abort_on_error=0:detect_leaks=0',
                     UBSAN_OPTIONS='halt_on_error=1:print_stacktrace=1',TSAN_OPTIONS='halt_on_error=1:exitcode=66')
            for case,marker in {'clean':None,**cases}.items():
                result=execute([str(binary),case],output/f'{name}-{case}.log',timeout=60,env=env,cwd=output)
                log=(output/result['log']).read_text(errors='replace')
                result.update(case=case,passed=not result['timed_out'] and (result['exit_code']==0 if marker is None else result['exit_code'] not in (0,None) and marker in log))
                suite['cases'].append(result)
            suite['status']='passed' if all(c['passed'] for c in suite['cases']) else 'failed'
        suites.append(suite)
    report=manifest('sanitizers',compiler=compiler,compiler_log=version['log'],suites=suites,
                    passed=all(s['status']=='passed' for s in suites),
                    scope='Clang-instrumented C host/process/filesystem telemetry bridges and positive controls. Not whole-server Zig or prebuilt-library instrumentation.')
    write_json(output/'report.json',report)
    lines=['# Sanitizer support matrix','',report['platform'],'',report['scope'],'',
           '| Suite | Result | Clean bridge | Fault controls |','| --- | --- | --- | --- |']
    for s in suites:
        lines.append(f"| {s['name']} | {s['status']} | {next((str(c['passed']) for c in s['cases'] if c['case']=='clean'),'not run')} | {sum(c['passed'] for c in s['cases'] if c['case']!='clean')} |")
    (output/'report.md').write_text('\n'.join(lines)+'\n')
    return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',required=True)
    parser.add_argument('--compiler',default='clang')
    args=parser.parse_args()
    try:
        report=run(args.output,args.compiler)
        print({s['name']:s['status'] for s in report['suites']})
        raise SystemExit(0 if report['passed'] else 1)
    except (OSError,RuntimeError) as error: parser.exit(1,str(error)+'\n')
