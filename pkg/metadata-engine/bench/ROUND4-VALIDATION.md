# 第四轮：持续运行、复杂事务与恢复验证

日期：2026-11-17。前三轮优化后的独立引擎通过本轮短时验证，未发现需要修改生产引擎
逻辑的问题。本轮补充测试、采样和故障工具，没有接入 ZigFS，也没有改变存储格式。
四轮计划中本机可执行的工作已完成；长期和目标平台可靠性仍有明确缺口。

环境：Apple M2 Pro、16 GiB 内存、macOS Darwin 25.2.0 ARM64、Zig 0.17.0。
持续模型用 ReleaseFast；单元测试分别用 Debug / ReleaseSafe，文件系统故障探针用
ReleaseSafe。本报告的 MiB = 1,048,576 字节，KiB = 1,024 字节。

## 1. 直接看结论

| 项目 | 结果 | 能证明什么 |
| --- | --- | --- |
| 单元与契约测试 | Debug、ReleaseSafe 各 62/62 通过 | 新增复杂事务和既有契约在本机构建通过 |
| SIGKILL | 27 个场景通过 | 指定进程强杀边界可恢复，不等于断电 |
| 5 分钟小值持续运行 | 通过，约 788 万次成功事务 | 指定固定键空间内模型一致、重开正确 |
| 2 分钟大值持续运行 | 通过，约 187 万次成功事务 | 额度压力下可重试恢复；RSS 长期稳定性未证实 |
| 真实磁盘满、只读挂载 | 独立 HFS+ 镜像实测通过 | 本机对应文件系统错误处理成立 |
| 停机备份恢复 | 正常恢复及损坏拒绝通过 | 全目录备份可恢复，检查过程不改源文件 |
| 同步失败、短写 | 确定性注入通过 | 对应程序错误路径已覆盖，不代表真实设备故障 |
| 真正冷缓存、数小时/数日、Linux/NAS、真实断电 | 未验证 | 不预测“通过”，也不据此给数据库成熟度排名 |

## 2. 持续运行：时间、内存、空间

两组均在同一进程、同一实例上运行，覆盖六个命名空间。持续覆盖、tombstone、重新
创建、条件冲突、原子批量、精确读取、分页与后台检查点交错执行。结束后完整模型校验，
再关闭重开并逐条验证。记录数包含 tombstone，不表示所有记录都保留完整 payload。

| 指标 | 小值模型 | 大值模型 |
| --- | ---: | ---: |
| 固定记录数 | 12,288 | 6,144 |
| 每条有效值大小 | 256 B | 4 KiB |
| 负载实测时间 | 300.007 秒 | 120.127 秒 |
| 成功事务 | 7,881,020 | 1,867,644 |
| 其中批量事务 | 1,125,860 | 266,807 |
| tombstone 操作 | 1,576,204 | 373,529 |
| 预期条件冲突 | 15,751,295 | 3,729,880 |
| WAL 额度重试 | 0 | 181 |
| 周期模型校验次数 | 964 | 457 |
| 检查点次数 | 1,134 | 519 |
| WAL 轮转次数 | 3,415 | 7,325 |
| 进程采样峰值 RSS | 23.27 MiB | 161.70 MiB |
| 引擎跟踪分配峰值 | 4.78 MiB | 32.51 MiB |
| 关闭后引擎跟踪分配 | 0 B | 0 B |
| WAL 额度 | 8 MiB | 48 MiB |
| 每秒采样的最大 WAL | 3.00 MiB | 37.40 MiB |
| 目录文件逻辑大小采样峰值 | 9.99 MiB | 84.52 MiB |
| 目录文件数采样峰值 | 7 | 52 |
| 重开数据校验 | 通过 | 通过 |

额度重试是 `ResourceLimit` 后等待维护再提交，不是丢弃事务。大值组完成全部模型校验，
但这不意味着生产调用者可以忽略重试。WAL 额度约束与整个目录占用不是同一个指标。

RSS 并非全程平稳。下表给出各时间窗口的 RSS 中位数：

| 时间窗口 | 小值模型 | 大值模型 |
| --- | ---: | ---: |
| 0–30 秒 | 8.63 MiB | 69.87 MiB |
| 30–60 秒 | 11.15 MiB | 105.31 MiB |
| 60–90 秒 | 13.55 MiB | 119.66 MiB |
| 90–121 秒 | 16.07 MiB | 134.30 MiB |
| 180–240 秒 | 21.88 MiB | — |
| 240 秒至结束 | 17.45 MiB | — |

小值组后段 RSS 回落；大值组在两分钟窗口内仍有增长，不能宣布进程内存已达到稳定平台。
引擎跟踪量只统计经过包装 allocator 的申请字节，不含调用者模型、查询结果、I/O 实现、
分配器缓存及操作系统开销；关闭后归零不等于整个进程所有分配均已证明无泄漏。
后续若放宽时间限制，应优先对大值组延长采样并定位 RSS 来源。

资源与引擎状态每秒分别采样，采样不是同一原子视图，也不保证捕获瞬时峰值。目录统计
按文件名累加逻辑大小，含快照及临时文件；轮转硬链接可能瞬时重复计数。原始数据中的
`allocated_disk_bytes` 同样逐文件名累加块数，不能当作去重后的精确物理磁盘占用。

这轮更改了 payload、键空间及校验间隔；模型带有频繁完整校验，事务数不等于业务 QPS，
不能与此前 60 秒小键空间模型或外部 KV 压测直接比较。本轮未重复百万条性能对照。

原始数据：[300 秒](results/round4-soak-300s.json)、
[4 KiB / 120 秒](results/round4-soak-4kib-120s.json)。

## 3. 复杂事务与故障边界

新增 `src/reliability_tests.zig`，覆盖：

- 96 条记录跨六命名空间：末条条件冲突时全部拒绝，条件正确时原子提交；半数 tombstone
  后仍计入记录额度，missing 不可绕过历史版本，exact 可恢复，检查点重开后逐条核对。
- 八个 Runtime 客户端：各完成 256 次双账户 CAS 转账。每次一致扫描核对总额 2,000,000，
  条件冲突重试，后台检查点并行运行；最终 generation 为 2049，两账户各 1,000,000，重开一致。
- 六命名空间事务：注入短写、磁盘满、同步失败、同步后中断，恢复结果只能六条全有或全无；
  同步后中断要求六条全有，既有已确认记录必须保留。失败返回不意味着事务一定未落盘。

原有 27 个强杀场景继续通过，包含第三轮固定视图捕获后覆盖、插入及 tombstone 边界。
引擎仍没有 LSM compaction；本轮检查的是 WAL 回收与临时视图释放，没有实现 tombstone
物理 GC、公开 MVCC 或磁盘页索引。

## 4. 真实文件系统与备份

`tests/reliability.py --disk-image` 创建独立 32 MiB HFS+ 稀疏镜像，先检查卷容量上限，
只填充该测试卷。实测卷容量 33,513,472 B，填入 32,505,856 B 后得到 errno 28（ENOSPC）。
随后的 2 MiB 双键事务失败，引擎进入需恢复的冻结状态；删除填充文件后重开，已确认记录
完整，失败事务本次两条均不存在，没有部分事务，后续写入及检查点成功。

卸载后以只读方式重新挂载，离线 inspect 成功且文件哈希不变；写模式打开返回
`ReadOnlyFileSystem`。测试正常结束，临时卷已卸载清理。整组约 5.56 秒。
这只覆盖本机 HFS+，并非 Linux/NAS 文件系统或真实介质同步错误。

停机备份复制整个数据库目录，包括 snapshot 和其后的 WAL，恢复后检查六命名空间共
18 条记录，并继续写入。源库及备份哈希保持不变。另补测损坏快照校验和、缺失 WAL：
inspect 均报 `CorruptRecord`，且不改写损坏文件；补测约 0.09 秒。

原始记录：[真实文件系统测试](results/round4-filesystem.json)、
[备份与损坏拒绝补测](results/round4-backup.json)。后者没有再次传 `--disk-image`，
其 `filesystem_faults: unverified` 仅描述该次补测，不覆盖前一份实际通过的记录。

## 5. 复现与验收范围

在 `pkg/metadata-engine` 下执行：

```sh
zig build test test-crash --summary all
zig build test -Doptimize=ReleaseSafe --summary all
zig build mixed-soak -Doptimize=ReleaseFast -- --seconds 300 --slots 2048 --payload 256 --output bench/results/round4-soak-300s.json
zig build mixed-soak -Doptimize=ReleaseFast -- --seconds 120 --slots 1024 --payload 4096 --output bench/results/round4-soak-4kib-120s.json
zig build reliability-probe -Doptimize=ReleaseSafe
zig build -Doptimize=ReleaseFast
python3 tests/reliability.py zig-out/bin/metadata-reliability-probe zig-out/bin/metadata-tool --disk-image --output bench/results/round4-filesystem.json
python3 tests/reliability.py zig-out/bin/metadata-reliability-probe zig-out/bin/metadata-tool --output bench/results/round4-backup.json
```

所有实际运行的单项用例均少于十分钟。混合脚本限制负载为 1–540 秒，子进程超时为
负载时长加 30 秒；编译时间另计。预计超过十分钟的长测不执行，正确性不可用预测替代。
冷缓存需在可控制缓存并记录磁盘读取的环境验证，重开进程不算冷缓存。
当前结论是本机短时可靠性筛查通过，不是生产成熟度或长期资源稳定性的认证。
