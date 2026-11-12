#!/usr/bin/env python3
"""OIDC configuration CRUD through a real BFF and ZigFS; no external IdP needed."""
import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import subprocess
import tempfile
import urllib.request
import sys
sys.dont_write_bytecode = True
from user_access_keys import free_port
import time
import urllib.error


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--admin-bin', required=True, type=Path)
    parser.add_argument('--zig-bin', default=Path('zigfs/zig-out/bin/zigfs'), type=Path)
    args = parser.parse_args()
    processes = []
    with tempfile.TemporaryDirectory(prefix='zigfs-oidc-') as directory:
        root = Path(directory)
        api_port, bff_port = free_port(), free_port()
        config = root / '.env'
        config.write_text(f'''
ZIGFS_API_ADDRESS=127.0.0.1:{api_port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
ZIGFS_ROOT_USER=qa
ZIGFS_ROOT_PASSWORD=oidc-test-only-password
ZIGFS_ADMIN_SESSION_SECRET=oidc-test-only-session-secret-123456789
''')
        log = (root / 'services.log').open('w')
        browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def ready(base):
            for _ in range(200):
                try:
                    with urllib.request.urlopen(base + '/health/ready', timeout=1) as res:
                        if res.status == 200:
                            return
                except OSError:
                    pass
                time.sleep(.05)
            raise RuntimeError('readiness timeout')
        def start_zig():
            process = subprocess.Popen([str(args.zig_bin.resolve()), '--env-file', str(config)], stdout=log, stderr=log)
            processes.append(process)
            ready(f'http://127.0.0.1:{api_port}')
            return process
        def req(method, path, body=None, status=200):
            request = urllib.request.Request(f'http://127.0.0.1:{bff_port}/api/v1' + path, method=method,
                data=json.dumps(body).encode() if body is not None else None, headers={'Content-Type': 'application/json'})
            try:
                result = browser.open(request, timeout=10)
            except urllib.error.HTTPError as error:
                result = error
            assert result.status == status, (method, path, result.status, status)
            data = result.read()
            return json.loads(data) if data else None
        def login():
            req('POST', '/auth/login', {'username': 'qa', 'password': 'oidc-test-only-password'})
        try:
            zig = start_zig()
            processes.append(subprocess.Popen([str(args.admin_bin.resolve())], env=dict(os.environ,
                ZIGFS_ADMIN_LISTEN=f'127.0.0.1:{bff_port}', ZIGFS_ENDPOINT=f'http://127.0.0.1:{api_port}'), stdout=log, stderr=log))
            ready(f'http://127.0.0.1:{bff_port}')
            path = '/oidc/providers'
            req('GET', path, status=401)
            login()
            assert req('GET', path)['items'] == []
            provider = dict(provider_id='keycloak', client_id='console', client_secret='test-secret-oidc-unique',
                configuration_url='https://idp.example/.well-known/openid-configuration',
                redirect_uri='https://console.example/callback', role_policy='readonly')
            req('POST', path, dict(provider, role_policy='nonexistent'), 400)
            req('POST', path, dict(provider, scopes='email'), 400)
            created = req('POST', path, provider, 201)
            assert created['client_secret'] == '' and created['has_secret']
            req('POST', path, provider, 409)
            req('DELETE', '/policies/readonly', status=409)
            updated = req('PATCH', path + '/keycloak', dict(provider, client_secret='', display_name='QA provider', enabled=False))
            assert updated['has_secret'] and updated['client_secret'] == '' and not updated['enabled']
            req('PATCH', path + '/keycloak', dict(provider, provider_id='renamed'), 400)
            req('PATCH', path + '/missing', dict(provider, provider_id='missing'), 404)
            stored = root / 'data/.zigfs/system/oidc-providers.enc'
            assert provider['client_secret'].encode() not in stored.read_bytes()
            zig.terminate(); zig.wait(timeout=10)
            zig = start_zig()
            login()
            assert req('GET', path)['items'][0]['display_name'] == 'QA provider'
            req('POST', '/users', dict(name='limited', password='limited-test-password', policies=[], enabled=True), 201)
            req('POST', '/auth/logout', status=204)
            req('POST', '/auth/login', dict(username='limited', password='limited-test-password'))
            req('GET', path, status=403)
            req('POST', '/auth/logout', status=204)
            login()
            before = stored.read_bytes()
            stored.write_bytes(b'corrupted')
            req('GET', path, status=503)
            req('POST', path, provider, 503)
            stored.write_bytes(before)
            req('DELETE', path + '/keycloak', status=204)
            assert req('GET', path)['items'] == []
            req('DELETE', path + '/keycloak', status=404)
            print('PASS: OIDC CRUD, references, redaction, encryption, restart, corruption, 401/403/409')
        finally:
            for process in reversed(processes):
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=10)
            log.close()

if __name__ == '__main__':
    main()
