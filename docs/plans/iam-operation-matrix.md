# IAM 操作—Action—资源—上下文矩阵

> P0 交付物（2026-10-30）。`Status` 描述当前实现状态；`Tests` 列出对应验证入口，已执行结果记录在 `iam-permissions-completion.md` 和测试基线中。

## S3 数据面

| Operation | Action | Resource | 关键上下文 | Status | Tests |
| --- | --- | --- | --- | --- | --- |
| ListBuckets | `s3:ListAllMyBuckets` | `arn:aws:s3:::*` | Principal、账户 | Implemented | list buckets |
| CreateBucket | `s3:CreateBucket` | bucket ARN | region、Principal | Implemented | create bucket |
| HeadBucket | `s3:ListBucket` | bucket ARN | Principal、SourceIp | Implemented | head bucket |
| GetBucketLocation | `s3:GetBucketLocation` | bucket ARN | region | Implemented | bucket location |
| GetBucketPolicy | `s3:GetBucketPolicy` | bucket ARN | Principal、resource policy | Implemented | bucket policy |
| PutBucketPolicy | `s3:PutBucketPolicy` | bucket ARN | Principal/Resource | Implemented | bucket policy |
| DeleteBucketPolicy | `s3:DeleteBucketPolicy` | bucket ARN | Principal、resource policy | Implemented | bucket policy |
| Get/PutBucketVersioning | `s3:GetBucketVersioning` / `s3:PutBucketVersioning` | bucket ARN | version state | Implemented | versioning |
| Get/Put/DeleteLifecycle | lifecycle Actions | bucket ARN | lifecycle configuration | Implemented | lifecycle |
| DeleteBucket | `s3:DeleteBucket` | bucket ARN | ownership、empty state | Implemented | delete bucket |
| ListObjectsV2 | `s3:ListBucket` | bucket ARN | prefix、delimiter、max-keys、continuation token | Implemented | list objects |
| ListObjectVersions | `s3:ListBucketVersions` | bucket ARN | prefix、version ID、delete markers | Implemented | list versions |
| ListMultipartUploads | `s3:ListBucketMultipartUploads` | bucket ARN | prefix、markers | Implemented | list multipart |
| PutObject | `s3:PutObject` | object ARN | tagging、copy-source、SSE、storage class | Implemented | put object |
| Get/HeadObject | `s3:GetObject` / `s3:GetObjectVersion` | object/version ARN | versionId、range、conditional headers | Implemented | get/head object |
| DeleteObject | `s3:DeleteObject` / `s3:DeleteObjectVersion` | object/version ARN | versionId、retention | Implemented | delete object |
| DeleteObjects | object delete Actions | each object/version ARN | per-item version、retention | Implemented | batch delete; `http.zig` per-item allow/deny coverage |
| Get/Put/DeleteObjectTagging | object tagging Actions | object/version ARN | existing/request tags | Implemented | object tagging |
| CreateMultipartUpload | `s3:PutObject` | object ARN | tagging、SSE、retention | Implemented | multipart create |
| UploadPart | `s3:PutObject` | object/upload ARN | upload ID、part number | Implemented | upload part |
| UploadPartCopy | source `s3:GetObject`, target `s3:PutObject` | source + target ARN | source version、copy range headers | Implemented | `http.zig` multipart lifecycle copy-part coverage |
| ListParts | `s3:ListMultipartUploadParts` | object/upload ARN | upload ID、part markers | Implemented | list parts |
| CompleteMultipartUpload | `s3:PutObject` | object/upload ARN | part list、tags、source state | Implemented | complete multipart |
| AbortMultipartUpload | `s3:DeleteObject` | object/upload ARN | upload ID | Implemented | abort multipart |
| POST Policy Upload | `s3:PutObject` plus POST policy | object ARN | form policy、signed fields、tagging | Implemented | `http.zig` POST policy upload and invalid-signature coverage |
| Presigned request | operation-specific | operation resource | expiry、signature age、session token | Implemented | presign create/consume |
| Unsupported operation | deny | n/a | operation parser result | Implemented | unsupported operation |

`CopyObject` and `UploadPartCopy` enter the PutObject path with explicit source authorization before the destination write. POST policy upload performs independent form-policy signature and IAM checks; DeleteObjects evaluates each object independently and returns per-item errors.

## Zig Management API

All routes are under `/_admin/v1`. The HTTP layer authenticates the management principal; non-root routes currently default to `admin:*` unless a narrower mapping exists in `management_auth.routeAction`.

| Route group | Methods | Intended Action | Resource | Status |
| --- | --- | --- | --- | --- |
| `/auth/login`, `/auth/session` | POST/GET | login/session Actions | session | Implemented |
| `/users`, `/users/:name` | GET/POST/PATCH/DELETE | user CRUD Actions | user | Implemented |
| `/users/:name/access-keys`, `/:id` | GET/POST/PATCH/DELETE | access key Actions | user key | Implemented |
| `/groups`, `/groups/:name` | GET/POST/PATCH/DELETE | group CRUD Actions | group | Implemented |
| `/organizations`, `/organizations/:name` | GET/POST/DELETE | organization CRUD Actions | organization | Implemented |
| `/roles`, `/roles/:name` | GET/POST/PATCH/DELETE | role federation/STS CRUD Actions | independent role principal | Implemented |
| `/sts/assume-role` | POST | `sts:AssumeRole` | role ARN | Implemented |
| `/role-sessions` | GET | session list Action | role session | Implemented |
| `/role-sessions/:access_key/revoke` | POST | session revoke Action | role session | Implemented |
| `/policies`, `/policies/:name` | GET/POST/PATCH/DELETE | policy CRUD Actions | identity policy | Implemented |
| `/buckets`, `/buckets/:name` | GET/POST/DELETE | bucket CRUD Actions | bucket | Implemented |
| `/buckets/:name/configuration` | GET/PATCH | configuration Actions | bucket | Implemented |
| `/buckets/:name/usage`, `/events` | GET | usage/event Actions | bucket | Implemented |
| `/buckets/:name/versions`, `/objects` | GET | list Actions | bucket/object | Implemented |
| `/buckets/:name/directories` | POST/DELETE | directory Actions | bucket/prefix | Implemented |
| `/buckets/:name/policy` | GET/PUT/DELETE | bucket policy Actions | bucket policy | Implemented |
| `/buckets/:name/tags` | GET/PUT/DELETE | bucket tag Actions | bucket | Implemented |
| `/objects/presign` | POST | presign + object Action | object | Implemented |
| `/multipart-uploads*` | POST/GET/DELETE | multipart Actions | upload/object | Implemented |
| `/access-keys` | GET/POST/PATCH/DELETE | access key Actions | account key | Implemented |
| `/storage*`, `/system`, `/health`, `/settings` | GET/POST | storage/system Actions | system | Implemented |

## OIDC 配置管理（2026-11-02）

`/_admin/v1/oidc/providers` GET/POST 和 `/_admin/v1/oidc/providers/:id` PATCH/DELETE 仅部署管理员可用；BFF 对应 `/api/v1/oidc/providers` 路径并透传调用者会话。普通主体即便拥有 `admin:*` 仍不能配置 OIDC。

配置、Discovery/JWKS、Code + PKCE、state/nonce、九种非对称 JWT 算法校验、Claim/固定 Policy 映射、会话撤销和 S3 临时凭证已接通；`login_supported: true`。公共登录操作不开放 Provider 管理权限。验证入口：`conformance/oidc_providers.py`、`conformance/oidc_login.py`。协议范围与部署步骤见 [oidc-login.md](../oidc-login.md)。

## Go BFF routes

The Go router mirrors the management surface under `/api/v1`. Every private route must preserve the caller cookie/session and delegate final authorization to ZigFS.

| Route families | Methods |
| --- | --- |
| `/auth/*`, `/system`, `/storage*`, `/management-health`, `/settings` | GET/POST |
| `/users*`, `/users/:name/access-keys*`, `/groups*` | GET/POST/PATCH/DELETE |
| `/organizations*`, `/roles*`, `/sts/assume-role`, `/role-sessions*` | GET/POST/DELETE |
| `/policies*` | GET/POST/PATCH/DELETE |
| `/buckets*`, configuration/usage/events/versions/objects | GET/POST/PATCH/DELETE |
| `/buckets/:name/policy`, `/buckets/:name/tags` | GET/PUT/DELETE |
| directories, presign and multipart routes | GET/POST/DELETE |
| `/access-keys*` | GET/POST/PATCH/DELETE |

## 八个默认策略审计

| Policy | Actions | Resource | Actual implementation status |
| --- | --- | --- | --- |
| `consoleAdmin` | `admin:*`, `kms:*`, `s3:*`, `sts:AssumeRole` | S3/KMS wildcard | Policy authorization covered by `policy_store.zig`; cryptographic KMS API is not exposed by ZigFS |
| `diagnostics` | Profiling, ServerTrace, ConsoleLog, ServerInfo, TopLocksInfo, OBDInfo, Prometheus, BandwidthMonitor, `sts:AssumeRole` | S3 wildcard | Policy action matching covered; unsupported diagnostics endpoints remain explicit deny |
| `KMSAuditor` | DescribeKey, ListKeys, `sts:AssumeRole` | KMS wildcard | Default policy action allow/deny covered by `policy_store.zig` |
| `KMSKeyAdministrator` | Describe/List/Enable/Disable/Rotate/Delete key, `sts:AssumeRole` | KMS wildcard | Default policy action allow/deny covered by `policy_store.zig` |
| `KMSKeyUser` | GenerateDataKey/Decrypt/DescribeKey, `sts:AssumeRole` | KMS wildcard | Default policy action allow/deny covered by `policy_store.zig` |
| `readonly` | GetBucketLocation, GetObject, GetBucketQuota, `sts:AssumeRole` | S3 wildcard | GetObject/GetBucketLocation verified; unsupported quota action remains an explicit deny |
| `readwrite` | `s3:*`, `sts:AssumeRole` | S3 wildcard | all implemented S3 operations use the shared authorization gate |
| `writeonly` | PutObject, `sts:AssumeRole` | S3 wildcard | PutObject, multipart writes and copy targets require `s3:PutObject`; read/tag actions remain denied |

## Exact route inventory

The grouped tables above are the authorization view. The following inventories are the exact current paths and are the change-detection source for P0.

### Go BFF `/api/v1`

```text
/auth/login  /auth/logout  /auth/session
/system  /storage  /storage/scanner  /storage/gc  /management-health  /settings
/users  /users/:name  /users/:name/access-keys  /users/:name/access-keys/:id
/groups  /groups/:name
/organizations  /organizations/:name
/roles  /roles/:name  /sts/assume-role  /role-sessions  /role-sessions/:access_key/revoke
/policies  /policies/:name
/buckets  /buckets/:name  /buckets/:name/configuration  /buckets/:name/usage
/buckets/:name/events  /buckets/:name/policy  /buckets/:name/tags
/buckets/:name/versions  /buckets/:name/objects  /buckets/:name/directories
/buckets/:name/multipart-uploads  /objects/presign
/multipart-uploads  /multipart-uploads/:id  /multipart-uploads/:id/complete
/access-keys  /access-keys/:id
```

### Zig Management `/_admin/v1`

```text
/users  /users/:name  /users/:name/access-keys  /users/:name/access-keys/:id
/groups  /groups/:name  /organizations  /organizations/:name
/roles  /roles/:name  /sts/assume-role  /role-sessions
/role-sessions/:access_key/revoke  /policies  /policies/:name
/auth/login  /auth/session  /buckets  /buckets/:name
/buckets/:name/configuration  /buckets/:name/usage  /buckets/:name/events
/buckets/:name/versions  /buckets/:name/objects  /buckets/:name/directories
/buckets/:name/multipart-uploads  /buckets/:name/policy  /buckets/:name/tags
/objects/presign  /multipart-uploads  /multipart-uploads/:id
/multipart-uploads/:id/complete  /access-keys  /access-keys/:id
/storage  /storage/scanner  /storage/gc  /system  /health  /settings
```

## Reference and P0 status

- Policy syntax reference is IAM JSON policy version `2012-10-17`; operation names come from `zigfs/src/transport/s3_protocol.zig`.
- Coverage references are `docs/api/s3-api-coverage.md`, `docs/api/s3-compatibility.md`, `docs/api/zigfs-management-v1.openapi.yaml`, and `docs/api/admin-bff-v1.openapi.yaml`.
- Every operation row now has a shared authorization gate and a focused allow/deny path; unsupported capabilities return an explicit deny or NotImplemented response.

- [x] S3 operations and current Action/resource/context mapping enumerated.
- [x] Zig Management and Go BFF route families enumerated.
- [x] API coverage and compatibility references compared; gaps retained.
- [x] Eight default policy documents audited against implemented capabilities.
- [x] Reference policy version and operation naming sources fixed.
- [x] Dedicated permission test entrypoint and coverage baseline are defined in `conformance/iam_permissions.sh` and `docs/plans/iam-p0-test-baseline.md`; execution status is recorded per suite and does not treat blocked toolchains as passes.

OIDC 扩展覆盖资料同步、Refresh Token 轮换、RP/后通道退出、环境管理来源和 STS 托管限制策略。自动回归为 `conformance/oidc_login.py`；签名算法集合及 AWS 本地映射差异见操作文档，浏览器交互见 W09。
