# ZigFS 0.1 Release Candidate 发布检查单

目标标签：`v0.1.0-rc.1`；服务版本：`0.1.0`；执行日期：`2026-09-07`。

## 版本与文档

- [x] `zigfs/src/version.zig` 为 `0.1.0`，启动日志和 Management System API 一致。
- [x] `CHANGELOG.md`、RC 发布说明、升级和回滚手册已审阅。
- [x] S3 兼容矩阵、Management OpenAPI、SDK fixture 和 README 互相一致。
- [x] `.docs/` 未进入发布包，发布包不包含 `.env` 或测试数据。

## 构建与自动化测试

- [x] `cd zigfs && zig build -Doptimize=ReleaseSafe`
- [x] `cd zigfs && zig build test`（180 项通过）
- [x] `cd zigfs-admin/server && go test ./...`
- [x] `cd zigfs-admin/web && pnpm run build`（pnpm）
- [x] `./conformance/run.sh`：TypeScript/Web 与 Swift/iOS 均通过。
- [x] `./compatibility/run.sh`：AWS CLI、mc、rclone、Ruby aws-sdk-s3 和原生 HTTP 矩阵通过；不支持项有记录。
- [x] `node benchmarks/run.mjs --profile smoke --output <temporary-report>` 完成；报告命令字段已脱敏，`benchmarks/report.test.mjs` 通过。

## 数据目录与恢复

- [x] 全新数据根可以启动并返回 `/health/ready` `200`。
- [x] 全新目录包含 `format.meta`、实例身份、Master Key、Metadata 和 Journal。
- [x] 已有 V1 数据根可以直接打开，Bucket/Object/Multipart/Credential 只读校验通过。
- [x] 删除 `.zigfs/indexes/` 后可以全量重建并保持数据可读。
- [x] 未知 `format.meta` 主版本拒绝启动且原文件不变。
- [x] 未来 Payload minor、损坏 checksum、Journal 或 Master Key 进入失败/Not Ready。
- [x] 升级前完整备份可以在新数据根通过旧版本启动和只读校验。
- [x] RC 失败时按回滚手册使用旧版本二进制恢复成功（独立端口 `19087`）。

## 安全与发布包

- [ ] 部署时管理员密码和 Session Secret 已替换默认值，配置文件权限受限（部署前人工动作）。
- [x] 日志、兼容性报告、Benchmark 和构建产物不含 AK/SK、Session Token 或密码。
- [x] 发布包不含 SQLite、数据库文件、`.zigfs` 测试目录或真实用户对象。
- [x] Admin 仍只是 Web/BFF，ZigFS 是 S3、Management、Metadata 和 Credential 唯一事实来源。
- [x] Apache License 2.0 的 `LICENSE` 文件随发布包提供。

## 记录

将每项命令、客户端版本、服务端版本、数据根校验和、报告路径和失败项写入发布归档。
只有所有必选项均完成，才允许把 RC 归档为可发布候选；本检查单不替代生产变更审批。

## 本次执行记录

执行日期：`2026-09-07`。ZigFS 服务版本：`0.1.0`；RC 标签：`v0.1.0-rc.1`。

- Zig 单元测试：`180/180` 通过；Go 测试、pnpm Web 构建、Node/Ruby 语法和 OpenAPI YAML 校验通过。
- Conformance：TypeScript/Web、Swift/iOS 均通过。
- Compatibility：AWS CLI `2.36.38`、mc `2025-08-13`、rclone `1.75.0`、Ruby `aws-sdk-s3 1.224.0` 均通过；Unsupported 项按矩阵记录。
- Smoke benchmark：临时 Bucket 的 Put/Get/Range/List/Delete/Multipart 均通过；报告输出到临时目录，管理员密码脱敏单测通过。
- 回滚：提交 `5533e94` 的独立二进制使用完整 V1 数据根副本启动于 `19087`，`/health/ready` 返回 `200`，恢复状态 `ready`。
