"""Offline subprocess checks: python3 tests/cli_smoke.py [path/to/zc]."""
import json
from pathlib import Path
import subprocess
import sys

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/zc").resolve()


def run(args, code=0, json_stream=None):
    result = subprocess.run([str(binary), *args], capture_output=True, text=True, timeout=5)
    assert result.returncode == code, (args, result.returncode, result.stderr)
    assert "stack trace" not in result.stderr and "cli.zig:" not in result.stderr, result.stderr
    if code:
        assert result.stdout == "", (args, result.stdout)
    else:
        assert result.stderr == "", (args, result.stderr)
    if json_stream:
        value = json.loads(getattr(result, json_stream))
        assert value["schema_version"] == 1
        assert value["status"] == ("success" if code == 0 else "error")
    return result


for args in ([], ["help"], ["--help"], ["-h"], ["bucket"], ["object", "--help"],
             ["help", "object", "move"], ["mv", "--help"]):
    assert "Usage:" in run(args).stdout
assert run(["--version"]).stdout == "zc 0.1.0\n"
assert run(["-V"]).stdout == "zc 0.1.0\n"
for args in (["--json", "--version"], ["--version", "--json"],
             ["--quiet", "--json", "--version"], ["object", "--json", "move", "--help"],
             ["--format=json", "help"]):
    run(args, json_stream="stdout")
assert run(["--quiet", "--version"]).stdout == ""
run(["--no-color", "--no-progress", "--debug", "--help"])
for args in (["--format"], ["--format="], ["--format", "xml"], ["--bad"],
             ["help", "mv", "extra"], ["bucket", "typo"], ["--help", "--bad"],
             ["--", "--version"], ["bucket", "--version"]):
    run(args, 2)
for args in (["--json", "--format=human"], ["--bad", "--json"],
             ["--json", "--format"], ["--format=human", "--json"]):
    run(args, 2, "stderr")
for args in (["version"], ["bucket", "version"], ["version", "source", "target"],
             ["version", "--", "--json"]):
    run(args, 7)
run(["version", "--json"], 7, "stderr")
secret = run(["--json", "--secret=DO_NOT_ECHO"], 2, "stderr")
assert "DO_NOT_ECHO" not in secret.stderr
assert run(["mv", "--help"]).stdout == run(["object", "move", "--help"]).stdout
print("CLI subprocess checks passed (help, aliases, formats, streams, exit codes, redaction).")
