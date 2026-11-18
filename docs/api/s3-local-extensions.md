# 本地 S3 扩展行为（2026-11-18）

这些接口使用 ZigFS 元数据、对象存储、IAM 和现有后台扫描器。它们不建立 AWS 服务连接，也不表示 AWS S3 全字段兼容。运行证据见 [CLI 验收](../../zigfs-cli/docs/zigfs-zc-cli-validation.md)。

## 存储格式与归档

对象元数据 minor version 从 7 升为 **8**，增加存储类、恢复截止时间和智能归档层。新版本能够读取旧格式（旧对象默认为 STANDARD），旧二进制不能读取新写入的 v8 记录。部署前保留可恢复备份；不能直接用旧程序打开已写入 v8 的数据目录进行回退。

单次 PUT 和 CopyObject 支持 STANDARD、GLACIER、DEEP_ARCHIVE、INTELLIGENT_TIERING。未恢复的 GLACIER/DEEP_ARCHIVE 对象读取和复制返回 InvalidObjectState；HEAD 和元数据查询仍可用。RestoreObject 会读取并验证原数据的解密与完整性，再原子发布 1–36500 天的读窗口。初次返回 202，再次延长返回 200；本地校验在响应前完成，不存在后台云恢复任务。到期再次拒绝读取。智能归档对象恢复后清除归档层，回到热读。

这是**本地逻辑归档和读取控制**：密文并未移到外部冷介质，容量不会因此减少。存储类不改变对象内容或 ETag。分片创建仍不支持存储类参数。

## 注解

注解属于父对象的 bucket UUID、object UUID、data generation；覆盖同名对象不会继承旧注解。支持命名读写、删除、前缀分页和父对象 ETag 条件。每条 1 B–1 MiB，每个对象版本最多 1000 条，名称最多 256 UTF-8 字节且不含控制字符。

注解独立密文先持久化，再原子发布索引；密钥由父对象数据密钥（未加密对象使用实例主密钥）派生，密文绑定其存储路径。原地重新封装同一父数据密钥不会改变派生密钥。支持 MD5/SHA256 输入校验；其他校验算法不支持。正常替换/删除会移除旧密文；崩溃、索引发布失败或父对象删除产生的无引用记录目前尚无专用回收器。

## 通知、网站和日志

S3 QueueConfiguration/TopicConfiguration 的目标为 `arn:zigfs:events:::目标ID`。先通过 Management event-destinations 注册 HTTP/MQTT 目标，再设置 S3 通知规则；规则接入现有持久化 outbox 和重试。支持创建/删除事件、前缀/后缀过滤。目标被规则引用时不能删除；不支持 AWS SNS/SQS ARN 或 Lambda。

Website 的 IndexDocument.Suffix 在当前 S3 endpoint 的匿名桶根路径和目录路径生效。ErrorDocument 保留 404 状态，仅在没有桶资源策略且允许公开读取时使用；公开访问拦截始终保留。RedirectAllRequestsTo 和 RoutingRules 明确拒绝。

Logging 的 TargetBucket 必须属于同一 owner。请求结束后写 `${TargetPrefix}${timestampMS}-${uuid}.jsonl`，包含方法、资源、actor、状态、耗时和 request ID，不包含凭据。内部写入不递归触发日志或事件；写入失败记录警告，原请求结果不变。日志是本地 JSONL，不是 AWS 标准访问日志格式，也不提供独立持久化日志重投队列。

## 报表与智能分层

现有生命周期扫描线程同时运行分层和报表扫描，扫描间隔由 `ZIGFS_S3_LIFECYCLE_SCAN_INTERVAL_SECONDS` 配置。首个符合周期的扫描生成报表；Inventory 支持 Daily/Weekly，Analytics 每天，Metrics 每分钟。持久化检查点在 CSV 和 manifest 发布之后写入；重启后相同配置和周期不重复生成。输出路径：

```text
${DestinationPrefix}.zigfs-reports/${kind}/${SHA256(configurationId)}/${period}.csv
${DestinationPrefix}.zigfs-reports/${kind}/${SHA256(configurationId)}/${period}.csv.manifest.json
```

Inventory 目标来自 S3BucketDestination；Analytics 可配置 DataExport 目标，缺省与 Metrics 一样写源桶。目标必须同 owner。只支持 CSV 和 Prefix 过滤；Tag/And、自定义加密及 Inventory OptionalFields 明确拒绝。内部报表对象不会触发事件；统计排除 key 中含 `.zigfs-reports/` 的对象。

- Inventory 固定列：Bucket,Key,VersionId,IsLatest,DeleteMarker,Size,LastModifiedDate,ETag,StorageClass。时间是 Unix 秒；支持 Current/All。
- Analytics 按存储类输出对象数和字节数。
- Metrics 输出对象/字节快照及累计请求、GET、PUT、DELETE、客户端/服务端错误计数；不是单周期增量。
- manifest 包含 sourceBucket、configurationId、kind，以及每个 CSV 的 key、size、MD5checksum。

Intelligent tiering 支持 Enabled/Disabled、Prefix 和 ARCHIVE_ACCESS（90–730 天）、DEEP_ARCHIVE_ACCESS（180–730 天）。按实际读取版本记录最近访问时间并防止旧时间覆盖新时间；扫描与读取并发时重新检查访问记录。到期切换逻辑归档层，恢复回热读，不进行物理介质迁移，不模拟 AWS 小对象分层或费用规则。

## 其他兼容边界

ABAC 未配置时保持原启用行为；显式 Disabled 禁用桶 ResourceTag 条件上下文，对象标签策略独立。CORS 配置作用于 OPTIONS 和成功对象 GET/HEAD；其他操作、错误/304 和部分通配符仍未完整覆盖。

Select 仅支持未压缩默认 CSV 的 `SELECT * FROM S3Object`，最多 16 MiB。Torrent 返回 canonical bencode 与真实 SHA-1 分块信息，trackerless，最多 16 MiB。固定 BucketOwnerEnforced、不支持任意 ACL，PAB 四开关仅接受一致值。Requester 计费和全球加速不在本地服务实现范围，相关启用请求拒绝。
