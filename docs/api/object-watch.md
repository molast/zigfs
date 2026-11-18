# 单实例对象事件游标（基础路径已运行验证）

`GET /_admin/v1/buckets/:name/watch` 使用独立 Management 端点和 Bearer 会话，要求 `admin:*` 权限。事件从成功操作后的既有通知捕获入口产生，不依赖配置外发通知目标，不通过 ListObjects 差异推测事件。

参数：`cursor`、`prefix`、`suffix`、`events`（PUT/GET/DELETE/ILM/SCANNER，逗号分隔）、`wait`（0–20 秒）、`limit`（1–200）。首次不带 cursor 时从当前尾部初始化并返回游标，不回放启动前历史。后续带游标长轮询，空页同样返回推进后的 next_cursor。会话过期终止等待。

响应包含 `items`、`next_cursor` 和初始化标记；每条事件包含 sequence、time、category、event、bucket、key、size、etag、version_id、generation。sequence 是进程全局捕获顺序，过滤可导致序号不连续；不承诺多个并发业务操作的事务提交顺序。

服务端最多保留 4096 条 / 8 MiB 事件，单页最多 200 条 / 1 MiB 事件正文。游标绑定进程 epoch，重启、回放淘汰或捕获失败使旧游标返回 HTTP 409 `CursorExpired`；错误游标返回 400。不自动跳到最新位置，不提供持久化回放或 exactly-once。

CLI `watch ALIAS/BUCKET[/PREFIX]` 支持事件/前后缀过滤、`--cursor` 或 `--cursor-file`、`--count`、`--reconnect-attempts`（0–10，默认 3）。只对网络错误有限重连；正常长轮询持续进行直到数量满足或 Ctrl-C。输出一行一个版本化 JSON 事件，非 quiet 时另含游标进度。`--cursor-file` 必须为真实文件路径，拒绝 `-`，且不能与 `--cursor` 同用；名为 `-` 的真实文件请使用 `./-`。检查点文件绑定管理端点、Bucket 和过滤条件，以 0600 原子替换，整页输出后保存；崩溃可能重复，调用方按游标/序号去重。

这是有限进程内回放接口，不能替代持久化消息队列。2026-11-18 已通过真实 CLI 的 PUT 事件、游标消费、事件过滤、JSONL 和 0600 检查点验证；还验证了受限用户被拒绝、重启后旧游标失效；容量、完整授权矩阵、重连与并发行为尚未完整验证。详见 [集中运行报告](../zigfs-zc-cli-validation.md)。
