#!/usr/bin/env python3
"""Real-process global audit coverage, identity, filtering and persistence checks."""
import concurrent.futures
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
    with tempfile.TemporaryDirectory(prefix='zigfs-log-') as temporary:
        root = Path(temporary)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        config_path = root / 'config.yaml'
        config_path.write_text(f'''server:
  api_address: 127.0.0.1:{port}
observability:
  metrics_enabled: false
storage:
  data_root: {root}/data
admin:
  username: logger-admin
  password: isolated-logger-password
  session_secret: isolated-log-test-secret-000000000000000000
''')
        process = None
        console = (root / 'console.log').open('w')
        token = ''

        def request(path, value=None, method=None, authenticated=True, extra_headers=None):
            headers = {'Content-Type': 'application/json'}
            headers.update(extra_headers or {})
            if authenticated:
                headers['Authorization'] = 'Bearer ' + token
            req = urllib.request.Request(endpoint + '/_admin/v1/' + path, data=None if value is None else json.dumps(value).encode(), headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=10) as response:
                body = response.read()
                return json.loads(body) if body else None

        def start():
            nonlocal process, token
            process = subprocess.Popen([str(Path('zigfs/zig-out/bin/zigfs').resolve()), '--config', str(config_path)], stdout=console, stderr=console)
            for _ in range(200):
                if process.poll() is not None:
                    raise AssertionError((root / 'console.log').read_text())
                try:
                    urllib.request.urlopen(endpoint + '/health/ready', timeout=1).close()
                    break
                except OSError:
                    time.sleep(.05)
            else:
                raise AssertionError('readiness timeout')
            token = request('auth/login', {'username': 'logger-admin', 'password': 'isolated-logger-password'}, authenticated=False)['token']

        def stop():
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=15)

        def save(**changes):
            current = request('settings/logs')
            current.update(changes)
            return request('settings/logs', current, 'PUT')

        def rejected(call, codes):
            try:
                call()
            except HTTPError as error:
                assert error.code in codes, (error.code, error.read())
                return
            raise AssertionError('request unexpectedly succeeded')

        try:
            audit_path = root / 'data/.zigfs/system/audit-events.json'
            audit_path.parent.mkdir(parents=True, exist_ok=True)
            audit_path.write_text(json.dumps([{'timestamp_unix_seconds': int(time.time()), 'request_id': 'legacy-seed', 'actor': 'legacy-user', 'action': 'get_object', 'target': '/historical/key.txt', 'outcome': 'success:200'}]))
            start()
            rejected(lambda: request('auth/login', {'username': 'logger-admin', 'password': 'wrong-password'}, authenticated=False), [401])
            request('buckets', {'name': 'audit-check', 'owner': 'audit-s3-owner'})
            request('users', {'name': 'alice', 'password': 'alice-password-123', 'policies': ['consoleAdmin']})
            options = request('audit-events/options')
            assert len(options['categories']) == 7
            assert {'PutObject','CreateUser','RotateKey','PutBucketPolicy'} <= {o['name'] for o in options['operations']}
            root_token = token
            token = request('auth/login', {'username': 'alice', 'password': 'alice-password-123'}, authenticated=False)['token']
            request('settings/logs', {'level': 'off'}, 'PUT', extra_headers={'User-Agent': 'audit-schema-client', 'X-Forwarded-For': '203.0.113.99'})
            request('auth/logout', method='POST')
            token = root_token
            rejected(lambda: request('settings/logs', {'level': 'invalid'}, 'PUT'), [400])
            rejected(lambda: request('audit-events', authenticated=False), [401])
            request('users', {'name': 'audit-reader', 'password': 'reader-password-123', 'policies': ['readonly']})
            token = request('auth/login', {'username': 'audit-reader', 'password': 'reader-password-123'}, authenticated=False)['token']
            rejected(lambda: request('audit-events'), [403])
            token = root_token
            rejected(lambda: request('settings/kms/keys/action', {'id': 'test-audit-key', 'action': 'rotate'}), [409, 503])
            rejected(lambda: request('audit-events?limit=201'), [400])
            credentials = request('access-keys', {'owner': 'audit-s3-owner'})
            import datetime, hashlib, hmac
            def s3(method, path, payload=b''):
                stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
                date = stamp[:8]
                host = f'127.0.0.1:{port}'
                digest = hashlib.sha256(payload).hexdigest()
                signed = 'host;x-amz-content-sha256;x-amz-date'
                canonical = f'{method}\n{path}\n\nhost:{host}\nx-amz-content-sha256:{digest}\nx-amz-date:{stamp}\n\n{signed}\n{digest}'
                scope = f'{date}/us-east-1/s3/aws4_request'
                to_sign = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
                signing = ('AWS4' + credentials['secret_key']).encode()
                for value in [date, 'us-east-1', 's3', 'aws4_request']:
                    signing = hmac.new(signing, value.encode(), hashlib.sha256).digest()
                signature = hmac.new(signing, to_sign.encode(), hashlib.sha256).hexdigest()
                headers = {'Host': host, 'x-amz-date': stamp, 'x-amz-content-sha256': digest, 'Authorization': f"AWS4-HMAC-SHA256 Credential={credentials['access_key']}/{scope}, SignedHeaders={signed}, Signature={signature}"}
                try:
                    with urllib.request.urlopen(urllib.request.Request(endpoint + path, data=payload if method=='PUT' else None, method=method, headers=headers)) as response:
                        return response.read()
                except HTTPError as error:
                    raise AssertionError(error.read()) from error
            s3('PUT', '/audit-check/a.txt', b'audit object')
            assert s3('GET', '/audit-check/a.txt') == b'audit object'
            s3('DELETE', '/audit-check/a.txt')
            rejected(lambda: urllib.request.urlopen(endpoint + '/audit-check/private.txt?versionId=safe-version&X-Amz-Security-Token=do-not-record-token'), [400])
            events = request('audit-events?limit=200')['items']
            assert any(e['actor']=='alice' and e['action']=='PUT /_admin/v1/settings/logs' and e['outcome']=='success:200' for e in events)
            assert any(e['actor']=='alice' and e['action']=='POST /_admin/v1/auth/logout' for e in events)
            assert any(e['action']=='POST /_admin/v1/auth/login' and e['outcome']=='failure:401' for e in events)
            for action in ['put_object', 'get_object', 'delete_object']:
                assert any(e['action']==action and e['actor']=='audit-s3-owner' and e['target']=='/audit-check/a.txt' for e in events), action
            assert any(e['actor']=='audit-reader' and e['action']=='GET /_admin/v1/audit-events' and e['outcome']=='failure:403' for e in events)
            assert any(e['action']=='kms:rotate' and e['target']=='test-audit-key' and e['outcome'].startswith('failure:') for e in events)
            assert len({e['request_id'] for e in events}) == len(events)
            for event in events:
                assert event['schema_version']=='1.0' and event['event_id']
                assert event['event_time'].endswith('Z')
                assert event['request']['request_id']==event['request_id']
                assert event['operation']['name']==event['event_action']
                assert event['response']['status'] in ['success','failure','denied','error','unknown']
                assert event['response']['duration_ms'] >= 0
            old = next(e for e in events if e['request_id']=='legacy-seed')
            old_id = old['event_id']
            assert old['metadata']['legacy'] and old['request']['source_ip'] is None and old['identity']['auth_type']=='unknown'
            config_event = next(e for e in events if e['actor']=='alice' and e['event_action']=='UpdateLogConfiguration')
            assert config_event['request']['source_ip']=='127.0.0.1'
            assert config_event['request']['user_agent']=='audit-schema-client'
            assert config_event['identity']['principal_id']
            assert config_event['identity']['auth_type']=='internal'
            assert config_event['event_category']=='system_management' and config_event['event_type']=='admin_action'
            key_event = next(e for e in events if e['action']=='kms:rotate')
            assert key_event['event_action']=='RotateKey' and key_event['resource']['name']=='test-audit-key'
            assert key_event['response']['status']==('error' if key_event['response']['http_status']>=500 else 'failure')
            created = next(e for e in events if e['event_action']=='CreateUser' and e['resource']['name']=='alice')
            assert created['resource']['type']=='user'
            safe = next(e for e in events if e['target']=='/audit-check/private.txt')
            assert safe['request']['query']['versionId']=='safe-version'
            assert safe['resource']['version_id']=='safe-version'
            assert 'X-Amz-Security-Token' not in safe['request']['query']
            filtered = request('audit-events?category=object_storage&action=PutObject&actor=audit-s3-owner&bucket=audit-check&service=s3&event_type=api_request&source_ip=127.0.0.1')['items']
            assert len(filtered)==1 and filtered[0]['resource']['object_key']=='a.txt'
            assert filtered[0]['identity']['access_key_id']==credentials['access_key']
            assert filtered[0]['identity']['auth_type']=='s3_access_key'
            only = request('audit-events?request_id='+filtered[0]['request_id'])['items']
            assert len(only)==1 and only[0]['event_id']==filtered[0]['event_id']
            denied = request('audit-events?category=security&outcome=denied')['items']
            assert denied and all(e['response']['status']=='denied' and e['event_type']=='security_event' for e in denied)
            serialized = json.dumps(events)
            for secret in ['reader-password-123', 'alice-password-123', 'isolated-logger-password', credentials['secret_key'], token, 'do-not-record-token']:
                assert secret not in serialized
            failures = request('audit-events?outcome=failure&limit=200')['items']
            assert failures and all(e['response']['status']=='failure' for e in failures)
            assert request('audit-events?action=put_object')['items'][0]['actor']=='audit-s3-owner'
            first = request('audit-events?action=put_object&limit=1')
            assert len(first['items'])==1 and first.get('next_cursor') is None
            page = request('audit-events?outcome=failure&limit=1')
            assert page['next_cursor']
            following = request('audit-events?outcome=failure&limit=1&cursor='+page['next_cursor'])
            assert following['items'][0]['request_id'] != page['items'][0]['request_id']
            bucket = request('buckets/audit-check/events?limit=200')['items']
            assert any(e['action']=='put_object' for e in bucket)
            stop(); start()
            assert any(e['action']=='put_object' and e['actor']=='audit-s3-owner' for e in request('audit-events?limit=200')['items'])
            assert next(e for e in request('audit-events?request_id=legacy-seed')['items'])['event_id']==old_id
            assert (root / 'data/.zigfs/system/audit-events.json').exists()
            print('PASS V1 schema, operation catalog, linked filters, identities/resources, source IP spoof protection, query allowlist, status categories, stable event IDs, legacy migration and restart persistence')
        finally:
            stop()
            console.close()


if __name__ == '__main__':
    run()
