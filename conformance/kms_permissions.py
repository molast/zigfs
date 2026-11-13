#!/usr/bin/env python3
"""Policy-document driven KMS console permissions against an isolated server."""
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
            expected = {
                'consoleAdmin': (True, True, True), 'diagnostics': (False, False, False),
                'KMSAuditor': (True, True, True), 'KMSKeyAdministrator': (True, True, True),
                'KMSKeyUser': (True, False, True), 'readonly': (False, False, False),
                'readwrite': (False, False, False), 'writeonly': (False, False, False),
            }
            sessions = {}
            for index, (name, flags) in enumerate(expected.items()):
                # Assign copied JSON under unrelated names; no built-in-name authorization.
                document = api('policies/' + name)['document']
                custom_name = 'policy-' + str(index)
                api('policies', {'name':custom_name, 'document':document})
                user = 'user-' + str(index)
                api('users', {'name':user,'password':'test-password-123','policies':[custom_name]})
                if name in ['readonly','writeonly']:
                    reject(lambda: login(user, 'test-password-123'), 403)
                    continue
                bearer = login(user, 'test-password-123')
                sessions[name] = bearer
                caps = api('auth/session', bearer=bearer)['capabilities']
                assert (caps['kms'], caps['kms_list'], caps['kms_describe']) == flags, (name, caps)
                assert any(caps.values()), name
            api('settings/kms', {'backend':'local','localKeyDirectory':'/data/test'}, method='PUT')
            api('settings/kms/start', {}, method='POST')
            key = api('settings/kms/keys', {'name':'test-key'})
            key_id = key['id']
            user = sessions['KMSKeyUser']
            details = api('settings/kms/keys/action', {'id':key_id,'action':'describe'}, bearer=user)
            assert details['id'] == key_id and 'encrypted_key_material' not in details
            for path in ['settings','settings/kms','settings/kms/keys','users','buckets']:
                reject(lambda: api(path, bearer=user), 403)
            for action in ['rotate','delete','schedule-deletion','cancel-deletion']:
                reject(lambda: api('settings/kms/keys/action', {'id':key_id,'action':action}, bearer=user), 403)
            reject(lambda: api('settings/kms/keys', {'name':'denied'}, bearer=user), 403)
            auditor = sessions['KMSAuditor']
            keys = api('settings/kms/keys', bearer=auditor)
            assert not keys['canCreate']
            assert all(not item['permissions']['rotate'] and not item['permissions']['delete'] for item in keys['items'])
            reject(lambda: api('settings/kms/keys/action', {'id':key_id,'action':'rotate'}, bearer=auditor), 403)
            manager = sessions['KMSKeyAdministrator']
            api('settings/kms/keys/action', {'id':key_id,'action':'rotate'}, bearer=manager)
            assert api('settings/kms/keys/action', {'id':key_id,'action':'describe'}, bearer=manager)['version'] == 2
            reject(lambda: api('settings/kms', {}, method='PUT', bearer=manager), 403)
            # Existing login reacts immediately to a scoped explicit deny in its JSON.
            document = json.loads(api('policies/policy-4')['document'])
            document['Statement'].append({'Effect':'Deny','Action':'kms:DescribeKey','Resource':'arn:aws:kms:::key/' + key_id})
            api('policies/policy-4', {'name':'policy-4','document':json.dumps(document)}, method='PATCH')
            reject(lambda: api('settings/kms/keys/action', {'id':key_id,'action':'describe'}, bearer=user), 403)
            # Conditions are checked with the HTTP request context, not bypassed.
            conditional = {'Version':'2012-10-17','Statement':[{'Effect':'Allow','Action':'kms:DescribeKey','Resource':'arn:aws:kms:::*','Condition':{'Bool':{'aws:SecureTransport':'true'}}}]}
            api('policies/policy-4', {'name':'policy-4','document':json.dumps(conditional)}, method='PATCH')
            reject(lambda: api('settings/kms/keys/action', {'id':key_id,'action':'describe'}, bearer=user), 403)
            print('PASS: eight policy JSON documents under custom names; KMS describe/list/rotate authorization, configuration denial, explicit Deny and conditions')
        finally:
            stop()
            output.close()

if __name__ == '__main__':
    run()
