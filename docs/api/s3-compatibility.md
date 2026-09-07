# S3/Data API 兼容矩阵

- **版本：** V1 Draft 1.1
- **更新日期：** 2026-09-07
- **默认 Endpoint：** `http://127.0.0.1:9000`
- **默认 Region：** `us-east-1`

本文是 ZigFS 文件操作接口和后续多语言 SDK 的能力事实来源。`Implemented`
表示 Handler、鉴权、持久化和 Zig 原生 TCP 回归测试已完成；外部客户端实测状态单独列出。
AWS S3 操作的全量盘点和未实现边界见 [s3-api-coverage.md](s3-api-coverage.md)。

## 外部客户端回归

Phase 9 的可重复 Runner 位于 [`compatibility/README.md`](../../compatibility/README.md)，
运行 `./compatibility/run.sh` 会隔离启动 ZigFS、通过 Management API 签发临时凭证，并输出
`phase9-compatibility-v1` JSON/Markdown 报告。当前环境实测版本为 AWS CLI 2.36.38、MinIO
Client 2025-08-13、rclone 1.75.0 和 Node 24 原生 HTTP。

Runner 实际执行并校验字节内容；原生 HTTP Runner 另外覆盖 Multipart，AWS CLI、mc 和 rclone
的多 Part 大文件基线保留在 Phase 5 历史矩阵中。客户端没有稳定入口的 POST Policy、signed streaming Trailer
checksum，以及 AWS CLI 自动附加但 ZigFS 当前未声明的 DeleteObjects checksum 变体，会明确记为
`Unsupported`，不计作 `Passed`；真正的协议、状态码或内容错误记为 `Failed`。独立官方 AWS SDK
运行时可选；当前 Ruby `aws-sdk-s3` 已由 Compatibility Runner 作为独立验证工具覆盖，
未安装时才记为 `Skipped`。

## 请求模型

- 默认使用 Path-style：`/{bucket}/{object}`。配置 `s3.virtual_hosted_style: true` 后，
  同时支持 Virtual-hosted-style：`Host: {bucket}.{s3.public_endpoint authority}`、
  `/{object}`；精确 `s3.public_endpoint authority` 仍支持 Path-style。
- Bucket API 使用 Signature V4 Authorization Header；对象级 GET/PUT 同时支持 Header 和 Presigned Query。
- Credential Scope Service 固定为 `s3`，Region 必须等于 YAML `s3.region`。
- Header 鉴权必须提供 `Host`、`X-Amz-Date`、`X-Amz-Content-Sha256` 和 `Authorization`；Presigned Query 只要求请求携带其 `SignedHeaders` 中声明的 Header。
- 默认允许 900 秒时钟偏差，可通过 `s3.request_time_skew_seconds` 配置为 60 至 3600 秒。
- Presigned URL 的 `X-Amz-Expires` 必须为 `1..604800` 秒；未来时间沿用上述偏差窗口，超过有效期立即拒绝。
- Presigned URL 必须包含 Algorithm、Credential、Date、Expires、SignedHeaders 和 Signature；签名绑定 Method、完整 Path、全部 Query 和声明的 Header。
- 临时凭证使用 AK/SK/Session Token：Header 请求必须携带并签名 `x-amz-security-token`，Presigned URL 必须携带签名绑定的 `X-Amz-Security-Token`；永久凭证携带 Token 同样被拒绝。
- 同一请求不能同时携带 Authorization Header 和 Presigned Query；Presigned Query 当前只授权对象级 GET/PUT。
- `x-amz-*` 扩展 Header 除 `x-amz-content-sha256` 外必须进入 `SignedHeaders`。
- 支持固定 SHA-256 Hex、`UNSIGNED-PAYLOAD`、`STREAMING-AWS4-HMAC-SHA256-PAYLOAD` 和带五种 Flexible Checksum trailer 的 `STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER`。
- PutObject 和 UploadPart 支持 AWS Flexible Checksums 的 `CRC32`、`CRC32C`、`CRC64NVME`、`SHA1`、`SHA256` Header 与 signed trailer 模式；校验值参与 SigV4 并在 staged 流式落盘时重新计算。
- Bucket、Object 和 Credential 状态均由 ZigFS 自有 Metadata Engine 持久化，不依赖数据库。

## Bucket

| Operation | Method/Request | 状态 | 成功响应 | 权限 |
|---|---|---|---|---|
| ListBuckets | `GET /` | Implemented | `200` XML | Bucket Read |
| CreateBucket | `PUT /{bucket}` | Implemented | `200` + `Location` | Bucket Write |
| HeadBucket | `HEAD /{bucket}` | Implemented | `200`，无 Body | Bucket Read |
| GetBucketLocation | `GET /{bucket}?location=` | Implemented | `200` XML | Bucket Read |
| DeleteBucket | `DELETE /{bucket}` | Implemented | `204` | Bucket Write |
| ListObjectsV2 | `GET /{bucket}?list-type=2` | Implemented | `200` XML | Object Read |

CreateBucket 规则：

- `us-east-1` Endpoint 使用空 Body；提供 LocationConstraint 会返回 `InvalidLocationConstraint`。
- 其他 Region 必须提供匹配的 `CreateBucketConfiguration/LocationConstraint` XML。
- 同 Owner 在 `us-east-1` 重复创建保持 `200` 幂等；其他 Region 返回 `BucketAlreadyOwnedByYou`。
- 同名 Bucket 已属于其他 Owner 时返回 `BucketAlreadyExists`。

ListObjectsV2 已支持：

| Query | 规则 |
|---|---|
| `list-type` | 必须且只能为 `2` |
| `prefix` | 可选，最长 1024 bytes |
| `delimiter` | 可选，空值等同未设置 |
| `max-keys` | `0..1000`，默认 `1000` |
| `start-after` | 可选；有 Continuation Token 时 Token 优先 |
| `continuation-token` | `ZFCT` V1.0，不透明、URL-safe、绑定 Bucket/Prefix/Delimiter |
| `encoding-type` | 可选，只接受 `url` |
| `fetch-owner` | 可选，只接受 `true` 或 `false`；`true` 时每个 Contents 返回 Owner |

响应包含 `Name`、`Prefix`、`KeyCount`、`MaxKeys`、`IsTruncated`、`Contents`、
`CommonPrefixes` 和按需返回的 Continuation 字段。排序使用 Object Key byte order。

## Object

| Operation | Method/Request | 状态 | 成功响应 | 权限 |
|---|---|---|---|---|
| PutObject | `PUT /{bucket}/{key}` | Implemented | `200` + quoted MD5 `ETag`，按需返回 checksum | Object Write |
| POST Policy Upload | `POST /{bucket}` + `multipart/form-data` | Implemented | `201` XML、`200`/`204` 空响应，按 `success_action_status` | Object Write |
| GetObject | `GET /{bucket}/{key}` | Implemented | `200` + 流式 Body | Object Read |
| HeadObject | `HEAD /{bucket}/{key}` | Implemented | `200`，无 Body | Object Read |
| DeleteObject | `DELETE /{bucket}/{key}` | Implemented | `204`，幂等 | Object Write |
| DeleteObjects | `POST /{bucket}?delete=` | Implemented | `200` XML，逐项 `Deleted`/`Error` | Object Write |
| Range GetObject | `Range: bytes=...` | Implemented | `206` + `Content-Range` | Object Read |
| Presigned PutObject | `PUT /{bucket}/{key}?X-Amz-*` | Implemented | 与 PutObject 相同 | Object Write |
| Presigned GetObject | `GET /{bucket}/{key}?X-Amz-*` | Implemented | 与 GetObject 相同 | Object Read |
| Presigned DeleteObject | `DELETE /{bucket}/{key}?X-Amz-*` | Implemented | 与 DeleteObject 相同 | Object Write |
| Conditional Get/Head/Put | `If-Match`、`If-None-Match`、日期条件 | Implemented | `304`/`412`，按条件返回 | Object Read/Write |
| CopyObject | `PUT /{bucket}/{key}` + `X-Amz-Copy-Source` | Implemented | `200` `CopyObjectResult` XML | Object Read + Object Write |

## Multipart Upload

| Operation | Method/Request | 状态 | 成功响应 | 权限 |
|---|---|---|---|---|
| CreateMultipartUpload | `POST /{bucket}/{key}?uploads=` | Implemented | `200` XML + `UploadId` | Object Write |
| UploadPart | `PUT /{bucket}/{key}?partNumber=N&uploadId=ID` | Implemented | `200` + quoted MD5 `ETag` | Object Write |
| ListParts | `GET /{bucket}/{key}?uploadId=ID` | Implemented | `200` XML | Object Read |
| CompleteMultipartUpload | `POST /{bucket}/{key}?uploadId=ID` | Implemented | `200` XML + composite `ETag` | Object Write |
| AbortMultipartUpload | `DELETE /{bucket}/{key}?uploadId=ID` | Implemented | `204` | Object Write |

- Upload ID 是随机 UUID V4 的 32 位小写 Hex 表示，不包含 Bucket、Key 或磁盘路径。
- Part Number 范围为 `1..10000`；每个 Part 使用固定缓冲流式落盘并保存 Size、MD5 ETag、SHA-256、LastModified、Data Generation 和提交状态。同一 Part Number 可原子覆盖，并发上传由 Upload 级锁串行提交元数据。
- UploadPart 支持固定 SHA-256、`Content-MD5`、五种 Flexible Checksum Header，以及无 trailer/五种 signed trailer 两种 AWS streaming chunk signature；错误 checksum 或签名不发布 Part。
- ListParts 支持 `part-number-marker` 和 `max-parts=0..1000`，默认 `1000`，按 Part Number 升序返回。
- Complete XML 接受 `ETag`/`PartNumber` 两种字段顺序，并兼容 rclone 的 XML 实体引号。请求 Part 必须升序、无重复、存在且 ETag 一致；除最后一个提交 Part 外，每个 Part 至少 5 MiB。
- Complete 使用固定缓冲把已选 Part 拼接为普通 Object Generation，并复用 Object Metadata CAS 与原子发布流程。最终 ETag 为 `MD5(concat(binary_part_md5))-part_count`。
- Complete 或 Abort 成功后，Upload Metadata 提交 Tombstone，再清理整个 Upload 数据目录，不会删除或修改此前已完成的对象。
- 启动时清理已提交 Tombstone 的残留 Part，并按 `s3.multipart_expiry_seconds` 清理超时未完成上传；默认 7 天，允许 60 秒至 30 天。
- Multipart 当前只接受 Signature V4 Header 鉴权；对象级 Presigned GET/PUT 不扩大为 Presigned Multipart。

PutObject：

- 请求和磁盘写入均为固定缓冲流式处理。
- `Content-Type` 缺失时使用 `application/octet-stream`。
- `Content-MD5` 可选；非法、重复或不匹配分别返回稳定 Digest 错误。
- 固定 `X-Amz-Content-Sha256` 会在流式落盘时再次校验，不能只信任签名 Header。
- 支持 `x-amz-sdk-checksum-algorithm` 与对应的 `x-amz-checksum-crc32`、`x-amz-checksum-crc32c`、`x-amz-checksum-crc64nvme`、`x-amz-checksum-sha1`、`x-amz-checksum-sha256`；CRC 值使用大端字节、SHA 值使用原始摘要字节并统一采用标准 Base64，错误值返回 `BadDigest`，成功响应回写同一 checksum Header。
- `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` 按 aws-chunked 帧逐 chunk 验签，校验签名链和 `x-amz-decoded-content-length`；失败的流不会发布对象。
- `STREAMING-AWS4-HMAC-SHA256-PAYLOAD-TRAILER` 要求 `Content-Encoding: aws-chunked`、`x-amz-decoded-content-length` 和对应的 `x-amz-trailer`；`x-amz-sdk-checksum-algorithm` 存在时必须与 Trailer 算法一致，缺失时从 Trailer Header 名称推断以保持既有 CRC64NVME 客户端兼容。ZigFS 在最终 EOF 前同时验证 chunk 签名链、`AWS4-HMAC-SHA256-TRAILER` 签名和声明的五种 checksum。
- Trailer 签名失败返回 `SignatureDoesNotMatch`，checksum 不匹配返回 `BadDigest`，非法 framing/trailer 返回 `InvalidRequest`；任何失败均不发布 Object/Part，成功响应回写已验证的同名 `x-amz-checksum-*`。
- `x-amz-meta-*` 名称规范化为小写并持久化；重复名称和超限元数据被拒绝。

DeleteObjects：

- 请求体上限 2 MiB，每批最多 1000 个 Object Key，必须携带正确的 `Content-MD5`。
- 支持 XML Namespace、XML Entity 和 `Quiet=true/false`；兼容 mc 的 Quiet-before-Object 编码。
- 每项复用 DeleteObject 的幂等 Tombstone 与延迟 GC 语义，非 Quiet 响应返回逐项结果。

GetObject/HeadObject 返回 `Content-Type`、`Content-Length`、`ETag`、`Last-Modified`、
用户元数据、`Accept-Ranges: bytes`、`X-Amz-Request-Id` 和 `X-Request-ID`。

Range GetObject 支持 `bytes=start-end`、`bytes=start-` 和 `bytes=-suffix` 单范围语义。
响应按对象长度截断 end，返回 `206`、`Content-Range` 和范围长度；空对象、越界、倒序、
零长度 suffix 与 Multi-Range 返回 `416 InvalidRange` 及 `Content-Range: bytes */size`。

Conditional Requests：

- `If-Match` 和 `If-None-Match` 接受一个或多个带引号的 ETag，也接受 `*`；If-Match 使用强比较，If-None-Match 允许 `W/` 弱标记。
- GET/HEAD 的 If-None-Match 命中或 If-Modified-Since 表示资源未变化时返回 `304 Not Modified`，Body 为空并保留 ETag 与 Last-Modified Header。
- GET/HEAD/PUT 的 If-Match、If-Unmodified-Since 不满足时返回 `412 PreconditionFailed`；PUT 的 If-None-Match 命中时同样返回 `412`。
- If-Match 优先于 If-Unmodified-Since，If-None-Match 优先于 If-Modified-Since；日期使用 RFC 7231 IMF-fixdate（GMT，秒精度）。
- 条件 PUT 在读取请求 Body 前先检查当前对象，并把观察到的 Metadata Generation 绑定到最终提交 CAS；并发覆盖会返回 `412`，不会发布新 Object。
- 缺失对象上的 `If-None-Match: *` 可创建对象；缺失对象上的 If-Match 不满足条件。

CopyObject：

- 使用 `PUT /{target-bucket}/{target-key}` 和 `x-amz-copy-source`（`/source-bucket/source-key` 或 `source-bucket/source-key`）；源路径严格 Percent Decode，兼容带或不带前导 `/` 的 AWS/MinIO 表示，源对象与目标对象都必须属于当前凭证 Owner。
- CopyObject 同时要求 Object Read（源）和 Object Write（目标）权限。源对象不存在返回 `NoSuchKey`，源 Bucket 不存在返回 `NoSuchBucket`；请求携带 Body、非法源路径或重复源 Header 返回 `InvalidRequest`/`InvalidArgument`。

POST Policy Upload：

- 使用 `POST /{bucket}`，请求必须是带 boundary 的 `multipart/form-data`，`file` 字段必须最后出现，文件内容通过固定缓冲直接进入 staged Object 流。
- 必需字段为 `key`、`policy`、`x-amz-algorithm`、`x-amz-credential`、`x-amz-date` 和 `x-amz-signature`；临时 Credential 还必须携带 `x-amz-security-token`。Policy 使用 `AWS4-HMAC-SHA256` 派生密钥直接签名 Base64 Policy。
- Policy `expiration` 使用 UTC ISO-8601；支持对象精确条件、`eq`、`starts-with` 和 `content-length-range`。Bucket 条件绑定 URL Bucket，`key` 在校验前展开 `${filename}`。
- 支持 `Content-Type`、`Content-MD5`、`x-amz-checksum-crc64nvme`、`x-amz-meta-*` 和 `success_action_status=200|201|204`。ACL、redirect、其他 checksum 或未识别表单字段返回 `NotImplemented`。
- 策略过期、条件/签名/Session Token/校验和失败、文件大小越界、断流或非法 multipart 均不会发布 Object；`201` 返回标准 `PostResponse` XML，默认成功状态为 `204`。
- 默认 `x-amz-metadata-directive` 为 `COPY`，复制源对象的 Content-Type、用户元数据、大小、SHA-256 和 ETag（包括 multipart ETag）。`REPLACE` 使用目标请求的 Content-Type 和 `x-amz-meta-*`，对象字节和 checksum 仍由流式复制重新校验。
- 支持 `x-amz-copy-source-if-match`、`x-amz-copy-source-if-none-match`、`x-amz-copy-source-if-modified-since` 和 `x-amz-copy-source-if-unmodified-since`；条件不满足返回 `412 PreconditionFailed`。目标可使用普通 `If-*` 条件并绑定 Metadata Generation CAS。
- 复制使用固定缓冲区分段读取和暂存，不把完整源对象加载到内存；目标发布遵循普通 PutObject 的 fsync、Metadata Commit 和失败不发布语义。成功响应包含 `LastModified` 和带引号的 `ETag`。

连接中断：

- 固定 `Content-Length` 的 PutObject/UploadPart 会跟踪未读取字节，Body 收满前 EOF 返回 `400 InvalidRequest`。
- 中途断流不会发布 Object 或 Part，也不会遗留 `.zigfs/tmp/object-*.data` 或 `multipart-*.data`。
- GetObject 客户端在响应流中断开时，ZigFS 终止发送并释放当前 Generation 的 Read Lease；后续覆盖、删除和读取不会被该连接阻塞。

Presigned GET/PUT/DELETE：

- Canonical Request 的 Payload 使用 S3 标准 `UNSIGNED-PAYLOAD`；PUT 仍会验证显式提供的 Content-MD5 或受支持 checksum。
- AK/SK 当前状态、类型、硬过期时间和 Policy 在每次请求时由 ZigFS Credential Service 查询；临时凭证的 URL 不能超过 Credential 自身寿命，禁用、过期或权限不足的 URL 即使 Presigned Query 尚未过期也会被拒绝。
- Management Presign API 支持 `GET`、`PUT` 和 `DELETE`；Admin 对象详情、上传、下载和删除均通过短时效 URL 直连 S3/Data API，Admin 不转发对象字节。
- 缺失、重复、非法或超过 7 天的鉴权参数返回 `AuthorizationQueryParametersError`；签名篡改返回 `SignatureDoesNotMatch`，过期返回 `AccessDenied` 和 `Request has expired.`。
- `auth/sigv4.zig` 提供内部 Presigned GET/PUT/DELETE 生成器；Management Presign API 复用该实现，不建立第二套签名协议。

## 错误

除 HEAD 外，S3 错误使用 `application/xml`：

```xml
<Error>
  <Code>NoSuchKey</Code>
  <Message>The specified key does not exist.</Message>
  <Resource>/bucket/key</Resource>
  <RequestId>...</RequestId>
</Error>
```

已映射错误码：`AccessDenied`、`InvalidAccessKeyId`、`InvalidToken`、`ExpiredToken`、`SignatureDoesNotMatch`、
`AuthorizationHeaderMalformed`、`AuthorizationQueryParametersError`、`RequestTimeTooSkewed`、`NoSuchBucket`、`NoSuchKey`、
`BucketAlreadyExists`、`BucketAlreadyOwnedByYou`、`BucketNotEmpty`、`InvalidBucketName`、
`InvalidRequest`、`InvalidArgument`、`InvalidLocationConstraint`、`MalformedXML`、
`InvalidDigest`、`BadDigest`、`XAmzContentSHA256Mismatch`、`NoSuchUpload`、
`InvalidPart`、`InvalidPartOrder`、`EntityTooSmall`、`EntityTooLarge`、`NotImplemented`、
`PreconditionFailed`、`ServiceUnavailable` 和 `InternalError`。

错误响应不包含数据根目录、内部 Record 路径、Zig 类型或堆栈。HEAD 错误只返回状态与
Request ID Header，不返回 XML Body。

## 尚未实现

| 能力 | 阶段/行为 |
|---|---|
| Multi-Range | V1 当前不支持，返回 `416 InvalidRange` |
| DeleteObjects Flexible Checksum Header/Trailer | V1 当前只要求并验证 `Content-MD5`；客户端自动附加的 checksum 扩展返回 `501 NotImplemented` |
| S3 Object Versioning、ACL、Tagging、Select | V1 非当前范围 |

## 验证矩阵

| 客户端/测试 | 状态 | 覆盖 |
|---|---|---|
| Zig 原生环回 TCP Contract Test | Pass | 未签名、错误/过期签名、永久/临时 Credential、Session Token Header/Presigned 正反向、POST Policy（签名、条件、`${filename}`、状态码、大小限制、失败不发布）、禁用 Credential、Bucket/Object CRUD、Digest、五种 Flexible Checksum Header/Trailer、XML、List V2 分页、Conditional GET/HEAD/PUT（304/412、ETag/日期优先级、条件 PUT 不发布）、CopyObject（COPY/REPLACE、流式字节一致、标准 XML）、Virtual-hosted Header/Presigned SigV4 与 Host 拒绝、完整 Multipart 生命周期、五种 signed trailer 正向与失败不发布、Object/Part 中途断流清理、下载取消释放租约、稳定错误、Method/Query 篡改和过期拒绝 |
| AWS 官方 S3 SigV4 GET Object 向量 | Pass | Canonical Request、Scope、HMAC-SHA256，签名 `67fe34c...2722900` |
| Phase 9 Compatibility Runner / AWS CLI 2.36.38 | Pass with Unsupported variant | `compatibility/run.sh --client aws` 实测 Bucket/Object CRUD、List、Head、Get、Presigned GET、CopyObject；DeleteObjects 因 AWS CLI 自动附加服务端未声明的 checksum 变体明确记为 `Unsupported` |
| Phase 9 Compatibility Runner / MinIO Client (`mc`) 2025-08-13 | Pass with Unsupported coverage | `compatibility/run.sh --client mc` 实测 Bucket/Object CRUD、递归 List、Head/Get、签名流式 Put、DeleteObjects、Presigned GET、CopyObject；POST Policy 与 streaming checksum 变体无稳定 CLI 入口，记为 `Unsupported` |
| Phase 9 Compatibility Runner / rclone 1.75.0 | Pass with config | `list_version=2`、`force_path_style=true` 下实测 Bucket/Object CRUD、递归 List、内容校验、CopyObject 和清理；rclone 不生成 S3 SigV4 Presigned URL、无稳定 POST Policy/Trailer checksum CLI，均记为 `Unsupported` |
| Phase 9 Compatibility Runner / Node 24 HTTP | Pass with Unsupported coverage | 原生 SigV4 Header/Presigned、Bucket/Object/List、CopyObject、Multipart、DeleteObjects 和 SHA256 Flexible Checksum Header；Node fetch 无法构造 signed streaming Trailer，记为 `Unsupported` |
| TypeScript/Web Conformance | Pass | Web Crypto SigV4、Web Streams Put/Get、64 位 `bigint`、Range、List V2 Token、Multipart、Abort、错误映射和取消后继续访问 |
| Swift/iOS Conformance | Pass | CryptoKit SigV4、Foundation 文件/响应流、64 位 `UInt64`、Range、List V2 Token、Multipart、Abort、错误映射和取消后继续访问 |
| 独立 AWS SDK / signed trailer 外部扩展 | Phase 9 Additional coverage: Pass/Partial | Ruby `aws-sdk-s3` Bucket/Object/Copy/Delete 生命周期已通过；客户端 signed trailer 选择能力继续按各自 CLI 限制记录 |

AK/SK 的创建、禁用、删除和 Policy 配置不属于 S3/Data API；它们是 ZigFS
Management API。文件 SDK 只建立在本文声明的 S3 操作之上，不包含管理操作。
