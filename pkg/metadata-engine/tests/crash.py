#!/usr/bin/env python3
"""Kill the actual engine process at named persistence boundaries, then reopen."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import time
from pathlib import Path


def run(*args):
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=30)


def contents(directory):
    return {
        str(path.relative_to(directory)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in directory.rglob('*')
        if path.is_file()
    }


def kill_at_boundary(probe, directory, mode, point):
    child = subprocess.Popen(
        [probe, mode, str(directory), point],
        stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    )
    try:
        deadline = time.monotonic() + 20
        while not (directory / 'READY').exists():
            if child.poll() is not None:
                raise AssertionError(f'{point}: process exited early: {child.communicate()}')
            if time.monotonic() >= deadline:
                raise TimeoutError(f'{point}: boundary not reached')
            time.sleep(0.01)
        child.kill()
        child.communicate(timeout=10)
    finally:
        if child.poll() is None:
            child.kill()
            child.communicate(timeout=10)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('probe', type=Path)
    parser.add_argument('tool', type=Path)
    args = parser.parse_args()
    probe, tool = str(args.probe.resolve()), str(args.tool.resolve())
    points = ('after_append', 'before_sync', 'after_sync', 'archive_source_synced', 'archive_linked', 'after_archive',
              'replacement_synced',
              'wal_replaced', 'after_rotate', 'checkpoint_captured',
              'snapshot_written', 'snapshot_synced', 'snapshot_published', 'after_snapshot', 'cleanup_started')
    with tempfile.TemporaryDirectory(prefix='metadata-crash-') as temporary:
        for point in points:
            directory = Path(temporary) / point
            directory.mkdir()
            run(probe, 'seed', str(directory))
            kill_at_boundary(probe, directory, 'crash', point)
            before = contents(directory)
            inspected = json.loads(run(tool, 'inspect', str(directory)).stdout)
            assert before == contents(directory), f'{point}: inspect changed files'
            assert inspected['records'] >= 1
            extra = ['expect-new'] if point == 'after_sync' else []
            run(probe, 'verify', str(directory), *extra)
            run(tool, 'inspect', str(directory))
            print(f'PASS SIGKILL {point}')
        group_points = ('before-group', 'append-1', 'append-2', 'before-sync',
                        'after-sync', 'after-group', 'notify-1')
        for point in group_points:
            directory = Path(temporary) / f'group-{point}'
            directory.mkdir()
            run(probe, 'seed', str(directory))
            kill_at_boundary(probe, directory, 'group-crash', point)
            before = contents(directory)
            run(tool, 'inspect', str(directory))
            assert before == contents(directory), f'group-{point}: inspect changed files'
            run(probe, 'group-verify', str(directory), point)
            run(tool, 'inspect', str(directory))
            print(f'PASS Runtime Group Commit SIGKILL {point}')
        # A fixed view must survive acknowledged updates after its capture,
        # whether the old snapshot or newly installed snapshot wins recovery.
        for point in ('snapshot_written', 'snapshot_synced', 'snapshot_published',
                      'after_snapshot', 'cleanup_started'):
            directory = Path(temporary) / f'pinned-{point}'
            directory.mkdir()
            run(probe, 'seed', str(directory))
            kill_at_boundary(probe, directory, 'pinned-crash', point)
            before = contents(directory)
            run(tool, 'inspect', str(directory))
            assert before == contents(directory), f'pinned-{point}: inspect changed files'
            run(probe, 'pinned-verify', str(directory))
            run(tool, 'inspect', str(directory))
            print(f'PASS pinned view SIGKILL {point}')
        # Verify offline detection and explicit tail repair are separate actions.
        directory = Path(temporary) / 'torn-tail'
        directory.mkdir()
        run(probe, 'seed', str(directory))
        with (directory / 'wal').open('ab') as wal:
            wal.write(b'partial')
        before = contents(directory)
        report = json.loads(run(tool, 'inspect', str(directory)).stdout)
        assert report['incomplete_tail_bytes'] == 7
        assert before == contents(directory)
        run(tool, 'recover', str(directory))
        assert (directory / 'wal').stat().st_size > 80
        report = json.loads(run(tool, 'inspect', str(directory)).stdout)
        assert report['incomplete_tail_bytes'] == 0
        print('PASS inspect is read-only; recover truncates only incomplete tail')


if __name__ == '__main__':
    main()
