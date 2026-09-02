# ZigFS

ZigFS 是一个使用 Zig 构建的轻量级、单机 S3 兼容对象存储项目。

仓库包含两个独立项目：

- `zigfs/`：Zig 数据面，负责 S3/Data API、Management API、鉴权、对象数据和元数据。
- `zigfs-admin/`：可选管理网页，包含 Go + Gin BFF 和 Vite + React 前端。

Admin 只是 ZigFS Management API 的一个网页客户端。移除 Admin 后，ZigFS 仍然独立提供文件服务和管理 API，其他授权用户或系统可以直接对接。

## 当前状态

当前已完成工程初始化和架构边界搭建：

- Zig 0.16 项目、构建和测试入口
- YAML 配置与代码内默认值
- Domain、Ports、Adapters、Metadata、Transport 模块骨架
- 本地数据目录初始化
- ZigFS Management API 路由清单
- Go 1.27 + Gin 1.12 管理 BFF
- Bucket、Object、AK/SK 和 System 类型化 Zig Client
- React 管理界面骨架

S3 HTTP Server、Signature V4、对象持久化、元数据事务和 ZigFS Management API Handler 尚未实现。

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
  s3_address: "0.0.0.0:9000"
  management_address: "127.0.0.1:9001"

storage:
  data_root: "data"
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

ZIGFS_WEB_ADMIN_TOKEN=local-admin-token \
ZIGFS_ADMIN_TOKEN=zigfs-management-token \
ZIGFS_ENDPOINT=http://127.0.0.1:9001 \
go run ./cmd/admin
```

主要环境变量：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `ZIGFS_ADMIN_LISTEN` | `:8080` | Admin HTTP 监听地址 |
| `ZIGFS_ENDPOINT` | `http://127.0.0.1:9001` | ZigFS Management API 地址 |
| `ZIGFS_ADMIN_TOKEN` | 空 | 调用 ZigFS 的管理凭证 |
| `ZIGFS_WEB_ADMIN_TOKEN` | 无，必须提供 | 网页访问凭证 |
| `ZIGFS_WEB_ROOT` | `../web/dist` | React 构建产物目录 |

## ZigFS Admin Web

要求：Node.js 24 或兼容版本。

```bash
cd zigfs-admin/web
npm install
npm run typecheck
npm run dev
```

开发服务器默认监听 `http://127.0.0.1:5173`，并把 `/api` 和 `/health` 代理到 `http://127.0.0.1:8080`。

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

- ZigFS 是对象数据、元数据、Bucket 和 AK/SK 的唯一事实来源。
- 不使用 SQLite 或其他外部数据库保存对象存储元数据。
- Admin 不直接访问数据目录，不代理对象文件流。
- 模块只依赖明确的 Port，协议层不能直接操作文件系统。
- 优先使用标准库，第三方依赖按必要性逐项引入。
- 所有网络接口必须同步维护契约文档和兼容性测试。
