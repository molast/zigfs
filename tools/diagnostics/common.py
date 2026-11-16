"""Local artifact helpers. No credentials or process environment are serialized."""
import hashlib
import json
import os
import pathlib
import platform
import subprocess
import time


def directory(path):
    path = pathlib.Path(path).resolve()
    path.mkdir(parents=True, exist_ok=False, mode=0o700)
    return path


def write_json(path, value):
    with pathlib.Path(path).open('w') as stream:
        json.dump(value, stream, indent=2, allow_nan=False)
        stream.write('\n')
    os.chmod(path, 0o600)


def identity(binary):
    path = pathlib.Path(binary).resolve(strict=True)
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(block)
    return dict(path=str(path), sha256=digest.hexdigest(), bytes=path.stat().st_size)


def execute(command, log, timeout=60, env=None, cwd=None):
    started = time.monotonic()
    with pathlib.Path(log).open('w') as stream:
        try:
            result = subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT,
                                    timeout=timeout, env=env, cwd=cwd, text=True)
            code, timed_out = result.returncode, False
        except subprocess.TimeoutExpired:
            code, timed_out = None, True
    os.chmod(log, 0o600)
    return dict(exit_code=code, timed_out=timed_out, elapsed_seconds=time.monotonic()-started,
                log=pathlib.Path(log).name)


def manifest(kind, **values):
    return dict(schema_version=1, kind=kind, platform=platform.platform(), timestamp=time.time(), **values)


def verify_process(pid, binary):
    """Reject PID/executable mismatches before attaching or labeling a snapshot."""
    if pid <= 1: raise ValueError('PID must exceed 1')
    os.kill(pid, 0)
    if platform.system() == 'Linux':
        actual = pathlib.Path(f'/proc/{pid}/exe').resolve(strict=True)
    elif platform.system() == 'Darwin':
        result = subprocess.run(['ps','-p',str(pid),'-o','comm='], capture_output=True,text=True,timeout=5)
        if result.returncode or not result.stdout.strip(): raise ValueError('Could not identify process executable')
        actual = pathlib.Path(result.stdout.strip())
    else: raise ValueError('Process identification unsupported on this platform')
    if not actual.samefile(binary): raise ValueError('PID does not match the supplied executable')
