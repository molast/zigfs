#!/usr/bin/env python3
"""Two-process listener migration, persistence, rejection and restart ordering."""
import argparse
import http.cookiejar
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request
from urllib.error import HTTPError

def run(zig, admin):
    with tempfile.TemporaryDirectory(prefix='zigfs-listeners-') as directory:
        root = Path(directory)
        sockets = []
        for _ in range(5):
            sock = socket.socket()
            sock.bind(('127.0.0.1', 0))
            sockets.append(sock)
        old, new, web_old, web_new, occupied = [sock.getsockname()[1] for sock in sockets]
        for sock in sockets[:4]: sock.close()
        sockets[4].listen()
        config = root / '.env'
        config.write_text(f"""
ZIGFS_API_ADDRESS=127.0.0.1:{old}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
ZIGFS_ROOT_USER=admin
ZIGFS_ROOT_PASSWORD=isolated-password
ZIGFS_ADMIN_SESSION_SECRET=isolated-listener-secret-00000000000000000000
""")
        log = (root / 'services.log').open('w')
        zp = ap = None
        origin = f'http://127.0.0.1:{web_old}'
        opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        def wait(url, process):
            for _ in range(300):
                if process.poll() is not None: raise AssertionError((root / 'services.log').read_text())
                try:
                    urllib.request.urlopen(url, timeout=1).close()
                    return
                except OSError: time.sleep(.05)
            raise AssertionError('startup timed out')
        def start_zig(port):
            nonlocal zp
            zp = subprocess.Popen([str(zig.resolve()), '--env-file', str(config)], stdout=log, stderr=log)
            wait(f'http://127.0.0.1:{port}/health/ready', zp)
        def start_admin(port):
            nonlocal ap, origin
            env = {**os.environ, 'ZIGFS_ENDPOINT': f'http://127.0.0.1:{old}', 'ZIGFS_ADMIN_LISTEN': f'127.0.0.1:{web_old}',
                   'ZIGFS_ADMIN_CONFIG': str(root / 'admin/listener.json'), 'ZIGFS_WEB_ROOT': str(root / 'web')}
            ap = subprocess.Popen([str(admin.resolve())], env=env, stdout=log, stderr=log)
            origin = f'http://127.0.0.1:{port}'
            wait(origin + '/health/live', ap)
        def stop(process):
            if process and process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
        def request(path, value=None, method=None):
            req = urllib.request.Request(origin + '/api/v1/' + path, data=None if value is None else json.dumps(value).encode(),
                                         headers={'Content-Type': 'application/json'}, method=method)
            with opener.open(req, timeout=15) as response:
                body = response.read()
                return json.loads(body) if body else None
        def rejected(value, code):
            try: request('settings/listeners', value, 'PUT')
            except HTTPError as err:
                body = json.loads(err.read())
                assert body['code'] == code, body
            else: raise AssertionError('unexpected save success')
        try:
            start_zig(old)
            start_admin(web_old)
            request('auth/login', {'username': 'admin', 'password': 'isolated-password'})
            value = {'api_address': f'127.0.0.1:{new}', 'admin_listen_address': f'127.0.0.1:{web_new}',
                     'upstream_endpoint': f'http://127.0.0.1:{new}'}
            rejected({**value, 'admin_listen_address': f'127.0.0.1:{occupied}'}, 'AdminListenAddressUnavailable')
            rejected({**value, 'api_address': f'127.0.0.1:{occupied}'}, 'ListenAddressUnavailable')
            rejected({**value, 'api_address': '127.0.0.1:0'}, 'InvalidListenAddress')
            request('settings/listeners', value, 'PUT')
            status = request('settings')
            assert status['api_address'] == f'127.0.0.1:{old}'
            assert status['pending_api_address'] == value['api_address']
            assert status['api_restart_required'] and status['admin_restart_required']
            # BFF first: continues to use old ZigFS while loading new Admin bind.
            stop(ap)
            start_admin(web_new)
            assert request('settings')['api_address'] == f'127.0.0.1:{old}'
            stop(zp)
            start_zig(new)
            status = request('settings')
            assert status['api_address'] == value['api_address'], status
            assert not status['api_restart_required'] and not status['admin_restart_required']
            assert status['upstream_endpoint'] == value['upstream_endpoint']
            # Move back, this time ZigFS first, with Admin still on its old bind.
            back = {'api_address': f'127.0.0.1:{old}', 'admin_listen_address': f'127.0.0.1:{web_old}',
                    'upstream_endpoint': f'http://127.0.0.1:{old}'}
            request('settings/listeners', back, 'PUT')
            stop(zp)
            start_zig(old)
            assert request('settings')['api_address'] == back['api_address']
            stop(ap)
            start_admin(web_old)
            status = request('settings')
            assert not status['api_restart_required'] and not status['admin_restart_required'], status
            print('PASS: occupied/invalid listeners rejected; pending values persist; both restart orders preserve BFF connectivity')
        except HTTPError as error:
            print(error.read().decode())
            print((root / 'services.log').read_text())
            raise
        finally:
            stop(ap)
            stop(zp)
            sockets[4].close()
            log.close()

if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--zig', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    parser.add_argument('--admin', type=Path, required=True)
    args = parser.parse_args()
    run(args.zig, args.admin)
