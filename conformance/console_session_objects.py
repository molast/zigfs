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
from urllib.error import HTTPError


def run(binary=Path('zigfs/zig-out/bin/zigfs')):
    with tempfile.TemporaryDirectory(prefix='zigfs-console-') as temporary:
        root = Path(temporary)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        config_path = root / 'config.yaml'
        config_path.write_text(f'''server:
  api_address: 127.0.0.1:{port}
s3:
  public_endpoint: {endpoint}
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
            process = subprocess.Popen([str(binary.resolve()), '--config', str(config_path)], stdout=console, stderr=console)
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
            request('buckets', {'name': 'console-test', 'owner': 'another-owner'})
            before = request('access-keys')
            root_token = token

            def sign(method, key='hello.txt', **options):
                return request('objects/presign', dict(bucket='console-test', key=key, method=method, expires_seconds=60, **options))

            def consume(signed, method='GET', body=None):
                req = urllib.request.Request(signed['url'], data=body, headers=signed['required_headers'], method=method)
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
            consume(sign('PUT', 'admin.txt'), 'PUT', b'user admin')
            token = request('auth/login', {'username': 'reader', 'password': 'console-user-password'}, authenticated=False)['token']
            read = sign('GET')
            assert consume(read)[0] == b'console without access keys'
            rejected(lambda: sign('PUT'), [403])
            rejected(lambda: sign('DELETE'), [403])
            token = root_token
            request('users/reader', {'enabled': False}, 'PATCH')
            rejected(lambda: consume(read), [403])
            short = request('objects/presign', {'bucket': 'console-test', 'key': 'hello.txt', 'method': 'GET', 'expires_seconds': 1})
            time.sleep(2)
            rejected(lambda: consume(short), [403])
            assert request('access-keys') == before, 'Web operations must not create stored credentials'
            print('PASS: no-AK root/admin upload, multipart, copy, tags, delete; read-only, tamper, expiry and disable checks')
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
