# Diagnostics 控制台权限

`diagnostics` 内置策略保留原始 Action 和 `arn:aws:s3:::*` Resource，不需要改成管理员策略。

登录和会话响应新增两个能力字段，由 BFF 原样转交前端：

| 字段 | 权限 | 控制台用途 |
| --- | --- | --- |
| `capabilities.server_info` | `admin:ServerInfo` | 系统运行状态、健康信息 |
| `capabilities.console_log` | `admin:ConsoleLog` | 系统日志查询和下载 |

后端和能力探测均以 `arn:aws:s3:::*` 作为上述诊断操作的资源进行策略判断，显式 Deny 仍优先。拥有 `ServerInfo` 不再被当作具备用户、角色等管理权限。`admin:*` / 根身份仍可使用诊断页面。

系统运行状态页面在仅具备诊断权限时，不请求管理权限限定的 storage、scanner、settings 接口，不显示存储配置和扫描器管理信息。系统日志页面允许读取日志输出配置用于展示，但更新配置仍要求管理权限；审计日志没有随之开放。

对应只读接口（ZigFS 前缀 `/_admin/v1`，BFF 前缀 `/api/v1`）：

- `GET /system`、`GET /health`：`admin:ServerInfo`。
- `GET /metrics`：`admin:Prometheus`。
- `GET /settings/logs`、`GET /settings/logs/query`、`GET /settings/logs/download`：`admin:ConsoleLog`。

策略中的 Profiling、ServerTrace、TopLocksInfo、OBDInfo、BandwidthMonitor 并不意味着已有对应控制台页面；本次没有新增这些诊断功能。`sts:AssumeRole` 仅允许申请角色会话，仍需目标角色信任，不授予角色管理权限。

验证：`/usr/bin/python3 conformance/diagnostics_permissions.py`，使用隔离的服务器和 diagnostics 用户，检查可读接口及管理/S3拒绝路径。Zig 单元测试同时验证 ConsoleLog 显式 Deny 不影响 ServerInfo 授权。

## 策略正文决定权限

策略名称仅用于关联存储的策略文档；自定义策略与内置策略使用相同评估逻辑。每次后端请求会重新解析当前身份及其绑定、继承的策略正文。修改内置策略不会被默认模板覆盖，也不会因名称保留原有权限；显式 Deny 优先于 Allow。

本地及 STS 登录的控制台在窗口获得焦点、或可见状态下每 30 秒重新获取会话能力，更新菜单；接口授权不等待这一 UI 刷新周期。OIDC 保留已有的会话刷新流程。

集成验证覆盖：相同正文配自定义名称、原会话下修改内置 diagnostics 为 S3 策略、添加 ConsoleLog Deny 后立即拒绝访问且 ServerInfo 保持可用。
