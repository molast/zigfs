"""Real isolated ZigFS S3 integration plus local HTTP/TLS fault-injection tests.
Run from zigfs-cli: python3 tests/s3api_integration.py [zc] [zigfs]
"""
from concurrent.futures import ThreadPoolExecutor
import base64
import hashlib
import hmac
import fcntl
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import signal
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

CLI = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zc').resolve()
SERVER = Path(sys.argv[2] if len(sys.argv) > 2 else '../zigfs/zig-out/bin/zigfs').resolve()
AK = 'ZcIntegrationAccessKey123'
SK = 'zc-integration-secret-key-0123456789abcdef'
REGION = 'us-west-2'
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def request(url, method='GET', body=None, headers=None, expected=200):
    try:
        response = opener.open(urllib.request.Request(url, data=body, headers=headers or {}, method=method), timeout=10)
    except urllib.error.HTTPError as error:
        response = error
    data = response.read()
    assert response.status == expected, (method, urllib.parse.urlsplit(url).path, response.status, expected)
    return data

with tempfile.TemporaryDirectory(prefix='zc-s3api-') as tmp:
    root = Path(tmp)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ZIGFS_', 'ZC_')) and k not in ('HOME', 'XDG_CONFIG_HOME')}
    env.update(HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'config'))
    def cli(args, code=0, raw=False, stdin_input=None):
        p = subprocess.run([str(CLI), *args], env=env, capture_output=True, timeout=30, input=stdin_input)
        assert p.returncode == code, (args[:3], p.returncode, p.stderr.decode(errors='replace'))
        if code:
            assert not p.stdout
            value = json.loads(p.stderr)
        elif raw:
            assert not p.stderr
            return p.stdout
        else:
            assert not p.stderr
            value = json.loads(p.stdout)
        assert SK.encode() not in p.stdout + p.stderr and AK.encode() not in p.stdout + p.stderr
        return value
    def alias(name, endpoint, *options, ak=AK, sk=SK):
        cli(['--json', 'alias', 'set', name, endpoint, ak, sk, '--region', REGION, *options])
    def call(op, fields=None, name='real', options=(), code=0, raw=False):
        source = root / 'request.json'
        source.write_text(json.dumps(fields or {}))
        args = ([] if raw else ['--json']) + ['s3api', op, name, '--input-json', str(source), *map(str, options)]
        return cli(args, code, raw)

    # Skeleton/help must not need config, credentials or a network service.
    skeleton = cli(['s3api', 'get-object', '--generate-input-skeleton'])
    assert set(skeleton) == {'Bucket', 'Key'}
    assert cli(['--json', 's3api', 'put-object', '--help'])['type'] == 'help'
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
    endpoint = f'http://127.0.0.1:{port}'
    settings = root / '.env'
    settings.write_text(f'''ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}
ZIGFS_DATA_ROOT={root}/data
ZIGFS_S3_REGION={REGION}
ZIGFS_METRICS_ENABLED=false
ZIGFS_ROOT_USER=qa
ZIGFS_ROOT_PASSWORD=zc-integration-password
ZIGFS_ADMIN_SESSION_SECRET=zc-test-session-secret-0123456789abcdef
ZIGFS_ACCESS_KEY={AK}
ZIGFS_SECRET_KEY={SK}
''')
    log = (root / 'server.log').open('wb')
    server = subprocess.Popen([str(SERVER), '--env-file', str(settings)], cwd=root, env=env, stdout=log, stderr=log)
    try:
        for _ in range(200):
            if server.poll() is not None:
                raise RuntimeError('isolated ZigFS exited during startup')
            try:
                request(endpoint + '/health/ready'); break
            except (OSError, urllib.error.URLError):
                time.sleep(0.05)
        else:
            raise RuntimeError('isolated ZigFS readiness timeout')
        alias('real', endpoint)
        call('list-buckets')
        bucket = 'zc-protocol-test'
        url = endpoint + '/' + bucket
        call('create-bucket', {'Bucket': bucket, 'CreateBucketConfiguration': {'LocationConstraint': REGION}})
        listed = call('list-buckets')['data']['result']
        assert bucket in [b['Name'] for b in listed['Buckets']['Bucket']]
        call('head-bucket', {'Bucket': bucket})
        assert call('get-bucket-location', {'Bucket': bucket})['data']['result'] in ('', REGION)
        call('head-bucket', {'Bucket': 'missing-bucket'}, code=5)
        key = 'folder//../中 +%?&.bin'
        body = root / 'payload.bin'
        body.write_bytes(bytes(range(256)) * (48 * 1024))  # 12 MiB, larger than control buffers.
        args = {'Bucket': bucket, 'Key': key, 'ContentType': 'application/octet-stream', 'Metadata': {'test': 'unicode-key'}}
        call('put-object', args, options=('--body', body), code=2)
        call('put-object', args, options=('--body', body, '--yes'))
        head = call('head-object', {'Bucket': bucket, 'Key': key})['data']
        assert int(head['headers']['content_length']) == body.stat().st_size
        # Stored SHA256 is available even if PUT did not request a checksum algorithm.
        expected_sha = base64.b64encode(hashlib.sha256(body.read_bytes()).digest()).decode()
        assert call('head-object', {'Bucket': bucket, 'Key': key, 'ChecksumMode': 'ENABLED'})['data']['headers']['checksum_sha256'] == expected_sha
        ranged = root / 'range-with-checksum'
        range_result = call('get-object', {'Bucket': bucket, 'Key': key, 'Range': 'bytes=17-27', 'ChecksumMode': 'ENABLED'}, options=('--output', ranged))['data']
        assert range_result['headers']['checksum_sha256'] is None
        assert ranged.read_bytes() == body.read_bytes()[17:28]

        saved = root / 'download.bin'
        got = call('get-object', {'Bucket': bucket, 'Key': key}, options=('--output', saved))['data']
        assert got['bytes_written'] == body.stat().st_size
        assert hashlib.sha256(body.read_bytes()).digest() == hashlib.sha256(saved.read_bytes()).digest()
        call('get-object', {'Bucket': bucket, 'Key': key}, options=('--output', saved), code=6)
        assert call('get-object', {'Bucket': bucket, 'Key': key, 'Range': 'bytes=17-27'}, raw=True) == body.read_bytes()[17:28]
        call('get-object', {'Bucket': bucket, 'Key': key}, code=2)  # JSON cannot mix with raw output.
        call('get-object', {'Bucket': bucket, 'Key': key, 'IfMatch': '"wrong"'}, options=('--output', root / 'precondition.bin'), code=6)
        assert not (root / 'precondition.bin').exists()
        call('get-object', {'Bucket': bucket, 'Key': 'missing'}, options=('--output', root / 'missing.bin'), code=5)
        assert not (root / 'missing.bin').exists()
        call('put-object', {'Bucket': bucket, 'Key': 'second', 'Body': base64.b64encode(b'hello').decode()}, options=('--yes',))
        listing = call('list-objects-v2', {'Bucket': bucket, 'MaxKeys': 1})['data']['result']
        assert listing['IsTruncated'] == 'true' and listing['NextContinuationToken']
        page = call('list-objects-v2', {'Bucket': bucket, 'MaxKeys': 1, 'ContinuationToken': listing['NextContinuationToken']})['data']['result']
        assert page['Contents'][0]['Key'] != listing['Contents'][0]['Key']
        # Step 04: high-level operations share the protocol layer.
        cli(['--json', 'mb', 'real/zc-empty'])
        cli(['--json', 'bucket', 'stat', 'real/zc-empty'])
        assert cli(['--json', 'bucket', 'location', 'real/zc-empty'])['data']['result'] == REGION
        buckets = cli(['--json', 'ls', 'real'])['data']
        assert {'zc-empty', bucket} <= {x['entry']['Name'] for x in buckets['items']}
        listing = cli(['--json', 'ls', f'real/{bucket}', '--recursive', '--page-size', '1'])['data']
        assert listing['pages'] == 2 and listing['complete']
        assert {x['entry']['Key'] for x in listing['items']} == {key, 'second'}
        shallow = cli(['--json', 'object', 'list', f'real/{bucket}', '--list-api', 'v2', '--page-size', '1'])['data']
        assert any(x['kind'] == 'prefix' and x['entry']['Prefix'] == 'folder/' for x in shallow['items'])
        filtered = cli(['--json', 'ls', f'real/{bucket}/folder//../', '-r'])['data']
        assert [x['entry']['Key'] for x in filtered['items']] == [key]
        assert cli(['--json', 'ls', 'real/zc-empty'])['data']['count'] == 0
        cli(['--json', 'rb', 'real/zc-empty'], code=2)
        cli(['--json', 'rb', 'real/zc-empty', '--dry-run'])
        cli(['--json', 'bucket', 'stat', 'real/zc-empty'])
        cli(['--json', 'rb', f'real/{bucket}', '--yes'], code=6)
        call('head-object', {'Bucket': bucket, 'Key': key})
        cli(['--json', 'rb', 'real/zc-empty', '--yes'])
        cli(['--json', 'bucket', 'stat', 'real/zc-empty'], code=5)
        for extra in ('--force', '--with-lock', '--ignore-existing'):
            cli(['--json', 'mb', 'real/zc-empty', extra], code=2)
        legacy_listing = cli(['--json', 'ls', f'real/{bucket}', '--list-api', 'v1',
                              '--page-size', '1'])['data']
        assert legacy_listing['complete'] and len(legacy_listing['pages']) == 2
        legacy_names = set()
        for page in legacy_listing['pages']:
            legacy_names.update(item['Key'] for item in page.get('Contents', []))
            legacy_names.update(item['Prefix'] for item in page.get('CommonPrefixes', []))
        shallow_names = {item['entry'].get('Key', item['entry'].get('Prefix'))
                         for item in shallow['items']}
        assert legacy_names == shallow_names
        assert not cli(['--quiet', 'ls', f'real/{bucket}'], raw=True)
        assert cli(['ls', f'real/{bucket}', '--summarize'], raw=True).endswith(b'entries, 1 pages\n')
        alias('bad', endpoint, sk='wrong-secret-key-0123456789abcdef')
        call('list-buckets', name='bad', code=4)
        # Real short-lived credentials (token must be signed and transmitted).
        login = json.loads(request(endpoint + '/_admin/v1/auth/login', 'POST', json.dumps({'username': 'qa', 'password': 'zc-integration-password'}).encode(), {'Content-Type': 'application/json'}))
        auth = {'Authorization': 'Bearer ' + login['token'], 'Content-Type': 'application/json'}
        credentials = json.loads(request(endpoint + '/_admin/v1/access-keys', 'POST', b'{"ttl_seconds":600}', auth, 201))
        alias('temporary', endpoint, '--session-token', credentials['session_token'], ak=credentials['access_key'], sk=credentials['secret_key'])
        call('list-buckets', name='temporary')
        alias('missingtoken', endpoint, ak=credentials['access_key'], sk=credentials['secret_key'])
        call('list-buckets', name='missingtoken', code=4)
        readonly = json.loads(request(endpoint + '/_admin/v1/access-keys', 'POST',
            json.dumps({'policy': {'bucket_read': True, 'bucket_write': False, 'object_read': True, 'object_write': False}}).encode(), auth, 201))
        alias('readonly', endpoint, ak=readonly['access_key'], sk=readonly['secret_key'])
        cli(['--json', 'ls', 'readonly'])
        # The newly issued identity does not own the original private bucket.
        cli(['--json', 'ls', f'readonly/{bucket}'], code=4)
        cli(['--json', 'mb', 'readonly/zc-denied'], code=4)
        cli(['--json', 'rb', f'readonly/{bucket}', '--yes'], code=4)
        cli(['--json', 'ls', 'bad'], code=4)
        # Step 05: high-level single-object commands, real data and checksums.
        remote = f'real/{bucket}/high//../中 +%.bin'
        uploaded = cli(['--json', 'put', str(body), remote, '--checksum', 'SHA256',
             '--content-type', 'application/octet-stream', '--metadata', 'Origin=cli',
             '--metadata', 'empty='])
        assert uploaded['data']['headers']['checksum_sha256'] == base64.b64encode(hashlib.sha256(body.read_bytes()).digest()).decode()
        bad_digest = call('put-object', {'Bucket': bucket, 'Key': 'bad-digest', 'Body': base64.b64encode(b'bad-digest').decode(),
            'ChecksumAlgorithm': 'SHA256', 'ChecksumSHA256': base64.b64encode(bytes(32)).decode()}, options=('--yes',), code=1)
        assert bad_digest['error']['code'] == 'BadDigest'
        call('head-object', {'Bucket': bucket, 'Key': 'bad-digest'}, code=5)
        info = cli(['--json', 'stat', remote, '--checksum', 'SHA256'])['data']
        assert info['metadata'] == {'origin': 'cli', 'empty': ''}
        assert info['headers']['checksum_sha256'] == base64.b64encode(hashlib.sha256(body.read_bytes()).digest()).decode()
        assert cli(['--json', 'stat', remote])['data']['headers']['checksum_sha256'] is None
        cli(['--json', 'put', str(body), remote], code=6)
        cli(['--json', 'put', str(body), remote, '--overwrite'], code=2)
        cli(['--json', 'put', str(body), remote, '--overwrite', '--yes', '--checksum', 'SHA256'])
        dest = root / 'high-download.bin'
        verified = cli(['--json', 'cp', remote, str(dest), '--checksum-sha256', hashlib.sha256(body.read_bytes()).hexdigest()])['data']
        assert verified['checksum_verified'] and dest.read_bytes() == body.read_bytes()
        cli(['--json', 'get', remote, str(dest)], code=6)
        assert cli(['--json', 'get', remote, str(dest), '--overwrite', '--yes', '--checksum', 'SHA256'])['data']['checksum_verified']
        assert dest.read_bytes() == body.read_bytes()
        cli(['--json', 'get', remote, str(dest), '--overwrite', '--yes', '--checksum-sha256', '0' * 64], code=1)
        original = dest.read_bytes()
        cli(['--json', 'get', remote, str(dest), '--overwrite', '--yes', '--if-match', '"wrong"'], code=6)
        assert dest.read_bytes() == original
        cli(['--json', 'get', remote, str(dest), '--overwrite', '--yes', '--checksum-sha256', hashlib.sha256(body.read_bytes()).hexdigest()])
        assert cli(['cat', remote, '--offset', '17', '--length', '11'], raw=True) == body.read_bytes()[17:28]
        assert cli(['get', remote, '-', '--range', 'bytes=17-27', '--quiet'], raw=True) == body.read_bytes()[17:28]
        cli(['--json', 'get', remote, str(root / 'not-modified'), '--if-none-match', info['headers']['etag']], code=6)
        cli(['--json', 'get', remote, str(root / 'future'), '--if-modified-since', 'Wed, 01 Jan 2031 00:00:00 GMT'], code=6)
        cli(['--json', 'get', remote, str(root / 'past'), '--if-unmodified-since', 'Sat, 01 Jan 2000 00:00:00 GMT'], code=6)
        assert cli(['head', remote, '--bytes', '17'], raw=True) == body.read_bytes()[:17]
        cli(['--json', 'cat', remote], code=2)
        cli(['--json', 'get', remote, '-', '--checksum', 'SHA256'], code=2)
        cli(['--json', 'stat', remote, '--metadata', 'x=y'], code=2)
        cli(['--json', 'get', remote, str(root / 'range-invalid'), '--offset', str(2**64-1), '--length', '2'], code=2)
        cli(['--json', 'cp', remote, f'real/{bucket}/copy', '--dry-run'])
        cli(['--json', 'put', '-', remote], code=7)
        cli(['--json', 'put', str(root / 'missing-source'), remote, '--dry-run'])
        for payload, suffix in [(b'', 'zero'), (b'one\ntwo\nthree', 'lines'), (b'x' * 70000 + b'\nnext\n', 'long-line')]:
            source = root / suffix
            source.write_bytes(payload)
            obj = f'real/{bucket}/{suffix}'
            cli(['--json', 'cp', str(source), obj, '--checksum', 'SHA256'])
            target = root / (suffix + '-download')
            assert cli(['--json', 'object', 'get', obj, str(target), '--checksum', 'SHA256'])['data']['checksum_verified']
            assert target.read_bytes() == payload
            assert cli(['cat', obj, '--quiet'], raw=True) == payload
            assert cli(['head', obj, '--lines', '1'], raw=True) == (payload.splitlines(keepends=True)[0] if payload else b'')
        assert cli(['head', f'real/{bucket}/lines'], raw=True) == b'one\ntwo\nthree'
        cli(['--json', 'object', 'put', str(body), f'readonly/{bucket}/denied'], code=4)
        cli(['--json', 'get', f'real/{bucket}/missing', str(root / 'not-created')], code=5)
        assert not (root / 'not-created').exists()
        # Step 06: copy/move/delete only on unversioned buckets.
        source = f'real/{bucket}/lines'
        copied = f'real/{bucket}/copied//../中 +%&.txt'
        cli(['--json', 'cp', source, copied])
        assert cli(['cat', copied], raw=True) == b'one\ntwo\nthree'
        cli(['--json', 'cp', source, copied], code=6)
        cli(['--json', 'cp', source, copied, '--overwrite'], code=2)
        cli(['--json', 'cp', source, copied, '--overwrite', '--yes', '--metadata-directive', 'REPLACE', '--metadata', 'copy=yes', '--content-type', 'text/custom'])
        info = cli(['--json', 'stat', copied])['data']
        assert info['metadata'] == {'copy': 'yes'} and info['headers']['content_type'] == 'text/custom'
        cli(['--json', 'cp', source, copied, '--overwrite', '--yes', '--source-if-match', '"wrong"'], code=6)
        cli(['--json', 'cp', source, copied, '--overwrite', '--yes', '--if-match', '"wrong"'], code=6)
        cli(['--json', 'cp', source, copied, '--metadata', 'ignored=no', '--dry-run'], code=2)
        cli(['--json', 'cp', source, source, '--overwrite', '--yes'], code=2)
        alias('same-server', endpoint)
        cli(['--json', 'cp', source, f'same-server/{bucket}/other'], code=7)
        moved = f'real/{bucket}/moved'
        cli(['--json', 'mv', copied, moved], code=2)
        cli(['--json', 'mv', copied, moved, '--dry-run'])
        cli(['--json', 'stat', copied])
        cli(['--json', 'mv', copied, source, '--yes'], code=6)
        cli(['--json', 'stat', copied])
        cli(['--json', 'mv', copied, moved, '--yes'])
        cli(['--json', 'stat', copied], code=5)
        assert cli(['cat', moved], raw=True) == b'one\ntwo\nthree'
        cli(['--json', 'rm', moved], code=2)
        cli(['--json', 'rm', moved, '--dry-run'])
        cli(['--json', 'stat', moved])
        cli(['--json', 'rm', moved, '--yes'])
        cli(['--json', 'rm', moved, '--yes'])  # Idempotent missing-key deletion.
        cli(['--json', 'rm', f'readonly/{bucket}/lines', '--yes'], code=4)
        keys_file = root / 'delete-keys.json'
        keys_file.write_text(json.dumps(['zero', 'long-line', 'missing & <key>']))
        batch = cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--keys-file', str(keys_file), '--yes'])
        assert len(batch['data']['result']['Deleted']) == 3
        call('head-object', {'Bucket': bucket, 'Key': 'zero'}, code=5)
        keys_file.write_text(json.dumps({'Objects': [{'Key': 'missing-from-file'}], 'Quiet': False}))
        cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--file', str(keys_file), '--dry-run'])
        cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--file', str(keys_file), '--yes'])
        keys_file.write_text(json.dumps({'Objects': [{'Key': 'missing-version', 'VersionId': 'null'}]}))
        cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--file', str(keys_file), '--yes'])
        keys_file.write_text(json.dumps(['duplicate', 'duplicate']))
        cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--keys-file', str(keys_file), '--yes'], code=2)
        keys_file.write_text(json.dumps([f'missing-{i}' for i in range(1000)]))
        batch = cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--keys-file', str(keys_file), '--yes'])
        assert len(batch['data']['result']['Deleted']) == 1000
        keys_file.write_text(json.dumps([f'missing-{i}' for i in range(1001)]))
        assert cli(['--json', 'object', 'remove-batch', f'real/{bucket}', '--keys-file', str(keys_file), '--yes'])['data']['completed'] == 2
        invalid_batch = {'Objects':[{'Key':f'missing-{i}'} for i in range(1001)],'Unknown':True}
        keys_file.write_text(json.dumps(invalid_batch))
        cli(['--json','object','remove-batch',f'real/{bucket}','--file',str(keys_file),'--yes'],code=2)
        cli(['--json', 'mb', 'real/zc-versioned'])
        for state in ('Enabled', 'Suspended'):
            request(endpoint + '/_admin/v1/buckets/zc-versioned/configuration', 'PATCH', json.dumps({'versioning': state}).encode(), auth)
            cli(['--json', 'rm', 'real/zc-versioned/key', '--yes'])
            cli(['--json', 'cp', source, 'real/zc-versioned/key'])
        # Conditional Complete: real server, retained pending uploads, and racing publishers.
        def prepared_completion(key, data=b'conditional multipart'):
            remote = f'real/{bucket}/{key}'
            uid = cli(['--json', 'multipart', 'create', remote])['data']['result']['UploadId']
            part_path = root / ('part-' + uid)
            part_path.write_bytes(data)
            etag = cli(['--json', 'multipart', 'upload-part', remote, '--upload-id', uid,
                        '--part-number', '1', '--body', str(part_path), '--yes'])['data']['headers']['etag']
            path = root / ('complete-' + uid + '.json')
            path.write_text(json.dumps({'Parts': [{'PartNumber': 1, 'ETag': etag}]}))
            return ['--json', 'multipart', 'complete', remote, '--upload-id', uid,
                    '--file', str(path), '--yes'], uid

        conditional, pending_uid = prepared_completion('conditional')
        cli(conditional + ['--if-match', '"missing"'], code=6)
        cli(conditional + ['--if-none-match', '*'])
        assert cli(['cat', f'real/{bucket}/conditional'], raw=True) == b'conditional multipart'
        cli(conditional + ['--if-none-match', '*'], code=6)
        replacement, pending_uid = prepared_completion('conditional', b'replacement')
        cli(replacement + ['--if-none-match', '*'], code=6)
        stale_etag = cli(['--json', 'stat', f'real/{bucket}/conditional'])['data']['headers']['etag']
        cli(['--json', 'put', str(body), f'real/{bucket}/conditional', '--overwrite', '--yes'])
        cli(replacement + ['--if-match', stale_etag], code=6)
        assert cli(['cat', f'real/{bucket}/conditional'], raw=True) == body.read_bytes()
        assert len(cli(['--json', 'multipart', 'parts', f'real/{bucket}/conditional',
                        '--upload-id', pending_uid])['data']['items']) == 1
        fresh_etag = cli(['--json', 'stat', f'real/{bucket}/conditional'])['data']['headers']['etag']
        cli(replacement + ['--if-match', fresh_etag])
        assert cli(['cat', f'real/{bucket}/conditional'], raw=True) == b'replacement'

        # Start two independently prepared uploads together; exactly one may publish.
        for race in range(4):
            racers = [prepared_completion(f'conditional-race-{race}', bytes([65+i])*1024)
                      for i in range(2)]
            condition = ['--if-none-match', '*']
            if race >= 2:
                cli(['--json', 'put', str(body), f'real/{bucket}/conditional-race-{race}'])
                race_etag = cli(['--json', 'stat', f'real/{bucket}/conditional-race-{race}'])['data']['headers']['etag']
                condition = ['--if-match', race_etag]
            barrier = threading.Barrier(2)
            def publish(entry):
                barrier.wait(timeout=10)
                return subprocess.run([str(CLI), *entry[0], *condition],
                                      env=env, capture_output=True, timeout=30)
            with ThreadPoolExecutor(max_workers=2) as pool:
                results = list(pool.map(publish, racers))
            assert sorted(p.returncode for p in results) == [0, 6], results
            winner = next(i for i, result in enumerate(results) if result.returncode == 0)
            assert cli(['cat', f'real/{bucket}/conditional-race-{race}'], raw=True) == bytes([65+winner])*1024
            loser = 1 - winner
            cli(['--json', 'multipart', 'abort', f'real/{bucket}/conditional-race-{race}',
                 '--upload-id', racers[loser][1], '--yes'])

        # Automatic pipe defaults to create-only; rejection retains the original bytes.
        cli(['--json', 'pipe', f'real/{bucket}/safe-pipe'], stdin_input=b'original')
        cli(['--json', 'pipe', f'real/{bucket}/safe-pipe'], code=6, stdin_input=b'rejected')
        assert cli(['cat', f'real/{bucket}/safe-pipe'], raw=True) == b'original'
        cli(['--json', 'pipe', f'real/{bucket}/safe-pipe', '--overwrite'], code=2, stdin_input=b'')
        safe_etag = cli(['--json', 'stat', f'real/{bucket}/safe-pipe'])['data']['headers']['etag']
        cli(['--json', 'pipe', f'real/{bucket}/safe-pipe', '--overwrite', '--yes',
             '--if-match', safe_etag], stdin_input=b'updated')
        assert cli(['cat', f'real/{bucket}/safe-pipe'], raw=True) == b'updated'

        # Step 07: multipart lifecycle and paginated inspection.
        partfile = root / 'manual-part'
        partfile.write_bytes(b'p' * (5 * 1024 * 1024))
        tailfile = root / 'manual-tail'
        tailfile.write_bytes(b'tail')
        multi = f'real/{bucket}/manual-multi'
        created = cli(['--json', 'multipart', 'create', multi, '--content-type', 'text/multipart', '--metadata', 'workflow=manual'])
        upload_id = created['data']['result']['UploadId']
        spare = cli(['--json', 'multipart', 'create', f'real/{bucket}/manual-spare'])['data']['result']['UploadId']
        uploads = cli(['--json', 'multipart', 'list', f'real/{bucket}', '--prefix', 'manual-', '--page-size', '1'])['data']
        assert uploads['pages'] >= 2 and {x['UploadId'] for x in uploads['items']} >= {upload_id, spare}
        etags = []
        for n, path_part in [(1, partfile), (2, tailfile)]:
            result = cli(['--json', 'multipart', 'upload-part', multi, '--upload-id', upload_id, '--part-number', str(n), '--body', str(path_part), '--yes'])
            etags.append(result['data']['headers']['etag'])
        listed = cli(['--json', 'multipart', 'parts', multi, '--upload-id', upload_id, '--page-size', '1'])['data']
        assert listed['pages'] == 2 and [p['PartNumber'] for p in listed['items']] == ['1', '2']
        complete_file = root / 'complete.json'
        complete_file.write_text(json.dumps({'Parts': [{'PartNumber': n, 'ETag': e} for n, e in enumerate(etags, 1)]}))
        cli(['--json', 'multipart', 'complete', multi, '--upload-id', upload_id, '--file', str(complete_file)], code=2)
        cli(['--json', 'multipart', 'complete', multi, '--upload-id', upload_id, '--file', str(complete_file), '--yes'])
        assert cli(['cat', multi], raw=True) == partfile.read_bytes() + b'tail'
        assert cli(['--json', 'stat', multi])['data']['metadata']['workflow'] == 'manual'
        cli(['--json', 'multipart', 'abort', f'real/{bucket}/manual-spare', '--upload-id', spare, '--yes'])
        assert not cli(['--json', 'multipart', 'list', f'real/{bucket}', '--prefix', 'manual-'])['data']['items']
        auto_state = root / 'auto.json'
        cli(['--json', 'put', str(body), f'real/{bucket}/auto', '--multipart-threshold', '1MiB', '--part-size', '5MiB', '--state-file', str(auto_state)])
        assert json.loads(auto_state.read_text())['phase'] == 'completed'
        multi_checksum = base64.b64encode(hashlib.sha256(body.read_bytes()).digest()).decode()
        assert cli(['--json', 'stat', f'real/{bucket}/auto', '--checksum', 'SHA256'])['data']['headers']['checksum_sha256'] == multi_checksum
        multi_download = root / 'multipart-verified'
        assert cli(['--json', 'get', f'real/{bucket}/auto', str(multi_download), '--checksum', 'SHA256'])['data']['checksum_verified']
        assert multi_download.read_bytes() == body.read_bytes()

        assert auto_state.stat().st_mode & 0o077 == 0
        assert cli(['cat', f'real/{bucket}/auto'], raw=True) == body.read_bytes()
        denied_state = root / 'auto-denied.json'
        cli(['--json', 'put', str(tailfile), f'real/{bucket}/auto', '--part-size', '5MiB',
             '--state-file', str(denied_state)], code=6)
        assert json.loads(denied_state.read_text())['phase'] == 'completing'
        assert cli(['cat', f'real/{bucket}/auto'], raw=True) == body.read_bytes()

        cli(['--json', 'put', str(body), f'real/{bucket}/auto', '--resume', '--part-size', '5MiB', '--state-file', str(auto_state)], code=6)
        zero_source = root / 'auto-zero-source'
        zero_source.write_bytes(b'')
        cli(['--json','put',str(zero_source),f'real/{bucket}/auto-zero','--part-size','5MiB','--overwrite','--yes'])
        assert cli(['cat',f'real/{bucket}/auto-zero'],raw=True) == b''
        empty_multi = root / 'empty-multipart-verified'
        assert cli(['--json', 'get', f'real/{bucket}/auto-zero', str(empty_multi), '--checksum', 'SHA256'])['data']['checksum_verified']
        assert empty_multi.read_bytes() == b''

        cli(['--json','put',str(body),f'real/{bucket}/bad-limit','--part-size','4MiB','--overwrite','--yes'],code=2)
        cli(['--json','put',str(body),f'real/{bucket}/bad-limit','--part-size','5MiB','--max-parts','2','--overwrite','--yes'],code=2)
        for payload, suffix in [(b'', 'empty'), (b'pipe' * (2 * 1024 * 1024), 'binary')]:
            cli(['--json', 'pipe', f'real/{bucket}/pipe-{suffix}', '--part-size', '5MiB'], stdin_input=payload)
            assert cli(['cat', f'real/{bucket}/pipe-{suffix}'], raw=True) == payload
        cli(['--json', 'pipe', f'real/{bucket}/pipe-resume', '--resume', '--overwrite', '--yes'], code=2, stdin_input=b'')
        # A forwarding fault proxy retains real ZigFS storage and independent SigV4 validation.
        class UploadProxy(BaseHTTPRequestHandler):
            mode = 'part2-lost'
            calls = []
            protocol_version = 'HTTP/1.1'
            def log_message(self, *_): pass
            def handle(self):
                try: super().handle()
                except ConnectionResetError: pass
            def forward(self):
                payload = self.rfile.read(int(self.headers.get('Content-Length', '0')))
                UploadProxy.calls.append((self.command, self.path))
                conn = http.client.HTTPConnection('127.0.0.1', port, timeout=15)
                conn.request(self.command, self.path, body=payload, headers=dict(self.headers))
                reply = conn.getresponse()
                data = reply.read()
                lost = (UploadProxy.mode == 'part2-lost' and 'partNumber=2' in self.path or
                        UploadProxy.mode == 'complete-lost' and self.command == 'POST' and 'uploadId=' in self.path)
                if lost:
                    self.send_response(503); self.send_header('Content-Length', '0'); self.end_headers()
                else:
                    self.send_response(reply.status)
                    for k,v in reply.getheaders():
                        if k.lower() not in ('connection', 'transfer-encoding', 'content-length'):
                            self.send_header(k,v)
                    self.send_header('Content-Length', str(len(data)))
                    self.end_headers()
                    if self.command != 'HEAD': self.wfile.write(data)
                conn.close()
            do_GET = do_PUT = do_POST = do_DELETE = do_HEAD = forward
        proxy = ThreadingHTTPServer(('127.0.0.1', 0), UploadProxy)
        threading.Thread(target=proxy.serve_forever, daemon=True).start()
        try:
            alias('recovery', f'http://127.0.0.1:{proxy.server_port}')
            resume_source = root / 'resume-source'
            resume_source.write_bytes(body.read_bytes())
            checkpoint = root / 'resume.json'
            resume_args = ['--json', 'put', str(resume_source), f'recovery/{bucket}/resume', '--resume', '--part-size', '5MiB', '--state-file', str(checkpoint), '--overwrite', '--yes']
            cli(resume_args, code=3)
            state = json.loads(checkpoint.read_text())
            assert state['phase'] == 'uploading' and len(state['parts']) == 1
            assert sum('partNumber=2' in p for m,p in UploadProxy.calls) == 1
            count_before = len(UploadProxy.calls)
            cli([arg for arg in resume_args if arg not in ('--overwrite', '--yes')], code=6)
            assert len(UploadProxy.calls) == count_before
            resume_source.write_bytes(b'changed')
            cli(resume_args, code=6)
            resume_source.write_bytes(body.read_bytes())
            changed_layout = resume_args.copy()
            changed_layout[changed_layout.index('5MiB')] = '6MiB'
            cli(changed_layout, code=6)
            assert len(UploadProxy.calls) == count_before
            saved_checkpoint = checkpoint.read_text()
            damaged = json.loads(saved_checkpoint)
            damaged['parts'] = damaged['parts'] * 4
            checkpoint.write_text(json.dumps(damaged))
            cli(resume_args, code=2)
            checkpoint.write_text(saved_checkpoint)
            with open(str(checkpoint) + '.lock', 'rb') as held:
                fcntl.flock(held, fcntl.LOCK_EX | fcntl.LOCK_NB)
                cli(resume_args, code=6)
            assert len(UploadProxy.calls) == count_before
            # Altering a recorded remote part must be detected before more uploads.
            cli(['--json','multipart','upload-part',f'recovery/{bucket}/resume','--upload-id',state['upload_id'],'--part-number','1','--body',str(partfile),'--yes'])
            cli(resume_args, code=6)
            first = root / 'original-first'
            first.write_bytes(body.read_bytes()[:5*1024*1024])
            cli(['--json','multipart','upload-part',f'recovery/{bucket}/resume','--upload-id',state['upload_id'],'--part-number','1','--body',str(first),'--yes'])
            UploadProxy.mode = 'none'
            before_resume = len(UploadProxy.calls)
            cli(resume_args)
            resumed = UploadProxy.calls[before_resume:]
            assert not any('partNumber=1' in p for m,p in resumed)
            assert any('partNumber=2' in p for m,p in resumed)  # Unacknowledged remote part is reuploaded.
            assert cli(['cat', f'real/{bucket}/resume'], raw=True) == body.read_bytes()
            UploadProxy.mode = 'complete-lost'
            unknown = root / 'unknown.json'
            unknown_args = ['--json','put',str(tailfile),f'recovery/{bucket}/unknown','--part-size','5MiB','--state-file',str(unknown),'--overwrite','--yes']
            cli(unknown_args, code=3)
            assert json.loads(unknown.read_text())['phase'] == 'completing'
            assert cli(['cat',f'real/{bucket}/unknown'],raw=True) == b'tail'
            calls_before = len(UploadProxy.calls)
            cli([*unknown_args, '--resume'], code=6)
            assert len(UploadProxy.calls) == calls_before
        finally:
            proxy.shutdown(); proxy.server_close()
        # Step 08: plan before writes, recursive/multi-source operations and cleanup.
        cli(['--json','mb','real/zc-bulk'])
        tree = root / 'tree'
        (tree / 'sub').mkdir(parents=True)
        (tree / 'a.txt').write_bytes(b'alpha')
        (tree / 'sub' / 'b.txt').write_bytes(b'beta')
        (tree / 'skip.log').write_bytes(b'skip')
        preview = cli(['--json','cp',str(tree)+'/', 'real/zc-bulk/input/', '-r', '--include','*.txt','--dry-run'])
        assert preview['data']['planned'] == 2
        assert cli(['--json','ls','real/zc-bulk','-r'])['data']['count'] == 0
        uploaded = cli(['--json','cp',str(tree)+'/', 'real/zc-bulk/input/', '-r','--include','*.txt','--concurrency','2','--summary'])
        assert uploaded['data']['completed'] == 2 and uploaded['data']['failed'] == 0
        downloaded = root / 'download-tree'
        downloaded.mkdir()
        result = cli(['--json','cp','real/zc-bulk/input/',str(downloaded),'-r','--concurrency','2','--page-size','1'])
        assert result['data']['completed'] == 2
        assert (downloaded/'a.txt').read_bytes() == b'alpha' and (downloaded/'sub'/'b.txt').read_bytes() == b'beta'
        cli(['--json','cp','real/zc-bulk/input/', 'real/zc-bulk/input/nested/', '-r'],code=6)
        cli(['--json','cp',str(tree/'a.txt'),str(tree/'sub'/'b.txt'),'real/zc-bulk/multiple/','--concurrency','2'])
        assert cli(['cat','real/zc-bulk/multiple/a.txt'],raw=True) == b'alpha'
        cli(['--json','cp',str(tree/'a.txt'),'real/zc-bulk/exact','--summary'])
        assert cli(['cat','real/zc-bulk/exact'],raw=True) == b'alpha'
        cli(['--json','cp','real/zc-bulk/exact',str(root/'exact-download'),'--summary'])
        assert (root/'exact-download').read_bytes() == b'alpha'
        # Invalid per-object options must fail during planning, before the first write.
        cli(['--json','cp',str(tree/'a.txt'),str(tree/'sub'/'b.txt'),'real/zc-bulk/invalid/','--metadata-directive','REPLACE'],code=2)
        assert cli(['--json','ls','real/zc-bulk/invalid/','-r'])['data']['count'] == 0
        cli(['--json','cp',str(tree/'a.txt'),str(tree/'sub'/'b.txt'),'real/zc-bulk/large-preflight/','--multipart-threshold','1'])
        assert cli(['--json','ls','real/zc-bulk/large-preflight/','-r'])['data']['count'] == 2
        duplicate = root / 'duplicate'
        duplicate.mkdir()
        (duplicate/'a.txt').write_bytes(b'different')
        cli(['--json','cp',str(tree/'a.txt'),str(duplicate/'a.txt'),'real/zc-bulk/collision/'],code=6)
        assert cli(['--json','ls','real/zc-bulk/collision/','-r'])['data']['count'] == 0
        (tree/'link').symlink_to(root/'payload.bin')
        cli(['--json','cp',str(tree)+'/', 'real/zc-bulk/symlink/','-r'],code=2)
        (tree/'link').unlink()
        root_link = root / 'root-link'
        root_link.symlink_to(tree, target_is_directory=True)
        cli(['--json','cp',str(root_link)+'/', 'real/zc-bulk/root-symlink/','-r'],code=2)
        # A remote path that could escape the local destination fails before creating files.
        call('put-object',{'Bucket':'zc-bulk','Key':'unsafe/../escape','Body':'eA=='},options=('--yes',))
        cli(['--json','cp','real/zc-bulk/unsafe/',str(downloaded),'-r'],code=2)
        assert not (root/'escape').exists()
        call('put-object',{'Bucket':'zc-bulk','Key':'case/A.txt','Body':'eA=='},options=('--yes',))
        call('put-object',{'Bucket':'zc-bulk','Key':'case/a.txt','Body':'eQ=='},options=('--yes',))
        cli(['--json','cp','real/zc-bulk/case/',str(downloaded),'-r'],code=6)
        (downloaded/'redirect').symlink_to(root, target_is_directory=True)
        call('put-object',{'Bucket':'zc-bulk','Key':'symlink/redirect/escape','Body':'eA=='},options=('--yes',))
        cli(['--json','cp','real/zc-bulk/symlink/',str(downloaded),'-r'],code=6)
        assert not (root/'escape').exists()
        moved = cli(['--json','mv','real/zc-bulk/multiple/','real/zc-bulk/moved/','-r','--yes','--concurrency','2'])
        assert moved['data']['completed'] == 2
        assert cli(['--json','ls','real/zc-bulk/multiple/','-r'])['data']['count'] == 0
        cli(['--json','rm','real/zc-bulk/moved/','-r','--yes','--exclude','b.txt'])
        assert cli(['--json','ls','real/zc-bulk/moved/','-r'])['data']['count'] == 1
        cli(['--json','rm','real/zc-bulk/no-such/','-r','--yes','--fail-empty'],code=5)
        # Fail-fast does not schedule later waves; continue-on-error still returns failure.
        bad = cli(['--json','cp','real/zc-bulk/missing','real/zc-bulk/exact','real/zc-bulk/failfast/','--summary'],code=5)
        assert bad['error']['summary']['not_started'] == 1
        continued = cli(['--json','cp','real/zc-bulk/missing','real/zc-bulk/exact','real/zc-bulk/continue/','--continue-on-error'],code=5)
        assert continued['error']['summary']['completed'] == 1
        cli(['--json','rb','real/zc-versioned','--force','--dangerous','--yes'])
        pending_id = cli(['--json','multipart','create','real/zc-bulk/pending'])['data']['result']['UploadId']
        cli(['--json','rb','real/zc-bulk','--force','--yes'],code=6)
        cli(['--json','stat','real/zc-bulk/exact'])
        clean_preview = cli(['--json','rb','real/zc-bulk','--force','--dangerous','--dry-run'])
        assert clean_preview['data']['remove_bucket']
        cleaned = cli(['--json','rb','real/zc-bulk','--force','--dangerous','--yes'])
        assert cleaned['data']['removed_bucket']
        cli(['--json','bucket','stat','real/zc-bulk'],code=5)
        exec(Path(__file__).with_name('share_checks.py').read_text(), globals())
        print('PASS step 08: recursive and multi-source copy/move/remove, filters, collisions/traversal/symlink rejection, batch chunks, failure summaries and guarded cleanup.')
        print('PASS step 07: real conditional Complete, concurrent create/replace, automatic no-overwrite, lifecycle/pagination, pipe, lost-part recovery, policy/source mismatch protection and ambiguous Complete refusal.')
        print('PASS step 06: same-instance copy/move/delete, metadata, source/target conditions, confirmation, 1000-key batch and versioning guard.')
        print('PASS step 05: binary/empty/long-line transfers, aliases, SHA256, metadata, ranges, conditions and atomic overwrite protection.')
        print('PASS step 04: bucket lifecycle, full pagination, prefixes, aliases, dry-run, nonempty/permission protection.')
        print('PASS real ZigFS: signed read/write, 12 MiB stream, special keys, pagination, errors, temporary credentials.')
    finally:
        server.terminate()
        try: server.wait(timeout=10)
        except subprocess.TimeoutExpired: server.kill(); server.wait()
        log.close()

    # Independent HTTP fixture verifies signature itself and injects deterministic faults.
    class Fixture(BaseHTTPRequestHandler):
        mode = 'ok'
        calls = 0
        paths = []
        verified = 0
        active = 0
        peak = 0
        active_lock = threading.Lock()
        started = threading.Event()
        copies = 0
        deletes = 0
        posts = 0
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
        def handle(self):
            try: super().handle()
            except ConnectionResetError: pass  # Expected when timeout/limit tests close sockets.
        def verify(self, payload=b''):
            auth = self.headers['Authorization']
            bits = dict(v.strip().split('=', 1) for v in auth.split(' ', 1)[1].split(','))
            ak, scope = bits['Credential'].split('/', 1)
            names = bits['SignedHeaders'].split(';')
            canonical_headers = ''.join(f'{n}:{" ".join(self.headers[n].split())}\n' for n in names)
            parts = urllib.parse.urlsplit(self.path)
            pairs = [(urllib.parse.quote(k, safe='-_.~'), urllib.parse.quote(v, safe='-_.~')) for k,v in urllib.parse.parse_qsl(parts.query, keep_blank_values=True)]
            query = '&'.join(f'{k}={v}' for k,v in sorted(pairs))
            digest = hashlib.sha256(payload).hexdigest()
            assert self.headers['x-amz-content-sha256'] == digest
            canonical = '\n'.join([self.command, parts.path, query, canonical_headers, bits['SignedHeaders'], digest])
            message = '\n'.join(['AWS4-HMAC-SHA256', self.headers['x-amz-date'], scope, hashlib.sha256(canonical.encode()).hexdigest()])
            key = ('AWS4' + SK).encode()
            for component in scope.split('/'):
                key = hmac.new(key, component.encode(), hashlib.sha256).digest()
            assert ak == AK and hmac.compare_digest(bits['Signature'], hmac.new(key, message.encode(), hashlib.sha256).hexdigest())
            Fixture.verified += 1
        def reply(self, status, data, extra=None):
            self.send_response(status)
            self.send_header('Content-Length', str(len(data)))
            self.send_header('x-amz-request-id', 'fixture-request-123')
            for k, v in (extra or {}).items(): self.send_header(k, v)
            self.end_headers()
            if self.command != 'HEAD':
                try: self.wfile.write(data)
                except (BrokenPipeError, ConnectionResetError): pass
        def do_GET(self):
            Fixture.calls += 1; Fixture.paths.append((self.path, self.headers.get('Host')))
            try: self.verify()
            except Exception:
                self.reply(403, b'<Error><Code>SignatureDoesNotMatch</Code></Error>'); return
            mode = Fixture.mode
            if mode.startswith('bulk-'):
                if mode == 'bulk-plan-fail':
                    if 'continuation-token=' in self.path:
                        self.reply(403,b'<Error><Code>AccessDenied</Code></Error>'); return
                    self.reply(200,b'<ListBucketResult><IsTruncated>true</IsTruncated><NextContinuationToken>next</NextContinuationToken><Contents><Key>prefix/one</Key><Size>1</Size><ETag>&quot;e&quot;</ETag></Contents></ListBucketResult>'); return
                if mode == 'bulk-retry':
                    self.reply(503,b'<Error><Code>SlowDown</Code></Error>'); return
                with Fixture.active_lock:
                    Fixture.active += 1
                    Fixture.peak = max(Fixture.peak, Fixture.active)
                try:
                    if mode == 'bulk-interrupt':
                        Fixture.started.set()
                        time.sleep(2)
                    elif mode == 'bulk-parallel':
                        time.sleep(0.3)
                    self.reply(200,b'x' * (128*1024 if mode == 'bulk-rate' else 1))
                finally:
                    with Fixture.active_lock: Fixture.active -= 1
                return
            if mode.startswith('mutation-'):
                if 'versioning=' in self.path:
                    self.reply(200, b'<VersioningConfiguration/>'); return
                if self.command == 'HEAD':
                    value = '"changed"' if mode == 'mutation-changed' and Fixture.copies else '"copied"'
                    self.reply(200, b'', {'etag': value, 'last-modified': 'Mon, 16 Nov 2026 00:00:00 GMT'}); return
            if mode.startswith('checksum-'):
                payload = b'checksum-test'
                if mode == 'checksum-retry' and Fixture.calls == 1:
                    self.send_response(200); self.send_header('Content-Length', '1000'); self.end_headers()
                    self.wfile.write(b'partial'); self.wfile.flush(); self.close_connection = True; return
                checksum = base64.b64encode(hashlib.sha256(payload if mode in ('checksum-ok', 'checksum-retry') else b'wrong').digest()).decode()
                self.reply(200, payload, {} if mode == 'checksum-missing' else {'x-amz-checksum-sha256': checksum}); return
            if mode.startswith('pages'):
                token = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query).get('continuation-token', [None])[0]
                assert token in (None, 'a+/=&中')
                if token and mode == 'pages-fail':
                    self.reply(403, b'<Error><Code>AccessDenied</Code></Error>'); return
                more = token is None or mode == 'pages-loop'
                continuation = '<ContinuationToken>a+/=&amp;中</ContinuationToken>' if more else ''
                self.reply(200, ('<ListAllMyBucketsResult><Buckets><Bucket><Name>' +
                    ('first-bucket' if token is None else 'second-bucket') +
                    '</Name></Bucket></Buckets>' + continuation + '</ListAllMyBucketsResult>').encode()); return
            if mode == 'retry' and Fixture.calls < 3:
                self.reply(503, b'<Error><Code>SlowDown</Code></Error>'); return
            if mode == 'redirect':
                self.reply(307, b'', {'Location': 'http://127.0.0.1:1/credential-leak'}); return
            if mode == 'timeout':
                time.sleep(2); self.reply(200, b'<ListAllMyBucketsResult/>'); return
            if mode == 'malformed':
                self.reply(200, b'<ListAllMyBucketsResult>'); return
            if mode == 'oversize':
                self.reply(200, b'x' * (4 * 1024 * 1024 + 1)); return
            if mode == 'embedded-error':
                self.reply(200, b'<Error><Code>InternalError</Code></Error>'); return
            if mode == 'denied':
                self.reply(403, f'<Error><Code>AccessDenied</Code><Message>{SK}</Message></Error>'.encode()); return
            if mode == 'partial':
                self.send_response(200); self.send_header('Content-Length', '100000'); self.end_headers()
                self.wfile.write(b'partial'); self.wfile.flush(); self.close_connection = True; return
            self.reply(200, b'<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>')
        do_HEAD = do_GET
        def do_DELETE(self):
            Fixture.deletes += 1
            Fixture.calls += 1
            self.verify()
            self.reply(503, b'<Error><Code>SlowDown</Code></Error>')
        def do_PUT(self):
            Fixture.calls += 1
            payload = self.rfile.read(int(self.headers['Content-Length']))
            self.verify(payload)
            if Fixture.mode == 'part-missing-etag':
                self.reply(200, b''); return
            if self.headers.get('x-amz-copy-source'):
                Fixture.copies += 1
                if Fixture.mode == 'mutation-embedded':
                    self.reply(200, b'<Error><Code>InternalError</Code></Error>'); return
                if Fixture.mode == 'mutation-empty':
                    self.reply(200, b'<CopyObjectResult/>'); return
                if Fixture.mode.startswith('mutation-'):
                    self.reply(200, b'<CopyObjectResult><ETag>&quot;copied&quot;</ETag></CopyObjectResult>'); return
            self.reply(503, b'<Error><Code>SlowDown</Code></Error>')

        def do_POST(self):
            Fixture.posts += 1
            payload = self.rfile.read(int(self.headers['Content-Length']))
            self.verify(payload)
            if 'uploadId=' in self.path:
                assert b'<CompleteMultipartUpload' in payload and b'<PartNumber>1</PartNumber>' in payload
                if Fixture.mode == 'complete-error':
                    self.reply(200, b'<Error><Code>InternalError</Code></Error>'); return
                if Fixture.mode == 'complete-empty':
                    self.reply(200, b'<CompleteMultipartUploadResult/>'); return
                self.reply(503, b'<Error><Code>SlowDown</Code></Error>'); return
            assert self.headers['Content-MD5'] == base64.b64encode(hashlib.md5(payload).digest()).decode()
            assert b'<Key>one</Key>' in payload and b'<Key>two</Key>' in payload
            if Fixture.mode == 'mutation-batch-transient':
                self.reply(503, b'<Error><Code>SlowDown</Code></Error>'); return
            if Fixture.mode == 'mutation-batch-missing':
                self.reply(200, b'<DeleteResult><Deleted><Key>one</Key></Deleted></DeleteResult>'); return
            self.reply(200, f'<DeleteResult><Deleted><Key>one</Key></Deleted><Error><Key>two</Key><Code>AccessDenied</Code><Message>{SK}</Message></Error></DeleteResult>'.encode())

    def fixture_server(tls=False):
        http = ThreadingHTTPServer(('127.0.0.1', 0), Fixture)
        if tls:
            ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            ctx.load_cert_chain(root / 'cert.pem', root / 'key.pem')
            http.socket = ctx.wrap_socket(http.socket, server_side=True)
        thread = threading.Thread(target=http.serve_forever, daemon=True); thread.start()
        return http

    fixture = fixture_server()
    fixture_url = f'http://127.0.0.1:{fixture.server_port}'
    try:
        alias('fixture', fixture_url)
        bulk_dest = root / 'bulk-fixture-download'
        bulk_dest.mkdir()
        Fixture.mode, Fixture.calls = 'bulk-plan-fail', 0
        outcome = cli(['--json','cp','fixture/test-bucket/prefix/',str(bulk_dest),'-r'],code=4)
        assert outcome['error']['completed'] == 0 and not list(bulk_dest.iterdir()) and Fixture.calls == 2
        Fixture.mode, Fixture.calls, Fixture.peak = 'bulk-parallel', 0, 0
        cli(['--json','cp','fixture/test-bucket/one','fixture/test-bucket/two',str(bulk_dest),'--concurrency','2'])
        assert Fixture.peak == 2
        Fixture.mode, Fixture.calls = 'bulk-retry', 0
        outcome = cli(['--json','cp','fixture/test-bucket/missing1','fixture/test-bucket/missing2',str(bulk_dest),'--concurrency','2','--continue-on-error','--retry-attempts','3'],code=3)
        assert Fixture.calls == 4 and outcome['error']['summary']['retries_used'] == 2
        Fixture.mode = 'bulk-rate'
        started = time.monotonic()
        cli(['--json','cp','fixture/test-bucket/rated',str(bulk_dest/'rated'),'--rate-limit','128KiB','--summary'])
        assert time.monotonic() - started >= 1.2
        Fixture.mode, Fixture.calls = 'bulk-interrupt', 0
        Fixture.started.clear()
        interrupted = subprocess.Popen([str(CLI),'--json','cp','fixture/test-bucket/interrupt1','fixture/test-bucket/interrupt2',str(bulk_dest),'--summary'],env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
        assert Fixture.started.wait(5)
        interrupted.send_signal(signal.SIGINT)
        out,err=interrupted.communicate(timeout=8)
        assert interrupted.returncode == 130 and not out
        assert json.loads(err)['error']['summary']['not_started'] == 1
        assert Fixture.calls == 1 and not (bulk_dest/'interrupt1').exists()
        for mode, code in [('complete-error', 1), ('complete-empty', 1), ('complete-transient', 3)]:
            Fixture.mode, Fixture.posts = mode, 0
            call('complete-multipart-upload', {'Bucket':'test-bucket','Key':'key','UploadId':'test-id','MultipartUpload':{'Parts':[{'PartNumber':1,'ETag':'"etag"'}]}}, name='fixture', options=('--yes',), code=code)
            assert Fixture.posts == 1
        Fixture.mode = 'part-missing-etag'
        call('upload-part', {'Bucket':'test-bucket','Key':'key','UploadId':'test-id','PartNumber':1,'Body':'aGVsbG8='}, name='fixture', options=('--yes',), code=1)
        for mode, code in [('mutation-embedded', 1), ('mutation-empty', 1), ('mutation-changed', 6), ('mutation-delete-fail', 3)]:
            Fixture.mode, Fixture.calls, Fixture.copies, Fixture.deletes = mode, 0, 0, 0
            outcome = cli(['--json', 'mv', 'fixture/test-bucket/source', 'fixture/test-bucket/dest', '--yes'], code=code)
            assert Fixture.copies == 1
            assert Fixture.deletes == (1 if mode == 'mutation-delete-fail' else 0)
            assert outcome['error']['copy_completed'] == (mode in ('mutation-changed', 'mutation-delete-fail'))
        keys = root / 'fixture-keys.json'
        keys.write_text(json.dumps(['one', 'two']))
        for mode, code in [('mutation-batch-partial', 1), ('mutation-batch-missing', 1), ('mutation-batch-transient', 3)]:
            Fixture.mode, Fixture.posts = mode, 0
            outcome = cli(['--json', 'object', 'remove-batch', 'fixture/test-bucket', '--keys-file', str(keys), '--yes'], code=code)
            assert Fixture.posts == 1
            if mode == 'mutation-batch-partial':
                inner = outcome['error']['cause']['error']
                assert inner['failed'] == 1 and inner['result']['Error'] == [{'Key': 'two', 'Code': 'AccessDenied'}]
        Fixture.mode, Fixture.posts = 'mutation-batch-partial', 0
        partial_bulk = cli(['--json','object','remove-batch','fixture/test-bucket','--keys-file',str(keys),'--yes','--summary'],code=1)['error']['summary']
        assert partial_bulk['delete_confirmed'] == 1 and partial_bulk['delete_failed'] == 1 and partial_bulk['delete_outcome_unknown'] == 0
        assert Fixture.posts == 1
        for mode, code in [('checksum-ok', 0), ('checksum-retry', 0), ('checksum-bad', 1), ('checksum-missing', 7)]:
            Fixture.mode, Fixture.calls = mode, 0
            target = root / (mode + '.bin')
            target.write_bytes(b'existing')
            cli(['--json', 'get', 'fixture/test-bucket/key', str(target), '--overwrite', '--yes', '--checksum', 'SHA256'], code=code)
            assert target.read_bytes() == (b'checksum-test' if code == 0 else b'existing')
            assert Fixture.calls == (2 if mode == 'checksum-retry' else 1)
        Fixture.mode, Fixture.calls = 'partial', 0
        partial = root / 'high-partial.bin'
        partial.write_bytes(b'preserved')
        cli(['--json', 'get', 'fixture/test-bucket/key', str(partial), '--overwrite', '--yes', '--retry-attempts', '2'], code=3)
        assert partial.read_bytes() == b'preserved' and Fixture.calls == 2
        for mode, code in [('pages', 0), ('pages-fail', 4), ('pages-loop', 1)]:
            Fixture.mode, Fixture.calls = mode, 0
            result = cli(['--json', 'ls', 'fixture', '--page-size', '1'], code=code)
            assert Fixture.calls == 2
            if not code:
                assert result['data']['count'] == 2 and result['data']['complete']
        Fixture.mode, Fixture.calls = 'retry', 0
        call('delete-bucket', {'Bucket': 'test-bucket'}, name='fixture', options=('--yes',), code=3)
        assert Fixture.calls == 1  # DELETE cannot be retried after an ambiguous response.
        for mode, code, count in [('ok',0,1), ('retry',0,3), ('redirect',6,1), ('denied',4,1), ('malformed',1,1), ('oversize',1,1), ('embedded-error',1,1)]:
            Fixture.mode, Fixture.calls = mode, 0
            result = call('list-buckets', name='fixture', code=code)
            assert Fixture.calls == count, (mode, Fixture.calls)
            assert result['error' if code else 'data']['request_id'] == 'fixture-request-123'
        Fixture.mode, Fixture.calls = 'timeout', 0
        start = time.monotonic()
        call('list-buckets', name='fixture', options=('--timeout','1','--connect-timeout','1'), code=3)
        assert time.monotonic() - start < 3 and Fixture.calls == 1
        Fixture.mode, Fixture.calls = 'ok', 0
        call('list-buckets', {'Unknown': True}, name='fixture', code=2)
        call('list-buckets', name='fixture', options=('-H','Authorization:leak'), code=2)
        call('list-buckets', name='fixture', options=('-H','x-amz-date:bad'), code=2)
        assert Fixture.calls == 0
        call('list-buckets', name='fixture', options=('-H','x-amz-test:  a   b  ',))
        cli(['--json','-H','x-amz-test:','s3api','list-buckets','fixture'])
        # Virtual-hosted Host and canonical path must be signed together.
        alias('dns', f'http://localhost:{fixture.server_port}', '--bucket-lookup', 'dns')
        call('head-object', {'Bucket':'test-bucket','Key':'nested//../中 +%'}, name='dns')
        assert Fixture.paths[-1][1] == f'test-bucket.localhost:{fixture.server_port}'
        assert Fixture.paths[-1][0] == '/nested//../%E4%B8%AD%20%2B%25'
        Fixture.calls = 0
        call('put-object', {'Bucket':'test-bucket','Key':'test','Body':'aGVsbG8='}, name='fixture', options=('--yes',), code=3)
        assert Fixture.calls == 1, 'PUT must not retry even a transient failure'
        Fixture.mode, Fixture.calls = 'partial', 0
        partial = root / 'partial.bin'
        call('get-object', {'Bucket':'test-bucket','Key':'test'}, name='fixture', options=('--output',partial,'--retry-attempts','2'), code=3)
        assert not partial.exists() and Fixture.calls == 2
        assert Fixture.verified > 5
        print('PASS HTTP fixture: independent SigV4, retries, timeout, redirect refusal, limits, partial cleanup, redaction.')
    finally:
        fixture.shutdown(); fixture.server_close()

    # Real TLS handshake fixture, with its own disposable private CA/certificate.
    subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-keyout',str(root/'key.pem'),'-out',str(root/'cert.pem'),'-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    tls = fixture_server(tls=True)
    try:
        Fixture.mode = 'ok'
        alias('tls', f'https://localhost:{tls.server_port}')
        call('list-buckets', name='tls', code=3)
        call('list-buckets', name='tls', options=('--ca-cert',root/'cert.pem'))
        call('list-buckets', name='tls', options=('--insecure',))
        alias('mismatch', f'https://127.0.0.1:{tls.server_port}', '--ca-cert',str(root/'cert.pem'))
        call('list-buckets', name='mismatch', code=3)
        call('list-buckets', name='mismatch', options=('--insecure',))
        post_tls = ThreadingHTTPServer(('127.0.0.1', 0), PostFixture)
        post_context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        post_context.load_cert_chain(root/'cert.pem', root/'key.pem')
        post_tls.socket = post_context.wrap_socket(post_tls.socket, server_side=True)
        threading.Thread(target=post_tls.serve_forever, daemon=True).start()
        try:
            PostFixture.mode = 'ok'
            fields_path.write_text(json.dumps(fixture_fields))
            alias('posttls', f'https://localhost:{post_tls.server_port}')
            post_args = ['--json', 'object', 'post', 'posttls/test-bucket', '--file', str(post_source), '--fields-file', str(fields_path), '--yes']
            cli(post_args, code=3)
            cli(post_args + ['--ca-cert', str(root/'cert.pem')])
            cli(post_args + ['--insecure'])
            cli(post_args + ['--endpoint', f'https://127.0.0.1:{post_tls.server_port}', '--ca-cert', str(root/'cert.pem')], code=3)
        finally:
            post_tls.shutdown()
            post_tls.server_close()
        print('PASS TLS fixture: default rejection, custom CA, hostname mismatch, explicit insecure.')
    finally:
        tls.shutdown(); tls.server_close()
print('All S3 protocol integration checks passed; only isolated local resources were used.')
