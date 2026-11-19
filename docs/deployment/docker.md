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

也可在仓库根目录运行 `./docker.sh` 使用交互菜单：

- `4`：根据 `docker-compose.dev.yml` 启动完整 dev 环境；`5` 停止 dev 环境。
- `6`：根据 `docker-compose.yml` 启动完整正式环境；`7` 停止正式环境。
- `1`～`3`：构建本地镜像。启动时使用对应 Compose 文件配置的镜像，不自动构建；使用本地构建结果时需配置 `ZIGFS_IMAGE` 和 `ZIGFS_ADMIN_IMAGE` 为对应本地镜像标签。

两个环境默认使用相同的主机端口，切换环境前先停止当前环境，或配置不同端口。停止操作保留数据卷。

控制台默认端口为 `9001`，S3 为 `9000`，Metrics 为 `9090`。主机端口可通过 `ZIGFS_ADMIN_PORT`、`ZIGFS_API_PORT`、`ZIGFS_METRICS_PORT` 修改；更改 S3 主机端口时同步调整公开地址。

容器内部路径、监听端口及 Admin 上游地址按容器网络固定设置。Admin 通过 `http://zigfs:9000` 连接 ZigFS，不使用本机开发环境的 `ZIGFS_ENDPOINT`。完整变量说明见 [配置文档](../configuration.md)。

## 数据与配置

ZigFS 镜像支持直接挂载 NAS 目录，例如 `./data:/var/lib/zigfs`。启动入口以 root
准备数据目录，将其中的普通文件和目录归属调整为 `10001:10001` 并补齐所有者的
读写权限（目录增加遍历权限），随后立即降权，以该普通用户运行 ZigFS。
初始化不跟随符号链接、不遍历嵌套挂载，也不会删除数据或转换存储格式。
请挂载 ZigFS 专用目录；启动时会扫描已有内容，大数据目录可能需要更长的健康检查宽限期。
只读挂载、NAS ACL 或 root squash 限制仍可能阻止初始化，此时容器日志会明确提示。
显式指定 Compose `user:` 时尊重该用户设置，不自动提权或修改归属。
此行为需使用包含新启动入口的镜像，已发布的 `v0.1.0-alpha.7` 不会自动改变。

正式部署使用 Compose 项目 `zigfs`，对象数据保存到命名卷 `zigfs-data`（默认 Docker 卷名 `zigfs_zigfs-data`）。开发配置使用项目 `zigfs-dev` 和独立的数据卷，两者不会自动共享已有数据。切换已有部署时，先备份并明确挂载原数据卷，不要将新建空卷误认为数据丢失。

Admin 的 `ZIGFS_ADMIN_CONFIG` 位于 `/app/config/listener.json`。当前 Compose 使用独立配置卷保存监听设置及网关 CA，重建容器后保留。升级已有容器时先备份原 `/app/config`，新卷不会自动迁移旧可写层。新镜像入口自动准备专用配置目录并降权运行。HTTPS 端口默认映射 8443，网关默认关闭，启用方法见 [内置 HTTPS 网关](../gateway.md)。

## 更新

```bash
docker compose -f docker-compose.yml pull
docker compose -f docker-compose.yml up -d
```

更新镜像或修改环境变量后需重建对应容器；`restart` 不会加载新的镜像或环境变量。保留数据卷，不要执行 `down -v`。

`docker-compose.dev.yml` 保留用于本地开发调试；Docker Hub 镜像部署使用本文的 `docker-compose.yml`。
