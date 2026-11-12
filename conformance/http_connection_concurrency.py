#!/usr/bin/env python3
"""Idle/keep-alive sockets must not block accepting new HTTP connections."""
import argparse
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import urllib.request


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--binary', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='zigfs-connections-') as directory:
        root = Path(directory)
        with socket.socket() as probe:
            probe.bind(('127.0.0.1', 0))
            port = probe.getsockname()[1]
        config = root / '.env'
        config.write_text(f'''
ZIGFS_API_ADDRESS=127.0.0.1:{port}
ZIGFS_METRICS_ENABLED=false
ZIGFS_DATA_ROOT={root}/data
''')
        with (root / 'server.log').open('w') as log:
            process = subprocess.Popen([str(args.binary.resolve()), '--env-file', str(config)], stdout=log, stderr=log)
            idle = []
            try:
                endpoint = f'http://127.0.0.1:{port}/health/ready'
                for _ in range(200):
                    assert process.poll() is None, (root / 'server.log').read_text()
                    try:
                        urllib.request.urlopen(endpoint, timeout=.5).close()
                        break
                    except OSError:
                        time.sleep(.05)
                else:
                    raise AssertionError('readiness timed out')
                # Exceed Threaded's CPU-based async budget. These connections
                # remain open and send no complete request until after the probe.
                for _ in range((os.cpu_count() or 8) + 8):
                    connection = socket.create_connection(('127.0.0.1', port), timeout=3)
                    idle.append(connection)
                    connection.sendall(b'GET /health/ready HTTP/1.1\r\nHost: localhost\r\n')
                with urllib.request.urlopen(endpoint, timeout=3) as response:
                    assert response.status == 200
                for connection in idle:
                    connection.sendall(b'Connection: close\r\n\r\n')
                    assert b' 200 ' in connection.recv(1024)
                print(f'PASS: {len(idle)} idle connections do not block new requests; all pending requests finish')
            finally:
                for connection in idle:
                    connection.close()
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()


if __name__ == '__main__':
    main()
