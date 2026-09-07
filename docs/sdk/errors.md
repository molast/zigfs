# 文件 SDK 错误模型

- **契约版本：** V1.0
- **更新日期：** 2026-09-07

所有语言实现必须提供等价的结构化错误：

```text
ZigFSError
  code: String
  message: String
  httpStatus: Integer?
  requestId: String?
  resource: String?
  retryable: Boolean
  cause: PlatformError?
```

S3 XML `Code`、`Message`、`Resource` 和 `RequestId` 原样保留；Header 中存在
`X-Amz-Request-Id` 时也应保留。解析失败不能丢掉 HTTP Status 和平台底层错误。
Secret Key、Authorization、Cookie、完整 Presigned Query 和请求 Body 不得进入错误描述。

## 稳定分类

| 分类 | 典型 S3 Code/场景 | 默认可重试 |
|---|---|---|
| Authentication | `AccessDenied`、`InvalidAccessKeyId`、`InvalidToken`、`ExpiredToken`、`SignatureDoesNotMatch` | 否 |
| Validation | `InvalidArgument`、`InvalidRequest`、`BadDigest`、`InvalidRange`、`EntityTooSmall`、`EntityTooLarge` | 否 |
| Not Found | `NoSuchBucket`、`NoSuchKey`、`NoSuchUpload` | 否 |
| Conflict | `BucketAlreadyExists`、`BucketNotEmpty`、`InvalidPartOrder` | 否 |
| Unsupported | `NotImplemented` | 否 |
| Service | `ServiceUnavailable`、`InternalError` 或 HTTP `5xx` | 仅满足重试前提时 |
| Transport | DNS、连接、TLS、超时、断流 | 仅满足重试前提时 |
| Cancelled | 调用方取消 | 否 |

`NotImplemented` 即使是 HTTP `501` 也不可重试。未知 S3 Code 仍返回 `ZigFSError`，保留原始 Code。实现不得只凭 Code 判定可重试；还要
检查操作幂等性、Body 是否可重放、响应 Body 是否已交付以及取消状态。

## 重试约束

- 默认最多 3 次尝试，使用带随机扰动的指数退避，并允许调用方关闭或替换策略。
- `GET`、`HEAD`、List 和幂等 Delete 在响应未交付时可重试临时网络错误与 `5xx`。
- PutObject/UploadPart 只有在输入流可重新打开且响应未开始时才可重试。
- CreateMultipart 和 CompleteMultipart 结果不明确时必须先查询/对账，不能盲目重放。
- 响应字节已交付后不能透明地从头重试；Range 续传由上层使用已确认 Offset 发起。
- 调用方取消、认证失败、校验错误和明确的 `4xx` 不自动重试。
- `Retry-After` 合法时优先使用，但仍受调用方最大等待时间限制。

共享重试判定 Case 位于 `conformance/fixtures/v1.json`，所有目标语言必须得到相同期望。
