"""Real isolated ZigFS S3 integration plus local HTTP/TLS fault-injection tests.
Run from zigfs-cli: python3 tests/s3api_integration.py [zc] [zigfs]
"""
import base64
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
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
    def cli(args, code=0, raw=False):
        p = subprocess.run([str(CLI), *args], env=env, capture_output=True, timeout=15)
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
        protocol_version = 'HTTP/1.1'
        def log_message(self, *_): pass
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
        def do_PUT(self):
            Fixture.calls += 1
            payload = self.rfile.read(int(self.headers['Content-Length']))
            self.verify(payload)
            self.reply(503, b'<Error><Code>SlowDown</Code></Error>')

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
        print('PASS TLS fixture: default rejection, custom CA, hostname mismatch, explicit insecure.')
    finally:
        tls.shutdown(); tls.server_close()
print('All S3 protocol integration checks passed; only isolated local resources were used.')
