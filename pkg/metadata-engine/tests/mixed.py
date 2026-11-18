"""Run one bounded-key engine instance; sample its RSS, then verify reopen."""
import argparse
import json
import pathlib
import platform
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('binary')
    parser.add_argument('--seconds', type=int, default=60)
    parser.add_argument('--output', type=pathlib.Path)
    parser.add_argument('--slots', type=int, default=64)
    parser.add_argument('--payload', type=int, default=256)
    args = parser.parse_args()
    if not 1 <= args.seconds <= 540:
        parser.error('--seconds must be between 1 and 540')
    samples = []
    with tempfile.TemporaryDirectory(prefix='metadata-mixed-') as temporary:
        root = pathlib.Path(temporary)
        with (root / 'output').open('w+') as output:
            process = subprocess.Popen(
                [str(pathlib.Path(args.binary).resolve()), str(root / 'db'), str(args.seconds), str(args.slots), str(args.payload)],
                stdout=output, stderr=subprocess.STDOUT,
            )
            start = time.monotonic()
            try:
                while process.poll() is None:
                    if time.monotonic() - start > args.seconds + 30:
                        raise TimeoutError('mixed workload stalled')
                    rss = subprocess.run(
                        ['ps', '-o', 'rss=', '-p', str(process.pid)],
                        capture_output=True, text=True, check=False,
                    )
                    if rss.returncode == 0 and rss.stdout.strip():
                        sample = {'seconds': round(time.monotonic() - start, 3),
                                  'rss_kib': int(rss.stdout.strip())}
                        files = []
                        for path in (root / 'db').glob('*'):
                            try:
                                stat = path.stat()
                            except FileNotFoundError:
                                continue  # Concurrent segment reclamation.
                            if path.is_file():
                                files.append((path.name, stat.st_size, stat.st_blocks * 512))
                        sample.update(file_count=len(files),
                                      logical_disk_bytes=sum(size for _, size, _ in files),
                                      allocated_disk_bytes=sum(size for _, _, size in files),
                                      snapshot_bytes=sum(size for name, size, _ in files if name == 'snapshot'))
                        samples.append(sample)
                    time.sleep(1)
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
            output.seek(0)
            log = output.read()
            if process.returncode:
                raise RuntimeError(log)
            events = [json.loads(line) for line in log.splitlines() if line.strip()]
            telemetry = [event for event in events if event.get('sample')]
            results = [event for event in events if not event.get('sample')]
            if len(results) != 1:
                raise RuntimeError(f'expected one final result: {log}')
            result = results[0]
    report = {'platform': platform.platform(), 'single_process': True,
              'slots_per_namespace': args.slots, 'payload_bytes': args.payload,
              'namespaces': result['namespace_count'], 'result': result, 'engine_samples': telemetry,
              'rss_samples': samples,
              'peak_sampled_rss_kib': max((s['rss_kib'] for s in samples), default=0)}
    rendered = json.dumps(report, indent=2) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(rendered)
    summary = {key: value for key, value in report.items()
               if key not in ('rss_samples', 'engine_samples')}
    summary['resource_samples'] = len(samples)
    summary['engine_samples'] = len(telemetry)
    print(json.dumps(summary, indent=2))


if __name__ == '__main__':
    main()
