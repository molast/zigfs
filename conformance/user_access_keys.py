#!/usr/bin/env python3
"""Isolated user-key API/S3 regression. Build ZigFS and the Admin binary first.

Usage: python3 conformance/user_access_keys.py --admin-bin /tmp/zigfs-admin
"""
import argparse
import datetime
import hashlib
import hmac
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.parse
import urllib.error
import urllib.request


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--admin-bin', required=True, type=Path)
    parser.add_argument('--zig-bin', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    args = parser.parse_args()
    api_port, bff_port = free_port(), free_port()
    while bff_port == api_port:
        bff_port = free_port()
    processes = []
    with tempfile.TemporaryDirectory(prefix='zigfs-user-keys-') as directory:
        root = Path(directory)
        config = root / 'config.yaml'
        config.write_text(f'''server:
  api_address: 127.0.0.1:{api_port}
s3:
  public_endpoint: http://127.0.0.1:{api_port}
observability:
  metrics_enabled: false
storage:
  data_root: {root}/data
admin:
  username: qa
  password: user-key-test-only
  session_secret: user-key-test-only-session-secret-123456789
''')
        log = (root / 'services.log').open('w')
        jar = http.cookiejar.CookieJar()
        browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(jar))
        api_base = f'http://127.0.0.1:{api_port}'
        bff_base = f'http://127.0.0.1:{bff_port}'

        def response(client, request, status):
            try:
                result = client.open(request, timeout=10)
            except urllib.error.HTTPError as error:
                result = error
            data = result.read()
            # Do not echo credential response bodies on failure.
            assert result.status == status, (request.get_method(), urllib.parse.urlsplit(request.full_url).path, result.status, status)
            return data

        def req(method, path, body=None, status=200):
            request = urllib.request.Request(bff_base + '/api/v1' + path, method=method,
                data=json.dumps(body).encode() if body is not None else None,
                headers={'Content-Type': 'application/json'})
            data = response(browser, request, status)
            return json.loads(data) if data else None

        def start(binary, env=None, extra=()):
            process = subprocess.Popen([str(binary.resolve()), *extra], env=env, stdout=log, stderr=log)
            processes.append(process)
            return process

        def ready(base, process):
            for _ in range(200):
                if process.poll() is not None:
                    raise RuntimeError('test service exited; check configuration/build')
                try:
                    with urllib.request.urlopen(base + '/health/ready', timeout=1) as result:
                        if result.status == 200:
                            return
                except (OSError, urllib.error.URLError):
                    pass
                time.sleep(0.05)
            raise RuntimeError('service readiness timeout')

        def s3(key, method='GET', path='/', status=200, with_token=True, extra_headers=None):
            now = datetime.datetime.now(datetime.timezone.utc)
            date, stamp = now.strftime('%Y%m%d'), now.strftime('%Y%m%dT%H%M%SZ')
            empty_hash = hashlib.sha256(b'').hexdigest()
            headers = {'host': f'127.0.0.1:{api_port}', 'x-amz-date': stamp, 'x-amz-content-sha256': empty_hash}
            if key.get('session_token') and with_token:
                headers['x-amz-security-token'] = key['session_token']
            headers.update(extra_headers or {})
            target = urllib.parse.urlsplit(path)
            query = '&'.join(f'{urllib.parse.quote(k, safe="-_.~")}={urllib.parse.quote(v, safe="-_.~")}' for k, v in sorted(urllib.parse.parse_qsl(target.query, keep_blank_values=True)))
            names = ';'.join(sorted(headers))
            canonical = '\n'.join([method, target.path, query, ''.join(f'{name}:{headers[name]}\n' for name in sorted(headers)), names, empty_hash])
            scope = f'{date}/us-east-1/s3/aws4_request'
            message = '\n'.join(['AWS4-HMAC-SHA256', stamp, scope, hashlib.sha256(canonical.encode()).hexdigest()])
            signing_key = ('AWS4' + key['secret_key']).encode()
            for value in [date, 'us-east-1', 's3', 'aws4_request']:
                signing_key = hmac.new(signing_key, value.encode(), hashlib.sha256).digest()
            signature = hmac.new(signing_key, message.encode(), hashlib.sha256).hexdigest()
            headers['Authorization'] = f"AWS4-HMAC-SHA256 Credential={key['access_key']}/{scope}, SignedHeaders={names}, Signature={signature}"
            request = urllib.request.Request(api_base + path, method=method, headers=headers,
                                             data=b'' if method == 'PUT' else None)
            return response(urllib.request.build_opener(), request, status)

        try:
            zig = start(args.zig_bin, extra=('--config', str(config)))
            ready(api_base, zig)
            env = dict(os.environ, ZIGFS_ADMIN_LISTEN=f'127.0.0.1:{bff_port}', ZIGFS_ENDPOINT=api_base,
                       ZIGFS_WEB_ROOT=str(Path('zigfs-admin/web/dist').resolve()))
            admin = start(args.admin_bin, env=env)
            ready(bff_base, admin)
            for method, suffix in [('GET', ''), ('POST', ''), ('PATCH', '/unknown'), ('DELETE', '/unknown')]:
                req(method, '/users/alice/access-keys' + suffix, status=401)
            req('POST', '/auth/login', {'username': 'qa', 'password': 'user-key-test-only'})
            for name in ['alice', 'bob', 'qa']:
                req('POST', '/users', {'name': name, 'password': 'user-password-only', 'enabled': True, 'policies': []}, 201)
            full = dict(bucket_read=True, bucket_write=True, object_read=True, object_write=True, bypass_governance_retention=False)
            read = dict(full, bucket_write=False, object_write=False)
            path = '/users/alice/access-keys'
            req('GET', '/users/missing/access-keys', status=404)
            req('POST', '/users/missing/access-keys', {'policy': full}, 404)
            req('POST', path, {'ttl_seconds': 59}, 400)
            req('POST', path, {'ttl_seconds': 43201}, 400)
            key = req('POST', path, {'owner': 'qa', 'policy': full}, 201)
            assert key['owner'] == 'user:alice' and key['secret_key']
            key_path = path + '/' + key['id']
            listed = req('GET', path)['items']
            assert len(listed) == 1 and 'secret_key' not in listed[0] and 'session_token' not in listed[0]
            assert not req('GET', '/users/bob/access-keys')['items']
            for method, body in [('PATCH', {'enabled': False}), ('DELETE', None)]:
                req(method, '/users/bob/access-keys/' + key['id'], body, 404)
            req('DELETE', '/users/alice', status=409)
            req('POST', path, {'access_key': 'bad', 'secret_key': 'short'}, 400)
            req('POST', path, {'expires_at': '2000-01-01T00:00:00Z'}, 400)
            # Actual SigV4 access and owner boundaries.
            # This key explicitly grants bucket read, including listing.
            s3(key)
            s3(key, 'PUT', '/alice-key-test')
            assert b'alice-key-test' in s3(key)
            bob = req('POST', '/users/bob/access-keys', {'policy': full}, 201)
            assert b'alice-key-test' not in s3(bob)
            s3(bob, 'HEAD', '/alice-key-test', 403)
            readonly = req('POST', path, {'policy': read}, 201)
            s3(readonly, 'PUT', '/read-only-denied', 403)
            # Screenshot form fields work for both administrator and user keys.
            expiry = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(days=30)).strftime('%Y-%m-%dT%H:%M:%SZ')
            fields = dict(access_key='CustomMixedUserKey123', secret_key='0123456789abcdef0123456789abcdef', name='backup', description='daily backup', expires_at=expiry, inherit_policy=True)
            inherited = req('POST', path, fields, 201)
            assert inherited['access_key'] == fields['access_key'] and inherited['secret_key'] == fields['secret_key']
            assert inherited['name'] == 'backup' and inherited['description'] == 'daily backup' and inherited['inherit_policy']
            assert inherited['expires_at'] == expiry and 'session_token' not in inherited
            req('POST', path, fields, 409)
            external = req('POST', '/access-keys', dict(fields, access_key='CustomMixedAdminKey123'), 201)
            assert external['owner'] == 'qa' and external['name'] == 'backup' and external['inherit_policy']
            s3(external)
            assert all('secret_key' not in item for item in req('GET', '/access-keys')['items'])
            # Dynamic user/group inheritance, resource bounds, and explicit Deny.
            s3(key, 'PUT', '/alice-key-test/public.txt')
            s3(key, 'PUT', '/alice-key-test/private.txt')
            s3(inherited, 'GET', '/alice-key-test/public.txt', 403)
            user = req('GET', '/users/alice')
            req('PATCH', '/users/alice', dict(user, policies=['readonly']))
            s3(inherited, 'GET', '/alice-key-test/public.txt')
            s3(inherited, 'PUT', '/alice-key-test/public.txt', 403)
            group = req('POST', '/groups', dict(name='writers', enabled=True, policies=['readwrite'], members=['alice']), 201)
            s3(inherited, 'PUT', '/alice-key-test/public.txt')
            group_patch = dict(name=group['name'], description=group.get('description', ''), enabled=False, policies=group.get('policies', []), members=group.get('members', []))
            req('PATCH', '/groups/writers', group_patch)
            s3(inherited, 'PUT', '/alice-key-test/public.txt', 403)
            group_patch['enabled'] = True
            req('PATCH', '/groups/writers', group_patch)
            deny = dict(Version='2012-10-17', Statement=[dict(Effect='Deny', Action='s3:*', Resource='arn:aws:s3:::alice-key-test/private*')])
            req('POST', '/policies', dict(name='deny-private', document=json.dumps(deny)), 201)
            user = req('GET', '/users/alice')
            req('PATCH', '/users/alice', dict(user, policies=['readonly', 'deny-private']))
            s3(inherited, 'GET', '/alice-key-test/private.txt', 403)
            s3(inherited, 'GET', '/alice-key-test/public.txt')
            scoped = dict(Version='2012-10-17', Statement=[dict(Effect='Allow', Action='s3:GetObject', Resource='arn:aws:s3:::alice-key-test/public*')])
            req('POST', '/policies', dict(name='scoped', document=json.dumps(scoped)), 201)
            user = req('GET', '/users/alice')
            req('PATCH', '/users/alice', dict(user, policies=['scoped'], groups=[]))
            s3(inherited, 'GET', '/alice-key-test/public.txt')
            s3(inherited, 'GET', '/alice-key-test/private.txt', 403)
            req('PATCH', '/policies/scoped', dict(name='scoped', document=json.dumps(dict(scoped, Statement=[]))))
            s3(inherited, 'GET', '/alice-key-test/public.txt', 403)
            req('PATCH', '/policies/scoped', dict(name='scoped', document=json.dumps(scoped)))
            s3(inherited, 'GET', '/alice-key-test/public.txt')
            # Both editors persist sparse changes and enforce their key JSON policy.
            inherited_path = path + '/' + inherited['id']
            external_path = '/access-keys/' + external['id']
            req('PATCH', inherited_path, {'policy_document': '{broken'}, 400)
            patch = req('PATCH', inherited_path, {'name': 'edited backup', 'description': 'edited description', 'clear_expiry': True})
            assert patch['name'] == 'edited backup' and patch['description'] == 'edited description' and 'expires_at' not in patch and 'secret_key' not in patch
            patch = req('PATCH', inherited_path, {'expires_at': expiry})
            assert patch['name'] == 'edited backup' and patch['expires_at'] == expiry
            empty_doc = json.dumps(dict(Version='2012-10-17', Statement=[]))
            req('PATCH', inherited_path, {'policy_document': empty_doc})
            s3(inherited, 'GET', '/alice-key-test/public.txt', 403)
            req('PATCH', inherited_path, {'policy_document': json.dumps(scoped)})
            s3(inherited, 'GET', '/alice-key-test/public.txt')
            # A permissive key policy cannot exceed its inherited parent policy.
            all_doc = json.dumps(dict(Version='2012-10-17', Statement=[dict(Effect='Allow', Action='s3:*', Resource='arn:aws:s3:::*')]))
            req('PATCH', inherited_path, {'policy_document': all_doc})
            s3(inherited, 'GET', '/alice-key-test/private.txt', 403)
            req('PATCH', inherited_path, {'inherit_policy': False})
            s3(inherited, 'GET', '/alice-key-test/private.txt')
            req('PATCH', inherited_path, {'inherit_policy': True, 'policy_document': json.dumps(scoped)})
            req('PATCH', external_path, {'policy_document': empty_doc, 'name': 'external edited'})
            s3(external, status=403)
            req('PATCH', external_path, {'policy_document': ''})
            s3(external)
            # Conditions use actual signed S3 request context, not client assertions.
            conditional = req('POST', path, {'policy': full}, 201)
            conditional_path = path + '/' + conditional['id']
            def condition_policy(condition, action='s3:GetObject', resource='arn:aws:s3:::alice-key-test/*'):
                document = dict(Version='2012-10-17', Statement=dict(Effect='Allow', Action=action, Resource=resource, Condition=condition))
                req('PATCH', conditional_path, {'policy_document': json.dumps(document)})
            condition_policy({
                'StringEquals': {'aws:username': 'alice', 's3:authType': 'REST-HEADER'},
                'IpAddress': {'aws:SourceIp': '127.0.0.0/8'},
                'Bool': {'aws:SecureTransport': False},
                'DateGreaterThan': {'aws:CurrentTime': '2020-01-01T08:00:00+08:00'},
                'NumericLessThan': {'s3:signatureAge': 10000},
            })
            s3(conditional, 'GET', '/alice-key-test/public.txt')
            condition_policy({'IpAddress': {'aws:SourceIp': '192.0.2.0/24'}})
            s3(conditional, 'GET', '/alice-key-test/public.txt', 403, extra_headers={'x-forwarded-for': '192.0.2.1'})
            condition_policy({'Bool': {'aws:SecureTransport': True}})
            s3(conditional, 'GET', '/alice-key-test/public.txt', 403, extra_headers={'x-forwarded-proto': 'https'})
            condition_policy({'StringEquals': {'s3:authType': 'POST'}})
            s3(conditional, 'GET', '/alice-key-test/public.txt?authType=POST', 403)
            condition_policy({'StringLike': {'s3:prefix': 'public*'}, 'NumericLessThanEquals': {'s3:max-keys': 10}}, 's3:ListBucket', 'arn:aws:s3:::alice-key-test')
            s3(conditional, 'GET', '/alice-key-test?list-type=2&prefix=public&max-keys=5')
            s3(conditional, 'GET', '/alice-key-test?list-type=2&prefix=private&max-keys=5', 403)
            s3(conditional, 'GET', '/alice-key-test?list-type=2&prefix=public&max-keys=20', 403)
            condition_policy({'Null': {'aws:Referer': True}, 'StringEqualsIfExists': {'aws:Referer': 'trusted'}})
            s3(conditional, 'GET', '/alice-key-test/public.txt')
            s3(conditional, 'GET', '/alice-key-test/public.txt', 403, extra_headers={'referer': 'untrusted'})
            document = dict(Version='2012-10-17', Statement=[
                dict(Effect='Allow', Action='s3:*', Resource='*'),
                dict(Effect='Deny', Action='s3:GetObject', Resource='*', Condition={'Bool': {'aws:SecureTransport': False}})])
            req('PATCH', conditional_path, {'policy_document': json.dumps(document)})
            s3(conditional, 'GET', '/alice-key-test/public.txt', 403)
            condition_policy({}, resource='arn:aws:s3:::${aws:username}-key-test/public*')
            s3(conditional, 'GET', '/alice-key-test/public.txt')
            s3(conditional, 'GET', '/alice-key-test/private.txt', 403)
            for condition in [{'Unknown': {'aws:username': 'alice'}}, {'StringEquals': {'aws:Unknown': 'x'}}, {'NumericEqualsIfExists': {'s3:max-keys': 'bad'}}]:
                invalid = dict(Version='2012-10-17', Statement=dict(Effect='Allow', Action='s3:*', Resource='*', Condition=condition))
                req('PATCH', conditional_path, {'policy_document': json.dumps(invalid)}, 400)
            # Administrator presigning defers conditions to URL consumption.
            condition_policy({'StringEquals': {'s3:authType': 'REST-QUERY-STRING'}}, resource='arn:aws:s3:::*')
            signed = req('POST', '/objects/presign', dict(access_key=conditional['access_key'], bucket='alice-key-test', key='public.txt', method='GET', expires_seconds=60))
            response(urllib.request.build_opener(), urllib.request.Request(signed['url'], headers=signed.get('required_headers', {})), 200)
            s3(conditional, 'GET', '/alice-key-test/public.txt', 403)
            condition_policy({'IpAddress': {'aws:SourceIp': '192.0.2.0/24'}}, resource='arn:aws:s3:::*')
            response(urllib.request.build_opener(), urllib.request.Request(signed['url'], headers=signed.get('required_headers', {})), 403)
            req('DELETE', conditional_path, status=204)
            # Absolute expiry works without a temporary session token.
            soon = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=3)).strftime('%Y-%m-%dT%H:%M:%SZ')
            dated = req('POST', path, dict(policy=read, expires_at=soon), 201)
            s3(dated)
            time.sleep(3.1)
            s3(dated, status=403)
            req('DELETE', path + '/' + dated['id'], status=204)

            admin_key = req('POST', '/access-keys', {'policy': full}, 201)
            same_name = req('POST', '/users/qa/access-keys', {'policy': full}, 201)
            assert admin_key['owner'] == 'qa' and same_name['owner'] == 'user:qa'
            assert all(not item['owner'].startswith('user:') for item in req('GET', '/access-keys')['items'])
            temp = req('POST', path, {'policy': read, 'ttl_seconds': 60}, 201)
            assert temp['kind'] == 'temporary' and temp['session_token'] and temp['expires_at']
            s3(temp)
            s3(temp, status=403, with_token=False)
            updated = req('PATCH', key_path, {'enabled': False})
            assert not updated['enabled'] and 'secret_key' not in updated
            s3(key, status=403)
            req('PATCH', key_path, {'enabled': True})
            user = req('GET', '/users/alice')
            req('PATCH', '/users/alice', dict(user, enabled=False))
            s3(key, status=403)
            req('POST', path, {'policy': full}, 409)
            req('PATCH', '/users/alice', dict(user, enabled=True))
            s3(key)
            zig.terminate(); zig.wait(timeout=10)
            zig = start(args.zig_bin, extra=('--config', str(config)))
            ready(api_base, zig)
            assert len(req('GET', path)['items']) == 4
            restored = next(item for item in req('GET', path)['items'] if item['id'] == inherited['id'])
            assert restored['name'] == 'edited backup' and restored['description'] == 'edited description' and restored['inherit_policy'] and restored['expires_at'] == expiry
            assert restored['policy_document'] == json.dumps(scoped)
            s3(inherited, 'GET', '/alice-key-test/public.txt')
            s3(inherited, 'GET', '/alice-key-test/private.txt', 403)
            s3(key)
            s3(key, 'DELETE', '/alice-key-test/public.txt', 204)
            s3(key, 'DELETE', '/alice-key-test/private.txt', 204)
            s3(key, 'DELETE', '/alice-key-test', 204)
            for item in req('GET', path)['items']:
                req('DELETE', path + '/' + item['id'], status=204)
            s3(key, status=403)
            req('DELETE', '/users/alice', status=204)
            req('POST', '/users', {'name': 'alice', 'password': 'replacement-password', 'enabled': True, 'policies': []}, 201)
            assert not req('GET', path)['items']
            s3(key, status=403)
            print('PASS: scoped CRUD, owner isolation, secret redaction, TTL/token validation, real SigV4 permissions, user/key disable, restart persistence, delete/recreate safety, custom AK/SK and metadata, dated expiry, dynamic user/group IAM inheritance with resource matching and Deny; IAM conditions, variables, forwarded-header/query spoof resistance and presigned consumption')
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill(); process.wait()
            log.close()


if __name__ == '__main__':
    main()
