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
                save(level='info')
            directory = root / 'data/logs/nested'
            files = list(directory.glob('zigfs-*.log'))
            assert len(files) > 1
            for file in files:
                assert file.stat().st_mode & 0o777 == 0o600
                for line in file.read_text().splitlines():
                    assert json.loads(line)['level'] == 'INFO'
            assert 'Log configuration updated' in request('settings/logs/query')['content']
            # Explicit bounds override the saved range without modifying configuration.
            before_range = request('settings/logs')['range']
            assert request('settings/logs/query?from=1&to=2')['content'] == ''
            rejected(lambda: request('settings/logs/query?from=200&to=100'), [400])
            assert request('settings/logs')['range'] == before_range
            recent = request(f'settings/logs/query?from={int(time.time())-60}&to={int(time.time())+60}')['content']
            record = json.loads(recent.splitlines()[0])
            assert record['schema_version'] == '1.0' and record['timestamp'].endswith('Z')
            assert record['service']['name'] == 'zigfs' and record['source']['type'] == 'application'
            audit_files = list((root / 'data/audit-logs').glob('audit-*.log'))
            audit_records = [json.loads(line) for file in audit_files for line in file.read_text().splitlines()]
            assert audit_records and all('event_category' in event for event in audit_records)
            assert all('event_category' not in json.loads(line) for line in recent.splitlines())
            assert all('message' not in event for event in audit_records)
            # Reading logs, config, health and system state must not produce system logs.
            before_poll = {f.name: f.read_bytes() for f in directory.glob('zigfs-*.log')}
            for _ in range(8):
                request('settings/logs/query')
                request('settings/logs')
                request('system')
                urllib.request.urlopen(endpoint + '/health/ready', timeout=1).close()
            assert {f.name: f.read_bytes() for f in directory.glob('zigfs-*.log')} == before_poll
            assert 'http request method=' not in request('settings/logs/query')['content']



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
            # Trigger a real backend I/O failure; keep the active segment writable
            # in a renamed directory while breaking the query directory lookup.
            save(output='file', format='json', level='info', directory='diagnostics', maxSize='10', sizeUnit='MiB')
            diagnostic_dir = root / 'data/diagnostics'
            moved = root / 'data/diagnostics-held'
            diagnostic_dir.rename(moved)
            diagnostic_dir.write_text('not a directory')
            rejected(lambda: request('settings/logs/query'), [503])
            diagnostic_dir.unlink()
            moved.rename(diagnostic_dir)
            diagnostics = [json.loads(line) for line in request('settings/logs/query')['content'].splitlines()]
            errors = [record for record in diagnostics if record['level'] == 'ERROR']
            assert errors and errors[-1]['error']['stack_trace']
            assert errors[-1]['error']['trace_kind'] == 'reporting_site'
            assert errors[-1]['source']['file'].endswith('management.zig')
            assert 'respondError' in errors[-1]['error']['stack_trace']
            assert errors[-1]['context']['request_id']
            # Independently configured audit output, level, format, range and retention.
            def save_audit(**changes):
                current = request('settings/audit-logs')
                current.update(changes)
                return request('settings/audit-logs', current, 'PUT')
            audit_initial = request('settings/audit-logs')
            assert audit_initial['output'] == 'file' and audit_initial['directory'] == 'audit-logs'
            partial_audit = request('settings/audit-logs', {'level':'info'}, 'PUT')
            assert partial_audit['output'] == 'file' and partial_audit['directory'] == 'audit-logs'
            rejected(lambda: save_audit(output='console'), [400])
            saved_system = request('settings/logs')
            saved_audit = save_audit(directory='audit/custom', maxSize='0.5', sizeUnit='KiB', format='text', downloads='disabled', range='1h')
            assert request('settings/logs') == saved_system
            assert json.loads((root / 'data/.zigfs/config/audit_log_config.json').read_text()) == saved_audit
            rejected(lambda: request('settings/audit-logs/download'), [403])
            save(output='console', level='off')
            for _ in range(5): request('system')
            audit_content = request('settings/audit-logs/query')['content']
            assert ' [audit] ' in audit_content and 'event_category' in audit_content
            assert 'GetSystemInfo' in audit_content
            assert len(list((root / 'data/audit/custom').glob('audit-*.log'))) > 1
            assert request('audit-events?limit=200')['items']
            assert request('settings/audit-logs') == saved_audit
            # Changing only audit level stops audit writes even if system logging is active.
            save_audit(level='off')
            audit_dir = root / 'data/audit/custom'
            before_audit = {f.name:f.read_bytes() for f in audit_dir.glob('audit-*.log')}
            save(output='file', level='info')
            request('system'); request('audit-events')
            assert {f.name:f.read_bytes() for f in audit_dir.glob('audit-*.log')} == before_audit
            save_audit(level='info', downloads='enabled')
            assert request('settings/audit-logs/download')['content']
            # Audit cleanup only deletes its own segments, even in a shared directory.
            old_audit = audit_dir / ('audit-100-' + 'c'*32 + '.log')
            old_audit.write_text('100 info [audit] {}\n'); os.utime(old_audit,(100,100))
            foreign_system = audit_dir / ('zigfs-100-' + 'd'*32 + '.log')
            foreign_system.write_text('100 info [system] keep\n'); os.utime(foreign_system,(100,100))
            save_audit(retention='1', cleanup='enabled')
            assert not old_audit.exists() and foreign_system.exists()
            persisted_audit = request('settings/audit-logs')
            persisted_system = request('settings/logs')
            stop(); start()
            assert request('settings/audit-logs') == persisted_audit
            assert request('settings/logs') == persisted_system
            assert request('audit-events')['items']
            save(level='off', downloads='enabled')
            query = request('settings/logs/query')['content']
            request('system')
            assert request('settings/logs/query')['content'] == query
            print('PASS independent audit/system settings, fixed audit file output, level/format/rotation/download/retention/restart, poll isolation, real I/O error stack, persistence/restart, live filtering/format/output, rotation, retention, query range, downloads, concurrency, invalid inputs and path confinement')
        finally:
            stop()
            console.close()


if __name__ == '__main__':
    run()
