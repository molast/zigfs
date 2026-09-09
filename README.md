# ZigFS

ZigFS 是一个使用 Zig 构建的轻量级、单机 S3 兼容对象存储项目。

仓库包含两个独立项目：

- `zigfs/`：Zig 数据面，负责 S3/Data API、Management API、鉴权、对象数据和元数据。
- `zigfs-admin/`：可选管理网页；Vite + React Web 负责展示与交互，Go + Gin Server 只负责静态资源托管和接口转发。

Admin 只是 ZigFS Management API 的一个网页客户端。移除 Admin 后，ZigFS 仍然独立提供文件服务和管理 API，其他授权用户或系统可以直接对接。

职责定义：Admin Web 是展示层，Admin Server 是接口转发层，ZigFS 才是唯一服务端和所有数据、认证、权限及业务规则的权威来源。

## 当前状态

当前已完成 0.1 Release Candidate（服务版本 `0.1.0`，候选标签 `v0.1.0-rc.1`）的工程、
协议、恢复和发布准备：

- Zig 0.16 项目、构建和测试入口
- YAML 配置与代码内默认值
- Domain、Ports、Adapters、Metadata、Transport 模块骨架
- 本地数据目录初始化
- 固定版本的 `.zigfs/format.meta`、持久化 Instance ID 和 SHA-256 损坏检测
- 数据根目录 OS 独占锁，同一目录禁止两个 ZigFS 写进程同时运行
- 显式 little-endian 编解码的版本化 Metadata Record Envelope
- 自有 Metadata Repository、Transaction Journal 与单调 Generation
- Intent/Commit/Abort、临时文件 fsync、原子 Record 发布和父目录同步
- Bucket、Object、Upload ID、Access Key 四类可重建内存索引
- Object Key 有序索引及 Prefix、Delimiter、Start After、分页基础语义
- 启动 Journal 回放、未完成事务恢复、孤儿临时文件清理和 Tombstone 过滤
- Recovery 状态机；损坏数据保持进程存活并让 Ready 返回 `503`
- S3 兼容 Bucket Name 校验和版本化 Bucket Metadata Payload
- `BucketStore` Port、Metadata Adapter，以及与 HTTP 解耦的 Create、Head、List、Delete Bucket Core
- Bucket 同 Owner 幂等创建、跨 Owner 同名冲突、非空删除保护、Tombstone 和删除后重建
- Bucket 持久化与索引原子发布；重启可恢复，损坏 Bucket Payload 会阻止 Ready
- 完整 1024-byte S3 Object Key、Content-Type 和有界 User Metadata 校验
- `ZFOB` V1.0 Object Metadata、Object/Data Generation UUID、MD5 ETag 与 SHA-256
- `ObjectStore`、流式 `ObjectDataStore` Port 和 UUID 分代的本地数据布局
- 固定缓冲的 Object Put/Get/Head/Delete、Content-MD5 校验、覆盖与 Tombstone
- 64 路 Object 读写锁；长上传期间 GET 继续读取旧 Data Generation
- Object 重启恢复、暂存数据清理和损坏 Metadata/Data 检测
- List Objects V2 Core：Prefix、Delimiter、Max Keys、Start After 和 Continuation Token
- `ZFCT` V1.0 URL-safe 分页 Token，绑定 Bucket/Prefix/Delimiter 并校验 SHA-256
- 严格 UUID Generation 扫描和幂等 GC，回收覆盖旧版、删除对象数据与无 Metadata 孤儿
- 全 Object 锁 GC 屏障，保护活跃 GET 和 PUT 的 Data/Metadata 提交窗口
- ZigFS 常驻 HTTP Server、Health API 和 Prometheus Metrics Listener
- HTTP Request ID 透传/生成与基础访问日志
- 向后兼容的 `ZFCR` V1.1 永久/临时 Credential Metadata、AES-256-GCM Secret/Session Token 加密和数据根随机 Master Key
- 永久 AK/SK 与临时 AK/SK/Session Token 创建、查询、更新、禁用、过期、删除、重启恢复和最小 Bucket/Object Policy
- Signature V4 Header/Presigned Query 验签、Canonical URI/Query/Header、Region Scope、Payload Hash、有效期和时钟偏差校验
- Path-style 与可配置 Virtual-hosted-style S3 Router、Host-aware SigV4、稳定 XML 错误，以及 Bucket/Object/List V2 HTTP Handler
- S3 Put/Get 流式传输、Content-MD5/SHA-256 与 CRC32/CRC32C/CRC64NVME/SHA1/SHA256 Flexible Checksum 校验、ETag、用户元数据和分页响应
- S3 Bucket Versioning：Enabled/Suspended、不可变 Version ID、DeleteMarker、指定版本 GET/HEAD/DELETE、ListObjectVersions，以及通过 CopyObject 将旧版本发布为新当前版本
- S3 Lifecycle：持久化规则、当前/非当前版本过期、过期 DeleteMarker 清理和 YAML 可配置后台扫描周期
- Admin 版本视图：查看 DeleteMarker、删除最新 DeleteMarker 恢复对象，以及通过标准 CopyObject 回溯任意旧版本
- Admin Lifecycle 规则页：新增、编辑、启停和删除当前版本、非当前版本及过期 DeleteMarker 的 Expiry 规则
- AWS SigV4 aws-chunked 签名链，以及五种 Flexible Checksum signed trailer 的签名与 checksum 校验
- S3 Multipart Create、并发 UploadPart、ListParts、ListMultipartUploads、Manifest-only Complete、Abort、复合 ETag 和启动超时清理
- Multipart 以 Part 为边界暂停/恢复；支持 Presigned 全生命周期、Upload ID 重发现和跳过已提交 Part
- 真实环回 TCP S3 集成测试，覆盖鉴权拒绝、CRUD、分页、Policy 与 Credential 禁用
- ZigFS Management API：Bucket、Object 管理视图、Presign、AK/SK、Storage、System、Health 和 Settings
- ZigFS YAML 管理员身份、Management 登录和短期会话校验，以及统一 JSON 错误和危险操作审计日志
- Go 1.27 + Gin 1.12 管理 BFF
- Bucket、Object、Presign、AK/SK、Storage、System、Health 和 Settings 类型化 Zig Client
- React Dashboard、Buckets、Objects、Access Keys、Storage、System 和 Settings 管理页面
- Admin 对 ZigFS Offline、Not Ready 和未登录状态的独立展示
- 语言无关文件 SDK 设计、版本、错误与一致性测试契约
- TypeScript/Web 与 Swift/iOS 两套 S3 一致性 Adapter，共享 SigV4、64 位、错误和重试向量
- 隔离 ZigFS 端到端 SDK Gate，覆盖流式 Put/Get、Range、分页、Multipart、取消和错误映射
- Phase 8 故障注入：覆盖 Object Data、Journal、Metadata Commit 前后崩溃点，重启只恢复完整代
  数据代，暂存数据清理且不可达代由 GC 回收
- 启动 Storage write probe；只读、路径冲突和探针写入失败会阻止服务进入 Ready
- Metadata Repository 全量重建在索引快照损坏或删除后仍可工作；对象 Data 同长度篡改由 SHA-256
  检测并以 `CorruptData` 报告
- `benchmarks/run.mjs` 可复现运行 Small/Large Object、并发、Multipart、Range 和 CRUD 基准，
  输出 Requests/s、吞吐、p50/p95/p99、RSS、CPU 与平台可用的 Disk I/O

Phase 4 S3 Protocol and Authentication 已完成约定的三客户端矩阵。核心 Bucket/Object/List V2
Path-style HTTP API、Signature V4 Header、AK/SK 加密持久化和 Policy 已实现并通过真实
TCP 回归测试；AWS CLI 2.36.38、rclone 1.75.0 和 mc 2025-08-13 已通过当前声明范围，
包括 mc 默认的签名流式 Put 和 DeleteObjects 删除。Phase 5 已完成，单 Range GetObject
及 `206/416` 语义已通过 AWS CLI；对象级 Presigned GET/PUT 已实现，AWS CLI、mc、rclone
生成的 Presigned GET 均通过匿名下载与字节一致性验证。Multipart 完整生命周期也已通过
AWS CLI、mc 和 rclone 的并发大文件上传与下载校验。五种 Flexible Checksum signed streaming trailer
已完成原生 TCP 正向、错误 checksum、错误 trailer 签名及失败不发布回归；Object/Part 中途
断流不会发布数据或遗留暂存文件，下载取消会释放读取租约。条件请求已支持 GET/HEAD/PUT
的 ETag/日期前置条件和 `304`/`412` 语义。Virtual-hosted-style 已支持（默认关闭，可通过
`s3.virtual_hosted_style` 开启）。Temporary Credentials 已支持 Header 与 Presigned SigV4
Session Token 绑定；POST Policy Upload 已支持 SigV4 Policy、条件和 multipart 文件流；五种 Flexible Checksum trailer 均已实现，独立 AWS SDK trailer 矩阵作为补充验证继续维护。Phase 6 Management and Admin
已实现 ZigFS Management Handler、真实 TCP Contract、Gin BFF 和完整 React 管理页面。
Phase 7 SDK Conformance 已完成语言无关契约和共享向量，并由 TypeScript/Web、Swift/iOS
两个生态直接连接隔离 ZigFS 通过完整文件操作 Gate；该阶段验证 S3 契约，不发布第二套协议。
Phase 8 Reliability and Performance 已加入确定性故障注入、写能力探针、索引重建和数据校验损坏
测试，以及可输出原始 JSON 的 `smoke`/`full` 基准工具。基准结果与硬件、构建模式和并发度绑定，
不构成脱离环境的性能承诺。
Phase 9 S3 Compatibility Hardening and 0.1 Release Candidate 已完成。Conditional Requests、
CopyObject、Virtual-hosted-style、Temporary Credentials、POST Policy Upload、Flexible
Checksum Trailer、外部客户端兼容性 Runner、对外契约同步、RC 发布材料和全量 Gate 均已完成。
发布版本仍为服务版本 `0.1.0`，候选标签为 `v0.1.0-rc.1`。
Phase 10 Resumable Multipart Upload 已完成 ZigFS S3/Management 能力与 Admin 操作链路：客户端可通过
`ListMultipartUploads` 和 `ListParts` 恢复未完成上传，Admin 支持真实分片进度、暂停、继续、失败重试、
取消清理以及刷新页面后重新选择原文件继续。全部 Part 上传后，Complete 只发布引用既有 Part 的对象 Manifest，不重新读取或复制完整文件；
若刷新或网络中断导致 Complete 响应丢失，会根据 UploadId 和最终 Object 自动校准结果。单次 `PutObject` 和单个 `UploadPart` 仍遵循 S3 语义，
不能从请求体中间续传，中断的 Part 必须完整重传。
Phase 11 Object Versioning and Lifecycle 已完成：版本历史和 Lifecycle 规则由 ZigFS 自有 Metadata
Engine 持久化，S3 标准接口负责文件客户端操作，Management API 负责 Admin 配置与历史查看；
Admin 仍然不保存 Bucket、Object、版本或规则状态。

外部客户端兼容性 Runner 位于 [compatibility/README.md](compatibility/README.md)，可重复运行
AWS CLI、MinIO Client、rclone 和原生 HTTP 矩阵，并输出不含凭证的 JSON/Markdown 报告：

```bash
./compatibility/run.sh
```

AWS S3 全量操作覆盖和未实现边界见 [docs/api/s3-api-coverage.md](docs/api/s3-api-coverage.md)。

运维、备份恢复和 V1 限制见 [docs/operations.md](docs/operations.md)、
[docs/backup-and-recovery.md](docs/backup-and-recovery.md) 和
[docs/known-limitations.md](docs/known-limitations.md)。0.1 Release Candidate 的版本、
构建、升级、回滚和发布检查见 [docs/release/v1-release-candidate.md](docs/release/v1-release-candidate.md)。
基准工作负载和采样方法见 [docs/benchmarks.md](docs/benchmarks.md)。

## SDK 一致性验证

要求：Node.js 24、TypeScript 5.9、Swift 6.3、Zig 0.16 和 `curl`。前端依赖已安装后运行：

```bash
./conformance/run.sh
```

测试只启动临时 ZigFS，不启动 Admin。临时 AK/SK 由 ZigFS Management API 创建，TypeScript
和 Swift Adapter 仅调用 S3/Data API，结束后销毁完整临时数据目录。契约见
[docs/sdk/conformance.md](docs/sdk/conformance.md)。

## 启动脚本

根目录提供统一的交互式启动脚本：

```bash
./start.sh
```

运行后可选择启动 ZigFS、启动 ZigFS Admin，或构建 Docker 镜像。选择 ZigFS 时只启动
文件服务；选择 ZigFS Admin 时会启动完整依赖链，不需要再打开另一个终端。Docker 构建
入口可继续选择 ZigFS、ZigFS Admin 或一次构建全部镜像。

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

## Docker

ZigFS 与 ZigFS Admin 使用独立镜像。可以运行根目录脚本并选择“构建 Docker 镜像”：

```bash
./start.sh
```

默认镜像标签为 `0.1.0`，可以通过 `ZIGFS_DOCKER_TAG` 覆盖：

```bash
ZIGFS_DOCKER_TAG=0.1.0-dev ./start.sh
```

ZigFS Dockerfile 基于 Alpine，构建阶段从 Zig 官方下载索引中选择与容器架构匹配的
Zig 0.16.0 压缩包并校验 SHA-256，不依赖 Alpine 仓库或额外的 Zig 镜像。

也可以直接执行 Docker 命令构建两个项目：

```bash
docker build -t zigfs:0.1.0 ./zigfs
docker build -t zigfs-admin:0.1.0 ./zigfs-admin
```

创建内部网络并启动 ZigFS：

```bash
docker network create zigfs-network
docker run -d \
  --name zigfs \
  --network zigfs-network \
  -p 9000:9000 \
  -p 9090:9090 \
  -v zigfs-data:/var/lib/zigfs \
  zigfs:0.1.0
```

再启动只负责 Web 展示和 API 转发的 Admin：

```bash
docker run -d \
  --name zigfs-admin \
  --network zigfs-network \
  -p 9001:9001 \
  -e ZIGFS_ENDPOINT=http://zigfs:9000 \
  zigfs-admin:0.1.0
```

ZigFS 镜像内置 [容器默认配置](zigfs/config.docker.yaml)，数据目录为
`/var/lib/zigfs`。生产部署应修改管理员凭证、`session_secret` 和
`s3.public_endpoint`，并将配置挂载到 `/etc/zigfs/config.yaml`：

```bash
docker run -d \
  --name zigfs \
  --network zigfs-network \
  -p 9000:9000 \
  -p 9090:9090 \
  -v zigfs-data:/var/lib/zigfs \
  -v "$(pwd)/zigfs/config.docker.yaml:/etc/zigfs/config.yaml:ro" \
  zigfs:0.1.0
```

Admin 镜像不包含 ZigFS 数据与管理员账号。它仅通过 `ZIGFS_ENDPOINT` 调用
ZigFS Management API；跨 Docker 网络、主机或 HTTPS 部署时修改该环境变量即可。

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

- **S3/Data API**：Bucket、Object、PUT/GET、Multipart、Range、Presigned URL、Versioning 和 Lifecycle。
- **ZigFS Management API**：Bucket 配置与版本管理视图、AK/SK、Storage、System 和动态配置。
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
  stream_buffer_size: 65536

s3:
  public_endpoint: "http://127.0.0.1:9000"
  virtual_hosted_style: false
  region: "us-east-1"
  request_time_skew_seconds: 900
  multipart_expiry_seconds: 604800
  lifecycle_scan_interval_seconds: 300

admin:
  username: "admin"
  password: "zigfs-admin"
  session_secret: "zigfs-local-session-secret-change-before-production"
  session_ttl_seconds: 28800
```

`server.api_address` 是 ZigFS 的实际监听地址；`s3.public_endpoint` 是返回给浏览器、移动端
或其他客户端的公开 S3 地址，用于生成绝对 Presigned URL，也作为开启 Virtual-hosted-style
时的 Host authority 基准。反向代理或跨主机部署时应把
它设置为客户端实际可访问的 `http://` 或 `https://` Authority，且不能包含路径、凭证或查询参数。
开启 `s3.virtual_hosted_style` 后，ZigFS 还接受 `<scheme>://<bucket>.<authority>/<object>` 形式的
S3 请求；精确 authority 仍保留 Path-style。客户端 DNS 或反向代理必须能够解析对应的 Bucket 子域名。

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
| `ZIGFS_UPSTREAM_TIMEOUT` | `15m` | Admin 等待 ZigFS 管理操作完成的最长时间，使用 Go duration 语法 |

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
├── .docs/
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
