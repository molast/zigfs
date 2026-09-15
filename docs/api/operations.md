# 运维与网络接口

- **契约版本：** V1.2
- **更新日期：** 2026-09-08

## ZigFS

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/health/live` | 无或网络限制 | 进程和事件循环存活 |
| GET | `/health/ready` | 无或网络限制 | 存储、元数据恢复和写入能力就绪 |
| GET | `/_admin/v1/health` | Management 凭证 | 详细健康和恢复状态 |
| GET | `/_admin/v1/system` | Management 凭证 | 版本、运行时间和对象统计 |
| GET | `/_admin/v1/storage` | Management 凭证 | 容量与磁盘状态 |
| GET | `/_admin/v1/storage/scanner` | Management 凭证 | 16 分片 Scanner 进度与最近结果 |
| POST | `/_admin/v1/storage/gc` | Management 凭证 | 完整扫描并清理过期 MPU 和不可达数据 |
| GET | `/_admin/v1/settings` | Management 凭证 | 脱敏后的只读生效配置 |
| GET | `/_admin/v1/buckets/{name}/configuration` | Management 凭证 | 获取 Bucket Versioning/Lifecycle 配置 |
| PATCH | `/_admin/v1/buckets/{name}/configuration` | Management 凭证 | 更新 Bucket Versioning/Lifecycle 配置 |
| GET | `/_admin/v1/buckets/{name}/versions?prefix=` | Management 凭证 | 查看对象版本与 DeleteMarker |
| POST | `/_admin/v1/multipart-uploads` | Management 凭证 | 创建并持久化 Multipart Upload |
| GET | `/_admin/v1/buckets/{name}/multipart-uploads` | Management 凭证 | 发现 Bucket 中未完成的上传 |
| GET | `/_admin/v1/multipart-uploads/{id}?bucket=&key=` | Management 凭证 | 查询 Upload 与已提交 Parts |
| POST | `/_admin/v1/multipart-uploads/{id}/complete` | Management 凭证 | 使用 Part Number/ETag 完成上传 |
| DELETE | `/_admin/v1/multipart-uploads/{id}?bucket=&key=` | Management 凭证 | 取消上传并清理已提交分片 |
| POST | `/_admin/v1/objects/presign` | Management 凭证 | 生成对象、指定版本、CopyObject 或 UploadPart 的短时效直连 URL；调用方必须携带响应中的 `required_headers` |

`storage` 在 V1 报告当前可见对象的逻辑字节数；`total` 和 `available` 在没有正式容量
Backend 时为 `null`，不能把单个平台的文件系统调用结果冒充为可移植容量契约。
文件清理和分片扫描语义见[存储扫描与文件清理架构](../storage-reclamation.md)。

## S3/Data API

以下接口由 ZigFS `server.api_address` 直接提供，默认使用 Signature V4 Header 认证；
对象级 GetObject、PutObject、DeleteObject 与 Multipart 全生命周期也支持 Signature V4 Presigned Query：

永久凭证使用 AK/SK。临时凭证还必须携带 Session Token：Header SigV4 使用已进入
`SignedHeaders` 的 `x-amz-security-token`，Presigned Query 使用签名绑定的
`X-Amz-Security-Token`；缺失、错误和过期分别返回稳定的 `InvalidToken` 或 `ExpiredToken`。

当 `s3.virtual_hosted_style` 开启时，上述 Bucket/Object 路径也可使用
`Host: <bucket>.<s3.public_endpoint authority>` 和 `/{object}` 的 Virtual-hosted-style；
精确的公开 authority 始终保留 Path-style。

| Method | Path | 含义 |
|---|---|---|
| GET | `/` | ListBuckets |
| PUT | `/{bucket}` | CreateBucket |
| HEAD | `/{bucket}` | HeadBucket |
| GET | `/{bucket}?location=` | GetBucketLocation |
| DELETE | `/{bucket}` | DeleteBucket |
| GET | `/{bucket}?list-type=2` | ListObjectsV2 |
| GET | `/{bucket}?versions=` | ListObjectVersions |
| GET | `/{bucket}?versioning=` | GetBucketVersioning |
| PUT | `/{bucket}?versioning=` | PutBucketVersioning |
| GET | `/{bucket}?lifecycle=` | GetBucketLifecycleConfiguration |
| PUT | `/{bucket}?lifecycle=` | PutBucketLifecycleConfiguration |
| DELETE | `/{bucket}?lifecycle=` | DeleteBucketLifecycle |
| POST | `/{bucket}?delete=` | DeleteObjects |
| POST | `/{bucket}` | S3 POST Policy Upload（`multipart/form-data`） |
| PUT | `/{bucket}/{object}` | PutObject |
| PUT | `/{bucket}/{object}` + `x-amz-copy-source: /{source-bucket}/{source-object}[?versionId=ID]` | CopyObject（可指定源 Version ID） |
| GET | `/{bucket}/{object}[?versionId=ID]` | GetObject / GetObjectVersion |
| HEAD | `/{bucket}/{object}[?versionId=ID]` | HeadObject / HeadObjectVersion |
| DELETE | `/{bucket}/{object}[?versionId=ID]` | DeleteObject / DeleteObjectVersion |

Admin 中“恢复被删除对象”使用 `DELETE ?versionId=<DeleteMarker ID>` 删除最新 DeleteMarker；
“回溯到旧版本”使用带源 `versionId` 的 CopyObject，将旧版本内容发布为新的当前版本。两项操作都
经过 ZigFS 生成的 Presigned URL 直连 S3/Data API，不新增 Admin 私有文件协议。

Multipart Upload：

| Method | Path | 含义 |
|---|---|---|
| POST | `/{bucket}/{object}?uploads=` | CreateMultipartUpload |
| PUT | `/{bucket}/{object}?partNumber=N&uploadId=ID` | UploadPart |
| GET | `/{bucket}/{object}?uploadId=ID` | ListParts |
| POST | `/{bucket}/{object}?uploadId=ID` | CompleteMultipartUpload |
| DELETE | `/{bucket}/{object}?uploadId=ID` | AbortMultipartUpload |
| GET | `/{bucket}?uploads=` | ListMultipartUploads |

Multipart 暂停/恢复以 Part 为边界。恢复端先用 `ListMultipartUploads` 找回 Upload ID，再用
`ListParts` 获取已提交 Part；已提交 Part 可跳过，上传中断的 Part 必须完整重传。单次
`PutObject` 和单个 `UploadPart` 不提供请求体字节中点续传。

UploadPart 成功时 Part 已经作为不可变数据持久化。CompleteMultipartUpload 只校验 Part、计算
复合 ETag 并通过 Object Metadata CAS 发布有序 Manifest，不重新读取或复制完整对象；GET 按
Manifest 顺序读取，Range 只访问相交 Part。活动 Upload 和所有对象版本的 Manifest 都进入 GC
可达集合，只有永久删除对象版本后，不再被引用的 Part 才可物理回收。

完整 Header、Query、XML、错误和已知差异见
[s3-compatibility.md](s3-compatibility.md)。对象 GET/HEAD/PUT 支持 ETag 和 HTTP 日期条件请求，S3 API 不经过 Go Admin。

POST Policy Upload 使用表单中的 `key`、`policy`、`x-amz-algorithm`、`x-amz-credential`、
`x-amz-date` 和 `x-amz-signature` 完成 SigV4 Policy 验证，`file` 必须是最后一个字段。
支持 `Content-Type`、`Content-MD5`、`x-amz-checksum-crc64nvme`、`x-amz-meta-*`、
`content-length-range` 和 `success_action_status`；策略过期、条件不满足、校验和失败或
multipart 解析失败均不会发布对象。

请求和响应约束：

- `PutObject`、`UploadPart` 支持 `Content-MD5`、固定 SHA-256 和 `CRC32`、`CRC32C`、
  `CRC64NVME`、`SHA1`、`SHA256` Flexible Checksum；checksum Header 使用标准 Base64。
- `STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER` 还需要 `Content-Encoding: aws-chunked`、
  `x-amz-decoded-content-length` 和 `x-amz-trailer`，服务端在发布 Object/Part 前验证完整签名链。
- `DeleteObjects` 请求体使用 `<Delete>` 根元素，最多 1000 个 `<Object><Key>...</Key></Object>`，
  必须提供正确的 `Content-MD5` 或一个 Flexible Checksum Header，成功返回 `200` XML；批量
  `VersionId` 尚未实现。
- ETag 始终是带双引号的 opaque 字符串；Multipart ETag 使用 `"<md5>-<part-count>"` 形式，
  客户端不得去掉引号或将其当作安全摘要。
- 条件请求使用 `If-Match`、`If-None-Match`、`If-Modified-Since`、`If-Unmodified-Since`；
  GET/HEAD 未变化返回 `304`，写入前置条件失败返回 `412 PreconditionFailed`。
- 临时凭证必须携带 `x-amz-security-token`，该 Header 或 Presigned Query 参数必须参与 SigV4 签名。
- 版本化 Bucket 的 Put/Copy/Multipart Complete 返回 `x-amz-version-id`；CopyObject 可在
  `x-amz-copy-source` 中指定 `versionId`，成功时返回 `x-amz-copy-source-version-id`。普通删除按状态创建
  DeleteMarker，带 `versionId` 的删除永久移除指定版本。Lifecycle Scanner 周期由
  `s3.lifecycle_scan_interval_seconds` 配置。

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

S3 响应同时返回 `X-Amz-Request-Id`；S3 XML 错误中的 `RequestId` 与该值一致。稳定错误码、
HTTP 状态和重试边界以 [s3-compatibility.md](s3-compatibility.md) 的错误章节为准。
