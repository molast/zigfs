#!/usr/bin/env python3
"""Scoped IAM resource capability and request authorization regression tests."""
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

        def document(action, resource, effect='Allow', condition=None):
            statement = {'Effect':effect,'Action':action,'Resource':resource}
            if condition: statement['Condition'] = condition
            return json.dumps({'Version':'2012-10-17','Statement':[statement]})

        def user(name, action, resource):
            doc = json.loads(document(action,resource))
            if name == 'scoped-reader':
                doc['Statement'].append({'Effect':'Allow','Action':'admin:ServerInfo','Resource':'arn:aws:s3:::*'})
            api('policies', {'name':name, 'document':json.dumps(doc)})
            api('users', {'name':name,'password':'test-password-123','policies':[name]})
            return login(name, 'test-password-123')

        try:
            start()
            token = login('file-root', 'file-root-password')
            admin = user('arn-admin', 'admin:*', 'arn:aws:s3:::*')
            assert api('auth/session', bearer=admin)['capabilities']['admin']
            api('users', bearer=admin)
            reader = user('scoped-reader', 's3:ListBucket', 'arn:aws:s3:::photos')
            assert api('auth/session', bearer=reader)['capabilities']['s3']
            api('buckets', {'name':'photos'})
            api('buckets', {'name':'private'})
            api('buckets/photos/objects', bearer=reader)
            reject(lambda: api('buckets/private/objects', bearer=reader), 403)
            reject(lambda: api('buckets', bearer=reader), 403)
            api('settings/kms', {'backend':'local','localKeyDirectory':'/data/test'}, method='PUT')
            api('settings/kms/start', {}, method='POST')
            key = api('settings/kms/keys', {'name':'scoped-key'})
            key_reader = user('scoped-key-reader', 'kms:DescribeKey', 'arn:aws:kms:::key/' + key['id'])
            caps = api('auth/session', bearer=key_reader)['capabilities']
            assert caps['kms'] and caps['kms_describe'] and not caps['kms_list']
            api('settings/kms/keys/action', {'id':key['id'],'action':'describe'}, bearer=key_reader)
            reject(lambda: api('settings/kms/keys/action', {'id':'other','action':'describe'}, bearer=key_reader), 403)
            reject(lambda: api('settings/kms/keys', bearer=key_reader), 403)
            # The management resource must be identical to the default-key guard.
            api('policies', {'name':'creator','document':document('kms:CreateKey','arn:aws:kms:::*')})
            api('users/arn-admin', {'name':'arn-admin','enabled':True,'policies':['arn-admin','creator']}, method='PATCH')
            admin = login('arn-admin', 'test-password-123')
            api('settings/kms/keys', {'name':'default-key','setAsDefault':True}, bearer=admin)
            trust = json.dumps({'Version':'2012-10-17','Statement':[{'Effect':'Allow','Principal':'*','Action':'sts:AssumeRole','Resource':'*'}]})
            role = api('roles', {'id':'','name':'reader-role','policies':['readonly'],'trust_policy':trust})
            other = api('roles', {'id':'','name':'other-role','policies':['readonly'],'trust_policy':trust})
            arn = 'arn:aws:iam::000000000000:role/reader-role'
            scoped_doc = json.loads(document('sts:AssumeRole',arn))
            scoped_doc['Statement'].append({'Effect':'Allow','Action':'admin:ServerInfo','Resource':'arn:aws:s3:::*'})
            api('policies', {'name':'scoped-assumer','document':json.dumps(scoped_doc)})
            # Retain a console page without adding another sts permission.
            api('policies', {'name':'page-only','document':document('admin:ServerInfo','arn:aws:s3:::*')})
            api('users', {'name':'scoped-assumer','password':'test-password-123','policies':['scoped-assumer','page-only']})
            assuming = login('scoped-assumer','test-password-123')
            assert api('auth/session', bearer=assuming)['capabilities']['sts']
            request = {'role_id':role['id'],'session_name':'test','duration_seconds':900}
            api('sts/assume-role', request, bearer=assuming)
            reject(lambda: api('sts/assume-role', {**request,'role_id':other['id']}, bearer=assuming), 403)
            api('policies/scoped-assumer', {'name':'scoped-assumer','document':document('sts:AssumeRole',arn,condition={'Bool':{'aws:SecureTransport':'true'}})}, method='PATCH')
            reject(lambda: api('sts/assume-role', request, bearer=assuming), 403)
            api('policies/scoped-assumer', {'name':'scoped-assumer','document':document('sts:AssumeRole',arn,'Deny')}, method='PATCH')
            assert not api('auth/session', bearer=assuming)['capabilities']['sts']
            reject(lambda: api('sts/assume-role', request, bearer=assuming), 403)
            print('PASS: management ARN, scoped bucket/key/role capabilities, default-key guard, cross-resource denial, STS transport condition and explicit Deny')
        finally:
            stop()
            output.close()

if __name__ == '__main__':
    run()
