#!/usr/bin/env python3
"""Run P2 sustained stress against isolated real services; no existing instance is touched."""
import argparse
import http.cookiejar
import json
import math
import os
import pathlib
import secrets
import socket
import subprocess
import tempfile
import time
import urllib.request


def check_rss_growth(samples_path, warmup_seconds, max_growth_mib):
    """Bound observed peak growth after warmup; never compare different processes."""
    rows = [json.loads(line) for line in samples_path.read_text().splitlines()]
    points = [row for row in rows if row.get('elapsed_seconds', 0) >= warmup_seconds]
    if len(points) < 2 or any('error' in row or not row.get('latest') for row in points):
        raise ValueError('RSS regression needs at least two successful samples after warmup')
    latest = [row['latest'] for row in points]
    run_id = latest[0].get('run_id')
    if run_id is None or any(point.get('run_id') != run_id for point in latest):
        raise ValueError('RSS regression cannot compare samples across process restarts')
    timestamps = [point['timestamp'] for point in latest]
    if any(b <= a for a, b in zip(timestamps, timestamps[1:])):
        raise ValueError('RSS regression needs increasing sample timestamps')
    rss = [point.get('rss') for point in latest]
    if any(type(value) not in (int, float) or not math.isfinite(value) or value < 0 for value in rss):
        raise ValueError('RSS regression needs valid RSS values')
    growth = max(rss) - rss[0]
    return dict(schema_version=1, kind='rss-regression', run_id=run_id,
                passed=growth <= max_growth_mib * 1024 * 1024,
                warmup_seconds=warmup_seconds, max_growth_mib=max_growth_mib,
                samples=len(rss), baseline_bytes=rss[0], peak_bytes=max(rss),
                last_bytes=rss[-1], growth_bytes=growth,
                scope='Observed RSS growth after warmup in one process; not proof of leak absence')


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1',0)); return sock.getsockname()[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zig-bin',required=True,type=pathlib.Path)
    parser.add_argument('--admin-bin',required=True,type=pathlib.Path)
    parser.add_argument('--seconds',type=int,default=1800)
    parser.add_argument('--core-max-mib',type=int,default=1024,help='Per-core file budget, 1..16384 MiB')
    parser.add_argument('--max-rss-growth-mib',type=int,help='Fail when RSS peak grows beyond this budget after warmup')
    parser.add_argument('--rss-warmup-seconds',type=int,default=30)
    parser.add_argument('--memory-probe',type=pathlib.Path,help='Run complete diagnostic capture/report suite using this isolated fault probe')
    parser.add_argument('--thread-probe',type=pathlib.Path,help='Zig TSan positive/negative probe for full reports')
    args=parser.parse_args()
    if args.memory_probe and not args.thread_probe: parser.error('--memory-probe full suite also requires --thread-probe')
    if not 1<=args.seconds<=86400: parser.error('seconds must be 1..86400')
    if not 1<=args.core_max_mib<=16384: parser.error('core-max-mib must be 1..16384')
    if args.max_rss_growth_mib is not None:
        if args.max_rss_growth_mib < 1 or not 0 <= args.rss_warmup_seconds <= args.seconds - 20:
            parser.error('RSS regression requires a positive MiB budget and at least 20 seconds after warmup')
    root=pathlib.Path(__file__).resolve().parents[1]
    work=pathlib.Path(tempfile.mkdtemp(prefix='zigfs-p2-runtime-'))
    zigport,adminport=port(),port()
    env=dict(os.environ,ZIGFS_DATA_ROOT=str(work/'data'),ZIGFS_API_ADDRESS=f'127.0.0.1:{zigport}',
             ZIGFS_METRICS_ENABLED='false',ZIGFS_ROOT_USER='p2-test',ZIGFS_ROOT_PASSWORD=secrets.token_hex(20),
             ZIGFS_ADMIN_SESSION_SECRET=secrets.token_hex(32),ZIGFS_ACCESS_KEY='P2TESTACCESS123456',
             ZIGFS_SECRET_KEY=secrets.token_hex(24),ZIGFS_ADMIN_LISTEN=f'127.0.0.1:{adminport}',
             ZIGFS_ENDPOINT=f'http://127.0.0.1:{zigport}',ZIGFS_ADMIN_CONFIG=str(work/'admin.json'))
    processes=[]
    with (work/'services.log').open('w') as log:
        try:
            for binary in [args.zig_bin,args.admin_bin]:
                processes.append(subprocess.Popen([str(binary.resolve())],cwd=work,env=env,stdout=log,stderr=log))
            jar=http.cookiejar.CookieJar()
            client=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
            base=f'http://127.0.0.1:{adminport}'
            for _ in range(100):
                try: client.open(base+'/health/ready',timeout=1).close(); break
                except OSError:
                    if any(p.poll() is not None for p in processes): raise RuntimeError('Service exited; inspect services.log')
                    time.sleep(.2)
            login=urllib.request.Request(base+'/api/v1/auth/login',data=json.dumps(dict(username=env['ZIGFS_ROOT_USER'],password=env['ZIGFS_ROOT_PASSWORD'])).encode(),headers={'Content-Type':'application/json'})
            client.open(login,timeout=10).close()
            cookie=next(c.value for c in jar if c.name=='zigfs_admin_session')
            env['ZIGFS_DIAGNOSTIC_COOKIE']=cookie
            for _ in range(50):
                with client.open(base+'/api/v1/monitoring',timeout=5) as response: initial=json.load(response)
                if initial['latest']:break
                time.sleep(.2)
            assert initial['latest']
            target=work/'target.json'
            target.write_text(json.dumps([dict(name='ZigFS',endpoint=env['ZIGFS_ENDPOINT'],access_key_env='ZIGFS_ACCESS_KEY',secret_key_env='ZIGFS_SECRET_KEY')]))
            # Useful for local captures while stress runs. Contains no credentials.
            (work/'instance.json').write_text(json.dumps(dict(pid=processes[0].pid,binary=str(args.zig_bin.resolve()),base=base)))
            print(json.dumps({'artifacts':str(work),'pid':processes[0].pid,'seconds':args.seconds}),flush=True)
            evidence=[]
            def tool(name, arguments):
                subprocess.run(['python3',str(root/'tools/diagnostics'/name),*map(str,arguments)],env=env,check=True)
            if args.memory_probe:
                tool('check_memory.py',['--binary',args.memory_probe.resolve(),'--output',work/'memory'])
                evidence.append(work/'memory/report.json')
                tool('check_thread.py',['--binary',args.thread_probe.resolve(),'--output',work/'zig-tsan'])
                evidence.append(work/'zig-tsan/report.json')
                tool('sanitizers.py',['--output',work/'sanitizers'])
                evidence.append(work/'sanitizers/report.json')
                tool('dump.py',['--binary',args.memory_probe.resolve(),'--output',work/'crash','--max-mib',args.core_max_mib,'--','double-free'])
                evidence.append(work/'crash/report.json')
                tool('symbolize.py',['--binary',args.memory_probe.resolve(),'--capture',work/'crash/report.json','--output',work/'symbols'])
                evidence.append(work/'symbols/report.json')
                tool('snapshot.py',['--pid',processes[0].pid,'--binary',args.zig_bin.resolve(),'--monitor',base+'/api/v1/monitoring','--output',work/'before'])
                evidence.append(work/'before/report.json')
            result=subprocess.run(['python3',str(root/'tools/diagnostics/stress.py'),'--targets',str(target),'--output',str(work/'stress'),'--seconds',str(args.seconds),'--monitor',base+'/api/v1/monitoring'],env=env)
            if result.returncode: raise RuntimeError('Stress failed; inspect stress/report.json')
            report=json.loads((work/'stress/report.json').read_text())
            assert report['passed'] and report['elapsed_seconds']>=args.seconds and report['sample_count']>=2
            if args.max_rss_growth_mib is not None:
                growth = check_rss_growth(work/'stress/samples.jsonl', args.rss_warmup_seconds, args.max_rss_growth_mib)
                (work/'rss-regression.json').write_text(json.dumps(growth, indent=2)+'\n')
                evidence.append(work/'rss-regression.json')
                assert growth['passed'], 'RSS growth exceeded budget; inspect rss-regression.json'
            assert all(p.poll() is None for p in processes)
            with client.open(base+'/api/v1/buckets',timeout=10) as response: buckets=response.read()
            assert b'zigfs-stress-' not in buckets,'Stress bucket was not cleaned'
            if args.memory_probe:
                tool('snapshot.py',['--pid',processes[0].pid,'--binary',args.zig_bin.resolve(),'--monitor',base+'/api/v1/monitoring','--compare',work/'before/report.json','--output',work/'after'])
                evidence.extend([work/'after/report.json',work/'stress/report.json'])
                tool('dump.py',['--pid',processes[0].pid,'--binary',args.zig_bin.resolve(),'--style','modified-memory','--max-mib',args.core_max_mib,'--output',work/'live-core'])
                evidence.append(work/'live-core/report.json')
                arguments=['--output',work/'report']
                for item in evidence: arguments.extend(['--input',item])
                tool('report.py',arguments)
                assert all(p.poll() is None for p in processes), 'Capture failed to leave services running'
            log.flush()
            log_text=(work/'services.log').read_text()
            assert not any(marker in log_text for marker in ['WARNING: ThreadSanitizer','ERROR: AddressSanitizer','runtime error:', 'panic:']), 'Native diagnostic error in service log'
            print(json.dumps({'passed':True,'artifacts':str(work),'operations':sum(r['successes'] for r in report['operations'].values())}),flush=True)
        finally:
            for process in reversed(processes):
                process.terminate()
                try: process.wait(timeout=10)
                except subprocess.TimeoutExpired: process.kill();process.wait()


if __name__=='__main__':main()
