# API 契约索引

ZigFS 维护三套相互独立的网络契约：

| 接口 | 用途 | 调用方 | 契约 |
|---|---|---|---|
| S3/Data API | Bucket、Object、Multipart、上传下载 | 文件 SDK、S3 Client、应用程序 | [s3-compatibility.md](s3-compatibility.md) |
| ZigFS Management API | AK/SK、管理视图、Storage、System、配置 | Admin、授权用户、自动化系统 | [zigfs-management-v1.openapi.yaml](zigfs-management-v1.openapi.yaml) |
| Admin BFF API | React 网页操作适配 | React Admin | [admin-bff-v1.openapi.yaml](admin-bff-v1.openapi.yaml) |

Health 与监控契约见 [operations.md](operations.md)。

Phase 5 的 S3 Bucket/Object/List V2、Multipart、单 Range、Presigned GET/PUT、Signature V4
Header/Streaming 以及 CRC64NVME signed trailer 已实现，并覆盖上传断流和下载取消语义。
Phase 9 已补齐 GET/HEAD/PUT 的 Conditional Requests，包括 ETag/HTTP 日期条件、304/412
响应和条件 PUT 的 Metadata Generation CAS，并实现 CopyObject 的流式复制、权限、元数据
指令和条件语义。
随后完成可配置 Virtual-hosted-style Addressing：校验 `s3.public_endpoint` authority、
提取 Bucket 子域名并将实际 Host 绑定到 SigV4；默认仍使用 Path-style。
Temporary Credentials 也已实现：`ZFCR` V1.1 向后兼容持久化临时 AK/SK/Session Token，
Header 与 Presigned SigV4 均绑定 Token，并对缺失、错误和过期返回稳定 S3 错误。
S3 POST Policy Upload 也已实现：Policy 使用 SigV4 直接签名，支持条件、有效期、
`multipart/form-data` 文件流、Content-MD5/CRC64NVME 和 `success_action_status`，失败时不发布对象。
Phase 6 ZigFS Management、Gin BFF 与 Admin 页面已完成；Phase 7 已由 TypeScript/Web 和
Swift/iOS Adapter 通过共享向量及隔离 ZigFS 端到端文件操作 Gate。具体状态以 S3 兼容矩阵、
SDK 一致性契约和 OpenAPI Operation 描述为准。
