#!/usr/bin/env python3
"""Run a signed S3 workload against an isolated ZigFS namespace and write a performance report."""
import argparse
import concurrent.futures
import datetime
import hashlib
import hmac
import json
import math
import os
import pathlib
import platform
import secrets
import statistics
import time
import urllib.error
import urllib.parse
import urllib.request


class S3:
    def __init__(self, target):
        self.url = target['endpoint'].rstrip('/')
        parsed = urllib.parse.urlsplit(self.url)
        if parsed.scheme not in ('http', 'https') or parsed.path not in ('', '/') or parsed.username or parsed.query:
            raise ValueError('Endpoint must be an HTTP(S) origin, without embedded credentials')
        self.host = parsed.netloc
        self.region = target.get('region', 'us-east-1')
        self.key = os.environ[target['access_key_env']]
        self.secret = os.environ[target['secret_key_env']]

    def request(self, method, path, body=b'', query=''):
        stamp = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%dT%H%M%SZ')
        digest = hashlib.sha256(body).hexdigest()
        scope = f'{stamp[:8]}/{self.region}/s3/aws4_request'
        signed = 'host;x-amz-content-sha256;x-amz-date'
        canonical = f'{method}\n{path}\n{query}\nhost:{self.host}\nx-amz-content-sha256:{digest}\nx-amz-date:{stamp}\n\n{signed}\n{digest}'
        message = f'AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}'
        signing = ('AWS4' + self.secret).encode()
        for part in [stamp[:8], self.region, 's3', 'aws4_request']:
            signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
        headers = {'x-amz-date': stamp, 'x-amz-content-sha256': digest, 'Authorization': f'AWS4-HMAC-SHA256 Credential={self.key}/{scope}, SignedHeaders={signed}, Signature={hmac.new(signing, message.encode(), hashlib.sha256).hexdigest()}'}
        request = urllib.request.Request(self.url + path + ('?' + query if query else ''), data=body if method == 'PUT' else None, headers=headers, method=method)
        with urllib.request.urlopen(request, timeout=30) as response:
            # Bounded workload payload and full consumption; latency includes transfer.
            return response.read()


def percentile(values, q):
    return sorted(values)[max(0, math.ceil(len(values) * q) - 1)] if values else None


def run_target(target, size, count, concurrency):
    client = S3(target)
    bucket = 'zigfs-benchmark-' + secrets.token_hex(8)
    payload = bytes((i % 251 for i in range(size)))
    objects = [f'/{bucket}/object-{i:06d}' for i in range(count)]
    started = time.time()
    report = dict(name=target['name'], endpoint=target['endpoint'], declared_version=target.get('version', 'not supplied'), operations=[], cleanup_errors=[])
    created = False
    try:
        client.request('PUT', '/' + bucket)
        created = True
        # Same deterministic bytes and sequence, separate isolated namespace for each target.
        for operation in ['PUT', 'GET', 'HEAD', 'LIST', 'DELETE']:
            latencies, errors = [], 0
            wall = time.perf_counter()
            def execute(path):
                before = time.perf_counter()
                try:
                    value = client.request('GET' if operation == 'LIST' else operation,
                        '/' + bucket if operation == 'LIST' else path,
                        payload if operation == 'PUT' else b'', 'list-type=2&max-keys=1000' if operation == 'LIST' else '')
                    if operation == 'GET' and value != payload:
                        return None, 'payload_mismatch'
                    return (time.perf_counter() - before) * 1000, None
                except (OSError, urllib.error.HTTPError) as error:
                    return None, str(getattr(error, 'code', type(error).__name__))
            with concurrent.futures.ThreadPoolExecutor(max_workers=concurrency) as pool:
                outcomes = list(pool.map(execute, objects))
            elapsed = time.perf_counter() - wall
            error_counts = {}
            for duration, error in outcomes:
                if error:
                    errors += 1; error_counts[error] = error_counts.get(error, 0) + 1
                else:
                    latencies.append(duration)
            report['operations'].append(dict(operation=operation, attempts=count, successes=len(latencies), errors=errors,
                error_codes=error_counts, elapsed_seconds=elapsed, successful_requests_per_second=len(latencies) / elapsed,
                payload_bytes_per_second=(len(latencies) * size / elapsed) if operation in ('PUT','GET') else None,
                mean_ms=statistics.mean(latencies) if latencies else None, p50_ms=percentile(latencies,.5), p95_ms=percentile(latencies,.95), p99_ms=percentile(latencies,.99)))
    finally:
        if created:
            for path in objects:
                try: client.request('DELETE', path)
                except OSError: report['cleanup_errors'].append(path.rsplit('/',1)[-1])
            try: client.request('DELETE', '/' + bucket)
            except OSError: report['cleanup_errors'].append(bucket)
    report['started_at'] = started
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--targets', required=True, help='JSON array with name/endpoint/access_key_env/secret_key_env/version')
    parser.add_argument('--output', required=True, help='New report path; credentials are never written')
    parser.add_argument('--size', type=int, default=65536)
    parser.add_argument('--count', type=int, default=100)
    parser.add_argument('--concurrency', type=int, default=4)
    args = parser.parse_args()
    if not 1 <= args.size <= 16*1024*1024 or not 1 <= args.count <= 10000 or not 1 <= args.concurrency <= 128:
        parser.error('size 1..16 MiB, count 1..10000 and concurrency 1..128 required')
    targets = json.loads(pathlib.Path(args.targets).read_text())
    if len(targets) != 1:
        parser.error('Supply exactly one ZigFS target')
    output = pathlib.Path(args.output)
    if output.exists(): parser.error('Output already exists')
    report = dict(schema_version=1, workload=dict(size=args.size,count=args.count,concurrency=args.concurrency),
        client_platform=platform.platform(), generated_at=time.time(), targets=[], limitations='Client-side end-to-end timings, new HTTP connections, no warmup. This is an independent ZigFS test report, not runtime telemetry. Record hardware, storage, durability and build version when interpreting results.')
    failed = False
    for target in targets:
        try:
            result = run_target(target, args.size, args.count, args.concurrency)
            report['targets'].append(result)
            failed |= bool(result['cleanup_errors']) or any(row['errors'] for row in result['operations'])
        except Exception as error:
            failed = True
            report['targets'].append(dict(name=target.get('name'), status='unavailable', error=type(error).__name__))
    with output.open('x') as file: json.dump(report,file,indent=2)
    print(json.dumps({'report':str(output),'targets':len(targets),'all_successful':not failed}))
    return int(failed)

if __name__ == '__main__':
    raise SystemExit(main())
