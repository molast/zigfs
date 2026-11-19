#!/usr/bin/env python3
"""Real ZigFS + Admin gateway conformance, with strict TLS and isolated data.

No hosts, DNS or OS trust changes. Uses only Python's standard library.
Run after building both binaries; see --help for executable paths.
"""
import argparse
import datetime
import hashlib
import hmac
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time
import urllib.parse
import uuid
import xml.etree.ElementTree as ET


class LocalHTTPSConnection(http.client.HTTPSConnection):
    """Connect to loopback while retaining the requested Host and TLS SNI."""

    def connect(self):
        sock = socket.create_connection(('127.0.0.1', self.port), self.timeout)
        self.sock = self._context.wrap_socket(sock, server_hostname=self.host)


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def request(origin, method, path, body=None, headers=None, context=None):
    parsed = urllib.parse.urlsplit(origin)
    if parsed.scheme == 'https':
        connection = LocalHTTPSConnection(parsed.hostname, parsed.port or 443,
                                          context=context, timeout=30)
    else:
        connection = http.client.HTTPConnection(parsed.hostname, parsed.port, timeout=30)
    try:
        connection.request(method, path, body=body, headers=headers or {})
        response = connection.getresponse()
        return response.status, response.headers, response.read()
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--zigfs', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    admin_options = parser.add_mutually_exclusive_group(required=True)
    admin_options.add_argument('--admin', type=Path)
    admin_options.add_argument('--admin-image', help='Existing Linux Admin runtime image; requires Docker host.docker.internal')
    args = parser.parse_args()
    zig_binary = args.zigfs.resolve()
    admin_binary = args.admin.resolve() if args.admin else None
    container_name = 'zigfs-gateway-check-' + uuid.uuid4().hex[:12]
    access = 'GatewayConformanceKey'
    secret = 'gateway-conformance-secret-key-0123456789'
    ports = [free_port() for _ in range(3)]
    assert len(set(ports)) == 3, 'retry: OS selected duplicate ephemeral ports'
    zig_origin, admin_origin = [f'http://127.0.0.1:{port}' for port in ports[:2]]
    https_admin = f'https://admin.zigfs.home.arpa:{ports[2]}'
    https_s3 = f'https://s3.zigfs.home.arpa:{ports[2]}'
    import_port = free_port()
    base_env = {key: value for key, value in os.environ.items() if not key.startswith('ZIGFS_')}

    with tempfile.TemporaryDirectory(prefix='zigfs-gateway-conformance-') as directory:
        root = Path(directory)
        (root / 'empty.env').touch()
        processes = []
        logs = []

        def start(binary, env):
            log = (root / f'process-{len(logs)}.log').open('w')
            logs.append(log)
            command = [str(binary)]
            if binary is None:
                command = ['docker', 'run', '--rm', '--pull', 'never', '--name', container_name,
                           '--publish', f'127.0.0.1:{ports[1]}:{ports[1]}',
                           '--publish', f'127.0.0.1:{ports[2]}:{ports[2]}',
                           '--publish', f'127.0.0.1:{import_port}:{import_port}',
                           '--volume', f'{root}:{root}']
                for name, value in env.items():
                    command.extend(['--env', f'{name}={value}'])
                command.append(args.admin_image)
            process = subprocess.Popen(command, env={**base_env, **env}, stdout=log, stderr=log)
            processes.append(process)
            return process

        def ready(origin, process):
            for _ in range(200):
                assert process.poll() is None, f'{origin} exited; inspect isolated process log'
                try:
                    if request(origin, 'GET', '/health/ready')[0] == 200:
                        return
                except OSError:
                    pass
                time.sleep(.05)
            raise AssertionError(f'{origin} readiness timeout')

        def stop(process):
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)

        cookie = ''

        def api(method, path='', value=None, expected=200):
            headers = {'Origin': admin_origin, 'Content-Type': 'application/json', 'Cookie': cookie}
            payload = None if value is None else json.dumps(value).encode()
            status, response_headers, body = request(admin_origin, method, '/api/v1/' + path, payload, headers)
            assert status == expected, (method, path, status, body[:500])
            if path.endswith('ca.crt'):
                return body
            return json.loads(body) if body else None

        def s3(method, path, payload=b'', extra=None, expected=200):
            stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
            date = stamp[:8]
            digest = hashlib.sha256(payload).hexdigest()
            host = urllib.parse.urlsplit(https_s3).netloc
            headers = {'host': host, 'x-amz-date': stamp, 'x-amz-content-sha256': digest, **(extra or {})}
            signed_headers = ';'.join(sorted(headers))
            canonical_headers = ''.join(f'{name}:{headers[name]}\n' for name in sorted(headers))
            parsed = urllib.parse.urlsplit(path)
            query = urllib.parse.urlencode(sorted(urllib.parse.parse_qsl(parsed.query, keep_blank_values=True)),
                                           quote_via=urllib.parse.quote)
            # ZigFS canonicalizes decoded path bytes while preserving object slashes.
            # Keep the original encoded path on the wire to exercise proxy transparency.
            canonical_path = urllib.parse.quote_from_bytes(urllib.parse.unquote_to_bytes(parsed.path), safe='/')
            canonical = f'{method}\n{canonical_path}\n{query}\n{canonical_headers}\n{signed_headers}\n{digest}'
            scope = f'{date}/us-east-1/s3/aws4_request'
            message = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
            signing = ('AWS4' + secret).encode()
            for part in [date, 'us-east-1', 's3', 'aws4_request']:
                signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
            signature = hmac.new(signing, message.encode(), hashlib.sha256).hexdigest()
            headers['authorization'] = f'AWS4-HMAC-SHA256 Credential={access}/{scope}, SignedHeaders={signed_headers}, Signature={signature}'
            status, response_headers, body = request(https_s3, method, path,
                                                    payload if method in ('PUT', 'POST') else None,
                                                    headers, context=tls)
            assert status == expected, (method, path, status, body[:500])
            return body, {name.lower(): value for name, value in response_headers.items()}

        zig_env = {
            'ZIGFS_ENV_FILE': str(root / 'empty.env'),
            'ZIGFS_DATA_ROOT': str(root / 'data'),
            'ZIGFS_API_ADDRESS': f'127.0.0.1:{ports[0]}',
            'ZIGFS_METRICS_ENABLED': 'false',
            'ZIGFS_ROOT_USER': 'admin',
            'ZIGFS_ROOT_PASSWORD': 'gateway-test-password',
            'ZIGFS_ADMIN_SESSION_SECRET': 'gateway-test-session-secret-32-bytes-long',
            'ZIGFS_ACCESS_KEY': access,
            'ZIGFS_SECRET_KEY': secret,
            'ZIGFS_S3_PUBLIC_ENDPOINT': zig_origin,
        }
        admin_env = {
            'ZIGFS_ENV_FILE': str(root / 'empty.env'),
            'ZIGFS_ADMIN_LISTEN': f'127.0.0.1:{ports[1]}',
            'ZIGFS_ENDPOINT': zig_origin,
            'ZIGFS_ADMIN_CONFIG': str(root / 'config/listener.json'),
            'ZIGFS_GATEWAY_CONFIG_DIR': str(root / 'config/gateway'),
            'ZIGFS_WEB_ROOT': str(Path('zigfs-admin/web/dist').resolve()),
        }
        if args.admin_image:
            admin_env['ZIGFS_ADMIN_LISTEN'] = f'0.0.0.0:{ports[1]}'
            admin_env['ZIGFS_ENDPOINT'] = f'http://host.docker.internal:{ports[0]}'
            admin_env['ZIGFS_WEB_ROOT'] = '/app/web'
        listen_host = '0.0.0.0' if args.admin_image else '127.0.0.1'
        try:
            ready(zig_origin, start(zig_binary, zig_env))
            admin_process = start(admin_binary, admin_env)
            ready(admin_origin, admin_process)
            status, headers, body = request(admin_origin, 'POST', '/api/v1/auth/login',
                                            json.dumps({'username': 'admin', 'password': 'gateway-test-password'}),
                                            {'Content-Type': 'application/json'})
            assert status == 200, body
            cookie = headers['Set-Cookie'].split(';')[0]
            status = api('GET', 'settings/gateway')
            config = {'listen_address': f'{listen_host}:{ports[2]}',
                      'admin_domain': 'admin.zigfs.home.arpa', 's3_domain': 's3.zigfs.home.arpa',
                      'external_port': ports[2], 'certificate_mode': 'local'}
            prepared = api('PUT', 'settings/gateway', {'revision': status['revision'], 'config': config})
            ca = api('GET', 'settings/gateway/ca.crt')
            tls = ssl.create_default_context(cadata=ca.decode())
            for origin in [https_admin, https_s3]:
                try:
                    request(origin, 'GET', '/_gateway/probe', context=ssl.create_default_context())
                except ssl.SSLCertVerificationError:
                    pass
                else:
                    raise AssertionError('private CA was trusted before being supplied')
                result = request(origin, 'GET', '/_gateway/probe', context=tls)
                assert result[0] == 200 and result[2].decode() == prepared['candidate']['id']
            api('POST', 'settings/gateway/check', {})
            active = api('POST', 'settings/gateway/apply',
                         {'revision': prepared['revision'], 'client_verified': True})
            assert api('GET', 'settings')['s3_public_endpoint'] == https_s3
            s3('PUT', '/gateway-bucket')
            for origin in ['https://first.example', 'https://second.example']:
                code, headers, _ = request(https_s3, 'OPTIONS', '/gateway-bucket/object', headers={
                    'Origin': origin, 'Access-Control-Request-Method': 'PUT',
                    'Access-Control-Request-Headers': 'content-type,x-amz-date'}, context=tls)
                assert code in (200, 204), (code, headers)
                assert headers.get('Access-Control-Allow-Origin') in ('*', origin), headers
            s3('PUT', '/gateway-bucket/empty')
            assert s3('GET', '/gateway-bucket/empty')[0] == b''
            key = '/gateway-bucket/' + urllib.parse.quote('中文 space+%/nested//object', safe='/')
            payload = b'0123456789-gateway'
            s3('PUT', key, payload)
            assert s3('GET', key)[0] == payload
            assert s3('GET', key, extra={'range': 'bytes=2-5'}, expected=206)[0] == b'2345'
            _, head = s3('HEAD', key)
            assert int(head['content-length']) == len(payload)
            s3('GET', key, extra={'if-none-match': head['etag']}, expected=304)
            s3('PUT', '/gateway-bucket/copy', extra={'x-amz-copy-source': key})
            assert s3('GET', '/gateway-bucket/copy')[0] == payload
            error, _ = s3('GET', '/gateway-bucket/missing', expected=404)
            assert b'NoSuchKey' in error
            encoded_slash = '/gateway-bucket/encoded%2Fslash'
            s3('PUT', encoded_slash, b'encoded slash')
            assert s3('GET', encoded_slash)[0] == b'encoded slash'
            custom_cors = (
                '<CORSConfiguration><CORSRule><AllowedOrigin>https://first.example</AllowedOrigin>'
                '<AllowedMethod>PUT</AllowedMethod><AllowedHeader>*</AllowedHeader>'
                '</CORSRule></CORSConfiguration>'
            )
            s3('PUT', '/gateway-bucket?cors=', custom_cors.encode())
            code, headers, _ = request(https_s3, 'OPTIONS', key, headers={
                'Origin': 'https://first.example', 'Access-Control-Request-Method': 'PUT',
                'Access-Control-Request-Headers': 'content-type'}, context=tls)
            assert code in (200, 204) and headers.get('Access-Control-Allow-Origin') == 'https://first.example'
            code, headers, _ = request(https_s3, 'OPTIONS', key, headers={
                'Origin': 'https://second.example', 'Access-Control-Request-Method': 'PUT'}, context=tls)
            direct_code, direct_headers, _ = request(zig_origin, 'OPTIONS', key, headers={
                'Origin': 'https://second.example', 'Access-Control-Request-Method': 'PUT'})
            assert code == direct_code == 403
            # Error responses may expose diagnostics with wildcard ACAO, but must
            # retain the upstream rejection and must not grant preflight methods.
            assert 'Access-Control-Allow-Methods' not in headers
            for name in ['Access-Control-Allow-Origin', 'Access-Control-Allow-Headers']:
                assert headers.get(name) == direct_headers.get(name), (name, headers)

            s3('DELETE', '/gateway-bucket?cors=', expected=204)
            print('PASS: strict CA trust, CORS, unicode paths, empty objects, Range, HEAD, conditions, copy, XML errors')

            initiated, _ = s3('POST', '/gateway-bucket/multipart?uploads=')
            upload_id = ET.fromstring(initiated).findtext('{*}UploadId')
            assert upload_id
            upload_query = urllib.parse.urlencode({'uploadId': upload_id})
            parts = [b'a' * (5 * 1024 * 1024), b'last-part']
            etags = []
            for index, data in enumerate(parts, 1):
                _, part_headers = s3('PUT', f'/gateway-bucket/multipart?partNumber={index}&{upload_query}', data)
                etags.append(part_headers['etag'])
            completion = '<CompleteMultipartUpload>' + ''.join(
                f'<Part><PartNumber>{index}</PartNumber><ETag>{etag}</ETag></Part>'
                for index, etag in enumerate(etags, 1)) + '</CompleteMultipartUpload>'
            s3('POST', f'/gateway-bucket/multipart?{upload_query}', completion.encode())
            assert s3('GET', '/gateway-bucket/multipart')[0] == b''.join(parts)
            s3('PUT', '/gateway-bucket?versioning=', b'<VersioningConfiguration><Status>Enabled</Status></VersioningConfiguration>')
            _, version_headers = s3('PUT', '/gateway-bucket/versioned', b'first')
            version = version_headers['x-amz-version-id']
            s3('PUT', '/gateway-bucket/versioned', b'second')
            version_path = '/gateway-bucket/versioned?' + urllib.parse.urlencode({'versionId': version})
            assert s3('GET', version_path)[0] == b'first'
            s3('DELETE', version_path, expected=204)
            assert s3('GET', '/gateway-bucket/versioned')[0] == b'second'
            print('PASS: multipart upload/completion and version-specific deletion')

            # Import the isolated instance's leaf/chain/key into a different port.
            # Test-only access to private state; production Admin never exposes keys.
            persisted = json.loads((root / 'config/gateway/state.json').read_text())
            material = persisted['active']['material']
            imported_config = {**config, 'certificate_mode': 'import',
                               'listen_address': f'{listen_host}:{import_port}'}
            imported_config['external_port'] = int(imported_config['listen_address'].rsplit(':', 1)[1])
            bad_config = {**imported_config, 'admin_domain': 'wrong.zigfs.home.arpa'}
            api('PUT', 'settings/gateway', {
                'revision': active['revision'], 'config': bad_config,
                'certificate_pem': material['certificate'], 'private_key_pem': material['key']}, expected=400)
            assert api('GET', 'settings/gateway')['active']['id'] == active['active']['id']
            imported = api('PUT', 'settings/gateway', {
                'revision': active['revision'], 'config': imported_config,
                'certificate_pem': material['certificate'] + ca.decode(),
                'private_key_pem': material['key']})
            for domain in ['admin.zigfs.home.arpa', 's3.zigfs.home.arpa']:
                origin = f"https://{domain}:{imported_config['external_port']}"
                code, _, body = request(origin, 'GET', '/_gateway/probe', context=tls)
                assert code == 200 and body.decode() == imported['candidate']['id']
            rolled_back = api('POST', 'settings/gateway/rollback', {'revision': imported['revision']})
            assert rolled_back['candidate'] is None
            assert rolled_back['active']['id'] == active['active']['id']
            active = rolled_back
            assert s3('GET', key)[0] == payload
            print('PASS: imported certificate chain, rejected wrong SAN and rollback preserving active HTTPS')

            stop(admin_process)
            admin_process = start(admin_binary, admin_env)
            ready(admin_origin, admin_process)
            assert api('GET', 'settings/gateway/ca.crt') == ca
            assert s3('GET', key)[0] == payload
            assert api('GET', 'settings/gateway')['active']['id'] == active['active']['id']
            disabled = api('POST', 'settings/gateway/apply', {
                'revision': active['revision'], 'disable': True, 'fallback_endpoint': zig_origin})
            assert disabled['active'] is None
            assert api('GET', 'settings')['s3_public_endpoint'] == zig_origin
            print('PASS: restart preserves CA/active entry; disable restores HTTP endpoint')
        except Exception:
            for log in logs:
                log.flush()
            print('Isolated service errors:')
            for path in root.glob('process-*.log'):
                for line in path.read_text().splitlines():
                    if 'ERROR' in line or 'error:' in line:
                        print(line[:400])
            raise
        finally:
            for process in reversed(processes):
                stop(process)
            for log in logs:
                log.close()


if __name__ == '__main__':
    main()
