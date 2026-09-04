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
Phase 6 ZigFS Management、Gin BFF 与 Admin 页面已完成；Phase 7 已由 TypeScript/Web 和
Swift/iOS Adapter 通过共享向量及隔离 ZigFS 端到端文件操作 Gate。具体状态以 S3 兼容矩阵、
SDK 一致性契约和 OpenAPI Operation 描述为准。
