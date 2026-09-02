# API 契约索引

ZigFS 维护三套相互独立的网络契约：

| 接口 | 用途 | 调用方 | 契约 |
|---|---|---|---|
| S3/Data API | Bucket、Object、Multipart、上传下载 | 文件 SDK、S3 Client、应用程序 | [s3-compatibility.md](s3-compatibility.md) |
| ZigFS Management API | AK/SK、管理视图、Storage、System、配置 | Admin、授权用户、自动化系统 | [zigfs-management-v1.openapi.yaml](zigfs-management-v1.openapi.yaml) |
| Admin BFF API | React 网页操作适配 | React Admin | [admin-bff-v1.openapi.yaml](admin-bff-v1.openapi.yaml) |

Health 与监控契约见 [operations.md](operations.md)。

当前处于项目初始化阶段。接口进入代码骨架不代表已经实现；具体状态以 S3 兼容矩阵和 OpenAPI Operation 描述为准。
