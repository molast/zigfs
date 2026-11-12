#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

zig build -Doptimize=ReleaseSafe
cp zig-out/bin/zc ./zc
chmod +x ./zc

printf 'Built: %s/zc\n' "$SCRIPT_DIR"
