# S3/Data API 兼容矩阵

- **版本：** V1 Draft 0.7
- **更新日期：** 2026-09-03
- **默认 Endpoint：** `http://127.0.0.1:9000`
- **默认 Region：** `us-east-1`

本文是 ZigFS 文件操作接口和后续多语言 SDK 的能力事实来源。`Implemented`
表示 Handler、鉴权、持久化和 Zig 原生 TCP 回归测试已完成；外部客户端实测状态单独列出。

## 请求模型

- 当前只支持 Path-style：`/{bucket}/{object}`。
- Bucket API 使用 Signature V4 Authorization Header；对象级 GET/PUT 同时支持 Header 和 Presigned Query。
- Credential Scope Service 固定为 `s3`，Region 必须等于 YAML `s3.region`。
- Header 鉴权必须提供 `Host`、`X-Amz-Date`、`X-Amz-Content-Sha256` 和 `Authorization`；Presigned Query 只要求请求携带其 `SignedHeaders` 中声明的 Header。
- 默认允许 900 秒时钟偏差，可通过 `s3.request_time_skew_seconds` 配置为 60 至 3600 秒。
- Presigned URL 的 `X-Amz-Expires` 必须为 `1..604800` 秒；未来时间沿用上述偏差窗口，超过有效期立即拒绝。
- Presigned URL 必须包含 Algorithm、Credential、Date、Expires、SignedHeaders 和 Signature；签名绑定 Method、完整 Path、全部 Query 和声明的 Header。
- 同一请求不能同时携带 Authorization Header 和 Presigned Query；Presigned Query 当前只授权对象级 GET/PUT。
- `x-amz-*` 扩展 Header 除 `x-amz-content-sha256` 外必须进入 `SignedHeaders`。
- 支持固定 SHA-256 Hex、`UNSIGNED-PAYLOAD` 和 `STREAMING-AWS4-HMAC-SHA256-PAYLOAD`；带 trailer 的 streaming 变体尚不支持。
- PutObject 支持 AWS Flexible Checksums 的 `CRC64NVME` Header 模式；校验值参与 SigV4 并在流式落盘时重新计算。
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
| GetObject | `GET /{bucket}/{key}` | Implemented | `200` + 流式 Body | Object Read |
| HeadObject | `HEAD /{bucket}/{key}` | Implemented | `200`，无 Body | Object Read |
| DeleteObject | `DELETE /{bucket}/{key}` | Implemented | `204`，幂等 | Object Write |
| DeleteObjects | `POST /{bucket}?delete=` | Implemented | `200` XML，逐项 `Deleted`/`Error` | Object Write |
| Range GetObject | `Range: bytes=...` | Implemented | `206` + `Content-Range` | Object Read |
| Presigned PutObject | `PUT /{bucket}/{key}?X-Amz-*` | Implemented | 与 PutObject 相同 | Object Write |
| Presigned GetObject | `GET /{bucket}/{key}?X-Amz-*` | Implemented | 与 GetObject 相同 | Object Read |
| Conditional Get/Head | `If-Match` 等 | Phase 5 | `501 NotImplemented` | - |
| CopyObject | `X-Amz-Copy-Source` | Not Supported | `501 NotImplemented` | - |

PutObject：

- 请求和磁盘写入均为固定缓冲流式处理。
- `Content-Type` 缺失时使用 `application/octet-stream`。
- `Content-MD5` 可选；非法、重复或不匹配分别返回稳定 Digest 错误。
- 固定 `X-Amz-Content-Sha256` 会在流式落盘时再次校验，不能只信任签名 Header。
- 支持 `x-amz-sdk-checksum-algorithm: CRC64NVME` 与 `x-amz-checksum-crc64nvme`；值必须是 8-byte 大端 checksum 的标准 Base64，错误值返回 `BadDigest`，成功响应回写同一 checksum Header。
- `STREAMING-AWS4-HMAC-SHA256-PAYLOAD` 按 aws-chunked 帧逐 chunk 验签，校验签名链和 `x-amz-decoded-content-length`；失败的流不会发布对象。
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

Presigned GET/PUT：

- Canonical Request 的 Payload 使用 S3 标准 `UNSIGNED-PAYLOAD`；PUT 仍会验证显式提供的 Content-MD5 或受支持 checksum。
- AK/SK 当前状态和 Policy 在每次请求时由 ZigFS Credential Service 查询；禁用凭证或权限不足的 URL 即使未过期也会被拒绝。
- 缺失、重复、非法或超过 7 天的鉴权参数返回 `AuthorizationQueryParametersError`；签名篡改返回 `SignatureDoesNotMatch`，过期返回 `AccessDenied` 和 `Request has expired.`。
- `auth/sigv4.zig` 提供内部 Presigned GET/PUT 生成器；Phase 6 的 Management Presign API 将复用该实现，不建立第二套签名协议。

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

已映射错误码：`AccessDenied`、`InvalidAccessKeyId`、`SignatureDoesNotMatch`、
`AuthorizationHeaderMalformed`、`AuthorizationQueryParametersError`、`RequestTimeTooSkewed`、`NoSuchBucket`、`NoSuchKey`、
`BucketAlreadyExists`、`BucketAlreadyOwnedByYou`、`BucketNotEmpty`、`InvalidBucketName`、
`InvalidRequest`、`InvalidArgument`、`InvalidLocationConstraint`、`MalformedXML`、
`InvalidDigest`、`BadDigest`、`XAmzContentSHA256Mismatch`、`NotImplemented`、
`ServiceUnavailable` 和 `InternalError`。

错误响应不包含数据根目录、内部 Record 路径、Zig 类型或堆栈。HEAD 错误只返回状态与
Request ID Header，不返回 XML Body。

## 尚未实现

| 能力 | 阶段/行为 |
|---|---|
| Multipart Upload 全生命周期 | Phase 5，当前路由返回 `NotImplemented` |
| 条件请求 | Phase 5，当前 Header 返回 `NotImplemented` |
| Multi-Range | V1 当前不支持，返回 `416 InvalidRange` |
| Temporary Credentials / Session Token | 后续阶段，当前返回 `NotImplemented` 或鉴权失败 |
| S3 POST Policy Upload | 非 Presigned PUT；`mc share upload` 使用此协议，当前未实现 |
| AWS streaming signed trailer / trailer checksum | Phase 5 扩展项，当前返回 `NotImplemented` |
| Virtual-hosted-style | 未声明支持，只使用 Path-style |
| S3 Object Versioning、ACL、Tagging、Copy、Select | V1 非当前范围 |

## 验证矩阵

| 客户端/测试 | 状态 | 覆盖 |
|---|---|---|
| Zig 原生环回 TCP Contract Test | Pass | 未签名、错误/过期签名、Policy、禁用 Credential、Bucket/Object CRUD、Digest、Header、XML、List V2 分页、Presigned GET/PUT、Method/Query 篡改和过期拒绝 |
| AWS 官方 S3 SigV4 GET Object 向量 | Pass | Canonical Request、Scope、HMAC-SHA256，签名 `67fe34c...2722900` |
| AWS CLI 2.36.38 | Pass | 错误 AK、Bucket/Object CRUD、特殊 Key、List V2/Delimiter/分页、Content-Type、ETag、CRC64NVME、错误 checksum、单 Range `206` 与越界 `416`、独立生成 Presigned GET 及字节一致性 |
| MinIO Client (`mc`) 2025-08-13 | Pass | Alias、Bucket CRUD、Location、List V2、Head/Get、带空格 Key、签名流式 Put、下载字节一致性、DeleteObjects 和 `mc share download` Presigned GET；`mc share upload` 使用未实现的 POST Policy，不等同于 Presigned PUT |
| rclone 1.75.0 | Pass with config | `list_version=2` 下 Bucket/Object CRUD、特殊 Key、Metadata、MD5、下载字节一致性和 `rclone link` Presigned GET 通过；`provider=Other` 默认 ListObjects V1，不在当前兼容范围 |
| AWS SDK | Pending environment | 当前只安装 AWS CLI，尚未安装独立 SDK 测试运行时 |

AK/SK 的创建、禁用、删除和 Policy 配置不属于 S3/Data API；它们是 ZigFS
Management API。文件 SDK 只建立在本文声明的 S3 操作之上，不包含管理操作。
