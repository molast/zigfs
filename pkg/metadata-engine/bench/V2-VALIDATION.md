# v2 独立引擎验证记录

日期：2026-11-17；Zig 0.17.0；macOS 26.2、aarch64。本地原生测试；性能构建为 ReleaseFast。
CPU 型号、挂载参数和磁盘硬件未完整采集，不能据此给 NAS 制定生产 QPS 指标。
文件同步开启，未清除 OS 缓存，未做真实断电试验。

## 正确性与构建

- Debug、ReleaseSafe：38/38 项独立测试通过（含本轮新增的 5 项维护恢复测试）。
- Debug、ReleaseSafe 均通过 18 个实际子进程 SIGKILL 边界：原有 11 个 Engine 场景，
  加上 7 个 Runtime 同组多事务场景，验证确认事务保留、事务原子性和 FIFO 前缀恢复。
- 离线 inspect 不修改文件；recover 只修复不完整的活跃 WAL 尾部。
- x86_64 Linux ReleaseSafe 交叉编译通过；没有在 Linux/NAS 上运行这些测试。
- ZigFS 主项目没有添加依赖或切换存储后端。

测试命令：

```sh
zig build test --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build test-crash --summary all
zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe --prefix /tmp/metadata-v2-linux-build
```

## 万条记录：直接提交与 FIFO/Group Commit

两个全新目录，各 10,000 条、256 B payload、插入批量 32、8 个覆盖 worker。
覆盖每个对象为独立事务；runtime 的等待窗口为默认 100 μs。

| 指标 | direct | runtime |
| --- | ---: | ---: |
| 覆盖事务数 | 10,000 | 10,000 |
| 提交 WAL 同步次数 | 10,000 | 1,252 |
| 覆盖 QPS | 36,272.61 | 39,031.65 |
| P50（μs） | 24.75 | 189.46 |
| P95（μs） | 43.00 | 245.29 |
| P99（μs） | 66.83 | 482.17 |
| 最大延迟（ms） | 208.922 | 3.674 |

这组结果体现了取舍：FIFO 消除了该轮观测到的少量长时间写者饥饿，合并等待却增加了
常见分位延迟。单轮吞吐差异不能证明所有负载都更快。sync 指标只计提交 WAL 同步，
不包括轮转、快照和目录同步。未与旧 ZigFS `.record` 仓库或 SQLite 做性能对照。

```sh
zig build bench -Doptimize=ReleaseFast -- /tmp/meta-direct-run1 10000 256 32 8 direct
zig build bench -Doptimize=ReleaseFast -- /tmp/meta-runtime-run1 10000 256 32 8 runtime
```

## 十万条持续校验

最终版本加强了数据检查：插入 payload 为 `x`，覆盖为 `y`，重开后逐条校验 key、覆盖后的
payload、数量以及最终 generation；不只比较数量或相同内容。

- 实际运行 60.93 秒，15 轮，每轮 100,000 条。
- 每轮包括插入、读取、8 worker 覆盖、分页、扫描、WAL 恢复、快照和再恢复。
- 合计 1,500,000 条插入、1,500,000 次覆盖；校验错误 0。
- 子进程峰值 RSS：86.17 MiB。
- 每轮覆盖 QPS 范围：37,055.15–42,270.90，中位数 40,299.97。
- 各轮最大覆盖延迟中的最大值：133.736 ms。

首轮与 Linux 交叉编译有资源竞争，因此这份数据主要验证持续正确性，不是隔离环境的
稳态性能基准。每轮独立进程和目录，不等于单进程连续运行数日的泄漏/碎片验证。

[原始逐轮报告](results/v2-soak-100k.json)

```sh
zig build soak -Doptimize=ReleaseFast -- --seconds 60 --operations 100000 --workers 8 --output /tmp/meta-soak.json
```

## 百万条容量验证

一轮 1,000,000 条、256 B payload、8 worker、批量插入 32；启用默认后台维护。
数据全部位于独立临时目录，完成后由测试脚本清理。

| 指标 | 结果 |
| --- | ---: |
| 完整流程耗时 | 46.14 s |
| 子进程峰值 RSS | 852.78 MiB |
| 批量插入 mutations/s | 301,123.81 |
| 批量插入事务/s | 9,410.12 |
| 覆盖 QPS | 34,428.34 |
| 覆盖提交 WAL 同步次数 | 125,006 |
| 覆盖 P99 | 475.08 μs |
| 覆盖最大延迟 | 149.892 ms |
| 覆盖阶段新增轮转 | 26 |
| 覆盖结束时后台快照次数 | 9 |
| 10,000 页、每页 100 条的总分页耗时 | 499.797 ms |
| 全量复制排序扫描 | 854.272 ms |
| 首次重开（已有后台快照及增量 WAL） | 3,189.528 ms |
| 最后一次手动 checkpoint | 2,277.859 ms |
| 最后一次快照重开 | 3,220.389 ms |

最终 key、覆盖后的 payload、数量和 generation（1,031,250）均校验通过。
**百万条时峰值内存约 853 MiB，最大写延迟仍约 150 ms。** 原因分析需要进一步 profiling；
锁内视图复制和 WAL 轮转都会阻塞请求，不能把“后台快照”理解为完全无停顿。
常驻逻辑数据额度也不是 RSS 上限。

日志中的 `wal_reopen` 在后台维护启用后可能同时加载快照与增量 WAL，不能解释为纯 WAL
全量重放速度。热内存 get QPS 不包含 HTTP、S3 或对象内容读取。

[百万条原始报告](results/v2-capacity-1m.json)

```sh
zig build soak -Doptimize=ReleaseFast -- --seconds 1 --operations 1000000 --workers 8 --output /tmp/meta-capacity.json
```

`--seconds` 是开始下一轮的时间预算；一轮开始后会完成全部校验，因此这里实际运行超过
1 秒。大规模基准仍需补充不同 payload、混合读写、冷缓存、真实满盘/断电、目标 NAS/Linux
以及数小时以上的单进程运行，不能将这次容量验证当作生产认证。

## 本轮收尾：单进程、单实例混合参考模型

```sh
zig build test-mixed --summary all
zig build mixed-soak -Doptimize=ReleaseSafe -- --seconds 60 --output bench/results/v2-mixed-60s.json
zig build test test-crash -Doptimize=ReleaseSafe --summary all
```

新增混合测试在六个命名空间各使用 64 个键，固定随机种子。前台顺序推进参考状态模型，
Runtime 写线程和后台维护同时运行；包含 missing/exact 条件写、覆盖、tombstone、双记录
原子事务、get、包含/过滤 tombstone 的有界分页及过期 generation 拒绝。
每 64 个事务核对全量模型、记录数和逻辑字节数，计时负载结束后才关闭重开并再次核对。
WAL 单段 4 KiB、总额度 64 KiB、后台周期 10 ms、快照阈值 16 KiB。

| 指标 | 60 秒 ReleaseSafe 结果 |
| --- | ---: |
| 成功事务 | 1,111,919 |
| 双记录批量事务 | 158,846 |
| tombstone 写入 | 222,384 |
| 预期条件/分页冲突 | 2,223,505 |
| 完整参考模型校验（含停止及重开） | 17,375 |
| 后台快照 | 4,574 |
| WAL 轮转 | 38,858 |
| 额度重试 | 0 |
| 同一 PID 每秒采样 RSS 峰值 | 17,232 KiB（16.83 MiB） |
| 最后一次采样 RSS | 12,064 KiB（11.78 MiB） |

模型校验及重开全部通过。2 秒 Debug 快速测试也通过。额度耗尽后的恢复由独立小额度
单元测试覆盖，本次混合负载没有触发额度拒绝。开始阶段与 ReleaseSafe 回归构建存在
资源竞争，不作为隔离环境的吞吐基准。RSS 有上升和回落，采样不代表瞬时峰值，
60 秒不足以证明没有长期泄漏或碎片问题；仍需目标环境数小时/数日运行。

[单进程原始报告](results/v2-mixed-60s.json)

F1/F2 的测试还覆盖默认快照阈值高于 WAL 额度、阈值以下的额度压力、无新 generation
时的删除/目录同步失败重试，以及回收重试保留快照之后的 WAL。文件格式保持 v2，
未接入 ZigFS 元数据路径，未添加迁移流程。


## 性能优化后的回归

扫描游标、全量有序复制、快照数组预分配及缓冲写入优化后，Debug / ReleaseSafe 均通过
40/40 项单元测试、18 个实际 SIGKILL 场景与 2 秒混合参考模型验证。十万条及百万条
前后各三轮完整流程的内容与恢复校验全部通过。
详细收益、内存取舍以及百万条写入 P99 退化见 [性能优化对照](PERFORMANCE.md)。
