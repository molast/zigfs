# Multipart 逻辑发布与分片元数据

实现依据：[Multipart 分片合并优化设计](../plans/zigfs_multipart_merge_optimization.md)。本次落实 P0：流式校验、分片元数据持久化、逻辑发布、幂等 Complete、Range、journal 恢复及引用安全。

## 上传与完成

UploadPart 在接收流时计算 MD5、SHA-256、SHA-1、CRC32、CRC32C 和 CRC64NVME，验证客户端提供的校验值。数据同步落盘后，在该不可变 generation 内写 `.part.meta.tmp`、同步、原子重命名为 `part.meta`，最后通过原有 metadata journal 提交上传记录。并发重传使用新的 generation，不能覆盖已有的半成品。

`part.meta` 使用 `ZFPART01` 魔数、32 字节 SHA-256 和版本化 JSON payload，保存 Upload ID、Part Number、Completed 状态、完成时间、generation、明文长度、物理长度、修改时间、ETag 和各校验值。Complete 验证该记录与已提交的上传元数据一致，校验文件大小及修改时间；不重读分片数据。同大小的外部修改可通过时间检查拒绝，静默介质损坏仍由读取校验发现，不能声称仅查元数据能发现所有 bit rot。

普通 S3 Multipart 的分片编号必须严格递增、不能重复，但不强制连续。非最后一片仍需满足最小大小。

Complete 对同一 Upload ID 加锁，验证提交清单，建立正式对象的独立 segment 文件和清单，持久化数据引用后再提交对象元数据。对象提交复用现有 generation/journal 事务。分片清理失败仍由已有 GC 重试，已发布对象保持可读。

## 物理布局

保留既有路径、分片和对象 ID，避免迁移已有数据：

```text
multipart/<shard>/<upload-id>/<part-number>/<generation>/
  data
  part.meta

objects/<bucket-id>/<shard>/<object-id>/<generation>/data/
  object.meta
  part-0
  part-1
  ...
```

`part-N` 是原始已持久化分片的硬链接，正式对象不引用上传路径。发布清单前完成硬链接和目录同步；之后删除临时目录只减少链接计数，不删除正式对象的数据。覆盖、版本删除和 GC 继续以正式对象 generation 的可达性为准。

`object.meta` 的 `ZFCOMP01` header 区分普通/加密清单。普通清单带 SHA-256；清单包含 `layout=segments`、逻辑总长、每个 segment 的 offset、Part Number、length、原 generation 和 SHA-256。对象的内部 `checksum_sha256` 在 `data_layout=segments` 时是清单摘要，**不是 FULL_OBJECT SHA-256**，不会作为全文 checksum 返回 S3 客户端。Multipart ETag 仍是各 Part MD5 的组合 ETag。

SSE-S3/SSE-KMS 对象不解密、重写分片。清单中的分片解密密钥用最终对象的 DEK 通过 AES-256-GCM 加密，绑定对象 associated data；DEK 继续由 SSE-S3 master key 或所选 KMS 包装。读操作先验证/解开对象密钥和清单，再按原分片 generation 的 associated data 解密命中的帧。

如果文件系统不支持硬链接、跨设备，或旧分片加密布局与目标不匹配，则使用原来的流式连续文件兼容路径。该路径仍可能与对象总字节数相关。默认本地同文件系统、布局匹配的 Multipart 走 O(Part 数) 的逻辑发布。

## 读取与恢复

GET 流式读取有序 segments，完整分片按已记录的 SHA-256 校验；加密数据逐帧认证。Range 只读取命中的 segment 子区间，加密 Range 只解密命中的帧，不先拼接完整文件。清单自身会完整读取和校验，内存需求与 Part 数及流缓冲区有关，不随对象总字节数增长。

新对象元数据 payload 为 `ZFOB 1.7`，增加 data layout 和 Multipart completion receipt（Upload ID + 有序 Part Number/ETag 清单的 SHA-256）。现有 1.0–1.6 元数据仍可读取；旧二进制不支持读取新格式，升级后不可直接降级写入同一数据目录。

重试相同 Upload ID 和清单会返回原对象版本，不重复创建版本；不同清单返回 InvalidPart。这在对象对应版本仍保留时有效。若其版本已被永久删除或未启用版本的对象被覆盖，则不再返回已删除的完成结果。

对象已提交但上传 tombstone 尚未提交时，恢复后的 Complete 识别对象中的 receipt，仅补齐上传终结/清理。对象尚未提交时，保留上传分片，可重试；未提交的 staging/孤立 generation 由恢复和 GC 回收。故障注入覆盖数据准备、目录发布、对象 journal 提交、上传 journal 提交和清理失败。

旧上传没有 `part.meta` 时，使用已有 journal 中持久化的分片记录继续完成；旧连续对象和历史 multipart manifest 保持可读。已有未完成上传无需重传。

## 当前边界与验证

本次未新增可配置、限速的后台物理 Compaction；它是设计文档中的后续 P1，可选整理不影响逻辑对象读写。Complete/Abort 提交终态后，将上传目录原子移入 `.zigfs/trash/multipart/upload-<id>`，作为持久化清理队列；目录树删除由启动/周期 GC 重试，不阻塞完成响应。清理不会扫描/复制对象内容。

验证命令：

```sh
cd zigfs && zig build test && zig build
python conformance/multipart_segments.py --mib 1024
python conformance/sse_s3.py
python conformance/sse_kms.py
```

集成测试使用独立临时数据目录，覆盖真实文件 inode 复用、强制退出/重启、重复 Complete、版本唯一性、跨分片 Range、全对象内容校验、SSE-S3、复制、删除和损坏元数据拒绝。性能测试报告上传耗时与 Complete 耗时，不将上传耗时或 Debug 校验成本计入 Complete。

## 本机实测（Debug 构建）

2026-11-11，独立临时服务、8 MiB 分片，Complete 请求计时包括 HTTP、元数据校验、发布和当时的即时清理：

| 对象 | 分片数 | Complete |
| --- | ---: | ---: |
| 1 GiB 普通对象 | 128 | 0.100 s |
| 16 MiB SSE-S3 对象 | 2 | 0.008 s |

通过 inode 对比验证未复制 payload；读取时全对象 SHA-256 与原内容一致。这不是 100 GB/3000 Part 的实测，也不是性能 SLA。后续清理改为原子移入 GC 队列，不再同步删除目录树。

## Web 上传分片与并发策略

新任务按文件大小选择分片，所有大小均按 1024 换算：

| 文件大小 | 默认分片 | 最大并发 |
| --- | ---: | ---: |
| 小于 256 MiB | 8 MiB | 4 |
| 256 MiB 至小于 4 GiB | 32 MiB | 4 |
| 4 GiB 及以上 | 64 MiB | 2 |

超大文件继续按 10,000 分片限制向上调整分片大小（以 MiB 对齐）。每次启动或恢复上传时读取浏览器的 `navigator.hardwareConcurrency`（客户端可用逻辑核数，不是 ZigFS 服务端核数，也不是实时 CPU 空闲率）。CPU 并发预算为 `max(1, floor(逻辑核数 / 2))`：2 核一路、4 核两路、6 核三路、8 核及以上最多四路。无法获取或返回无效值时沿用四路预算。最终并发数为 `max(1, min(CPU预算, 4, floor(128 MiB / partSize)))`，同时限制连接数和在途数据窗口；若单个分片大于 128 MiB，仍允许一路流式上传。这里限制的是调度窗口，并非浏览器/服务进程总内存上限。请求直接发送 File 的 Blob 切片，不在页面里整文件读取或拼接。

任务使用动态工作队列，某个分片完成后立即补位；每个分片独立签名、最多尝试三次。进度为已确认字节加所有在途分片字节，重试会清除该分片上一轮的临时进度；速度统计汇总各路实际发送字节，包含重试流量。暂停、取消、组件卸载会中止所有活动 PUT；终止性错误会停止调度并等待在途工作退出，避免重试与上一轮任务重叠。仅全部分片成功后按 Part Number 排序提交 Complete。

已有任务使用持久化的原分片大小，恢复时从 ZigFS 查询已完成分片并跳过它们，不为了更改分片大小重新上传。旧 8 MiB 任务也会使用最多四路并发。

2026-11-11 同机、同一 Debug 二进制、隔离服务顺序测试，使用 boto3 直接请求 S3（非浏览器端到端测速）：

| 1 GiB 普通对象上传策略 | 分片数 | UploadPart 总耗时 | 平均速度 | Complete |
| --- | ---: | ---: | ---: | ---: |
| 8 MiB × 1 路 | 128 | 49.059 s | 20.9 MiB/s | 0.067 s |
| 32 MiB × 4 路 | 32 | 12.558 s | 81.5 MiB/s | 0.022 s |

```sh
python conformance/multipart_segments.py --mib 1024 --part-mib 8 --concurrency 1
python conformance/multipart_segments.py --mib 1024 --part-mib 32 --concurrency 4
cd zigfs-admin/web
node --test scripts/multipart-upload.test.mjs
```

实际浏览器吞吐量仍取决于网络、磁盘、CPU、加密及服务构建模式；此对比不代表所有部署环境都能达到相同速度。

## 构建模式对吞吐量的影响

2026-11-11 在同机对照中，保持 1 GiB 文件、32 MiB 分片、四路并发以及原有校验和持久化语义，仅更换 Zig 构建模式。ReleaseSafe 安装到独立临时目录，未替换测试期间运行中的用户服务。

| 构建模式 | UploadPart 总耗时 | 平均速度 | Complete |
| --- | ---: | ---: | ---: |
| Debug（上述对照） | 12.558 s | 81.5 MiB/s | 0.022 s |
| ReleaseSafe，第 1 轮 | 3.147 s | 325.4 MiB/s | 0.021 s |
| ReleaseSafe，第 2 轮 | 3.102 s | 330.1 MiB/s | 0.021 s |

两轮均通过重启恢复、重复 Complete、全对象 SHA-256、Range、复制、删除、SSE-S3 和损坏元数据拒绝检查。SSE-S3 用 64 MiB 小样本做正确性回归，不能当作 1 GiB 加密吞吐量测试。上传计时不包含创建上传任务和 Complete；这是 boto3 直连本机 S3 的测量，不是浏览器端到端耗时，也没有实测 MinIO/RustFS。

```sh
cd zigfs
zig build -Doptimize=ReleaseSafe --prefix /private/tmp/zigfs-upload-release-safe
cd ..
python conformance/multipart_segments.py --mib 1024 --part-mib 32 --concurrency 4 \
  --binary /private/tmp/zigfs-upload-release-safe/bin/zigfs
```

`start.sh` 和 `start.ps1` 的菜单提供 Debug / Release 两个启动选项。Release 使用 ReleaseSafe，与 Docker 构建模式一致，保留安全检查和错误追踪。明确的菜单选择优先于环境变量；兼容的 `fs` 入口默认 ReleaseSafe，可用 `ZIGFS_BUILD_MODE` 覆盖。直接 `zig build` 的默认模式不变。脚本修改不会改变已运行的服务，需重新启动后生效。

本轮不改变校验算法、fsync 或分片存储格式，也不继续增加并发。后续若优化发布构建的吞吐，应分别测量校验 CPU、持久化延迟、网络和磁盘的瓶颈，再评估硬件 CRC、缓冲区大小或批量元数据提交；不能从估算图表推断其他服务的同机性能。

## 浏览器并发上传停滞修复

HTTP 长连接处理必须使用 `Io.Group.concurrent`，不能依赖 `Group.async`：后者在 Threaded 的 CPU 工作预算耗尽时可以同步执行连接处理，导致 `accept` 循环停在某个 keep-alive/未完成请求上，新连接不能被服务。后台常驻维护任务和 metrics listener 同样改用保证并发的调度；连接调度资源不足时关闭该连接，不堵塞或退出监听循环。

浏览器分片 PUT 增加 60 秒无字节进展的看门狗，以及 15 分钟单次请求总超时。只有实际上传字节增加才延长无进展期限；等待服务端确认也受该期限限制。超时作为可重试错误交给原有最多三次的分片重试流程，用户暂停仍使用 AbortError，不混淆两种情况。成功、失败、暂停均清理定时器。

回归命令：

```sh
python conformance/http_connection_concurrency.py --binary /path/to/zigfs
cd zigfs-admin/web
node --test scripts/multipart-upload.test.mjs scripts/multipart-timeout.test.mjs
```

连接测试保留超过 CPU 调度预算的未完成 HTTP 请求，验证健康检查仍可通过，并验证所有待处理连接随后都能完成。修复前相同测试在健康检查处超时。

### 下载暂停/续传诊断

`conformance/multipart_segments.py --check-resume` 会在对象下载中途关闭响应，再从非分片边界发送 Range 请求，核对 206、Content-Range、ETag 及续传拼接后的完整 SHA-256，并报告完整下载和续传速度。2026-11-11 的隔离 ReleaseSafe 测试中，1 GiB 普通对象完整下载约 445 MiB/s、续传约 1020 MiB/s；64 MiB 加密样本约 702/682 MiB/s。测试受热缓存影响，不能外推为 39 GiB 文件的持续同盘读写性能，也不能据此排除浏览器端问题。

Chrome 的原生暂停/继续可能暂停并恢复同一条 HTTP 响应，而不重新发送 Range；连接中断后的恢复才可能重新请求剩余范围。排查时需区分这两种情况，并采样发生降速时的连接、磁盘、CPU、内存及实际字节进度，不能只根据剩余时间估算认定是 Range 路径变慢。
