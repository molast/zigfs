# P0 权限专用测试入口与覆盖基线

统一入口：`./conformance/iam_permissions.sh`。它分别执行 Zig 单测、Go BFF 单测、Go race、Web 构建和真实用户 Key/S3 链路，并把每个套件的日志与状态写入 `.iam-test-results/`（可用 `IAM_RESULTS=/tmp/zigfs-iam-results` 覆盖）。任一套件失败或被工具链阻塞，入口返回非零。

## 覆盖清单

| 层 | 入口/编号 | 覆盖范围 |
| --- | --- | --- |
| Zig 策略 | Z01–Z04 | IAM JSON、Action/Resource/Condition、Allow/Deny、Boundary、资源策略合并 |
| Zig 身份凭证 | Z05–Z08 | User/Group/Key、会话、撤权、到期、秘密脱敏、迁移 |
| Zig S3/STS | Z09–Z14 | 请求上下文、每个 S3 operation、对象标签、Bucket Policy、STS/组织 |
| Zig 管理 | Z15–Z17 | 管理路由 Action、资源范围、默认 admin/KMS/MFA/保留边界 |
| Go BFF | G01–G09 | contract、client、service、handler、router、race、错误映射和身份透传 |
| 真实链路 | C01–C16 | 用户/组/Key 权限、撤权、资源策略、条件、标签、预签名、Multipart、STS、重启恢复 |
| Web | W01–W06 | 表单、权限变化刷新、403/401/409、秘密一次显示、标签/策略编辑和 toast |

## 当前已确认结果

- Go `go test ./...`：已通过。
- Go `go test -race ./...`：已通过。
- Web TypeScript 检查：已通过。
- Zig 全量测试：当前被 Zig 0.17 工具链兼容错误阻塞，不能记为通过。
- Web `corepack pnpm --dir zigfs-admin/web run build`：已通过；直接调用系统 `pnpm` 会因错误的 native binary 解析而失败，统一入口使用 Corepack。
- 真实 conformance：Zig/Admin 已可构建，但现有 `user_access_keys.py` 在首个对象 PUT 处返回 403；该旧链路预期/权限映射仍需修正，不能记为通过。

## 必须修正的旧预期

1. 共享 Bucket 不再要求请求主体等于 `bucket.owner`；只要 IAM/资源策略允许即可访问。
2. `inherit_policy=false` 只关闭 Key 自身继承开关，不得突破用户直属策略和启用组权限上限。
3. 预签名 URL 创建成功不等于永久授权；消费时必须重新解析当前凭证、会话和策略。
4. 组 Allow/Deny 与用户直属策略按统一 IAM 合并，显式 Deny 始终优先。
5. 删除、禁用、解绑、策略修改和角色撤销必须立即影响下一次请求及预签名消费。
6. ACL、MFA、KMS、Object Lock 等未实现能力必须稳定拒绝，不能因默认 JSON 存在而把测试预期改为成功。
7. 对象标签按版本隔离；复制、Multipart 完成、删除和 GC 不得读取或删除其他版本标签。

旧测试若依赖上述越权或 owner-only 行为，应改为明确的拒绝回归或共享资源允许回归，并保留原始复现说明。
