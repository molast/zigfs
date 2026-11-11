#!/usr/bin/env python3
"""Isolated real-process reclamation benchmark, not upload throughput.

Seeds valid committed multipart tombstones and intent/commit journal pairs.
Never accepts an existing data directory. All fixtures live in a temporary root.
"""
import argparse
import hashlib
import json
import re
import select
import signal
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import time
import urllib.request
import uuid

RECORD_DIRS = {
    1: '.zigfs/system/configuration/records',
    2: 'metadata/buckets',
    3: 'metadata/objects',
    4: 'metadata/multipart',
    5: '.zigfs/system/credentials',
    6: 'metadata/directories',
}


def checksummed(value):
    return value + hashlib.sha256(value).digest()


def seed(root, count, all_types=False):
    journal = root / '.zigfs/journal'
    multipart = root / 'metadata/multipart'
    configuration = root / '.zigfs/system/configuration'
    for directory in (journal, multipart, configuration, *(root / path for path in RECORD_DIRS.values())):
        directory.mkdir(parents=True, exist_ok=True)
    instance = uuid.uuid4().bytes
    (root / '.zigfs/format.meta').write_bytes(checksummed(
        struct.pack('<8sHHHH16sq', b'ZIGFSFMT', 1, 0, 72, 0, instance, int(time.time()))))
    (configuration / 'generation.meta').write_bytes(checksummed(
        struct.pack('<8sHHIQ', b'ZFSGEN01', 1, 0, 0, count)))
    for generation in range(1, count + 1):
        kind = (generation - 1) % 6 + 1 if all_types else 4
        key = uuid.uuid4().hex.encode()
        key_hash = hashlib.sha256(key).digest()
        payload = struct.pack('<4sHH', b'ZFMP', len(key), 1) + key
        record = struct.pack('<4sHHBBHQQI', b'ZFRD', 1, 0, kind, 0, 32, generation, len(payload), 0)
        (root / RECORD_DIRS[kind] / (key_hash.hex() + '.record')).write_bytes(checksummed(record + payload))
        transaction = uuid.uuid4()
        for state in (1, 2):
            entry = struct.pack('<4sHHBBHQQ16s32sI', b'ZFJN', 1, 0, state, kind, 0,
                                generation, 0, transaction.bytes, key_hash, 0)
            name = f'{generation:020}-{transaction.hex}-{state}.journal'
            (journal / name).write_bytes(checksummed(entry))


def usage(root):
    result = {'files': 0, 'bytes': 0, 'allocated_bytes': 0}
    for directory in (root / '.zigfs/journal', *(root / path for path in RECORD_DIRS.values())):
        for path in directory.iterdir():
            stat = path.stat()
            if path.is_file():
                result['files'] += 1
                result['bytes'] += stat.st_size
                result['allocated_bytes'] += stat.st_blocks * 512
    return result


def crash_at_atomic_write(probe, root):
    targets = ['.zigfs/format.meta', '.zigfs/system/configuration/generation.meta',
               '.zigfs/journal/checkpoint.meta', '.zigfs/journal/probe.journal',
               '.zigfs/config/log_config.json']
    for target in targets:
        destination = root / target
        destination.parent.mkdir(parents=True, exist_ok=True)
        original = destination.read_bytes() if destination.exists() else None
        child = subprocess.Popen([str(probe), str(root), target], stderr=subprocess.PIPE)
        try:
            ready, _, _ = select.select([child.stderr], [], [], 10)
            assert ready and child.stderr.readline() == b'READY\n', 'crash probe did not become ready'
            child.kill()
            assert child.wait(timeout=10) == -signal.SIGKILL
            assert (destination.read_bytes() if destination.exists() else None) == original
        finally:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
            child.stderr.close()
    leftovers = [p for p in root.rglob('*') if p.is_file() and re.fullmatch(r'[0-9a-f]{16}', p.name)]
    assert len(leftovers) == len(targets), leftovers
    return leftovers


def run(binary, count, timeout, all_types=False, crash_probe=None):
    with tempfile.TemporaryDirectory(prefix='zigfs-metadata-') as temporary:
        base = Path(temporary)
        root = base / 'data'
        seed_started = time.monotonic()
        seed(root, count, all_types)
        before = usage(root)
        print(json.dumps({'phase': 'seeded', 'tasks': count, 'seconds': round(time.monotonic() - seed_started, 3), **before}), flush=True)
        leftovers = crash_at_atomic_write(crash_probe, root) if crash_probe else []
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        config = base / 'config.yaml'
        config.write_text(f'''server:
  api_address: 127.0.0.1:{port}
observability:
  metrics_enabled: false
storage:
  data_root: {root}
  metadata_maintenance_interval_seconds: 1
  metadata_maintenance_batch_size: 10000
admin:
  username: maintenance-test
  password: isolated-maintenance-password
  session_secret: isolated-maintenance-secret-0000000000000000
''')
        console_path = base / 'console.log'
        process = None

        def stop():
            nonlocal process
            if process and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=15)
            process = None

        def start(console):
            nonlocal process
            began = time.monotonic()
            process = subprocess.Popen([str(binary), '--config', str(config)], stdout=console, stderr=console)
            while time.monotonic() - began < timeout:
                if process.poll() is not None:
                    raise AssertionError(console_path.read_text())
                try:
                    with urllib.request.urlopen(f'http://127.0.0.1:{port}/health/ready', timeout=1):
                        return time.monotonic() - began
                except OSError:
                    time.sleep(.1)
            raise AssertionError('readiness timeout\n' + console_path.read_text())

        with console_path.open('w') as console:
            try:
                began = time.monotonic()
                readiness = start(console)
                assert all(not path.exists() for path in leftovers), 'atomic orphan survived startup'
                print(json.dumps({'phase': 'ready', 'tasks': count, 'seconds': round(readiness, 3)}), flush=True)
                while time.monotonic() - began < timeout:
                    if process.poll() is not None:
                        raise AssertionError(console_path.read_text())
                    if not any((root / '.zigfs/journal').glob('*.journal')) and not any(
                            any((root / directory).glob('*.record')) for directory in RECORD_DIRS.values()):
                        break
                    time.sleep(.2)
                else:
                    raise AssertionError('reclamation timeout\n' + console_path.read_text())
                elapsed = time.monotonic() - began
                stop()
                after = usage(root)
                assert after['files'] == 1, after  # The single checkpoint remains.
                assert struct.unpack_from('<H', (root / '.zigfs/format.meta').read_bytes(), 14)[0] == 1
                restart = start(console)
                stop()
                assert usage(root) == after
                result = {'tasks': count, 'all_types': all_types, 'killed_atomic_writers': len(leftovers), 'before': before, 'after': after,
                          'first_ready_seconds': round(readiness, 3),
                          'drained_seconds': round(elapsed, 3),
                          'restart_ready_seconds': round(restart, 3)}
                print(json.dumps(result), flush=True)
                return result
            finally:
                stop()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', type=Path, default=Path('zigfs/zig-out/bin/zigfs'))
    parser.add_argument('--tasks', type=int, nargs='+', default=[1000])
    parser.add_argument('--timeout', type=int, default=600)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--all-types', action='store_true', help='spread tombstones over all six metadata types')
    parser.add_argument('--crash-probe', type=Path, help='compiled metadata_atomic_crash.zig helper')
    args = parser.parse_args()
    if any(count < 1 for count in args.tasks):
        parser.error('--tasks must be positive')
    results = [run(args.binary.resolve(), count, args.timeout, args.all_types,
                   args.crash_probe.resolve() if args.crash_probe else None) for count in args.tasks]
    if args.output:
        args.output.write_text(json.dumps(results, indent=2) + '\n')
