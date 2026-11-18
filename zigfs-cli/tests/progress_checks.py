"""Executed by s3api_integration.py with its isolated real server and fixture data."""
import errno
import fcntl
import pty
import re
import select
import struct
import termios


def terminal_transfer(arguments, expected=0, extra_env=None):
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 30, 160, 0, 0))
    terminal_env = dict(env)
    terminal_env.pop('NO_COLOR', None)
    terminal_env['TERM'] = 'xterm-256color'
    terminal_env.update(extra_env or {})
    # Keep stdout separate: progress must never corrupt downloaded bytes or JSON.
    with tempfile.TemporaryFile() as stdout_file:
        process = subprocess.Popen([str(CLI), *map(str, arguments)], env=terminal_env,
                                   stdout=stdout_file, stderr=slave)
        os.close(slave)
        captured = bytearray()
        before_exit = False
        deadline = time.monotonic() + 40
        try:
            while time.monotonic() < deadline:
                readable, _, _ = select.select([master], [], [], 0.1)
                if readable:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError as error:
                        if error.errno == errno.EIO:
                            break
                        raise
                    if not chunk:
                        break
                    captured.extend(chunk)
                    if process.poll() is None:
                        before_exit = True
                elif process.poll() is not None:
                    break
            else:
                raise AssertionError('terminal transfer timed out')
            assert process.wait(timeout=5) == expected, captured.decode(errors='replace')
            stdout_file.seek(0)
            output = stdout_file.read()
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
    assert AK.encode() not in captured and SK.encode() not in captured
    return bytes(captured), output, before_exit


progress_target = f'real/{bucket}/progress-single'
text, _, early = terminal_transfer(['cp', body, progress_target, '--rate-limit', '4MiB'])
assert early and b'Hashing' in text and b'Uploading' in text
assert re.search(rb'\[#{1,9}-{1,9}\]', text) and b'[##########]' in text
assert b'MiB/s' in text and b'ETA' in text and b'%' in text
assert b'Waiting for server' in text and b'sent 12.0 MiB' in text
assert b'\x1b[36m' in text and b'\x1b[32m' in text and b'Done' in text
assert text.count(b'Uploading') > 2

parallel_source = root / 'progress-parallel'
parallel_source.mkdir()
(parallel_source / 'a.bin').write_bytes(body.read_bytes())
(parallel_source / 'b.bin').write_bytes(body.read_bytes())
text, _, _ = terminal_transfer(['cp', parallel_source, f'real/{bucket}/progress-parallel/',
                               '--recursive', '--concurrency', '2'])
assert b'Done' in text and b'sent 24.0 MiB' in text

progress_download = root / 'progress-download'
text, _, _ = terminal_transfer(['get', progress_target, progress_download])
assert b'Downloading' in text and b'Done' in text
assert progress_download.read_bytes() == body.read_bytes()
text, raw, _ = terminal_transfer(['cat', progress_target])
assert raw == body.read_bytes() and b'Downloading' in text

multipart_target = f'real/{bucket}/progress-multipart'
text, _, _ = terminal_transfer(['cp', body, multipart_target, '--multipart-threshold', '5MiB',
                               '--part-size', '5MiB', '--state-file', root / 'progress-upload.json'])
assert b'Hashing source' in text and b'Verifying source' in text
assert b'part 1/' not in text and b'part 2/' not in text and b'part 3/' not in text
percentages = [float(value) for value in re.findall(rb'Uploading.*?([0-9]+\.[0-9]+)%', text)]
assert percentages == sorted(percentages)
assert b'Completing upload' in text and b'Done' in text

for options, environment in [(['--no-color'], {}), ([], {'NO_COLOR': '1'}), ([], {'TERM': 'dumb'})]:
    text, raw, _ = terminal_transfer(['cat', progress_target, *options], extra_env=environment)
    assert b'\x1b[' not in text and raw == body.read_bytes()
    assert b'Downloading' in text
for option in ('--no-progress', '--quiet'):
    text, raw, _ = terminal_transfer(['cat', progress_target, option])
    assert text == b'' and raw == body.read_bytes()
text, output, _ = terminal_transfer(['--json', 'get', progress_target, root / 'progress-json-download'])
assert text == b'' and json.loads(output)['status'] == 'success'
text, _, _ = terminal_transfer(['get', f'real/{bucket}/progress-missing', root / 'progress-missing'], expected=5)
assert b'\x1b[31m' in text and b'Failed' in text and b'Done' not in text
print('PASS progress: live PTY refresh/speed, upload/download bytes, multipart phases, colors, quiet/JSON/raw stream isolation, failure status.')
