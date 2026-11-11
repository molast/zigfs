# ZigFS Audit Event Schema V1.0

实现依据：[rustfs-audit-log-schema-v1.md](../plans/rustfs-audit-log-schema-v1.md)。实际操作覆盖见 [audit-coverage.md](audit-coverage.md)。

## 事件结构

新事件包含规范中的 `schema_version`、`event_id`、`event_time`、`event_category`、`event_type`、`event_action` 和 `request`、`identity`、`resource`、`operation`、`response`、`metadata` 分组。

- `schema_version="1.0"`，`event_id="evt_" + 随机 UUID`，不使用客户端提供的 Request ID 作为事件 ID。
- `event_time` 使用 UTC RFC 3339，精度为毫秒。运行日志通过 `request.request_id` 关联。
- `event_action` 和 `operation.name` 使用稳定名称，如 PutObject、CreateUser、UpdateLogConfiguration、RotateKey，不含动态路径或用户名。
- `operation.service` 为 s3/admin/kms/sts。`operation.is_read_only` 来自操作目录，未知操作按 GET/HEAD 推断。
- HTTP 401/403 → `denied`、`security`、`security_event`，但操作名称和资源仍保留。
- 其他 4xx → `failure`；5xx → `error`；已取得的 2xx/3xx → `success`；缺少状态的历史事件 → `unknown`。请求处理异常采用 500，不能保证客户端已收到响应。

## 请求、身份和资源

`request.method`、`protocol`、`path`、`user_agent`、`source_ip` 在请求体读取前保存。User-Agent 最长 1024 字节。

`source_ip` 当前仅使用 ZigFS TCP 对端地址，不信任 X-Forwarded-For 或 X-Real-IP。经 BFF/反向代理时，该字段显示 BFF/代理地址；当前没有可信代理配置，不能声称这是原始浏览器地址。

Query 仅保留 `versionId`、`uploadId`、`prefix`、`key`，每项最多 2048 字节并解码。签名、凭证及 Token 查询参数不在白名单。原始 path 不包含查询字符串。

身份只在验证成功后填写：

| auth_type | 来源 |
| --- | --- |
| s3_access_key | 已验证 S3 AK/SK 请求，记录 AK ID，绝不记录 SK |
| sts | 已验证临时凭证请求 |
| oidc | 已验证 OIDC/Web Identity |
| internal | 已验证内部管理会话 |
| anonymous | 未验证身份，包括认证失败 |
| unknown | 仅用于无法确认原认证方式的历史记录 |

`principal_id` 使用认证模块提供的主体 ID；没有主体 ID 时为 null，不把用户名假装成 ID。`session_id` 当前为 null，不将实际会话令牌放入该字段。

资源包含 type、bucket、object_key、version_id；为管理资源额外允许 `name`。S3 资源由解析后的目标提取；管理 Bucket 路由提取 Bucket；创建 Bucket、用户/组、策略、目录、预签名对象、KMS Key 额外提取所需的非敏感资源标识。集合读取时不把路由名（例如 users 或 keys）当作具体资源名称。无法确定资源时留空。

## 可选字段及扩展边界

- `response.duration_ms` 为服务器处理耗时，不含审计持久化时间。历史记录展示“—”，不把结构默认值 0 当成实测值。
- `response.error_code`、`error_message` 当前为 null：尚未统一采集处理器返回的领域错误；不从正文提取内部路径、凭证或堆栈，也不伪造领域错误码。
- `metadata.region` 使用实例区域。没有稳定实例 ID 配置时，server_id 为 null。
- `system_event`、Webhook、Kafka 等仅是规范中的扩展方向，本次未实现。
- 原有 timestamp_unix_seconds/request_id/actor/action/target/outcome 作为弃用兼容字段保留；新页面及新筛选使用结构化字段。Bucket 的旧 BFF 响应继续使用兼容字段。

## 查询与操作目录

全局查询：`GET /_admin/v1/audit-events`；BFF 对应 `/api/v1/audit-events`。

| 参数 | 说明 |
| --- | --- |
| cursor | 非负整数偏移游标 |
| limit | 1–200，默认 50 |
| from / to | Unix 秒，包含边界 |
| category | 7 种 event_category 之一 |
| action | 标准 event_action 精确匹配；旧 action 精确值仍兼容 |
| outcome | success/failure/denied/error/unknown；旧完整 outcome 仍支持精确匹配 |
| actor | 主体名称或 ID，精确匹配 |
| bucket | resource.bucket 精确匹配 |
| request_id | request.request_id 精确匹配 |
| source_ip | request.source_ip 精确匹配 |
| service | operation.service 精确匹配 |
| event_type | event_type 精确匹配 |

条件之间为 AND。返回 `{items,next_cursor}`，items 为 V1 结构。全局接口要求管理权限；BFF 只转发，不直接读取数据目录。

目录：`GET /_admin/v1/audit-events/options`，BFF 对应 `/api/v1/audit-events/options`。返回 `{categories,operations}`，每项含 name、category、resource_type、service、is_read_only，以及服务端内部映射字段。UI 按分类及服务筛选、按名称去重，再提供可搜索下拉列表。安全分类使用全部操作目录，因为各操作都可能认证或授权失败。

## 历史数据

活动窗口与归档均能读取旧的六字段 JSON。第一次读取时构建稳定 legacy_ 事件 ID，按可确认的旧动作和路径映射分类/资源，标记 metadata.legacy。旧身份类型为 unknown；未知 HTTP 状态维持 unknown；不补造源 IP、主体 ID、会话或耗时。

同一旧记录转换多次、重启后不会产生新事件 ID。原文件读取不需要一次性批量改写或删除；活动窗口下一次正常保存时写入完整结构。
