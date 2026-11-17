# 外部 KV 对照工具

这是独立测试 module，不是 ZigFS 或 Admin 的依赖。实际构建和数据目录均使用临时目录。
源码、go.mod/go.sum 留在这里用于复现；不要把临时数据库加入仓库。

初次安装：

```sh
go mod init zigfs-engine-compare
go get go.etcd.io/bbolt
go get github.com/cockroachdb/pebble
go get github.com/dgraph-io/badger/v4
```

本次锁定 bbolt v1.5.0、Pebble v1.1.5、Badger v4.9.6，Go 1.27.1。
复现使用已保存的 go.mod/go.sum，而不是重新获取 latest：

```sh
# 在 pkg/metadata-engine 中执行
benchmark_dir=$(mktemp -d /tmp/zigfs-kv.XXXXXX)
cp bench/external/main.go bench/external/main_test.go bench/external/go.mod bench/external/go.sum bench/external/run.py "$benchmark_dir/"
(cd "$benchmark_dir" && go test -race ./... && go build -o kvbench .)
zig build -Doptimize=ReleaseFast --prefix "$benchmark_dir/zig"
python3 "$benchmark_dir/run.py" --zig "$benchmark_dir/zig/bin/metadata-bench" --go "$benchmark_dir/kvbench" --records 10000 --workers 8 --rounds 3 --output /tmp/external-10k.json
```

`run.py` 默认依次测试 zig、zig-fullsync、bbolt、bbolt-batch、pebble、badger，后续轮次
循环调整起点。可用 `--engines` 选择子集、`--payload` 调整值长度；批量插入固定 32 条，
分页固定 100 条，覆盖每次一个键。workers=1 时 Zig 使用 direct，其余使用 Runtime。
每轮独立临时库，退出后检查文件尺寸并清理。每个二进制由独立 Python 子进程包装，
记录单个数据库进程的峰值 RSS；保存每轮原始输出、SHA-256、指标和三轮中位数。

Zig `compare` 模式只执行一次正常关闭/重开，再逐条校验，跳过原 benchmark 的显式
checkpoint 和第二次重开，使各引擎阶段相同。该可选模式不改变正常 bench 默认流程。

macOS 的 `compare-fullsync` 模式只用于基准程序：通过独立 Io 包装器对普通文件使用
F_FULLFSYNC，目录继续使用现有目录同步，失败不静默降级。引擎默认同步策略不变。
包装器每次同步会额外查询文件类型，测量包含该成本；其他平台不支持此模式，请从
`--engines` 中移除 zig-fullsync。Go File.Sync 在 macOS 默认也采用 F_FULLFSYNC。
Badger SyncWrites=true 使用 mmap MS_SYNC，与上述硬件缓存刷新语义不同。

适配器所有读取/扫描均复制键和值后返回。初次插入检查 missing；Pebble 的该检查只对
本测试的单插入写者成立，不是通用并发 CAS。覆盖键按 worker 分区，无同键竞争。
工具不实现 generation、tombstone、完整 MetadataRepository 契约或复杂业务事务。
错误和重开数据不符均以非零状态退出。bbolt Batch 回调可被重试，适配器回调没有外部副作用。

参考 [对照报告](../EXTERNAL-COMPARISON.md) 中的同步强度与测试规模说明，不能把所有行
直接视为相同断电保证、相同缓存预算、或完整元数据仓库接入后的性能。

## 大规模补测与断点续跑

逐条强同步的百万条更新可能需要很长时间。`--timeout` 为每个数据库进程的秒数上限，
默认且最高为 600（10 分钟）；包装器每 30 秒报告当前案例仍在运行。它不会因为耗时较长而减少
操作数或跳过同步。预计超过 10 分钟的配置不启动，另在 external-predictions.json
记录预测依据；预测不混入实测 runs。

`--resume` 读取输出文件，校验数据规模、配置和二进制 SHA-256，只跳过已完整验证的案例。
每完成一个案例就原子保存结果；失败的案例没有合格结果，重新运行时仍会完整重测。
中断尚未完成的案例无法在库内断点继续，临时库清理后从头开始该案例。

```sh
python3 bench/external/run.py --zig "$benchmark_dir/zig/bin/metadata-bench" --go "$benchmark_dir/kvbench" --records 100000 --workers 8 --rounds 1 --timeout 600 --engines zig badger zig-fullsync pebble --resume --output /tmp/external-100k-short.json
python3 bench/external/run.py --zig "$benchmark_dir/zig/bin/metadata-bench" --go "$benchmark_dir/kvbench" --records 1000000 --workers 8 --rounds 1 --timeout 600 --engines zig badger zig-fullsync --resume --output bench/results/external-1m-256b-8w.json
```

补测每配置先跑一轮，报告会明确区分已有三轮中位数与新增单轮结果。
已保存的 100k 原始文件包含旧计划的六个配置，其中 bbolt 两项按新时限中止/预测；
不要直接续跑该文件来重启长测。上面的重现命令只选择四项，并输出新文件。
每项均有实测结果或明确的预测/中止记录后，可生成按数据量排列的中文时间/内存表：

```sh
python3 bench/external/summarize.py bench/results/external-10k-256b-8w.json bench/results/external-100k-256b-8w.json bench/results/external-1m-256b-8w.json --predictions bench/results/external-predictions.json --output bench/EXTERNAL-COMPARISON.md
```

汇总器拒绝未解释的缺项和重复案例；只有验证通过的 runs 可进入实测行。预测/中止
通过单独文件补充，显式标明类型，阶段耗时和内存不填假值。按当前用户限制，
不要重新启动已判定超时的 bbolt 配置；先用 --engines 仅选预测不超过 10 分钟的项。
