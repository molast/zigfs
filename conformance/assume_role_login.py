#!/usr/bin/env python3
"""AssumeRole issuance, console login, S3 access and revocation against an isolated server."""
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
import urllib.parse
from urllib.error import HTTPError


def run():
    binary = Path('zigfs/zig-out/bin/zigfs').resolve()
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
        base_env = {key: value for key, value in os.environ.items() if not key.startswith('ZIGFS_')}

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

        def s3(method, path, key=access, password=secret, payload=b'', extra=None, with_headers=False):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            date, host = stamp[:8], f'127.0.0.1:{port}'
            digest = hashlib.sha256(payload).hexdigest()
            sign_headers = {'host':host,'x-amz-content-sha256':digest,'x-amz-date':stamp,**(extra or {})}
            signed = ';'.join(sorted(sign_headers))
            canonical_headers = ''.join(f'{k}:{sign_headers[k]}\n' for k in sorted(sign_headers))
            parsed = urllib.parse.urlsplit(path)
            query = urllib.parse.urlencode(sorted(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)), quote_via=urllib.parse.quote)
            canonical = f'{method}\n{parsed.path}\n{query}\n{canonical_headers}\n{signed}\n{digest}'
            scope = f'{date}/us-east-1/s3/aws4_request'
            message = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
            signing = ('AWS4' + password).encode()
            for part in [date,'us-east-1','s3','aws4_request']:
                signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
            headers = {'Host':host,'x-amz-date':stamp,'x-amz-content-sha256':digest,'Authorization':f'AWS4-HMAC-SHA256 Credential={key}/{scope}, SignedHeaders={signed}, Signature={hmac.new(signing,message.encode(),hashlib.sha256).hexdigest()}'}
            headers.update(extra or {})
            req = urllib.request.Request(endpoint + path, method=method, data=payload if method in ('PUT','POST') else None, headers=headers)
            with urllib.request.urlopen(req, timeout=10) as response:
                body = response.read()
                return (body, response.headers) if with_headers else body

        try:
            start()
            token = login('file-root', 'file-root-password')
            doc = json.loads(api('policies/readonly')['document'])
            doc['Statement'].append({'Effect':'Allow','Action':'s3:ListAllMyBuckets','Resource':'arn:aws:s3:::*'})
            api('policies', {'name':'console-reader','document':json.dumps(doc)})
            role = api('roles', {'id':'', 'name':'reader', 'enabled':True, 'max_session_seconds':3600,
                'trust_policy':json.dumps({'Version':'2012-10-17','Statement':[]}), 'policies':['console-reader']})
            assert role['id']
            request = {'role_id':role['id'], 'session_name':'console', 'duration_seconds':900}
            reject(lambda: api('sts/assume-role', {**request, 'duration_seconds':4000}), 400)
            api('roles/reader', {**role, 'enabled':False}, method='PATCH')
            reject(lambda: api('sts/assume-role', request), 403)
            api('roles/reader', role, method='PATCH')
            permanent = api('access-keys', {'name':'permanent-regression'})
            issued = api('sts/assume-role', request)
            def check_access_keys():
                keys = [item['access_key'] for item in api('access-keys')['items']]
                assert permanent['access_key'] in keys
                assert issued['access_key'] not in keys
            check_access_keys()
            assert issued['expires_at'] > time.time()
            credentials = {'username':issued['access_key'], 'secret_key':issued['secret_key'], 'session_token':issued['session_token']}
            reject(lambda: api('auth/sts-login', {**credentials, 'secret_key':'invalid'}, bearer=''), 401)
            reject(lambda: api('auth/sts-login', {**credentials, 'session_token':'invalid'}, bearer=''), 401)
            session = api('auth/sts-login', credentials, bearer='')
            assert session['token']
            assert api('auth/session', bearer=session['token'])['policies'] == ['console-reader']
            s3('PUT', '/role-check')
            s3('PUT', '/role-check/test.txt', payload=b'role access')
            extra = {'x-amz-security-token':issued['session_token']}
            assert s3('GET', '/role-check/test.txt', key=issued['access_key'], password=issued['secret_key'], extra=extra) == b'role access'
            reject(lambda: s3('PUT', '/role-check/denied.txt', key=issued['access_key'], password=issued['secret_key'], extra=extra, payload=b'denied'), 403)
            reject(lambda: api('roles/reader', method='DELETE'), 409)
            assert any(item['access_key'] == issued['access_key'] for item in api('role-sessions')['items'])
            reject(lambda: api('role-sessions/' + issued['access_key'], method='DELETE'), 409)
            api('role-sessions/' + issued['access_key'] + '/revoke', {}, method='POST')
            check_access_keys()
            reject(lambda: api('auth/sts-login', credentials, bearer=''), 401)
            reject(lambda: api('auth/session', bearer=session['token']), 401)
            reject(lambda: s3('GET', '/role-check/test.txt', key=issued['access_key'], password=issued['secret_key'], extra=extra), 403)
            legacy_session = api('role-sessions')['items'][0]
            api('role-sessions/' + issued['access_key'], method='DELETE')
            assert not api('role-sessions')['items']
            reject(lambda: api('role-sessions/' + issued['access_key'], method='DELETE'), 404)
            check_access_keys()
            reject(lambda: api('auth/sts-login', credentials, bearer=''), 401)
            api('roles/reader', method='DELETE')
            assert not api('roles')['items']
            # Reproduce an old server deleting the role but retaining revoked sessions.
            stop()
            store = root / 'data/.zigfs/system/roles.json'
            snapshot = json.loads(store.read_text())
            snapshot['sessions'] = [legacy_session]
            store.write_text(json.dumps(snapshot))
            start()
            token = login('file-root', 'file-root-password')
            assert not api('roles')['items']
            assert api('role-sessions')['items'][0]['revoked']
            reject(lambda: api('auth/sts-login', credentials, bearer=''), 401)
            api('role-sessions/' + issued['access_key'], method='DELETE')
            assert not api('role-sessions')['items']
            print('PASS: role create/update, duration, disabled role, STS login, read-only S3, revoke and delete')
        finally:
            stop()
            output.close()


if __name__ == '__main__':
    run()
