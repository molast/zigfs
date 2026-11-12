#!/usr/bin/env bash

set -Eeuo pipefail

DOCS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
MODE="${1:-}"

fail() {
  printf '错误: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "未找到命令 '$1'，请先安装后重试。"
}

ensure_dependencies() {
  if [[ ! -x "${DOCS_DIR}/node_modules/.bin/fumapress" ]]; then
    printf '文档依赖尚未安装，正在执行 pnpm install...\n'
    (cd "${DOCS_DIR}" && pnpm install --frozen-lockfile)
  fi
}

usage() {
  cat <<'HELP'
用法: ./start.sh [dev|start|build|check]

不带参数时显示交互式菜单。

命令:
  dev    启动开发服务器
  start  启动生产服务，需要先执行 build
  build  执行 TypeScript 检查、文档检查和生产构建
  check  只执行文档结构检查和 TypeScript 检查

环境变量:
  ZIGFS_DOCS_HOST  开发/生产服务监听地址，默认 127.0.0.1
  ZIGFS_DOCS_PORT  开发/生产服务端口，默认 3000
HELP
}

select_mode() {
  printf '%s\n' \
    '请选择操作:' \
    '  1) 启动开发服务' \
    '  2) 启动生产服务' \
    '  3) 检查并构建文档' \
    '  4) 检查文档' \
    '  0) 退出'
  read -r -p '请输入选项 [0-4]: ' MODE
  case "${MODE}" in
    1) MODE=dev ;;
    2) MODE=start ;;
    3) MODE=build ;;
    4) MODE=check ;;
    0) exit 0 ;;
    *) fail "无效选项: ${MODE}" ;;
  esac
}

require_command node
require_command pnpm

if [[ -z "${MODE}" ]]; then
  select_mode
fi

case "${MODE}" in
  -h|--help|help)
    usage
    ;;
  dev)
    ensure_dependencies
    exec pnpm --dir "${DOCS_DIR}" run dev -- \
      --host "${ZIGFS_DOCS_HOST:-127.0.0.1}" \
      --port "${ZIGFS_DOCS_PORT:-3000}" \
      "${@:2}"
    ;;
  start)
    ensure_dependencies
    exec pnpm --dir "${DOCS_DIR}" run start -- \
      --host "${ZIGFS_DOCS_HOST:-127.0.0.1}" \
      --port "${ZIGFS_DOCS_PORT:-3000}" \
      "${@:2}"
    ;;
  build)
    ensure_dependencies
    (cd "${DOCS_DIR}" && pnpm run types:check && pnpm run check && pnpm run build)
    ;;
  check)
    ensure_dependencies
    (cd "${DOCS_DIR}" && pnpm run types:check && pnpm run check)
    ;;
  *)
    usage
    fail "未知命令: ${MODE}"
    ;;
esac
