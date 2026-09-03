# ZigFS 配置

ZigFS 使用 YAML 配置，并在代码中维护完整默认值。

## 加载顺序

```text
内置默认值 -> config.yaml -> 命令行覆盖
```

默认查找当前工作目录的 `config.yaml`。文件不存在时使用默认值；如果使用 `--config <path>` 显式指定，则文件缺失或格式错误会阻止启动。

## V1 Schema

```yaml
server:
  api_address: "0.0.0.0:9000"

observability:
  metrics_enabled: true
  metrics_address: "127.0.0.1:9090"

storage:
  data_root: "data"
  stream_buffer_size: 65536

s3:
  region: "us-east-1"
  request_time_skew_seconds: 900
  multipart_expiry_seconds: 604800

admin:
  username: "admin"
  password: "zigfs-admin"
  session_secret: "zigfs-local-session-secret-change-before-production"
  session_ttl_seconds: 28800
```

| 字段 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `server.api_address` | `0.0.0.0:9000` | string | ZigFS API 监听地址，承载 S3/Data、Management 和 Health 路由 |
| `observability.metrics_enabled` | `true` | bool | 是否启用 Prometheus Metrics Listener |
| `observability.metrics_address` | `127.0.0.1:9090` | string | Prometheus Metrics 监听地址 |
| `storage.data_root` | `data` | string | ZigFS 独占数据根目录 |
| `storage.stream_buffer_size` | `65536` | integer | Object 流式 I/O 缓冲区，允许 4096 至 1048576 bytes |
| `s3.region` | `us-east-1` | string | Signature V4 Credential Scope 和 CreateBucket LocationConstraint 所属 Region |
| `s3.request_time_skew_seconds` | `900` | integer | Header 签名及 Presigned 未来签发时间允许的时钟偏差，允许 60 至 3600 秒 |
| `s3.multipart_expiry_seconds` | `604800` | integer | 启动恢复时清理未完成 Multipart Upload 的超时，允许 60 至 2592000 秒 |

Presigned URL 的最大有效期遵循 S3 Signature V4 标准，固定为 604800 秒（7 天），不通过 YAML 放宽。

| `admin.username` | `admin` | string | ZigFS Bootstrap 管理员账号 |
| `admin.password` | `zigfs-admin` | string | ZigFS Bootstrap 管理员密码 |
| `admin.session_secret` | 本地开发密钥 | string | ZigFS 签发 Management Token 的 HMAC-SHA256 密钥，至少 32 字节 |
| `admin.session_ttl_seconds` | `28800` | integer | Management Token 有效期，允许 60 至 86400 秒 |

V1 解析器只支持该 Schema 所需的 YAML 映射、字符串、布尔和整数标量子集，并拒绝未知字段。完整 YAML 特性不属于 V1 配置契约。

管理员身份属于 ZigFS，不属于 Go Admin。Go Admin 只配置自身监听地址、ZigFS Endpoint
和静态资源路径。对外部署前必须修改默认密码和 Session Secret，并限制配置文件权限。
