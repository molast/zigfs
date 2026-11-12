# 实例信息

入口为 **System Setting → General → Instance Information**。本页描述已接入的实例信息；Region 编辑见 [S3 Region 设置](region-settings.md)；安全参数见 [会话与请求认证](authentication-settings.md)；显示偏好见 [时区与日期显示偏好](display-settings.md)。

| 字段 | 来源 | 是否可编辑 |
|---|---|---|
| 服务名称 | ZigFS 实例展示配置，默认 `ZigFS` | 是 |
| 实例描述 | ZigFS 实例展示配置，默认空 | 是，可清空 |
| 实例 ID | 数据目录已有的持久化 UUID | 否 |
| 启动时间 | ZigFS 本次启动记录的 Unix 秒时间戳 | 否 |
| 运行时长 | ZigFS 计算的运行秒数 | 否 |

修改服务名称或描述后点击保存，立即生效，无需重启。服务名称用于实例展示，不改变 S3 endpoint、签名服务名、Bucket 名称或实例 ID。

名称不能为空，最多 128 个 UTF-8 字节，不能包含控制字符；描述最多 4096 个 UTF-8 字节，允许换行、回车和制表符。前端逐项显示校验错误；后端再次校验，非法更新不会替换已有配置。

配置由 ZigFS 原子保存到 `storage.data_root/.zigfs/config/instance.json`，重启后保留。没有文件时返回默认值，损坏或读取失败不会静默恢复默认值。BFF 不读取数据目录。

实例 ID 来自现有的 `.zigfs/format.meta`，同一数据目录重启后不变；启动时间每次进程启动重新记录。页面按实例显示偏好显示后端时间，不使用浏览器时钟反推启动时间。运行时长为最近一次读取的快照，点击“刷新配置”更新。

## 接口

| 操作 | BFF | ZigFS |
|---|---|---|
| 读取 | `GET /api/v1/settings/instance` | `GET /_admin/v1/settings/instance` |
| 保存 | `PUT /api/v1/settings/instance` | `PUT /_admin/v1/settings/instance` |

这些接口需要管理会话及当前路由要求的 `admin:*` 权限。BFF 使用登录 Cookie，ZigFS 使用 Bearer 管理会话。保存提交完整的名称、描述对象：

```json
{
  "service_name": "研发存储",
  "description": "研发环境对象存储"
}
```

读取和保存成功均返回 200，示例：

```json
{
  "service_name": "研发存储",
  "description": "研发环境对象存储",
  "instance_id": "01234567-89ab-4cde-8123-456789abcdef",
  "started_at_unix_seconds": 1794441600,
  "uptime_seconds": 120
}
```

客户端不能提交实例 ID、启动时间或运行时长进行修改。

| 错误码 | 状态 | 含义 |
|---|---|---|
| `InvalidServiceName` | 400 | 名称为空、超长或包含非法字符 |
| `InvalidInstanceDescription` | 400 | 描述超长或包含非法字符 |
| `InstanceSettingsUnavailable` | 503 | 配置读取或保存失败 |
| `AccessDenied` | 403 | 当前策略不允许该操作 |

前端按错误码显示中英文提示。操作通过现有审计流程分类为 `GetInstanceSettings`、`UpdateInstanceSettings`。

验证覆盖默认值、中文和多行文本保存、非法更新不覆盖已有值、只读身份拒绝访问、重启后名称/描述和实例 ID 保留，以及启动时间更新。
