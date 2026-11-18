# ZigFS 服务压测

| 入口 | 用途 |
| --- | --- |
| `run.mjs` | S3 对象大小/并发矩阵、Range、Multipart、进程资源采样 |
| `benchmark.py` | 指定大小/数量/并发的轻量 S3 压测 |
| `stress.py` | 有界持续读写、内容校验、资源采样与清理 |
| `report.test.mjs` | 报告命令脱敏的单元测试 |

以下命令从仓库根目录执行。结果放在 `zigfs/bench/results/`，已加入 Git 忽略规则。
独立库的压测仍归属 [metadata-engine/bench](../../pkg/metadata-engine/bench/)。
恢复、崩溃与协议一致性验证仍在 `conformance/`；采样和诊断工具仍在顶层 `tools/`。

## Python 入口

两个 Python 工具都使用单目标 JSON 数组；凭据从指定环境变量读取，不写入配置或报告：

```json
[
  {
    "name": "local-zigfs",
    "endpoint": "http://127.0.0.1:9000",
    "region": "us-east-1",
    "access_key_env": "BENCH_ACCESS_KEY",
    "secret_key_env": "BENCH_SECRET_KEY"
  }
]
```

```sh
mkdir -p zigfs/bench/results
python3 zigfs/bench/benchmark.py --targets /tmp/zigfs-target.json \
  --output zigfs/bench/results/quick.json --size 4096 --count 8 --concurrency 2
python3 zigfs/bench/stress.py --targets /tmp/zigfs-target.json \
  --output zigfs/bench/results/stress-new --seconds 60 --concurrency 4 --size 65536
```

报告路径须尚不存在；持续压测会自行创建输出目录。`stress.py` 复用同目录 S3 客户端和
顶层 `tools/diagnostics/common.py` 的报告辅助代码。更多参数用 `--help` 查看。

## Node.js 基准


该目录提供不依赖第三方压测库的 S3 API 基准工具。工具通过 ZigFS
Management API 临时创建 AK/SK，通过 S3/Data API 完成所有文件操作，结束后
删除临时凭证和 Bucket。

## 前置条件

- ZigFS 已启动并处于 `Ready`。
- Node.js 24 或更新版本。
- 运行账号可以调用 `/_admin/v1/auth/login` 和 `/_admin/v1/access-keys`。

## 运行

```bash
node zigfs/bench/run.mjs \
  --endpoint http://127.0.0.1:9000 \
  --admin-username admin \
  --admin-password zigfs-admin \
  --profile smoke \
  --output zigfs/bench/results/phase8-smoke.json
```

`smoke` 覆盖 1 KiB、10 KiB、100 KiB、1 MiB 和 100 MiB 对象，并运行单连接及
并发连接的 Put/Get/Range/List/Delete 与 Multipart。`full` 额外运行 1 GiB 和
10 GiB 对象，适合专用测试盘：

```bash
node zigfs/bench/run.mjs \
  --endpoint http://127.0.0.1:9000 \
  --admin-username admin \
  --admin-password zigfs-admin \
  --profile full \
  --output zigfs/bench/results/phase8-full.json
```

当 ZigFS 由脚本或编排器启动时，可以用 `--pid <zigfs-pid>` 采集 RSS 和 CPU。
Linux 上同时采集 `/proc/<pid>/io` 的进程 I/O 增量；macOS 和其他平台会在报告
中标记 Disk I/O 不可用。也可以通过环境变量补充报告中的构建信息：

```bash
ZIGFS_BENCH_BUILD_MODE=ReleaseSafe \
ZIGFS_BENCH_ZIG_VERSION="$(zig version)" \
ZIGFS_BENCH_STREAM_BUFFER_SIZE=65536 \
ZIGFS_BENCH_COMMAND='...' \
node zigfs/bench/run.mjs ...
```

报告包含硬件、系统、Node/Zig 版本、对象分布、并发度、传输字节数、Requests/s、
吞吐和 p50/p95/p99。报告中的数值只代表本次运行环境，不是 ZigFS 的绝对性能
承诺。`full` 运行前请确认剩余空间足够，并保留原始 JSON 作为基线输入。
