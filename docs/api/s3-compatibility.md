# S3/Data API 兼容矩阵

- **版本：** V1 Draft 0.2
- **更新日期：** 2026-09-03
- **默认 Endpoint：** `http://127.0.0.1:9000`
- **默认 Region：** `us-east-1`

本文是 ZigFS 文件操作接口和后续多语言 SDK 的能力事实来源。`Implemented`
表示 Handler、鉴权、持久化和 Zig 原生 TCP 回归测试已完成；外部客户端实测状态单独列出。

## 请求模型

- 当前只支持 Path-style：`/{bucket}/{object}`。
- 当前只支持 Signature V4 Authorization Header，不支持 Presigned Query。
- Credential Scope Service 固定为 `s3`，Region 必须等于 YAML `s3.region`。
- 必须提供 `Host`、`X-Amz-Date`、`X-Amz-Content-Sha256` 和 `Authorization`。
- 默认允许 900 秒时钟偏差，可通过 `s3.request_time_skew_seconds` 配置为 60 至 3600 秒。
- `x-amz-*` 扩展 Header 除 `x-amz-content-sha256` 外必须进入 `SignedHeaders`。
- 支持固定 SHA-256 Hex 和 `UNSIGNED-PAYLOAD`；AWS streaming chunk signature 尚不支持。
- Bucket、Object 和 Credential 状态均由 ZigFS 自有 Metadata Engine 持久化，不依赖数据库。

## Bucket

| Operation | Method/Request | 状态 | 成功响应 | 权限 |
|---|---|---|---|---|
| ListBuckets | `GET /` | Implemented | `200` XML | Bucket Read |
| CreateBucket | `PUT /{bucket}` | Implemented | `200` + `Location` | Bucket Write |
| HeadBucket | `HEAD /{bucket}` | Implemented | `200`，无 Body | Bucket Read |
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
| `fetch-owner` | `false` 或缺失；`true` 返回 `NotImplemented` |

响应包含 `Name`、`Prefix`、`KeyCount`、`MaxKeys`、`IsTruncated`、`Contents`、
`CommonPrefixes` 和按需返回的 Continuation 字段。排序使用 Object Key byte order。

## Object

| Operation | Method/Request | 状态 | 成功响应 | 权限 |
|---|---|---|---|---|
| PutObject | `PUT /{bucket}/{key}` | Implemented | `200` + quoted MD5 `ETag` | Object Write |
| GetObject | `GET /{bucket}/{key}` | Implemented | `200` + 流式 Body | Object Read |
| HeadObject | `HEAD /{bucket}/{key}` | Implemented | `200`，无 Body | Object Read |
| DeleteObject | `DELETE /{bucket}/{key}` | Implemented | `204`，幂等 | Object Write |
| Range GetObject | `Range: bytes=...` | Phase 5 | `501 NotImplemented` | - |
| Conditional Get/Head | `If-Match` 等 | Phase 5 | `501 NotImplemented` | - |
| CopyObject | `X-Amz-Copy-Source` | Not Supported | `501 NotImplemented` | - |

PutObject：

- 请求和磁盘写入均为固定缓冲流式处理。
- `Content-Type` 缺失时使用 `application/octet-stream`。
- `Content-MD5` 可选；非法、重复或不匹配分别返回稳定 Digest 错误。
- 固定 `X-Amz-Content-Sha256` 会在流式落盘时再次校验，不能只信任签名 Header。
- `x-amz-meta-*` 名称规范化为小写并持久化；重复名称和超限元数据被拒绝。

GetObject/HeadObject 返回 `Content-Type`、`Content-Length`、`ETag`、`Last-Modified`、
用户元数据、`X-Amz-Request-Id` 和 `X-Request-ID`。当前不宣告 `Accept-Ranges`。

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
`AuthorizationHeaderMalformed`、`RequestTimeTooSkewed`、`NoSuchBucket`、`NoSuchKey`、
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
| Range 与条件请求 | Phase 5，当前 Header 返回 `NotImplemented` |
| Presigned GET/PUT | Phase 5，当前无 Authorization Header 时返回 `AccessDenied` |
| Temporary Credentials / Session Token | 后续阶段，当前返回 `NotImplemented` 或鉴权失败 |
| AWS streaming chunk signature/trailer checksum | Phase 5，当前返回 `NotImplemented` |
| Virtual-hosted-style | 未声明支持，只使用 Path-style |
| S3 Object Versioning、ACL、Tagging、Copy、Select | V1 非当前范围 |

## 验证矩阵

| 客户端/测试 | 状态 | 覆盖 |
|---|---|---|
| Zig 原生环回 TCP Contract Test | Pass | 未签名、错误/过期签名、Policy、禁用 Credential、Bucket/Object CRUD、Digest、Header、XML、List V2 分页 |
| AWS 官方 S3 SigV4 GET Object 向量 | Pass | Canonical Request、Scope、HMAC-SHA256，签名 `67fe34c...2722900` |
| AWS SDK | Pending environment | 当前开发环境未安装，Phase 4 Gate 剩余项 |
| MinIO Client (`mc`) | Pending environment | 当前开发环境未安装，Phase 4 Gate 剩余项 |
| rclone | Pending environment | 当前开发环境未安装，Phase 4 Gate 剩余项 |

AK/SK 的创建、禁用、删除和 Policy 配置不属于 S3/Data API；它们是 ZigFS
Management API。文件 SDK 只建立在本文声明的 S3 操作之上，不包含管理操作。
