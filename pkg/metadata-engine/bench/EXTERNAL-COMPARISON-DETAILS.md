# 外部引擎性能对照：技术明细

直观的数据量、耗时和内存对照请先看 [结果总览](EXTERNAL-COMPARISON.md)。
下面的明细表保留首轮 1 万条/单线程/4 KiB 测试；10 万和 100 万条补测及预测以总览为准。

日期：2026-11-17。Apple M2 Pro、10 逻辑 CPU、16 GiB 内存，macOS 26.2 / arm64，
本地 /private/tmp 所在数据卷。Zig 0.17.0 ReleaseFast；Go 1.27.1 普通优化构建，
正式测量不启用 race。Go 使用默认 GOMAXPROCS/GC，未统一各引擎缓存容量，也未清空 OS 缓存。
完整版本和二进制构建信息见 [环境记录](results/external-environment.json)。

实际独立工作目录：`/private/tmp/zigfs-engine-compare.AWOI7u`。
安装了 bbolt **v1.5.0**、Pebble **v1.1.5**、Badger **v4.9.6**。
工具、版本锁和重跑命令保存在 [external](external/README.md)，未加入 ZigFS / Admin 依赖。

## 首要发现：同步写不等于同一种持久化强度

| 测量行 | 提交路径 | 本机同步原语 |
| --- | --- | --- |
| zig | 1 worker 直接提交；8 worker Runtime Group Commit | Zig Io.Threaded 调用 fsync |
| zig-fullsync | 相同引擎，仅压测 Io 包装器替换普通文件同步 | F_FULLFSYNC；目录仍按引擎原有逻辑同步 |
| bbolt | 每次 DB.Update 独立事务，NoSync=false | Go File.Sync → F_FULLFSYNC |
| bbolt-batch | 初始插入仍 Update；并发覆盖用 DB.Batch，最多 64、等待 100 μs | 同上；允许合并多个调用 |
| pebble | batch.Commit(pebble.Sync)，WAL 启用，保留原生同步合并 | Go File.Sync → F_FULLFSYNC |
| badger | DB.Update，SyncWrites=true，保留原生写入合并 | WAL/value log 的 mmap MS_SYNC |

macOS 上 F_FULLFSYNC 会进一步请求设备刷新硬件缓存，不能将普通 fsync 或 MS_SYNC
的成绩直接视为同等保证。Zig-fullsync 包装器每次同步额外 stat 以区分目录，失败不静默
降级；这点与 Go 在 ENOTSUP 时可回退的实现也有区别。本次实际文件卷支持该模式。
生产引擎默认策略未改；本轮也没有做断电试验，以上是实现路径核对，不是硬件保证认证。

实现依据：Go `src/internal/poll/fd_fsync_darwin.go`；Zig `std/Io/Threaded.zig` 的
`fileSyncPosix`；bbolt `boltsync_unix.go`；Pebble `vfs/default_unix.go`；Badger
`memtable.go:SyncWAL` 与 ristretto `z/file.go:Sync`、`z/mmap_darwin.go`。

因此，提交吞吐重点比较 zig-fullsync、bbolt/bbolt-batch 和 pebble。
zig 与 badger 行保留用于说明各自配置下的性能，**不参与同等硬件刷新强度的胜负结论**。

## 测量口径

- 同样的 `bucket/key-{12 位数字}`，键按序插入；批量插入 32 条，覆盖每次一条，
  worker 按索引取模分配键，无同键争用；分页每页 100 条。每个阶段计时边界与 Zig bench 对齐。
- 插入检查 missing；Pebble 在单插入写者条件下检查，不提供通用并发 CAS。
  初始值全部为 x，覆盖后为 y；读取会校验初始值，重开后逐条验证键、覆盖值和数量。
  Zig 另验证 generation。所有错误退出，报告保留原始日志。
- get、分页、全量 scan 都返回复制后的键和值。Go 按 GC 回收，Zig 显式释放，清理时机不同。
  本测试未实现 Go 版完整 MetadataRepository（generation、tombstone 等），属于普通 KV 对照。
- Pebble 和 Badger 关闭压缩，其他缓存/表参数采用默认值。Badger 默认 MemTable 64 MiB、
  block cache 上限 256 MiB；Pebble 默认 MemTable 4 MiB。这不是相同内存预算的对照。
  小值不能据此评价 Badger Value Log 分离和 GC 的收益。
- 各进程独占本测试的执行时段，轮次循环调整引擎起点，避免总由同一引擎最后运行。
  每轮新库，峰值 RSS 来自该轮子进程的 RUSAGE_CHILDREN；未累计前一引擎的峰值。
- 关闭/重开为正常关闭，不是崩溃恢复。单列关闭耗时，因为不同引擎可能把刷盘工作放在 Close。
  Zig compare 模式跳过原基准的显式 checkpoint 和第二次重开，其他步骤保留。
  LSM flush/compaction、bbolt 读快照和 Zig checkpoint 不作为同一指标比较。
- 磁盘分别记录表观尺寸与分配块；包括日志、预分配和引擎文件，未强制统一压实/GC 状态。
  这些值不是长时间运行后的稳态空间放大系数。

## 10,000 条、256 B、8 并发：三轮中位数

插入 QPS 按记录数，插入 latency 按 32 条事务（原始报告保留）；覆盖每次一条，QPS=TPS。

| 引擎/模式 | 插入记录/s | 覆盖事务/s | 覆盖 P50（μs） | 覆盖 P99（μs） | 覆盖 QPS 三轮范围 |
| --- | ---: | ---: | ---: | ---: | ---: |
| zig | 386,105 | 39,503 | 186.5 | 396.8 | 31,579–42,545 |
| zig-fullsync | 10,001 | 3,740 | 1,665.6 | 4,421.4 | 2,359–4,058 |
| bbolt | 4,993 | 248 | 31,981.0 | 63,657.0 | 229–273 |
| bbolt-batch | 7,342 | 388 | 21,030.0 | 44,411.8 | 380–393 |
| pebble | 10,493 | 1,775 | 4,258.0 | 9,356.1 | 1,679–2,114 |
| badger | 201,709 | 30,296 | 237.1 | 566.1 | 29,943–30,913 |

读取在写入完成后进行，无并发写者，全部是热缓存测试。页和 scan 结果均包含值。

| 引擎/模式 | 热 get/s | 100 页总耗时（ms） | 全量 scan（ms） | Close（ms） | 重开（ms） |
| --- | ---: | ---: | ---: | ---: | ---: |
| zig | 8,385,744 | 0.754 | 0.981 | 0.548 | 22.367 |
| zig-fullsync | 5,970,149 | 1.948 | 2.405 | 1.375 | 41.717 |
| bbolt | 480,974 | 5.391 | 3.407 | 0.176 | 0.483 |
| bbolt-batch | 558,221 | 4.295 | 2.901 | 0.206 | 0.374 |
| pebble | 583,221 | 10.120 | 10.242 | 3.485 | 40.077 |
| badger | 880,111 | 13.281 | 6.957 | 15.805 | 4.258 |

| 引擎/模式 | 进程峰值 RSS（MiB） | 退出后文件表观尺寸（MiB） | 实际分配块（MiB） |
| --- | ---: | ---: | ---: |
| zig | 12.30 | 6.49 | 6.50 |
| zig-fullsync | 12.31 | 6.49 | 6.79 |
| bbolt | 31.92 | 8.00 | 8.00 |
| bbolt-batch | 30.77 | 8.00 | 8.00 |
| pebble | 39.23 | 2.62 | 2.64 |
| badger | 100.44 | 6.40 | 6.42 |

[全部 18 轮原始报告](results/external-10k-256b-8w.json)。磁盘尺寸在验证后的最终 Close 完成后采集，
不同引擎的关闭刷盘/压实行为会改变文件布局，不能直接据此推断运行中写放大。

## 1,000 条、256 B、单线程：三轮中位数

该组观察不依赖并发合并的提交成本；记录规模较小，不与上一组跨规模计算并发加速比。
Zig 为 direct，bbolt 为 Update，未额外测没有合并机会的 bbolt Batch。

| 引擎/模式 | 覆盖事务/s | P50（μs） | P99（μs） |
| --- | ---: | ---: | ---: |
| zig | 42,298 | 22.6 | 42.4 |
| zig-fullsync | 460 | 1,953.1 | 4,664.5 |
| bbolt | 239 | 4,032.0 | 8,020.0 |
| pebble | 451 | 2,471.3 | 4,253.0 |
| badger | 23,967 | 31.5 | 201.2 |

[全部 15 轮原始报告](results/external-1k-256b-1w.json)。

## 10,000 条、4 KiB、8 并发：探索性单轮

这一组扩大 payload，不能据单轮下稳定排名结论。约 39 MiB 的初始数据也更容易触发
表刷盘/日志轮转/后台维护；默认机制保留，各引擎并不在相同时间执行维护。

| 引擎/模式 | 覆盖事务/s | P99（μs） | 100 页（ms） | 峰值 RSS（MiB） |
| --- | ---: | ---: | ---: | ---: |
| zig | 31,869 | 530.0 | 2.792 | 84.30 |
| zig-fullsync | 2,555 | 5,041.6 | 3.122 | 84.08 |
| bbolt | 257 | 44,562.0 | 24.072 | 170.23 |
| bbolt-batch | 461 | 35,577.8 | 25.698 | 167.61 |
| pebble | 1,290 | 10,749.5 | 58.226 | 88.12 |
| badger | 9,721 | 3,389.7 | 65.130 | 352.67 |

[全部 6 轮原始报告](results/external-10k-4kib-8w.json)。

## 对当前项目的判断

1. **首先统一持久化目标。** 普通同步下 Zig/Badger 的数万 QPS 不能用来宣称比
   F_FULLFSYNC 的 bbolt/Pebble 快一个数量级。强同步对照下，256 B 单线程 Zig 约
   460 TPS、Pebble 约 451 TPS；8 并发 Zig 约 3,740 TPS、Pebble 约 1,775 TPS。
   这些只是当前机器和少量样本的观察，不是生产承诺或跨规模并发加速比。
2. **保留 Zig 引擎有依据，但不是全面胜出。** 小库热 get/扫描表现较好，默认配置下
   进程峰值 RSS 较低；这是全内存索引、实现语言、接口分配和默认缓存等共同作用，
   不能推广为大库/冷缓存/等内存预算优势。之前百万条仍约 837 MiB 的问题没有消失。
3. **bbolt 值得借鉴有序页与启动路径。** 该组小库的 bbolt 重开小于 1 ms，Zig 需
   重放并重建索引，约 22–42 ms；下一步先做顺序恢复读缓冲、索引构建和阶段 profiling。
   不直接将此结果推导成必须采用 B+Tree。
4. **Group Commit 有价值，尾延迟仍需单独优化。** bbolt Batch 明显优于本轮 Update，
   但并未追平追加日志型引擎。Zig/Pebble 的组策略和定时器并不相同；需要继续记录
   队列等待、组大小、同步耗时、轮转及快照持锁时间，定位此前百万条 P99 退化。
5. **本轮不支持引入 Value Log/LSM 大改的结论。** Badger 小值测试不能代表 Value Log GC；
   Pebble 的长期 compaction、写放大与读放大也未在这次短负载中充分体现。
   按设计文档先做 WAL 生命周期和维护调度，再评估冻结表/写时复制。

## 验证与尚未覆盖的范围

- Go 适配器 `go test -race ./...` 通过：覆盖四种配置的返回值所有权、拒绝批次无部分
  写入、并发覆盖、分页次序、关闭重开后的逐条值校验。
- 正式三组共 39 个进程全部成功，逐轮原始输出保留；另有六模式小样本 smoke 通过。
- Go 版本锁与源码为独立 bench module；数据自动清理，临时构建工程保留。生产源代码
  未接入任何 Go 数据库，Zig 改动仅为可选 benchmark 流程及 macOS 同步包装器。
- 大规模补测已加入总览：新增 7 项完整实测、4 项预测、1 项接近 10 分钟中止；
  仍未覆盖混合并发读写、同键冲突、tombstone/CAS 契约移植、冷缓存、
  长时间压实/GC、真实断电或目标 NAS/Linux 实机验证。4 KiB 仅一轮。
- 小规模与更强同步模式下的耗时波动较大，保留 QPS 范围；不能以默认配置报告替代
  相同内存预算和部署介质下的最终选型测试。


Zig 独立包 `zig build test --summary all` 回归通过（本轮缓存命中）；新增 benchmark
已通过 macOS ReleaseFast 实际运行和 x86_64 Linux ReleaseSafe 交叉编译。Linux 未实机运行，
FULLFSYNC 模式仅支持 macOS。Zig/Go 格式检查、Python 语法和 git diff --check 通过。


## 大规模补测：10 分钟限制

按用户新要求，预测超过 10 分钟的项目不再完整执行；运行中的数据库进程上限为 600 秒。
新增 10 万条 Zig 默认、Zig 强同步、Pebble、Badger，以及 100 万条 Zig 默认、Zig 强同步、
Badger 共 7 项，全部完成逐条重开校验。100 万条强同步 Zig 为 372.948 秒，未触及上限。
bbolt 合并的 10 万条在日志确认至少 570 秒后按用户新限制中止，没有完整结果。
其余 4 个长测项单独记录预测，不能计入通过次数或使用它们判断真实性能排名。

新原始文件的二进制 SHA-256 与首轮外部对照一致；数据库代码、256 B payload、批量 32、
8 并发和单次关闭重开的流程均未改变。新测试每配置一轮，与 1 万条的三轮中位数区分。
脚本新增限时、进度提示、完成项原子保存和配置/二进制一致性检查后的续跑。
续跑保留结果、超时终止及汇总拒绝未解释缺项的脚本检查均通过。

[10 万条原始结果](results/external-100k-256b-8w.json) ·
[100 万条原始结果](results/external-1m-256b-8w.json) ·
[预测依据和中止记录](results/external-predictions.json)
