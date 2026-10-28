#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FS_DIR="${ROOT_DIR}/zigfs"
ADMIN_WEB_DIR="${ROOT_DIR}/zigfs-admin/web"

fail() {
  printf '错误: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "未找到命令 '$1'，请先安装后重试。"
}

build_admin_web_assets() {
  if [[ -d "${ADMIN_WEB_DIR}/node_modules" ]]; then
    [[ -x "${ADMIN_WEB_DIR}/node_modules/.bin/tsc" ]] || \
      fail "Admin Web 依赖不完整，请先在 zigfs-admin/web 目录执行 pnpm install。"
    [[ -x "${ADMIN_WEB_DIR}/node_modules/.bin/vite" ]] || \
      fail "Admin Web 依赖不完整，请先在 zigfs-admin/web 目录执行 pnpm install。"
    printf '正在构建 Admin Web...\n'
    # 直接调用本地工具，避免 pnpm 在 macOS Apple Silicon 上加载错误的原生执行器。
    (cd "${ADMIN_WEB_DIR}" && ./node_modules/.bin/tsc -b && ./node_modules/.bin/vite build)
  elif [[ ! -f "${ADMIN_WEB_DIR}/dist/index.html" ]]; then
    fail "Admin Web 依赖尚未安装，请先在 zigfs-admin/web 目录执行 pnpm install。"
  fi
}

start_fs() {
  require_command zig

  printf '正在启动本地 ZigFS...\n'
  cd "${FS_DIR}"
  exec zig build run --watch
}

start_admin() {
  local endpoint="${ZIGFS_ENDPOINT:-http://127.0.0.1:9000}"
  endpoint="${endpoint%/}"

  require_command go
  build_admin_web_assets

  export ZIGFS_ENDPOINT="${endpoint}"
  export ZIGFS_WEB_ROOT="${ADMIN_WEB_DIR}/dist"

  printf '正在启动本地 Admin（不会自动启动 ZigFS）...\n'
  (cd "${ROOT_DIR}/zigfs-admin/server" && go run ./cmd/admin)
}

printf '%s\n' \
  '请选择操作:' \
  '  1) 启动本地 ZigFS' \
  '  2) 启动本地 Admin' \
  '  0) 退出'
read -r -p '请输入选项 [0-2]: ' choice

case "${choice}" in
  1 | fs | FS)
    start_fs
    ;;
  2 | admin | Admin | ADMIN)
    start_admin
    ;;
  0 | q | Q)
    exit 0
    ;;
  *)
    fail "无效选项: ${choice}"
    ;;
esac
