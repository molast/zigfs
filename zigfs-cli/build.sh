#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${ZC_INSTALL_DIR:-/opt/homebrew/bin}"

if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
  printf '错误: 安装目录不存在或不可写: %s。请通过 ZC_INSTALL_DIR 指定可写目录。\n' "$INSTALL_DIR" >&2
  exit 1
fi
# Resolve relative overrides before changing to the project directory.
INSTALL_DIR="$(cd -- "$INSTALL_DIR" && pwd)"
cd "$SCRIPT_DIR"

zig build -Doptimize=ReleaseSafe
install -m 755 zig-out/bin/zc ./zc

printf 'Built: %s/zc\n' "$SCRIPT_DIR"
if [[ "$INSTALL_DIR" != "$SCRIPT_DIR" ]]; then
  install -m 755 zig-out/bin/zc "$INSTALL_DIR/zc"
fi
printf 'Installed: %s/zc\n' "$INSTALL_DIR"

case ":${PATH}:" in
  *":${INSTALL_DIR}:"*) ;;
  *) printf '提示: 将 %s 加入 PATH 后即可直接运行 zc。\n' "$INSTALL_DIR" ;;
esac
