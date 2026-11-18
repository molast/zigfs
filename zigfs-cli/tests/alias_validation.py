"""Signed alias verification, safe replacement and explicit offline setup."""
import hashlib
import hmac
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zc').resolve()
secret = 'alias-validation-secret'
requests = []
response = [200, b'<ListAllMyBucketsResult><Buckets/></ListAllMyBucketsResult>']


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        requests.append(self.path)
        assert self.path == '/?max-buckets=1'
        authorization = self.headers['Authorization']
        credential, signed, signature = authorization.removeprefix('AWS4-HMAC-SHA256 ').split(', ')
        access, date, region, service, terminal = credential.removeprefix('Credential=').split('/')
        assert access == 'TEST_ACCESS' and region == 'us-east-1' and service == 's3'
        assert terminal == 'aws4_request'
        names = signed.removeprefix('SignedHeaders=')
        headers = ''.join(name + ':' + self.headers[name].strip() + '\n' for name in names.split(';'))
        canonical = '\n'.join(['GET', '/', 'max-buckets=1', headers, names, self.headers['x-amz-content-sha256']])
        scope = '/'.join([date, region, service, terminal])
        to_sign = '\n'.join(['AWS4-HMAC-SHA256', self.headers['x-amz-date'], scope,
                             hashlib.sha256(canonical.encode()).hexdigest()])
        key = ('AWS4' + secret).encode()
        for item in (date, region, service, terminal):
            key = hmac.new(key, item.encode(), hashlib.sha256).digest()
        expected = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
        assert signature == 'Signature=' + expected
        assert self.headers['x-amz-security-token'] == 'TEST_TOKEN'
        status, body = response
        if body == b'timeout':
            time.sleep(2)
        self.send_response(status)
        if status == 301:
            self.send_header('Location', '/must-not-follow')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass


with tempfile.TemporaryDirectory(prefix='zc-alias-validation-') as directory:
    root = Path(directory)
    config = root / 'aliases.toml'
    env = {key: value for key, value in os.environ.items() if not key.startswith('ZC_')}
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    worker = threading.Thread(target=server.serve_forever, daemon=True)
    worker.start()
    endpoint = f'http://127.0.0.1:{server.server_port}'

    def run(endpoint=endpoint, expected=0, extra=()):
        proc = subprocess.run([str(binary), '--config', str(config), '--json', 'alias', 'set',
                               'test', endpoint, 'TEST_ACCESS', secret, '--session-token', 'TEST_TOKEN',
                               '--connect-timeout', '1', '--timeout', '1', *extra],
                              env=env, capture_output=True, text=True, timeout=8)
        assert proc.returncode == expected, (proc.returncode, proc.stdout, proc.stderr)
        assert not (proc.stderr if expected == 0 else proc.stdout)
        for sensitive in (secret, 'TEST_ACCESS', 'TEST_TOKEN'):
            assert sensitive not in proc.stdout + proc.stderr
        return json.loads(proc.stdout if expected == 0 else proc.stderr)

    try:
        response[:] = [404, b'404 page not found']
        assert 'S3 port' in run(expected=1)['error']['message']
        assert not config.exists() and not config.with_suffix('.toml.lock').exists()
        response[:] = [200, b'<ListAllMyBucketsResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><Buckets/></ListAllMyBucketsResult>']
        assert run()['data']['verification'] == 'verified'
        saved = config.read_bytes()
        cases = [
            (200, b'<html>Metrics console</html>', 1, 'S3 port'),
            (200, b'<ListAllMyBucketsResult>', 1, 'S3 port'),
            (404, b'404 page not found', 1, 'S3 port'),
            (403, b'<Error><Code>SignatureDoesNotMatch</Code><Message>' + secret.encode() + b'</Message></Error>', 4, 'rejected'),
            (403, b'<Error><Code>InvalidAccessKeyId</Code></Error>', 4, 'rejected'),
            (403, b'<Error><Code>ExpiredToken</Code></Error>', 4, 'rejected'),
            (403, b'<Error><Code>AccessDenied</Code></Error>', 4, 'not invalid'),
            (301, b'redirect', 1, 'redirected'),
            (503, b'unavailable', 3, 'temporarily'),
            (200, b'timeout', 3, 'timeout'),
        ]
        for status, body, exit_code, message in cases:
            response[:] = [status, body]
            before = len(requests)
            assert message in run(expected=exit_code)['error']['message']
            assert len(requests) == before + 1
            assert config.read_bytes() == saved
        with socket.socket() as unavailable:
            unavailable.bind(('127.0.0.1', 0))
            closed = f'http://127.0.0.1:{unavailable.getsockname()[1]}'
        assert run(closed, expected=3)['error']['code'] == 'NETWORK_ERROR'
        assert config.read_bytes() == saved
        before = len(requests)
        assert run(closed, extra=['--skip-check'])['data']['verification'] == 'skipped'
        assert len(requests) == before and config.read_bytes() != saved
    finally:
        server.shutdown()
        server.server_close()
        worker.join()
print('Alias verification passed: independent SigV4, endpoint/credentials/permissions, timeout, no redirects, atomic preservation, offline opt-out.')
