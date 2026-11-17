# CLI 批量接入清单（待验证）

由 `python3 zigfs-cli/scripts/generate_coverage.py` 静态生成；仅核对注册表，不能替代运行验证。

单机 S3 与旧协议共 **100** 项；保留原有已验收路径，新增字段及命令均待验证。多机复制和云端可选 API 不注册。

完整请求字段来自 `src/models/s3.json`；默认通过 `s3api OP ALIAS --input-json FILE` 提交，复杂字段不要求每个高层入口都有独立短选项。

| S3 operation | s3api 入口 | 高层映射 / 已有路径 | 批量接入状态 |
|---|---|---|---|
| `abort-multipart-upload` | `s3api abort-multipart-upload` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `complete-multipart-upload` | `s3api complete-multipart-upload` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `copy-object` | `s3api copy-object` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `create-bucket` | `s3api create-bucket` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `create-multipart-upload` | `s3api create-multipart-upload` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `delete-bucket` | `s3api delete-bucket` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `delete-bucket-analytics-configuration` | `s3api delete-bucket-analytics-configuration` | `bucket analytics remove` | 新路径/扩展字段待验证 |
| `delete-bucket-cors` | `s3api delete-bucket-cors` | `bucket cors clear` | 新路径/扩展字段待验证 |
| `delete-bucket-encryption` | `s3api delete-bucket-encryption` | `bucket encryption clear` | 新路径/扩展字段待验证 |
| `delete-bucket-intelligent-tiering-configuration` | `s3api delete-bucket-intelligent-tiering-configuration` | `bucket intelligent-tiering remove` | 新路径/扩展字段待验证 |
| `delete-bucket-inventory-configuration` | `s3api delete-bucket-inventory-configuration` | `bucket inventory remove` | 新路径/扩展字段待验证 |
| `delete-bucket-lifecycle` | `s3api delete-bucket-lifecycle` | `bucket lifecycle clear` | 新路径/扩展字段待验证 |
| `delete-bucket-metrics-configuration` | `s3api delete-bucket-metrics-configuration` | `bucket metrics remove` | 新路径/扩展字段待验证 |
| `delete-bucket-ownership-controls` | `s3api delete-bucket-ownership-controls` | `bucket ownership clear` | 新路径/扩展字段待验证 |
| `delete-bucket-policy` | `s3api delete-bucket-policy` | `bucket policy clear` | 新路径/扩展字段待验证 |
| `delete-bucket-tagging` | `s3api delete-bucket-tagging` | `bucket tag clear` | 新路径/扩展字段待验证 |
| `delete-bucket-website` | `s3api delete-bucket-website` | `bucket website clear` | 新路径/扩展字段待验证 |
| `delete-object` | `s3api delete-object` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `delete-object-annotation` | `s3api delete-object-annotation` | `object annotation clear` | 新路径/扩展字段待验证 |
| `delete-object-tagging` | `s3api delete-object-tagging` | `object tag clear` | 新路径/扩展字段待验证 |
| `delete-objects` | `s3api delete-objects` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `delete-public-access-block` | `s3api delete-public-access-block` | `bucket public-access-block clear` | 新路径/扩展字段待验证 |
| `get-bucket-abac` | `s3api get-bucket-abac` | `bucket abac get` | 新路径/扩展字段待验证 |
| `get-bucket-accelerate-configuration` | `s3api get-bucket-accelerate-configuration` | `bucket accelerate get` | 新路径/扩展字段待验证 |
| `get-bucket-acl` | `s3api get-bucket-acl` | `bucket acl get` | 新路径/扩展字段待验证 |
| `get-bucket-analytics-configuration` | `s3api get-bucket-analytics-configuration` | `bucket analytics get` | 新路径/扩展字段待验证 |
| `get-bucket-cors` | `s3api get-bucket-cors` | `bucket cors get` | 新路径/扩展字段待验证 |
| `get-bucket-encryption` | `s3api get-bucket-encryption` | `bucket encryption get`、`bucket encryption info` | 新路径/扩展字段待验证 |
| `get-bucket-intelligent-tiering-configuration` | `s3api get-bucket-intelligent-tiering-configuration` | `bucket intelligent-tiering get` | 新路径/扩展字段待验证 |
| `get-bucket-inventory-configuration` | `s3api get-bucket-inventory-configuration` | `bucket inventory get` | 新路径/扩展字段待验证 |
| `get-bucket-lifecycle` | `s3api get-bucket-lifecycle` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `get-bucket-lifecycle-configuration` | `s3api get-bucket-lifecycle-configuration` | `bucket lifecycle get` | 新路径/扩展字段待验证 |
| `get-bucket-location` | `s3api get-bucket-location` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `get-bucket-logging` | `s3api get-bucket-logging` | `bucket logging get` | 新路径/扩展字段待验证 |
| `get-bucket-metrics-configuration` | `s3api get-bucket-metrics-configuration` | `bucket metrics get` | 新路径/扩展字段待验证 |
| `get-bucket-notification` | `s3api get-bucket-notification` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `get-bucket-notification-configuration` | `s3api get-bucket-notification-configuration` | `bucket notification get` | 新路径/扩展字段待验证 |
| `get-bucket-ownership-controls` | `s3api get-bucket-ownership-controls` | `bucket ownership get` | 新路径/扩展字段待验证 |
| `get-bucket-policy` | `s3api get-bucket-policy` | `bucket policy get` | 新路径/扩展字段待验证 |
| `get-bucket-policy-status` | `s3api get-bucket-policy-status` | `bucket policy status` | 新路径/扩展字段待验证 |
| `get-bucket-request-payment` | `s3api get-bucket-request-payment` | `bucket request-payment get` | 新路径/扩展字段待验证 |
| `get-bucket-tagging` | `s3api get-bucket-tagging` | `bucket tag get` | 新路径/扩展字段待验证 |
| `get-bucket-versioning` | `s3api get-bucket-versioning` | `bucket version get` | 新路径/扩展字段待验证 |
| `get-bucket-website` | `s3api get-bucket-website` | `bucket website get` | 新路径/扩展字段待验证 |
| `get-object` | `s3api get-object` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `get-object-acl` | `s3api get-object-acl` | `object acl get` | 新路径/扩展字段待验证 |
| `get-object-annotation` | `s3api get-object-annotation` | `object annotation get` | 新路径/扩展字段待验证 |
| `get-object-attributes` | `s3api get-object-attributes` | `object attributes` | 新路径/扩展字段待验证 |
| `get-object-legal-hold` | `s3api get-object-legal-hold` | `object legalhold get`、`object legalhold info` | 新路径/扩展字段待验证 |
| `get-object-lock-configuration` | `s3api get-object-lock-configuration` | `bucket lock get`、`bucket lock info` | 新路径/扩展字段待验证 |
| `get-object-retention` | `s3api get-object-retention` | `object retention get`、`object retention info` | 新路径/扩展字段待验证 |
| `get-object-tagging` | `s3api get-object-tagging` | `object tag get` | 新路径/扩展字段待验证 |
| `get-object-torrent` | `s3api get-object-torrent` | `object torrent` | 新路径/扩展字段待验证 |
| `get-public-access-block` | `s3api get-public-access-block` | `bucket public-access-block get` | 新路径/扩展字段待验证 |
| `head-bucket` | `s3api head-bucket` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `head-object` | `s3api head-object` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `list-bucket-analytics-configurations` | `s3api list-bucket-analytics-configurations` | `bucket analytics list` | 新路径/扩展字段待验证 |
| `list-bucket-intelligent-tiering-configurations` | `s3api list-bucket-intelligent-tiering-configurations` | `bucket intelligent-tiering list` | 新路径/扩展字段待验证 |
| `list-bucket-inventory-configurations` | `s3api list-bucket-inventory-configurations` | `bucket inventory list` | 新路径/扩展字段待验证 |
| `list-bucket-metrics-configurations` | `s3api list-bucket-metrics-configurations` | `bucket metrics list` | 新路径/扩展字段待验证 |
| `list-buckets` | `s3api list-buckets` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `list-multipart-uploads` | `s3api list-multipart-uploads` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `list-object-annotations` | `s3api list-object-annotations` | `object annotation list` | 新路径/扩展字段待验证 |
| `list-object-versions` | `s3api list-object-versions` | `bucket version list` | 新路径/扩展字段待验证 |
| `list-objects` | `s3api list-objects` | `object list-v1` | 新路径/扩展字段待验证 |
| `list-objects-v2` | `s3api list-objects-v2` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `list-parts` | `s3api list-parts` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `put-bucket-abac` | `s3api put-bucket-abac` | `bucket abac set` | 新路径/扩展字段待验证 |
| `put-bucket-accelerate-configuration` | `s3api put-bucket-accelerate-configuration` | `bucket accelerate set` | 新路径/扩展字段待验证 |
| `put-bucket-acl` | `s3api put-bucket-acl` | `bucket acl set` | 新路径/扩展字段待验证 |
| `put-bucket-analytics-configuration` | `s3api put-bucket-analytics-configuration` | `bucket analytics set` | 新路径/扩展字段待验证 |
| `put-bucket-cors` | `s3api put-bucket-cors` | `bucket cors set` | 新路径/扩展字段待验证 |
| `put-bucket-encryption` | `s3api put-bucket-encryption` | `bucket encryption set` | 新路径/扩展字段待验证 |
| `put-bucket-intelligent-tiering-configuration` | `s3api put-bucket-intelligent-tiering-configuration` | `bucket intelligent-tiering set` | 新路径/扩展字段待验证 |
| `put-bucket-inventory-configuration` | `s3api put-bucket-inventory-configuration` | `bucket inventory set` | 新路径/扩展字段待验证 |
| `put-bucket-lifecycle` | `s3api put-bucket-lifecycle` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `put-bucket-lifecycle-configuration` | `s3api put-bucket-lifecycle-configuration` | `bucket lifecycle set` | 新路径/扩展字段待验证 |
| `put-bucket-logging` | `s3api put-bucket-logging` | `bucket logging set` | 新路径/扩展字段待验证 |
| `put-bucket-metrics-configuration` | `s3api put-bucket-metrics-configuration` | `bucket metrics set` | 新路径/扩展字段待验证 |
| `put-bucket-notification` | `s3api put-bucket-notification` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `put-bucket-notification-configuration` | `s3api put-bucket-notification-configuration` | `bucket notification set` | 新路径/扩展字段待验证 |
| `put-bucket-ownership-controls` | `s3api put-bucket-ownership-controls` | `bucket ownership set` | 新路径/扩展字段待验证 |
| `put-bucket-policy` | `s3api put-bucket-policy` | `bucket policy set` | 新路径/扩展字段待验证 |
| `put-bucket-request-payment` | `s3api put-bucket-request-payment` | `bucket request-payment set` | 新路径/扩展字段待验证 |
| `put-bucket-tagging` | `s3api put-bucket-tagging` | `bucket tag set` | 新路径/扩展字段待验证 |
| `put-bucket-versioning` | `s3api put-bucket-versioning` | `bucket version set` | 新路径/扩展字段待验证 |
| `put-bucket-website` | `s3api put-bucket-website` | `bucket website set` | 新路径/扩展字段待验证 |
| `put-object` | `s3api put-object` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `put-object-acl` | `s3api put-object-acl` | `object acl set` | 新路径/扩展字段待验证 |
| `put-object-annotation` | `s3api put-object-annotation` | `object annotation set` | 新路径/扩展字段待验证 |
| `put-object-legal-hold` | `s3api put-object-legal-hold` | `object legalhold set` | 新路径/扩展字段待验证 |
| `put-object-lock-configuration` | `s3api put-object-lock-configuration` | `bucket lock set` | 新路径/扩展字段待验证 |
| `put-object-retention` | `s3api put-object-retention` | `object retention set` | 新路径/扩展字段待验证 |
| `put-object-tagging` | `s3api put-object-tagging` | `object tag set` | 新路径/扩展字段待验证 |
| `put-public-access-block` | `s3api put-public-access-block` | `bucket public-access-block set` | 新路径/扩展字段待验证 |
| `restore-object` | `s3api restore-object` | `object restore` | 新路径/扩展字段待验证 |
| `select-object-content` | `s3api select-object-content` | `sql` | 新路径/扩展字段待验证 |
| `update-object-encryption` | `s3api update-object-encryption` | `object encryption update` | 新路径/扩展字段待验证 |
| `upload-part` | `s3api upload-part` | 使用 s3api 原始入口；已有便利入口另见 README | 新路径/扩展字段待验证 |
| `upload-part-copy` | `s3api upload-part-copy` | `multipart copy-part` | 新路径/扩展字段待验证 |

## Management 路由

独立管理端点、Bearer 会话；具体请求 JSON 见 `docs/api/zigfs-management-v1.openapi.yaml` 和各命令 `--help`。源代码新增、OpenAPI 尚未描述的请求，由服务端校验；不宣称拥有完整本地 schema。

| CLI 入口 | HTTP | 位置参数（ALIAS 后） | 状态 |
|---|---|---|---|
| `admin access-key create` | `POST /_admin/v1/access-keys` | — | 待验证 |
| `admin access-key list` | `GET /_admin/v1/access-keys` | — | 待验证 |
| `admin access-key remove` | `DELETE /_admin/v1/access-keys/{id}` | id | 待验证 |
| `admin access-key update` | `PATCH /_admin/v1/access-keys/{id}` | id | 待验证 |
| `admin audit-events get` | `GET /_admin/v1/audit-events` | — | 待验证 |
| `admin audit-events options get` | `GET /_admin/v1/audit-events/options` | — | 待验证 |
| `admin audit-logs download` | `GET /_admin/v1/settings/audit-logs/download` | — | 待验证 |
| `admin audit-logs get` | `GET /_admin/v1/settings/audit-logs` | — | 待验证 |
| `admin audit-logs query` | `GET /_admin/v1/settings/audit-logs/query` | — | 待验证 |
| `admin audit-logs set` | `PUT /_admin/v1/settings/audit-logs` | — | 待验证 |
| `admin auth login` | `POST /_admin/v1/auth/login` | — | 待验证 |
| `admin auth logout` | `POST /_admin/v1/auth/logout` | — | 待验证 |
| `admin auth oidc backchannel-logout` | `POST /_admin/v1/auth/oidc/backchannel-logout` | — | 待验证 |
| `admin auth oidc callback` | `POST /_admin/v1/auth/oidc/callback` | — | 待验证 |
| `admin auth oidc end-session` | `POST /_admin/v1/auth/oidc/end-session` | — | 待验证 |
| `admin auth oidc logout` | `POST /_admin/v1/auth/oidc/logout` | — | 待验证 |
| `admin auth oidc providers` | `GET /_admin/v1/auth/oidc/providers` | — | 待验证 |
| `admin auth oidc refresh` | `POST /_admin/v1/auth/oidc/refresh` | — | 待验证 |
| `admin auth oidc start` | `POST /_admin/v1/auth/oidc/start` | — | 待验证 |
| `admin auth oidc web-identity` | `POST /_admin/v1/auth/oidc/web-identity` | — | 待验证 |
| `admin auth session` | `GET /_admin/v1/auth/session` | — | 待验证 |
| `admin bucket configuration get` | `GET /_admin/v1/buckets/{name}/configuration` | name | 待验证 |
| `admin bucket configuration set` | `PATCH /_admin/v1/buckets/{name}/configuration` | name | 待验证 |
| `admin bucket create` | `POST /_admin/v1/buckets` | — | 待验证 |
| `admin bucket events get` | `GET /_admin/v1/buckets/{name}/events` | name | 待验证 |
| `admin bucket list` | `GET /_admin/v1/buckets` | — | 待验证 |
| `admin bucket objects get` | `GET /_admin/v1/buckets/{name}/objects` | name | 待验证 |
| `admin bucket remove` | `DELETE /_admin/v1/buckets/{name}` | name | 待验证 |
| `admin bucket usage get` | `GET /_admin/v1/buckets/{name}/usage` | name | 待验证 |
| `admin bucket versions get` | `GET /_admin/v1/buckets/{name}/versions` | name | 待验证 |
| `admin bucket watch get` | `GET /_admin/v1/buckets/{name}/watch` | name | 待验证 |
| `admin diagnostics get` | `GET /_admin/v1/monitoring/diagnostics` | — | 待验证 |
| `admin diagnostics set` | `PUT /_admin/v1/monitoring/diagnostics` | — | 待验证 |
| `admin directory cleanup` | `POST /_admin/v1/buckets/{name}/directories/cleanup` | name | 待验证 |
| `admin directory create` | `POST /_admin/v1/buckets/{name}/directories` | name | 待验证 |
| `admin directory remove` | `DELETE /_admin/v1/buckets/{name}/directories` | name | 待验证 |
| `admin event-destination create` | `POST /_admin/v1/event-destinations` | — | 待验证 |
| `admin event-destination list` | `GET /_admin/v1/event-destinations` | — | 待验证 |
| `admin event-destination remove` | `DELETE /_admin/v1/event-destinations/{name}` | name | 待验证 |
| `admin event-destination set` | `PUT /_admin/v1/event-destinations/{name}` | name | 待验证 |
| `admin event-subscription get` | `GET /_admin/v1/buckets/{name}/event-subscriptions` | name | 待验证 |
| `admin event-subscription set` | `PUT /_admin/v1/buckets/{name}/event-subscriptions` | name | 待验证 |
| `admin group create` | `POST /_admin/v1/groups` | — | 待验证 |
| `admin group info` | `GET /_admin/v1/groups/{name}` | name | 待验证 |
| `admin group list` | `GET /_admin/v1/groups` | — | 待验证 |
| `admin group remove` | `DELETE /_admin/v1/groups/{name}` | name | 待验证 |
| `admin group update` | `PATCH /_admin/v1/groups/{name}` | name | 待验证 |
| `admin health` | `GET /_admin/v1/health` | — | 待验证 |
| `admin kms clear-cache` | `POST /_admin/v1/settings/kms/clear-cache` | — | 待验证 |
| `admin kms info` | `GET /_admin/v1/settings/kms` | — | 待验证 |
| `admin kms key action` | `POST /_admin/v1/settings/kms/keys/action` | — | 待验证 |
| `admin kms key create` | `POST /_admin/v1/settings/kms/keys` | — | 待验证 |
| `admin kms key list` | `GET /_admin/v1/settings/kms/keys` | — | 待验证 |
| `admin kms set` | `PUT /_admin/v1/settings/kms` | — | 待验证 |
| `admin kms start` | `POST /_admin/v1/settings/kms/start` | — | 待验证 |
| `admin kms stop` | `POST /_admin/v1/settings/kms/stop` | — | 待验证 |
| `admin logs download` | `GET /_admin/v1/settings/logs/download` | — | 待验证 |
| `admin logs get` | `GET /_admin/v1/settings/logs` | — | 待验证 |
| `admin logs query` | `GET /_admin/v1/settings/logs/query` | — | 待验证 |
| `admin logs set` | `PUT /_admin/v1/settings/logs` | — | 待验证 |
| `admin monitoring` | `GET /_admin/v1/monitoring` | — | 待验证 |
| `admin multipart abort` | `DELETE /_admin/v1/multipart-uploads/{uploadId}` | uploadId | 待验证 |
| `admin multipart complete` | `POST /_admin/v1/multipart-uploads/{uploadId}/complete` | uploadId | 待验证 |
| `admin multipart create` | `POST /_admin/v1/multipart-uploads` | — | 待验证 |
| `admin multipart info` | `GET /_admin/v1/multipart-uploads/{uploadId}` | uploadId | 待验证 |
| `admin multipart list` | `GET /_admin/v1/buckets/{name}/multipart-uploads` | name | 待验证 |
| `admin object legalhold set` | `PATCH /_admin/v1/buckets/{name}/legal-hold` | name | 待验证 |
| `admin object presign` | `POST /_admin/v1/objects/presign` | — | 待验证 |
| `admin oidc validate invoke` | `POST /_admin/v1/oidc/validate` | — | 待验证 |
| `admin oidc-provider create` | `POST /_admin/v1/oidc/providers` | — | 待验证 |
| `admin oidc-provider list` | `GET /_admin/v1/oidc/providers` | — | 待验证 |
| `admin oidc-provider remove` | `DELETE /_admin/v1/oidc/providers/{id}` | id | 待验证 |
| `admin oidc-provider update` | `PATCH /_admin/v1/oidc/providers/{id}` | id | 待验证 |
| `admin organization create` | `POST /_admin/v1/organizations` | — | 待验证 |
| `admin organization list` | `GET /_admin/v1/organizations` | — | 待验证 |
| `admin organization remove` | `DELETE /_admin/v1/organizations/{name}` | name | 待验证 |
| `admin organization update` | `PATCH /_admin/v1/organizations/{name}` | name | 待验证 |
| `admin policy create` | `POST /_admin/v1/policies` | — | 待验证 |
| `admin policy info` | `GET /_admin/v1/policies/{name}` | name | 待验证 |
| `admin policy list` | `GET /_admin/v1/policies` | — | 待验证 |
| `admin policy remove` | `DELETE /_admin/v1/policies/{name}` | name | 待验证 |
| `admin policy update` | `PATCH /_admin/v1/policies/{name}` | name | 待验证 |
| `admin role create` | `POST /_admin/v1/roles` | — | 待验证 |
| `admin role list` | `GET /_admin/v1/roles` | — | 待验证 |
| `admin role remove` | `DELETE /_admin/v1/roles/{name}` | name | 待验证 |
| `admin role update` | `PATCH /_admin/v1/roles/{name}` | name | 待验证 |
| `admin role-session create` | `POST /_admin/v1/sts/assume-role` | — | 待验证 |
| `admin role-session list` | `GET /_admin/v1/role-sessions` | — | 待验证 |
| `admin role-session remove` | `DELETE /_admin/v1/role-sessions/{access_key}` | access_key | 待验证 |
| `admin role-sessions revoke invoke` | `POST /_admin/v1/role-sessions/{access_key}/revoke` | access_key | 待验证 |
| `admin settings authentication get` | `GET /_admin/v1/settings/authentication` | — | 待验证 |
| `admin settings authentication set` | `PUT /_admin/v1/settings/authentication` | — | 待验证 |
| `admin settings display get` | `GET /_admin/v1/settings/display` | — | 待验证 |
| `admin settings display set` | `PUT /_admin/v1/settings/display` | — | 待验证 |
| `admin settings get` | `GET /_admin/v1/settings` | — | 待验证 |
| `admin settings instance get` | `GET /_admin/v1/settings/instance` | — | 待验证 |
| `admin settings instance set` | `PUT /_admin/v1/settings/instance` | — | 待验证 |
| `admin settings listener set` | `PUT /_admin/v1/settings/listener` | — | 待验证 |
| `admin settings network set` | `PUT /_admin/v1/settings/network` | — | 待验证 |
| `admin settings region get` | `GET /_admin/v1/settings/region` | — | 待验证 |
| `admin settings region set` | `PUT /_admin/v1/settings/region` | — | 待验证 |
| `admin storage gc` | `POST /_admin/v1/storage/gc` | — | 待验证 |
| `admin storage info` | `GET /_admin/v1/storage` | — | 待验证 |
| `admin storage scanner` | `GET /_admin/v1/storage/scanner` | — | 待验证 |
| `admin system` | `GET /_admin/v1/system` | — | 待验证 |
| `admin user access-key create` | `POST /_admin/v1/users/{name}/access-keys` | name | 待验证 |
| `admin user access-key list` | `GET /_admin/v1/users/{name}/access-keys` | name | 待验证 |
| `admin user access-key remove` | `DELETE /_admin/v1/users/{name}/access-keys/{id}` | name, id | 待验证 |
| `admin user access-key update` | `PATCH /_admin/v1/users/{name}/access-keys/{id}` | name, id | 待验证 |
| `admin user create` | `POST /_admin/v1/users` | — | 待验证 |
| `admin user info` | `GET /_admin/v1/users/{name}` | name | 待验证 |
| `admin user list` | `GET /_admin/v1/users` | — | 待验证 |
| `admin user remove` | `DELETE /_admin/v1/users/{name}` | name | 待验证 |
| `admin user update` | `PATCH /_admin/v1/users/{name}` | name | 待验证 |

## 高层兼容与便利入口

| 命令 | 分派目标 | 状态 |
|---|---|---|
| `admin access-key add` | `admin access-key create` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin access-key info` | `admin access-key info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin access-key ls` | `admin access-key list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin access-key rm` | `admin access-key remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group add` | `admin group create` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group add-members` | `admin group add-members` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group disable` | `admin group disable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group enable` | `admin group enable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group ls` | `admin group list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group rm` | `admin group remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin group rm-members` | `admin group rm-members` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid disable` | `admin oidc-provider disable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid enable` | `admin oidc-provider enable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid get` | `admin oidc-provider info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid list` | `admin oidc-provider list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid set` | `admin oidc-provider create` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid update` | `admin oidc-provider update` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin idp openid validate` | `admin oidc-provider validate` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms configure` | `admin kms set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms key cancel-deletion` | `admin kms key cancel-deletion` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms key delete` | `admin kms key delete` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms key rotate` | `admin kms key rotate` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms key schedule-deletion` | `admin kms key schedule-deletion` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms key status` | `admin kms key status` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms reconfigure` | `admin kms set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin kms status` | `admin kms info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin object legalhold clear` | `admin object legalhold clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin oidc-provider disable` | `admin oidc-provider disable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin oidc-provider enable` | `admin oidc-provider enable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin oidc-provider info` | `admin oidc-provider info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin oidc-provider validate` | `admin oidc-provider validate` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin policy add` | `admin policy create` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin policy attach` | `admin policy attach` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin policy detach` | `admin policy detach` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin policy entities` | `admin policy entities` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin policy ls` | `admin policy list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin policy rm` | `admin policy remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin role-session revoke` | `admin role-sessions revoke invoke` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin user add` | `admin user create` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin user disable` | `admin user disable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin user enable` | `admin user enable` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin user ls` | `admin user list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `admin user rm` | `admin user remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `anonymous get-json` | `anonymous get-json` | 已接入；具体分支/边界见缺口登记，待验证 |
| `anonymous links` | `anonymous links` | 已接入；具体分支/边界见缺口登记，待验证 |
| `anonymous set-json` | `anonymous set-json` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket anonymous get` | `anonymous get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket anonymous get-json` | `anonymous get-json` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket anonymous links` | `anonymous links` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket anonymous list` | `anonymous list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket anonymous set` | `anonymous set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket anonymous set-json` | `anonymous set-json` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket event add` | `event add` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket event clear` | `event clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket event get` | `event get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket event list` | `event list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket event remove` | `event remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket event set` | `event set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket quota clear` | `quota clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket quota info` | `quota info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket quota set` | `quota set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket tag list` | `bucket tag get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket tag remove` | `bucket tag remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `bucket version info` | `bucket version get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `cors get` | `bucket cors get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `cors list` | `bucket cors get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `cors remove` | `bucket cors clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `cors set` | `bucket cors set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `event add` | `event add` | 已接入；具体分支/边界见缺口登记，待验证 |
| `event list` | `event list` | 已接入；具体分支/边界见缺口登记，待验证 |
| `event remove` | `event remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `ilm restore` | `object restore` | 已接入；具体分支/边界见缺口登记，待验证 |
| `legalhold clear` | `object legalhold clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `legalhold info` | `object legalhold info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `legalhold set` | `object legalhold set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object find` | `find` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object legal-hold clear` | `object legalhold clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object legal-hold info` | `object legalhold info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object legal-hold set` | `object legalhold set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object legalhold clear` | `object legalhold clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object retention clear` | `object retention clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object tag list` | `object tag get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object tag remove` | `object tag remove` | 已接入；具体分支/边界见缺口登记，待验证 |
| `object tree` | `tree` | 已接入；具体分支/边界见缺口登记，待验证 |
| `retention clear` | `object retention clear` | 已接入；具体分支/边界见缺口登记，待验证 |
| `retention info` | `object retention info` | 已接入；具体分支/边界见缺口登记，待验证 |
| `retention set` | `object retention set` | 已接入；具体分支/边界见缺口登记，待验证 |
| `tag list` | `tag get` | 已接入；具体分支/边界见缺口登记，待验证 |
| `tag remove` | `tag remove` | 已接入；具体分支/边界见缺口登记，待验证 |

## 本次接入边界

- 集中审查 R01–R08 已补写逻辑、待验证：ListBuckets 分页、历史删除参数与部分失败汇总、扫描资源预算与过滤、工作流参数校验、原错误保留及帮助更新。详见 [集中静态审查清单](../docs/zigfs-zc-cli-static-review.md)。
- 字段处理补全（待验证）：新旧请求共享元数据 header-map 提取；模型化响应保留 data.metadata；生命周期编辑与文件往返保留 TransitionDefaultMinimumObjectSize。旧 Rules-only 导入仍由服务端决定未指定设置的缺省值。
- 最新逐项状态见 [缺口补全登记](../docs/zigfs-zc-cli-gap-audit.md)。注册数量不证明所有分支或参数组合已实现。
- 接续补全：retention bypass 请求字段、mirror 连接覆盖参数、模型/管理 JSON stdin、KMS create/status 便利参数、OIDC 保留现值更新、管理动作帮助；全部待验证。
- OIDC update 无 CAS，须串行写入；上游 KMS tag/列表分页/restart/roundtrip、Access Key provider 聚合过滤不属于当前已接入契约。用户专属密钥使用 admin user access-key list。
- 本轮缺口补全仅修改逻辑、生成模型/清单和格式化；没有编译、测试、CLI 请求或服务端联调。现有二进制未重建。
- watch 已接入真实成功对象事件的游标长轮询，需新版服务端及 admin:* Bearer 权限；4096 条 / 8 MiB 内存回放，重启或游标过期明确失败。不是持久化队列，不承诺无损或 exactly-once。
- mirror --watch 为周期性完整比较/同步；include/exclude 过滤同样保护目标删除。默认不删除，覆盖须 --overwrite --yes，删除须 --remove --yes。远端扫描须 --fallback。
- tree 输出分层结构，--level 截断标记 view_truncated；find 支持 * / ? GLOB、POSIX ERE 和相对时间过滤。du 优先管理快照，支持服务范围、版本和未完成分片扫描。
- 本地同步根目录须存在，拒绝符号链接和不安全名称。扫描最多 100000 项 / 64 MiB；树最多 200000 节点。
- 同实例比较 size+ETag，本地与远端保守复制；不把 ETag 当通用内容哈希。版本化移动须明确 --version-id；清桶与同步不锁并发写入。
- 配置便利语法与原始 s3api JSON 并存；tag remove 按键保留其他标签，event 按 ID 增删，生命周期导出可直接导入。S3 配置读改写无 CAS，需串行修改。
- IAM 成员/策略修改携带 expected_updated_at；OIDC 机密使用配置文件。KMS 计划删除仅支持服务端的 7 天窗口，立即删除需额外确认。
- 扩展 SSE/校验/条件字段通过 s3api 完整 JSON；自动分片恢复、stdout 下载、行截取与扩展字段的部分组合仍显式拒绝。
- SHA256 可自动计算；其他上传校验算法需提供校验值。SSE-C 密钥/MD5 使用 Base64；日期头使用 HTTP 日期，XML 时间使用 ISO 8601。
- Select 按帧校验 CRC 并输出 Records，错误或缺少 End 不发布文件；服务端集成行为待验证。
- 对象归档、报表、ABAC、加速、网站等客户端接入不等于服务端实现；501 不算通过。多机、云专属 API 和缺少独立契约的 service-account/MFA/IAM archive 不在本轮范围。
