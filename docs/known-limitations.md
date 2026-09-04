# V1 已知限制

- V1 是单数据根、单写进程架构；不提供多节点共识、跨节点复制或在线分片扩容。
- S3 当前使用 path-style 请求。Conditional Requests、Temporary Credentials、
  Virtual-hosted-style、S3 POST Policy 和非 CRC64NVME streaming trailer checksum
  不在当前兼容范围。
- `.zigfs/indexes/` 尚未作为持久化快照读取，启动总是扫描 Repository 全量重建；
  大量 Metadata 会增加恢复时间，但不会降低事实正确性。
- Storage Management API 在没有可移植容量 Backend 时将 `total` 和 `available` 报为
  `null`。启动写探针只能证明当前路径可写，不能保证后续不会 ENOSPC。
- V1 GC 需要扫描 Data Generation；大型数据根上的回收耗时随代数增长，应安排在
  低流量窗口并保留监控。
- Benchmark 的 RSS/CPU/Disk I/O 采样受操作系统和采样间隔影响，报告必须与硬件、
  构建模式、缓冲区和并发度一起解读；不提供脱离环境的吞吐承诺。
- 发生 Data checksum 错误时，Metadata 可能仍然可 Head/List；只有实际读取对象时
  才报告 `CorruptData`，这是为了保留可诊断的元数据事实。
