# ZigFS Metadata Engine

独立 Zig 0.17.0 package（0.3.0），已通过适配器接入 ZigFS；仍可单独构建和测试。
支持不透明 payload、条件更新、原子批量事务、FIFO/Group Commit、AVL 前缀分页、
分段 WAL、后台快照、日志回收、资源限制、指标和离线检查。

核心能力及 WAL 额度联动、清理失败自动重试已实现；Runtime Group Commit 强杀和
单进程混合参考模型验证通过。目标 NAS/Linux 与性能对照仍待验证，详见设计文档第 12 节。
开发阶段不做旧数据迁移，ZigFS 在数据根的 `.zigfs.sys/` 中初始化引擎，旧开发数据清空后重建。

## 业务命名空间

当前共有 19 个 namespace：保留 `system`（ID 1），核心 `bucket`、`object`、`multipart`、
`credential`、`directory`（ID 2–6），以及 `identity`、`policy`、`role`、`bucket_policy`、
`object_tag`、`oidc`、`settings`、`monitoring_settings`、`log_settings`、`audit_settings`、
`event_destination`、`bucket_subscription`、`kms`（ID 7–19）。

各分区拥有独立 HashMap/AVL 索引，同名键互不冲突；共享 WAL、快照和原子事务。
这属于逻辑分区，不生成每业务独立文件。持久化 ID 只能追加，不可重排；所有遍历由
`namespaces` / `namespace_count` 驱动。引擎文件格式仍为 v3；ZigFS 业务布局由数据根 v3 标记。

`metadata-tool namespaces DIRECTORY` 只读输出每个 namespace 的记录数（包含 tombstone），
需要独占目录锁，应在服务停机后使用。`inspect` 的 `namespace_records` 按 ID 减一索引。

## 构建与验证

```sh
cd pkg/metadata-engine
zig build test
zig build test -Doptimize=ReleaseSafe
zig build test-crash
zig build test-mixed
zig build -Doptimize=ReleaseFast
```

`test-crash` 需要 Python 3，在独立临时目录启动实际子进程并 SIGKILL，检查恢复结果。
`zig build` 输出 `metadata-bench` 和 `metadata-tool`；故障探针仅由测试目标构建，不安装。
模块名 `metadata_engine`，运行时无第三方依赖，不导入 `zigfs/src`。

## 使用与生命周期

```zig
var engine = try metadata_engine.Engine.openWithOptions(allocator, io, directory, .{
    .segment_bytes = 16 * 1024 * 1024,
    .max_live_bytes = 512 * 1024 * 1024,
});
defer engine.deinit();
var runtime: metadata_engine.Runtime = .{ .engine = &engine };
try runtime.start();
defer runtime.stop();
const repository = runtime.interface();
const generation = try repository.put(allocator, .object, "bucket/key", .missing, "payload");
const record = try repository.get(allocator, .object, "bucket/key");
defer record.deinit(allocator);
_ = try repository.tombstone(allocator, .object, "bucket/key", .{ .exact = generation });
```

- `directory` 为专用目录，调用者保持打开；禁止传入现有 ZigFS 数据目录。
- Engine/Runtime 导出接口或启动后地址必须稳定。由生命周期所有者停止外部调用并串行调用 stop，`runtime.stop()` 排空已接收
  请求并等待后台任务退出，之后才能 `engine.deinit()`。Runtime 不支持停止后重新 start。
- 使用 Runtime 或并发 checkpoint 时，Engine allocator 必须线程安全，如 `std.heap.smp_allocator`。
- get/scan/page 返回独立拥有的记录，调用者负责 deinit。put/tombstone 的 allocator 参数
  仅兼容原接口，持久内存归 Engine allocator。
- `engine.commit(mutations)` 为一个原子事务；`runtime.commit(mutations)` 将这个事务加入
  FIFO 队列。Group Commit 合并多个独立事务的同步，不将其变成一个跨请求原子事务。
- mutations/key/payload 在 commit 返回前必须保持有效且不可修改。已接收请求不可取消等待。
- `.missing` 不匹配 tombstone，且仅在首次物理回收前可用；启用回收的调用者须使用
  `.{ .missing_at = epoch }`。`.exact` 检查当前 generation。每个事务只有一个新 generation。
- 队列满返回 Busy；资源额度不足返回 ResourceLimit；读写结果不确定时返回 Unavailable，
  engine.stats().recovery_required 为 true，后续数据读取和写入均拒绝，必须关闭重开。

也可不启用 Runtime，直接使用 `engine.interface()`；这样每个 commit 单独同步，调用线程
直接竞争引擎互斥锁，不提供 FIFO 提交公平性。

## 有界前缀分页

```zig
const page = try engine.scanPage(allocator, .object, .{
    .prefix = "bucket/photos/",
    .start_after = previous_key,
    .limit = 100,
    .max_bytes = 1024 * 1024,
    .include_tombstones = false,
    .expected_generation = previous_generation,
});
defer page.deinit(allocator);
```

从 AVL 索引 seek，使用栈式游标按原始字节序遍历，索引开销为 O(log N + visited)。
一次最多访问 limit 个 key，并限制结果 key/payload
字节总量。过滤 tombstone 可能返回空页但仍有 `next_start_after`，必须继续使用该游标。
第一个待返回记录超过字节预算时返回 ResourceLimit，避免返回无法前进的游标。

`next_start_after == null` 才表示结束。游标是排他 key，不是 S3 token。
默认每页独立一致；同时提供上一页的 generation 与 gc_epoch 可在分页期间有写入或回收时返回 Conflict，
调用者应从头重试。此模式不是跨页 MVCC 快照。旧 `scan` 按有序索引全量复制，不再额外排序，但仍不适合作为有界分页接口。

## 快照、资源与指标

Runtime 默认队列上限 1024、Group Commit 至多 64 个事务、目标 4 MiB。
已有 `group_ready_transactions=8` 个请求或达到目标字节数时尽快提交；孤立请求等待
不超过 `group_low_load_delay_us=25` μs，其余请求最多等待 `group_delay_us=100` μs。
大于目标字节数的合法单事务单独成组。实际等待受 OS 调度影响，不承诺实时期限。

默认每秒检查维护条件，最小门槛为 min(配置的 32 MiB，WAL 额度 / 2)。开启默认
`adaptive_checkpoints` 后，动态 WAL 目标为 min(WAL 额度 / 2，max(最小门槛，逻辑数据量))。
达到最小门槛后，WAL 达到动态目标或累计修改量达到逻辑数据量的一半触发检查点；
普通维护间隔至少为上次维护耗时的 `checkpoint_cooldown_multiplier=4` 倍。
WAL 压力或额度使用达到 75% 绕过冷却和门槛；清理失败仍优先独立重试。
设置 `adaptive_checkpoints=false` 恢复固定门槛调度。较少快照会保留更多尾部 WAL。
能够在回收后容纳的事务因 WAL 额度被拒绝时，也会标记压力以触发下一轮维护。
自动维护要求 WAL 额度至少能容纳双文件头和最小事务（269 B）；设
`checkpoint_interval_ms = 0` 可关闭后台维护。checkpoint 在锁内捕获固定视图并切 WAL，
在锁外通过 64 KiB 缓冲写快照，flush 后才同步文件，再短暂持锁安装。
已覆盖 WAL 的删除、目录同步和成功路径的视图释放在状态锁外执行；
回收期间仍持快照锁，段选择边界固定，每次删除后短暂持状态锁扣减 WAL 额度。
第三轮将快照条目改为固定读视图：一次分配元信息/节点指针数组，借用 key 并固定 payload，
无需复制全部键值。捕获仍需 O(N) 遍历且持状态锁；覆盖写入延迟释放被视图引用的旧值。
每个节点用一个原子 pin 位交接释放责任，节点大小不变。同一时刻只有一个内部视图，
checkpoint_mutex 一直持有到视图释放完成。get/scan/page 仍返回独立副本，不提供公开 MVCC。
最坏情况下，捕获期间所有值都被覆盖，会保留一份旧 payload；未被覆盖的值只共享，不复制。
第一轮优化后，HashMap 持有共享记录节点，AVL 借用节点；覆盖更新保留键和节点。
恢复使用 64 KiB 读缓冲并复用大帧缓冲。快照先校验并统计各命名空间容量，再预留
HashMap、加载记录和批量构建 AVL。新快照按命名空间/键排序；读取时实际验证顺序，
v3 快照要求各命名空间内的键严格递增；乱序和重复键均视为损坏。
同一时刻最多一个 checkpoint；并发写入产生的新 WAL 不会被该快照清理。
回收失败保留 cleanup_pending，后台即使没有新写入也会重试删除及目录同步，不需要新快照。
也可手动调用 engine.retryCleanup()。ResourceLimit 不会自动等待，调用方可在维护后重试；
超大事务及记录数、内存等其他额度限制不由后台回收解除。

Engine 默认限制 100 万条记录、512 MiB key/payload 常驻数据、512 MiB 快照覆盖的逻辑数据、
1 GiB 保留 WAL；单段目标 16 MiB，事务不会被拆段。页最多 1 万条、16 MiB 返回数据。
这些不是进程 RSS 上限：还需要 HashMap、AVL、编码缓冲、固定视图条目、被覆盖的旧值和 allocator 开销。
WAL 优先通过硬链接封存同步后的旧 inode，再原子安装并同步新活跃 WAL；成功切换前不允许新追加。
只有 OperationUnsupported 回退到复制归档，其他失败冻结实例。WAL 和快照统一为 v3；
WAL 额度不含复制回退的临时副本和 snapshot 文件，磁盘需留出空间。

`engine.stats()` 提供 generation、快照边界、记录数、逻辑字节数、WAL 字节数、提交同步次数、
轮转、快照、重放和错误状态。同步次数仅统计 commit 的 WAL 同步，不包含归档/快照同步。
新增 wal_pressure、cleanup_pending、cleanup_retries 用于观察额度压力与回收重试。
`runtime.stats()` 提供排队数、峰值待处理数、拒绝数、组数、effective_checkpoint_wal_bytes
和维护错误。checkpoint_failures 累计快照及清理重试失败，last_checkpoint_error 在维护成功
后清空；累计失败次数保留。
指标计数在重启后重新开始；generation、checkpoint generation 和 gc_epoch 从磁盘恢复。

## 离线检查与恢复

```sh
zig-out/bin/metadata-tool inspect /path/to/database
zig-out/bin/metadata-tool recover /path/to/database
zig-out/bin/metadata-tool checkpoint /path/to/database
# 调用者已采用 missing_at 后，显式回收删除标记：
zig-out/bin/metadata-tool gc /path/to/database
```

所有命令要求数据库没有其他实例占用。输出 JSON 到 stdout，错误以非零状态退出。
`inspect` 不创建、删除或截断文件；检测到不完整尾部会报告 `incomplete_tail_bytes`。
`recover` 只在完整验证通过后截断最后的不完整帧，并清理安全回收的日志和已知原子临时文件；
完整帧校验失败、缺段、未来格式或损坏快照会明确失败，不能靠跳过损坏继续写入。
`checkpoint` 恢复后创建快照；`gc` 恢复后执行物理回收，会改变缺失条件写入要求。

可在目录参数后指定 `max_records max_live_bytes`，用于检查采用较高资源额度创建的数据库。
检查依然需要重建内存索引；资源不足与数据损坏是不同错误。

WAL 与 snapshot 统一使用文件格式 v3，80 B 文件头中的 6 B 字段用于回收世代
（WAL 中必须为零）。不兼容 v1/v2，遇到旧格式返回 UnsupportedFormat，不迁移、不静默
覆盖。开发环境可停止旧实例并删除旧专用数据目录，再用新版本初始化。此操作会丢失旧数据。

## 压测与持续验证

```sh
zig build bench -Doptimize=ReleaseFast -- /tmp/meta-direct-run1 10000 256 32 8 direct
zig build bench -Doptimize=ReleaseFast -- /tmp/meta-group-run1 10000 256 32 8 runtime
zig build soak -Doptimize=ReleaseFast -- --seconds 60 --operations 100000 --workers 8 --output /tmp/metadata-soak.json
zig build mixed-soak -Doptimize=ReleaseSafe -- --seconds 60 --output /tmp/metadata-mixed.json
```

bench 参数：**全新目录、操作数、payload 字节数、插入批量大小、覆盖并发数、direct/runtime**。
默认 runtime；只影响并发覆盖阶段。插入仍为显式批量 commit。所有提交保持文件同步，
没有关闭同步的高分模式。bench 保留数据，soak 仅自动删除自身创建的临时目录。

输出 QPS/TPS、P50/P95/P99/最大延迟、提交同步数、前缀分页、全量排序扫描、WAL 重放、
checkpoint 和快照重开耗时。每轮校验恢复后的 key、数量和 payload。soak 重复完整流程，
输出每轮原始记录、轮数、错误状态和子进程峰值 RSS；它不等同于单进程运行数日的耐久性测试。

mixed-soak 在同一进程、同一实例的固定键空间内运行参考模型，包含条件冲突、原子批量、
tombstone、精确读取、过滤分页、后台快照及轮转；负载结束后重开校验。它每秒采样同一
PID 的 RSS，输出 JSON，临时库自动清理。默认 60 秒，可增加 --seconds；
此工具侧重正确性，包含频繁全量模型校验，不能将事务速率直接当作生产 QPS。

bench 结果输出到 stderr，可用 `2>&1` 保存。批量 QPS 按 mutation 计数，TPS 按 commit 计数。
热读取不包含 HTTP/S3 或对象内容读取，重开时 OS 缓存通常仍热。完整实测和局限见
[基础版记录](bench/SMOKE.md)、[v2 验证记录](bench/V2-VALIDATION.md)
与 [性能优化对照](bench/PERFORMANCE.md)。
bbolt、Pebble、Badger 的独立 KV 对照见 [数据量、耗时与内存对照总览](bench/EXTERNAL-COMPARISON.md)，
注意 macOS 普通同步、F_FULLFSYNC 和 MS_SYNC 的差异。性能优化对照中的 compare.py 提供前后交替运行方式，
可记录同负载下的耗时、QPS、尾延迟和独立子进程峰值 RSS。

## 保持的边界

元数据仍全驻内存；读写共享状态锁，Group Commit 持锁到同步完成。没有磁盘页索引、
MVCC 或跨进程读写。tombstone 可显式物理回收，要求调用者采用世代条件；后台不自动回收。
业务 payload 不解释，不自动拆分对象版本、迁移 sidecar 或管理对象 GC。

只有一个快照，没有损坏快照自动回退。支持在线备份 API；手工复制现有库仍须停机复制完整目录。
文件 sync 与 SIGKILL 验证不等于真实断电保证；Linux/NAS 文件系统仍需部署环境验证。

详见 [设计文档](docs/zigfs-metadata-engine-design.md)。

外部对照专用 benchmark 可追加 `compare`（一次关闭/重开，跳过显式 checkpoint），或
macOS 的 `compare-fullsync`（普通文件使用 F_FULLFSYNC）。这是测试参数，不改变引擎默认策略。
临时 Go 工程的源码、锁定依赖和复现步骤见 [external/README](bench/external/README.md)。

第一轮优化的实测时间、内存和已知权衡见 [ROUND1-OPTIMIZATION.md](bench/ROUND1-OPTIMIZATION.md)。
压测末尾可追加 `profile`，逐阶段记录引擎分配量与进程 RSS；采样会影响性能，不能将
采样运行的耗时与普通运行直接比较。引擎分配量不含调用者持有的 get/scan/page 结果，
RSS 包含这些副本和分配器缓存。当前 RSS 采样支持 macOS，其他平台返回 0 表示不可用。
`bench/round1.py` 在 macOS 上使用 `/usr/bin/time -l`，交替运行保存的优化前后版本，
每档 1 万/10 万/100 万条各三次，每个用例超时 600 秒；预计超时的更大用例不运行。

第二轮的写入尾延迟、维护频率及内存对照见 [ROUND2-OPTIMIZATION.md](bench/ROUND2-OPTIMIZATION.md)。
`Engine.Options.diagnostics=true` 开启锁等待/持有、WAL 追加/同步/轮转、快照捕获/安装、
锁外清理的 count/total_ns/max_ns；Runtime stats 同时记录排队和收集等待。
默认关闭阶段计时。`metadata-bench` 末尾加 `phases` 可输出阶段指标；所有模式新增 P99.9。
排队时间止于出队，随后等待状态锁的时间单独统计；阶段可能嵌套，不能将总耗时简单相加。
`dirty_bytes` 是快照边界之后的累计提交字节，不是唯一脏键占用；`linked_rotations` 和
`rotation_copy_bytes` 可辨别是否走了无复制轮转。库 API 不添加日志输出。

第三轮的方案、状态转换及故障矩阵见 [ROUND3-DESIGN.md](bench/ROUND3-DESIGN.md)，
实测见 [ROUND3-OPTIMIZATION.md](bench/ROUND3-OPTIMIZATION.md)。文件格式及同步边界不变。
`profile` 中历史字段名 `snapshot_copy_live` 仍表示捕获刚结束；第三轮实际统计的是固定视图，
不是 key/payload 的全量副本。全量 scan 的调用者副本仍可能主导整个进程峰值 RSS。

## 第四轮可靠性验证

`bench/results/` 是本地压测产物目录，已由 `.gitignore` 排除，不随仓库分发。
报告中的原始 JSON 链接仅在保留对应本地结果时可用；运行复现命令可以生成新的结果，
但不能重建历史实测数据。测试源码、复现命令与 Markdown 汇总报告继续纳入版本管理。

[第四轮报告](bench/ROUND4-VALIDATION.md)区分短时实测与未验证项目。
持续模型现在支持键空间和值大小，覆盖当前全部 19 个命名空间，记录 Engine 分配、RSS、WAL、
快照和目录文件大小趋势。每个用例最多 540 秒负载，加有限关闭/校验时间，不超过十分钟。
它始终在同一实例运行，最后停机、重开并逐条对照参考模型；不是靠反复重启隐藏增长。

```sh
zig build mixed-soak -Doptimize=ReleaseFast -- --seconds 300 --slots 2048 --payload 256 --output bench/results/round4-soak-300s.json
zig build mixed-soak -Doptimize=ReleaseFast -- --seconds 120 --slots 1024 --payload 4096 --output bench/results/round4-soak-4kib-120s.json
zig build reliability-probe -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
python3 tests/reliability.py zig-out/bin/metadata-reliability-probe zig-out/bin/metadata-tool --output bench/results/round4-backup.json
```

macOS 上显式添加 `--disk-image` 可创建并挂载 32 MiB 的独立 HFS+ 镜像，验证真实
ENOSPC、空间恢复后的事务原子性和只读挂载。脚本先检查容量上限；只填充该测试卷，
正常结束卸载并删除镜像。失败记录保留临时路径，卸载失败时不递归删除挂载目录。
这不是 NAS 文件系统测试，也不是实际断电。同步失败仍使用确定性注入。

新增事务测试包含 96 条跨命名空间原子修改、八客户端 CAS 转账守恒，以及短写、磁盘满、
同步失败和同步后中断的多命名空间矩阵。tombstone 继续计入记录额度并保留 CAS 语义；
第四轮当时的“回收验证”指 WAL 和临时视图；后续物理 GC 与在线备份见下节。


## 安全回收与在线备份（0.3.0）

```zig
// 在进行“键不存在”的业务判断之前取世代；冲突后重新判断业务，不要盲目刷新世代重试。
const epoch = engine.stats().gc_epoch;
_ = try engine.interface().put(allocator, .object, "new-key", .{ .missing_at = epoch }, "value");

// 显式维护：释放 tombstone 的节点、键、记录额度，并收缩 HashMap 容量。
const collected = try engine.collectTombstones();
_ = collected;

// backup_parent 为调用者持有的目录句柄，"backup-001" 必须不存在。
// 返回捕获时的 generation、gc_epoch、records，可直接打开该目录验证或恢复。
const saved = try engine.backup(backup_parent, "backup-001");
_ = saved;
```

回收仅在确实存在 tombstone 时增加 `gc_epoch`；此后旧 `.missing` 和旧世代的
`.missing_at` 均返回 Conflict，即使目标键从未存在。旧 `.exact` 不能匹配已经回收的键，
重建后 generation 仍严格递增。`.any` 继续表示无条件写入，不提供旧请求保护。
普通 checkpoint 不回收 tombstone；请先更新所有创建调用者，再显式开启回收。
分页一致性检查需同时传 `expected_generation = page.generation` 和
`expected_gc_epoch = page.gc_epoch`；省略世代按零处理。

回收与检查点、备份串行，回收写快照及重建索引期间阻塞读写；尚未做增量后台 GC。
临时需要存活节点的新映射和视图数组，并不承诺 RSS 立即下降。安装结果不确定时冻结实例，
须重新打开；安装完成后的 WAL 清理失败可能返回错误，但回收已经生效，查看
`gc_epoch`、`tombstones_reclaimed`、`cleanup_pending`，可调用 `retryCleanup()`。

在线备份在捕获视图后允许写入，只包含捕获边界之前的数据。输出独立 snapshot、空 WAL
和 LOCK，不依赖源目录或硬链接；先同步临时目录，再以不覆盖方式发布正式目录并同步父目录。
目标应为受调用者控制的专用备份目录。失败不冻结源库；发布后的同步错误可能留下完整备份，
重试前应 inspect，不能假定目录不存在。进程强杀可能留下 `.metadata-backup-*` 临时目录，
确认没有备份任务使用后可清理；不要把它当作已完成备份。

备份期间检查点/回收会等待；写入可能因 WAL 额度背压，覆盖值也可能增加临时内存。
同一进程通过 Engine API 发起在线备份，不通过离线 CLI 越过数据库锁。
恢复时可直接打开备份目录，或在目标引擎停止后复制整个备份目录到新的专用位置；
恢复是回退到备份边界，应用必须废弃旧实例的条件写入令牌。
该备份不包含 ZigFS 对象数据或外部密钥，不是完整 ZigFS 备份。

格式、安全性与验证记录见 [维护功能说明](bench/MAINTENANCE-VALIDATION.md)。
