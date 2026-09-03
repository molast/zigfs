#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FS_DIR="${ROOT_DIR}/zigfs"
ADMIN_SERVER_DIR="${ROOT_DIR}/zigfs-admin/server"
ADMIN_WEB_DIR="${ROOT_DIR}/zigfs-admin/web"
AUTO_STARTED_FS_PID=""

fail() {
  printf '错误: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "未找到命令 '$1'，请先安装后重试。"
}

fs_is_ready() {
  local endpoint="$1"
  curl --fail --silent --show-error --max-time 2 \
    "${endpoint}/health/ready" >/dev/null 2>&1
}

stop_auto_started_fs() {
  local pid="${AUTO_STARTED_FS_PID}"
  [[ -n "${pid}" ]] || return 0
  AUTO_STARTED_FS_PID=""

  if kill -0 "${pid}" >/dev/null 2>&1; then
    printf '\n正在停止由本脚本启动的 ZigFS...\n'
    kill "${pid}" >/dev/null 2>&1 || true
  fi
  wait "${pid}" >/dev/null 2>&1 || true
}

ensure_fs_for_admin() {
  local endpoint="$1"
  local attempt
  local fs_status

  if fs_is_ready "${endpoint}"; then
    printf 'ZigFS 已就绪，复用现有服务。\n'
    return 0
  fi

  require_command zig
  printf 'ZigFS 尚未运行，正在构建并自动启动...\n'
  (cd "${FS_DIR}" && zig build)
  (cd "${FS_DIR}" && exec ./zig-out/bin/zigfs) &
  AUTO_STARTED_FS_PID=$!

  for attempt in {1..60}; do
    if fs_is_ready "${endpoint}"; then
      printf 'ZigFS 已就绪（%s）。\n' "${endpoint}"
      return 0
    fi

    if ! kill -0 "${AUTO_STARTED_FS_PID}" >/dev/null 2>&1; then
      fs_status=0
      wait "${AUTO_STARTED_FS_PID}" || fs_status=$?
      AUTO_STARTED_FS_PID=""
      fail "ZigFS 启动失败（退出码: ${fs_status}），请检查上方日志和配置。"
    fi
    sleep 0.25
  done

  fail "ZigFS 启动后未在规定时间内就绪（检查地址: ${endpoint}/health/ready）。"
}

start_fs() {
  require_command zig

  printf '正在启动 ZigFS...\n'
  cd "${FS_DIR}"
  exec zig build run
}

start_admin() {
  local endpoint="${ZIGFS_ENDPOINT:-http://127.0.0.1:9000}"
  endpoint="${endpoint%/}"

  require_command curl
  require_command go

  if [[ -d "${ADMIN_WEB_DIR}/node_modules" ]]; then
    require_command pnpm
    printf '正在构建 Admin Web...\n'
    (cd "${ADMIN_WEB_DIR}" && pnpm run build)
  elif [[ ! -f "${ADMIN_WEB_DIR}/dist/index.html" ]]; then
    fail "Admin Web 依赖尚未安装，请先在 zigfs-admin/web 目录执行 pnpm install。"
  fi

  export ZIGFS_ENDPOINT="${endpoint}"
  export ZIGFS_WEB_ROOT="${ADMIN_WEB_DIR}/dist"

  trap stop_auto_started_fs EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  ensure_fs_for_admin "${endpoint}"

  printf '正在启动 ZigFS Admin...\n'
  (cd "${ADMIN_SERVER_DIR}" && go run ./cmd/admin)
}

printf '%s\n' \
  '请选择要启动的服务:' \
  '  1) ZigFS' \
  '  2) ZigFS Admin' \
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
