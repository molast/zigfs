#!/usr/bin/env python3
"""Compare saved before/after binaries; each verified workload has a 600s cap."""
import argparse
import json
import re
import subprocess
import tempfile
import time
from pathlib import Path


def run(binary, records, profile):
    with tempfile.TemporaryDirectory(prefix='metadata-round1-') as directory:
        command = [str(binary.resolve()), str(Path(directory) / 'database'),
                   str(records), '256', '32', '8', 'runtime']
        if profile:
            command.append('profile')
        started = time.monotonic()
        result = subprocess.run(['/usr/bin/time', '-l', *command],
                                capture_output=True, text=True, timeout=600)
        output = result.stdout + result.stderr
        if result.returncode:
            raise RuntimeError(output)
        peak = re.search(r'(\d+)\s+maximum resident set size', output)
        return {'records': records, 'payload_bytes': 256, 'workers': 8,
                'profile': profile, 'elapsed_seconds': time.monotonic() - started,
                'returncode': result.returncode, 'output': output,
                'peak_rss_bytes': int(peak.group(1)) if peak else None}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--profile-only', action='store_true')
    args = parser.parse_args()
    if args.profile_only:
        report = run(args.after, 1000000, True)
        args.output.write_text(json.dumps(report, indent=2) + '\n')
        print(f'profile: {report["elapsed_seconds"]:.2f}s', flush=True)
        return
    reports = []
    for records in (10000, 100000, 1000000):
        for repeat in range(3):
            order = ('before', 'after') if repeat % 2 == 0 else ('after', 'before')
            for version in order:
                result = run(getattr(args, version), records, False)
                result.update(version=version, repeat=repeat + 1)
                reports.append(result)
                args.output.write_text(json.dumps(reports, indent=2) + '\n')
                print(f'{records} {version} round={repeat + 1}: '
                      f'{result["elapsed_seconds"]:.2f}s', flush=True)


if __name__ == '__main__':
    main()
