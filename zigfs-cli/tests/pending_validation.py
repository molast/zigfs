"""Steps 10–29 acceptance checks against a disposable real ZigFS instance.

Usage: python3 tests/pending_validation.py [zc] [zigfs] [report.json]
The report contains command names and sanitized outcomes, never credentials.
"""
import json
import os
from pathlib import Path
import re
import socket
import subprocess
import sys
sys.dont_write_bytecode = True
import tempfile
import time
import urllib.request

CLI = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zc').resolve()
SERVER = Path(sys.argv[2] if len(sys.argv) > 2 else '../zigfs/zig-out/bin/zigfs').resolve()
REPORT = Path(sys.argv[3] if len(sys.argv) > 3 else '/tmp/zc-pending-validation.json')
AK = 'PendingValidationAccessKey'
SK = 'pending-validation-secret-0123456789abcdef'
results = []


def check(name, function):
    selected = os.environ.get('PENDING_CHECK_FILTER')
    if selected and not re.search(selected, name):
        return
    try:
        evidence = function()
        entry = {'name': name, 'status': 'pass'}
        if isinstance(evidence, dict) and 'sampled_peak_rss_kib' in evidence:
            entry['evidence'] = evidence
        results.append(entry)
        print('PASS', name, flush=True)
    except Exception as error:
        message = str(error).replace(AK, '[access-key]').replace(SK, '[secret]')
        results.append({'name': name, 'status': 'fail', 'detail': message})
        print('FAIL', name, message, flush=True)


with tempfile.TemporaryDirectory(prefix='zc-pending-') as directory:
    root = Path(directory)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('ZIGFS_', 'ZC_'))}
    env['XDG_CONFIG_HOME'] = str(root / 'config')
    config = str(root / 'aliases.toml')

    def cli(args, expected=0, payload=None, raw=False):
        result = subprocess.run(
            [str(CLI), '--config', config, *args],
            env=env, capture_output=True, input=payload, timeout=35,
        )
        stream = result.stdout if result.returncode == 0 else result.stderr
        assert result.returncode == expected, (
            ' '.join(args[:4]), result.returncode, stream.decode(errors='replace')[:1500])
        if raw:
            return stream
        assert not (result.stderr if result.returncode == 0 else result.stdout)
        assert SK.encode() not in stream
        return json.loads(stream) if stream.strip() else None

    def run(command, *args, expected=0, payload=None):
        return cli(['--json', *command.split(), *map(str, args)], expected, payload)

    def file(name, value):
        path = root / name
        path.write_text(json.dumps(value))
        return str(path)

    def api(operation, value, *options, expected=0):
        return run('s3api ' + operation, 'qa', '--input-json',
                   file('request.json', value), *options, expected=expected)

    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    endpoint = f'http://127.0.0.1:{port}'
    settings = root / '.env'
    settings.write_text('\n'.join([
        f'ZIGFS_API_ADDRESS=127.0.0.1:{port}',
        f'ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}',
        f'ZIGFS_DATA_ROOT={root}/data',
        'ZIGFS_S3_REGION=us-east-1',
        'ZIGFS_METRICS_ENABLED=false',
        'ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS=1',
        'ZIGFS_ROOT_USER=qa',
        'ZIGFS_ROOT_PASSWORD=validation-password',
        'ZIGFS_ADMIN_SESSION_SECRET=validation-session-secret-0123456789abcdef',
        f'ZIGFS_ACCESS_KEY={AK}', f'ZIGFS_SECRET_KEY={SK}',
    ]))
    with (root / 'server.log').open('wb') as log:
        server = subprocess.Popen([str(SERVER), '--env-file', str(settings)],
                                  cwd=root, env=env, stdout=log, stderr=log)
        try:
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
            for _ in range(200):
                if server.poll() is not None:
                    raise RuntimeError('isolated server exited')
                try:
                    opener.open(endpoint + '/health/ready', timeout=1).close()
                    break
                except OSError:
                    time.sleep(0.05)
            else:
                raise RuntimeError('readiness timeout')
            run('alias set', 'qa', endpoint, AK, SK, '--management-endpoint', endpoint)
            bucket = 'validation-bucket'
            target = 'qa/' + bucket
            run('mb', target)
            body = root / 'payload.txt'
            body.write_text('name,value\nalpha,1\nbeta,2\n')
            obj = target + '/folder/data.csv'
            run('put', body, obj)

            def versions():
                run('version enable', target, '--yes')
                assert run('version info', target)['data']['result']['Status'] == 'Enabled'
                run('put', body, obj, '--overwrite', '--yes')
                run('bucket version list', target, '--max-keys', '1')
                run('version suspend', target, '--yes')
                assert run('version info', target)['data']['result']['Status'] == 'Suspended'
            check('10 version aliases and paginated versions', versions)

            def tags(destination):
                run('tag set', destination, '--tag', 'first=one', '--tag', 'second=two', '--yes')
                run('tag remove', destination, '--key', 'first', '--yes')
                value = run('tag list', destination)
                assert 'second' in json.dumps(value) and 'first' not in json.dumps(value)
                run('tag clear', destination, '--yes')
            check('12 bucket tags repeated keys and selective removal', lambda: tags(target))
            check('12 object tags repeated keys and selective removal', lambda: tags(obj))

            def anonymous():
                run('anonymous set', target, '--mode', 'download', '--yes')
                with opener.open(endpoint + '/' + bucket + '/folder/data.csv') as response:
                    assert response.read() == body.read_bytes()
                run('anonymous get-json', target)
                run('anonymous links', target)
                run('anonymous set', target, '--mode', 'none', '--yes')
                try:
                    opener.open(endpoint + '/' + bucket + '/folder/data.csv')
                except urllib.error.HTTPError as error:
                    assert error.code == 403
                else:
                    raise AssertionError('anonymous read remained authorized after clear')

            for family, destination in (('bucket acl', target), ('object acl', obj),
                                        ('bucket public-access-block', target), ('bucket ownership', target)):
                check('11 ' + family + ' get', lambda family=family, destination=destination: run(family + ' get', destination))

            def cors():
                value = {'CORSRules': [{'AllowedMethods': ['GET'], 'AllowedOrigins': ['https://example.test'], 'AllowedHeaders': ['*']}]}
                run('cors set', target, '--file', '-', '--yes', payload=json.dumps(value).encode())
                assert 'https://example.test' in json.dumps(run('cors get', target))
                request = urllib.request.Request(endpoint + '/' + bucket + '/folder/data.csv', method='OPTIONS',
                                                 headers={'Origin': 'https://example.test', 'Access-Control-Request-Method': 'GET'})
                with opener.open(request) as response:
                    assert response.headers['Access-Control-Allow-Origin'] == 'https://example.test'
                signed = run('share', obj, '--expire', '5m')['data']['url']
                for origin, expected in [('https://example.test', 'https://example.test'),
                                         ('https://denied.test', None)]:
                    with opener.open(urllib.request.Request(signed, headers={'Origin': origin})) as response:
                        assert response.headers.get('Access-Control-Allow-Origin') == expected
                        assert response.read() == body.read_bytes()
                run('cors remove', target, '--yes')
            check('12 CORS stdin roundtrip and real preflight', cors)

            def encryption():
                run('bucket encryption set', target, '--mode', 'sse-s3', '--yes')
                value = run('bucket encryption get', target)
                assert 'AES256' in json.dumps(value), value
                run('put', body, target + '/encrypted')
                signed = run('share', target + '/encrypted', '--expire', '5m')
                with opener.open(signed['data']['url']) as response:
                    assert response.headers['x-amz-server-side-encryption'] == 'AES256'
                    assert response.read() == body.read_bytes()
                run('bucket encryption clear', target, '--yes')
                with opener.open(signed['data']['url']) as response:
                    assert response.headers['x-amz-server-side-encryption'] == 'AES256'
            check('13 SSE-S3 default and existing object preservation', encryption)

            def lifecycle():
                rule = {'ID': 'first', 'Status': 'Enabled', 'Filter': {'Prefix': 'expire/'}, 'Expiration': {'Days': 30}}
                rule_file = file('rule.json', rule)
                run('ilm rule add', target, '--id', 'first', '--file', rule_file, '--yes')
                exported = root / 'lifecycle.json'
                run('ilm rule export', target, '--output', exported)
                assert 'first' in exported.read_text()
                run('ilm rule remove', target, '--all', '--yes')
                run('ilm rule import', target, exported, '--yes')
                assert 'first' in json.dumps(run('ilm rule list', target))
                run('ilm rule remove', target, '--all', '--yes')
            check('15 lifecycle first rule export import remove all', lifecycle)

            def notifications():
                import http.server
                import threading
                received = []
                class Receiver(http.server.BaseHTTPRequestHandler):
                    def do_POST(self):
                        received.append(json.loads(self.rfile.read(int(self.headers['Content-Length']))))
                        self.send_response(503 if len(received) == 1 else 204)
                        self.end_headers()
                    def log_message(self, *_args):
                        pass
                receiver = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Receiver)
                thread = threading.Thread(target=receiver.serve_forever, daemon=True)
                thread.start()
                try:
                    run('admin event-destination create', 'qa', '--file', file('event-target.json', {
                        'name': 'S3_TEST', 'type': 'webhook',
                        'endpoint': f'http://127.0.0.1:{receiver.server_port}/events',
                        'reconnect_interval': '1s'}), '--yes')
                    run('event add', target, '--id', 'images', '--type', 'queue', '--arn',
                        'arn:zigfs:events:::S3_TEST', '--events', 's3:ObjectCreated:*',
                        '--prefix', 'notify/', '--suffix', '.csv', '--yes')
                    assert 'images' in json.dumps(run('event list', target))
                    run('admin event-destination remove', 'qa', 'S3_TEST', '--yes', expected=6)
                    run('put', body, target + '/notify/deliver.csv')
                    deadline = time.monotonic() + 15
                    while len(received) < 2 and time.monotonic() < deadline:
                        time.sleep(0.1)
                    assert len(received) >= 2, received
                    assert received[0]['event_id'] == received[1]['event_id']
                    assert received[1]['Records'][0]['s3']['object']['key'] == 'notify%2Fdeliver.csv'
                    run('event remove', target, '--id', 'images', '--yes')
                    assert 'images' not in json.dumps(run('event list', target))
                    count = len(received)
                    run('put', body, target + '/notify/removed.csv')
                    run('put', body, target + '/outside-filter.csv')
                    time.sleep(1)
                    assert len(received) == count
                    run('admin event-destination remove', 'qa', 'S3_TEST', '--yes')
                finally:
                    receiver.shutdown()
                    receiver.server_close()
                    thread.join(timeout=3)

            def scan():
                for command in ('find', 'tree', 'du'):
                    run(command, target, '--fallback')
                run('find', target, '--fallback', '--name', '*.csv')
                run('tree', target, '--fallback', '--level', '1')
                run('du', 'qa', '--fallback', '--include', '*.csv', '--include', 'encrypted')
                run('du', target, '--fallback', '--versions')
                run('du', target, '--fallback', '--incomplete', '--min-size', '1')
                run('ping', 'qa')
                run('ready', 'qa')
            check('17 scanning filters service usage health', scan)

            def mirror():
                source = root / 'source'
                source.mkdir()
                (source / 'keep.txt').write_text('keep')
                (source / 'skip.bin').write_text('skip')
                run('mirror', str(source) + '/', target + '/mirror/', '--fallback', '--include', '*.txt', '--yes')
                assert cli(['cat', target + '/mirror/keep.txt'], raw=True) == b'keep'
                run('stat', target + '/mirror/skip.bin', expected=5)
                run('diff', str(source) + '/', target + '/mirror/', '--fallback', '--include', '*.txt')
                for shell in ('bash', 'zsh', 'fish'):
                    assert cli(['completions', shell], raw=True)
            check('18 mirror filter diff completions', mirror)

            def login():
                run('admin auth login', 'qa', '--file', file('login.json', {'username': 'qa', 'password': 'validation-password'}))
                run('admin auth session', 'qa')
                sessions = list(Path(config + '.sessions').rglob('*'))
                assert sessions
                for path in sessions:
                    if path.is_file() and 'token' in path.read_text():
                        assert path.stat().st_mode & 0o077 == 0
            check('19 management login session private storage', login)
            check('16 S3 notification delivery retry filters and removal', notifications)
            check('11 Management block_public_access field accepted', lambda: run(
                'admin bucket configuration set', 'qa', bucket, '--file',
                file('public.json', {'block_public_access': False}), '--yes'))

            def public_access():
                # Configure the documented backend prerequisite directly: the CLI
                # request model currently rejects this server-supported field.
                session_path = next(path for path in Path(config + '.sessions').rglob('*') if path.is_file())
                token = json.loads(session_path.read_text())['token']
                def set_block(enabled):
                    request = urllib.request.Request(endpoint + '/_admin/v1/buckets/' + bucket + '/configuration',
                        method='PATCH', data=json.dumps({'block_public_access': enabled}).encode(),
                        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
                    with opener.open(request) as response:
                        assert response.status == 200
                set_block(False)
                try:
                    anonymous()
                finally:
                    set_block(True)
            check('11 anonymous policy changes real access after backend PAB opt-out', public_access)

            def website():
                web = 'validation-website'
                run('mb', 'qa/' + web)
                run('admin bucket configuration set', 'qa', web, '--file', file('website-public.json', {
                    'block_public_access': False, 'access_policy': 'Readonly'}), '--yes')
                api('put-bucket-website', {'Bucket': web, 'WebsiteConfiguration': {
                    'IndexDocument': {'Suffix': 'index.html'}, 'ErrorDocument': {'Key': 'error.html'}}}, '--yes')
                import base64
                for key, payload in [('index.html', b'<h1>home</h1>'), ('docs/index.html', b'<h1>docs</h1>'),
                                     ('error.html', b'<h1>missing</h1>')]:
                    api('put-object', {'Bucket': web, 'Key': key, 'ContentType': 'text/html',
                        'Body': base64.b64encode(payload).decode()}, '--yes')
                for suffix, expected in [('/', b'<h1>home</h1>'), ('/docs/', b'<h1>docs</h1>')]:
                    with opener.open(endpoint + '/' + web + suffix) as response:
                        assert response.read() == expected
                try:
                    opener.open(endpoint + '/' + web + '/missing')
                    raise AssertionError('missing website path returned success')
                except urllib.error.HTTPError as error:
                    assert error.code == 404 and error.read() == b'<h1>missing</h1>'
                run('admin bucket configuration set', 'qa', web, '--file', file('website-private.json', {
                    'block_public_access': True}), '--yes')
                try:
                    opener.open(endpoint + '/' + web + '/')
                    raise AssertionError('website bypassed public access block')
                except urllib.error.HTTPError as error:
                    assert error.code == 403
            check('24 website serves index directory error document and enforces public access', website)

            def abac():
                run('tag set', target, '--tag', 'team=storage', '--yes')
                policy = {'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow',
                    'Action': 's3:GetObject', 'Resource': 'arn:aws:s3:::' + bucket + '/*',
                    'Condition': {'StringEquals': {'aws:ResourceTag/team': 'storage'}}}]}
                credential = run('admin access-key create', 'qa', '--file', file('abac-key.json', {
                    'policy_document': json.dumps(policy)}), '--yes')['data']['result']
                run('alias set', 'abac-key', endpoint, credential['access_key'], credential['secret_key'])
                for status, expected in [('Enabled', 0), ('Disabled', 4), ('Enabled', 0)]:
                    api('put-bucket-abac', {'Bucket': bucket, 'AbacStatus': {'Status': status}}, '--yes')
                    content = cli(['cat', 'abac-key/' + bucket + '/folder/data.csv'], expected=expected, raw=True)
                    if expected == 0:
                        assert content == body.read_bytes()
                run('tag clear', target, '--yes')
            check('27 ABAC switch controls bucket resource tag authorization', abac)

            def access_logs():
                destination = 'validation-access-logs'
                run('mb', 'qa/' + destination)
                api('put-bucket-logging', {'Bucket': bucket, 'BucketLoggingStatus': {
                    'LoggingEnabled': {'TargetBucket': destination, 'TargetPrefix': 'access/'}}}, '--yes')
                assert cli(['cat', obj], raw=True) == body.read_bytes()
                cli(['cat', target + '/missing-log-object'], expected=5, raw=True)
                deadline = time.monotonic() + 5
                records = []
                while time.monotonic() < deadline:
                    page = api('list-objects-v2', {'Bucket': destination})['data']['result']
                    entries = page.get('Contents', []) if isinstance(page, dict) else []
                    records = [json.loads(cli(['cat', 'qa/' + destination + '/' + entry['Key']], raw=True))
                               for entry in entries]
                    if any(item['status'] == 404 for item in records):
                        break
                    time.sleep(0.1)
                assert any(item['status'] == 200 and item['key'] == 'folder/data.csv' for item in records), records
                assert any(item['status'] == 404 for item in records), records
                assert all(SK not in json.dumps(item) for item in records)
                api('put-bucket-logging', {'Bucket': bucket, 'BucketLoggingStatus': {}}, '--yes')
            check('24 access logging writes successful and failed requests without recursion', access_logs)



            def management_reads():
                for command in ('admin user list', 'admin group list', 'admin policy list',
                                'admin access-key list', 'admin oidc-provider list', 'admin role-session list',
                                'admin settings get', 'admin kms info',
                                'admin system', 'admin health', 'admin storage info', 'admin monitoring',
                                'admin diagnostics get', 'admin logs get', 'admin audit-logs get'):
                    check(command, lambda command=command: run(command, 'qa'))
            management_reads()

            def quota():
                run('quota set', target, '--size', '1', '--yes')
                run('quota info', target)
                try:
                    run('put', body, target + '/over-quota', expected=1)
                finally:
                    run('quota clear', target, '--yes')
                run('quota clear', target, '--yes')
            check('16 quota enforcement', quota)

            def lock():
                credential = run('admin access-key create', 'qa', '--file', file('lock-key.json', {
                    'inherit_policy': True}), '--yes')['data']['result']
                run('alias set', 'lock', endpoint, credential['access_key'], credential['secret_key'])
                locked = 'lock/validation-locked'
                run('s3api create-bucket', 'lock', '--input-json', file('lock-bucket.json', {
                    'Bucket': 'validation-locked', 'ObjectLockEnabledForBucket': True}), '--yes')
                run('retention set', '--default', locked, '--file', file('lock.json', {
                    'ObjectLockEnabled': 'Enabled', 'Rule': {'DefaultRetention': {'Mode': 'GOVERNANCE', 'Days': 1}}}), '--yes')
                run('put', body, locked + '/held')
                run('legalhold set', locked + '/held', '--yes')
                assert 'ON' in json.dumps(run('legalhold info', locked + '/held'))
                run('legalhold clear', locked + '/held', '--yes')
                run('retention clear', locked + '/held', '--yes', expected=4)
                run('retention clear', locked + '/held', '--bypass', '--yes')
                assert 'RetainUntilDate' not in json.dumps(run('retention info', locked + '/held'))
                run('bucket lock clear', locked, '--yes')
                assert 'Enabled' in json.dumps(run('bucket lock info', locked))
                run('rb', locked, '--force', '--dangerous', '--bypass', '--yes', '--page-size', '1')
            check('14 lock default file legalhold governance bypass historical cleanup', lock)

            def iam():
                run('admin user create', 'qa', '--file', file('user.json', {
                    'name': 'test-user', 'password': 'test-user-password', 'policies': ['diagnostics'], 'enabled': True}), '--yes')
                run('admin user disable', 'qa', 'test-user', '--yes')
                assert run('admin user info', 'qa', 'test-user')['data']['result']['enabled'] is False
                run('admin user enable', 'qa', 'test-user', '--yes')
                run('admin group create', 'qa', '--file', file('group.json', {'name': 'test-group', 'members': [], 'policies': [], 'enabled': True}), '--yes')
                run('admin group add-members', 'qa', 'test-group', 'test-user', '--yes')
                assert 'test-user' in json.dumps(run('admin group info', 'qa', 'test-group'))
                run('admin group rm-members', 'qa', 'test-group', 'test-user', '--yes')
                run('admin policy attach', 'qa', 'readonly', '--user', 'test-user', '--yes')
                assert 'readonly' in json.dumps(run('admin user info', 'qa', 'test-user'))
                run('admin policy detach', 'qa', 'readonly', '--user', 'test-user', '--yes')
                run('admin group remove', 'qa', 'test-group', '--yes')
                run('admin user remove', 'qa', 'test-user', '--yes')
            check('20 IAM user toggles group members policy attachment', iam)

            def oidc():
                run('admin idp openid set', 'qa', 'test-provider', '--config-url',
                    'https://idp.example/.well-known/openid-configuration', '--client-id', 'console', '--redirect-uri', 'https://console.example/callback',
                    '--file', file('oidc.json', {'client_secret': 'test-only-secret'}), '--role-policy', 'readonly', '--yes')
                run('admin idp openid update', 'qa', 'test-provider', '--display-name', 'Updated', '--yes')
                value = run('admin oidc-provider list', 'qa')
                text = json.dumps(value)
                assert 'Updated' in text and 'console' in text and 'test-only-secret' not in text
                run('admin oidc-provider remove', 'qa', 'test-provider', '--yes')
            check('20 OIDC incremental update preserves omitted fields', oidc)

            reports = {
                'analytics': {'Id': 'test', 'StorageClassAnalysis': {}},
                'inventory': {'Id': 'test', 'IsEnabled': True, 'IncludedObjectVersions': 'Current',
                              'Schedule': {'Frequency': 'Daily'}, 'Destination': {'S3BucketDestination': {
                                  'Bucket': 'arn:aws:s3:::' + bucket, 'Format': 'CSV'}}},
                'metrics': {'Id': 'test'},
                'intelligent-tiering': {'Id': 'test', 'Status': 'Enabled',
                                       'Tierings': [{'Days': 90, 'AccessTier': 'ARCHIVE_ACCESS'}]},
            }
            for family, value in reports.items():
                def reporting(family=family, value=value):
                    run('bucket ' + family + ' set', target, '--id', 'test', '--file', file(family + '.json', value), '--yes')
                    run('bucket ' + family + ' get', target, '--id', 'test')
                    run('bucket ' + family + ' list', target)
                    if family != 'intelligent-tiering':
                        deadline = time.monotonic() + 8
                        generated = []
                        while time.monotonic() < deadline:
                            listing = api('list-objects-v2', {'Bucket': bucket,
                                'Prefix': '.zigfs-reports/' + family + '/'})['data']['result']
                            generated = listing.get('Contents', []) if isinstance(listing, dict) else []
                            if any(item['Key'].endswith('.manifest.json') for item in generated):
                                break
                            time.sleep(0.1)
                        assert generated, family + ' produced no report'
                        csv_key = next(item['Key'] for item in generated if item['Key'].endswith('.csv'))
                        contents = cli(['cat', target + '/' + csv_key], raw=True)
                        assert bucket.encode() in contents and len(contents.splitlines()) > 1
                        import hashlib
                        manifest = json.loads(cli(['cat', target + '/' + csv_key + '.manifest.json'], raw=True))
                        assert manifest['sourceBucket'] == bucket
                        assert manifest['files'][0]['key'] == csv_key
                        assert manifest['files'][0]['size'] == len(contents)
                        assert manifest['files'][0]['MD5checksum'] == hashlib.md5(contents).hexdigest()
                    run('bucket ' + family + ' remove', target, '--id', 'test', '--yes')
                check('25 ' + family + ' CRUD', reporting)

            def restore_standard():
                run('object restore', obj, '--days', '1', '--yes', expected=4)
                assert cli(['cat', obj], raw=True) == body.read_bytes()
            check('26 restore rejects STANDARD object without modifying bytes', restore_standard)

            def restore_archive():
                import base64
                common = {'Bucket': bucket, 'Key': 'archived.csv'}
                api('put-object', {**common, 'StorageClass': 'GLACIER',
                    'Body': base64.b64encode(body.read_bytes()).decode()}, '--yes')
                cli(['cat', target + '/archived.csv'], expected=4, raw=True)
                api('copy-object', {'Bucket': bucket, 'Key': 'cold-copy.csv',
                    'CopySource': bucket + '/archived.csv'}, '--yes', expected=4)
                api('restore-object', {**common, 'RestoreRequest': {'Days': 1}}, '--yes')
                assert cli(['cat', target + '/archived.csv'], raw=True) == body.read_bytes()
                api('restore-object', {**common, 'RestoreRequest': {'Days': 2}}, '--yes')
                attrs = api('get-object-attributes', {**common,
                    'ObjectAttributes': ['StorageClass', 'ObjectSize']})['data']['result']
                assert attrs['StorageClass'] == 'GLACIER' and attrs['ObjectSize'] == body.stat().st_size
                api('copy-object', {'Bucket': bucket, 'Key': 'cold-copy.csv',
                    'CopySource': bucket + '/archived.csv', 'StorageClass': 'DEEP_ARCHIVE'}, '--yes')
                cli(['cat', target + '/cold-copy.csv'], expected=4, raw=True)
                api('restore-object', {'Bucket': bucket, 'Key': 'cold-copy.csv',
                    'RestoreRequest': {'Days': 1}}, '--yes')
                assert cli(['cat', target + '/cold-copy.csv'], raw=True) == body.read_bytes()
                signed = run('share', target + '/archived.csv', '--expire', '5m')
                with opener.open(signed['data']['url']) as response:
                    assert 'ongoing-request="false"' in response.headers['x-amz-restore']
                    assert response.read() == body.read_bytes()
            check('26 local archived object restore permits verified temporary reads', restore_archive)


            def select_records():
                output = root / 'selected.csv'
                run('sql', obj, '--query', 'SELECT * FROM S3Object', '--input-format', 'csv',
                    '--output-format', 'csv', '--output', output, '--yes')
                assert output.read_bytes() == body.read_bytes()
                rejected_output = root / 'rejected-select.csv'
                run('sql', obj, '--query', 'SELECT * FROM S3Object WHERE 1 = 0',
                    '--input-format', 'csv', '--output-format', 'csv', '--output', rejected_output,
                    '--yes', expected=7)
                assert not rejected_output.exists()
            check('26 Select real Records stream and unsupported SQL rejection', select_records)
            def torrent():
                path = root / 'object.torrent'
                run('object torrent', obj, '--output', path)
                import hashlib
                torrent_bytes = path.read_bytes()
                payload = body.read_bytes()
                prefix = (f'd4:infod6:lengthi{len(payload)}e4:name8:data.csv'
                          '12:piece lengthi262144e6:pieces20:').encode()
                assert torrent_bytes == prefix + hashlib.sha1(payload).digest() + b'ee'

            check('26 torrent response is not ordinary object bytes', torrent)
            def annotations():
                import base64
                payload = b'annotation\x00binary\xff'
                common = {'Bucket': bucket, 'Key': 'folder/data.csv'}
                for name in ('one', 'two'):
                    api('put-object-annotation', {**common, 'AnnotationName': name,
                        'AnnotationPayload': base64.b64encode(payload).decode()}, '--yes')
                first = api('list-object-annotations', {**common, 'MaxAnnotationResults': 1})['data']['result']
                assert first['AnnotationCount'] == 1 and first['NextContinuationToken']
                second = api('list-object-annotations', {**common, 'MaxAnnotationResults': 1,
                    'ContinuationToken': first['NextContinuationToken']})['data']['result']
                assert second['AnnotationCount'] == 1 and not second.get('NextContinuationToken')
                saved = root / 'annotation.bin'
                api('get-object-annotation', {**common, 'AnnotationName': 'one'}, '--output', saved)
                assert saved.read_bytes() == payload
                api('put-object-annotation', {**common, 'AnnotationName': 'one',
                    'ObjectIfMatch': '"wrong"', 'AnnotationPayload': base64.b64encode(b'changed').decode()},
                    '--yes', expected=6)
                api('delete-object-annotation', {**common, 'AnnotationName': 'two'}, '--yes')
                assert cli(['cat', obj], raw=True) == body.read_bytes()
                # A new null-version write must not inherit the old generation's annotations.
                run('put', body, target + '/annotation-overwrite')
                temp = {'Bucket': bucket, 'Key': 'annotation-overwrite', 'AnnotationName': 'test'}
                api('put-object-annotation', {**temp, 'AnnotationPayload': base64.b64encode(payload).decode()}, '--yes')
                run('put', body, target + '/annotation-overwrite', '--overwrite', '--yes')
                api('get-object-annotation', temp, '--output', root / 'stale-annotation', expected=5)
            check('27 annotation encrypted CRUD pagination condition and generation isolation', annotations)
            kms_key = None

            def update_encryption():
                key = 'update-encryption-target'
                assert kms_key, 'local KMS fixture was not created'
                run('bucket encryption set', target, '--mode', 'sse-s3', '--yes')
                run('put', body, target + '/' + key)
                run('bucket encryption clear', target, '--yes')
                before = api('head-object', {'Bucket': bucket, 'Key': key, 'ChecksumMode': 'ENABLED'})
                api('update-object-encryption', {
                    'Bucket': bucket, 'Key': key, 'VersionId': 'null',
                    'ObjectEncryption': {'SSEKMS': {'KMSKeyArn': kms_key}},
                }, '--yes')
                after = api('head-object', {'Bucket': bucket, 'Key': key, 'ChecksumMode': 'ENABLED'})
                for field in ('etag', 'version_id', 'last_modified', 'content_length', 'checksum_sha256'):
                    assert before['data']['headers'][field] == after['data']['headers'][field], field
                signed = run('share', target + '/' + key, '--expire', '5m')
                with opener.open(signed['data']['url']) as response:
                    assert response.headers['x-amz-server-side-encryption'] == 'aws:kms'
                    assert response.read() == body.read_bytes()
                actual = cli(['cat', target + '/' + key], raw=True)
                assert actual == body.read_bytes(), 'encryption update overwrote object content: ' + repr(actual[:120])

            def kms():
                global kms_key
                settings_value = {
                    'backend': 'local', 'defaultKey': '', 'staticSecretKey': '',
                    'localKeyDirectory': str(root / 'kms'), 'filePermissions': '384',
                    'localCacheEnabled': False, 'address': '', 'token': '', 'namespace': '',
                    'mountPath': 'transit', 'kvMount': 'secret', 'keyPathPrefix': 'zigfs/kms/keys/',
                    'skipTlsVerification': False, 'caCertificatePath': '', 'clientCertificatePath': '',
                    'clientKeyPath': '', 'timeoutSeconds': '2', 'retryCount': '1',
                    'cacheEnabled': False, 'cacheTtlSeconds': '60', 'cacheCapacity': '10',
                }
                run('admin kms set', 'qa', '--file', file('kms.json', settings_value), '--yes')
                run('admin kms start', 'qa', '--yes')
                created = run('admin kms key create', 'qa', '--name', 'test-key', '--description', 'Validation', '--set-as-default', '--yes')
                run('admin kms key status', 'qa')
                value = created['data']['result']
                identifier = value.get('id') or value.get('key', {}).get('id')
                assert identifier, value
                kms_key = identifier
                run('admin kms key status', 'qa', identifier)
                run('bucket encryption set', target, '--mode', 'sse-kms', '--key-id', identifier, '--yes')
                run('put', body, target + '/kms-encrypted')
                run('admin kms key rotate', 'qa', identifier, '--yes')
                assert cli(['cat', target + '/kms-encrypted'], raw=True) == body.read_bytes()
                signed = run('share', target + '/kms-encrypted', '--expire', '5m')
                with opener.open(signed['data']['url']) as response:
                    assert response.headers['x-amz-server-side-encryption'] == 'aws:kms'
                run('bucket encryption clear', target, '--yes')
                run('admin kms key delete', 'qa', identifier, '--pending-window-days', '7', '--yes')
                run('admin kms key cancel-deletion', 'qa', identifier, '--yes')
            check('21 local KMS configuration key create status rotate schedule and cancel deletion', kms)
            check('27 in-place encryption update preserves object bytes', update_encryption)

            def watch():
                cursor = run('admin bucket watch get', 'qa', bucket, '--wait', '0')['data']['result']['next_cursor']
                run('put', body, target + '/watch-first')
                value = run('watch', target, '--cursor', cursor, '--count', '1', '--events', 'PUT', '--quiet')
                assert value['type'] == 'object-event' and value['data']['key'] == 'watch-first', value
                checkpoint = root / 'watch.cursor.json'
                process = subprocess.Popen([str(CLI), '--config', config, '--json', 'watch', target,
                    '--cursor-file', str(checkpoint), '--count', '1', '--events', 'PUT'],
                    env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    for _ in range(100):
                        if checkpoint.exists():
                            break
                        if process.poll() is not None:
                            raise AssertionError('watch exited before checkpoint')
                        time.sleep(0.05)
                    assert checkpoint.exists(), 'initial checkpoint not published'
                    run('put', body, target + '/watch-second')
                    stdout, stderr = process.communicate(timeout=10)
                    assert process.returncode == 0 and not stderr
                    lines = [json.loads(line) for line in stdout.splitlines()]
                    assert any(line['type'] == 'object-event' for line in lines)
                    assert checkpoint.stat().st_mode & 0o077 == 0
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()
            check('18 watch real event cursor filtering JSONL and private checkpoint', watch)

            def copy_part():
                destination = target + '/copy-part-result'
                created = run('multipart create', destination)
                upload_id = created['data']['result']['UploadId']
                copied = run('multipart copy-part', obj, destination, '--upload-id', upload_id,
                             '--part-number', '1', '--yes')['data']['result']
                copied = copied.get('CopyPartResult', copied)
                run('multipart complete', destination, '--upload-id', upload_id, '--file',
                    file('copy-complete.json', {'Parts': [{'PartNumber': 1, 'ETag': copied['ETag']}]}), '--yes')
                assert cli(['cat', destination], raw=True) == body.read_bytes()
            check('23 multipart copy-part completion preserves source bytes', copy_part)

            def unsupported_mutations():
                key = 'must-preserve'
                remote = target + '/' + key
                run('put', body, remote)
                cases = [
                    ('update-object-encryption', {'ObjectEncryption': {'SSEKMS': {
                        'KMSKeyArn': 'arn:aws:kms:us-east-1:123456789012:key/test-key'}}}, 1),
                    ('put-object-acl', {'ACL': 'private'}, 7),
                    ('put-object-retention', {'Retention': {'Mode': 'GOVERNANCE', 'RetainUntilDate': '2030-01-01T00:00:00Z'}}, 1),
                    ('put-object-legal-hold', {'LegalHold': {'Status': 'ON'}}, 1),
                    ('delete-object-annotation', {'AnnotationName': 'test'}, 0),
                ]
                for operation, fields, expected in cases:
                    api(operation, {'Bucket': bucket, 'Key': key, **fields}, '--yes', expected=expected)
                    assert cli(['cat', remote], raw=True) == body.read_bytes(), operation
            check('safety unsupported subresource mutations reject without replacing or deleting bytes', unsupported_mutations)

            def attributes():
                value = run('object attributes', obj, '--object-attributes', '["ObjectSize","ETag"]', '--all-pages')
                assert value['data']['pages'][0]['ObjectSize'] == body.stat().st_size, value
                run('object attributes', obj, '--object-attributes', '["ObjectParts"]', '--all-pages')
            check('23 attributes including no ObjectParts pagination', attributes)

            configurations = {
                'website': {'IndexDocument': {'Suffix': 'index.html'}},
                'logging': {},
                'request-payment': {'Payer': 'BucketOwner'},
                'accelerate': {'Status': 'Suspended'},
                'abac': {'Status': 'Enabled'},
            }
            for family, value in configurations.items():
                def configuration(family=family, value=value):
                    run('bucket ' + family + ' set', target, '--file', file(family + '.json', value), '--yes')
                    run('bucket ' + family + ' get', target)
                check('24/27 bucket ' + family + ' roundtrip', configuration)

            check('28 V1 object listing', lambda: run('object list', target, '--list-api', 'v1', '--page-size', '1'))

            def legacy():
                api('put-bucket-lifecycle', {'Bucket': bucket, 'LifecycleConfiguration': {
                    'Rules': [{'ID': 'legacy', 'Prefix': 'old/', 'Status': 'Enabled', 'Expiration': {'Days': 30}}]}}, '--yes')
                assert 'legacy' in json.dumps(api('get-bucket-lifecycle', {'Bucket': bucket}))
            check('28 legacy lifecycle schema roundtrip', legacy)
            check('28 legacy notification PUT', lambda: api('put-bucket-notification', {
                'Bucket': bucket, 'NotificationConfiguration': {}}, '--yes'))
            check('28 legacy notification GET', lambda: api('get-bucket-notification', {'Bucket': bucket}))

            def validation():
                for command, destination in (('version enable', target), ('version suspend', target),
                                              ('bucket lock clear', target), ('object legalhold enable', obj),
                                              ('object legalhold disable', obj)):
                    run(command, destination, '--unknown-value', 'no', '--yes', expected=2)
                run('watch', target, '--cursor-file', '-', expected=2)
                run('watch', target, '--cursor-file', root / 'cursor', '--cursor', 'bad', expected=2)
                run('event add', target, '--file', file('event.json', {}), '--arn', 'bad', '--yes', expected=2)
                run('rm', target, '--versions', '--recursive', '--page-size', '0', '--yes', expected=2)
            check('R06 and watch early argument rejection', validation)

            def help_boundaries():
                for command in ('rm', 'rb'):
                    value = json.dumps(run(command, '--help'))
                    assert 'Version cleanup' in value and 'concurrency' in value
                for command in ('admin group add-members', 'admin idp openid update', 'admin kms key create'):
                    assert 'ALIAS' in json.dumps(run(command, '--help'))
            check('R08 cleanup and management help boundaries', help_boundaries)

            def coverage():
                source = CLI.parents[2] / 'src'
                if not source.exists():
                    source = Path(__file__).resolve().parents[1] / 'src'
                paths = set()
                for name in ('catalog.zig', 'management_catalog.zig', 'compat_catalog.zig'):
                    paths.update(re.findall(r'\.path = "([^"]+)"', (source / name).read_text()))
                for command in sorted(paths):
                    result = run(command, '--help')
                    assert result['type'] == 'help', command
                operations = re.findall(r'\.path = "s3api ([^"]+)"', (source / 'catalog.zig').read_text())
                legacy = (source / 's3api.zig').read_text().split('pub const Operation = enum {', 1)[1].split('};', 1)[0]
                operations = sorted(set(operations) | set(re.findall(r'@"([^"]+)"', legacy)))
                for operation in operations:
                    run('s3api ' + operation, '--generate-input-skeleton')
                print(f'Covered {len(paths)} help paths and {len(operations)} skeletons', flush=True)
            check('29 all generated and compatibility help paths and S3 skeletons', coverage)
            from pending_protocol_checks import verify
            def launch(args):
                return subprocess.Popen([str(CLI), '--config', config, '--json', *args],
                                        env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            verify(check, run, root, AK, SK, launch)

            def authentication():
                run('admin user create', 'qa', '--file', file('limited-user.json', {
                    'name': 'limited', 'password': 'limited-test-password', 'policies': ['diagnostics'], 'enabled': True}), '--yes')
                run('admin auth logout', 'qa', '--yes')
                run('admin auth session', 'qa', expected=5)
                run('admin auth login', 'qa', '--file', file('limited-login.json', {
                    'username': 'limited', 'password': 'limited-test-password'}))
                try:
                    run('admin user list', 'qa', expected=4)
                    run('admin bucket watch get', 'qa', bucket, '--wait', '0', expected=4)
                finally:
                    run('admin auth logout', 'qa', '--yes')
                    login()
                run('admin user remove', 'qa', 'limited', '--yes')
                run('admin auth login', 'qa', '--file', '-', payload=json.dumps({
                    'username': 'qa', 'password': 'validation-password'}).encode())
                run('admin auth session', 'qa')
            check('19/20 logout removes session and limited principal cannot manage users or watch', authentication)

            def restart():
                global server
                cursor = run('admin bucket watch get', 'qa', bucket, '--wait', '0')['data']['result']['next_cursor']
                server.terminate()
                server.wait(timeout=10)
                server = subprocess.Popen([str(SERVER), '--env-file', str(settings)],
                                          cwd=root, env=env, stdout=log, stderr=log)
                for _ in range(200):
                    assert server.poll() is None
                    try:
                        opener.open(endpoint + '/health/ready', timeout=1).close()
                        break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise AssertionError('restart readiness timeout')
                login()
                assert run('version info', target)['data']['result']['Status'] == 'Suspended'
                run('admin kms key status', 'qa')
                assert cli(['cat', target + '/kms-encrypted'], raw=True) == body.read_bytes()
                assert cli(['cat', target + '/update-encryption-target'], raw=True) == body.read_bytes()
                assert cli(['cat', target + '/archived.csv'], raw=True) == body.read_bytes()
                api('get-object-annotation', {'Bucket': bucket, 'Key': 'folder/data.csv', 'AnnotationName': 'one'}, '--output', root / 'restarted-annotation')
                assert (root / 'restarted-annotation').read_bytes() == b'annotation\x00binary\xff'
                assert 'index.html' in json.dumps(run('bucket website get', target))
                run('admin bucket watch get', 'qa', bucket, '--cursor', cursor, '--wait', '0', expected=6)
            check('18/21 restart preserves versioning KMS decryption and rejects stale watch cursor', restart)

        finally:
            server.terminate()
            try:
                server.wait(timeout=10)
            except subprocess.TimeoutExpired:
                server.kill()
                server.wait()

REPORT.write_text(json.dumps(results, indent=2) + '\n')
failed = sum(item['status'] == 'fail' for item in results)
print(f'{len(results) - failed}/{len(results)} checks passed; report: {REPORT}')
sys.exit(bool(failed))
