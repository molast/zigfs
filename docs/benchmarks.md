# Phase 8 性能基线

基准工具位于 [benchmarks/run.mjs](../benchmarks/run.mjs)，运行和参数说明见
[benchmarks/README.md](../benchmarks/README.md)。它使用 ZigFS 的标准 S3/Data API
和 Signature V4，不绕过鉴权、Metadata Commit、fsync 或 checksum。

## 工作负载

| Profile | Small Object | Large Object | 并发 | Multipart |
|---|---|---|---|---|
| `smoke` | 1 KiB、10 KiB、100 KiB、1 MiB | 100 MiB | 1、4 | 10 MiB，5 MiB Part，2 并发 |
| `full` | 同上 | 100 MiB、1 GiB、10 GiB | 1、8 | 100 MiB，10 MiB Part，4 并发 |

每个 Profile 覆盖 PutObject、GetObject、单 Range GetObject、ListObjectsV2、
DeleteObject，并覆盖 Multipart Create、UploadPart、Complete、Get 和 Delete。
每次请求记录耗时，报告 p50、p95、p99、Requests/s、传输字节和吞吐。

## 采样与记录

报告同时记录测试命令、时间、Endpoint、Zig 构建模式和版本、流缓冲区、对象分布、
并发度、操作系统、CPU、逻辑核数、内存和 Node 版本。指定 `--pid` 后以 250ms
间隔采样 ZigFS RSS/CPU；Linux 记录 `/proc/<pid>/io` 读写增量，其他系统明确标记
Disk I/O 不可用。

基准数字只对生成报告的硬件、文件系统、构建模式和配置有效。比较两个版本时应
使用相同 Profile、相同数据根所在磁盘、相同缓冲区和并发度，并保存完整 JSON，
不能只比较终端打印的单一最好结果。任何优化提交都必须同时重跑故障注入、恢复、
checksum 和兼容性测试。
