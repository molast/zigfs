#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FS_DIR="${ROOT_DIR}/zigfs"
ADMIN_WEB_DIR="${ROOT_DIR}/zigfs-admin/web"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.dev.yml"
DOCKER_IMAGE_TAG="${ZIGFS_DOCKER_TAG:-0.1.0}"

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
  require_docker
  docker compose version >/dev/null 2>&1 || fail "未找到 Docker Compose，请确认 Docker Compose 插件已安装。"
}

build_admin_web_assets() {
  if [[ -d "${ADMIN_WEB_DIR}/node_modules" ]]; then
    require_command pnpm
    printf '正在构建 Admin Web...\n'
    (cd "${ADMIN_WEB_DIR}" && pnpm run build)
  elif [[ ! -f "${ADMIN_WEB_DIR}/dist/index.html" ]]; then
    fail "Admin Web 依赖尚未安装，请先在 zigfs-admin/web 目录执行 pnpm install。"
  fi
}

start_fs() {
  require_command zig

  printf '正在启动本地 ZigFS...\n'
  cd "${FS_DIR}"
  exec zig build run
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

  printf '正在构建 ZigFS Docker 镜像 zigfs:%s...\n' "${DOCKER_IMAGE_TAG}"
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
  if [[ ${#build_args[@]} -gt 0 ]]; then
    docker build "${build_args[@]}" --tag "zigfs:${DOCKER_IMAGE_TAG}" "${FS_DIR}"
  else
    docker build --tag "zigfs:${DOCKER_IMAGE_TAG}" "${FS_DIR}"
  fi
}

build_admin_image() {
  build_admin_web_assets
  printf '正在构建 ZigFS Admin Docker 镜像 zigfs-admin:%s...\n' "${DOCKER_IMAGE_TAG}"
  docker build --tag "zigfs-admin:${DOCKER_IMAGE_TAG}" "${ROOT_DIR}/zigfs-admin"
}

compose() {
  docker compose -f "${COMPOSE_FILE}" "$@"
}

start_compose_service() {
  local service="$1"

  require_compose
  if [[ ! -f "${COMPOSE_FILE}" ]]; then
    fail "未找到 Compose 文件: ${COMPOSE_FILE}"
  fi

  case "${service}" in
    zigfs)
      printf '正在通过 Compose 启动 ZigFS...\n'
      compose up -d --no-build zigfs
      printf 'ZigFS 已启动。\n'
      ;;
    admin)
      printf '正在通过 Compose 启动 Admin（自动带起 ZigFS）...\n'
      compose up -d --no-build admin
      printf 'Admin 已启动。\n'
      ;;
    *)
      fail "无效的 Compose 服务: ${service}"
      ;;
  esac
}

stop_compose_services() {
  require_compose
  printf '正在停止开发服务...\n'
  compose down
  printf '开发服务已停止。\n'
}

docker_menu() {
  local docker_choice

  require_docker
  while true; do
    printf '%s\n' \
      '请选择 Docker 操作:' \
      '  1) 构建 ZigFS 镜像' \
      '  2) 构建 Admin 镜像' \
      '  3) 构建全部镜像' \
      '  4) 启动 ZigFS' \
      '  5) 启动 Admin（自动带起 FS）' \
      '  6) 停止开发服务' \
      '  0) 返回上一级'
    read -r -p '请输入选项 [0-6]: ' docker_choice

    case "${docker_choice}" in
      1 | fs | FS)
        build_fs_image
        printf 'Docker 镜像构建完成。\n'
        ;;
      2 | admin | Admin | ADMIN)
        build_admin_image
        printf 'Docker 镜像构建完成。\n'
        ;;
      3 | all | All | ALL)
        build_fs_image
        build_admin_image
        printf 'Docker 镜像构建完成。\n'
        ;;
      4 | start-fs)
        start_compose_service zigfs
        ;;
      5 | start-admin)
        start_compose_service admin
        ;;
      6 | stop | down)
        stop_compose_services
        ;;
      0 | q | Q)
        return 0
        ;;
      *)
        fail "无效的 Docker 操作选项: ${docker_choice}"
        ;;
    esac
  done
}

printf '%s\n' \
  '请选择操作:' \
  '  1) 启动本地 ZigFS' \
  '  2) 启动本地 Admin' \
  '  3) Docker 服务' \
  '  0) 退出'
read -r -p '请输入选项 [0-3]: ' choice

case "${choice}" in
  1 | fs | FS)
    start_fs
    ;;
  2 | admin | Admin | ADMIN)
    start_admin
    ;;
  3 | docker | Docker | DOCKER)
    docker_menu
    ;;
  0 | q | Q)
    exit 0
    ;;
  *)
    fail "无效选项: ${choice}"
    ;;
esac
