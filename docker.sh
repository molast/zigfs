#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FS_DIR="${ROOT_DIR}/zigfs"
ADMIN_WEB_DIR="${ROOT_DIR}/zigfs-admin/web"
DEV_COMPOSE_FILE="${ROOT_DIR}/docker-compose.dev.yml"
PROD_COMPOSE_FILE="${ROOT_DIR}/docker-compose.yml"
LOCAL_IMAGE_TAG="${ZIGFS_DOCKER_TAG:-0.1.0}"

fail() {
  printf '错误: %s\n' "$1" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "未找到命令 '$1'，请先安装后重试。"
}

require_docker() {
  require_command docker
  docker info >/dev/null 2>&1 || fail "Docker 服务尚未运行，请先启动 Docker Desktop 或其他 Docker daemon。"
}

require_compose() {
  local compose_file="$1"

  require_docker
  docker compose version >/dev/null 2>&1 || fail "未找到 Docker Compose，请确认 Docker Compose 插件已安装。"
  [[ -f "${compose_file}" ]] || fail "未找到 Compose 文件: ${compose_file}"
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

has_local_zig_toolchain() {
  local candidate

  for candidate in \
    "${FS_DIR}/zig/zig-toolchain.tar.xz" \
    "${FS_DIR}/zig/zig-"*-linux-*.tar.xz \
    "${FS_DIR}/zig-toolchain.tar.xz" \
    "${FS_DIR}/zig-"*-linux-*.tar.xz; do
    if [[ -f "${candidate}" ]]; then
      return 0
    fi
  done
  return 1
}

build_fs_image() {
  local -a build_args=()

  printf '正在构建 ZigFS Docker 镜像 zigfs:%s...\n' "${LOCAL_IMAGE_TAG}"
  if has_local_zig_toolchain; then
    printf '检测到本地 Zig Linux 工具链，将使用离线构建。\n'
  else
    printf '未检测到本地 Zig Linux 工具链，将从官方地址下载。可通过 ZIG_DOWNLOAD_BASE_URL 指定镜像地址。\n'
  fi
  if [[ -n "${ZIG_DOWNLOAD_BASE_URL:-}" ]]; then
    build_args+=(--build-arg "ZIG_DOWNLOAD_BASE_URL=${ZIG_DOWNLOAD_BASE_URL}")
  fi
  if [[ -n "${ZIG_TOOLCHAIN_SHA256:-}" ]]; then
    build_args+=(--build-arg "ZIG_TOOLCHAIN_SHA256=${ZIG_TOOLCHAIN_SHA256}")
  fi
  if ((${#build_args[@]} > 0)); then
    docker build "${build_args[@]}" --tag "zigfs:${LOCAL_IMAGE_TAG}" "${FS_DIR}"
  else
    docker build --tag "zigfs:${LOCAL_IMAGE_TAG}" "${FS_DIR}"
  fi
}

build_admin_image() {
  build_admin_web_assets
  printf '正在构建 ZigFS Admin Docker 镜像 zigfs-admin:%s...\n' "${LOCAL_IMAGE_TAG}"
  docker build --tag "zigfs-admin:${LOCAL_IMAGE_TAG}" "${ROOT_DIR}/zigfs-admin"
}


compose() {
  local compose_file="$1"
  shift
  docker compose -f "${compose_file}" "$@"
}

start_compose_environment() {
  local compose_file="$1"
  local environment="$2"

  require_compose "${compose_file}"
  printf '正在通过 %s 启动%s环境（ZigFS + Admin）...\n' "${compose_file##*/}" "${environment}"
  compose "${compose_file}" up -d --no-build
  printf '%s环境已启动。\n' "${environment}"
}

stop_compose_services() {
  local compose_file="$1"
  local environment="$2"

  require_compose "${compose_file}"
  printf '正在停止%s环境...\n' "${environment}"
  compose "${compose_file}" down
  printf '%s环境已停止。\n' "${environment}"
}

docker_menu() {
  local choice

  require_docker
  while true; do
    printf '%s\n' \
      '请选择 Docker 操作:' \
      '  1) 构建 ZigFS 镜像' \
      '  2) 构建 Admin 镜像' \
      '  3) 构建全部镜像' \
      '  4) 启动 dev 环境（docker-compose.dev.yml，ZigFS + Admin）' \
      '  5) 停止 dev 环境' \
      '  6) 启动正式环境（docker-compose.yml，ZigFS + Admin）' \
      '  7) 停止正式环境' \
      '  0) 退出'
    read -r -p '请输入选项 [0-7]: ' choice

    case "${choice}" in
      1 | build-fs)
        build_fs_image
        printf 'ZigFS 镜像构建完成。\n'
        ;;
      2 | build-admin)
        build_admin_image
        printf 'Admin 镜像构建完成。\n'
        ;;
      3 | build-all)
        build_fs_image
        build_admin_image
        printf '全部 Docker 镜像构建完成。\n'
        ;;
      4 | start-admin | start-dev)
        start_compose_environment "${DEV_COMPOSE_FILE}" ' dev '
        ;;
      5 | stop | down | stop-dev)
        stop_compose_services "${DEV_COMPOSE_FILE}" ' dev '
        ;;
      6 | start-prod)
        start_compose_environment "${PROD_COMPOSE_FILE}" '正式'
        ;;
      7 | stop-prod)
        stop_compose_services "${PROD_COMPOSE_FILE}" '正式'
        ;;
      0 | q | Q)
        exit 0
        ;;
      *)
        printf '无效的 Docker 操作选项: %s\n' "${choice}" >&2
        continue
        ;;
    esac
    return 0
  done
}

docker_menu
