"""Compare actual CLI dry-run planning against the Admin policy's shared cases."""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'zig-out/bin/zc').resolve()
cases = json.loads((Path(__file__).resolve().parents[2] / 'docs/validation/upload-policy-cases.json').read_text())
with tempfile.TemporaryDirectory(prefix='zc-policy-') as directory:
    root = Path(directory)
    env = {k: v for k, v in os.environ.items() if not k.startswith('ZC_')}
    env['XDG_CONFIG_HOME'] = str(root / 'config')
    def run(args):
        result = subprocess.run([str(binary), '--json', *map(str, args)], env=env, capture_output=True, timeout=20)
        assert result.returncode == 0, result.stderr.decode()
        return json.loads(result.stdout)
    run(['alias', 'set', 'test', 'http://127.0.0.1:1', 'test', 'test-secret', '--skip-check'])
    source = root / 'sparse.bin'
    for case in cases:
        with source.open('wb') as output:
            output.truncate(case['size'])
        result = run(['put', source, 'test/bucket/key', '--dry-run'])
        data = result['data']
        if case['multipart']:
            assert data['part_size'] == case['part_size'], (case, data)
        else:
            assert 'part_size' not in data, (case, data)
print(f'CLI upload policy: {len(cases)} shared boundary cases passed')
