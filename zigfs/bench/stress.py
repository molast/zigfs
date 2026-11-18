#!/usr/bin/env python3
"""Run a bounded, sustained ZigFS workload with integrity checks and resource samples."""
import argparse
import concurrent.futures
import importlib.util
import json
import os
import pathlib
import secrets
import signal
import threading
import time
import urllib.request


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# Resolve shared helpers from this file, so invocation does not depend on cwd.
benchmark = load_module('zigfs_benchmark', pathlib.Path(__file__).with_name('benchmark.py'))
artifacts = load_module(
    'zigfs_diagnostic_artifacts',
    pathlib.Path(__file__).resolve().parents[2] / 'tools/diagnostics/common.py',
)
BOUNDS = [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000, 10000, 30000]


def percentile(histogram, count, quantile):
    if not count: return None
    cumulative = 0
    for bound, observations in zip(BOUNDS, histogram):
        cumulative += observations
        if cumulative >= count * quantile: return bound
    return None


def run(target, output, seconds=1800, concurrency=4, size=65536, pause=0.1, monitor=None, cookie=None, interval=10):
    output = artifacts.directory(output)
    client = benchmark.S3(target)
    bucket = 'zigfs-stress-' + secrets.token_hex(8)
    stop = threading.Event()
    interrupted = threading.Event()
    lock = threading.Lock()
    totals = {op: dict(attempts=0, successes=0, errors=0, histogram=[0]*14, bytes=0) for op in ['PUT','GET','HEAD','DELETE']}
    errors = {}
    samples = []
    old_handlers = {}
    def cancel(signum, frame):
        interrupted.set(); stop.set()
    for sig in [signal.SIGINT, signal.SIGTERM]:
        old_handlers[sig] = signal.signal(sig, cancel)
    started = time.monotonic()
    deadline = started + seconds
    created = False
    cleanup_errors = []
    fatal = None
    # Data and in-flight object count are bounded by size * concurrency.
    def worker(index):
        local = benchmark.S3(target)
        path = f'/{bucket}/worker-{index}'
        payload = bytes([(index + 17) % 251]) * size
        while time.monotonic() < deadline and not stop.is_set():
            for op in totals:
                if stop.is_set(): return
                begin = time.monotonic()
                error = None
                try:
                    value = local.request(op, path, payload if op == 'PUT' else b'')
                    if op == 'GET' and value != payload: error = 'payload_mismatch'
                except Exception as caught:
                    error = str(getattr(caught, 'code', type(caught).__name__))
                duration = (time.monotonic() - begin) * 1000
                with lock:
                    row = totals[op]; row['attempts'] += 1
                    if error:
                        row['errors'] += 1; errors[error] = errors.get(error, 0) + 1
                    else:
                        row['successes'] += 1
                        row['bytes'] += size if op in ('PUT','GET') else 0
                        index_bin = next((i for i,b in enumerate(BOUNDS) if duration <= b), 13)
                        row['histogram'][index_bin] += 1
            stop.wait(pause)
    def sample():
        if not monitor: return
        record = dict(elapsed_seconds=time.monotonic()-started)
        try:
            request = urllib.request.Request(monitor, headers={'Cookie': 'zigfs_admin_session='+cookie} if cookie else {})
            with urllib.request.urlopen(request, timeout=5) as response:
                value = json.load(response)
            # Allowlist: do not store tokens, arbitrary configuration or user object names.
            record.update(latest=value.get('latest'), analysis=value.get('analysis'), locks=value.get('locks'))
        except Exception as error:
            record['error'] = str(getattr(error, 'code', type(error).__name__))
        samples.append(record)
        with (output/'samples.jsonl').open('a') as stream: stream.write(json.dumps(record)+'\n')
    try:
        client.request('PUT','/'+bucket); created = True
        sample()
        with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
            jobs = [pool.submit(worker,i) for i in range(concurrency)]
            while time.monotonic() < deadline and not stop.is_set():
                stop.wait(min(interval,max(0,deadline-time.monotonic())))
                sample()
                if all(job.done() for job in jobs): break
            for job in jobs: job.result()
    except Exception as error:
        fatal = type(error).__name__; stop.set()
    finally:
        stop.set()
        workload_elapsed = time.monotonic()-started
        if created:
            for index in range(concurrency):
                try: client.request('DELETE', f'/{bucket}/worker-{index}')
                except Exception: cleanup_errors.append(f'worker-{index}')
            try: client.request('DELETE','/'+bucket)
            except Exception: cleanup_errors.append(bucket)
        for sig, handler in old_handlers.items(): signal.signal(sig, handler)
    for row in totals.values():
        row.update(p50_ms=percentile(row['histogram'], row['successes'], .5),
                   p95_ms=percentile(row['histogram'], row['successes'], .95),
                   p99_ms=percentile(row['histogram'], row['successes'], .99),
                   successful_requests_per_second=row['successes']/max(workload_elapsed,.001))
    passed = not (fatal or interrupted.is_set() or cleanup_errors or errors) and workload_elapsed >= seconds and all(row['successes'] for row in totals.values())
    report = artifacts.manifest('stress', passed=passed, requested_seconds=seconds, elapsed_seconds=workload_elapsed,
                      interrupted=interrupted.is_set(), fatal=fatal, concurrency=concurrency, size=size, pause_seconds=pause,
                      operations=totals, errors=errors, cleanup_errors=cleanup_errors,
                      sample_count=len(samples), sample_errors=sum('error' in row for row in samples),
                      telemetry_requested=bool(monitor), bucket=bucket,
                      scope='Client-side sustained S3 integrity test; percentiles are histogram upper bounds; not proof of leak absence')
    if monitor and (not samples or report['sample_errors'] or not all(row.get('latest') for row in samples)): report['passed']=False
    artifacts.write_json(output/'report.json',report)
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--targets', required=True)
    parser.add_argument('--output', required=True)
    parser.add_argument('--seconds', type=int, default=1800)
    parser.add_argument('--concurrency', type=int, default=4)
    parser.add_argument('--size', type=int, default=65536)
    parser.add_argument('--pause', type=float, default=.1)
    parser.add_argument('--monitor', help='BFF /api/v1/monitoring URL; cookie read from --cookie-env')
    parser.add_argument('--cookie-env', default='ZIGFS_DIAGNOSTIC_COOKIE')
    args=parser.parse_args()
    if not (1<=args.seconds<=86400 and 1<=args.concurrency<=32 and 1<=args.size<=16*1024*1024 and .01<=args.pause<=60): parser.error('Invalid workload bounds')
    targets=json.loads(pathlib.Path(args.targets).read_text())
    if len(targets)!=1: parser.error('Exactly one ZigFS target required')
    report=run(targets[0], args.output,args.seconds,args.concurrency,args.size,args.pause,args.monitor,os.environ.get(args.cookie_env))
    print(json.dumps({'passed':report['passed'],'elapsed_seconds':report['elapsed_seconds'],'output':args.output}))
    return 0 if report['passed'] else 1


if __name__=='__main__': raise SystemExit(main())
