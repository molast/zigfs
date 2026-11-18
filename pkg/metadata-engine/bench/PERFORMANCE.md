# 独立元数据引擎性能优化

按 1 万、10 万、100 万条查看耗时和内存，请先看[结果总览](EXTERNAL-COMPARISON.md)。

2026-11-17；Zig 0.17.0，macOS 26.2 / aarch64，ReleaseFast。
本轮依据 [v2 验证记录](V2-VALIDATION.md) 中的分页、全量扫描、快照耗时及容量内存问题优化。
保持独立包、v2 文件格式、每事务/组的 WAL 同步、快照文件和目录同步语义。

## 改动

- 分页：AVL 游标一次 seek 后顺序遍历，索引开销从 O(log N + visited × log N)
  降为 O(log N + visited)。游标借用节点，只在状态锁内有效；固定栈有 AVL 高度上界，
  不为每次访问分配内存，也不增加常驻节点大小。
- 全量 scan：按 AVL 顺序复制记录，预分配精确结果容量，省去额外排序及数组增长。
  仍返回调用者独立拥有的副本，仍是全量操作。
- 快照：一次分配条目数组，通过 64 KiB 缓冲写完整帧，flush 后才执行原有 sync、
  原子替换与目录同步。大于缓冲的帧也完整写入，文件格式和故障边界不变。
- 快照 key/payload 仍逐条复制，继续使用调用者 allocator 的大小类别。试验中的连续
  字节块方案虽然快，但十万条峰值 RSS 约 149 MiB，高于基线约 86 MiB，已撤回。
  最终实现保留缓冲写入的速度收益，避免这项内存退化。

## 对照方法

优化前后分别保存同配置二进制，在同一机器交替运行，测量时没有并行启动本任务的编译
或其他压测。每轮为全新临时库，100,000 / 1,000,000 条记录、256 B payload、批量插入 32、
8 个 Runtime 覆盖 worker，其他引擎选项相同。保持同步，未清除 OS 缓存。
每轮都执行读、覆盖、分页、扫描、恢复、快照和重开后的逐条内容/generation 校验。

`compare.py` 调用独立 soak 子进程，每次只启动一轮 workload，使 RSS 不受前一版本的
RUSAGE_CHILDREN 累计峰值影响。报告保留二进制 SHA-256、原始输出、每轮指标及中位数。
本机其他活动、温度和调度仍可能影响结果；这是本地对照，不是目标 NAS 的性能承诺。

```sh
# 修改引擎前后分别构建，保留两个二进制；不要用同一个文件覆盖基线。
zig build -Doptimize=ReleaseFast --prefix /tmp/metadata-perf-before
# 应用优化后：
zig build -Doptimize=ReleaseFast --prefix /tmp/metadata-perf-after
python3 bench/compare.py /tmp/metadata-perf-before/bin/metadata-bench /tmp/metadata-perf-after/bin/metadata-bench --rounds 3 --operations 100000 --output bench/results/v2-perf-100k.json
python3 bench/compare.py /tmp/metadata-perf-before/bin/metadata-bench /tmp/metadata-perf-after/bin/metadata-bench --rounds 2 --operations 1000000 --output bench/results/v2-perf-1m.json
```

## 十万条：各三轮中位数

| 指标 | 优化前 | 优化后 | 变化 |
| --- | ---: | ---: | ---: |
| checkpoint | 232.564 ms | 46.220 ms | -80.1% |
| 前缀分页（1,000 页） | 33.797 ms | 9.933 ms | -70.6% |
| 全量有序 scan | 48.768 ms | 10.350 ms | -78.8% |
| 峰值 RSS | 86.16 MiB | 83.94 MiB | -2.6% |
| 覆盖 QPS | 41,868 | 42,403 | +1.3% |
| 覆盖 P99 | 274.29 μs | 266.38 μs | -2.9% |
| 每轮最大覆盖延迟的中位数 | 14.874 ms | 16.025 ms | +7.7% |
| 快照重开 | 214.685 ms | 215.530 ms | +0.4% |

扫描与快照收益明显；覆盖吞吐和 P99 小幅变化不足以证明稳定改善，最大延迟没有改善。
快照重开没有加速；本轮未修改逐帧读取/解码和重建索引路径。
`full_sorted_scan` 是原有 benchmark 输出名称，优化后表示有序结果，不再执行额外排序。

[十万条原始报告](results/v2-perf-100k.json)

## 百万条：各三轮中位数

先完成两轮交替对照（before/after、after/before），发现优化版第二轮写入尾延迟偏高，
追加一组 before/after；以下纳入全部三轮，不删除较差轮次。追加组命令与上文相同，
使用 `--rounds 1 --output bench/results/v2-perf-1m-repeat.json`。

| 指标 | 优化前 | 优化后 | 变化 |
| --- | ---: | ---: | ---: |
| checkpoint | 2,179.142 ms | 461.951 ms | -78.8% |
| 前缀分页（10,000 页） | 440.332 ms | 167.775 ms | -61.9% |
| 全量有序 scan | 751.077 ms | 174.261 ms | -76.8% |
| 峰值 RSS | 852.13 MiB | 837.13 MiB | -1.8% |
| 覆盖 QPS | 36,019 | 37,980 | +5.4% |
| 覆盖 P99 | 363.92 μs | 488.25 μs | **+34.2%** |
| 每轮最大覆盖延迟的中位数 | 163.901 ms | 116.915 ms | -28.7% |
| 快照重开 | 2,879.913 ms | 2,728.500 ms | -5.3% |

**写入尾延迟没有稳定改善，P99 存在退化。** 优化前三轮最大写延迟范围为
107.244–174.481 ms，优化后为 89.639–289.729 ms；优化后的最差单次停顿反而更高。
本轮收益集中在扫描、快照总耗时及少量内存回收，不能概括为所有读写性能均改善。

两版维护参数相同，但优化版在覆盖阶段完成 10/10/11 次快照，基线为 9/8/9 次。
快照加速改变了后台维护频率，锁内复制和轮转停顿仍存在；这与 P99 变化的因果关系
尚未通过逐阶段 profiling 证实。后续应测量持锁阶段耗时，并优化复制/轮转停顿，
不能只调低同步强度或忽略较差轮次来提高成绩。快照重开的少量变化也不算本轮直接收益。

[百万条前两轮](results/v2-perf-1m.json) · [追加一轮](results/v2-perf-1m-repeat.json)

## 正确性与范围

新增随机插入后包含/排他 seek、空隙与耗尽游标验证，以及大于写缓冲的快照帧、多命名
空间、tombstone 和尾部缓冲的重开校验。既有 OOM、并发快照和分页字节/访问预算测试保留。
本轮仅修改独立包和文档，未接入 ZigFS。索引仍全驻内存，共享状态锁仍存在，
真实 Linux/NAS、冷缓存、数小时稳定性及 SQLite 对照尚待对应环境验证。


最终验证命令：

```sh
zig build test test-crash test-mixed --summary all
zig build test test-crash test-mixed -Doptimize=ReleaseSafe --summary all
```

两种构建均通过 40/40 单元测试、18 个真实 SIGKILL 场景及混合参考模型校验。
格式检查与 git diff --check 通过。性能测量完成后才运行最终回归，未与对照压测争用资源。


## 后续计划

重开与内存、写入尾延迟、条件性架构升级、长期与生产验证的四轮计划，统一维护在
[设计文档第 14 节](../docs/zigfs-metadata-engine-design.md#14-四轮优化与验证计划)。
计划包括执行顺序、每轮验收标准以及 10 分钟测试上限；预测不能作为正确性或长期稳定性通过的证据。
