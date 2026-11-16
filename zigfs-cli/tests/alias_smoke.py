"""Isolated alias tests; no network, real credentials or user configuration."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib

binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zc').resolve()
with tempfile.TemporaryDirectory(prefix='zc-alias-test-') as temp:
    root = Path(temp)
    env = {k: v for k, v in os.environ.items() if not k.startswith('ZC_') and k not in ('HOME', 'XDG_CONFIG_HOME')}
    env.update(HOME=str(root / 'home'), XDG_CONFIG_HOME=str(root / 'xdg'))
    config = root / 'xdg/zc/config.toml'
    secret, token = 'TEST_SECRET_quote"hash#back\\', 'TEST_SESSION_TOKEN'

    def run(*args, code=0, extra_env=None, raw=False):
        proc = subprocess.run([str(binary), '--json', *map(str, args)], env=env | (extra_env or {}), capture_output=True, text=True, timeout=10)
        assert proc.returncode == code, (args, proc.returncode, proc.stdout, proc.stderr)
        assert not (proc.stdout if code else proc.stderr), (args, proc.stdout, proc.stderr)
        value = json.loads(proc.stderr if code else proc.stdout)
        if not raw:
            assert value['status'] == ('error' if code else 'success')
        if '--include-credentials' not in args:
            for sensitive in (secret, token, 'TEST_ENV_SECRET'):
                assert sensitive not in proc.stdout + proc.stderr, (args, sensitive)
        return value

    def create(name, *opts, **kwargs):
        return run('alias', 'set', name, 'https://example.test:9000', 'AK', secret, *opts, **kwargs)

    assert run('alias', 'list')['data']['aliases'] == [] and not config.exists()
    create('local', '--session-token', token, '--region', 'test-1', '--bucket-lookup', 'dns', '--insecure', '--connect-timeout', '5', '--timeout', '40', '--management-endpoint', 'https://admin.test')
    assert config.stat().st_mode & 0o777 == 0o600
    assert tomllib.loads(config.read_text())['aliases'][0]['secret_key'] == secret
    info = run('alias', 'info', 'local')['data']
    assert info['alias']['insecure'] and info['alias']['region'] == 'test-1'
    assert info['credentials_configured'] and info['session_token_configured']
    assert 'secret_key' not in info['alias'] and 'access_key' not in info['alias']
    run('alias', 'info', 'missing', code=5)
    run('alias', 'set', 'env', 'http://localhost:9000', extra_env={'ZC_ACCESS_KEY_ID': 'ENV_AK', 'ZC_SECRET_ACCESS_KEY': 'TEST_ENV_SECRET', 'ZC_SESSION_TOKEN': token, 'ZC_REGION': 'env-1'})
    assert run('alias', 'info', 'env')['data']['alias']['region'] == 'env-1'
    before = config.read_bytes()
    run('alias', 'set', 'partial', 'http://localhost:9000', extra_env={'ZC_ACCESS_KEY_ID': 'AK'}, code=2)
    run('alias', 'set', 'partial', 'http://localhost:9000', 'AK', '--session-token', token, code=2)
    run('alias', 'set', 'partial', 'http://localhost:9000', code=2)
    assert config.read_bytes() == before
    key = root / 'secret.txt'; key.write_text(secret + '\n'); key.chmod(0o600)
    run('alias', 'set', 'file', 'https://example.test', 'AK', '--secret-key-file', key)
    run('alias', 'set', 'namedenv', 'https://example.test', 'AK', '--secret-key-from-env', 'TEST_KEY', extra_env={'TEST_KEY': secret})
    key.chmod(0o644)
    run('alias', 'set', 'file', 'https://example.test', 'AK', '--secret-key-file', key, code=4)
    create('bad', '--secret-key-from-env', 'TEST_KEY', code=2)
    for endpoint in ('ftp://example.test', 'https://user:pass@example.test', 'https://example.test/path', 'https://example.test?x=y', 'https://example.test#x', 'https://example.test:0'):
        run('alias', 'set', 'bad', endpoint, 'AK', secret, code=2)
    create('bad', '--signature', 'v2', code=7)
    run('--', 'alias', 'set', 'literal', 'https://example.test', 'AK', '--literal-secret')
    assert next(x for x in tomllib.loads(config.read_text())['aliases'] if x['name'] == 'literal')['secret_key'] == '--literal-secret'
    for opts in (('--timeout', '0'), ('--bucket-lookup', 'typo'), ('--connect-timeout', '99', '--timeout', '5'), ('--region', 'one', '--region', 'two')):
        create('bad', *opts, code=2)
    run('alias', 'list', '--replace', code=2)
    create('bad', '--ca-cert', root / 'missing.pem', code=5)
    cert = root / 'ca.pem'; cert.write_text('not a certificate')
    create('bad', '--ca-cert', cert, code=2)

    portable = root / 'portable.json'
    run('alias', 'export', 'local', '--output', portable)
    public_doc = json.loads(portable.read_text())
    assert 'secret_key' not in public_doc['aliases'][0] and portable.stat().st_mode & 0o777 == 0o600
    run('alias', 'export', 'local', '--output', portable, code=6)
    run('alias', 'export', 'local', '--output', portable, '--force')
    run('alias', 'export', '--include-credentials', code=2)
    run('alias', 'export', '--acknowledge-credentials', code=2)
    document = run('alias', 'export', 'local', '--include-credentials', '--acknowledge-credentials', raw=True)
    assert document['aliases'][0]['secret_key'] == secret
    target = root / 'imported/config.toml'
    run('--config', target, 'alias', 'import', portable)
    assert not run('--config', target, 'alias', 'info', 'local')['data']['credentials_configured']
    mixed = root / 'mixed.json'
    mixed.write_text(json.dumps({'schema_version': 1, 'aliases': [{'name': 'new-first', 'endpoint': 'https://new.test'}, public_doc['aliases'][0]]}))
    before = config.read_bytes()
    run('alias', 'import', mixed, code=6)
    assert config.read_bytes() == before
    run('alias', 'info', 'new-first', code=5)
    run('alias', 'import', mixed, '--replace')
    assert not run('alias', 'info', 'local')['data']['credentials_configured']
    invalid = root / 'invalid.json'
    for doc in ({'aliases': []}, {'schema_version': 2, 'aliases': []}, {'schema_version': 1, 'aliases': [public_doc['aliases'][0]] * 2}, {'schema_version': 1, 'aliases': [{'name': 'new-first', 'endpoint': 'https://ok.test'}, {'name': 'bad', 'endpoint': 'invalid'}]}, {'schema_version': 1, 'aliases': [], 'unknown': True}):
        invalid.write_text(json.dumps(doc)); before = config.read_bytes()
        run('alias', 'import', invalid, '--replace', code=2)
        assert config.read_bytes() == before
    exported = root / 'secrets.json'
    run('alias', 'export', 'file', '--include-credentials', '--acknowledge-credentials', '--output', exported)
    exported.chmod(0o644)
    run('--config', target, 'alias', 'import', exported, '--replace', code=4)
    exported.chmod(0o600)
    run('--config', target, 'alias', 'import', exported, '--replace')
    assert tomllib.loads(target.read_text())['aliases'][0]['secret_key'] == secret
    run('alias', 'export', '--output', config, '--force', code=2)

    env_config, explicit = root / 'env.toml', root / 'explicit.toml'
    create('path', extra_env={'ZC_CONFIG_FILE': str(env_config)})
    run('--config', explicit, 'alias', 'set', 'explicit', 'https://example.test', 'AK', secret, extra_env={'ZC_CONFIG_FILE': str(env_config)})
    assert env_config.exists() and explicit.exists()
    create('home', extra_env={'XDG_CONFIG_HOME': ''})
    assert (root / 'home/.config/zc/config.toml').exists()
    config.chmod(0o644); run('alias', 'list', code=4); config.chmod(0o600)
    broken = root / 'broken.toml'; broken.write_text('schema_version = 1\nunknown = true'); broken.chmod(0o600)
    run('--config', broken, 'alias', 'set', 'new', 'https://example.test', 'AK', secret, code=2)
    assert broken.read_text() == 'schema_version = 1\nunknown = true'
    link = root / 'link.toml'; link.symlink_to(config)
    run('--config', link, 'alias', 'list', code=2)
    run('alias', 'remove', 'file'); run('alias', 'info', 'file', code=5); run('alias', 'remove', 'file', code=5)
    if os.name == 'posix':
        import fcntl
        with open(str(config) + '.lock', 'r+') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            before = config.read_bytes()
            create('locked', code=6)
            assert config.read_bytes() == before
    # Export must not overwrite the active configuration via an alternate parent symlink.
    parent_link = root / 'alternate'; parent_link.symlink_to(config.parent, target_is_directory=True)
    run('alias', 'export', '--output', parent_link / config.name, '--force', code=2)

    # Human terminal input: no secret echo, restore termios on success and Ctrl+C.
    if os.name == 'posix':
        import pty
        import select
        import termios
        import time

        def terminal_set(name, input_bytes, expected):
            master, slave = pty.openpty()
            original = termios.tcgetattr(slave)
            proc = subprocess.Popen([str(binary), 'alias', 'set', name, 'https://example.test', 'AK'],
                                    stdin=slave, stderr=slave, stdout=subprocess.PIPE, env=env)
            captured = b''
            try:
                deadline = time.monotonic() + 10
                while b'Secret key: ' not in captured:
                    assert time.monotonic() < deadline, 'prompt timed out'
                    if select.select([master], [], [], 0.2)[0]:
                        captured += os.read(master, 4096)
                    assert proc.poll() is None, captured
                assert not termios.tcgetattr(slave)[3] & termios.ECHO
                os.write(master, input_bytes)
                out = b''
                deadline = time.monotonic() + 10
                while proc.poll() is None:
                    assert time.monotonic() < deadline, ('terminal execution timed out', captured)
                    for ready in select.select([master, proc.stdout], [], [], 0.1)[0]:
                        if ready == master:
                            captured += os.read(master, 4096)
                        else:
                            out += os.read(proc.stdout.fileno(), 4096)
                out += proc.stdout.read()
                while select.select([master], [], [], 0)[0]:
                    captured += os.read(master, 4096)
                assert proc.returncode == expected, (captured, out, proc.returncode)
                assert termios.tcgetattr(slave) == original, 'terminal settings not restored'
                assert b'PTY_TEST_SECRET' not in captured + out
            finally:
                if proc.poll() is None:
                    proc.kill(); proc.wait()
                os.close(master); os.close(slave)
        terminal_set('prompt', b'PTY_TEST_SECRET\n', 0)
        assert run('alias', 'info', 'prompt')['data']['credentials_configured']
        before = config.read_bytes()
        terminal_set('cancelled', b'\x03', 130)
        assert config.read_bytes() == before
print('Alias integration checks passed: isolated TOML, secrets, import/export, conflicts, paths, permissions, locks.')
