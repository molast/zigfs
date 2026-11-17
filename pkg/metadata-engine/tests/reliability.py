#!/usr/bin/env python3
"""Stopped backup restore and isolated macOS volume faults; never fill host storage."""
import argparse
import errno
import hashlib
import json
import platform
import shutil
import subprocess
import tempfile
import time
from pathlib import Path


def run(*command, timeout=45):
    result = subprocess.run([str(arg) for arg in command], capture_output=True,
                            text=True, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f'{command[0]} failed ({result.returncode}): '
                           f'{result.stdout}{result.stderr}')
    return result.stdout + result.stderr


def digest(directory):
    return {str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in directory.rglob('*') if path.is_file()}


def probe(binary, mode, directory):
    return json.loads(run(binary, mode, directory))


def backup_test(probe_binary, tool, temporary):
    source = temporary / 'source'
    source.mkdir()
    probe(probe_binary, 'seed', source)
    saved = digest(source)
    backup = temporary / 'backup'
    shutil.copytree(source, backup)
    assert saved == digest(backup)
    restored = temporary / 'restored'
    shutil.copytree(backup, restored)
    before = digest(restored)
    inspected = json.loads(run(tool, 'inspect', restored))
    assert digest(restored) == before
    assert inspected['generation'] == 13 and inspected['records'] == 18
    verified = probe(probe_binary, 'verify', restored)
    assert verified['verified'] and verified['write_after_recovery']
    assert digest(source) == saved and digest(backup) == saved
    rejected = []
    for kind in ('corrupt-snapshot', 'missing-wal'):
        damaged = temporary / kind
        shutil.copytree(backup, damaged)
        if kind == 'missing-wal':
            (damaged / 'wal').unlink()
        else:
            path = damaged / 'snapshot'
            data = bytearray(path.read_bytes())
            data[-1] ^= 1
            path.write_bytes(data)
        damaged_hash = digest(damaged)
        result = subprocess.run([str(tool), 'inspect', str(damaged)],
                                capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and 'CorruptRecord' in result.stderr
        assert digest(damaged) == damaged_hash
        rejected.append(kind)
    return {'status': 'passed', 'namespaces': 6, 'records': 18,
            'snapshot_plus_wal': True, 'inspect_unchanged': True,
            'source_and_backup_unchanged': True, 'restored': verified,
            'damaged_backups_rejected_without_modification': rejected}


def image_tests(probe_binary, tool, temporary):
    if platform.system() != 'Darwin' or not shutil.which('hdiutil'):
        return {'status': 'unverified', 'reason': 'requires macOS hdiutil isolated image'}
    image = temporary / 'bounded.sparseimage'
    mount = temporary / 'mount'
    mount.mkdir()
    # A 32 MiB HFS+ volume bounds all fill writes, including on hosts with large disks.
    run('hdiutil', 'create', '-size', '32m', '-fs', 'HFS+', '-volname',
        'MetadataReliability', '-type', 'SPARSE', image)
    mounted = False
    try:
        run('hdiutil', 'attach', '-nobrowse', '-mountpoint', mount, image)
        mounted = True
        database = mount / 'db'
        database.mkdir()
        probe(probe_binary, 'seed', database)
        filler = mount / 'fill.bin'
        filled = 0
        observed_errno = None
        # Confirm the bounded mount capacity before attempting to exhaust it.
        capacity = shutil.disk_usage(mount).total
        if capacity > 40 * 1024 * 1024:
            raise RuntimeError(f'unsafe fill target capacity: {capacity}')
        with filler.open('wb', buffering=0) as stream:
            chunk = b'F' * (1024 * 1024)
            while filled <= 40 * 1024 * 1024:
                try:
                    count = stream.write(chunk)
                    if not count:
                        raise RuntimeError('fill write made no progress')
                    filled += count
                except OSError as error:
                    observed_errno = error.errno
                    if error.errno != errno.ENOSPC:
                        raise
                    break
        if observed_errno != errno.ENOSPC:
            raise RuntimeError('bounded volume did not return ENOSPC')
        failure = probe(probe_binary, 'full-write', database)
        filler.unlink()
        recovered = probe(probe_binary, 'verify', database)
        full = {'status': 'passed', 'capacity_bytes': capacity,
                'filled_bytes': filled, 'fill_errno': observed_errno,
                'probe': failure, 'recovery': recovered}
        run('hdiutil', 'detach', mount)
        mounted = False
        run('hdiutil', 'attach', '-readonly', '-nobrowse', '-mountpoint', mount, image)
        mounted = True
        before = digest(database)
        inspected = json.loads(run(tool, 'inspect', database))
        rejected = probe(probe_binary, 'readonly', database)
        assert digest(database) == before
        readonly = {'status': 'passed', 'inspect_generation': inspected['generation'],
                    'files_unchanged': True, 'probe': rejected}
        return {'status': 'passed', 'filesystem': 'HFS+', 'enospc': full, 'readonly': readonly}
    finally:
        # Never remove the backing image or mount directory while still mounted.
        if mounted:
            run('hdiutil', 'detach', mount)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('probe', type=Path)
    parser.add_argument('tool', type=Path)
    parser.add_argument('--disk-image', action='store_true')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    started = time.monotonic()
    report = {'platform': platform.platform(), 'backup': None, 'filesystem_faults': None}
    # Explicit cleanup only after successful detach. On a detach failure retain
    # the temporary path for manual cleanup instead of traversing a mounted FS.
    temporary = Path(tempfile.mkdtemp(prefix='metadata-reliability-'))
    clean = False
    try:
        report['backup'] = backup_test(args.probe.resolve(), args.tool.resolve(), temporary)
        if args.disk_image:
            report['filesystem_faults'] = image_tests(args.probe.resolve(), args.tool.resolve(), temporary)
        else:
            report['filesystem_faults'] = {'status': 'unverified', 'reason': '--disk-image not requested'}
        clean = True
    except Exception as error:
        report['error'] = str(error)
        report['retained_temporary_path'] = str(temporary)
        raise
    finally:
        report['elapsed_seconds'] = time.monotonic() - started
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(json.dumps(report, indent=2))
        if clean:
            shutil.rmtree(temporary)


if __name__ == '__main__':
    main()
