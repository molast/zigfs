"""Compare verified KV workloads; each binary runs alone in a new temporary DB."""
import argparse
import hashlib
import json
import os
import signal
import platform
import re
import resource
import statistics
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def zig_metrics(output):
    metrics = {}
    aliases = {'latency_us_p50': 'p50_us', 'p95': 'p95_us', 'p99': 'p99_us', 'max': 'max_us'}
    for line in output.splitlines():
        fields = line.split()
        if not fields:
            continue
        name = fields[0]
        if name not in ('durable_insert', 'warm_get', 'concurrent_overwrite',
                        'prefix_pages', 'full_sorted_scan', 'close', 'wal_reopen'):
            continue
        values = {aliases.get(k, k): float(v) for k, v in
                  re.findall(r'(\w+)=([0-9]+(?:\.[0-9]+)?)(?:\s|$)', line)}
        metrics['reopen' if name == 'wal_reopen' else name] = values
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--single', help=argparse.SUPPRESS)
    parser.add_argument('--timeout', type=int, default=600, help='seconds allowed per database process (maximum 600)')
    parser.add_argument('--resume', action='store_true', help='continue completed cases in the output file')
    parser.add_argument('--zig', type=Path)
    parser.add_argument('--go', type=Path)
    parser.add_argument('--records', type=int, default=10000)
    parser.add_argument('--payload', type=int, default=256)
    parser.add_argument('--workers', type=int, default=8)
    parser.add_argument('--rounds', type=int, default=3)
    parser.add_argument('--engines', nargs='+', default=[
        'zig', 'zig-fullsync', 'bbolt', 'bbolt-batch', 'pebble', 'badger'])
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    if args.single:
        command = json.loads(args.single)
        start = time.monotonic()
        try:
            child = subprocess.run(command, capture_output=True, text=True, timeout=min(args.timeout, 600))
            stdout, stderr, returncode = child.stdout, child.stderr, child.returncode
            timed_out = False
        except subprocess.TimeoutExpired as error:
            def decoded(value):
                return value.decode(errors='replace') if isinstance(value, bytes) else (value or '')
            stdout, stderr, returncode = decoded(error.stdout), decoded(error.stderr), 124
            timed_out = True
        peak = resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss
        print(json.dumps({'returncode': returncode, 'stdout': stdout,
                          'stderr': stderr, 'timed_out': timed_out, 'elapsed_seconds': time.monotonic()-start,
                          'peak_rss_bytes': peak if sys.platform == 'darwin' else peak*1024}))
        return
    if not args.zig or not args.go or not args.output:
        parser.error('--zig, --go and --output required')
    if min(args.records, args.payload, args.workers, args.rounds, args.timeout) < 1:
        parser.error('sizes, workers and rounds must be positive')
    binaries = {'zig': args.zig.resolve(), 'go': args.go.resolve()}
    report = {'platform': platform.platform(), 'records': args.records,
              'payload_bytes': args.payload, 'batch_size': 32, 'workers': args.workers,
              'rounds': args.rounds, 'engines': args.engines,
              'binary_sha256': {k: hashlib.sha256(v.read_bytes()).hexdigest()
                                for k, v in binaries.items()}, 'runs': []}
    if args.resume and args.output.exists():
        previous = json.loads(args.output.read_text())
        for key in ('records', 'payload_bytes', 'batch_size', 'workers', 'rounds', 'engines', 'binary_sha256'):
            if previous[key] != report[key]:
                raise ValueError(f'resume configuration differs: {key}')
        report = previous
    completed = {(run['engine'], run['round']) for run in report['runs']}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    for iteration in range(args.rounds):
        offset = iteration % len(args.engines)
        order = args.engines[offset:] + args.engines[:offset]
        for name in order:
            if (name, iteration + 1) in completed:
                continue
            print(f'START {name} round={iteration+1} records={args.records}', flush=True)
            with tempfile.TemporaryDirectory(prefix='zigfs-kv-compare-') as temporary:
                db = Path(temporary) / 'db'
                common = [str(db), str(args.records), str(args.payload), '32', str(args.workers)]
                if name.startswith('zig'):
                    mode = 'direct' if args.workers == 1 else 'runtime'
                    comparison = 'compare-fullsync' if name == 'zig-fullsync' else 'compare'
                    command = [str(binaries['zig']), *common, mode, comparison]
                else:
                    command = [str(binaries['go']), name, *common]
                wrapper = subprocess.Popen([
                    sys.executable, str(Path(__file__).resolve()), '--single', json.dumps(command),
                    '--timeout', str(args.timeout),
                ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
                started = time.monotonic()
                try:
                    while True:
                        try:
                            stdout, stderr = wrapper.communicate(timeout=30)
                            break
                        except subprocess.TimeoutExpired:
                            print(f'RUNNING {name} round={iteration+1} '
                                  f'elapsed={time.monotonic()-started:.0f}s', flush=True)
                    if wrapper.returncode:
                        raise RuntimeError(f'{name} wrapper failed: {stderr}')
                finally:
                    if wrapper.poll() is None:
                        try:
                            os.killpg(wrapper.pid, signal.SIGTERM)
                        except ProcessLookupError:
                            pass
                        wrapper.communicate()
                run = json.loads(stdout)
                if run['returncode']:
                    report.setdefault('incomplete_runs', []).append({
                        **run, 'engine': name, 'round': iteration + 1, 'verified': False,
                    })
                    pending = args.output.with_suffix(args.output.suffix + '.tmp')
                    pending.write_text(json.dumps(report, indent=2)+'\n')
                    pending.replace(args.output)
                    raise RuntimeError(f'{name}: {run["stdout"]}\n{run["stderr"]}')
                run['metrics'] = zig_metrics(run['stderr']) if name.startswith('zig') else json.loads(run['stdout'])['metrics']
                run['disk_apparent_bytes'] = sum(p.stat().st_size for p in db.rglob('*') if p.is_file())
                run['disk_allocated_bytes'] = sum(p.stat().st_blocks*512 for p in db.rglob('*') if p.is_file())
                run['engine'] = name
                run['round'] = iteration + 1
                run['verified'] = True  # Nonzero exit on any count/content/reopen mismatch.
            report['runs'].append(run)
            pending = args.output.with_suffix(args.output.suffix + '.tmp')
            pending.write_text(json.dumps(report, indent=2)+'\n')
            pending.replace(args.output)
            print(f'{name} round={iteration+1} elapsed={run["elapsed_seconds"]:.2f}s '
                  f'overwrite_qps={run["metrics"]["concurrent_overwrite"]["qps"]:.0f}', flush=True)
    report['median'] = {}
    for name in args.engines:
        runs = [r for r in report['runs'] if r['engine'] == name]
        summary = {key: statistics.median(r[key] for r in runs) for key in
                   ('peak_rss_bytes', 'disk_apparent_bytes', 'disk_allocated_bytes', 'elapsed_seconds')}
        summary['metrics'] = {
            phase: {key: statistics.median(r['metrics'][phase][key] for r in runs)
                    for key in runs[0]['metrics'][phase]}
            for phase in runs[0]['metrics']}
        report['median'][name] = summary
    args.output.write_text(json.dumps(report, indent=2)+'\n')
    print('completed:', args.output)


if __name__ == '__main__':
    main()
