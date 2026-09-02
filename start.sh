#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FS_DIR="${ROOT_DIR}/zigfs"
ADMIN_SERVER_DIR="${ROOT_DIR}/zigfs-admin/server"
ADMIN_WEB_DIR="${ROOT_DIR}/zigfs-admin/web"

fail() {
  printf '错误: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "未找到命令 '$1'，请先安装后重试。"
}

start_fs() {
  require_command zig

  printf '正在启动 ZigFS...\n'
  cd "${FS_DIR}"
  exec zig build run
}

start_admin() {
  local endpoint="${ZIGFS_ENDPOINT:-http://127.0.0.1:9001}"
  endpoint="${endpoint%/}"

  require_command curl
  if ! curl --fail --silent --show-error --max-time 2 \
    "${endpoint}/health/ready" >/dev/null; then
    fail "ZigFS 尚未就绪，请先在另一个终端运行本脚本并选择启动 FS（检查地址: ${endpoint}/health/ready）。"
  fi

  require_command go

  if [[ -d "${ADMIN_WEB_DIR}/node_modules" ]]; then
    require_command npm
    printf '正在构建 Admin Web...\n'
    (cd "${ADMIN_WEB_DIR}" && npm run build)
  elif [[ ! -f "${ADMIN_WEB_DIR}/dist/index.html" ]]; then
    fail "Admin Web 依赖尚未安装，请先在 zigfs-admin/web 目录执行 npm install。"
  fi

  if [[ -z "${ZIGFS_WEB_ADMIN_TOKEN:-}" ]]; then
    if [[ ! -t 0 ]]; then
      fail "请通过 ZIGFS_WEB_ADMIN_TOKEN 环境变量设置网页管理凭证。"
    fi

    read -r -s -p '请输入 Admin 网页管理凭证: ' ZIGFS_WEB_ADMIN_TOKEN
    printf '\n'
    [[ -n "${ZIGFS_WEB_ADMIN_TOKEN}" ]] || fail "Admin 网页管理凭证不能为空。"
    export ZIGFS_WEB_ADMIN_TOKEN
  fi

  export ZIGFS_ENDPOINT="${endpoint}"
  export ZIGFS_WEB_ROOT="${ADMIN_WEB_DIR}/dist"

  printf '正在启动 ZigFS Admin...\n'
  cd "${ADMIN_SERVER_DIR}"
  exec go run ./cmd/admin
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
