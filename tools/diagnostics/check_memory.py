#!/usr/bin/env python3
"""Run isolated ZigFS memory fault probes and write evidence; never attach to a server."""
import argparse
import datetime
import json
import pathlib
import platform
import resource
import subprocess

CASES = {
    'clean': None,
    'leak': 'DiagnosticLeakDetected',
    'double-free': 'double free',
    'use-after-free': 'write after free',
    'buffer-overflow': 'corrupt',
}


def run(binary, output):
    binary = pathlib.Path(binary).resolve(strict=True)
    output = pathlib.Path(output).resolve()
    output.mkdir(parents=True, exist_ok=False)
    # Faults must not generate large or potentially sensitive OS core dumps.
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    results = []
    for mode, marker in CASES.items():
        try:
            result = subprocess.run([str(binary), mode], cwd=output, capture_output=True,
                                    text=True, errors='replace', timeout=20)
            log = result.stdout + result.stderr
            passed = (result.returncode == 0 if marker is None else
                      result.returncode != 0 and marker.lower() in log.lower())
            row = dict(case=mode, exit_code=result.returncode, passed=passed, log=f'{mode}.log')
        except subprocess.TimeoutExpired as error:
            log = str(error)
            row = dict(case=mode, exit_code=None, passed=False, log=f'{mode}.log', error='timeout')
        (output / row['log']).write_text(log)
        results.append(row)
    report = dict(schema_version=1, kind='memory-probes', generated_at=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                  platform=platform.platform(), binary=str(binary), cases=results,
                  all_passed=all(row['passed'] for row in results),
                  scope='SafeAllocator isolated faults; not ASan/UBSan/TSan validation or proof the server is memory-safe')
    (output / 'report.json').write_text(json.dumps(report, indent=2) + '\n')
    lines = ['# ZigFS memory diagnostic probes', '', report['scope'], '',
             '| Probe | Result | Exit code | Evidence |', '| --- | --- | --- | --- |']
    lines += [f"| {row['case']} | {'PASS' if row['passed'] else 'FAIL'} | {row['exit_code']} | [{row['log']}]({row['log']}) |" for row in results]
    (output / 'report.md').write_text('\n'.join(lines) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, help='Built memory-diagnostic-probe executable')
    parser.add_argument('--output', required=True, help='New report directory; existing paths are rejected')
    args = parser.parse_args()
    try:
        report = run(args.binary, args.output)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
    print(json.dumps({'all_passed': report['all_passed'], 'report': str(pathlib.Path(args.output) / 'report.md')}))
    return 0 if report['all_passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())
