#!/usr/bin/env python3
"""Repeat verified write/read/page/checkpoint/reopen workloads for a time budget."""
import argparse
import json
import resource
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('benchmark', type=Path)
    parser.add_argument('--seconds', type=float, default=60)
    parser.add_argument('--operations', type=int, default=100000)
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--payload', type=int, default=256)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.seconds <= 0 or args.operations <= 0:
        parser.error('seconds and operations must be positive')
    binary = str(args.benchmark.resolve())
    started = time.monotonic()
    rounds = []
    while time.monotonic() - started < args.seconds:
        with tempfile.TemporaryDirectory(prefix='metadata-soak-') as temporary:
            target = str(Path(temporary) / 'database')
            result = subprocess.run(
                [binary, target, str(args.operations), str(args.payload), '32',
                 str(args.workers), 'runtime'],
                capture_output=True, text=True, timeout=300,
            )
            if result.returncode != 0:
                sys.stderr.write(result.stdout + result.stderr)
                raise RuntimeError(f'round {len(rounds) + 1} failed: {result.returncode}')
            rounds.append(result.stdout + result.stderr)
            print(f'round={len(rounds)} records={args.operations} elapsed_seconds={time.monotonic() - started:.2f}', flush=True)
    peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
    report = {
        'elapsed_seconds': time.monotonic() - started,
        'rounds': len(rounds),
        'records_per_round': args.operations,
        'workers': args.workers,
        'payload_bytes': args.payload,
        'peak_child_rss_bytes': peak if sys.platform == 'darwin' else peak * 1024,
        'platform': sys.platform,
        'errors': 0,
        'outputs': rounds,
    }
    if args.output:
        args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({key: value for key, value in report.items() if key != 'outputs'}))


if __name__ == '__main__':
    main()
