# 权限资源匹配排查

本次检查覆盖控制台登录/会话能力探测、管理 API 前置鉴权、AssumeRole、KMS 密钥操作，以及相关 S3/IAM 授权调用。策略名称不参与授权判断。

## 修复项

| 位置 | 原问题 | 修复 |
| --- | --- | --- |
| 管理能力探测 | 用 `*` 判断 ListUsers 等操作，而集合接口使用 `arn:aws:s3:::*` | 使用相同的管理资源定义 |
| STS 能力探测 | 用 `*` 检查 AssumeRole，漏掉仅授权指定角色 ARN 的策略 | 从策略 Resource 构造候选资源并用完整策略集评估 |
| AssumeRole API 前置检查 | 未读请求体时用默认 S3 资源检查 STS 权限 | 在读取 role_id 并解析角色后，使用目标角色 ARN 鉴权；保留调用者策略、信任策略及 HTTP 条件上下文 |
| S3/KMS scoped 能力探测 | 固定的通配资源不能匹配指定 Bucket、对象前缀、密钥 ARN | 检查策略中限定的资源及通配模式候选；不赋予集合列举权限 |
| 创建密钥并设置默认值 | 管理权限检查传 `*`，与配置接口资源不同 | 使用 `management_resource` |
| 管理 API 资源构造 | 分散在 HTTP 层；分配失败时退回通配 ARN | 归并到 management_auth.routeResource；分配错误向上传递，不扩大匹配范围 |

此前修复的 `diagnostics` 使用 S3 ARN、KMS 能力使用 KMS ARN 保持有效。KMS 集合列举仍使用集合资源，具体密钥操作仍使用实际 key ARN；用户和角色详情接口保留各自 IAM ARN。

## 能力与实际鉴权

能力标志只用于登录资格与界面入口。Scoped 探测检查策略中的明确资源，并将通配模式构造为具体候选；候选必须通过完整策略集（包含 Deny）的评估。这是入口提示，不是对任意资源、任意条件下权限的完整枚举。

接口始终使用实际 Action、目标 Resource、请求 Condition 判断。拥有一个对象的读取权限不代表能列出所有 Bucket；拥有一个密钥的 DescribeKey 不代表能 ListKeys；拥有一个角色的 AssumeRole 不代表能使用其他角色。

## 回归验证

- `zig build test`：管理 ARN、Bucket、对象前缀、Key、Role 的能力探测；相同资源的 Deny。
- `conformance/scoped_capabilities.py`：管理 ARN、指定 Bucket/Key/Role、跨资源拒绝、默认密钥权限、STS SecureTransport 条件及 Deny。
- `conformance/kms_permissions.py`：八种内置 JSON 使用自定义名称，KMS 操作及条件限制。
- `conformance/diagnostics_permissions.py`：诊断能力、策略编辑和 Deny。
- `conformance/assume_role_login.py`：STS 登录、S3 权限、撤销、会话清理与遗留记录。

上述集成脚本使用独立临时服务及数据目录，不修改现有用户策略或生产数据。

## 控制台登录拦截

密码登录、STS 登录和会话恢复均检查是否有控制台入口权限。空策略、仅 STS AssumeRole、仅 KMS 使用权限（例如 Decrypt、但没有 ListKeys/DescribeKey）不再因非页面能力而获准登录。KMS 列表/详情、诊断页面及已有 S3/管理页面能力仍可进入。

认证凭据正确但缺少控制台权限时，返回 HTTP 403、错误码 `ConsoleAccessDenied`。BFF 保留此错误码，不包装成服务离线；登录页显示本地化的无权登录提示。会话刷新发现该错误时退出控制台，BFF 清除 Cookie。普通操作的 AccessDenied 不会被当作整个账户失去登录权限。

验证脚本：`conformance/console_login_access.py`，覆盖空策略、STS-only、KMS 使用权限、正常 KMS 登录、已有会话被移除权限，以及 STS 登录拦截。

### Bucket 页面资格与个人资料

`s3` 标记仅表示存在 S3 操作能力；新增 `s3_console` 专门以 `s3:ListAllMyBuckets` 判断 Bucket 列表入口。登录资格和 Bucket 菜单使用 `s3_console`，不能以 GetObject/PutObject 代替列举权限。原始 readonly/writeonly 策略没有 ListAllMyBuckets；若无其他可见页面权限则拒绝控制台登录，S3 API 权限本身不变。

会话接口新增 `policies` 名称数组供个人资料标签显示：包含用户直接绑定、已启用用户组继承，以及角色或 OIDC 身份绑定的命名策略。前端去重展示；部署根身份没有绑定策略时显示破折号。此字段用于说明，不替代策略正文鉴权；内联会话限制不伪装成命名策略。
