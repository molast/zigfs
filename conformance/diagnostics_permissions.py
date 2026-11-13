#!/usr/bin/env python3
"""Diagnostics console permissions against an isolated server."""
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

        try:
            start()
            token = login('file-root', 'file-root-password')
            api('users', {'name':'diagnostic-user', 'password':'diagnostic-password', 'policies':['diagnostics']})
            diagnostic = login('diagnostic-user', 'diagnostic-password')
            caps = api('auth/session', bearer=diagnostic)['capabilities']
            assert caps['server_info'] and caps['console_log'] and caps['sts']
            assert not caps['admin'] and not caps['s3'] and not caps['kms']
            for path in ['system','health','settings/logs','settings/logs/query','settings/logs/download']:
                api(path, bearer=diagnostic)
            for path in ['users','roles','buckets','settings','storage','settings/audit-logs/query']:
                reject(lambda: api(path, bearer=diagnostic), 403)
            reject(lambda: api('settings/logs', {}, method='PUT', bearer=diagnostic), 403)
            original = api('policies/diagnostics')['document']
            api('policies', {'name':'custom-monitor', 'document':original})
            api('users', {'name':'custom-user', 'password':'custom-password', 'policies':['custom-monitor']})
            custom = login('custom-user', 'custom-password')
            assert api('auth/session', bearer=custom)['capabilities'] == caps
            modified = json.loads(original)
            modified['Statement'].append({'Effect':'Deny','Action':'admin:ConsoleLog','Resource':'*'})
            api('policies/custom-monitor', {'name':'custom-monitor','document':json.dumps(modified)}, method='PATCH')
            changed = api('auth/session', bearer=custom)['capabilities']
            assert changed['server_info'] and not changed['console_log']
            reject(lambda: api('settings/logs/query', bearer=custom), 403)
            api('system', bearer=custom)
            # Built-in names do not preserve privileges when their documents change.
            api('policies/diagnostics', {'name':'diagnostics','document':json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'s3:*','Resource':'arn:aws:s3:::*'}]})}, method='PATCH')
            changed = api('auth/session', bearer=diagnostic)['capabilities']
            assert changed['s3'] and not changed['server_info'] and not changed['console_log']
            reject(lambda: api('system', bearer=diagnostic), 403)
            api('buckets', bearer=diagnostic)
            print('PASS: diagnostics/custom policy contents, live policy edits, explicit Deny, system/log reads and management denial')
        finally:
            stop()
            output.close()

if __name__ == '__main__':
    run()
