# ZigFS

轻量级、单机、S3 兼容对象存储，使用 Zig 构建。

ZigFS 为自托管应用提供对象存储、S3 API 和独立管理 API，可搭配 ZigFS Admin 网页控制台使用。对象数据和元数据由 ZigFS 管理，不依赖 SQLite 或外部数据库。当前发布包含 alpha 预览版本。

## 镜像

| 镜像 | 用途 |
| --- | --- |
| [`molast/zigfs`](https://hub.docker.com/r/molast/zigfs) | 对象存储服务，提供 S3、Management 和 Health API |
| [`molast/zigfs-admin`](https://hub.docker.com/r/molast/zigfs-admin) | 可选网页控制台，包含 Web 页面和 Go BFF，需连接 ZigFS 服务 |

两个镜像均支持 **Linux AMD64（x86_64）** 和 **Linux ARM64（aarch64）**。Docker 会自动选择适合主机架构的镜像。

## 主要功能

- Bucket 和对象管理、对象复制、Range 下载、条件请求及预签名 URL。
- Multipart 分片上传、失败重试和未完成上传管理。
- 对象版本管理、DeleteMarker 和生命周期规则。
- 用户、策略、访问密钥及基于 AWS Signature V4 的 S3 请求认证。
- SSE-S3、SSE-KMS 加密和 KMS 密钥管理。
- 系统日志、审计日志、健康检查和 Prometheus 指标。
- 自有元数据引擎、事务日志和崩溃恢复。

具体 S3 支持范围见 [兼容性说明](https://github.com/molast/zigfs/blob/main/docs/api/s3-compatibility.md)。

## 快速开始

需要 Docker Engine 和 Docker Compose v2，无需本地安装 Zig、Go 或 Node.js。

### 1. 创建 `.env`

在部署目录中创建 `.env`，替换示例密码和会话密钥：

```dotenv
ZIGFS_IMAGE_TAG=0.1.0-alpha.3
ZIGFS_ROOT_USER=admin
ZIGFS_ROOT_PASSWORD=replace-with-your-console-password
ZIGFS_ADMIN_SESSION_SECRET=replace-with-a-random-secret-at-least-32-bytes
ZIGFS_S3_PUBLIC_ENDPOINT=http://localhost:9000
ZIGFS_S3_REGION=us-east-1
```

`ZIGFS_S3_PUBLIC_ENDPOINT` 必须是浏览器和 S3 客户端实际可访问的服务地址。远程部署时，将 `localhost` 替换为服务器 IP 或域名；使用 HTTPS 反向代理时填写对应 HTTPS 地址。

### 2. 创建 `compose.yaml`

将以下文件放在 `.env` 同一目录：

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

### 3. 启动

```bash
docker compose pull
docker compose up -d
docker compose ps
```

- **网页控制台**：`http://localhost:9001`，使用 `.env` 中的 `ZIGFS_ROOT_USER` 和 `ZIGFS_ROOT_PASSWORD` 登录。
- **S3 Endpoint**：`http://localhost:9000`。
- **就绪检查**：`http://localhost:9000/health/ready`。

远程部署请使用服务器实际地址访问。只需要 S3 服务时，可以省略 `zigfs-admin` 服务。

## 连接 S3 客户端

在控制台创建访问密钥，将 Access Key、Secret Key、Endpoint 和 Region 填入支持 S3 的客户端。默认使用 **Path-style** 寻址和 **AWS Signature V4** 签名。

也可以在 `.env` 中配置 `ZIGFS_ACCESS_KEY` 和 `ZIGFS_SECRET_KEY`，启用部署 root 的 S3 凭证。两者必须成对设置：AK 为 16–128 个英文字母或数字，SK 为 32–64 个不含空格的可打印 ASCII 字符。S3 凭证与控制台用户名、密码相互独立。

## 常用配置

| 变量 | 作用 |
| --- | --- |
| `ZIGFS_ROOT_USER` / `ZIGFS_ROOT_PASSWORD` | 控制台部署 root 用户名和密码 |
| `ZIGFS_ACCESS_KEY` / `ZIGFS_SECRET_KEY` | 可选的部署 root S3 访问密钥 |
| `ZIGFS_ADMIN_SESSION_SECRET` | 管理会话签名密钥，至少 32 字节 |
| `ZIGFS_DATA_ROOT` | 数据根目录，本示例为 `/var/lib/zigfs` |
| `ZIGFS_API_ADDRESS` | S3 和管理 API 的监听地址，本示例为 `0.0.0.0:9000` |
| `ZIGFS_S3_PUBLIC_ENDPOINT` | 客户端可访问的 S3 地址，用于生成预签名 URL |
| `ZIGFS_S3_REGION` | S3 签名区域，默认为 `us-east-1` |
| `ZIGFS_ENDPOINT` | Admin 连接 ZigFS 的内部地址，本示例为 `http://zigfs:9000` |

Compose 通过 `environment` 将 `.env` 中的配置传入容器。增加其他配置时，需同时补充对应服务的 `environment` 映射。修改启动变量后执行 `docker compose up -d` 重建受影响的容器；单纯执行 `docker compose restart` 不会载入新的环境变量。

部分控制台设置会持久化保存，并优先于对应的启动变量。完整规则见 [配置文档](https://github.com/molast/zigfs/blob/main/docs/configuration.md)。

## 数据持久化

`zigfs-data` 卷保存对象、元数据及 ZigFS 持久化配置。更新或重建容器时保留此卷。`docker compose down -v` 会删除该卷及其中的数据。

如改用宿主机目录挂载，目录需允许容器用户 **UID/GID `10001:10001`** 读写。备份应覆盖完整数据根目录，具体步骤见 [备份与恢复](https://github.com/molast/zigfs/blob/main/docs/backup-and-recovery.md)。

Admin 不需要挂载 ZigFS 数据卷。本示例由 Compose 固定 Admin 监听地址和上游地址；如需保留在控制台修改的 Admin 监听设置，请额外挂载可写的独立配置目录，并设置 `ZIGFS_ADMIN_CONFIG`，参见 [网络配置](https://github.com/molast/zigfs/blob/main/docs/network-settings.md)。

## 版本与更新

- `0.1.0-alpha.3`、`v0.1.0-alpha.3` 等标签对应指定版本。
- `latest` 随每次版本发布更新，**也包括 alpha、beta 和 rc 版本**，不代表稳定版。
- 建议将两个镜像固定到同一个版本；需要跟随最新发布时，将 `.env` 中的 `ZIGFS_IMAGE_TAG` 改为 `latest`。

更新 `.env` 中的版本后执行：

```bash
docker compose pull
docker compose up -d
```

已经运行的容器不会因 Docker Hub 的 `latest` 更新而自动升级。

## 项目链接

- [GitHub 源码](https://github.com/molast/zigfs)
- [发布版本](https://github.com/molast/zigfs/tags)
- [文档索引](https://github.com/molast/zigfs/blob/main/docs/README.md)
- [问题反馈](https://github.com/molast/zigfs/issues)
- [Apache License 2.0](https://github.com/molast/zigfs/blob/main/LICENSE)
