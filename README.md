# ZigFS

ZigFS 是一个使用 Zig 构建的轻量级、单机 S3 兼容对象存储项目。

仓库包含两个独立项目：

- `zigfs/`：Zig 数据面，负责 S3/Data API、Management API、鉴权、对象数据和元数据。
- `zigfs-admin/`：可选管理网页；Vite + React Web 负责展示与交互，Go + Gin Server 只负责静态资源托管和接口转发。

Admin 只是 ZigFS Management API 的一个网页客户端。移除 Admin 后，ZigFS 仍然独立提供文件服务和管理 API，其他授权用户或系统可以直接对接。

职责定义：Admin Web 是展示层，Admin Server 是接口转发层，ZigFS 才是唯一服务端和所有数据、认证、权限及业务规则的权威来源。

## 当前状态

当前已完成工程初始化和架构边界搭建：

- Zig 0.16 项目、构建和测试入口
- YAML 配置与代码内默认值
- Domain、Ports、Adapters、Metadata、Transport 模块骨架
- 本地数据目录初始化
- 固定版本的 `.zigfs/format.meta`、持久化 Instance ID 和 SHA-256 损坏检测
- 数据根目录 OS 独占锁，同一目录禁止两个 ZigFS 写进程同时运行
- 显式 little-endian 编解码的版本化 Metadata Record Envelope
- ZigFS 常驻 HTTP Server、Health API 和 Prometheus Metrics Listener
- HTTP Request ID 透传/生成与基础访问日志
- ZigFS Management API 路由清单
- ZigFS YAML 管理员身份、Management 登录和短期会话校验
- Go 1.27 + Gin 1.12 管理 BFF
- Bucket、Object、AK/SK 和 System 类型化 Zig Client
- React 管理界面骨架

Signature V4、S3 业务 Handler、对象持久化、元数据事务和 ZigFS Management API Handler 尚未实现。尚未实现的 S3 与 Management 路由当前返回 `501 Not Implemented`。

## 启动脚本

根目录提供统一的交互式启动脚本：

```bash
./start.sh
```

运行后可选择启动 ZigFS 或 ZigFS Admin。选择 ZigFS 时只启动文件服务；选择
ZigFS Admin 时会启动完整依赖链，不需要再打开另一个终端。

Admin 启动前会检查 ZigFS Management API 的
`http://127.0.0.1:9000/health/ready`。可以通过 `ZIGFS_ENDPOINT` 修改检查和连接地址。
如果 ZigFS 尚未运行，脚本会先构建并启动 ZigFS，等待 Ready 后再启动 Admin。
如果 ZigFS 已经运行，脚本直接复用现有实例。按 `Ctrl+C` 或 Admin 退出时，脚本只会
停止本次自动启动的 ZigFS，不会停止启动脚本前已经存在的 ZigFS 进程。

首次启动 Admin 前，需要安装并锁定前端依赖：

```bash
cd zigfs-admin/web
pnpm install
```

脚本会使用现有依赖构建前端，不会自动安装依赖。管理员身份配置、密码校验和
Management Token 签发全部由 ZigFS 负责，Go Admin 不保存管理员账号或密码。

默认本地登录账号为 `admin`，密码为 `zigfs-admin`。请在 `zigfs/config.yaml` 的
`admin` 段修改；对外部署前必须同时更换密码和 `session_secret`。

## 架构边界

```text
File SDK / S3 Client
        |
        | S3/Data API
        v
      ZigFS ----------------------> Storage Backend
        |                               + Metadata Engine
        |
        | Management API
        +<---------------- Admin / authorized integrations
                              |
                         Go + Gin BFF
                              |
                         React Admin
```

三类接口相互独立：

- **S3/Data API**：Bucket、Object、PUT/GET、Multipart、Range 和 Presigned URL。
- **ZigFS Management API**：Bucket 管理视图、AK/SK、Storage、System 和动态配置。
- **Admin BFF API**：只服务 React 网页操作，不是文件 SDK 的接口。

多语言 SDK 面向 Android、iOS、Web 和业务服务中的文件上传下载。AK/SK 的创建、禁用和删除属于管理操作，不进入文件 SDK。

默认端口：

| 端口 | 服务 |
|---|---|
| `9000` | ZigFS S3/Data、Management 和 Health API |
| `9001` | ZigFS Admin Web Console |
| `9090` | ZigFS Prometheus Metrics，默认仅监听本机 |

监听地址和端口均可配置，但服务职责保持不变。

## ZigFS

要求：Zig 0.16.0 或更新版本。

```bash
cd zigfs
cp config.example.yaml config.yaml
zig build test
zig build run
```

ZigFS 默认读取 `config.yaml`。文件不存在时使用代码默认值；通过 `--config <path>` 显式指定后，缺失或无效配置会导致启动失败。

```yaml
server:
  api_address: "0.0.0.0:9000"

observability:
  metrics_enabled: true
  metrics_address: "127.0.0.1:9090"

storage:
  data_root: "data"

admin:
  username: "admin"
  password: "zigfs-admin"
  session_secret: "zigfs-local-session-secret-change-before-production"
  session_ttl_seconds: 28800
```

加载优先级：

```text
内置默认值 -> YAML 配置 -> 命令行覆盖
```

## ZigFS Admin Server

要求：Go 1.27 或更新版本。

```bash
cd zigfs-admin/server
go mod tidy
go test ./...

ZIGFS_ENDPOINT=http://127.0.0.1:9000 \
go run ./cmd/admin
```

主要环境变量：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `ZIGFS_ADMIN_LISTEN` | `:9001` | Admin HTTP 监听地址 |
| `ZIGFS_ENDPOINT` | `http://127.0.0.1:9000` | ZigFS API 地址 |
| `ZIGFS_WEB_ROOT` | `../web/dist` | React 构建产物目录 |

Admin Server 不配置管理员账号、密码或固定 Management Token。登录信息由它转发给
ZigFS；ZigFS 签发的短期 Token 只通过 HttpOnly Cookie 随请求转交。

## ZigFS Admin Web

要求：Node.js 24 或兼容版本。

```bash
cd zigfs-admin/web
pnpm install
pnpm run typecheck
pnpm run dev
```

开发服务器默认监听 `http://127.0.0.1:5173`，并把 `/api` 和 `/health` 代理到 `http://127.0.0.1:9001`。

## 项目结构

```text
.
├── zigfs/
│   ├── build.zig
│   ├── config.example.yaml
│   └── src/
│       ├── application/
│       ├── auth/
│       ├── backend/
│       ├── common/
│       ├── domain/
│       ├── metadata/
│       ├── ports/
│       └── transport/
├── zigfs-admin/
│   ├── server/
│   │   ├── cmd/admin/
│   │   └── internal/
│   └── web/
│       └── src/
├── docs/
└── README.md
```

## 设计原则

- 第一原则：先把 ZigFS 的 S3 API 做到标准、稳定、完整，再实现多语言 SDK；SDK 不定义第二套文件协议。
- ZigFS 是对象数据、元数据、Bucket 和 AK/SK 的唯一事实来源。
- 不使用 SQLite 或其他外部数据库保存对象存储元数据。
- Admin 不直接访问数据目录，不代理对象文件流。
- 模块只依赖明确的 Port，协议层不能直接操作文件系统。
- 优先使用标准库，第三方依赖按必要性逐项引入。
- 所有网络接口必须同步维护契约文档和兼容性测试。

## 开源协议

本项目基于 [Apache License 2.0](LICENSE) 开源。
