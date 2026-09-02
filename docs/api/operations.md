# 运维接口

## ZigFS

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/health/live` | 无或网络限制 | 进程和事件循环存活 |
| GET | `/health/ready` | 无或网络限制 | 存储、元数据恢复和写入能力就绪 |
| GET | `/_admin/v1/health` | Management 凭证 | 详细健康和恢复状态 |
| GET | `/_admin/v1/system` | Management 凭证 | 版本、运行时间和对象统计 |
| GET | `/_admin/v1/storage` | Management 凭证 | 容量与磁盘状态 |

Prometheus 默认通过独立的 `127.0.0.1:9090` Listener 拉取指标：

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/metrics` | 默认使用网络限制 | Prometheus 文本格式运行指标 |

## Admin

| Method | Path | 认证 | 含义 |
|---|---|---|---|
| GET | `/health/live` | 无 | Gin 进程存活 |
| GET | `/health/ready` | 无 | Admin 可以连接 ZigFS |

`live` 不代表可以处理存储请求；编排系统应使用 `ready` 决定是否接收流量。

## Request ID

ZigFS 的 API、Health 和 Metrics 响应均返回 `X-Request-ID`。请求携带合法的
`X-Request-ID` 时 ZigFS 透传该值；缺失或不合法时生成新的 Request ID。合法值
长度为 1 到 128 字节，仅允许 ASCII 字母、数字、`-`、`_`、`.` 和 `:`。
