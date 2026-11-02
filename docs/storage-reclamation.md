# ZigFS 存储扫描与文件清理架构

本文定义 ZigFS 对未完成 Multipart Upload、悬垂数据和已删除数据的统一清理模型，
以及 Scanner 如何以有限的单周期成本覆盖完整 namespace。

## 清理模型

```text
                         ZigFS Storage
                               |
             +-----------------+-----------------+
             |                 |                 |
       Incomplete MPU      Dangling Data      Deleted Data
             |                 |                 |
        超时自动清理         Scanner 发现          Trash / GC
             |                 |                 |
            删除              Purge            最终物理删除
```

三类数据必须分别处理：

- **Incomplete MPU**：仍有 Multipart Metadata 引用，但上传长期未完成。服务启动和
  Scanner 周期会按 `s3.multipart_expiry_seconds` 使其过期，先提交 Multipart
  Tombstone，再删除对应 Part 数据。
- **Dangling Data**：磁盘上存在 Data Generation，但任何有效 Object Version、
  Multipart Manifest 或活跃 Multipart Upload 都不再引用它。Scanner 根据完整
  Metadata 可达图确认不可达后才能 Purge。
- **Deleted Data**：S3 删除或永久删除版本先提交 Metadata。旧 Data Generation
  随即变为不可达数据，GC 将 generation 原子移动到 `.zigfs/trash/`，同步目录后再
  物理删除。进程若在移动后中断，下次启动会继续清空 Trash。

Metadata 是可达性的唯一事实来源。Admin 中看不到对象只说明对象不再处于逻辑
namespace，不能据此直接删除 `objects/` 或 `multipart/` 中的文件。

## 16 分片 Scanner

```text
                            Scanner
                               |
                 +-------------+-------------+
                 |                           |
              Cluster 层                   Bucket 层
                 |                           |
           Bucket 分组扫描               Object 分组扫描
                 |                           |
                 +-------------+-------------+
                               |
                           Namespace
                               |
                         选择本周期对象
                               |
                    Usage / Lifecycle / Heal
```

单机 ZigFS 当前只有一个 Cluster 分组。每个扫描周期选择 `0..15` 中的一个 Object
分片，只进入各 Bucket 中命中的物理 namespace shard；16 个成功周期后覆盖完整
namespace，然后从分片 0 重新开始。新对象的 shard 由 `bucket name + object name`
的稳定 hash 决定，同时 Object ID 的其余位仍保持随机，以保留版本级唯一性。升级前
已存在的随机 Object ID 按其现有物理 shard 扫描，同样会在 16 个周期内覆盖。

Multipart Part 使用 Upload ID 对物理 namespace 分片。过期 MPU 的 Metadata 清理
独立于 Object 分片执行，确保过期上传不会等待完整 16 周期。

Scanner 每次都从全部有效 Metadata 构造可达集合，但只枚举本周期命中的数据目录。
这是安全性和 I/O 成本之间的边界：Metadata 很小且必须完整验证，可能很大的对象
Data namespace 则分片遍历。

图中的两层扫描在当前单机实现中对应：Cluster 层选择本地存储实例并遍历 Bucket，
Bucket 层只枚举本周期命中的 Object 或 Upload shard。Scanner 是 namespace
任务调度边界，不等同于 GC：当前接入的任务是容量统计与可达性 GC（Usage）以及过期
MPU 清理（Lifecycle）；Heal 保留为后续的数据校验、修复和副本恢复任务入口，不会把
发现损坏误当成可清理数据。

## 并发与故障安全

Scanner 和手动 GC 复用 Object GC 服务：

1. 按固定的 Multipart Lock、Object Lock 顺序获取两组全局锁，阻止扫描期间发布
   Part、切换 Object Version 或完成 Multipart Upload。
2. 在 Metadata State Lock 下构造所有 Object Version、Multipart Manifest 和活跃
   Upload 的可达集合。
3. 扫描选定物理分片；若某个可达 generation 缺失或结构异常，返回 `CorruptData`，
   不继续回收。
4. 对不可达 generation 执行 `rename -> fsync -> Trash delete -> fsync`。
5. 释放锁并记录扫描、保留、回收的 generation 数和字节数。

Full GC 与后台 Scanner 由 Scanner Mutex 串行化，避免两次回收同时处理同一目录。
完整扫描是幂等的；已经回收的 generation 不会再次出现在 namespace 中。
分片游标和最近报告由独立状态锁一次性读写，管理接口拿到的是同一时刻的快照，且不
需要在整个扫描期间持锁等待。

## 运行方式

- 后台 Scanner 使用 `s3.lifecycle_scan_interval_seconds` 作为当前扫描间隔，每次推进
  一个分片。默认 300 秒，即约 80 分钟覆盖一次完整 namespace。
- `GET /_admin/v1/storage/scanner` 返回下一个分片与最近一次扫描结果。
- `POST /_admin/v1/storage/gc` 立即扫描完整 namespace，并清理过期 MPU 与所有确认
  不可达的数据。
- Admin 的 Storage 页面展示以上状态，并在二次确认后触发 Full GC。

手动 GC 不是 Metadata 修复工具。遇到 `CorruptMetadata` 或可达数据缺失时必须停止
清理并按备份恢复流程处理，不能通过手工删除数据目录绕过一致性检查。


## Monitoring telemetry

`/_admin/v1/storage` keeps `used` as logical object bytes. Linux/macOS report
`total`, `available`, and `physical_used` for the filesystem containing the
opened ZigFS data root via `fstatvfs`. This includes other files on that volume;
reserved capacity can make `used + available` differ from total. Unsupported
platforms and measurement failures return null, never fabricated zeroes.

Scanner status includes `running`, `last_completed_at` (Unix seconds),
`last_duration_ms` (monotonic elapsed time), and `last_attempt_succeeded`.
These are runtime observations, reset after restart. Failed attempts retain the
last successful completion timestamp/report and expose failure separately.

Use `cd zigfs && zig build test` so the capacity backend C shim and libc are
linked. Direct `zig test src/root.zig` invocations additionally need
`src/backend/filesystem_capacity.c -lc`.
