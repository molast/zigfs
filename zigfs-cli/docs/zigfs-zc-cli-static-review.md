# CLI 集中静态审查（2026-11-17）

> **最新复验（2026-11-18）**：见 [后台能力与验证报告](zigfs-zc-cli-validation.md)。81/81 扩展场景通过，已加入实际归档恢复、加密注解 CRUD、通知重试、网站访问、日志落桶和报表生成；智能分层有控制时钟的存储测试。本地实现边界与剩余兼容限制详见报告；下方历史“待验证/受阻”状态保留供追溯。

原始审查集中对照文档、命令注册/别名、参数与分派、S3 模型、请求与响应、公用分页、配置往返、管理便利流程、扫描/同步/历史删除及输出错误处理。只读源码/模型并执行注册名称对照脚本；没有构建、执行 CLI、运行测试或连接服务端，未修改业务代码。

这是一份静态发现清单，不是全参数组合验证或零缺陷证明。下方统一登记已能从控制流确定的问题，避免逐次只报一两项。

## R01–R08 补全交付（2026-11-17）

后续编译修复：修正 `admin_workflows.itemBy` 参数与函数同名、`scan.incomplete` 可选前缀字符串类型推断错误；`cd zigfs-cli && zig build -Doptimize=ReleaseSafe` 已通过，生成 `zigfs-cli/zig-out/bin/zc`。未执行功能测试、CLI 请求或联调，以下行为状态仍为待验证；未更新系统安装的 zc。

八项在 2026-11-17 补写逻辑时统一为 **待验证**；2026-11-18 已执行关键分支验证，范围和未覆盖项见顶部报告。原逻辑补全轮仅修改源码、帮助和文档、格式化及生成覆盖清单，当时未编译、运行测试、启动 CLI 或联调；后续编译结果见上段。下方问题描述和覆盖记录保留为修复前的审查证据，不代表仍未实现。

| 编号 | 本次处理 | 状态 |
|---|---|---|
| R01 | ListBuckets 独立使用 ContinuationToken 续页；空 token 结束，重复 token 拒绝；不误用其他操作的回显 token | 所测分支通过；见运行报告 |
| R02 | 历史删除接入 endpoint/region/bucket-lookup/CA/超时、page-size 1–1000、治理绕过；分开列表、对象删除、中止分片和删桶参数，更新参数分派 | 所测分支通过；见运行报告 |
| R03 | 历史删除和 mirror 失败/取消保留原退出码及错误，汇总确认成功、失败阶段与对象/版本/上传 ID、未开始数量及已尝试操作的结果不确定性；本地异常也进入汇总 | 所测分支通过；见运行报告 |
| R04 | 分页临时 arena 使用独立 page_allocator；服务级 du 每桶独立 arena，仅深复制统计结果；跨桶、上传和分片共用累计记录数/序列化结果预算，过滤前计量 | 所测分支通过；见运行报告 |
| R05 | 未完成上传先筛名称/时间/深度，ListParts 累计大小后再做 min/max-size；子桶参数重建保留全部重复 include/exclude | 所测分支通过；见运行报告 |
| R06 | version enable/suspend、lock clear、legalhold enable/disable 明确白名单与目标类型；通知各动作分别校验参数，add 的 file 与 arn/events/prefix/suffix 冲突直接拒绝 | 所测分支通过；见运行报告 |
| R07 | 扫描使用调用级错误上下文保留底层退出码和原始错误，并标记 snapshot/list-multipart-uploads/list-parts 阶段；临时 arena 释放前复制错误 | 所测分支通过；见运行报告 |
| R08 | rb/rm 帮助增加版本清理专用支持/拒绝范围；修正 browse 帮助，标注步骤 04/08 旧验收范围，移除“下一步开始 10”的过时安排 | 所测分支通过；见运行报告 |

当前边界：历史删除串行且首错停止，拒绝过滤、并发、重试/限速、自定义请求头、summary/continue-on-error/fail-empty 等未接入的批量参数；`--bypass` 仅作用于对象删除，不绕过合规保留或 legal hold。`rb --dangerous` 须同时指定 `--force`。部分失败汇总的 `completed` 只统计收到成功响应的操作；已开始但未确认成功的失败项保守标记 `outcome_unknown`，不自动重试，也不声称已回滚。

服务扫描总预算为 100000 条记录和 64 MiB 序列化页面结果，记录包含 Bucket、对象/版本/删除标记、上传、分片及公共前缀，未被过滤选中的记录仍计数；桶数另限 10000。超限明确失败，不返回完整统计。该预算不是进程 RSS 上限；JSON、哈希表、分配器和单页请求缓冲另有开销。diff/mirror 两端也共享单次扫描预算。真实峰值内存、取消和失败路径仍待集中验证。

## 覆盖记录

| 层面 | 本轮检查内容 | 结果与边界 |
|---|---|---|
| 注册与可达性 | 100 项 S3 operation、114 条管理模型映射、基础/生成/工作流/兼容命令；父子路径冲突 | 无漏注册、无显式路径重复、无叶子路径遮挡子命令；不等于语义齐全 |
| 参数与分派 | cli、modeled、objects、mutations、versions、workflows、convenience | 发现 R02、R06 |
| 模型与协议 | 请求字段/响应字段、header-map、XML/JSON、签名和传输、各 List 操作的输入输出游标 | 发现 R01；最近的 Metadata/生命周期设置修复已纳入源码复看 |
| 分页与资源 | modeled、browse、multipart、bulk、scan 的分页与分配器生命周期 | 发现 R01、R04；旧 browse 使用正确的 ListBuckets 游标，不受 R01 影响 |
| 扫描与同步 | find/tree/du/diff/mirror 的过滤、数据来源、子调用、错误与结果汇总 | 发现 R03、R04、R05、R07 |
| 配置往返 | 标签、通知、匿名访问、生命周期、retention/legalhold、OIDC | 最近修复的字段保留路径未发现同类断点；部分参数分支仍有 R06 |
| 管理能力 | 会话/Bearer、路由/请求模型、IAM/OIDC/KMS 便利入口、下载/脱敏 | 无新增漏注册；没有重分类已明确排除的厂商语法；真实授权和持久化行为未验证 |
| 传输与流 | share/POST、分片/恢复、Select 帧处理、watch 游标、HTTP 回调 | 源码检查，没有执行故障注入；二进制 stdin/stdout 和扩展字段组合仍沿用明确边界 |
| 帮助与进度 | README、主参考文档、覆盖表、入口 help | 发现 R08，历史验收说明与当前状态需要区分 |

## 统一问题清单

### R01 — 高：服务级用量扫描可能只统计第一页 Bucket

模型 ListBuckets 的续页字段是 `ContinuationToken`。`modeled.executeInput` 的 more 判断只认 IsTruncated / NextToken / NextContinuationToken，映射也没有 ListBuckets 的 ContinuationToken。`du ALIAS --fallback` 在走服务扫描时通过这一分页器枚举 Bucket，可能只统计第一页并输出 `complete=true`。

依据：[分页器](../src/modeled.zig)、[服务扫描](../src/scan.zig)、本地 ListBucketsOutput 模型。修复需按 operation 区分游标，不能把所有响应中的 ContinuationToken 当作续页字段——其他操作可能只是回显输入 token。

### R02 — 中：历史删除专用路径没有接入通用参数

`versions.execute` 直接拒绝所有 value options，且旗标白名单无治理绕过。`rm --versions` / `rb --force` 进入这一专用路径后，endpoint、region、CA、timeout、page-size 等不会按普通删除流程工作；治理保留历史对象也不能通过该高层路径显式传递绕过参数。普通 retention 的 bypass 修复不覆盖这里。

依据：[历史删除](../src/versions.zig)、[CLI 分派](../src/cli.zig)。至少统一连接参数；其他批量控制须逐项接入或在该命令帮助明确拒绝，不应由通用帮助暗示可用。

### R03 — 中：历史删除与 mirror 缺少部分完成结果

历史删除循环已成功删除若干版本/中止若干分片后，后续失败直接返回该单次调用的错误，没有附上累计已完成数量和失败位置。mirror 同样在复制/删除中途失败时直接返回单次错误，最终 copied/removed 汇总只出现在全成功时。已有 bulk 的 summary 机制没有覆盖这两条独立执行路径。

依据：[versions.execute](../src/versions.zig)、[scan.executeOnce](../src/scan.zig)。应保留单次错误及其退出码，同时报告已确认成功、失败阶段、尚未执行与可能未知的结果；不能声称失败即无修改。

### R04 — 高：分页和服务级扫描的临时内存没有完整释放/计量

main 将进程 arena 传给 CLI；modeled 每页临时 arena 又使用该 allocator，页结果/token 等长期数据穿插分配到父 arena，子 arena 的 deinit 不能保证回收实际底层内存。每次请求的模型解析、传输缓冲等不计入 64 MiB 的结果字节计量，页数增长可能累积大量内存。service du 又在同一 allocator 上扫描所有 Bucket，未给每桶临时扫描设置独立释放生命周期，也没有整个服务扫描的累计对象/字节预算。

依据：[入口 allocator](../src/main.zig)、[模型分页](../src/modeled.zig)、[service du](../src/scan.zig)。这是分配器所有权的静态风险，未做内存实测；需独立可释放的临时 allocator，并只复制必要的结果/游标/统计，明确预算是每桶还是整体。

### R05 — 中：du 过滤在分片和服务范围不一致

- `incomplete` 在 ListParts 之前用 size=0 调用 selected。带正数 min-size 时所有未完成上传被排除；max-size 判断也不是基于已上传分片总大小。
- service du 为子 Bucket 重建参数时只遍历 r.values，重复 include/exclude 只剩最后一次值，未传递 r.repeated。单桶和服务级调用会得到不同筛选结果。

依据：[scan.incomplete / usage](../src/scan.zig)。应先做不依赖大小的筛选，汇总分片再做大小筛选；跨子调用保留重复参数及其排除优先语义。

### R06 — 中：部分工作流静默忽略不适用参数

`bucket version enable/suspend`、`bucket lock clear`、`object legalhold enable/disable` 使用 workflows 的 clean 后直接 executeInput。没有完整的 value-option 消费检查，executeInput 又不会逐一拒绝 r.values；例如 version enable 加未知 value option 仍可能发送启用请求。通知 add 使用 --file 时，也会静默忽略同时给出的 arn/events/prefix/suffix，而非按约定拒绝或合并。

依据：[workflows.clean / execute](../src/workflows.zig)、[modeled.executeInput](../src/modeled.zig)、[notification](../src/convenience.zig)。需命令级参数白名单与组合规则，统一“未知参数拒绝、文件与短选项冲突可解释”，不能只校验参数名称是否可解析。

### R07 — 中：扫描失败丢失原始错误码

snapshot/incomplete 将底层所有非零响应转为 `error.ListFailed`，CLI 没有专门映射，最后变成通用退出码 1 和通用错误。权限拒绝 4、网络失败 3、不存在 5、取消 130 等信息丢失；find/tree/du/diff/mirror 的扫描阶段均可能受影响。

依据：[scan](../src/scan.zig)、[CLI 错误映射](../src/cli.zig)。应保留底层结构化错误/退出码并补充阶段上下文，而不是仅抛无数据错误枚举。

### R08 — 低：帮助和进度仍混有已过期表述

browse.help 仍称 force/versioning 未支持；主文档步骤 08 的旧记录仍说 force 仅清未版本化桶、版本清理未开放，后续执行从步骤 10 开始。与当前 versions 分派和待验证批量交付状态不一致。历史验收记录可以保留，但需显式注明当时版本范围，并链接当前命令能力/限制，避免用户把旧限制当当前状态。

依据：[browse.help](../src/browse.zig)、[主参考文档](zigfs-zc-cli-rustfs-reference.md)。

## 后续处理与验证边界

R01–R08 的逻辑补全见上表。后续集中验证应覆盖多页/重复游标、跨桶预算、重复过滤、分片大小过滤、参数拒绝、删除中途失败/取消、原错误码及 arena 生命周期；不能仅凭本次补写就标记全 CLI 已完成。

多机/云专属、没有独立契约的 KMS 上游语法和 provider 聚合过滤、二进制 stdin/stdout 与扩展传输组合的已知限制不重复计为本轮新缺口。运行兼容性、权限、取消、持久化、并发竞争与真实资源占用仍未验证。
