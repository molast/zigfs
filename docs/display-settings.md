# 时区与日期显示偏好

入口：**System Setting → General → 显示偏好**。这是实例级配置，由管理员保存；普通控制台用户也使用同一实例的显示偏好。

| 设置 | 默认值 | 选项 |
|---|---|---|
| 显示时区 | `browser` | 跟随浏览器、UTC、服务端列出的 IANA 时区 |
| 日期格式 | `locale` | 跟随界面语言、`ymd`、`dmy`、`mdy` |

固定格式分别为 `YYYY-MM-DD HH:mm:ss`、`DD/MM/YYYY HH:mm:ss`、`MM/DD/YYYY HH:mm:ss`，使用 24 小时制。跟随语言由浏览器 Intl 按界面语言格式化。IANA 时区（例如 `Asia/Shanghai`、`America/New_York`）会按对应日期应用夏令时规则。

## 保存与生效

选择后先在预览中查看效果，点击保存后立即更新当前页面及后续页面的时间显示，无需重启。修改尚未保存时只影响预览；保存失败保留草稿，不修改已经生效的显示偏好。其他已打开会话刷新页面后获取更新。

ZigFS 原子保存到 `storage.data_root/.zigfs/config/display.json`。文件不存在时使用 `browser` / `locale`，重启后读取已保存值。BFF 只转发接口，不访问数据目录。可用时区目录在 `zigfs/src/application/display_timezones.txt` 中，接口提供 `supported_timezones`；页面只显示当前浏览器可识别的选项，不依赖宿主机时区文件。旧浏览器无法识别已保存时区时，格式化回退到 UTC。

配置读取失败时，设置接口返回 503；会话仍能验证，但 `display_preferences` 为 null，控制台提示加载失败并采用默认显示，避免显示配置损坏阻止登录。

## 影响范围

- 实例启动时间、刷新时间、Bucket 创建时间、对象修改/版本/保留时间、用户和会话时间、KMS Key 时间、系统日志图表和列表、审计日志列表和详情使用统一格式化入口。
- UTC 时间戳、日志文件原文、原始 JSON、导出数据及 API 请求保持原值。配置不改变服务器系统时钟、S3 签名、数据排序或会话有效期。
- 日期输入控件仍按浏览器时区解释，例如 AK/SK 过期时间日历、系统日志自定义查询时间。页面明确标注输入时区；显示偏好不会重新解释已输入的时间。
- 相对时间（例如“几分钟前”）和时长不受显示时区影响。

## 接口

| 操作 | BFF | ZigFS |
|---|---|---|
| 读取配置与时区列表 | `GET /api/v1/settings/display` | `GET /_admin/v1/settings/display` |
| 保存 | `PUT /api/v1/settings/display` | `PUT /_admin/v1/settings/display` |

设置读写需要管理权限。PUT 两字段必填：

```json
{"timezone": "Asia/Shanghai", "date_format": "ymd"}
```

成功均返回 200：

```json
{
  "timezone": "Asia/Shanghai",
  "date_format": "ymd",
  "supported_timezones": ["browser", "UTC", "Asia/Shanghai"]
}
```

上例省略其余可选时区。校验先检查时区、再检查格式，不合法的提交不会覆盖已保存配置。

`GET /auth/session` 增加 `display_preferences` 字段，仅包含 `timezone` 和 `date_format`。所有已认证用户都可获得这个无敏感信息的显示配置，不因此获得系统设置的读写权限。

| 错误码 | HTTP 状态 | 含义 |
|---|---|---|
| `InvalidDisplayTimezone` | 400 | 时区不在支持列表 |
| `InvalidDisplayDateFormat` | 400 | 日期格式不受支持 |
| `InvalidRequest` | 400 | JSON 类型、字段或结构错误 |
| `DisplaySettingsUnavailable` | 503 | 配置读取或保存失败 |
| `AccessDenied` | 403 | 无管理权限 |

审计操作为 `GetDisplaySettings` 和 `UpdateDisplaySettings`，分类为系统管理。

## 验证

Zig 测试覆盖默认值、非法配置不覆盖已有值和持久化。Go 测试覆盖设置与会话字段转发。`conformance/console_session_objects.py` 覆盖权限、配置即时读取、普通用户会话传播和重启保留。Web 的 `scripts/date-time.test.mjs` 覆盖跨日、夏令时、午夜、语言和失效日期；浏览器交互验证预览隔离、保存后即时更新及错误状态。
