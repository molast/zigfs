# Docker Hub 镜像部署

仓库根目录的 `docker-compose.yml` 用于运行已发布的镜像，不包含源码构建步骤：

- `molast/zigfs:latest`
- `molast/zigfs-admin:latest`

支持 Linux AMD64 和 ARM64。`latest` 包括 alpha、beta、rc 发布，并不代表稳定版；固定版本可设置 `ZIGFS_IMAGE` 和 `ZIGFS_ADMIN_IMAGE`，建议两个镜像使用同一版本。

## 配置与启动

首次部署时，在仓库根目录复制模板；已有 `.env` 时直接编辑，不要覆盖现有配置：

```bash
cp .env.example .env
```

编辑 `.env`，设置 `ZIGFS_ROOT_USER`、`ZIGFS_ROOT_PASSWORD` 和至少 32 字节的 `ZIGFS_ADMIN_SESSION_SECRET`，替换模板中的开发凭证。`ZIGFS_S3_PUBLIC_ENDPOINT` 应填写浏览器实际可访问的 S3 地址，例如 `https://s3.example.com` 或 `http://服务器IP:9000`。

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
docker compose -f docker-compose.yml ps
```

控制台默认端口为 `9001`，S3 为 `9000`，Metrics 为 `9090`。主机端口可通过 `ZIGFS_ADMIN_PORT`、`ZIGFS_API_PORT`、`ZIGFS_METRICS_PORT` 修改；更改 S3 主机端口时同步调整公开地址。

容器内部路径、监听端口及 Admin 上游地址按容器网络固定设置。Admin 通过 `http://zigfs:9000` 连接 ZigFS，不使用本机开发环境的 `ZIGFS_ENDPOINT`。完整变量说明见 [配置文档](../configuration.md)。

## 数据与配置

正式部署使用 Compose 项目 `zigfs`，对象数据保存到命名卷 `zigfs-data`（默认 Docker 卷名 `zigfs_zigfs-data`）。开发配置使用项目 `zigfs-dev` 和独立的数据卷，两者不会自动共享已有数据。切换已有部署时，先备份并明确挂载原数据卷，不要将新建空卷误认为数据丢失。

Admin 的 `ZIGFS_ADMIN_CONFIG` 位于 `/app/config/listener.json`，重启容器后保留，重建容器时不保留。本配置推荐由 Compose 管理 Admin 监听和上游地址；如果通过控制台修改它们并需要持久化，应独立挂载配置目录，保证 UID/GID `10001:10001` 可写。

## 更新

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
```

更新镜像或修改环境变量后需重建对应容器；`restart` 不会加载新的镜像或环境变量。保留数据卷，不要执行 `down -v`。

`docker-compose.dev.yml` 保留用于本地开发调试；Docker Hub 镜像部署使用本文的 `docker-compose.yml`。
