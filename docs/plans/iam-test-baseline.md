# IAM 权限测试基线

这是 P0 的测试入口与覆盖清单。入口和用例映射已建立，统一矩阵已执行；结果以 `conformance/iam_permissions.sh` 和权限完成文档为准。

## 执行入口（后续统一运行）

```sh
cd zigfs && zig build test
cd zigfs-admin/server && go test ./...
cd zigfs-admin/server && go test -race ./...
corepack pnpm --dir zigfs-admin/web run build
```

## Zig 用例分组

| ID | 范围 | 入口 |
| --- | --- | --- |
| Z01 | IAM JSON 类型、Action/Resource/Condition、Deny 优先 | `src/auth/iam_policy.zig` |
| Z02 | User/Group/Key 权限继承与限制 | `src/application/credential_service.zig` |
| Z03 | Bucket Policy Principal/Resource 决策 | `src/application/resource_policy_store.zig`, `src/transport/s3.zig` |
| Z04 | Object Tagging 与 ExistingObjectTag | `src/application/object_tag_store.zig`, `src/transport/s3.zig` |
| Z05 | Role/Organization 引用冲突 | `src/application/role_store.zig` |
| Z06 | AssumeRole、角色策略、boundary、撤销 | `src/transport/management.zig`, `src/application/credential_service.zig` |
| Z07 | 每个 S3 operation 的 Action/resource/context | `src/transport/s3_protocol.zig`, `src/transport/s3.zig` |
| Z08 | P2 策略文档限制、重复字段、未知字段、条件键和操作符 | `src/auth/iam_policy.zig`, `src/application/policy_store.zig` |
| Z09 | 结构化授权解释、策略类型隔离、ARN 条件校验 | `src/auth/iam_policy.zig`, `src/application/credential_service.zig` |
| Z10 | String/Arn IgnoreCase、Date UTC/offset/precision、set operators | `src/auth/iam_policy.zig` |
| Z11 | S3 统一 Action/resource/context、版本、复制源/目标、Multipart、DeleteObjects、POST、Presign | `src/transport/s3.zig`, `src/transport/s3_protocol.zig` |
| Z12 | Bucket Policy 用户/角色/会话/匿名、NotPrincipal、ACL 未实现稳定拒绝 | `src/application/resource_policy_store.zig`, `src/transport/s3.zig` |
| Z13 | Bucket Owner Enforced、Block Public Access 持久化与公共策略恢复入口 | `src/domain/bucket.zig`, `src/application/bucket_service.zig`, `src/transport/management.zig` |
| Z14 | ObjectTag duplicate/UTF-8 limits、version context、Bucket ResourceTag context | `src/application/object_tag_store.zig`, `src/transport/s3.zig`, `src/auth/iam_policy.zig` |
| Z15 | User PrincipalTag、temporary TokenIssueTime context | `src/application/credential_service.zig`, `src/transport/s3.zig` |
| Z16 | PUT/POST/Copy/Multipart 标签落盘、tagging directive、版本标签与删除联动 | `src/transport/s3.zig`, `src/application/object_tag_store.zig` |
| Z17 | ObjectTagging `versionId` 变体、URL 解码、并发/重启/恢复与旁路垃圾清理 | `src/transport/s3.zig`, `src/application/object_tag_store.zig`, `src/application/object_gc.zig` |
| Z18 | 管理会话逐请求重解析、身份版本撤权、路由 Action/资源 ARN 和组织上下文 | `src/transport/http.zig`, `src/transport/management_auth.zig` |

## Go/Web 用例分组

| ID | 范围 | 入口 |
| --- | --- | --- |
| G01 | BFF route/contract/client/service/handler 对齐 | `zigfs-admin/server/internal` |
| G02 | 409 引用冲突、403/401 错误映射 | `zigfs-admin/server/internal/router`, `handler` |
| G03 | AssumeRole 与 role-session revoke API | `zigfs-admin/server/internal/zigclient`, `handler` |
| G04 | Bearer 身份透传、Organization/Role PATCH、认证响应缓存控制 | `zigfs-admin/server/internal/middleware`, `handler`, `zigclient` |
| G05 | 管理端对象/目录/预签名/Multipart 路由 Action、资源 ARN 与匿名写入拒绝 | `src/transport/http.zig`, `src/transport/management_auth.zig`, `src/transport/s3.zig` |
| Z19 | Role/Session PrincipalTag 注入、未实现 SSE/KMS/ACL/MFA/ObjectLock 头拒绝、对象标签旁路校验/物理删除 | `src/application/role_store.zig`, `src/transport/s3.zig`, `src/application/object_tag_store.zig` |
| Z20 | User/Group/Access Key 有效权限来源、Key 限制、显式 Deny 与结构化解释 | `src/application/credential_service.zig`, `src/auth/iam_policy.zig` |
| Z21 | P1 恢复：重启、写入中断、保存失败、孤立引用、重复 Account/Role/Session ID、损坏 JSON | `src/application/mod.zig`, `src/application/role_store.zig`, `src/application/policy_store.zig`, `src/metadata/recovery.zig` |
| W01 | Role/Organization/Session 管理交互 | `zigfs-admin/web/src/features/roles` |
| W02 | secret 只在签发结果中显示、toast 和错误状态 | `zigfs-admin/web/src/api`, `features/roles` |

## 完成标准

每个 ID 至少包含 allow、显式 deny、主体禁用/撤销、持久化重启和错误路径；已执行结果、失败用例和旧预期修正记录在 `docs/plans/iam-permissions-completion.md`。浏览器交互项仍需单独执行后再标记完成。
