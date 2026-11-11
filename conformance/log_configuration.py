#!/usr/bin/env python3
"""Real-process log configuration, confinement, rotation and retention checks."""
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

        def request(path, value=None, method=None, authenticated=True):
            headers = {'Content-Type': 'application/json'}
            if authenticated:
                headers['Authorization'] = 'Bearer ' + token
            req = urllib.request.Request(endpoint + '/_admin/v1/' + path, data=None if value is None else json.dumps(value).encode(), headers=headers, method=method)
            with urllib.request.urlopen(req, timeout=10) as response:
                return json.load(response)

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
            start()
            defaults = request('settings/logs')
            assert defaults['directory'] == 'logs' and defaults['maxSize'] == '100'
            rejected(lambda: request('settings/logs', authenticated=False), [401, 403])
            saved = save(output='file', directory='logs/nested', maxSize='0.5', sizeUnit='KiB', retention='forever')
            assert json.loads((root / 'data/.zigfs/config/log_config.json').read_text()) == saved
            for _ in range(12):
                request('system')
            directory = root / 'data/logs/nested'
            files = list(directory.glob('zigfs-*.log'))
            assert len(files) > 1
            for file in files:
                assert file.stat().st_mode & 0o777 == 0o600
                for line in file.read_text().splitlines():
                    assert json.loads(line)['level'] == 'info'
            assert 'http request' in request('settings/logs/query')['content']
            assert request('settings/logs/download')['content']
            save(downloads='disabled')
            rejected(lambda: request('settings/logs/download'), [403])
            assert request('settings/logs/query')['content']
            before = request('settings/logs')
            for path in ['../outside', '/tmp/outside', 'a/../b', '.zigfs/config', 'a//b']:
                rejected(lambda path=path: save(directory=path), [400])
                assert request('settings/logs') == before
            outside = root / 'outside'
            outside.mkdir()
            (root / 'data/linked').symlink_to(outside, target_is_directory=True)
            rejected(lambda: save(directory='linked/logs'), [400, 503])
            assert not list(outside.iterdir())
            for size in ['0', '-1', 'nan', 'inf', '1e99']:
                rejected(lambda size=size: save(maxSize=size), [400])
            save(output='both', format='text', level='error', directory='filtered')
            request('system')
            assert not list((root / 'data/filtered').glob('*.log'))
            save(level='info')
            request('system')
            assert ' info [default] ' in request('settings/logs/query')['content']
            save(output='file')
            persisted = request('settings/logs')
            console_offset = (root / 'console.log').stat().st_size
            stop(); start()
            assert request('settings/logs') == persisted
            startup_console = (root / 'console.log').read_text()[console_offset:]
            for marker in ['initialized (data_root=', 'ZigFS API listening', 'Prometheus metrics listener disabled']:
                assert marker in startup_console, startup_console
                assert marker not in request('settings/logs/query')['content']
            assert 'http request' not in startup_console
            # Only owned, expired segments may be removed; unrelated files survive.
            directory = root / 'data/filtered'
            old = directory / ('zigfs-100-' + 'a' * 32 + '.log')
            def write_old():
                old.write_text('100 info [test] old\n')
                os.utime(old, (100, 100))
            write_old()
            unrelated = directory / 'keep.txt'; unrelated.write_text('keep')
            save(retention='1', cleanup='disabled')
            assert old.exists()
            save(retention='forever', cleanup='enabled')
            assert old.exists()
            save(retention='1')
            request('system')
            assert not old.exists() and unrelated.exists()
            now = int(time.time())
            old_range = directory / (f'zigfs-{now-7200}-' + 'b' * 32 + '.log')
            old_range.write_text(f'{now-7200} info [test] range-marker\n')
            save(range='1h')
            assert 'range-marker' not in request('settings/logs/query')['content']
            save(range='24h')
            assert 'range-marker' in request('settings/logs/query')['content'], (now, old_range.exists(), request('settings/logs/query'))
            with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
                list(pool.map(lambda _: request('system'), range(30)))
            save(level='off', downloads='enabled')
            query = request('settings/logs/query')['content']
            request('system')
            assert request('settings/logs/query')['content'] == query
            print('PASS persistence/restart, live filtering/format/output, rotation, retention, query range, downloads, concurrency, invalid inputs and path confinement')
        finally:
            stop()
            console.close()


if __name__ == '__main__':
    run()
