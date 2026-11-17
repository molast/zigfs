"""Alternate two benchmark binaries with identical verified workloads and RSS isolation."""
import argparse
import hashlib
import json
import platform
import re
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path


def metrics(output):
    result = {}
    for line in output.splitlines():
        name = line.split()[0]
        for key, value in re.findall(r'(\w+)=([0-9]+(?:\.[0-9]+)?)(?:\s|$)', line):
            result[f'{name}.{key}'] = float(value)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('before', type=Path)
    parser.add_argument('after', type=Path)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--operations', type=int, default=100000)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if args.rounds < 1 or args.operations < 100000:
        parser.error('rounds >= 1 and operations >= 100000 required for one full round per run')
    binaries = {'before': args.before.resolve(), 'after': args.after.resolve()}
    report = {
        'platform': platform.platform(), 'operations': args.operations,
        'payload_bytes': 256, 'batch_size': 32, 'workers': 8,
        'sha256': {name: hashlib.sha256(path.read_bytes()).hexdigest()
                   for name, path in binaries.items()},
        'runs': [],
    }
    for round_index in range(args.rounds):
        order = ['before', 'after'] if round_index % 2 == 0 else ['after', 'before']
        for name in order:
            # Each wrapper has exactly one benchmark child, so RUSAGE_CHILDREN
            # records that binary's RSS instead of a cumulative cross-run maximum.
            with tempfile.TemporaryDirectory(prefix='metadata-compare-') as temporary:
                output = Path(temporary) / 'result.json'
                subprocess.run([
                    sys.executable, str(Path(__file__).with_name('soak.py')),
                    str(binaries[name]), '--seconds', '0.01',
                    '--operations', str(args.operations), '--output', str(output),
                ], check=True, capture_output=True, text=True, timeout=360)
                run = json.loads(output.read_text())
            if run['rounds'] != 1:
                raise RuntimeError('comparison requires one workload per child')
            values = metrics(run['outputs'][0])
            values['peak_child_rss_bytes'] = run['peak_child_rss_bytes']
            report['runs'].append({'variant': name, 'round': round_index + 1,
                                   'metrics': values, 'raw': run})
            print(f'{name} round={round_index + 1} completed', flush=True)
    report['median'] = {}
    for name in binaries:
        runs = [run['metrics'] for run in report['runs'] if run['variant'] == name]
        report['median'][name] = {
            key: statistics.median(run[key] for run in runs) for key in runs[0]
        }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report['median'], indent=2))


if __name__ == '__main__':
    main()
