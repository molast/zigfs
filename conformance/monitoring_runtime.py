import json, os, pathlib, secrets, socket, subprocess, tempfile, time, urllib.request, urllib.error, http.cookiejar, datetime, hashlib, hmac
import argparse
import concurrent.futures
import threading
parser = argparse.ArgumentParser(description='Validate monitoring using isolated real ZigFS and BFF services.')
parser.add_argument('--admin-bin', required=True, type=pathlib.Path)
parser.add_argument('--zig-bin', type=pathlib.Path, help='Optional separately built diagnostic ZigFS executable')
parser.add_argument('--persistence', action='store_true', help='Also wait for a checkpoint and validate restart/corruption recovery')
parser.add_argument('--p1', action='store_true', help='Validate alert rules, hotspots, native captures and standalone benchmark')
args = parser.parse_args()
root=pathlib.Path(__file__).resolve().parents[1]
zig_binary=args.zig_bin.resolve() if args.zig_bin else root/'zigfs/zig-out/bin/zigfs'
work=pathlib.Path(tempfile.mkdtemp(prefix='zigfs-monitor-'))
processes=[]
def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1',0)); return s.getsockname()[1]
try:
    zigport, adminport, metricsport=port(),port(),port()
    access='MONITORTESTACCESS1234'; secret=secrets.token_hex(24)
    env=dict(os.environ, ZIGFS_DATA_ROOT=str(work/'data'), ZIGFS_API_ADDRESS=f'127.0.0.1:{zigport}', ZIGFS_METRICS_ENABLED='true', ZIGFS_METRICS_ADDRESS=f'127.0.0.1:{metricsport}', ZIGFS_ROOT_USER='monitor-check', ZIGFS_ROOT_PASSWORD=secrets.token_hex(16), ZIGFS_ADMIN_SESSION_SECRET=secrets.token_hex(32), ZIGFS_ACCESS_KEY=access, ZIGFS_SECRET_KEY=secret, ZIGFS_ADMIN_LISTEN=f'127.0.0.1:{adminport}', ZIGFS_ENDPOINT=f'http://127.0.0.1:{zigport}', ZIGFS_ADMIN_CONFIG=str(work/'admin.json'), ZIGFS_WEB_ROOT=str(root/'zigfs-admin/web/dist'))
    logs=open(work/'services.log','w')
    for executable in [zig_binary,args.admin_bin.resolve()]:
        processes.append(subprocess.Popen([str(executable)],cwd=work,env=env,stdout=logs,stderr=logs))
    base=f'http://127.0.0.1:{adminport}'
    jar=http.cookiejar.CookieJar()
    client=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
    for _ in range(100):
        try:
            client.open(base+'/health/ready',timeout=1); break
        except Exception:
            if any(p.poll() is not None for p in processes): raise RuntimeError((work/'services.log').read_text()[-2000:])
            time.sleep(.2)
    def call(path, payload=None, method=None, opener=client):
        request=urllib.request.Request(base+path,data=None if payload is None else json.dumps(payload).encode(),headers={'Content-Type':'application/json'},method=method)
        return json.load(opener.open(request,timeout=10))
    call('/api/v1/auth/login',dict(username=env['ZIGFS_ROOT_USER'],password=env['ZIGFS_ROOT_PASSWORD']))
    def reject(fn,code):
        try:fn()
        except urllib.error.HTTPError as e: assert e.code==code,(e.code,e.read())
        else:raise AssertionError(f'expected {code}')
    reject(lambda:urllib.request.urlopen(base+'/api/v1/monitoring'),401)
    password=secrets.token_hex(16)
    call('/api/v1/users',dict(name='monitor-reader',description='',enabled=True,policies=['diagnostics'],groups=[],password=password))
    reader_jar=http.cookiejar.CookieJar()
    local=urllib.request.build_opener(urllib.request.HTTPCookieProcessor(reader_jar))
    call('/api/v1/auth/login',dict(username='monitor-reader',password=password),opener=local)
    call('/api/v1/monitoring',opener=local)
    reject(lambda:call('/api/v1/users',opener=local),403)
    def s3(method,path,payload=b'',extra=None):
        stamp=datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ');date=stamp[:8];host=f'127.0.0.1:{zigport}'
        digest=hashlib.sha256(payload).hexdigest();signed='host;x-amz-content-sha256;x-amz-date'
        canonical=f'{method}\n{path}\n\nhost:{host}\nx-amz-content-sha256:{digest}\nx-amz-date:{stamp}\n\n{signed}\n{digest}'
        scope=f'{date}/us-east-1/s3/aws4_request';message=f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
        signing=('AWS4'+secret).encode()
        for part in [date,'us-east-1','s3','aws4_request']:signing=hmac.new(signing,part.encode(),hashlib.sha256).digest()
        headers={'Host':host,'x-amz-date':stamp,'x-amz-content-sha256':digest,'Authorization':f'AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={signed}, Signature={hmac.new(signing,message.encode(),hashlib.sha256).hexdigest()}'}
        headers.update(extra or {})
        return urllib.request.urlopen(urllib.request.Request(f'http://{host}'+path,method=method,data=payload if method=='PUT' else None,headers=headers),timeout=10).read()
    initial=call('/api/v1/monitoring?seconds=300')
    deadline=time.monotonic()+5
    while initial['latest'] is None or initial['latest']['process_cpu'] is None:
        assert time.monotonic()<deadline
        time.sleep(.3);initial=call('/api/v1/monitoring?seconds=300')
    assert initial['latest']['heap']>0 and initial['latest']['rss']>0
    assert initial['latest']['workers']>0,initial['latest']
    assert initial['latest']['p95'] is None
    assert initial['latest']['error_percent'] is None
    audit=call('/api/v1/audit-events?action=GetMonitoring&limit=100')
    assert audit['items'] and all(event['event_action']=='GetMonitoring' for event in audit['items'])
    assert all(event['operation']['is_read_only'] for event in audit['items'])
    s3('PUT','/monitor-test')
    payload=b'telemetry-real-data'*4096
    s3('PUT','/monitor-test/object',payload)
    assert s3('GET','/monitor-test/object')==payload
    assert s3('GET','/monitor-test/object',extra={'Range':'bytes=0-9'})==payload[:10]
    reject(lambda:s3('GET','/monitor-test/missing'),404)
    for _ in range(10):s3('GET','/monitor-test/object',extra={'Range':'bytes=0-9'})
    after=call('/api/v1/monitoring?seconds=300')
    assert after['s3']['completed']==15,after['s3']
    assert after['s3']['client_errors']==1
    assert sum(after['s3']['histogram'])==15
    ops={x['name']:x['metrics'] for x in after['operations']}
    assert ops['get_object']['completed']==13,ops
    metrics=urllib.request.urlopen(f'http://127.0.0.1:{metricsport}/metrics').read().decode()
    assert f'zigfs_object_upload_bytes_total {len(payload)}\n' in metrics,metrics
    assert f'zigfs_object_download_bytes_total {len(payload)+110}\n' in metrics
    assert 'zigfs_request_duration_seconds_bucket{scope="api",operation="s3",le="+Inf"} 15' in metrics
    deadline=time.monotonic()+15
    while True:
        time.sleep(1)
        history=call('/api/v1/monitoring?seconds=300')['history']
        if any((p['qps'] or 0)>0 and p['p95'] is not None and p['error_percent'] is not None for p in history):break
        assert time.monotonic()<deadline,history
    if args.p1:
        diagnostics='/api/v1/monitoring/diagnostics'
        reject(lambda:urllib.request.urlopen(base+diagnostics),401)
        reject(lambda:call(diagnostics,opener=local),403)
        reject(lambda:call(diagnostics,{'hotspots_enabled':True},'PUT',opener=local),403)
        original=call('/api/v1/monitoring')['alert_rules']
        invalid=json.loads(json.dumps(original));invalid[0]['threshold']=101
        reject(lambda:call(diagnostics,{'rules':invalid},'PUT'),400)
        assert call('/api/v1/monitoring')['alert_rules']==original
        rules=json.loads(json.dumps(original))
        for rule in rules:
            if rule['id']=='thread_high':rule.update(threshold=0,duration_seconds=0,severity='critical')
        call(diagnostics,{'rules':rules,'hotspots_enabled':True},'PUT')
        def wait_alert(state):
            deadline=time.monotonic()+10
            while True:
                snapshot=call('/api/v1/monitoring')
                alert=next(a for a in snapshot['alerts'] if a['id']=='thread_high')
                if alert['state']==state:return snapshot,alert
                assert time.monotonic()<deadline,alert
                time.sleep(.25)
        snapshot,alert=wait_alert('firing')
        assert any(e['id']=='thread_high' and e['severity']=='critical' and e['state']=='firing' for e in snapshot['alert_events'])
        call(diagnostics,{'acknowledge':'thread_high'},'PUT')
        assert next(a for a in call('/api/v1/monitoring')['alerts'] if a['id']=='thread_high')['acknowledged']
        for _ in range(4):s3('GET','/monitor-test/object')
        details=call(diagnostics)
        assert details['hotspots_enabled'] and any(s['address'] and s['bytes']>0 for s in details['hotspots'])
        call(diagnostics,{'hotspots_enabled':False},'PUT')
        assert not call(diagnostics)['hotspots_enabled']
        assert snapshot['locks']['metadata']['acquisitions']>0
        assert ops['put_object']['uploaded_bytes']==len(payload)
        assert ops['get_object']['downloaded_bytes']==len(payload)+110
        assert snapshot['analysis']['heap']['status']=='insufficient'
        # Verify persisted configuration with an actual process restart.
        processes[0].terminate();processes[0].wait(timeout=10)
        processes[0]=subprocess.Popen([str(zig_binary)],cwd=work,env=env,stdout=logs,stderr=logs)
        deadline=time.monotonic()+15
        while True:
            try:
                restarted=call('/api/v1/monitoring')
                if restarted['latest']:break
            except (urllib.error.HTTPError,OSError):pass
            assert time.monotonic()<deadline
            time.sleep(.2)
        assert restarted['alert_rules']==rules
        assert not call(diagnostics)['hotspots_enabled'], 'hotspots unexpectedly enabled across restart'
        call(diagnostics,{'rules':original},'PUT')
        wait_alert('normal')
        target=work/'benchmark-target.json'
        target.write_text(json.dumps([dict(name='ZigFS',endpoint=env['ZIGFS_ENDPOINT'],access_key_env='ZIGFS_ACCESS_KEY',secret_key_env='ZIGFS_SECRET_KEY',version=restarted['version'])]))
        subprocess.run(['python3',str(root/'zigfs/bench/benchmark.py'),'--targets',str(target),'--output',str(work/'benchmark.json'),'--size','4096','--count','8','--concurrency','2'],env=env,check=True)
        report=json.loads((work/'benchmark.json').read_text())
        assert all(row['successes']==8 and row['errors']==0 for row in report['targets'][0]['operations'])
        assert not report['targets'][0]['cleanup_errors']
        assert b'zigfs-benchmark-' not in s3('GET','/')
        for kind in ['cpu','threads']:
            # An idle process may produce an empty perf.data with exit code zero.
            # Keep signed, payload-checked work active during CPU sampling only.
            stop_load = threading.Event()
            def capture_load():
                while not stop_load.is_set():
                    assert s3('GET','/monitor-test/object') == payload
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as pool:
                load = pool.submit(capture_load) if kind == 'cpu' else None
                try:
                    subprocess.run(['python3',str(root/'tools/monitoring/capture.py'),'--pid',str(processes[0].pid),'--kind',kind,'--seconds','5','--output',str(work/kind)],check=True)
                finally:
                    stop_load.set()
                    if load is not None: load.result(timeout=15)
            assert json.loads((work/kind/'manifest.json').read_text())['passed']
        print('P1: permissions, validation, alert transitions/ack, rule persistence, hotspots, payloads, native captures and standalone benchmark passed',flush=True)
    if args.persistence:
        checkpoint = work/'data/.zigfs/monitoring/history-v1.json'
        deadline = time.monotonic()+75
        while True:
            saved = json.loads(checkpoint.read_text()) if checkpoint.exists() else {'points': []}
            if any((p['qps'] or 0)>0 for p in saved['points']): break
            assert time.monotonic()<deadline, 'checkpoint did not retain workload'
            time.sleep(1)
        old_point = next(p for p in saved['points'] if (p['qps'] or 0)>0)
        assert checkpoint.stat().st_size <= 16*1024*1024
        def restart():
            processes[0].terminate(); processes[0].wait(timeout=10)
            processes[0] = subprocess.Popen([str(zig_binary)],cwd=work,env=env,stdout=logs,stderr=logs)
            limit=time.monotonic()+15
            while True:
                try:
                    value=call('/api/v1/monitoring?seconds=300')
                    if value['latest'] and value['latest']['run_id'] != old_point['run_id']: return value
                except (urllib.error.HTTPError, OSError): pass
                assert processes[0].poll() is None, 'restart exited'
                assert time.monotonic()<limit, 'restart timeout'
                time.sleep(.2)
        restored=restart()
        assert any(p['timestamp']==old_point['timestamp'] and p['qps']==old_point['qps'] for p in restored['history'])
        assert restored['s3']['completed']==0, 'old process counters were restored'
        assert restored['latest']['qps'] in (None,0), 'restart fabricated a rate spike'
        processes[0].terminate(); processes[0].wait(timeout=10)
        checkpoint.write_text('{corrupt snapshot')
        # restart helper also accepts an already terminated process.
        recovered=restart()
        assert recovered['latest'] is not None
        assert not any(p['run_id']==old_point['run_id'] for p in recovered['history'])
        print('Persistence: periodic checkpoint, restart continuity, reset counters and corrupt-file recovery passed', flush=True)
    session_cookie=next(c.value for c in jar if c.name=='zigfs_admin_session')
    browserenv=dict(os.environ,MONITOR_BASE=base,MONITOR_COOKIE=session_cookie,MONITOR_ARTIFACTS=str(work),MONITOR_READER_COOKIE=next(c.value for c in reader_jar if c.name=='zigfs_admin_session'))
    if browser_script := os.environ.get('MONITOR_BROWSER_SCRIPT'):
        subprocess.run(['node',browser_script],env=browserenv,check=True)
    logs.flush()
    assert not any(marker in (work/'services.log').read_text() for marker in ['WARNING: ThreadSanitizer', 'ERROR: AddressSanitizer', 'runtime error:', 'panic:']), 'Native diagnostic failure in service log'
    print(json.dumps({'result':'real telemetry, histogram, payload bytes, worker counts, history, permissions passed','artifacts':str(work),'s3_requests':after['s3']['completed'],'history_points':len(history),'workers':initial['latest']['workers']},ensure_ascii=False))
finally:
    for p in reversed(processes):
        p.terminate()
        try:p.wait(timeout=5)
        except subprocess.TimeoutExpired:p.kill();p.wait()
