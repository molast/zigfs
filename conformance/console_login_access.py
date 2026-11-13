#!/usr/bin/env python3
"""Console login admission based on usable page permissions."""
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

        def denied(call, code='ConsoleAccessDenied'):
            try:
                call()
            except HTTPError as error:
                assert error.code == 403
                assert json.loads(error.read())['code'] == code
            else:
                raise AssertionError('console login unexpectedly succeeded')

        try:
            start()
            token = login('file-root', 'file-root-password')
            for name, action, resource in [('none',None,'*'),('sts-only','sts:AssumeRole','*'),('decrypt-only','kms:Decrypt','arn:aws:kms:::*')]:
                statements = [] if action is None else [{'Effect':'Allow','Action':action,'Resource':resource}]
                api('policies', {'name':name,'document':json.dumps({'Version':'2012-10-17','Statement':statements})})
                api('users', {'name':name,'password':'login-password-123','policies':[name]})
                denied(lambda: login(name,'login-password-123'))
                reject(lambda: login(name,'wrong-password'), 401)
            for policy in ['readonly','writeonly']:
                api('users', {'name':policy,'password':'login-password-123','policies':[policy]})
                denied(lambda: login(policy,'login-password-123'))
            api('users', {'name':'kms-reader','password':'login-password-123','policies':['KMSAuditor']})
            reader = login('kms-reader','login-password-123')
            assert api('auth/session', bearer=reader)['capabilities']['kms_list']
            assert api('auth/session', bearer=reader)['policies'] == ['KMSAuditor']
            api('groups', {'name':'observers','enabled':True,'members':['kms-reader'],'policies':['diagnostics','KMSAuditor']})
            assert set(api('auth/session', bearer=reader)['policies']) == {'KMSAuditor','diagnostics'}
            api('groups/observers', {'name':'observers','enabled':False,'members':['kms-reader'],'policies':['diagnostics']}, method='PATCH')
            api('policies/KMSAuditor', {'name':'KMSAuditor','document':json.dumps({'Version':'2012-10-17','Statement':[]})}, method='PATCH')
            denied(lambda: api('auth/session', bearer=reader))
            role = api('roles', {'id':'','name':'sts-only-role','policies':['sts-only'],'trust_policy':json.dumps({'Version':'2012-10-17','Statement':[]})})
            issued = api('sts/assume-role', {'role_id':role['id'],'session_name':'test','duration_seconds':900})
            denied(lambda: api('auth/sts-login', {'username':issued['access_key'],'secret_key':issued['secret_key'],'session_token':issued['session_token']}, bearer=''))
            print('PASS: no-page password/STS login blocked with ConsoleAccessDenied; bad passwords remain 401; permitted KMS login and later page-permission removal')
        finally:
            stop()
            output.close()

if __name__ == '__main__':
    run()
