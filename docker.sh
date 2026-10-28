#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
FS_DIR="${ROOT_DIR}/zigfs"
ADMIN_WEB_DIR="${ROOT_DIR}/zigfs-admin/web"
COMPOSE_FILE="${ROOT_DIR}/docker-compose.dev.yml"
LOCAL_IMAGE_TAG="${ZIGFS_DOCKER_TAG:-0.1.0}"
DOCKERHUB_TAG="${DOCKERHUB_TAG:-${LOCAL_IMAGE_TAG}}"
DOCKERHUB_NAMESPACE="${DOCKERHUB_NAMESPACE:-}"

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
  [[ -f "${COMPOSE_FILE}" ]] || fail "未找到 Compose 文件: ${COMPOSE_FILE}"
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
  docker compose -f "${COMPOSE_FILE}" "$@"
}

start_compose_service() {
  local service="$1"

  require_compose
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

resolve_dockerhub_namespace() {
  if [[ -z "${DOCKERHUB_NAMESPACE}" ]]; then
    read -r -p '请输入 Docker Hub 用户名或组织名: ' DOCKERHUB_NAMESPACE
  fi
  [[ "${DOCKERHUB_NAMESPACE}" =~ ^[a-z0-9][a-z0-9._-]*$ ]] || \
    fail "Docker Hub 用户名或组织名无效: ${DOCKERHUB_NAMESPACE}"
}

push_image() {
  local local_repository="$1"
  local hub_repository="$2"
  local local_image="${local_repository}:${LOCAL_IMAGE_TAG}"
  local remote_image
  local latest_image

  resolve_dockerhub_namespace
  remote_image="${DOCKERHUB_NAMESPACE}/${hub_repository}:${DOCKERHUB_TAG}"
  latest_image="${DOCKERHUB_NAMESPACE}/${hub_repository}:latest"
  docker image inspect "${local_image}" >/dev/null 2>&1 || \
    fail "本地镜像 ${local_image} 不存在，请先构建该镜像。"

  printf '正在标记 %s 为 %s...\n' "${local_image}" "${remote_image}"
  docker tag "${local_image}" "${remote_image}"
  printf '正在推送 %s...\n' "${remote_image}"
  docker push "${remote_image}"
  printf '镜像已推送: %s\n' "${remote_image}"

  # 发布版本时同步更新 latest，避免 Docker Hub 的 latest 仍指向旧镜像。
  # DOCKERHUB_TAG=latest 时上面已经完成推送，不需要重复推送。
  if [[ "${DOCKERHUB_TAG}" != "latest" ]]; then
    printf '正在标记 %s 为 %s...\n' "${local_image}" "${latest_image}"
    docker tag "${local_image}" "${latest_image}"
    printf '正在推送 %s...\n' "${latest_image}"
    docker push "${latest_image}"
    printf '镜像已推送: %s\n' "${latest_image}"
  fi
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
      '  4) 启动 ZigFS' \
      '  5) 启动 Admin（自动带起 FS）' \
      '  6) 停止开发服务' \
      '  7) 登录 Docker Hub' \
      '  8) 推送 ZigFS 镜像' \
      '  9) 推送 Admin 镜像' \
      ' 10) 推送全部镜像' \
      '  0) 退出'
    read -r -p '请输入选项 [0-10]: ' choice

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
      4 | start-fs)
        start_compose_service zigfs
        ;;
      5 | start-admin)
        start_compose_service admin
        ;;
      6 | stop | down)
        stop_compose_services
        ;;
      7 | login)
        docker login
        ;;
      8 | push-fs)
        push_image zigfs zigfs
        ;;
      9 | push-admin)
        push_image zigfs-admin zigfs-admin
        ;;
      10 | push-all)
        push_image zigfs zigfs
        push_image zigfs-admin zigfs-admin
        ;;
      0 | q | Q)
        exit 0
        ;;
      *)
        printf '无效的 Docker 操作选项: %s\n' "${choice}" >&2
        ;;
    esac
  done
}

docker_menu
