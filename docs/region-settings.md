# S3 Region 设置

入口为 **System Setting → General → 默认区域**。支持自定义区域，例如 `us-east-1`、`eu-central-1`、`local-1`。

Region 必须为 1–63 个小写英文字母、数字或连字符，首尾不能是连字符。服务端再次校验；非法提交不会覆盖已保存的配置。

## 保存与生效

1. 页面分别显示当前生效 Region 和可编辑的已保存 Region。
2. 保存后，配置写入 `storage.data_root/.zigfs/config/region.json`，页面显示待重启提示。当前请求继续使用旧 Region。
3. 手动重启 ZigFS 后，新 Region 统一用于 S3 签名校验、预签名链接、Bucket location 和相关策略上下文。
4. 同步修改 SDK/客户端的 Region，并重新获取预签名链接。旧 Region 签名的链接在重启后将被拒绝，即使尚未过期。

重启前若要取消待生效变更，将输入框改回“当前区域”的值并保存。此操作保留显式配置文件，不会恢复为跟随 `.env`。

持久化文件在启动时覆盖 `ZIGFS_S3_REGION`；文件不存在时使用启动配置（默认 `us-east-1`）。读取失败、损坏或非法值会阻止启动，不会静默回退。配置使用原子替换保存；Admin BFF 仅转发接口，不访问数据目录。Region 修改不迁移或删除已有 Bucket 和对象。

## 接口

| 操作 | BFF | ZigFS |
|---|---|---|
| 读取 | `GET /api/v1/settings/region` | `GET /_admin/v1/settings/region` |
| 保存 | `PUT /api/v1/settings/region` | `PUT /_admin/v1/settings/region` |

接口需要管理会话及管理权限。PUT 请求：

```json
{"s3_region": "eu-central-1"}
```

GET 和 PUT 成功均返回 200。保存后、重启前的响应示例：

```json
{
  "s3_region": "us-east-1",
  "pending_s3_region": "eu-central-1",
  "restart_required": true
}
```

重启后两个 Region 字段一致，`restart_required` 为 `false`。现有 `GET /settings` 中的 `s3_region` 始终表示当前生效值。

| 错误码 | HTTP 状态 | 含义 |
|---|---|---|
| `InvalidRegion` | 400 | Region 格式非法 |
| `RegionSettingsUnavailable` | 503 | 配置读取或保存失败 |
| `AccessDenied` | 403 | 策略不允许此操作 |

审计操作为 `GetRegionSettings` 和 `UpdateRegionSettings`，分类为系统管理。前端根据错误码展示中英文提示。

验证脚本：`python3 conformance/console_session_objects.py`。覆盖非法值、权限拒绝、保存与取消待生效配置、重启持久化，以及重启前后实际下载的签名区域一致性。
