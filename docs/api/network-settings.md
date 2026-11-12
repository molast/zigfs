# 网络配置 API

本页描述 Network 页面使用的管理接口。用户操作说明见 [网络配置](../network-settings.md)，部署示例见 [网络部署](../deployment/network.md)。

完整路由契约见 [ZigFS Management OpenAPI](zigfs-management-v1.openapi.yaml) 和 [Admin BFF OpenAPI](admin-bff-v1.openapi.yaml)。

## 接口与认证

| 功能 | Admin BFF | ZigFS Management | 成功状态 |
|---|---|---|---|
| 读取配置 | `GET /api/v1/settings` | `GET /_admin/v1/settings` | 200 |
| 保存公开访问和代理配置 | `PUT /api/v1/settings/network` | `PUT /_admin/v1/settings/network` | 200 |
| 保存监听配置 | `PUT /api/v1/settings/listeners` | `PUT /_admin/v1/settings/listener` | BFF 204；ZigFS 200 |

BFF 使用登录后的 `zigfs_admin_session` HttpOnly Cookie。ZigFS Management 使用 `Authorization: Bearer <management-session-token>`。这些接口需要管理权限；当前路由按 `admin:*` 校验。

BFF 不拥有 ZigFS 身份、权限或对象数据。监听配置保存时，BFF 先通过 ZigFS 验证权限，再持久化自身连接配置并转发 S3 监听变更。

## 读取配置

Network 使用以下字段；`GET settings` 还包含其他系统配置字段。

| 字段 | 类型 | 含义 |
|---|---|---|
| `api_address` | string | ZigFS 当前监听地址 |
| `pending_api_address` | string | 下一次启动使用的 ZigFS 监听地址 |
| `api_restart_required` | boolean | 待生效值是否与当前值不同 |
| `admin_listen_address` | string | BFF 当前监听地址，由 BFF 补充 |
| `pending_admin_listen_address` | string | BFF 下一次启动使用的监听地址 |
| `admin_restart_required` | boolean | BFF 是否需要重启 |
| `upstream_endpoint` | string | BFF 当前选择的 ZigFS 地址 |
| `pending_upstream_endpoint` | string | 最近保存的目标 ZigFS 地址 |
| `s3_public_endpoint` | string | 有效 Public URL |
| `s3_virtual_hosted_style` | boolean | 有效寻址模式 |
| `trusted_proxies` | string[] | 有效可信代理列表 |

Admin 和 BFF 上游字段由 BFF 补充，直接调用 ZigFS 不应依赖这些字段。Network 的监听状态应使用各自的重启标志，不使用通用的 `reload_required` 判断。

## 保存公开访问与可信代理

请求示例：

```http
PUT /api/v1/settings/network
Content-Type: application/json
```

```json
{
  "s3_public_endpoint": "https://s3.example.com",
  "s3_virtual_hosted_style": true,
  "trusted_proxies": ["127.0.0.1", "10.0.0.0/24", "::1"]
}
```

成功返回 200 和已保存的配置对象。配置即时用于新请求和新生成的链接，并在重启后保留。

这是整体替换接口，调用方应提交完整对象。`trusted_proxies` 省略时按空列表处理，会关闭信任；不要把省略字段理解为保持原值。

持久化位置为 `storage.data_root/.zigfs/config/network.json`。没有保存文件时，Public URL 和寻址模式使用启动配置，可信代理为空。写入使用原子替换和同步。

## 保存监听配置

通过 BFF 提交：

```http
PUT /api/v1/settings/listeners
Content-Type: application/json
```

```json
{
  "api_address": "0.0.0.0:19000",
  "admin_listen_address": "0.0.0.0:19001",
  "upstream_endpoint": "http://127.0.0.1:19000"
}
```

上例假设 BFF 与 ZigFS 同机。远程部署应提供 BFF 可达的上游地址。

成功返回 204，无响应体。调用方应再次读取 settings，展示待生效值和重启提示。保存不会重启服务，也不会修改 Public URL。

直接调用 ZigFS 时，请求仅包含其自身监听地址：

```http
PUT /_admin/v1/settings/listener
Content-Type: application/json
Authorization: Bearer <management-session-token>
```

```json
{
  "api_address": "0.0.0.0:19000"
}
```

直接调用不协调 BFF 上游，需要调用方自行处理连接配置。ZigFS 持久化位置为 `storage.data_root/.zigfs/config/listener.json`；BFF 文件由 `ZIGFS_ADMIN_CONFIG` 指定。

### 协调与失败语义

1. BFF 验证管理权限和输入，检查自身目标监听地址。
2. 在自身文件中保存当前与目标 ZigFS 地址，保留原 Admin 待生效地址。
3. 调用 ZigFS 保存 S3 监听配置。
4. ZigFS 成功后，BFF 提交新的 Admin 待生效地址。

确定的 ZigFS 4xx 拒绝会恢复 BFF 之前的候选配置。网络中断或存储错误可能无法判断远端是否已保存，因此保留候选地址用于恢复。两进程保存不是分布式原子事务；返回部分保存错误时，调用方应刷新核对状态。

重启后的地址切换仅针对连接建立失败，不会对 HTTP 拒绝、TLS 错误或响应中断自动重放写请求。

## 错误码

前端按 `code` 显示本地化提示，不能依赖后端英文 `message` 匹配。

| 错误码 | 常见状态 | 含义及处理 |
|---|---|---|
| `InvalidRequest` | 400 | BFF 请求 JSON 无效 |
| `InvalidPublicEndpoint` | 400 | Public URL 格式、长度或 origin 不合法 |
| `InvalidVirtualHostedEndpoint` | 400 | 虚拟主机模式使用了 IP 地址 |
| `InvalidTrustedProxy` | 400 | IP/CIDR 无效或超过数量、长度限制 |
| `InvalidListenAddress` | 400 | 监听 IP 或端口无效 |
| `InvalidUpstreamEndpoint` | 400 | BFF 上游 origin 无效 |
| `Unauthorized` | 401 | 缺少或无效的管理会话 |
| `AccessDenied` | 403 | 当前策略不允许管理操作 |
| `ListenAddressUnavailable` | 409 | ZigFS 目标监听地址不可用 |
| `AdminListenAddressUnavailable` | 409 | BFF 目标监听地址不可用 |
| `NetworkSettingsUnavailable` | 503 | 网络配置无法读取或保存 |
| `ListenerSettingsUnavailable` | 503 | 监听配置无法保存，或 BFF 未配置持久化支持 |
| `ListenerSettingsPartiallySaved` | 503 | 部分提交或恢复失败，应刷新核对两端状态 |

其他基础设施错误继续遵循通用 Management/BFF 错误契约。端口验证发生在保存时，正式重启仍可能因后续端口占用而失败。

## 审计与验证

配置保存按以下操作分类进入现有审计流程：

- `UpdateNetworkConfiguration`：公开访问、寻址模式、可信代理保存。
- `UpdateListenerConfiguration`：ZigFS 监听配置保存；BFF 协调监听时会调用该接口。

可信代理解析还影响审计中的 `request.source_ip`。此分类不表示每一项 BFF 本地文件操作都有独立审计事件。

仓库中的回归验证入口：

| 入口 | 覆盖内容 |
|---|---|
| `conformance/console_session_objects.py` | 保存权限、非法值、寻址切换、可信代理 IAM/审计一致性、伪造头拒绝、重启保留 |
| `conformance/listener_settings.py` | 独立 ZigFS/BFF 实例、端口占用、待生效状态、两种重启顺序、自动重连 |
| Zig 单元测试 | 地址、CIDR、代理链、配置持久化 |
| Go 单元测试 | BFF 配置加载、拒绝后的恢复、无权限无本地写入、已发送请求不重放 |
| Web 构建与 i18n 测试 | 类型检查、构建、语言键及插值一致性 |

这些验证记录对应实现能力，不代替实际部署的 DNS、TLS 和外部代理验收。
