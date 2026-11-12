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
  local build_mode="${1:-${ZIGFS_BUILD_MODE:-ReleaseSafe}}"
  case "${build_mode}" in
    Debug | ReleaseSafe | ReleaseFast | ReleaseSmall) ;;
    *) fail "无效的 ZIGFS_BUILD_MODE: ${build_mode}" ;;
  esac

  printf '正在启动本地 ZigFS（%s）...\n' "${build_mode}"
  cd "${FS_DIR}"
  local env_args=()
  if [[ -f "${ROOT_DIR}/.env" ]]; then env_args=(--env-file "${ROOT_DIR}/.env"); fi
  exec zig build run --watch "-Doptimize=${build_mode}" -- "${env_args[@]}"
}

start_admin() {

  require_command go
  build_admin_web_assets

  if [[ -f "${ROOT_DIR}/.env" ]]; then export ZIGFS_ENV_FILE="${ROOT_DIR}/.env"; fi

  printf '正在启动本地 Admin（不会自动启动 ZigFS）...\n'
  (cd "${ROOT_DIR}/zigfs-admin/server" && go run ./cmd/admin)
}

printf '%s\n' \
  '请选择操作:' \
  '  1) 启动本地 ZigFS (Debug)' \
  '  2) 启动本地 ZigFS (Release)' \
  '  3) 启动本地 Admin' \
  '  0) 退出'
read -r -p '请输入选项 [0-3]: ' choice

case "${choice}" in
  1 | debug | Debug | DEBUG)
    start_fs Debug
    ;;
  2 | release | Release | RELEASE)
    start_fs ReleaseSafe
    ;;
  fs | FS)
    start_fs
    ;;
  3 | admin | Admin | ADMIN)
    start_admin
    ;;
  0 | q | Q)
    exit 0
    ;;
  *)
    fail "无效选项: ${choice}"
    ;;
esac
