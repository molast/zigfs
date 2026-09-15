# ZigFS 运维手册

## 启动与就绪

生产环境应以前台进程或进程管理器运行 ZigFS，并将 `zigfs/config.yaml` 以受限
权限保存。推荐先检查：

```bash
curl --fail http://127.0.0.1:9000/health/live
curl --fail http://127.0.0.1:9000/health/ready
curl --fail http://127.0.0.1:9090/metrics
```

`live` 只代表进程和事件循环存活。`ready` 只有在格式、实例锁、存储写探针、
Journal 回放、Metadata 扫描、索引重建和密钥可用时才返回成功。启动时写探针会
创建并同步 `.zigfs/tmp/storage-ready.probe`，随后删除并同步父目录；初始化阶段
失败会返回 `StorageNotWritable` 并阻止 HTTP 服务进入 Ready。运行期的写入错误则
通过稳定的 `Unavailable`/`ServiceUnavailable` 语义返回，不能把成功响应伪装成持久化。

## 数据目录

`storage.data_root` 是 ZigFS 唯一事实来源：

- `metadata/` 保存版本化 Bucket/Object/Multipart/Credential 记录。
- `.zigfs/journal/` 保存 Intent、Commit 和 Abort。
- `objects/` 保存按 Data Generation 分代的数据文件。
- `.zigfs/system/` 保存格式、实例身份和 Credential Master Key。
- `.zigfs/indexes/` 在 V1 是可丢弃的加速层，启动始终从 Metadata Repository 重建。
- `.zigfs/trash/` 保存 GC 已从 namespace 原子移出、等待最终物理删除的数据；启动时
  会继续清理未完成的 Trash。

不要手工编辑或删除 `metadata/`、`.zigfs/journal/`、`.zigfs/system/` 或 `objects/`。
第二个 ZigFS 进程不能共享同一个数据根目录。

对象删除、悬垂数据、过期 Multipart 和 16 分片 Scanner 的完整语义见
[存储扫描与文件清理架构](storage-reclamation.md)。Admin Storage 页面可查看最近扫描
结果并触发一次完整 GC；不要手工删除物理数据文件。

## 监控与告警

Prometheus 只连接独立 Metrics Listener。至少监控 `zigfs_ready`、请求错误率、请求
延迟、恢复状态和进程 RSS。`/health/ready` 连续失败时停止流量导入，检查日志中的
`recovery_required` 原因；不要通过删除数据文件来“修复”损坏状态。

## 变更与升级

修改端口、数据根、Region、流缓冲区或 Multipart 过期时间前，先保存配置和当前
版本信息。V1 不自动迁移未知磁盘主版本；升级前必须按照备份文档制作可验证副本。
对象数据和 Metadata 的 fsync、Checksum、Metadata Commit 和 Journal 语义不能因
性能调优而关闭。

0.1 Release Candidate 的完整升级、拒绝和回滚步骤见
[docs/release/v1-release-candidate.md](release/v1-release-candidate.md)、
[升级运行手册](release/upgrade-v1.md) 和 [回滚运行手册](release/rollback-v1.md)。

## 故障排查

- `StorageNotWritable`：检查路径权限、挂载模式、容量和 inode；确认目录未被同名
  文件占用后再重启。
- `recovery_required/corrupt_journal`：保留原始目录和日志，停止写流量，按备份
  恢复或人工审计 Journal。
- `recovery_required/corrupt_record`：不要删除单条记录；恢复最近一个完整备份。
- GET 返回 `CorruptData`：Metadata 仍可能完整，但对应 Data Generation 缺失或
  checksum 不匹配，应从备份恢复对象数据并重新校验。
