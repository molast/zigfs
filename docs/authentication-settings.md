# 会话与请求认证设置

入口：**System Setting → General → 会话与请求认证**。

| 配置 | 默认值 | 可设置范围 | 作用 |
|---|---|---|---|
| 管理会话有效期 | 28800 秒（8 小时） | 60–86400 秒整数 | 控制新签发的管理会话有效期 |
| 签名时间偏差 | 900 秒（15 分钟） | 60–3600 秒整数 | S3 请求签名时间与服务器时间的容许偏差 |

前后端按顺序校验：先会话有效期，再签名时间偏差，每次仅报告第一个错误。JSON 接口只接受整数，不接受字符串或小数；两个字段均必填。表单以秒为单位，同时显示当前生效值。

## 保存和重启

保存后由 ZigFS 原子写入 `storage.data_root/.zigfs/config/authentication.json`，BFF 不访问数据目录。运行中的配置不变；重启 ZigFS 后统一应用到 HTTP 认证入口、用户登录及 S3 校验。页面显示待重启状态。如需取消待生效变更，将两个字段恢复为当前生效值后保存。

启动时该文件覆盖 `.env` 的 `ZIGFS_ADMIN_SESSION_TTL_SECONDS` 和 `ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS`；文件不存在则使用启动配置。文件损坏、非法或无法读取时启动失败，不静默回退。取消变更仍保留显式配置文件，不恢复为跟随 `.env`。

## 有效期的边界

- 重启后的部署管理员、普通用户、凭证登录所签发的控制台会话使用新有效期。已签发会话保留原到期时间；缩短配置不会立即注销已有用户。
- OIDC 新登录也使用该上限，但实际到期时间还受 IdP 令牌到期时间约束；已有 OIDC 会话按原有会话/刷新规则运行。
- 此配置不改变 AK/SK 本身的过期时间，也不改变 `sts:AssumeRole` 请求的凭证生命周期。
- 普通 S3 SigV4 请求校验过去和未来的签名时间偏差。预签名请求对未来签名时间使用偏差配置，同时独立校验链接有效期；增加偏差不会延长过期链接。POST Policy 也受现有签名时间/策略到期校验约束。
- 调整签名偏差不会修正机器时钟。客户端与服务端应使用正常的时间同步。

## 接口

| 操作 | BFF | ZigFS |
|---|---|---|
| 读取 | `GET /api/v1/settings/authentication` | `GET /_admin/v1/settings/authentication` |
| 保存 | `PUT /api/v1/settings/authentication` | `PUT /_admin/v1/settings/authentication` |

需要管理会话和管理权限。PUT 示例：

```json
{"admin_session_ttl_seconds": 3600, "request_time_skew_seconds": 60}
```

GET / PUT 成功返回 200，示例为保存后、重启前：

```json
{
  "current": {"admin_session_ttl_seconds": 28800, "request_time_skew_seconds": 900},
  "pending": {"admin_session_ttl_seconds": 3600, "request_time_skew_seconds": 60},
  "restart_required": true
}
```

重启后 `current` 与 `pending` 一致，`restart_required` 为 `false`。现有 `GET /settings` 始终报告实际生效值。

| 错误码 | HTTP 状态 | 含义 |
|---|---|---|
| `InvalidSessionLifetime` | 400 | 会话有效期类型或范围错误 |
| `InvalidSignatureClockSkew` | 400 | 签名时间偏差类型或范围错误 |
| `InvalidRequest` | 400 | JSON 结构错误、缺少字段或未知字段 |
| `AuthenticationSettingsUnavailable` | 503 | 配置读写失败 |
| `AccessDenied` | 403 | 策略不允许此操作 |

读写审计操作分别为 `GetAuthenticationSettings`、`UpdateAuthenticationSettings`，归入系统管理。

## 验证

Zig 单元测试覆盖默认值、上下界、非法值不覆盖已保存配置、文件损坏。Go 测试验证请求/响应和错误码转发。`python3 conformance/console_session_objects.py` 验证管理权限、逐项错误、待生效与取消、重启持久化、管理员和普通用户的新会话有效期、已有会话保持可用，以及真实 SigV4 下载在偏差范围内成功、超出范围返回 `RequestTimeTooSkewed`。
