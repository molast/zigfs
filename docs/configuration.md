# ZigFS 配置

ZigFS 使用 `.env` 配置，并在代码中维护完整默认值。控制台 General 页面的操作入口和生效总表见 [常规设置](general-settings.md)。

## 加载顺序

```text
内置默认值 -> .env -> 进程环境变量 -> 命令行 -> 对应的持久化配置覆盖
```

默认查找当前工作目录的 `.env`。文件不存在时使用默认值；如果使用 `--env-file <path>` 显式指定，则文件缺失或格式错误会阻止启动。

## Root 登录与 S3 密钥

支持 `ZIGFS_ROOT_USER`、`ZIGFS_ROOT_PASSWORD`、`ZIGFS_ACCESS_KEY`、`ZIGFS_SECRET_KEY`。
可使用进程环境变量或 `.env` 中同名键；进程环境变量优先，重启生效。登录密码与 S3 SK 相互独立。完整规则见 [账户资料与 Root 凭证](account-and-root-credentials.md)。

从仓库根目录执行 `cp .env.example .env`，`./start.sh` 会将此文件传给 ZigFS 和 Admin。直接运行 ZigFS 默认读取当前工作目录的 `.env`；在 `zigfs/` 下运行时使用 `zig build run -- --env-file ../.env`。Admin 默认读取当前目录的 `.env`，也可以通过 `ZIGFS_ENV_FILE=/absolute/path/.env` 指定，显式文件缺失会启动失败。

`.env` 不提交，仓库只保留根目录的 [模板](../.env.example)。旧 YAML 不再读取，`--config` 改为 `--env-file`。各项启动配置的大写变量见下表，迁移时必须保持数据目录不变。相对数据路径相对于进程工作目录解析；`start.sh` 保持从 `zigfs/` 启动，因此 `data` 仍指向 `zigfs/data`。

## 文件语法和 Compose

每行 `UPPERCASE_KEY=value`；支持空行、`#` 注释、CRLF、空值、单引号和双引号。行尾注释需与未加引号的值用空格隔开。重复键以最后一次为准。ZigFS 和 BFF 按字面读取，不执行 shell、不展开 `$VAR`、不解析转义或多行字符串；需要 `$` 的秘密请使用单引号，以同时避免 Compose 插值。含引号、换行等复杂值可通过进程环境注入。未知的大写键被忽略，以便同一文件容纳 Compose、BFF 和构建变量。布尔值使用 `true` / `false`，整数使用十进制。显式空值覆盖文件值，必填配置无效时阻止 ZigFS 启动。

`docker compose -f docker-compose.dev.yml up --build` 自动读取根目录 `.env` 并将声明的变量传入对应服务；Root 秘密只传给 ZigFS，不传给 BFF。容器内数据目录固定 `/var/lib/zigfs`，监听端口固定 9000/9090/9001，上游使用 `http://zigfs:9000`；主机端口用 `ZIGFS_API_PORT`、`ZIGFS_METRICS_PORT`、`ZIGFS_ADMIN_PORT` 修改。`ZIGFS_S3_PUBLIC_ENDPOINT` 要填写客户端实际可访问的地址。容器镜像不包含 `.env` 或秘密。

BFF 支持 `ZIGFS_ADMIN_LISTEN`、`ZIGFS_ENDPOINT`、`ZIGFS_WEB_ROOT`、`ZIGFS_UPSTREAM_TIMEOUT`（默认 `15m`）、`ZIGFS_ADMIN_CONFIG`；其空值使用内置默认值。ZigFS 还支持 `ZIGFS_KMS_ALLOW_INSECURE_DEV_DEFAULTS`（默认 `false`）及 `ZIGFS_OIDC_PROVIDERS`（单行 JSON，默认 `[]`）。

## 实例展示配置

常规设置中的服务名称、实例描述由 ZigFS 保存在
`${ZIGFS_DATA_ROOT}/.zigfs/config/instance.json`，保存即时生效，重启后保留。
该文件不修改 S3 签名或实例 ID，详见 [实例信息](instance-settings.md)。

## 控制台保存的认证配置

`${ZIGFS_DATA_ROOT}/.zigfs/config/authentication.json` 保存会话有效期和签名时间偏差，
下次启动时覆盖 `ZIGFS_ADMIN_SESSION_TTL_SECONDS` 和 `ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS`。
已签发会话保留原到期时间。详见 [会话与请求认证](authentication-settings.md)。

## 控制台保存的显示偏好

`${ZIGFS_DATA_ROOT}/.zigfs/config/display.json` 保存控制台显示时区和日期格式，
保存后立即生效，不改变服务端 UTC 时间戳或系统时钟。详见 [显示偏好](display-settings.md)。

## 控制台保存的 Region

常规设置中的 Region 保存到 `${ZIGFS_DATA_ROOT}/.zigfs/config/region.json`。
下次启动时覆盖 `ZIGFS_S3_REGION`，保存后不会改变正在运行的签名校验。
操作步骤、取消待生效变更和客户端影响见 [S3 Region](region-settings.md)。

## 控制台保存的网络配置

System Setting → Network 保存的设置不会回写 `.env`。S3 监听地址保存在
`${ZIGFS_DATA_ROOT}/.zigfs/config/listener.json`，在下一次启动绑定前覆盖 `ZIGFS_API_ADDRESS`。
Public URL、寻址模式和可信代理保存在 `.zigfs/config/network.json`，即时生效并在重启后保留；
其中的 Public URL 和寻址模式优先于 `ZIGFS_S3_PUBLIC_ENDPOINT`、`ZIGFS_S3_VIRTUAL_HOSTED_STYLE`。
覆盖文件不存在时使用启动配置。

Go BFF 的独立配置文件由 `ZIGFS_ADMIN_CONFIG` 指定，默认位于系统用户配置目录下的
`zigfs-admin/listener.json`。保存的 Admin 监听地址和 ZigFS 上游候选地址优先于
`ZIGFS_ADMIN_LISTEN`、`ZIGFS_ENDPOINT`。BFF 不访问 ZigFS 数据目录。

字段、生效时机、错误恢复及部署示例见 [网络配置](network-settings.md)。
不要向下面的 `.env` 添加 `trusted_proxies` 等未支持的字段；可信代理通过 Network 管理接口保存。

## V1 Schema

```dotenv
ZIGFS_API_ADDRESS="0.0.0.0:9000"

ZIGFS_METRICS_ENABLED=true
ZIGFS_METRICS_ADDRESS="127.0.0.1:9090"

ZIGFS_DATA_ROOT="data"
ZIGFS_STREAM_BUFFER_SIZE=65536

ZIGFS_S3_PUBLIC_ENDPOINT="http://127.0.0.1:9000"
ZIGFS_S3_VIRTUAL_HOSTED_STYLE=false
ZIGFS_S3_REGION="us-east-1"
ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS=900
ZIGFS_S3_MULTIPART_EXPIRY_SECONDS=604800
ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS=300

ZIGFS_ROOT_USER="admin"
ZIGFS_ROOT_PASSWORD="zigfs-admin"
ZIGFS_ADMIN_SESSION_SECRET="zigfs-local-session-secret-change-before-production"
ZIGFS_ADMIN_SESSION_TTL_SECONDS=28800
```

| 字段 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `ZIGFS_API_ADDRESS` | `0.0.0.0:9000` | string | ZigFS API 监听地址，承载 S3/Data、Management 和 Health 路由 |
| `ZIGFS_METRICS_ENABLED` | `true` | bool | 是否启用 Prometheus Metrics Listener |
| `ZIGFS_METRICS_ADDRESS` | `127.0.0.1:9090` | string | Prometheus Metrics 监听地址 |
| `ZIGFS_DATA_ROOT` | `data` | string | ZigFS 独占数据根目录 |
| `ZIGFS_STREAM_BUFFER_SIZE` | `65536` | integer | Object 流式 I/O 缓冲区，允许 4096 至 1048576 bytes |
| `ZIGFS_METADATA_MAINTENANCE_INTERVAL_SECONDS` | `60` | integer | 元数据检查点与历史回收周期，允许 1 至 3600 秒；目录扫描尚未完成时下一轮间隔缩短到 1 秒 |
| `ZIGFS_METADATA_MAINTENANCE_BATCH_SIZE` | `1000` | integer | 每轮分别最多访问多少个 journal 目录条目和元数据目录条目，允许 1 至 10000；活跃文件也占预算，游标跨批次续扫；不是毫秒耗时上限 |
| `ZIGFS_S3_REGION` | `us-east-1` | string | Signature V4 Credential Scope 和 CreateBucket LocationConstraint 所属 Region |
| `ZIGFS_S3_PUBLIC_ENDPOINT` | `http://127.0.0.1:9000` | string | 客户端访问的 S3 authority；不能包含路径、凭证或 Query |
| `ZIGFS_S3_VIRTUAL_HOSTED_STYLE` | `false` | bool | 是否接受 `<bucket>.<public_endpoint authority>/<key>`；关闭时仅使用 Path-style |
| `ZIGFS_S3_REQUEST_TIME_SKEW_SECONDS` | `900` | integer | Header 签名及 Presigned 未来签发时间允许的时钟偏差，允许 60 至 3600 秒 |
| `ZIGFS_S3_MULTIPART_EXPIRY_SECONDS` | `604800` | integer | 启动恢复时清理未完成 Multipart Upload 的超时，允许 60 至 2592000 秒 |
| `ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS` | `300` | integer | 后台 Lifecycle Scanner 周期，允许 1 至 86400 秒；规则和清理状态只保存在 ZigFS |

Presigned URL 的最大有效期遵循 S3 Signature V4 标准，固定为 604800 秒（7 天），不通过 `.env` 放宽。

| 字段 | 默认值 | 类型 | 说明 |
|---|---|---|---|
| `ZIGFS_ROOT_USER` | `admin` | string | ZigFS Bootstrap 管理员账号 |
| `ZIGFS_ROOT_PASSWORD` | `zigfs-admin` | string | ZigFS Bootstrap 管理员密码 |
| `ZIGFS_ADMIN_SESSION_SECRET` | 本地开发密钥 | string | ZigFS 签发 Management Token 的 HMAC-SHA256 密钥，至少 32 字节 |
| `ZIGFS_ADMIN_SESSION_TTL_SECONDS` | `28800` | integer | Management Token 有效期，允许 60 至 86400 秒 |

配置值仍使用原有边界校验，错误配置会阻止启动。

管理员身份属于 ZigFS，不属于 Go Admin。Go Admin 只配置自身监听地址、ZigFS Endpoint
和静态资源路径。对外部署前必须修改默认密码和 Session Secret，并限制配置文件权限。
