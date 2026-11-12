# 账户资料与 Root 凭证

右上角用户菜单提供 **Profile（个人资料）**、**Security（安全）** 和退出登录。可直接访问 `/account`、`/account/security`，所有已登录身份均可查看自己的资料，不要求系统管理权限。

Profile 展示用户名、按当前能力判断的管理员/用户角色、当前身份可用状态、身份来源和会话到期时间。部署 root 可看到已配置的 Root Access Key；STS 身份显示实际登录使用的 Session Access Key。普通密码登录没有临时 AK，不会伪造“会话访问密钥”。Secret Key、密码和会话 Token 不会通过资料接口返回。

Security 说明当前身份的凭证管理方式：部署 root 修改启动配置并重启；普通用户由管理员在 Users 中修改密码；OIDC 用户在身份提供方修改；STS 用户重新申请临时凭证。当前不提供本页面自助改密，暂不实现两步验证，不显示虚假的 2FA 开关。

## 四个启动配置项

| 大写变量（环境或 .env） | 作用 | 默认值 |
|---|---|---|
| `ZIGFS_ROOT_USER` | 控制台 root 用户名 | `admin` |
| `ZIGFS_ROOT_PASSWORD` | 控制台 root 密码 | `zigfs-admin` |
| `ZIGFS_ACCESS_KEY` | root S3 AK | 空 |
| `ZIGFS_SECRET_KEY` | root S3 SK | 空 |

进程环境变量逐项覆盖 `.env`；显式空值也会覆盖。AK 为 16–128 个英文字母或数字，SK 为 32–64 个不含空格的可打印 ASCII 字符。AK/SK 必须成对有效，非法配置阻止启动；两者都为空时不启用 root S3 密钥。

控制台密码与 S3 Secret Key 相互独立，不将其中一组当成另一组的默认值。

## `.env` 示例

```dotenv
ZIGFS_ROOT_USER=storage-admin
ZIGFS_ROOT_PASSWORD='replace-this-console-password'
ZIGFS_ACCESS_KEY=ExampleRootAccessKey01
ZIGFS_SECRET_KEY='replace-this-example-secret-with-a-real-key'
```

环境变量可覆盖上述 `.env`，例如通过服务管理器或容器的 environment / env_file 配置这些键，再正常启动 ZigFS。只在启动时读取，改动后必须重启。

## 生效与权限

- root S3 密钥由 ZigFS 验签服务直接解析，支持 Header SigV4、预签名以及复用该验签服务的请求路径；不是仅用于页面显示。
- 密钥使用完整权限策略，能够访问其他所有者的 Bucket；仍经过服务现有的请求签名、资源策略及对象保留规则。
- 配置 root 密钥不写入普通 AK/SK 存储，也不出现在普通密钥列表中；只能通过启动配置轮换或关闭，不能在密钥管理中修改/删除。
- 普通密钥创建不能占用当前配置的 root AK。启动时发现该 AK 已存在于普通密钥索引，返回 `RootAccessKeyConflict` 并退出，避免覆盖现有身份。`ZIGFSCONSOLESESSION` 是保留标识，不能作为 root AK。
- 更换 AK/SK 并重启后，仅新的配置密钥可以认证，旧配置密钥不会作为普通密钥残留。去掉环境变量时会重新采用 `.env` 值。
- 控制台会话仍使用 `ZIGFS_ADMIN_SESSION_SECRET` 和已有有效期规则。修改 root 密码本身不会撤销已签发会话；需要使旧会话全部失效时，同时轮换 `ZIGFS_ADMIN_SESSION_SECRET` 并重启。

## 会话接口新增字段

`GET /_admin/v1/auth/session` 和 BFF 的 `GET /api/v1/auth/session` 返回：

| 字段 | 值 |
|---|---|
| `auth_source` | `deployment`、`local`、`oidc` 或 `sts` |
| `root_access_key` | 仅部署 root 返回其已配置的 AK；其他身份或未配置时为 null |
| `session_access_key` | STS 会话的 AK；其他登录方式为 null |

未登录不能读取；已有身份验证会检查用户是否仍有效。资料刷新重新读取此接口，失败时保留页面已有内容并提示错误。

## 验证

- `cd zigfs && zig build && zig build test`
- `cd zigfs-admin/server && go test ./...`
- Web 构建、多语言和 `scripts/routes.test.mjs`。
- `python3 conformance/root_credentials.py`：`.env`/环境变量优先级、控制台登录、S3 列表/读写/预签名、重启轮换、非法配置、保留 AK 与已有密钥冲突、资料响应不含秘密及普通用户隔离。
- `python3 conformance/console_session_objects.py`：原有管理会话与控制台操作回归。
