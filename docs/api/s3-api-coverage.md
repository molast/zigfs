# AWS S3 API 全量覆盖清单

- **文档版本：** 0.1.0
- **更新日期：** 2026-09-07
- **适用服务版本：** ZigFS `0.1.0` / `v0.1.0-rc.1`
- **关联契约：** [S3/Data API 兼容矩阵](s3-compatibility.md)

本文回答一个明确问题：ZigFS 当前是否实现了 AWS S3 的全部 API。结论是：**没有**。
ZigFS 0.1 的目标是稳定的核心文件存储 API，不是 AWS S3 全部控制面和扩展能力的替代品。
本文覆盖 AWS S3 General Purpose Buckets 的常用 REST 操作，并把 S3 Express、Object Lambda
和 S3 Tables 等独立服务或专用能力明确列为范围外；后续新增 S3 能力必须先在这里登记，
再进入实现计划、契约和测试矩阵。

## 状态定义

| 状态 | 含义 |
|---|---|
| `Implemented` | ZigFS 有对应端点，V1 声明的请求、响应、鉴权、持久化和错误语义已实现并有测试。未列出的可选 AWS 扩展参数不因此自动获得支持。 |
| `Partial` | 有对应端点，但操作的核心语义或常用标准变体仍缺失；调用方必须按备注处理。 |
| `Not Implemented` | 属于可规划的标准 S3 操作，目前没有实现；应返回稳定的 `501 NotImplemented` 或对应未实现错误。 |
| `Out of Scope` | 控制面、云厂商托管能力、S3 专用集成或当前产品明确不纳入的能力；不作为 0.1 的交付条件。 |

`Implemented` 只表示“ZigFS V1 声明的兼容子集已完成”，不表示通过了该 AWS 操作的全部可选
Header、Query、权限模型或高级存储语义。参数级细节以兼容矩阵为准。

## 覆盖总览

| API 域 | V1 结论 |
|---|---|
| Service/Bucket 基础读写 | `Implemented`：ListBuckets、Create/Head/DeleteBucket、GetBucketLocation、ListObjectsV2。 |
| Object/List 核心文件操作 | `Implemented`：Put/Get/Head/Delete、DeleteObjects、CopyObject、单 Range 和 Browser POST；旧版 List、Versioning、ACL、Tagging 等仍有缺口。 |
| Multipart | `Implemented`：Create、UploadPart、ListParts、Complete、Abort；ListMultipartUploads 和 UploadPartCopy 未实现。 |
| Bucket 配置、治理和云集成 | `Out of Scope` 或 `Not Implemented`：见下方逐项清单。 |
| S3 Express、Object Lambda、S3 Tables | `Out of Scope`：这些是独立服务形态或专用集成，不属于 ZigFS 0.1 普通 S3 API。 |

## Service 与 Bucket API

### Service

| AWS 操作 | HTTP 形态 | 状态 | ZigFS 0.1 说明 |
|---|---|---|---|
| `ListBuckets` | `GET /` | `Implemented` | 返回当前凭证 Owner 可见的 Bucket。 |
| `ListDirectoryBuckets` | S3 Express 专用 | `Out of Scope` | ZigFS 是单数据根普通 S3 兼容服务，不提供 S3 Express Directory Bucket。 |

### Bucket 基础与权限

| AWS 操作 | HTTP 形态 | 状态 | ZigFS 0.1 说明 |
|---|---|---|---|
| `CreateBucket` | `PUT /{bucket}` | `Implemented` | 支持 Bucket 名称校验、Region/LocationConstraint 和 Owner 幂等规则。 |
| `HeadBucket` | `HEAD /{bucket}` | `Implemented` | 返回存在性和权限结果；错误只返回状态与 Request ID。 |
| `DeleteBucket` | `DELETE /{bucket}` | `Implemented` | 空 Bucket 删除；非空返回 `BucketNotEmpty`。 |
| `GetBucketLocation` | `GET /{bucket}?location` | `Implemented` | 返回 ZigFS 配置的 Region。 |
| `GetBucketAcl` | `GET /{bucket}?acl` | `Not Implemented` | V1 使用 ZigFS Owner/Policy，不提供 S3 ACL 文档模型。 |
| `PutBucketAcl` | `PUT /{bucket}?acl` | `Not Implemented` | 同上。 |
| `GetBucketPolicy` | `GET /{bucket}?policy` | `Not Implemented` | 不提供 S3 Bucket Policy 资源。 |
| `PutBucketPolicy` | `PUT /{bucket}?policy` | `Not Implemented` | 不提供 S3 Bucket Policy 写入。 |
| `DeleteBucketPolicy` | `DELETE /{bucket}?policy` | `Not Implemented` | 不提供 S3 Bucket Policy 删除。 |
| `GetBucketPolicyStatus` | `GET /{bucket}?policyStatus` | `Out of Scope` | 依赖 S3 公共访问策略模型。 |

### Bucket 配置与云集成

以下操作均未纳入 ZigFS 0.1。它们不是 Bucket/Object 核心文件读写的必要条件，后续如需支持
必须单独增加数据模型、权限边界、持久化记录、契约和兼容性测试。

| AWS 操作 | 状态 | AWS 能力 |
|---|---|---|
| `GetBucketCors` / `PutBucketCors` / `DeleteBucketCors` | `Out of Scope` | CORS 配置 |
| `GetBucketLifecycleConfiguration` / `PutBucketLifecycleConfiguration` / `DeleteBucketLifecycle` | `Out of Scope` | Lifecycle/过期规则 |
| `GetBucketLogging` / `PutBucketLogging` | `Out of Scope` | Server access logging |
| `GetBucketNotificationConfiguration` / `PutBucketNotificationConfiguration` | `Out of Scope` | SNS/SQS/Lambda 通知 |
| `GetBucketReplication` / `PutBucketReplication` / `DeleteBucketReplication` | `Out of Scope` | 跨 Region/跨 Bucket 复制 |
| `GetBucketTagging` / `PutBucketTagging` / `DeleteBucketTagging` | `Not Implemented` | Bucket Tagging |
| `GetBucketVersioning` / `PutBucketVersioning` | `Not Implemented` | Object Versioning 开关 |
| `ListObjectVersions` | `Not Implemented` | 版本对象列表 |
| `GetBucketWebsite` / `PutBucketWebsite` / `DeleteBucketWebsite` | `Out of Scope` | 静态网站托管 |
| `GetBucketEncryption` / `PutBucketEncryption` / `DeleteBucketEncryption` | `Out of Scope` | S3 SSE/KMS 默认加密配置；Credential Secret 的内部加密不等同于该 API。 |
| `GetPublicAccessBlock` / `PutPublicAccessBlock` / `DeletePublicAccessBlock` | `Out of Scope` | 公共访问阻断 |
| `GetBucketOwnershipControls` / `PutBucketOwnershipControls` / `DeleteBucketOwnershipControls` | `Out of Scope` | Object Ownership |
| `GetObjectLockConfiguration` / `PutObjectLockConfiguration` | `Out of Scope` | Object Lock 默认配置 |
| `GetBucketRequestPayment` / `PutBucketRequestPayment` | `Out of Scope` | Requester Pays |
| `GetBucketAccelerateConfiguration` / `PutBucketAccelerateConfiguration` | `Out of Scope` | Transfer Acceleration |
| `GetBucketAnalyticsConfiguration` / `PutBucketAnalyticsConfiguration` / `DeleteBucketAnalyticsConfiguration` / `ListBucketAnalyticsConfigurations` | `Out of Scope` | Analytics |
| `GetBucketIntelligentTieringConfiguration` / `PutBucketIntelligentTieringConfiguration` / `DeleteBucketIntelligentTieringConfiguration` / `ListBucketIntelligentTieringConfigurations` | `Out of Scope` | Intelligent-Tiering |
| `GetBucketInventoryConfiguration` / `PutBucketInventoryConfiguration` / `DeleteBucketInventoryConfiguration` / `ListBucketInventoryConfigurations` | `Out of Scope` | Inventory 报表 |
| `GetBucketMetricsConfiguration` / `PutBucketMetricsConfiguration` / `DeleteBucketMetricsConfiguration` / `ListBucketMetricsConfigurations` | `Out of Scope` | CloudWatch Metrics 配置 |

## Object 与 List API

| AWS 操作 | HTTP 形态 | 状态 | ZigFS 0.1 说明 |
|---|---|---|---|
| `ListObjects` | `GET /{bucket}` | `Not Implemented` | V1 只实现 ListObjectsV2，不提供旧版 ListObjects 语义。 |
| `ListObjectsV2` | `GET /{bucket}?list-type=2` | `Implemented` | 支持 Prefix、Delimiter、分页 Token、StartAfter、EncodingType 和 FetchOwner。 |
| `PutObject` | `PUT /{bucket}/{key}` | `Implemented` | 支持流式写入、Metadata、MD5、SHA-256、五种 Flexible Checksum 和 aws-chunked。 |
| `PostObject`（Browser POST） | `POST /{bucket}` | `Implemented` | 支持 SigV4 POST Policy、条件、文件流和失败不发布语义；未支持的表单扩展返回 `NotImplemented`。 |
| `GetObject` | `GET /{bucket}/{key}` | `Implemented` | 支持完整对象和单范围请求；Multi-Range、部分响应覆盖参数不在 V1。 |
| `HeadObject` | `HEAD /{bucket}/{key}` | `Implemented` | 返回大小、ETag、Last-Modified、Content-Type、Metadata 和 checksum。 |
| `DeleteObject` | `DELETE /{bucket}/{key}` | `Implemented` | 幂等 Tombstone，延迟 GC。 |
| `DeleteObjects` | `POST /{bucket}?delete` | `Implemented` | 最多 1000 个 Key，必须携带正确 Content-MD5，支持 Quiet 和逐项结果。 |
| `CopyObject` | `PUT /{bucket}/{key}` + `x-amz-copy-source` | `Implemented` | 支持 COPY/REPLACE Metadata、源/目标权限、条件和流式复制。 |
| `GetObjectAttributes` | `GET /{bucket}/{key}?attributes` | `Not Implemented` | 不提供独立 Object Attributes 响应。 |
| `GetObjectAcl` | `GET /{bucket}/{key}?acl` | `Not Implemented` | 不提供 S3 ACL。 |
| `PutObjectAcl` | `PUT /{bucket}/{key}?acl` | `Not Implemented` | 不提供 S3 ACL。 |
| `GetObjectTagging` / `PutObjectTagging` / `DeleteObjectTagging` | `?tagging` | `Not Implemented` | Object Tagging 不在 V1。 |
| `GetObjectLegalHold` / `PutObjectLegalHold` | `?legal-hold` | `Out of Scope` | Object Lock Legal Hold。 |
| `GetObjectRetention` / `PutObjectRetention` | `?retention` | `Out of Scope` | Object Lock Retention。 |
| `GetObjectTorrent` | `GET /{bucket}/{key}?torrent` | `Out of Scope` | BitTorrent 传输。 |
| `RestoreObject` | `POST /{bucket}/{key}?restore` | `Out of Scope` | Glacier/Archive 恢复；ZigFS 没有 Archive Storage Class。 |
| `SelectObjectContent` | `POST /{bucket}/{key}?select&select-type=2` | `Out of Scope` | S3 Select 查询引擎。 |
| `WriteGetObjectResponse` | Object Lambda 专用 | `Out of Scope` | AWS Object Lambda 回调接口。 |

## Multipart API

| AWS 操作 | HTTP 形态 | 状态 | ZigFS 0.1 说明 |
|---|---|---|---|
| `CreateMultipartUpload` | `POST /{bucket}/{key}?uploads` | `Implemented` | 创建持久化 Upload Metadata 和 UploadId。 |
| `UploadPart` | `PUT /{bucket}/{key}?partNumber&uploadId` | `Implemented` | 支持并发 Part、覆盖、MD5、SHA-256、五种 Flexible Checksum 和 signed trailer。 |
| `UploadPartCopy` | `PUT /{bucket}/{key}?partNumber&uploadId` + `x-amz-copy-source` | `Not Implemented` | 不提供服务端 Multipart Part Copy。 |
| `ListParts` | `GET /{bucket}/{key}?uploadId` | `Implemented` | 支持 Part Number Marker、分页和升序结果。 |
| `CompleteMultipartUpload` | `POST /{bucket}/{key}?uploadId` | `Implemented` | 校验 Part 顺序/ETag，提交普通 Object Generation 和复合 ETag。 |
| `AbortMultipartUpload` | `DELETE /{bucket}/{key}?uploadId` | `Implemented` | Tombstone Upload Metadata 并清理 Part 数据。 |
| `ListMultipartUploads` | `GET /{bucket}?uploads` | `Not Implemented` | 不提供 Bucket 级未完成 Upload 列表。 |

Multipart 的 V1 鉴权只接受 Signature V4 Authorization Header；对象级 Presigned URL 不扩展为
Presigned Multipart。除最后一个 Part 外，Complete 时执行 AWS 最小 Part Size 规则。

## ZigFS 已实现的协议能力

下列能力不是独立 AWS S3 Operation，但决定上述操作是否可被文件 SDK 和客户端稳定使用：

| 能力 | 状态 | 说明 |
|---|---|---|
| Signature V4 Header | `Implemented` | Canonical URI/Query/Header、Region、Payload Hash、时钟偏差和错误映射。 |
| Presigned GET/PUT/DELETE | `Implemented` | 最长 7 天；临时凭证的 Session Token 参与签名并受凭证寿命约束。 |
| Temporary Credentials | `Implemented` | AK/SK/Session Token 由 ZigFS Metadata 持久化并加密，Admin 只调用 Management API。 |
| Path-style / Virtual-hosted-style | `Implemented` | 默认 Path-style；Virtual-hosted-style 由 `s3.virtual_hosted_style` 开启。 |
| Flexible Checksum | `Implemented` | CRC32、CRC32C、CRC64NVME、SHA1、SHA256 的 Header/签名 Trailer；DeleteObjects 仍只要求 Content-MD5。 |
| Conditional Requests | `Implemented` | GET/HEAD/PUT 的 ETag 和 HTTP 日期条件，含 304/412 与条件写 CAS。 |

## 0.1 已知差异

这些差异不能从“核心操作已实现”推断为已支持：

1. Multi-Range 请求返回 `416 InvalidRange`。
2. DeleteObjects 的 Flexible Checksum Header/Trailer 变体返回 `501 NotImplemented`；Content-MD5 仍是必需校验。
3. Object Versioning、ACL、Tagging、Select、Object Lock 和 Bucket 配置类 API 未实现或不在范围内。
4. POST Policy 只支持兼容矩阵中声明的字段和 checksum；ACL、redirect、其他 checksum 与未识别表单字段返回 `NotImplemented`。
5. 单个已实现操作的非 V1 Header、Query、XML 字段不自动获得兼容保证；新增支持必须更新本文和 [兼容矩阵](s3-compatibility.md)。

## 后续实现顺序

后续版本应按文件 SDK 真实需求和兼容收益排序，而不是按 AWS API 数量堆叠：

1. `ListObjects`/`ListObjectVersions`、`ListMultipartUploads`、`UploadPartCopy` 等文件生命周期补齐。
2. Object Tagging、Bucket Tagging 和 Versioning，先确定 Metadata Record 版本与 GC 语义。
3. ACL/Policy/Ownership Controls，先确定 Owner、Policy 和 Admin Management API 的统一权限模型。
4. CORS、Lifecycle、Notification、Replication、Encryption 等平台配置能力。
5. Select、Object Lock、Inventory、Analytics、Intelligent-Tiering 和云厂商集成类能力。

每个新增操作必须同时提交：HTTP/XML/错误契约、鉴权与权限规则、Metadata/Journal 设计、正常/异常/恢复测试、至少一个真实客户端验证，以及对应语言 SDK 映射。服务版本仍按 `0.1.x` 演进，不能因新增 S3 操作直接改成 `1.0.0`。
