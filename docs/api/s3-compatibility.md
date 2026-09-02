# S3/Data API 兼容矩阵

本文档是 ZigFS 文件操作接口和多语言 SDK 的能力清单。当前所有操作均处于 `Planned`，尚未实现 HTTP Handler。

## Bucket

| Operation | Method/Request | 状态 | SDK |
|---|---|---|---|
| CreateBucket | `PUT /{bucket}` | Planned | 是 |
| HeadBucket | `HEAD /{bucket}` | Planned | 是 |
| ListBuckets | `GET /` | Planned | 是 |
| ListObjectsV2 | `GET /{bucket}?list-type=2` | Planned | 是 |
| DeleteBucket | `DELETE /{bucket}` | Planned | 是 |

## Object

| Operation | Method/Request | 状态 | SDK |
|---|---|---|---|
| PutObject | `PUT /{bucket}/{key}` | Planned | 是，流式上传 |
| GetObject | `GET /{bucket}/{key}` | Planned | 是，流式下载 |
| HeadObject | `HEAD /{bucket}/{key}` | Planned | 是 |
| DeleteObject | `DELETE /{bucket}/{key}` | Planned | 是 |
| Range GetObject | `GET` + `Range` | Planned | 是 |
| Conditional Get/Head | `If-Match` 等 Header | Planned | 是 |

## Multipart

| Operation | Method/Request | 状态 | SDK |
|---|---|---|---|
| CreateMultipartUpload | `POST ?uploads` | Planned | 是 |
| UploadPart | `PUT ?partNumber=&uploadId=` | Planned | 是 |
| ListParts | `GET ?uploadId=` | Planned | 是 |
| CompleteMultipartUpload | `POST ?uploadId=` | Planned | 是 |
| AbortMultipartUpload | `DELETE ?uploadId=` | Planned | 是 |

## 鉴权与访问

| 能力 | 状态 | 说明 |
|---|---|---|
| AWS Signature Version 4 | Planned | Header 与 Query 签名 |
| Presigned URL | Planned | PUT/GET |
| Temporary Credentials | Planned | 移动端和 Web 优先使用 |
| Content-MD5 | Planned | 仅用于协议兼容与完整性 |
| SHA-256 Checksum | Planned | SigV4 与完整性校验 |

AK/SK 的创建、禁用、删除和 Policy 配置不属于本接口，见 ZigFS Management API。
