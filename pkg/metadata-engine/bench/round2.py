#!/usr/bin/env python3
"""Run bounded, serial before/after workloads on macOS, including diagnostics."""
import argparse
import hashlib
import json
import subprocess
import tempfile
import time
import re
from pathlib import Path


def run(binary, records, workers, mode, payload=256):
    with tempfile.TemporaryDirectory(prefix='metadata-round2-') as temporary:
        command = [str(binary.resolve()), str(Path(temporary) / 'db'),
                   str(records), str(payload), '32', str(workers), 'runtime']
        if mode != 'plain':
            command.append(mode)
        started = time.monotonic()
        process = subprocess.run(['/usr/bin/time', '-l', *command],
                                 capture_output=True, text=True, timeout=600)
        output = process.stdout + process.stderr
        if process.returncode:
            raise RuntimeError(output)
        peak = re.search(r'(\d+)\s+maximum resident set size', output)
        return {'records': records, 'workers': workers, 'mode': mode, 'payload_bytes': payload,
                'elapsed_seconds': time.monotonic() - started,
                'peak_rss_bytes': int(peak.group(1)) if peak else None,
                'output': output, 'returncode': process.returncode,
                'binary_sha256': hashlib.sha256(binary.read_bytes()).hexdigest()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--records', type=int, nargs='+', default=[10000, 100000, 1000000])
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--payload', type=int, default=256)
    parser.add_argument('--repeats', type=int, default=3)
    parser.add_argument('--mode', choices=['plain', 'phases', 'profile'], default='plain')
    parser.add_argument('--version', choices=['both', 'before', 'after'], default='both')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    reports = []
    for records in args.records:
        for repeat in range(args.repeats):
            order = ('before', 'after') if repeat % 2 == 0 else ('after', 'before')
            if args.version != 'both':
                order = (args.version,)
            for version in order:
                result = run(getattr(args, version), records, args.workers, args.mode, args.payload)
                result.update(version=version, repeat=repeat + 1)
                reports.append(result)
                args.output.write_text(json.dumps(reports, indent=2) + '\n')
                print(f'{records} {version} {args.mode} round={repeat + 1}: '
                      f'{result["elapsed_seconds"]:.2f}s', flush=True)


if __name__ == '__main__':
    main()
