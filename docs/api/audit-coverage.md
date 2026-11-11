# ZigFS 审计覆盖清单（V1）

以 [RustFS Audit Event Schema V1.0](../plans/rustfs-audit-log-schema-v1.md) 为结构依据，具体 ZigFS 落地约定见 [审计结构与查询接口](audit-schema-v1.md)。本文是当前实现清单，不把规范中的未来能力描述成已实现。

## 当前审计种类

| 分类 | 中文名称 | 典型操作 |
| --- | --- | --- |
| `object_storage` | 对象存储 | PutObject、GetObject、DeleteObject、分段上传、目录清理 |
| `identity` | 身份与认证 | Login、CreateUser、CreateAccessKey、OIDC、STS |
| `access_control` | 访问控制 | PutBucketPolicy、CreatePolicy、角色和组织权限 |
| `bucket_management` | Bucket 管理 | CreateBucket、UpdateBucketConfiguration、版本控制与加密配置 |
| `system_management` | 系统管理 | UpdateLogConfiguration、RunGarbageCollection、审计查询 |
| `kms` | KMS 密钥管理 | CreateKey、RotateKey、StartKMS、密钥删除与恢复 |
| `security` | 安全事件 | 任意操作的 HTTP 401/403 认证或授权拒绝，保留原操作名称 |

每个请求记录一次。事件类型为 `api_request`、`admin_action` 或 `security_event`；`system_event` 是预留类型，目前未发出后台系统事件。

审计页支持：分类、分类内具体操作（可搜索）、结果、时间范围、服务、操作者、Bucket、请求 ID、来源 IP、事件类型。选项来自后端 `/audit-events/options` 目录。安全事件中允许选择各模块操作，因为任何操作都可能被拒绝。详情侧栏按事件、请求、身份、资源、操作、响应和扩展信息展示。

## 已接入的完整操作映射

以下表格由 `zigfs/src/application/audit_schema.zig` 中的目录整理。管理路径列出方法和路由模板；S3/STS/KMS 动作列出内部识别名。同名动作可来自不同服务，使用服务筛选区分。请求使用不支持的方法时会保留失败状态；无法识别语义时为 `UnknownOperation`。

| 标准操作 | 分类 | 服务 | 请求/内部动作 | 只读 |
| --- | --- | --- | --- | --- |
| `UnknownOperation` | `system_management` | `admin` | `` | 否 |
| `UnknownOperation` | `object_storage` | `s3` | `` | 否 |
| `ListBuckets` | `bucket_management` | `s3` | `list_buckets` | 是 |
| `CreateBucket` | `bucket_management` | `s3` | `create_bucket` | 否 |
| `HeadBucket` | `bucket_management` | `s3` | `head_bucket` | 是 |
| `GetBucketLocation` | `bucket_management` | `s3` | `get_bucket_location` | 是 |
| `GetBucketPolicy` | `access_control` | `s3` | `get_bucket_policy` | 是 |
| `PutBucketPolicy` | `access_control` | `s3` | `put_bucket_policy` | 否 |
| `DeleteBucketPolicy` | `access_control` | `s3` | `delete_bucket_policy` | 否 |
| `GetBucketEncryption` | `bucket_management` | `s3` | `get_bucket_encryption` | 是 |
| `PutBucketEncryption` | `bucket_management` | `s3` | `put_bucket_encryption` | 否 |
| `DeleteBucketEncryption` | `bucket_management` | `s3` | `delete_bucket_encryption` | 否 |
| `GetBucketVersioning` | `bucket_management` | `s3` | `get_bucket_versioning` | 是 |
| `PutBucketVersioning` | `bucket_management` | `s3` | `put_bucket_versioning` | 否 |
| `GetBucketLifecycle` | `bucket_management` | `s3` | `get_bucket_lifecycle` | 是 |
| `PutBucketLifecycle` | `bucket_management` | `s3` | `put_bucket_lifecycle` | 否 |
| `DeleteBucketLifecycle` | `bucket_management` | `s3` | `delete_bucket_lifecycle` | 否 |
| `DeleteBucket` | `bucket_management` | `s3` | `delete_bucket` | 否 |
| `DeleteObjects` | `object_storage` | `s3` | `delete_objects` | 否 |
| `ListObjectsV2` | `object_storage` | `s3` | `list_objects_v2` | 是 |
| `ListObjectVersions` | `object_storage` | `s3` | `list_object_versions` | 是 |
| `ListMultipartUploads` | `object_storage` | `s3` | `list_multipart_uploads` | 是 |
| `PutObject` | `object_storage` | `s3` | `put_object` | 否 |
| `GetObject` | `object_storage` | `s3` | `get_object` | 是 |
| `GetObjectTagging` | `object_storage` | `s3` | `get_object_tagging` | 是 |
| `PutObjectTagging` | `object_storage` | `s3` | `put_object_tagging` | 否 |
| `DeleteObjectTagging` | `object_storage` | `s3` | `delete_object_tagging` | 否 |
| `HeadObject` | `object_storage` | `s3` | `head_object` | 是 |
| `DeleteObject` | `object_storage` | `s3` | `delete_object` | 否 |
| `CreateMultipartUpload` | `object_storage` | `s3` | `create_multipart_upload` | 否 |
| `UploadPart` | `object_storage` | `s3` | `upload_part` | 否 |
| `ListParts` | `object_storage` | `s3` | `list_parts` | 是 |
| `CompleteMultipartUpload` | `object_storage` | `s3` | `complete_multipart_upload` | 否 |
| `AbortMultipartUpload` | `object_storage` | `s3` | `abort_multipart_upload` | 否 |
| `PostPolicyUpload` | `object_storage` | `s3` | `post_policy_upload` | 否 |
| `UnsupportedOperation` | `object_storage` | `s3` | `unsupported` | 否 |
| `Login` | `identity` | `admin` | `POST /_admin/v1/auth/login` | 否 |
| `STSLogin` | `identity` | `admin` | `POST /_admin/v1/auth/sts-login` | 否 |
| `GetSession` | `identity` | `admin` | `GET /_admin/v1/auth/session` | 是 |
| `Logout` | `identity` | `admin` | `POST /_admin/v1/auth/logout` | 否 |
| `ListLoginProviders` | `identity` | `admin` | `GET /_admin/v1/auth/oidc/providers` | 是 |
| `StartOIDCLogin` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/start` | 否 |
| `CompleteOIDCLogin` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/callback` | 否 |
| `RefreshSession` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/refresh` | 否 |
| `LogoutOIDC` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/logout` | 否 |
| `EndOIDCSession` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/end-session` | 否 |
| `BackchannelLogout` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/backchannel-logout` | 否 |
| `AssumeWebIdentity` | `identity` | `admin` | `POST /_admin/v1/auth/oidc/web-identity` | 否 |
| `ListUsers` | `identity` | `admin` | `GET /_admin/v1/users` | 是 |
| `CreateUser` | `identity` | `admin` | `POST /_admin/v1/users` | 否 |
| `GetUser` | `identity` | `admin` | `GET /_admin/v1/users/:id` | 是 |
| `UpdateUser` | `identity` | `admin` | `PATCH /_admin/v1/users/:id` | 否 |
| `UpdateUser` | `identity` | `admin` | `PUT /_admin/v1/users/:id` | 否 |
| `DeleteUser` | `identity` | `admin` | `DELETE /_admin/v1/users/:id` | 否 |
| `ListGroups` | `identity` | `admin` | `GET /_admin/v1/groups` | 是 |
| `CreateGroup` | `identity` | `admin` | `POST /_admin/v1/groups` | 否 |
| `GetGroup` | `identity` | `admin` | `GET /_admin/v1/groups/:id` | 是 |
| `UpdateGroup` | `identity` | `admin` | `PATCH /_admin/v1/groups/:id` | 否 |
| `UpdateGroup` | `identity` | `admin` | `PUT /_admin/v1/groups/:id` | 否 |
| `DeleteGroup` | `identity` | `admin` | `DELETE /_admin/v1/groups/:id` | 否 |
| `ListPolicies` | `access_control` | `admin` | `GET /_admin/v1/policies` | 是 |
| `CreatePolicy` | `access_control` | `admin` | `POST /_admin/v1/policies` | 否 |
| `GetPolicy` | `access_control` | `admin` | `GET /_admin/v1/policies/:id` | 是 |
| `UpdatePolicy` | `access_control` | `admin` | `PATCH /_admin/v1/policies/:id` | 否 |
| `UpdatePolicy` | `access_control` | `admin` | `PUT /_admin/v1/policies/:id` | 否 |
| `DeletePolicy` | `access_control` | `admin` | `DELETE /_admin/v1/policies/:id` | 否 |
| `ListRoles` | `access_control` | `admin` | `GET /_admin/v1/roles` | 是 |
| `CreateRole` | `access_control` | `admin` | `POST /_admin/v1/roles` | 否 |
| `GetRole` | `access_control` | `admin` | `GET /_admin/v1/roles/:id` | 是 |
| `UpdateRole` | `access_control` | `admin` | `PATCH /_admin/v1/roles/:id` | 否 |
| `UpdateRole` | `access_control` | `admin` | `PUT /_admin/v1/roles/:id` | 否 |
| `DeleteRole` | `access_control` | `admin` | `DELETE /_admin/v1/roles/:id` | 否 |
| `ListOrganizations` | `access_control` | `admin` | `GET /_admin/v1/organizations` | 是 |
| `CreateOrganization` | `access_control` | `admin` | `POST /_admin/v1/organizations` | 否 |
| `GetOrganization` | `access_control` | `admin` | `GET /_admin/v1/organizations/:id` | 是 |
| `UpdateOrganization` | `access_control` | `admin` | `PATCH /_admin/v1/organizations/:id` | 否 |
| `UpdateOrganization` | `access_control` | `admin` | `PUT /_admin/v1/organizations/:id` | 否 |
| `DeleteOrganization` | `access_control` | `admin` | `DELETE /_admin/v1/organizations/:id` | 否 |
| `ListAccessKeys` | `identity` | `admin` | `GET /_admin/v1/access-keys` | 是 |
| `CreateAccessKey` | `identity` | `admin` | `POST /_admin/v1/access-keys` | 否 |
| `GetAccessKey` | `identity` | `admin` | `GET /_admin/v1/access-keys/:id` | 是 |
| `UpdateAccessKey` | `identity` | `admin` | `PATCH /_admin/v1/access-keys/:id` | 否 |
| `UpdateAccessKey` | `identity` | `admin` | `PUT /_admin/v1/access-keys/:id` | 否 |
| `DeleteAccessKey` | `identity` | `admin` | `DELETE /_admin/v1/access-keys/:id` | 否 |
| `ListOIDCProviders` | `identity` | `admin` | `GET /_admin/v1/oidc/providers` | 是 |
| `CreateOIDCProvider` | `identity` | `admin` | `POST /_admin/v1/oidc/providers` | 否 |
| `GetOIDCProvider` | `identity` | `admin` | `GET /_admin/v1/oidc/providers/:id` | 是 |
| `UpdateOIDCProvider` | `identity` | `admin` | `PATCH /_admin/v1/oidc/providers/:id` | 否 |
| `UpdateOIDCProvider` | `identity` | `admin` | `PUT /_admin/v1/oidc/providers/:id` | 否 |
| `DeleteOIDCProvider` | `identity` | `admin` | `DELETE /_admin/v1/oidc/providers/:id` | 否 |
| `ListUserAccessKeys` | `identity` | `admin` | `GET /_admin/v1/users/:id/access-keys` | 是 |
| `CreateUserAccessKey` | `identity` | `admin` | `POST /_admin/v1/users/:id/access-keys` | 否 |
| `GetUserAccessKey` | `identity` | `admin` | `GET /_admin/v1/users/:id/access-keys/:key` | 是 |
| `UpdateUserAccessKey` | `identity` | `admin` | `PATCH /_admin/v1/users/:id/access-keys/:key` | 否 |
| `DeleteUserAccessKey` | `identity` | `admin` | `DELETE /_admin/v1/users/:id/access-keys/:key` | 否 |
| `ValidateOIDCProvider` | `identity` | `admin` | `POST /_admin/v1/oidc/validate` | 否 |
| `AssumeRole` | `identity` | `admin` | `POST /_admin/v1/sts/assume-role` | 否 |
| `ListRoleSessions` | `identity` | `admin` | `GET /_admin/v1/role-sessions` | 是 |
| `RevokeRoleSession` | `identity` | `admin` | `POST /_admin/v1/role-sessions/:id/revoke` | 否 |
| `ListBuckets` | `bucket_management` | `admin` | `GET /_admin/v1/buckets` | 是 |
| `CreateBucket` | `bucket_management` | `admin` | `POST /_admin/v1/buckets` | 否 |
| `DeleteBucket` | `bucket_management` | `admin` | `DELETE /_admin/v1/buckets/:bucket` | 否 |
| `GetBucketConfiguration` | `bucket_management` | `admin` | `GET /_admin/v1/buckets/:bucket/configuration` | 是 |
| `UpdateBucketConfiguration` | `bucket_management` | `admin` | `PATCH /_admin/v1/buckets/:bucket/configuration` | 否 |
| `GetBucketUsage` | `bucket_management` | `admin` | `GET /_admin/v1/buckets/:bucket/usage` | 是 |
| `GetBucketTags` | `bucket_management` | `admin` | `GET /_admin/v1/buckets/:bucket/tags` | 是 |
| `PutBucketTags` | `bucket_management` | `admin` | `PUT /_admin/v1/buckets/:bucket/tags` | 否 |
| `DeleteBucketTags` | `bucket_management` | `admin` | `DELETE /_admin/v1/buckets/:bucket/tags` | 否 |
| `GetBucketPolicy` | `access_control` | `admin` | `GET /_admin/v1/buckets/:bucket/policy` | 是 |
| `PutBucketPolicy` | `access_control` | `admin` | `PUT /_admin/v1/buckets/:bucket/policy` | 否 |
| `DeleteBucketPolicy` | `access_control` | `admin` | `DELETE /_admin/v1/buckets/:bucket/policy` | 否 |
| `ListObjects` | `object_storage` | `admin` | `GET /_admin/v1/buckets/:bucket/objects` | 是 |
| `ListObjectVersions` | `object_storage` | `admin` | `GET /_admin/v1/buckets/:bucket/versions` | 是 |
| `ListMultipartUploads` | `object_storage` | `admin` | `GET /_admin/v1/buckets/:bucket/multipart-uploads` | 是 |
| `CreateDirectory` | `object_storage` | `admin` | `POST /_admin/v1/buckets/:bucket/directories` | 否 |
| `DeleteDirectory` | `object_storage` | `admin` | `DELETE /_admin/v1/buckets/:bucket/directories` | 否 |
| `CleanupDirectory` | `object_storage` | `admin` | `POST /_admin/v1/buckets/:bucket/directories/cleanup` | 否 |
| `SetObjectLegalHold` | `object_storage` | `admin` | `PATCH /_admin/v1/buckets/:bucket/legal-hold` | 否 |
| `PresignObject` | `object_storage` | `admin` | `POST /_admin/v1/objects/presign` | 否 |
| `CreateMultipartUpload` | `object_storage` | `admin` | `POST /_admin/v1/multipart-uploads` | 否 |
| `ListParts` | `object_storage` | `admin` | `GET /_admin/v1/multipart-uploads/:id` | 是 |
| `CompleteMultipartUpload` | `object_storage` | `admin` | `POST /_admin/v1/multipart-uploads/:id/complete` | 否 |
| `AbortMultipartUpload` | `object_storage` | `admin` | `DELETE /_admin/v1/multipart-uploads/:id` | 否 |
| `GetStorage` | `system_management` | `admin` | `GET /_admin/v1/storage` | 是 |
| `GetStorageScanner` | `system_management` | `admin` | `GET /_admin/v1/storage/scanner` | 是 |
| `RunGarbageCollection` | `system_management` | `admin` | `POST /_admin/v1/storage/gc` | 否 |
| `GetSystemInfo` | `system_management` | `admin` | `GET /_admin/v1/system` | 是 |
| `GetSettings` | `system_management` | `admin` | `GET /_admin/v1/settings` | 是 |
| `GetManagementHealth` | `system_management` | `admin` | `GET /_admin/v1/health` | 是 |
| `GetLogConfiguration` | `system_management` | `admin` | `GET /_admin/v1/settings/logs` | 是 |
| `UpdateLogConfiguration` | `system_management` | `admin` | `PUT /_admin/v1/settings/logs` | 否 |
| `QueryRuntimeLogs` | `system_management` | `admin` | `GET /_admin/v1/settings/logs/query` | 是 |
| `DownloadRuntimeLogs` | `system_management` | `admin` | `GET /_admin/v1/settings/logs/download` | 是 |
| `ListAuditEvents` | `system_management` | `admin` | `GET /_admin/v1/audit-events` | 是 |
| `ListAuditOperations` | `system_management` | `admin` | `GET /_admin/v1/audit-events/options` | 是 |
| `ListBucketAuditEvents` | `system_management` | `admin` | `GET /_admin/v1/buckets/:bucket/events` | 是 |
| `GetKMSConfiguration` | `kms` | `kms` | `GET /_admin/v1/settings/kms` | 是 |
| `UpdateKMSConfiguration` | `kms` | `kms` | `PUT /_admin/v1/settings/kms` | 否 |
| `StartKMS` | `kms` | `kms` | `POST /_admin/v1/settings/kms/start` | 否 |
| `StopKMS` | `kms` | `kms` | `POST /_admin/v1/settings/kms/stop` | 否 |
| `ClearKMSCache` | `kms` | `kms` | `POST /_admin/v1/settings/kms/clear-cache` | 否 |
| `ListKeys` | `kms` | `kms` | `GET /_admin/v1/settings/kms/keys` | 是 |
| `CreateKey` | `kms` | `kms` | `POST /_admin/v1/settings/kms/keys` | 否 |
| `KeyAction` | `kms` | `kms` | `POST /_admin/v1/settings/kms/keys/action` | 否 |
| `DeleteKey` | `kms` | `kms` | `kms:delete` | 否 |
| `ScheduleKeyDeletion` | `kms` | `kms` | `kms:schedule-deletion` | 否 |
| `CancelKeyDeletion` | `kms` | `kms` | `kms:cancel-deletion` | 否 |
| `RotateKey` | `kms` | `kms` | `kms:rotate` | 否 |
| `AssumeRoleWithWebIdentity` | `identity` | `sts` | `sts:AssumeRoleWithWebIdentity` | 否 |

## 记录范围与边界

- 已接入 ZigFS 的管理 API 和 S3 统一请求链路，包括读取、变更、认证失败、权限拒绝、参数错误及服务端错误。新增请求 ID 与独立事件 ID 不混用。
- 登录、会话、普通退出及 OIDC/STS 流程已接入。普通退出仍由 BFF 清 Cookie，不改变无状态令牌原有有效期；OIDC 退出保留原会话撤销行为。
- S3 复制当前归类为 PutObject，分段复制为 UploadPart；移动/重命名的复制和删除分别记录。批量操作每个 HTTP 请求一条，不为每个子项目生成记录；HTTP 200 的部分子项失败不自动改为整条 failure。
- 公开 `/health/live`、`/health/ready`、指标监听器上的 `/metrics` 和 OPTIONS 不记录。类似 `/health/object.txt` 的普通 S3 资源不会被排除。
- BFF/浏览器转发前拒绝的请求、前端校验失败、无效 HTTP 连接、静态资源不是 ZigFS API 审计事件。
- 后台自动 GC、恢复、生命周期任务、日志自动清理、SSE 内部加解密、外部 KMS 内部事件未逐项审计；手动触发的 API 会记录。
- 尚未实现 Webhook、Kafka、持久化分发队列、防篡改、配置前后差异或每个批量子项目审计。

## 保存和兼容

审计数据默认位于 `data/audit-logs/audit-*.log`，文件权限 0600。写入级别、格式、目录、轮转、保留时间、下载权限及默认查询范围由独立的 `data/.zigfs/config/audit_log_config.json` 控制；输出固定为文件。旧的 `data/.zigfs/system/audit-events.json` 和 `audit-archive/` 在首次启动时幂等导入，原文件作为只读迁移备份保留，不再写入或参与查询。系统日志配置不控制审计。

旧记录读取时转换为 V1，并设置 `metadata.legacy=true`；旧记录没有采集的真实身份 ID、认证类型、来源 IP、耗时、HTTP 错误码不补造。历史事件 ID 按原始记录确定性生成，重启后保持不变。六个原有平铺字段暂时保留，用于 Bucket 事件客户端兼容。

审计为本地普通持久化记录，不是不可变外部仓库。磁盘故障、进程强制终止时不保证零丢失；归档查询扫描文件，偏移分页在并发新增记录时不提供快照隔离。

## 验证情况

- Zig 单元测试：分类/标准操作映射、KMS 显式动作优先级、结果分类、历史记录迁移、全局与 Bucket 查询、分页、归档恢复及探针排除边界。
- `conformance/audit_events.py`：实际服务 V1 结构、目录和组合筛选、管理及 S3 操作、真实身份、独立事件 ID、资源字段、来源 IP 防伪造、Query 白名单、敏感信息排除、运行日志关闭时继续审计、旧数据及重启恢复。
- Go：筛选与结构化 JSON 透传；前端：构建、语言目录、筛选联动、操作搜索、详情、分页和错误提示。

表中操作的接入依据为统一请求链路和映射目录，不代表已经逐一执行过每个 API 的端到端测试。


新增审计日志配置操作：`GetAuditLogSettings`、`UpdateAuditLogSettings`、
`QueryAuditLogs`、`DownloadAuditLogs`，均归类为 `system_management`。
审计级别与保留策略见 [audit-log-configuration.md](audit-log-configuration.md)。
