#!/usr/bin/env python3
"""Web object operations without AK/SK, with live session authorization."""
import argparse
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
import urllib.parse
from urllib.error import HTTPError


def run(binary=Path('zigfs/zig-out/bin/zigfs')):
    with tempfile.TemporaryDirectory(prefix='zigfs-console-') as temporary:
        root = Path(temporary)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        config_path = root / '.env'
        config_path.write_text(f'''
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
ZIGFS_ROOT_USER=logger-admin
ZIGFS_ROOT_PASSWORD=isolated-logger-password
ZIGFS_ADMIN_SESSION_SECRET=isolated-log-test-secret-000000000000000000
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
            process = subprocess.Popen([str(binary.resolve()), '--env-file', str(config_path)], stdout=console, stderr=console)
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

        def rejected(call, codes):
            try:
                call()
            except HTTPError as error:
                assert error.code in codes, (error.code, error.read())
                return
            raise AssertionError('request unexpectedly succeeded')

        try:
            start()
            display_default = request('settings/display')
            assert display_default['timezone'] == 'browser' and display_default['date_format'] == 'locale'
            assert 'UTC' in display_default['supported_timezones'] and 'Asia/Shanghai' in display_default['supported_timezones']
            display_value = {'timezone': 'Asia/Shanghai', 'date_format': 'ymd'}
            saved_display = request('settings/display', display_value, 'PUT')
            assert all(saved_display[k] == v for k, v in display_value.items())
            assert request('auth/session')['display_preferences'] == display_value
            for bad in [{'timezone': 'Invalid/Zone'}, {'timezone': '../UTC'}, {'timezone': ''}, {'date_format': 'invalid'}, {'date_format': ''}]:
                rejected(lambda: request('settings/display', {**display_value, **bad}, 'PUT'), [400])
                assert request('settings/display') == saved_display
            rejected(lambda: request('settings/display', {'timezone': 'UTC'}, 'PUT'), [400])
            rejected(lambda: request('settings/display', {**display_value, 'extra': True}, 'PUT'), [400])
            rejected(lambda: request('settings/display', authenticated=False), [401])
            initial_instance = request('settings/instance')
            assert initial_instance['service_name'] == 'ZigFS'
            assert initial_instance['description'] == ''
            assert len(initial_instance['instance_id']) == 36
            assert abs(time.time() - initial_instance['started_at_unix_seconds'] - initial_instance['uptime_seconds']) < 5
            instance_value = {'service_name': '研发存储', 'description': 'Primary storage\n第二行'}
            saved_instance = request('settings/instance', instance_value, 'PUT')
            assert saved_instance['instance_id'] == initial_instance['instance_id']
            assert saved_instance['started_at_unix_seconds'] == initial_instance['started_at_unix_seconds']
            rejected(lambda: request('settings/instance', {**instance_value, 'service_name': '  '}, 'PUT'), [400])
            rejected(lambda: request('settings/instance', {**instance_value, 'description': 'x' * 4097}, 'PUT'), [400])
            assert request('settings/instance')['service_name'] == instance_value['service_name']
            request('buckets', {'name': 'console-test', 'owner': 'another-owner'})
            before = request('access-keys')
            root_token = token

            def sign(method, key='hello.txt', **options):
                return request('objects/presign', dict(bucket='console-test', key=key, method=method, expires_seconds=60, **options))

            def consume(signed, method='GET', body=None, extra_headers=None):
                req = urllib.request.Request(signed['url'], data=body, headers={**signed['required_headers'], **(extra_headers or {})}, method=method)
                with urllib.request.urlopen(req, timeout=10) as response:
                    return response.read(), dict(response.headers)

            put = sign('PUT')
            assert token not in put['url']
            consume(put, 'PUT', b'console without access keys')
            get = sign('GET')
            assert consume(get)[0] == b'console without access keys'
            download = sign('GET', download=True)
            body, download_headers = consume(download)
            assert body == b'console without access keys'
            assert download_headers.get('Content-Disposition', download_headers.get('content-disposition')) == 'attachment'
            assert not consume(get)[1].get('content-disposition')
            version_download = sign('GET', download=True, version_id='null')
            assert consume(version_download)[0] == body
            range_request = urllib.request.Request(download['url'], headers={'Range': 'bytes=0-6'})
            with urllib.request.urlopen(range_request, timeout=10) as response:
                assert response.status == 206 and response.read() == b'console'
                assert response.headers['Content-Disposition'] == 'attachment'
            tampered = dict(download, url=download['url'].replace('attachment', 'inline'))
            rejected(lambda: consume(tampered), [403])
            rejected(lambda: sign('PUT', download=True), [400])
            rejected(lambda: sign('GET', download=True, tagging=True), [400])
            rejected(lambda: consume(get, 'DELETE'), [403])
            altered = dict(get, url=get['url'].replace('/hello.txt?', '/other.txt?'))
            rejected(lambda: consume(altered), [403])
            copy = sign('PUT', 'copy.txt', copy_source_bucket='console-test', copy_source_key='hello.txt')
            consume(copy, 'PUT', b'')
            assert consume(sign('GET', 'copy.txt'))[0] == b'console without access keys'
            upload = request('multipart-uploads', {'bucket': 'console-test', 'key': 'multipart.txt', 'content_type': 'text/plain'})
            part = sign('PUT', 'multipart.txt', upload_id=upload['upload_id'], part_number=1)
            _, headers = consume(part, 'PUT', b'multipart session upload')
            completion = {'bucket': 'console-test', 'key': 'multipart.txt', 'parts': [{'part_number': 1, 'etag': headers.get('ETag', headers.get('etag'))}]}
            # Force body reads to refill the HTTP buffer that originally held the
            # request path, as a large real-world completion part list does.
            complete_request = urllib.request.Request(
                endpoint + '/_admin/v1/multipart-uploads/' + upload['upload_id'] + '/complete',
                data=b' ' * (64 * 1024) + json.dumps(completion).encode(),
                headers={'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token},
                method='POST',
            )
            with urllib.request.urlopen(complete_request, timeout=10) as response:
                assert response.status == 200
                response.read()
            # Replaying the ordinary small request must still be idempotent.
            request('multipart-uploads/' + upload['upload_id'] + '/complete', completion)
            assert consume(sign('GET', 'multipart.txt'))[0] == b'multipart session upload'
            consume(sign('PUT', tagging=True), 'PUT', b'<Tagging><TagSet><Tag><Key>kind</Key><Value>test</Value></Tag></TagSet></Tagging>')
            assert b'test' in consume(sign('GET', tagging=True))[0]
            assert consume(sign('GET'))[0] == b'console without access keys'
            consume(sign('DELETE', tagging=True), 'DELETE')
            assert consume(sign('GET'))[0] == b'console without access keys'
            consume(sign('DELETE', 'copy.txt'), 'DELETE')
            request('users', {'name': 'console-admin', 'password': 'console-user-password', 'policies': ['consoleAdmin']})
            request('users', {'name': 'reader', 'password': 'console-user-password', 'policies': ['readonly']})
            token = request('auth/login', {'username': 'console-admin', 'password': 'console-user-password'}, authenticated=False)['token']
            try:
                request('users/console-admin', method='DELETE')
            except HTTPError as error:
                assert error.code == 403
                assert json.loads(error.read())['code'] == 'CannotRemoveCurrentUser'
            else:
                raise AssertionError('administrator deleted their own identity')
            assert request('users/console-admin')['name'] == 'console-admin'
            request('users', {'name': 'deletable', 'password': 'console-user-password', 'policies': ['readonly']})
            request('users/deletable', method='DELETE')
            consume(sign('PUT', 'admin.txt'), 'PUT', b'user admin')
            token = request('auth/login', {'username': 'reader', 'password': 'console-user-password'}, authenticated=False)['token']
            assert request('auth/session')['display_preferences'] == display_value
            rejected(lambda: request('settings/display'), [403])
            rejected(lambda: request('settings/display', display_value, 'PUT'), [403])
            rejected(lambda: request('settings/instance'), [403])
            rejected(lambda: request('settings/instance', instance_value, 'PUT'), [403])
            rejected(lambda: request('settings/authentication'), [403])
            rejected(lambda: request('settings/authentication', {'admin_session_ttl_seconds': 3600, 'request_time_skew_seconds': 60}, 'PUT'), [403])
            rejected(lambda: request('settings/region'), [403])
            rejected(lambda: request('settings/region', {'s3_region': 'eu-central-1'}, 'PUT'), [403])
            read = sign('GET')
            assert consume(read)[0] == b'console without access keys'
            rejected(lambda: request('settings/network', {'s3_public_endpoint': endpoint, 's3_virtual_hosted_style': False}, 'PUT'), [403])
            rejected(lambda: sign('PUT'), [403])
            rejected(lambda: sign('DELETE'), [403])
            token = root_token
            request('users/reader', {'enabled': False}, 'PATCH')
            rejected(lambda: consume(read), [403])
            short = request('objects/presign', {'bucket': 'console-test', 'key': 'hello.txt', 'method': 'GET', 'expires_seconds': 1})
            time.sleep(2)
            rejected(lambda: consume(short), [403])
            assert request('access-keys') == before, 'Web operations must not create stored credentials'
            for bad in ['ftp://storage.example.com', 'https://storage.example.com/path', 'https://user:pass@storage.example.com']:
                rejected(lambda: request('settings/network', {'s3_public_endpoint': bad, 's3_virtual_hosted_style': False}, 'PUT'), [400])
            request('settings/network', {'s3_public_endpoint': 'https://storage.example.com', 's3_virtual_hosted_style': True}, 'PUT')
            assert sign('GET')['url'].startswith('https://console-test.storage.example.com/')
            virtual = sign('GET')
            parsed_url = urllib.parse.urlsplit(virtual['url'])
            headers = dict(virtual['required_headers'])
            headers['Host'] = parsed_url.netloc
            direct = urllib.request.Request(endpoint + parsed_url.path + '?' + parsed_url.query, headers=headers)
            with urllib.request.urlopen(direct, timeout=10) as response:
                assert response.read() == b'console without access keys'

            stop()
            start()
            assert request('settings/display') == saved_display
            assert request('auth/session')['display_preferences'] == display_value
            restarted_instance = request('settings/instance')
            assert restarted_instance['instance_id'] == initial_instance['instance_id']
            assert restarted_instance['service_name'] == instance_value['service_name']
            assert restarted_instance['description'] == instance_value['description']
            assert restarted_instance['started_at_unix_seconds'] > initial_instance['started_at_unix_seconds']
            saved = request('settings')
            assert saved['s3_public_endpoint'] == 'https://storage.example.com'
            assert saved['s3_virtual_hosted_style'] is True
            assert sign('GET')['url'].startswith('https://console-test.storage.example.com/')
            request('settings/network', {'s3_public_endpoint': endpoint, 's3_virtual_hosted_style': False}, 'PUT')
            assert consume(sign('GET'))[0] == b'console without access keys'
            request('policies', {'name': 'proxy-conditions', 'document': json.dumps({
                'Version': '2012-10-17', 'Statement': [
                    {'Effect': 'Deny', 'Action': 's3:GetObject', 'Resource': '*', 'Condition': {'NotIpAddress': {'aws:SourceIp': '198.51.100.7/32'}}},
                    {'Effect': 'Deny', 'Action': 's3:GetObject', 'Resource': '*', 'Condition': {'Bool': {'aws:SecureTransport': 'false'}}},
                ]})})
            request('users/console-admin', {'policies': ['consoleAdmin', 'proxy-conditions']}, 'PATCH')
            token = request('auth/login', {'username': 'console-admin', 'password': 'console-user-password'}, authenticated=False)['token']
            proxy_signed = sign('GET')
            forwarded = {'X-Forwarded-For': '198.51.100.7', 'X-Forwarded-Proto': 'https'}
            rejected(lambda: consume(proxy_signed, extra_headers=forwarded), [403])
            token = root_token
            network = {'s3_public_endpoint': endpoint, 's3_virtual_hosted_style': False, 'trusted_proxies': ['127.0.0.1/32']}
            rejected(lambda: request('settings/network', {**network, 'trusted_proxies': ['127.0.0.1/99']}, 'PUT'), [400])
            request('settings/network', network, 'PUT')
            assert consume(proxy_signed, extra_headers=forwarded)[0] == b'console without access keys'
            rejected(lambda: consume(proxy_signed, extra_headers={'X-Forwarded-For': '198.51.100.7, 192.0.2.1', 'X-Forwarded-Proto': 'https, http'}), [403])
            rejected(lambda: consume(proxy_signed, extra_headers={'X-Forwarded-For': 'bad', 'X-Forwarded-Proto': 'https'}), [403])
            stop()
            start()
            assert request('settings')['trusted_proxies'] == ['127.0.0.1/32']
            assert consume(proxy_signed, extra_headers=forwarded)[0] == b'console without access keys'
            events = request('audit-events?limit=200')
            assert any(event['request']['source_ip'] == '198.51.100.7' for event in events['items']), events
            request('settings/network', {**network, 'trusted_proxies': []}, 'PUT')
            rejected(lambda: consume(proxy_signed, extra_headers=forwarded), [403])
            initial_region = request('settings/region')
            assert initial_region == {'s3_region': 'us-east-1', 'pending_s3_region': 'us-east-1', 'restart_required': False}
            pending = request('settings/region', {'s3_region': 'eu-central-1'}, 'PUT')
            assert pending == {'s3_region': 'us-east-1', 'pending_s3_region': 'eu-central-1', 'restart_required': True}
            for bad in ['', 'US-east-1', '-zone', 'zone-', 'a/b', 'zone 1', '区', 'x' * 64]:
                rejected(lambda: request('settings/region', {'s3_region': bad}, 'PUT'), [400])
                assert request('settings/region') == pending
            def credential_scope(signed):
                return urllib.parse.parse_qs(urllib.parse.urlsplit(signed['url']).query)['X-Amz-Credential'][0]
            old_signed = sign('GET')
            assert '/us-east-1/s3/aws4_request' in credential_scope(old_signed)
            assert consume(old_signed)[0] == b'console without access keys'
            assert request('settings')['s3_region'] == 'us-east-1'
            cancelled = request('settings/region', {'s3_region': 'us-east-1'}, 'PUT')
            assert cancelled == initial_region
            request('settings/region', {'s3_region': 'eu-central-1'}, 'PUT')
            stop()
            start()
            assert request('settings/region') == {'s3_region': 'eu-central-1', 'pending_s3_region': 'eu-central-1', 'restart_required': False}
            assert request('settings')['s3_region'] == 'eu-central-1'
            new_signed = sign('GET')
            assert '/eu-central-1/s3/aws4_request' in credential_scope(new_signed)
            assert consume(new_signed)[0] == b'console without access keys'
            rejected(lambda: consume(old_signed), [400, 403])
            defaults = {'admin_session_ttl_seconds': 28800, 'request_time_skew_seconds': 900}
            changed = {'admin_session_ttl_seconds': 3600, 'request_time_skew_seconds': 60}
            assert request('settings/authentication') == {'current': defaults, 'pending': defaults, 'restart_required': False}
            auth_pending = request('settings/authentication', changed, 'PUT')
            assert auth_pending == {'current': defaults, 'pending': changed, 'restart_required': True}
            for field, invalid_values in [('admin_session_ttl_seconds', [0, 59, 86401, -1, 1.5, '3600', None]), ('request_time_skew_seconds', [0, 59, 3601, -1, 1.5, '60', None])]:
                for value in invalid_values:
                    rejected(lambda: request('settings/authentication', {**changed, field: value}, 'PUT'), [400])
                    assert request('settings/authentication') == auth_pending
            rejected(lambda: request('settings/authentication', {'admin_session_ttl_seconds': 3600}, 'PUT'), [400])
            rejected(lambda: request('settings/authentication', {**changed, 'extra': True}, 'PUT'), [400])
            try:
                request('settings/authentication', {'admin_session_ttl_seconds': 0, 'request_time_skew_seconds': 0}, 'PUT')
            except HTTPError as error:
                assert json.loads(error.read())['code'] == 'InvalidSessionLifetime'
            else:
                raise AssertionError('invalid authentication values accepted')
            def login_lifetime(username, password, expected):
                before = time.time()
                result = request('auth/login', {'username': username, 'password': password}, authenticated=False)
                assert before + expected - 2 <= result['expires_at'] <= time.time() + expected + 2, result
                return result
            old_login = login_lifetime('logger-admin', 'isolated-logger-password', 28800)
            login_lifetime('console-admin', 'console-user-password', 28800)
            credentials = request('access-keys', {'owner': 'clock-skew-test', 'policy_document': json.dumps({'Version': '2012-10-17', 'Statement': [{'Effect': 'Allow', 'Action': 's3:GetObject', 'Resource': 'arn:aws:s3:::console-test/*'}]})})
            import datetime, hashlib, hmac
            def signed_download(offset):
                stamp = (datetime.datetime.now(datetime.timezone.utc) + datetime.timedelta(seconds=offset)).strftime('%Y%m%dT%H%M%SZ')
                date = stamp[:8]
                host = f'127.0.0.1:{port}'
                path = '/console-test/hello.txt'
                digest = hashlib.sha256(b'').hexdigest()
                signed = 'host;x-amz-content-sha256;x-amz-date'
                canonical = f'GET\n{path}\n\nhost:{host}\nx-amz-content-sha256:{digest}\nx-amz-date:{stamp}\n\n{signed}\n{digest}'
                scope = f'{date}/eu-central-1/s3/aws4_request'
                to_sign = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
                signing = ('AWS4' + credentials['secret_key']).encode()
                for value in [date, 'eu-central-1', 's3', 'aws4_request']:
                    signing = hmac.new(signing, value.encode(), hashlib.sha256).digest()
                signature = hmac.new(signing, to_sign.encode(), hashlib.sha256).hexdigest()
                headers = {'Host': host, 'x-amz-date': stamp, 'x-amz-content-sha256': digest, 'Authorization': f"AWS4-HMAC-SHA256 Credential={credentials['access_key']}/{scope}, SignedHeaders={signed}, Signature={signature}"}
                with urllib.request.urlopen(urllib.request.Request(endpoint + path, headers=headers), timeout=10) as response:
                    return response.read()
            for offset in [-120, 120]:
                assert signed_download(offset) == b'console without access keys'
            assert not request('settings/authentication', defaults, 'PUT')['restart_required']
            request('settings/authentication', changed, 'PUT')
            stop()
            start()
            assert request('settings/authentication') == {'current': changed, 'pending': changed, 'restart_required': False}
            effective = request('settings')
            assert all(effective[key] == value for key, value in changed.items())
            login_lifetime('logger-admin', 'isolated-logger-password', 3600)
            login_lifetime('console-admin', 'console-user-password', 3600)
            # Previously issued sessions remain valid and retain their embedded expiry.
            saved_token = token
            token = old_login['token']
            assert request('settings/authentication')['current'] == changed
            token = saved_token
            assert signed_download(0) == b'console without access keys'
            for offset in [-120, 120]:
                try:
                    signed_download(offset)
                except HTTPError as error:
                    assert error.code == 403
                    assert b'<Code>RequestTimeTooSkewed</Code>' in error.read()
                else:
                    raise AssertionError('out-of-window signature accepted')
            # All General settings remain readable together and expose specific audit operations.
            for section, value in [('instance', instance_value), ('region', {'s3_region': 'eu-central-1'}), ('authentication', changed), ('display', display_value)]:
                request('settings/' + section)
                request('settings/' + section, value, 'PUT')
            expected_operations = {prefix + kind + 'Settings' for prefix in ['Get', 'Update'] for kind in ['Instance', 'Region', 'Authentication', 'Display']}
            options = request('audit-events/options')
            assert expected_operations <= {operation['name'] for operation in options['operations']}
            events = request('audit-events?limit=200')
            assert expected_operations <= {event['event_action'] for event in events['items']}
            print('PASS: console object operations, self-deletion protection; network validation, authorization, live virtual-host download, trusted proxy IAM/audit, spoof rejection, instance settings/identity/startup, region validation/authorization/pending cancellation/signatures and restart persistence; authentication validation/authorization/session TTL/clock skew; display preferences/validation/session propagation/persistence')
        except Exception as error:
            if isinstance(error, HTTPError):
                print('HTTP error response:', error.read().decode())
            print((root / 'console.log').read_text())
            raise
        finally:
            stop()
            console.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    run(parser.parse_args().binary)
