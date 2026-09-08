# Changelog

本文件记录 ZigFS 对外可见的功能、兼容性和运维行为变化。

## [v0.1.0-rc.1] - 2026-09-07

这是 ZigFS 0.1 的 Release Candidate。服务端版本仍为 `0.1.0`；`v0.1.0-rc.1`
只是本次候选发布标签，不表示已经进入正式 `1.0.0`。

### S3/Data API

- Bucket、Object、List Objects V2、Range、Multipart 和 DeleteObjects。
- AWS Signature V4 Header、Presigned GET/PUT/DELETE 和 Session Token。
- Conditional Requests、CopyObject、Virtual-hosted-style（可配置）和 S3 POST Policy Upload。
- Content-MD5、SHA-256、CRC32、CRC32C、CRC64NVME、SHA1、SHA256 校验。
- aws-chunked 签名流和五种 Flexible Checksum signed trailer。
- 固定长度和流式上传的断流不发布语义，下载取消后的读取租约释放。
- Bucket Versioning、DeleteMarker、指定版本 GET/HEAD/DELETE 与 ListObjectVersions。
- Lifecycle 配置、当前/非当前版本过期、过期 DeleteMarker 清理和后台 Scanner。

### 持久化与恢复

- 自有 Metadata Repository、Transaction Journal、Object Data Generation 和可重建索引。
- `ZFOH` V1.0 Object History 与向后兼容的 `ZFBK` V1.1 Bucket 配置 Payload。
- `format.meta` 主版本 1；数据目录不依赖 SQLite 或其他外部数据库。
- 启动写能力探针、实例独占锁、checksum 校验和损坏数据的 Not Ready 语义。
- 完整 `data_root` 备份、V1 数据目录直接打开和未知格式拒绝策略。

### Management/Admin

- ZigFS Management API 负责 Bucket、Object 视图、AK/SK、Storage、System、Health 和 Settings。
- Go 1.27 + Gin 1.12 Admin BFF 只转发管理请求，React Admin 只负责展示和操作。
- Admin 不保存管理员身份、Bucket、Object 或 Credential 状态。
- Bucket 配置与对象版本历史由 ZigFS Management API 提供，Admin 只展示和转发操作。

### SDK 与验证

- TypeScript/Web 和 Swift/iOS 文件 SDK 一致性 Adapter，共享 `vector_revision: 2` 夹具。
- AWS CLI、MinIO Client、rclone 和原生 Node HTTP Compatibility Runner。
- 故障注入、索引重建、数据校验和 Small/Large Object Benchmark；Benchmark 报告命令字段自动脱敏管理员密码。

### 已知限制

- V1 是单数据根、单写进程架构，不提供集群复制、共识或在线分片扩容。
- 没有跨版本自动迁移；未知磁盘主版本、未来 Payload minor 版本和损坏记录必须先恢复备份。
- 在没有可移植容量 Backend 时，Storage API 的 `total` 和 `available` 为 `null`。
- ACL、redirect 等未纳入本 RC 的能力继续按 S3 兼容矩阵标记为未实现。

## 版本说明

- 服务版本由 `zigfs/src/version.zig` 提供，目前为 `0.1.0`。
- Management API OpenAPI 契约版本为 `1.0.0`，与服务发布版本独立。
- SDK 契约和共享一致性向量版本独立于服务端版本，详见 `docs/sdk/versioning.md`。
