# 常规设置

入口：**System Setting → General**。本页是常规设置的统一使用与运维入口，涵盖实例信息、S3 Region、会话与请求认证、显示偏好。当前页面中的可编辑配置均已通过 Admin BFF 接入 ZigFS；实例 ID、启动时间、运行时长来自后端，只读展示。

## 配置与生效总表

所有文件路径均相对于 `ZIGFS_DATA_ROOT`（通常为 `data`）。

| 页面配置 | 是否可编辑 | 保存位置 / 数据来源 | 生效方式 | 详细文档 |
|---|---|---|---|---|
| 服务名称、实例描述 | 是 | `.zigfs/config/instance.json` | 保存后立即生效 | [实例信息](instance-settings.md) |
| 实例 ID | 否 | `.zigfs/format.meta` 中的持久化 UUID | 同一数据目录重启后不变 | [实例信息](instance-settings.md) |
| 启动时间、运行时长 | 否 | ZigFS 实际启动时间、运行秒数 | 点击刷新配置获取新快照 | [实例信息](instance-settings.md) |
| 默认区域 Region | 是 | `.zigfs/config/region.json` | 重启 ZigFS 后生效 | [S3 Region](region-settings.md) |
| 管理会话有效期、签名时间偏差 | 是 | `.zigfs/config/authentication.json` | 重启 ZigFS 后生效 | [会话与请求认证](authentication-settings.md) |
| 显示时区、日期格式 | 是 | `.zigfs/config/display.json` | 当前会话保存后立即生效；其他会话刷新页面获取 | [显示偏好](display-settings.md) |

## 使用流程

1. 修改对应分组后，点击该分组的保存按钮。各分组独立保存；刷新配置会重新加载服务端值，包括覆盖未保存草稿。
2. 实例信息保存后即可读取。显示偏好在保存前只影响预览，保存成功后应用到控制台时间展示。
3. Region 和认证参数保存后显示待重启状态；重启前“当前值”仍是原配置。要取消待生效变更，把该分组全部字段改回当前值并保存。
4. 手动重启 ZigFS 后，刷新配置确认当前值更新、待重启提示消失。控制台不会自动重启服务。
5. 修改 Region 后更新 SDK/客户端的签名 Region，并重新获取预签名链接。修改会话有效期只影响新签发的会话；已有会话保留原有效期。

保存与加载失败通过统一 Toast 提示，字段错误按顺序标记，不一次标红所有字段。保存失败保留草稿；请求校验失败不会覆盖已保存配置。页面对启动参数的校验范围、接口错误码及边界行为详见各配置专题。

## 权限与事实来源

四组设置的 GET/PUT 接口均要求管理会话及 `admin:*` 管理权限；未登录或无权限的请求被拒绝。普通已登录用户仅通过 `/auth/session` 获取无敏感信息的 `display_preferences`，用于统一显示，不因此获得设置接口权限。

ZigFS 负责校验、原子保存和读取配置，Admin BFF 只转发接口，不直接操作数据目录。Region/认证持久化文件在启动时覆盖对应 `.env` 值；取消待生效变更仍会保留显式配置，不恢复为跟随 `.env`。文件缺失使用默认值或启动配置。故障处理差异见下表。

| 故障 | 行为 |
|---|---|
| 实例信息文件无法读取或解析 | 设置接口返回 `InstanceSettingsUnavailable`，不会伪造正常读取结果 |
| Region / 认证配置无法读取、解析或校验 | 相应设置 GET 返回 503；下次 ZigFS 启动失败，需先修复配置 |
| 显示配置无法读取或校验 | 设置接口返回 503；会话认证仍可用，显示偏好为 null，控制台提示并使用默认显示 |

备份时应包含上述配置文件及 `.zigfs/format.meta`。不要通过修改实例 ID 文件来“重命名”实例；名称应在页面中修改。通用备份流程见 [备份与恢复](backup-and-recovery.md)。

## 接口与审计

| 分组 | BFF 路径（GET / PUT） | ZigFS 路径（GET / PUT） | 审计操作 |
|---|---|---|---|
| 实例信息 | `/api/v1/settings/instance` | `/_admin/v1/settings/instance` | `GetInstanceSettings` / `UpdateInstanceSettings` |
| Region | `/api/v1/settings/region` | `/_admin/v1/settings/region` | `GetRegionSettings` / `UpdateRegionSettings` |
| 认证参数 | `/api/v1/settings/authentication` | `/_admin/v1/settings/authentication` | `GetAuthenticationSettings` / `UpdateAuthenticationSettings` |
| 显示偏好 | `/api/v1/settings/display` | `/_admin/v1/settings/display` | `GetDisplaySettings` / `UpdateDisplaySettings` |

以上审计归为系统管理。字段契约见 [ZigFS Management OpenAPI](api/zigfs-management-v1.openapi.yaml) 与 [Admin BFF OpenAPI](api/admin-bff-v1.openapi.yaml)。

## 回归验证

在仓库根目录执行后端与端到端验证：

```sh
(cd zigfs && zig build && zig build test)
(cd zigfs-admin/server && go test ./...)
python3 conformance/console_session_objects.py
```

在 `zigfs-admin/web` 下执行：

```sh
pnpm run build
pnpm run test:i18n
node --test scripts/date-time.test.mjs
```

如果本机 pnpm 启动器不可用，使用项目已安装依赖执行等价检查：

```sh
node node_modules/typescript/bin/tsc -b
node node_modules/vite/bin/vite.js build
node --test scripts/i18n.test.mjs scripts/date-time.test.mjs
```

回归覆盖如下：

- Zig：配置默认值、校验范围、非法更新保留旧值、持久化与配置文件错误。
- Go：接口转发、认证字段与错误码保留，现有路由和服务测试。
- 隔离 ZigFS 实测：管理员与只读用户权限、四组配置重启保留、实例 ID 稳定、启动时间变化、待生效变更取消、真实 S3 签名与会话有效期、普通会话显示偏好传递、八个审计操作。
- Web：TypeScript / Vite 构建、中英文目录、跨时区日期变化、夏令时、午夜和语言切换。
- 浏览器表单检查：初始禁用保存、逐项校验、失败草稿保留、错误 Toast、Region 待重启/取消、显示预览隔离与保存后即时更新。

本次接入的功能边界到此完整；未来增加字段时，应同时更新本总表、专题文档、OpenAPI、生效逻辑及对应验证。
