#!/usr/bin/env python3
"""Isolated root configuration, profile metadata and real S3 authentication checks."""
import datetime
import hashlib
import hmac
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
from urllib.error import HTTPError


def run():
    binary = Path('zigfs/zig-out/bin/zigfs').resolve()
    names = ['ZIGFS_ACCESS_KEY', 'ZIGFS_SECRET_KEY', 'ZIGFS_ROOT_USER', 'ZIGFS_ROOT_PASSWORD']
    with tempfile.TemporaryDirectory(prefix='zigfs-root-') as directory:
        root = Path(directory)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        access, secret = 'YamlAccessKey123456', '0123456789012345678901234567890123456789'
        config = root / '.env'
        config.write_text(f'''ZIGFS_ACCESS_KEY={access}
ZIGFS_SECRET_KEY={secret}
ZIGFS_ROOT_USER=file-root
ZIGFS_ROOT_PASSWORD=file-root-password
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
''')
        process, token = None, ''
        output = (root / 'process.log').open('w')
        base_env = {key: value for key, value in os.environ.items() if key not in names}

        def stop():
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=15)

        def start(overrides=None, expected_error=None):
            nonlocal process
            process = subprocess.Popen([str(binary), '--env-file', str(config)], env={**base_env, **(overrides or {})}, stdout=output, stderr=output)
            if expected_error:
                assert process.wait(timeout=15) != 0
                assert expected_error in (root / 'process.log').read_text()
                return
            for _ in range(200):
                assert process.poll() is None, 'server unexpectedly exited'
                try:
                    urllib.request.urlopen(endpoint + '/health/ready', timeout=1).close()
                    return
                except OSError:
                    time.sleep(.05)
            raise AssertionError('readiness timeout')

        def api(path, value=None, method=None, bearer=None):
            req = urllib.request.Request(endpoint + '/_admin/v1/' + path, data=None if value is None else json.dumps(value).encode(), headers={'Content-Type':'application/json', 'Authorization':'Bearer ' + (token if bearer is None else bearer)}, method=method)
            with urllib.request.urlopen(req, timeout=10) as response:
                data = response.read()
                return json.loads(data) if data else None

        def login(user, password):
            return api('auth/login', {'username':user, 'password':password}, bearer='')['token']

        def reject(call, status):
            try:
                call()
            except HTTPError as error:
                assert error.code == status
            else:
                raise AssertionError('request unexpectedly succeeded')

        def s3(method, path, key=access, password=secret, payload=b''):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            date, host = stamp[:8], f'127.0.0.1:{port}'
            digest = hashlib.sha256(payload).hexdigest()
            signed = 'host;x-amz-content-sha256;x-amz-date'
            canonical = f'{method}\n{path}\n\nhost:{host}\nx-amz-content-sha256:{digest}\nx-amz-date:{stamp}\n\n{signed}\n{digest}'
            scope = f'{date}/us-east-1/s3/aws4_request'
            message = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
            signing = ('AWS4' + password).encode()
            for part in [date,'us-east-1','s3','aws4_request']:
                signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
            headers = {'Host':host,'x-amz-date':stamp,'x-amz-content-sha256':digest,'Authorization':f'AWS4-HMAC-SHA256 Credential={key}/{scope}, SignedHeaders={signed}, Signature={hmac.new(signing,message.encode(),hashlib.sha256).hexdigest()}'}
            req = urllib.request.Request(endpoint + path, method=method, data=payload if method == 'PUT' else None, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as response:
                return response.read()

        try:
            start()
            token = login('file-root','file-root-password')
            session = api('auth/session')
            assert session['is_root'] and session['auth_source'] == 'deployment'
            assert session['root_access_key'] == access and session['session_access_key'] is None
            for path in ['auth/session','settings','access-keys']:
                assert secret not in json.dumps(api(path))
            api('buckets', {'name':'root-test','owner':'other-owner'})
            assert b'root-test' in s3('GET','/')
            s3('PUT','/root-test/object',payload=b'root configuration test')
            assert s3('GET','/root-test/object') == b'root configuration test'
            reject(lambda:s3('GET','/root-test/object',password='x'*40),403)
            presign = api('objects/presign', {'access_key':access,'bucket':'root-test','key':'object','method':'GET','expires_seconds':60})
            with urllib.request.urlopen(presign['url']) as response:
                assert response.read() == b'root configuration test'
            reject(lambda:api('access-keys',{'owner':'test','access_key':access,'secret_key':secret}),409)
            api('users',{'name':'reader','password':'reader-password','policies':['readonly']})
            reader = login('reader','reader-password')
            ordinary = api('auth/session',bearer=reader)
            assert ordinary['auth_source']=='local' and ordinary['root_access_key'] is None
            assert not ordinary['is_root']
            stop()
            env = dict(zip(names,['EnvAccessKey123456','e'*40,'env-root','env-root-password']))
            start(env)
            reject(lambda:login('file-root','file-root-password'),401)
            token=login('env-root','env-root-password')
            assert api('auth/session')['root_access_key']==env['ZIGFS_ACCESS_KEY']
            assert s3('GET','/root-test/object',key=env['ZIGFS_ACCESS_KEY'],password=env['ZIGFS_SECRET_KEY'])==b'root configuration test'
            reject(lambda:s3('GET','/root-test/object'),403)
            stop()
            start()
            token=login('file-root','file-root-password')
            assert s3('GET','/root-test/object')==b'root configuration test'
            stop()
            start({'ZIGFS_SECRET_KEY':''},expected_error='InvalidRootCredentials')
            # Restart preserves file credentials.
            start()
            token=login('file-root','file-root-password')
            assert api('auth/session')['root_access_key']==access
            stored=api('access-keys',{'owner':'collision-check'})
            stop()
            start({'ZIGFS_ACCESS_KEY':stored['access_key']},expected_error='RootAccessKeyConflict')
            print('PASS: dotenv/env precedence, root login/profile, S3 list/put/get/presign, rotation, no secret disclosure, ordinary user isolation, reserved key and stored-key collision')
        finally:
            stop()
            output.close()


if __name__ == '__main__':
    run()
