# 运维接口

## ZigFS

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/health/live` | 无或网络限制 | 进程和事件循环存活 |
| GET | `/health/ready` | 无或网络限制 | 存储、元数据恢复和写入能力就绪 |
| GET | `/_admin/v1/health` | Management 凭证 | 详细健康和恢复状态 |
| GET | `/_admin/v1/system` | Management 凭证 | 版本、运行时间和对象统计 |
| GET | `/_admin/v1/storage` | Management 凭证 | 容量与磁盘状态 |
| GET | `/_admin/v1/settings` | Management 凭证 | 脱敏后的只读生效配置 |

`storage` 在 V1 报告当前可见对象的逻辑字节数；`total` 和 `available` 在没有正式容量
Backend 时为 `null`，不能把单个平台的文件系统调用结果冒充为可移植容量契约。

## S3/Data API

以下接口由 ZigFS `server.api_address` 直接提供，默认使用 Signature V4 Header 认证；
对象级 GetObject 和 PutObject 也支持 Signature V4 Presigned Query：

| Method | Path | 含义 |
|---|---|---|
| GET | `/` | ListBuckets |
| PUT | `/{bucket}` | CreateBucket |
| HEAD | `/{bucket}` | HeadBucket |
| GET | `/{bucket}?location=` | GetBucketLocation |
| DELETE | `/{bucket}` | DeleteBucket |
| GET | `/{bucket}?list-type=2` | ListObjectsV2 |
| POST | `/{bucket}?delete=` | DeleteObjects |
| PUT | `/{bucket}/{object}` | PutObject |
| GET | `/{bucket}/{object}` | GetObject |
| HEAD | `/{bucket}/{object}` | HeadObject |
| DELETE | `/{bucket}/{object}` | DeleteObject |

完整 Header、Query、XML、错误和已知差异见
[s3-compatibility.md](s3-compatibility.md)。S3 API 不经过 Go Admin。

Prometheus 默认通过独立的 `127.0.0.1:9090` Listener 拉取指标：

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/metrics` | 默认使用网络限制 | Prometheus 文本格式运行指标 |

## Admin

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/health/live` | 无 | Gin 进程存活 |
| GET | `/health/ready` | 无 | Admin 可以连接 ZigFS |

`live` 不代表可以处理存储请求；编排系统应使用 `ready` 决定是否接收流量。

启动会执行受控的 Storage write probe；初始化探针失败时服务不会进入 HTTP Ready，
返回 `StorageNotWritable`。恢复或运行期不可用时 `ready` 返回 `503`，并在详细
Management Health 中保留恢复错误分类。运维、备份和恢复流程见
[operations.md](../operations.md) 与 [backup-and-recovery.md](../backup-and-recovery.md)。

## Request ID

ZigFS 的 API、Health 和 Metrics 响应均返回 `X-Request-ID`。请求携带合法的
`X-Request-ID` 时 ZigFS 透传该值；缺失或不合法时生成新的 Request ID。合法值
长度为 1 到 128 字节，仅允许 ASCII 字母、数字、`-`、`_`、`.` 和 `:`。

S3 响应同时返回 `X-Amz-Request-Id`；S3 XML 错误中的 `RequestId` 与该值一致。
