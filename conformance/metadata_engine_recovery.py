#!/usr/bin/env python3
"""Verify real-process readiness for missing/corrupt metadata and rejected old roots."""
import argparse
import hashlib
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import tempfile
import time
import urllib.error
import urllib.request


def wait_ready(process, endpoint, expected, log_path):
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(log_path.read_text())
        try:
            with urllib.request.urlopen(endpoint + '/health/ready', timeout=1) as response:
                status = response.status
        except urllib.error.HTTPError as error:
            status = error.code
            error.close()
        except OSError:
            time.sleep(0.05)
            continue
        if status == expected:
            return
        time.sleep(0.05)
    raise AssertionError(f'expected readiness {expected}\n{log_path.read_text()}')


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)


def check(binary, case):
    with tempfile.TemporaryDirectory(prefix='zigfs-engine-recovery-') as temporary:
        base = Path(temporary)
        root = base / 'data'
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        endpoint = f'http://127.0.0.1:{port}'
        config = base / '.env'
        config.write_text(f'''ZIGFS_DATA_ROOT={root}
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_ROOT_USER=recovery-test
ZIGFS_ROOT_PASSWORD=isolated-recovery-password
ZIGFS_ADMIN_SESSION_SECRET=isolated-recovery-session-secret-000000000000
''')
        log_path = base / 'server.log'
        with log_path.open('w') as log:
            process = subprocess.Popen([str(binary), '--env-file', str(config)], stdout=log, stderr=log)
            try:
                wait_ready(process, endpoint, 200, log_path)
            finally:
                stop(process)
            database = root / '.zigfs.sys'
            assert (database / 'wal').is_file()
            assert not (root / 'metadata').exists()
            assert not (root / '.zigfs/journal').exists()
            if case == 'missing':
                shutil.rmtree(database)
            elif case == 'corrupt':
                (database / 'wal').write_bytes(b'corrupted-engine-wal')
            else:
                path = root / '.zigfs/format.meta'
                header = bytearray(path.read_bytes())
                struct.pack_into('<H', header, 8, 2 if case == 'old-system-layout' else 1)
                header[40:] = hashlib.sha256(header[:40]).digest()
                path.write_bytes(header)
            before = {str(path.relative_to(root)): path.read_bytes()
                      for path in database.glob('*') if path.is_file()}
            process = subprocess.Popen([str(binary), '--env-file', str(config)], stdout=log, stderr=log)
            try:
                if case in ('old-format', 'old-system-layout'):
                    assert process.wait(timeout=30) != 0
                    assert 'UnsupportedMajorVersion' in log_path.read_text()
                else:
                    wait_ready(process, endpoint, 503, log_path)
                    with urllib.request.urlopen(endpoint + '/health/live', timeout=3) as response:
                        assert response.status == 200
            finally:
                stop(process)
            after = {str(path.relative_to(root)): path.read_bytes()
                     for path in database.glob('*') if path.is_file()}
            assert after == before, f'{case}: source was modified or recreated'
            print(f'PASS {case}: correct health/rejection, no metadata reset')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    args = parser.parse_args()
    for case in ('missing', 'corrupt', 'old-format', 'old-system-layout'):
        check(args.binary.resolve(), case)


if __name__ == '__main__':
    main()
