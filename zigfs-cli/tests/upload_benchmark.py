"""Compare sequential and parallel uploads against one disposable Debug server.

Usage: python3 tests/upload_benchmark.py NEW_ZC SERVER [BASELINE_ZC]
Includes hashing and completion in elapsed time; never uses an existing instance.
"""
import hashlib
import json
import os
from pathlib import Path
import socket
import statistics
import subprocess
import sys
import tempfile
import time
import urllib.request

cli = Path(sys.argv[1]).resolve()
server_binary = Path(sys.argv[2]).resolve()
baseline = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else None
with tempfile.TemporaryDirectory(prefix='zc-upload-benchmark-') as temporary:
    root = Path(temporary)
    env = {k: v for k, v in os.environ.items() if not k.startswith(('ZC_', 'ZIGFS_'))}
    env['XDG_CONFIG_HOME'] = str(root / 'config')
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        port = listener.getsockname()[1]
    endpoint = f'http://127.0.0.1:{port}'
    settings = root / '.env'
    settings.write_text('\n'.join([
        f'ZIGFS_API_ADDRESS=127.0.0.1:{port}',
        f'ZIGFS_S3_PUBLIC_ENDPOINT={endpoint}',
        f'ZIGFS_DATA_ROOT={root}/data',
        'ZIGFS_METRICS_ENABLED=false',
        'ZIGFS_ROOT_USER=qa',
        'ZIGFS_ROOT_PASSWORD=benchmark-password',
        'ZIGFS_ADMIN_SESSION_SECRET=benchmark-session-secret-0123456789abcdef',
        'ZIGFS_ACCESS_KEY=BenchmarkAccessKey',
        'ZIGFS_SECRET_KEY=benchmark-secret-0123456789abcdef',
    ]))
    log = (root / 'server.log').open('wb')
    server = subprocess.Popen([str(server_binary), '--env-file', str(settings)],
                              cwd=root, env=env, stdout=log, stderr=log)

    def run(binary, args):
        result = subprocess.run([str(binary), '--json', *map(str, args)], env=env,
                                capture_output=True, timeout=120)
        assert result.returncode == 0, result.stderr.decode(errors='replace')
        return json.loads(result.stdout)

    try:
        for _ in range(200):
            try:
                with urllib.request.urlopen(endpoint + '/health/ready', timeout=1):
                    break
            except OSError:
                if server.poll() is not None:
                    raise RuntimeError('benchmark server exited')
                time.sleep(0.05)
        else:
            raise RuntimeError('benchmark server not ready')
        run(cli, ['alias', 'set', 'bench', endpoint, 'BenchmarkAccessKey',
                  'benchmark-secret-0123456789abcdef'])
        run(cli, ['mb', 'bench/benchmark'])
        source = root / 'payload.bin'
        chunk = os.urandom(1024 * 1024)
        with source.open('wb') as output:
            for _ in range(128):
                output.write(chunk)
        with source.open('rb') as original:
            expected_hash = hashlib.file_digest(original, 'sha256').digest()
        candidates = [('new-serial', cli, ['--part-concurrency', '1']),
                      ('new-parallel', cli, [])]
        if baseline:
            candidates.insert(0, ('baseline', baseline, []))
        samples = {name: [] for name, _, _ in candidates}
        for iteration in range(3):
            order = candidates if iteration % 2 == 0 else list(reversed(candidates))
            for name, binary, options in order:
                target = f'bench/benchmark/{name}-{iteration}'
                started = time.monotonic()
                run(binary, ['cp', source, target, '--part-size', '16MiB',
                             '--state-file', root / f'{name}-{iteration}.json', *options])
                elapsed = time.monotonic() - started
                samples[name].append(elapsed)
                destination = root / f'{name}-{iteration}.download'
                run(cli, ['get', target, destination])
                with destination.open('rb') as downloaded:
                    assert hashlib.file_digest(downloaded, 'sha256').digest() == expected_hash
                run(cli, ['rm', target, '--yes'])
                print(f'{name} run {iteration + 1}: {elapsed:.3f}s, {128 / elapsed:.1f} MiB/s', flush=True)
        print(json.dumps({name: {'seconds': times,
                                 'median_MiB_per_second': 128 / statistics.median(times)}
                          for name, times in samples.items()}, indent=2))
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        log.close()
