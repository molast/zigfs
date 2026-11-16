#!/usr/bin/env python3
"""Capture a local ZigFS process with native tooling; never fabricate a profile."""
import argparse
import json
import os
import pathlib
import platform
import shutil
import subprocess
import time


def capture(pid, kind, seconds, output):
    if pid <= 1 or not 1 <= seconds <= 60:
        raise ValueError('PID must exceed 1 and duration must be between 1 and 60 seconds')
    os.kill(pid, 0)
    output = pathlib.Path(output)
    output.mkdir(parents=True, exist_ok=False)
    system = platform.system()
    if system == 'Darwin':
        tool = shutil.which('sample')
        if not tool:
            raise RuntimeError('macOS sample is not installed')
        # sample reports thread call stacks and sampled CPU call trees.
        command = [tool, str(pid), str(seconds if kind == 'cpu' else 1), '10', '-file', str(output / 'sample.txt')]
    elif system == 'Linux' and kind == 'cpu':
        tool = shutil.which('perf')
        if not tool:
            raise RuntimeError('Install Linux perf; kernel perf_event permissions are required')
        command = [tool, 'record', '-F', '99', '-g', '-p', str(pid), '-o', str(output / 'perf.data'), '--', 'sleep', str(seconds)]
    elif system == 'Linux':
        tool = shutil.which('gdb')
        if not tool:
            raise RuntimeError('Install gdb; ptrace permissions are required for thread stacks')
        # Attaching briefly pauses the target. The CLI is deliberately not an HTTP endpoint.
        command = [tool, '-nx', '-batch', '-p', str(pid), '-ex', 'set pagination off', '-ex', 'thread apply all bt', '-ex', 'detach']
    else:
        raise RuntimeError(f'Unsupported diagnostic platform: {system}')
    started = time.time()
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=seconds + 30, text=True)
    (output / 'tool.log').write_text(result.stdout)
    manifest = dict(platform=system, pid=pid, kind=kind, duration_seconds=seconds if kind == 'cpu' else (1 if system == 'Darwin' else None), elapsed_seconds=time.time() - started, started_at=started,
                    exit_code=result.returncode, passed=False, tool=pathlib.Path(tool).name,
                    scope='local process', notes='Sampling is approximate; gdb attachment briefly pauses the process. Symbols depend on the target build.')
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    if result.returncode:
        raise RuntimeError(f'Capture failed (exit {result.returncode}); see {output / "tool.log"}. No successful profile is claimed.')
    if system == 'Linux' and kind == 'threads':
        (output / 'threads.txt').write_text(result.stdout)
    if system == 'Linux' and kind == 'cpu':
        report = subprocess.run([tool, 'report', '--stdio', '-i', str(output / 'perf.data')], capture_output=True, text=True, timeout=30)
        (output / 'cpu-report.txt').write_text(report.stdout + report.stderr)
        if report.returncode:
            raise RuntimeError('perf captured data but report generation failed; inspect perf.data and cpu-report.txt')
        samples = subprocess.run([tool, 'script', '-i', str(output / 'perf.data'), '-F', 'event'], capture_output=True, text=True, timeout=30)
        (output / 'sample-events.txt').write_text(samples.stdout)
        (output / 'sample-events.log').write_text(samples.stderr)
        if samples.returncode or not samples.stdout.strip():
            raise RuntimeError('perf produced no readable samples; retry while the target is under load. No successful profile is claimed.')
        manifest['sample_count'] = len(samples.stdout.splitlines())
    manifest['passed'] = True
    (output / 'manifest.json').write_text(json.dumps(manifest, indent=2))
    return manifest


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--pid', type=int, required=True)
    parser.add_argument('--kind', choices=['cpu', 'threads'], required=True)
    parser.add_argument('--seconds', type=int, default=5)
    parser.add_argument('--output', required=True, help='New output directory; existing paths are never overwritten')
    args = parser.parse_args()
    try:
        print(json.dumps(capture(args.pid, args.kind, args.seconds, args.output), indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.TimeoutExpired) as error:
        parser.exit(1, f'{error}\n')
