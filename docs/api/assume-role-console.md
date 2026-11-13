# 角色与 AssumeRole 临时凭证

## 控制台入口

左侧「身份与访问管理 → 角色」（`/roles`）。该管理页面仅向具有管理权限的用户显示，包含角色列表、创建/编辑角色、申请临时凭证和撤销角色会话。

1. 创建角色，选择权限策略、最大会话时间和信任策略。
2. 点击角色行的「申请临时凭证」，填写会话名称和有效期；按信任策略要求填写 External ID / Source Identity。
3. 保存返回的 Access Key、Secret Key、Session Token。可下载 `sts-credentials.json`；关闭结果弹窗后无法从列表重新查看 Secret Key 和 Session Token。
4. 退出后，在登录页的 STS 登录入口填写上述三个值；也可用于支持 STS 的 S3 客户端，请求必须携带 Session Token。
5. 在角色会话列表中撤销会话，凭证和已创建的控制台会话立即失效。删除角色前须撤销所有未过期会话；删除角色会同时清除其过期和已撤销会话记录。

已撤销会话的「撤销」按钮旁显示「删除」。确认后永久删除该会话记录；未撤销记录无法删除（API 返回 `409 RoleSessionNotRevoked`），删除不存在的记录返回 `404 RoleSessionNotFound`。删除记录不会恢复凭证有效性。

普通用户的长期 AK/SK 不能替代 STS 临时三元组。访问密钥列表仅列出永久凭证，不包含 STS 临时凭证；角色会话（包括已撤销记录）在角色页面管理。

## 权限与信任

权限策略决定临时会话能做什么；信任策略决定谁可以扮演角色。普通调用者必须同时拥有 `sts:AssumeRole` 授权，并通过目标角色的信任策略检查。服务器根身份可以签发角色会话，无需普通调用者的信任授权，但签发后的会话仍受角色权限约束。

默认空信任策略不信任普通用户。可针对明确的用户 ARN 设置 Allow，例如（将账号 ID 和用户名替换为实际值）：

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::<account-id>:user/<username>"},
    "Action": "sts:AssumeRole",
    "Resource": "*"
  }]
}
```

角色管理页可见性不等同于 AssumeRole 授权；具备 `sts:AssumeRole` 权限的普通调用者可通过 API 申请，但不会因此获得角色管理权限。临时会话登录后的菜单取决于其有效权限。

角色最大会话时间为 900–43200 秒；实际申请时长不能超过该角色的上限。禁用角色后无法再申请新的临时凭证。

## 接口

控制台通过 BFF `/api/v1` 调用 ZigFS `/_admin/v1`，不直接访问数据目录：

| 方法与路径（相对于前缀） | 用途 |
| --- | --- |
| `GET /roles` | 列出角色 |
| `POST /roles` | 创建角色 |
| `PATCH /roles/:name` | 更新角色 |
| `DELETE /roles/:name` | 删除角色 |
| `POST /sts/assume-role` | 签发临时 AK/SK/Token |
| `GET /role-sessions` | 列出会话，不返回秘密凭证 |
| `POST /role-sessions/:access_key/revoke` | 撤销会话 |
| `DELETE /role-sessions/:access_key` | 删除已撤销的会话记录 |

AssumeRole 请求字段：`role_id`、`session_name`、`duration_seconds`，以及可选的 `external_id`、`source_identity`。返回 `access_key`、`secret_key`、`session_token`、`role_id`、`session_name`、`expires_at`（Unix 秒）。这是 ZigFS 管理 API，不是新增 AWS STS Query 协议端点。

## 验证

构建 ZigFS 后执行 `/usr/bin/python3 conformance/assume_role_login.py`。脚本使用独立临时目录及端口，验证角色创建/更新、时长限制、禁用角色、STS 登录、只读 S3 权限、撤销及删除，不使用本地实际凭证。

旧版本删除角色可能留下已撤销的孤立会话。读取时允许保留这些已撤销记录，以便在角色会话列表中删除；它们仍无法通过认证。未撤销会话引用不存在的角色仍视为数据错误。角色删除成功后的刷新错误单独提示，不再误报删除失败。
