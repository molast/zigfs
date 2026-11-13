# ZigFS Admin

ZigFS 的网页管理控制台，包含 React Web 界面和 Go BFF 服务。

本镜像需连接 [ZigFS 对象存储服务](https://hub.docker.com/r/molast/zigfs)。用户认证、权限校验、对象数据和元数据由 ZigFS 管理；Admin 提供网页界面及管理 API 转发，不需要挂载 ZigFS 数据目录。

## 支持的平台

- `linux/amd64`：x86_64
- `linux/arm64`：ARM64 / aarch64

Docker 拉取镜像时会自动选择对应架构。当前发布包含 alpha 预览版本。

## 主要功能

- Bucket、对象、目录和对象版本管理。
- 文件上传、下载、分片上传任务管理及预签名链接。
- 用户、策略和 Access Key / Secret Key 管理。
- Bucket 加密设置、KMS 配置及密钥管理。
- 系统日志、审计日志和存储状态查看。
- 常规设置、网络设置及个人账户信息。
- 中文和英文界面。

可见菜单和可执行操作由登录身份的策略权限决定。

## 使用 Docker Compose 部署

需要 Docker Engine 和 Docker Compose v2，无需另外安装 Go 或 Node.js。以下示例同时启动 ZigFS 和 ZigFS Admin。

### 1. 创建 `.env`

替换示例中的控制台密码和会话签名密钥：

```dotenv
ZIGFS_IMAGE_TAG=0.1.0-alpha.3
ZIGFS_ROOT_USER=admin
ZIGFS_ROOT_PASSWORD=replace-with-your-console-password
ZIGFS_ADMIN_SESSION_SECRET=replace-with-a-random-secret-at-least-32-bytes
ZIGFS_S3_PUBLIC_ENDPOINT=http://localhost:9000
ZIGFS_S3_REGION=us-east-1
```

远程部署时，将 `ZIGFS_S3_PUBLIC_ENDPOINT` 改为浏览器实际能够访问的服务器 IP 或域名。该地址用于上传、下载和预签名链接，不能使用只有容器内部才能解析的 `http://zigfs:9000`。

### 2. 创建 `compose.yaml`

将文件放在 `.env` 同一目录：

```yaml
services:
  zigfs:
    image: molast/zigfs:${ZIGFS_IMAGE_TAG:-latest}
    restart: unless-stopped
    ports:
      - "9000:9000"
    environment:
      ZIGFS_API_ADDRESS: "0.0.0.0:9000"
      ZIGFS_DATA_ROOT: /var/lib/zigfs
      ZIGFS_ROOT_USER: ${ZIGFS_ROOT_USER:?Set ZIGFS_ROOT_USER in .env}
      ZIGFS_ROOT_PASSWORD: ${ZIGFS_ROOT_PASSWORD:?Set ZIGFS_ROOT_PASSWORD in .env}
      ZIGFS_ADMIN_SESSION_SECRET: ${ZIGFS_ADMIN_SESSION_SECRET:?Set ZIGFS_ADMIN_SESSION_SECRET in .env}
      ZIGFS_S3_PUBLIC_ENDPOINT: ${ZIGFS_S3_PUBLIC_ENDPOINT:-http://localhost:9000}
      ZIGFS_S3_REGION: ${ZIGFS_S3_REGION:-us-east-1}
      ZIGFS_ACCESS_KEY: ${ZIGFS_ACCESS_KEY:-}
      ZIGFS_SECRET_KEY: ${ZIGFS_SECRET_KEY:-}
    volumes:
      - zigfs-data:/var/lib/zigfs
    healthcheck:
      test: ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9000/health/ready"]
      interval: 5s
      timeout: 3s
      retries: 20
      start_period: 10s

  zigfs-admin:
    image: molast/zigfs-admin:${ZIGFS_IMAGE_TAG:-latest}
    restart: unless-stopped
    depends_on:
      zigfs:
        condition: service_healthy
    ports:
      - "9001:9001"
    environment:
      ZIGFS_ADMIN_LISTEN: ":9001"
      ZIGFS_ENDPOINT: http://zigfs:9000
      ZIGFS_WEB_ROOT: /app/web
      ZIGFS_UPSTREAM_TIMEOUT: 15m

volumes:
  zigfs-data:
```

### 3. 启动并登录

```bash
docker compose pull
docker compose up -d
docker compose ps
```

访问 **http://localhost:9001**，使用 `.env` 中的 `ZIGFS_ROOT_USER` 和 `ZIGFS_ROOT_PASSWORD` 登录。远程部署时将 `localhost` 替换为服务器地址。

登录凭证配置在 **ZigFS 服务**上，无需向 Admin 容器传入 Root 密码或 S3 AK/SK。其他用户由管理员在控制台创建并授权。

## 连接已有 ZigFS 服务

如果 ZigFS 已经部署，可以只运行 Admin。以下地址为示例，请替换为 Admin 容器可访问的 ZigFS 地址：

```bash
docker run -d \
  --name zigfs-admin \
  --restart unless-stopped \
  -p 9001:9001 \
  -e ZIGFS_ENDPOINT=http://192.168.1.10:9000 \
  molast/zigfs-admin:0.1.0-alpha.3
```

如果 ZigFS 位于同一个 Docker 自定义网络中，可为 Admin 添加 `--network <网络名>`，并将 `ZIGFS_ENDPOINT` 设置为 `http://<ZigFS容器名>:9000`。容器中的 `localhost` 指向容器自身。

网页能正常打开并不代表 ZigFS 已连接成功：Admin 必须能够访问上游管理 API，浏览器也必须能够访问 ZigFS 的 S3 公开地址。HTTPS 部署时，两者的公开访问地址应与反向代理配置一致，避免浏览器阻止混合内容请求。

## 环境变量

| 变量 | 镜像默认值 | 说明 |
| --- | --- | --- |
| `ZIGFS_ADMIN_LISTEN` | `:9001` | Admin HTTP 监听地址 |
| `ZIGFS_ENDPOINT` | `http://zigfs:9000` | Admin 容器访问 ZigFS 的内部地址 |
| `ZIGFS_WEB_ROOT` | `/app/web` | 内置 Web 静态文件目录，通常无需修改 |
| `ZIGFS_UPSTREAM_TIMEOUT` | `15m` | 上游请求超时，支持 `30s`、`15m` 等 Go duration 格式 |
| `ZIGFS_ADMIN_CONFIG` | 系统用户配置目录下的 `zigfs-admin/listener.json` | Admin 监听地址和上游地址的持久化配置文件路径 |

Compose 示例通过 `environment` 注入变量。修改后执行 `docker compose up -d` 重建受影响的容器；`docker compose restart` 不会更新容器环境变量。

## 持久化与数据

Bucket、对象、用户、策略和密钥由 ZigFS 持久化保存。Admin 不需要也不应共享 ZigFS 数据卷。

上面的示例通过 Compose 管理 Admin 的监听地址和上游地址。如需保留在控制台 Network 页面保存的 Admin 监听配置，应为 Admin 单独挂载配置目录，并将 `ZIGFS_ADMIN_CONFIG` 设置为该目录中的文件路径，例如 `/app/config/listener.json`。挂载目录必须允许容器用户 **UID/GID `10001:10001`** 读写。

已保存的 Admin 监听配置优先于 `ZIGFS_ADMIN_LISTEN` 和 `ZIGFS_ENDPOINT`。具体生效规则见 [网络配置文档](https://github.com/molast/zigfs/blob/main/docs/network-settings.md)。

## 版本与升级

建议 ZigFS 和 ZigFS Admin 使用相同版本，例如 `0.1.0-alpha.3`。

`latest` 随每次版本发布更新，**包括 alpha、beta 和 rc 预发布版本**，不代表稳定版。已运行的容器不会自动升级。

修改 `.env` 中的 `ZIGFS_IMAGE_TAG` 后执行：

```bash
docker compose pull
docker compose up -d
```

保留 ZigFS 数据卷。使用 `docker compose down -v` 会删除 Compose 管理的数据卷。

## 项目链接

- [ZigFS 服务镜像](https://hub.docker.com/r/molast/zigfs)
- [GitHub 源码](https://github.com/molast/zigfs)
- [配置文档](https://github.com/molast/zigfs/blob/main/docs/configuration.md)
- [发布版本](https://github.com/molast/zigfs/tags)
- [问题反馈](https://github.com/molast/zigfs/issues)
- [Apache License 2.0](https://github.com/molast/zigfs/blob/main/LICENSE)
