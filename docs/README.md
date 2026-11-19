# ZigFS 文档

本目录是 ZigFS 使用、配置、部署和接口文档的入口。文档使用标准 Markdown 和相对链接，可作为后续文档站的内容来源。

## 文档归属

根目录 `docs/` 保留跨项目规则、共享 API 契约、配置使用、部署运维及联调记录。
单个项目专属的设计、实现和验证文档放在该项目内；新增文档按此规则归档。

- [CLI 文档](../zigfs-cli/docs/README.md)：指令设计、审计、验证报告和性能记录。
- [服务端文档](../zigfs/docs/README.md)：存储实现、元数据接入、内部设计和性能基线。
- [Admin 文档](../zigfs-admin/docs/README.md)：控制台交互和开发说明。
- [元数据引擎设计](../pkg/metadata-engine/docs/zigfs-metadata-engine-design.md)：独立组件设计与验证。
- [文档站设计](../zigfs-docs/docs/zigfs-docs-architecture.md)：文档站架构；开发入口见 [zigfs-docs](../zigfs-docs/README.md)。
- [统一客户端上传规则](client-upload-policy.md)：CLI 与 Admin 共用，保留在本目录。

## 配置与使用

- [账户资料与 Root 凭证](account-and-root-credentials.md)：Profile/Security、部署 root 登录和 S3 密钥。

- [常规设置总览](general-settings.md)：全部字段、生效方式、权限、存储位置和验证入口。
- [实例信息](instance-settings.md)：名称、描述、稳定实例 ID 和真实启动时间。
- [S3 Region](region-settings.md)：区域校验、保存、重启生效与客户端签名。
- [会话与请求认证](authentication-settings.md)：会话有效期、签名时间偏差。
- [时区与日期显示偏好](display-settings.md)：实例级显示配置与输入时区。
- [配置参考](configuration.md)：启动配置、默认值和持久化覆盖优先级。
- [内置 HTTPS 网关](gateway.md)：证书、域名、Admin 设置、Docker 部署和恢复流程。
- [网络配置](network-settings.md)：Network 页面字段、操作步骤、生效方式与故障排查。
- [AK/SK 凭证导出](credentials-export.md)：credentials.json 字段及 Endpoint、签名和寻址规则。
- [OpenID 登录](oidc-login.md)：外部身份接入。
- [SSE-S3](api/sse-s3.md) 与 [SSE-KMS](api/sse-kms.md)：加密功能说明。
- [系统日志](api/system-logs.md) 与 [审计日志配置](api/audit-log-configuration.md)。

## 部署与运维

- [网络部署示例](deployment/network.md)：本机、局域网、HTTPS 代理、虚拟主机寻址和容器网络。
- [运维手册](operations.md)。
- [备份与恢复](backup-and-recovery.md)。
- [存储扫描与清理](../zigfs/docs/storage-reclamation.md)。
- [已知限制](known-limitations.md)。

## 接口与兼容性

- [API 文档索引](api/README.md)。
- [网络配置 API](api/network-settings.md)。
- [S3 兼容性](api/s3-compatibility.md) 与 [操作覆盖范围](api/s3-api-coverage.md)。
- [ZigFS Management OpenAPI](api/zigfs-management-v1.openapi.yaml)。
- [Admin BFF OpenAPI](api/admin-bff-v1.openapi.yaml)。
- [SDK 设计](sdk/design.md) 与 [一致性验证](sdk/conformance.md)。

## 设计与实施计划

- [内置 HTTPS 网关](plans/builtin-https-gateway.md)：设计与实施记录；本地证书、域名路由、Admin 设置、Docker 部署与验收计划。

## 发布

- [发布候选说明](release/v1-release-candidate.md)。
- [升级](release/upgrade-v1.md) 与 [回滚](release/rollback-v1.md)。

## 后续文档站组织

建议沿用“配置与使用 → 部署与运维 → 接口与兼容性 → 发布”的导航。Network 的内容对应以下三个页面：

| 导航位置 | 内容文件 | 读者 |
|---|---|---|
| 配置 / 网络 | `network-settings.md` | 控制台使用者、管理员 |
| 部署 / 网络与反向代理 | `deployment/network.md` | 部署运维人员 |
| API / 网络配置 | `api/network-settings.md` | 集成开发者 |

迁移到文档站时保留文件间链接，按站点框架添加导航和页面元数据即可。文档站源码已位于 `zigfs-docs/`，开发与构建方式见其 [README](../zigfs-docs/README.md)；是否上线以实际部署为准。`plans/` 是设计和实施记录，应与用户文档分开，不应把计划项直接展示为已实现能力。
