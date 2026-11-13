# KMS 控制台策略权限

所有权限来自当前策略 JSON。名称只用于关联文档，不用于选择角色或硬编码权限；用户直接绑定策略及用户组策略由 ZigFS 统一评估。

KMS 能力探测使用资源 `arn:aws:kms:::*`，不再错误地用 `*` 导致内置 KMS 策略无法匹配。会话响应中 `kms` 控制 KMS 入口，`kms_list` 和 `kms_describe` 控制列举与指定密钥查看入口。

仅具备 KMS 权限的用户通过「系统设置」进入密钥访问页面，不请求系统设置、KMS 后端配置、存储或系统状态等管理接口。

| 策略原始正文 | 控制台行为 |
| --- | --- |
| KMSKeyUser | 可输入已知密钥 ID 查看元数据；无 ListKeys、创建、轮换、删除或配置权限 |
| KMSAuditor | 可列出和查看密钥；无创建、轮换、删除或配置权限 |
| KMSKeyAdministrator | 可列出、查看、轮换和删除密钥；原始策略不包含 CreateKey 或配置管理权限 |

上表只说明默认 JSON 内容。编辑这些 JSON 后，授权随正文变化。GenerateDataKey / Decrypt 不等同于 ListKeys 或服务管理权限；本次没有新增独立的数据密钥生成、解密控制台工具。

## 接口授权

- `GET /_admin/v1/settings/kms/keys`：检查 `kms:ListKeys`，资源 `arn:aws:kms:::*`。`canCreate` 同时检查 `kms:CreateKey`；每条记录的 `permissions` 返回 describe、rotate、delete 决策供按钮展示使用。
- `POST /_admin/v1/settings/kms/keys`：检查 `kms:CreateKey`；设置默认密钥还需管理权限。
- `POST /_admin/v1/settings/kms/keys/action`：请求 `{id, action}`。新增 `describe` 返回该密钥元数据，不包含密钥材料；对应 `kms:DescribeKey`。`rotate` 对应 `kms:RotateKey`；`delete`、`schedule-deletion`、`cancel-deletion` 对应 `kms:DeleteKey`。
- 单个密钥的资源为 `arn:aws:kms:::key/<id>`。服务端按实际请求上下文评估 Condition 和显式 Deny，不以菜单状态代替授权。
- BFF 路径前缀为 `/api/v1`，转发上述请求和结果。
- KMS 配置、启动、停止、清缓存仍由管理权限控制，不因拥有任意 KMS 使用权限而开放。

## 验证

`/usr/bin/python3 conformance/kms_permissions.py` 使用隔离数据目录。将全部八份内置策略 JSON 复制为无关的自定义名称并验证登录能力，再验证 KMS 查询、列表、轮换、拒绝越权、原会话下修改 JSON、密钥级 Deny 和 SecureTransport 条件。
