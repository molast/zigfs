# 文件 SDK 设计

- **契约版本：** V1.0
- **状态：** Phase 7 Conformance Baseline
- **更新日期：** 2026-09-07

ZigFS 多语言 SDK 只面向文件存储操作，不封装 Admin BFF API，也不提供 AK/SK 创建、禁用、删除或系统配置。

## 目标平台

- Kotlin / Android
- Swift / iOS
- TypeScript / Web
- Go、Python、Rust 等服务端语言

## 核心能力

```text
Client
├── Bucket
│   ├── create
│   ├── exists/head
│   ├── list
│   └── delete
├── Object
│   ├── put stream/file
│   ├── get stream/file
│   ├── head
│   ├── list
│   └── delete
├── Multipart
│   ├── initialize
│   ├── upload part
│   ├── complete
│   └── abort
└── Access
    ├── Signature V4
    ├── temporary credentials
    └── presigned URL
```

SDK 的网络边界固定为 [S3/Data API](../api/s3-compatibility.md)。实现可以复用成熟的
S3 协议库，但不得新增 ZigFS 私有文件接口，也不得通过 Admin BFF 代理对象字节。

## 公共模型

各语言可以使用符合本地习惯的命名，但必须保留以下语义：

| 模型 | 必需字段 | 约束 |
|---|---|---|
| `Credentials` | `accessKey`、`secretKey`、可选 `sessionToken`、可选 `expiresAt` | Secret 不写日志；过期前刷新 |
| `Bucket` | `name`、可选 `creationDate` | 名称规则以服务端结果为准 |
| `ObjectSummary` | `key`、`size`、`etag`、`lastModified` | `size` 为无符号 64 位语义 |
| `ObjectMetadata` | Summary 字段、`contentType`、`userMetadata`、checksum | Header 名大小写不敏感 |
| `ByteRange` | `start`、可选 `end` | 闭区间，均为无符号 64 位语义 |
| `ListPage<T>` | `items`、可选 `nextToken` | Token 不透明，不解析、不修改 |
| `MultipartUpload` | `uploadId`、`bucket`、`key` | Upload ID 不透明 |
| `UploadedPart` | `partNumber`、`etag`、可选 checksum | Part Number 为 `1..10000` |
| `TransferProgress` | `transferred`、可选 `total` | 两者均为无符号 64 位语义 |
| `ZigFSError` | 见 [errors.md](errors.md) | 保留服务端 Code、Status、Request ID |

公开 API 至少提供异步操作和显式取消句柄。流式输入必须声明是否可重放；只有可重放
Body 才能在传输失败后自动重试。

## 操作契约

| SDK 操作 | S3 Operation | Body/返回值 | 幂等与重试 |
|---|---|---|---|
| `listBuckets` | ListBuckets | `List<Bucket>` | 只读，可重试 |
| `createBucket` | CreateBucket | Bucket 名 | 只在同 Owner 幂等语义下重试 |
| `headBucket` | HeadBucket | `Boolean` 或 Metadata | 只读，可重试 |
| `deleteBucket` | DeleteBucket | 无 | 空 Bucket 删除可重试 |
| `putObject` | PutObject | 可重放流/文件 | Body 可重放且响应未开始时可重试 |
| `getObject` | GetObject | 流 | 首字节交付前可重试；交付后由调用方续传 |
| `headObject` | HeadObject | `ObjectMetadata` | 只读，可重试 |
| `deleteObject` | DeleteObject | 无 | 幂等，可重试 |
| `listObjects` | ListObjectsV2 | `ListPage<ObjectSummary>` | 只读，可按原 Token 重试 |
| `getRange` | Range GetObject | 流和 Content Range | 与 GetObject 相同 |
| `createMultipart` | CreateMultipartUpload | `MultipartUpload` | 不盲目自动重试 |
| `uploadPart` | UploadPart | `UploadedPart` | 同 Part 可覆盖，Body 可重放时可重试 |
| `completeMultipart` | CompleteMultipartUpload | Object ETag | 结果不明确时先对账，不盲目重试 |
| `abortMultipart` | AbortMultipartUpload | 无 | 可重试 |

协议字段、Query、XML 和当前差异以 S3 兼容矩阵为唯一事实来源。本文件不复制服务端
Bucket 校验、Policy 或 Multipart 状态机。

## 移动端与 Web 安全

长期 Secret Key 不得写入移动应用、网页包或公开配置。客户端优先使用：

1. 业务后端签发的短期凭证。
2. 业务后端或 ZigFS 授权服务生成的 Presigned PUT/GET URL。
3. 明确受限且可撤销的 Credential Policy。

AK/SK 的生成和权限配置通过 ZigFS Management API 完成，通常由 Admin 网页操作。

生产移动端或浏览器 SDK 的默认入口应是 Presigned URL 或短期凭证提供器。构造函数不得
鼓励把长期 Secret Key 固化在源码、应用包、浏览器存储或静态配置中。Phase 7 的端到端
测试凭证由隔离 ZigFS 临时生成，测试结束即随临时数据目录销毁。

## 跨语言契约

- 上传下载必须使用流，不能要求整文件进入内存。
- 支持进度回调、取消、超时、断点续传和安全重试。
- Object Size、Offset、Part Size 使用 64 位整数。
- Upload ID、Continuation Token 保持不透明。
- ETag 与 checksum 不擅自转换或解释为安全摘要。
- 错误保留 S3 Error Code、HTTP Status、Request ID 和可重试标记。
- 各 SDK 使用共享兼容测试数据和端到端测试套件。

具体版本兼容、错误模型和 Gate 分别见 [versioning.md](versioning.md)、
[errors.md](errors.md) 与 [conformance.md](conformance.md)。
