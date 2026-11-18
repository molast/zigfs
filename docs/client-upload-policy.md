# 客户端上传与分片规则

适用于 ZigFS CLI（`zc`）和 Admin 新建上传任务。分片由客户端计算；服务端负责校验分片协议、大小、数量、权限和最终合并，不替客户端决定默认分片策略。

## 默认规则

所有大小使用二进制单位：1 MiB = 1,048,576 字节，1 GiB = 1024 MiB。区间左闭右开，达到边界立即进入下一档。

| 文件大小 | 上传方式 | 基准分片大小 | 默认并发上限 |
|---|---|---:|---:|
| 小于 16 MiB | Single PUT | 不分片 | 1 |
| 16 MiB 至小于 128 MiB | Multipart | 8 MiB | 2 |
| 128 MiB 至小于 1 GiB | Multipart | 16 MiB | 4 |
| 1 GiB 至小于 10 GiB | Multipart | 32 MiB | 4 |
| 10 GiB 至小于 100 GiB | Multipart | 64 MiB | 4 |
| 100 GiB 至 5 TiB（含） | Multipart | 128 MiB | 4 |

图示建议的超大文件 4–8 路并发，目前统一取保守下限 4 路；不自动启用 8 路。空文件采用 Single PUT。超过 5 TiB 在创建任务之前拒绝。

这是**按文件大小选择的动态策略**，不是运行中根据网络速度改变片边界的自适应算法。两端使用相同规则；不同机器的 CPU 限制可能导致实际并发不同。

## 分片大小计算

设文件大小为 F，基准分片大小为 B，最大分片数为 N（默认 10,000）：

```text
required = ceil(F / N)
partSize = ceil(max(B, required) / 1 MiB) × 1 MiB
partCount = max(1, ceil(F / partSize))
```

结果必须在 5 MiB–5 GiB 范围内，否则拒绝；不能仅截断至 5 GiB 后忽略片数超限。最后一片可以小于 5 MiB。例如 5 TiB 文件采用 525 MiB 分片，确保片数不超过 10,000。

## 并发和资源

实际默认并发为 `min(档位并发, 可用逻辑 CPU 数, 当前任务共享预算)`，至少 1。无法获取 CPU 数时按 1 处理；Admin 使用浏览器报告的 `navigator.hardwareConcurrency`，CLI 使用系统 CPU 查询。

CLI 的 `--concurrency` 控制多文件并发，不能超过 `min(32, 可用逻辑 CPU 数)`。多个文件共享 CPU 预算，避免文件数乘以分片并发后超限。`--part-concurrency 1..4` 控制单文件分片并发，显式超过可用预算时报错。Admin 当前逐文件执行，各文件内部并发上传分片。

不再根据“分片大小 × 并发数不超过 128 MiB”减少路数：CLI 从文件区间流式读取，Admin 使用 Blob 切片，不要求在 JavaScript 中整体复制分片。分片大小不等于常驻内存大小；浏览器、网络库及服务端仍有各自缓冲，不宣称固定内存上限。目前不检测磁盘/网络速度自动调整并发。

## 覆盖参数与续传

CLI 可以显式设置 `--multipart-threshold`、`--part-size`、`--max-parts` 和 `--part-concurrency`。显式分片大小不自动修改，仍须满足大小和片数限制。手动指定分片选项或 `--resume` 可让小文件进入 Multipart。

```sh
zc cp ./video.mp4 zigfs/molast/videos/video.mp4
zc cp ./video.mp4 zigfs/molast/videos/video.mp4 --resume
zc cp ./video.mp4 zigfs/molast/videos/video.mp4 --part-size 32MiB --part-concurrency 2
```

CLI 不带 `--resume` 时总是新建 UploadId、从头上传；已有默认或显式检查点先备份为 `STATE.previous-随机值`，再原子写入新任务。备份保留旧任务信息，不会自动中止旧远端分片任务；可通过 multipart list/abort 管理。损坏的检查点也可以备份后重新上传，但文件权限、锁和普通文件安全检查仍保留。远端完整对象的防覆盖规则独立，覆盖仍须 `--overwrite --yes`。

CLI `--resume` 未指定 `--part-size` 时读取旧检查点的大小；指定时必须与旧任务一致。Admin 优先使用持久化任务的 `partSize`，其次由远端已有非末尾分片推断。新默认值不能重新切割正在续传的旧任务。CLI 继续检查源文件摘要、上传身份、布局和远端已确认片；不确定的创建/合并结果仍禁止盲目恢复。

CLI 标准输入 `pipe` 不知道完整大小，采用 8 MiB 默认分片、串行上传；可显式设置 `--part-size`，不能断点续传。Admin 小于 16 MiB 的新文件直接通过预签名 PUT 上传；失败保留文件供重新上传，没有分片续传。

## 实现与验证

- CLI：[upload_policy.zig](../zigfs-cli/src/upload_policy.zig)。
- Admin：[upload-policy.ts](../zigfs-admin/web/src/features/objects/upload-policy.ts)。
- 共用边界样例：[upload-policy-cases.json](validation/upload-policy-cases.json)。

两个语言实现以同一份 14 项边界样例验证，涵盖各档位前一字节、边界值、空文件和 5 TiB。CLI 使用稀疏文件 dry-run 检查实际命令的选择；Admin 检查纯策略函数。额外覆盖最大分片数、CPU 并发限制、旧任务布局、单次 PUT/Multipart 分流、错误重试与续传。

```sh
(cd zigfs-cli && zig build test --summary all)
python3 zigfs-cli/tests/upload_policy.py zigfs-cli/zig-out/bin/zc
node zigfs-admin/web/scripts/upload-policy.test.mjs
node zigfs-admin/web/scripts/multipart-upload.test.mjs
```
