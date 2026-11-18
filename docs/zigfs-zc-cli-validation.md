# CLI 后台能力补齐与复验（2026-11-18）

最新扩展验收 **81/81 场景组通过**。原先只验证 STANDARD 拒绝的 restore，现在增加了 GLACIER 写入、未恢复读取拒绝、恢复后字节比对、重复恢复及重启保留；还验证归档复制和 DEEP_ARCHIVE 恢复。原 28 个失败场景的所测路径已补齐，但这不是完整 AWS S3 兼容声明。

证据：[最新后台验收 JSON](validation/zc-2026-11-18-backends.json)、[真实服务验收脚本](../zigfs-cli/tests/pending_validation.py)。保留 [首次 49/77](validation/zc-2026-11-18.json) 和 [协议阶段 77/77](validation/zc-2026-11-18-followup.json)；下方旧结论仅供追溯。

## 本轮实际行为

| 能力 | 新增实现与验证 | 适用边界 |
|---|---|---|
| 归档与恢复 | PUT/CopyObject 保存存储类；归档 GET 拒绝；Restore 校验解密和完整性后开放临时读取；HEAD/属性/列表返回实际存储类；恢复过期与错误数据版本单元测试 | 本地逻辑归档，数据仍在本地存储；不是异地冷介质迁移。支持 STANDARD、GLACIER、DEEP_ARCHIVE、INTELLIGENT_TIERING；分片创建的存储类参数仍不支持 |
| 注解 | 加密 PUT/GET/DELETE、分页列表、父对象 ETag 条件、覆盖代际隔离、重启读取；错误密钥与移动密文均无法解密 | 每条 1 B–1 MiB，每版本最多 1000 条；MD5/SHA256 校验；崩溃或父对象删除留下的无引用注解记录尚无专用 GC |
| S3 通知 | 接入现有持久化事件队列和重试；真实 HTTP 首次 503 后重试成功且 event_id 一致；引用目标禁止删除；移除规则后停止投递 | Queue/Topic 指向已注册本地目标 `arn:zigfs:events:::目标ID`，不连接 AWS SNS/SQS；支持创建/删除事件及前缀/后缀过滤 |
| Website | 匿名桶首页、目录首页、404 错误页实际返回；公开访问拦截仍生效 | 使用当前 S3 endpoint；不支持 RoutingRules/RedirectAllRequestsTo；错误页仅用于无资源策略的公开桶 |
| Logging | 实际成功和失败请求生成同 owner 目标桶内的 JSONL 对象；不记录凭据、不递归产生日志 | 在请求结束后同步写入，写入失败不改变原响应；不是 AWS 空格分隔日志或独立持久化日志投递队列 |
| ABAC | Enabled/Disabled 实际控制桶 ResourceTag 条件授权；限制凭据的允许→拒绝→允许已验证 | 未设置时保持原有启用行为；对象标签授权独立 |
| CORS | OPTIONS 加上真实 GET/HEAD 的 Origin 匹配与 ExposeHeader；非匹配来源不返回允许头 | 其他操作、错误/304 响应仍可能使用原全局策略；未实现全部通配符模式 |
| Inventory / Analytics / Metrics | 后台扫描生成真实 CSV 和 manifest 对象；持久化周期检查点；配置后等待并读取实际报表 | 本地固定报表 schema；只支持 Prefix 筛选、CSV、同 owner 目标；OptionalFields、自定义报表加密等不支持的配置拒绝。Metrics 为累计请求/错误数和对象/字节快照 |
| Intelligent tiering | 按版本记录访问时间，扫描按 90/180 天规则切换逻辑归档层，恢复回热读；控制时钟的真实存储单元测试验证转换和内容 | 不迁移物理介质；支持 Prefix；未模拟 AWS 小对象计费/分层规则 |

操作约定、输出位置和格式升级见 [本地 S3 扩展说明](api/s3-local-extensions.md)。Select 仍限未压缩默认 CSV 的 `SELECT * FROM S3Object`（16 MiB），torrent 为最多 16 MiB 的 trackerless 元数据；Requester 计费、全球加速、任意 ACL 和独立 PAB 四开关组合不在本地实现范围。

## 验证范围

验证使用隔离目录、端口和凭据，不修改用户运行实例或系统安装的二进制。服务端单元/契约测试 340/340、CLI 单元测试（23 项，构建缓存命中）、CLI smoke/alias、S3 HTTP/TLS 回归和 81/81 场景扩展验收通过。81 个场景组包含 366 个 help 路径和 100 个 skeleton，入口覆盖不等于所有参数和所有授权组合覆盖。

---

# 协议阶段历史记录（2026-11-18）

后续验收脚本 **77/77 场景组通过**，初次基线为 49/77。原 28 个失败场景中，27 个所测命令场景已获得成功响应和对应断言；剩余 restore 场景纠正了错误前提，验证 STANDARD 对象返回 `InvalidObjectState`，**没有实现归档恢复，也不能把该负向验收等同于恢复成功**。

本轮结果：[复验 JSON](validation/zc-2026-11-18-followup.json)。下方保留首次验收及其 [49/77 基线 JSON](validation/zc-2026-11-18.json)，便于追溯测试前提变化。一个场景组可能包含多个命令，场景通过率不是完整 S3 兼容率。

## 已修复及实际验证范围

| 范围 | 实现和证据 | 限制 |
|---|---|---|
| 桶标签、ACL、所有权、公开访问 | 标签写入现有桶元数据；ACL/所有权查询实际 owner；PAB 查询实际拦截状态；Management schema 补全 `block_public_access` | 固定 BucketOwnerEnforced；不支持任意 ACL 授权；PAB 四开关只接受全部相同，拒绝无法表达的组合 |
| CORS | 元数据持久化、配置往返、真实 OPTIONS Origin/Method/Header 匹配 | 不是全部浏览器 CORS 行为验收；现有普通响应的全局 CORS 策略仍保留 |
| 锁与保留期 | 创建锁定桶启用版本；默认保留、legal hold、按版本更新 retention；真实授权绕过及历史清桶 | 绕过需凭据权限和 IAM 授权；普通初始化凭据无此权限；合规模式不可缩短或降级 |
| 分片复制 | 修复 CLI 把仅有 URI/header/query 的 UploadPartCopy 编成非空 XML 的错误；完成上传并逐字节比对 | 未扩大分片大小、并发或恢复能力声明 |
| 对象属性 | 按请求输出 ETag/大小/StorageClass/完整 SHA256；有 manifest 时输出分页 parts | 当前真实验收主要覆盖无 multipart manifest 对象；不宣称穷尽分片属性组合 |
| 原地加密 | 将 SSE-S3 数据密钥重新封装到已创建的本地 KMS key，原子更新版本历史元数据；内容、ETag、版本、时间、大小和校验和不变；重启后仍可读 | 拒绝未加密、segments 布局及受锁保护对象；外部 KMS 未复验 |
| Select | 真实 CRC 校验 Records/Stats/End 帧，CSV 输出逐字节比对；不支持的 SQL 返回远端错误且不发布输出文件 | 仅未压缩默认 CSV 的 `SELECT * FROM S3Object`，最多 16 MiB；不是通用 SQL/JSON/Parquet 引擎 |
| torrent | 返回真实 canonical bencode 和 SHA-1 分块哈希，测试精确比较全部字节 | trackerless；当前最多 16 MiB；没有实际 BitTorrent 客户端传输验收 |
| 注解查询 | 检查父对象/版本存在并返回空注解列表 | 写入、读取单个及删除注解尚不支持；不是完整注解 CRUD |
| V1 列表 | marker 和 V2 continuation-token 分离；修复 CLI V1 只取第一页，恢复默认 delimiter；真实分页包含 common prefixes，原回归比较 V1/V2 条目 | 未穷举所有 marker/encoding 组合 |
| notification、website、logging、ABAC、analytics/inventory/metrics/intelligent-tiering | 按桶 UUID 在 Metadata Engine 持久化配置；按 ID CRUD/list；旧 notification schema 往返；website 配置重启保留 | **仅配置协议验收**。未接入 S3 notification 的实际投递、网站托管、访问日志目标写入、ABAC 开关执行、报表调度或智能分层执行器，不应启用后期待这些后台效果 |
| request-payment、accelerate | BucketOwner/Suspended 配置往返 | Requester 和 Enabled 明确拒绝；不模拟 AWS 账单或全球加速 |
| restore | STANDARD 对象返回 InvalidObjectState；内容不变 | **归档存储类及实际恢复任务仍未实现** |

## 测试前提和断言调整

- 加密用例原先在创建 KMS key 之前引用不存在的 AWS ARN；现在先启动隔离本地 KMS 并创建 key，再验证真实重封装。测试检查 HEAD 响应头和 GET 字节，避免把 legacy HEAD 的空 JSON body 当作模型字段。
- 保留期用例改用明确继承管理员策略的新凭据；保留不带 bypass 的拒绝断言。服务端没有放宽初始化凭据权限。
- restore 原用例要求普通 STANDARD 对象恢复成功，这不符合存储类语义；改为明确的负向验证，原功能缺口仍列出。
- 未支持/无效的对象子资源写入继续验证原数据不变；已支持的操作不再套用旧的统一 501 断言。
- Select 的 HTTP 错误不再因为缺少 End 帧被错误分类为 NETWORK_ERROR；成功流仍必须通过 CRC 和 End 校验。

## 本轮检查

CLI 单元测试 23/23；ZigFS 单元/契约测试 336/336；CLI smoke、alias 集成及完整 S3/HTTP/TLS 回归全部通过。复验使用独立临时目录、端口和凭据，不修改用户实例、不安装系统二进制。

以上结果补齐了原失败命令的所测协议路径，但**不代表用户要求的全部后端业务能力已经完成**。尤其配置协议通过不能代替后台效果验收。

---

# 首次 CLI 集中运行验证（2026-11-18，历史基线）

本轮执行了原三份文档中待验证命令的集中验收，结果为**部分通过，存在明确功能缺口，不能宣布步骤 10–29 全部完成**。新增验收有 77 个场景组：49 组通过、28 组未通过。一个场景组可包含多个命令；这些数字不是完整命令或参数覆盖率。

机器可读结果见 [完整结果 JSON](validation/zc-2026-11-18.json)。测试代码见 [真实服务验收](../zigfs-cli/tests/pending_validation.py) 和 [独立 HTTP 协议/故障注入](../zigfs-cli/tests/pending_protocol_checks.py)。失败场景继续要求完整功能成功，因此当前新增验收脚本退出码为 1；没有把“不支持”改成“功能通过”。

## 环境和已执行检查

- 基线提交 `1280f0e` 加本轮工作区修改；Zig `0.17.0`、Python `3.14.7`；CLI `0.1.0` ReleaseSafe，ZigFS 本地 Debug 构建。
- 每次测试使用临时数据目录、临时端口、测试凭据及独立 CLI 配置；测试自行启动并终止服务，不使用用户实例或系统安装的 `zc`。
- CLI 单元测试 **23/23** 通过；ZigFS 单元/契约测试 **334/334** 通过。
- CLI smoke、alias 集成、原有真实 S3 + 独立 HTTP 故障注入 + TLS 全量回归通过；路由修复后重新运行通过。
- 实际执行 **366 个生成/兼容入口的 help** 和 **100 项 S3 输入 skeleton**。这证明入口可运行，不证明所有操作和所有输入字段已通过业务验收。

可复现命令（仓库根目录）：

```sh
(cd zigfs-cli && zig build test --summary all && zig build -Doptimize=ReleaseSafe)
(cd zigfs && zig build test --summary all && zig build)
python3 zigfs-cli/tests/cli_smoke.py zigfs-cli/zig-out/bin/zc
python3 zigfs-cli/tests/alias_smoke.py zigfs-cli/zig-out/bin/zc
python3 zigfs-cli/tests/s3api_integration.py zigfs-cli/zig-out/bin/zc zigfs/zig-out/bin/zigfs
python3 zigfs-cli/tests/pending_validation.py zigfs-cli/zig-out/bin/zc zigfs/zig-out/bin/zigfs /tmp/zc-validation.json
```

新增脚本支持 `PENDING_CHECK_FILTER` 正则筛选独立场景，主要用于协议测试定位；有登录等前置依赖的真实服务组应运行完整脚本。

## 验证中修复的问题

**未实现的对象子资源误路由到普通对象读写。** 修复前，`object encryption update` 返回成功，并将 `<ObjectEncryption>…` 配置 XML 写成原对象内容；`object torrent` 返回的是普通对象字节。annotation、ACL、retention、legal-hold 也存在落入普通对象路径的风险。

服务端现在对 `acl/annotation/attributes/encryption/legal-hold/retention/restore/select/torrent` 对象子资源明确分类为 unsupported。新增路由单元测试覆盖 GET/HEAD/PUT/POST/DELETE、版本/预签名参数及冲突子资源。真实 CLI 验证加密更新、ACL、retention、legal-hold、annotation 删除均被拒绝且原对象字节保持不变。此修复**没有实现这些 API**。

原有测试中把 `version` 命令组、精确版本批量删除、版本化复制/删除和历史清桶当作未开放的旧断言已同步当前契约；历史清桶的输出使用 `removed_bucket`，专用路径不再传入不支持的 concurrency 参数。

## 步骤 10–29 运行结论

| 步骤 | 已验证内容 | 结论与剩余范围 |
|---|---|---|
| 10 | 版本 enable/info/suspend、版本列表分页；原回归覆盖精确版本删除及历史清桶 | 已测分支通过；未穷举每种 copy/move/version-id 组合 |
| 11 | anonymous 策略修改能改变实际访问权限；ACL、PAB、Ownership 真实调用 | 匿名访问须先在后端关闭 block_public_access；CLI 管理请求模型拒绝该字段（退出 2），本次直接调用隔离实例 Management 设置前置条件。ACL/PAB/Ownership S3 API 不支持（退出 7） |
| 12 | 对象标签多键设置、按键删除、剩余标签保留与清除 | 对象标签通过；Bucket 标签和 CORS 不支持。CORS 首次设置失败，后续预检未执行 |
| 13 | SSE-S3 默认加密、真实响应头/内容、清默认不改变已有对象；本地 SSE-KMS 写入、密钥轮转后读取与响应头 | 已测本地路径通过；外部 KMS、所有 SSE-C/复制/分片组合未完成验收 |
| 14 | retention default 文件转发与 bypass 请求头经独立 HTTP 验证 | 真实 PutObjectLockConfiguration 不支持，锁/保留完整 S3 工作流受阻；不以协议 fixture 代替真实保护语义 |
| 15 | 首条 lifecycle 规则、export/import/remove-all；旧生命周期协议；独立最小转换大小设置往返 | 已测配置路径通过；后台到期执行和全部 Prefix/Tag/Size/And 组合未验证 |
| 16 | quota 单位转换、写入超额真实失败、清除；S3 event 调用 | quota 通过；S3 通知不支持，按 ID 增删完整流程受阻；原生目标外发未验证 |
| 17 | find/tree/du、服务/版本/未完成上传扫描、健康查询；重复过滤、累计预算和错误注入 | 已测分支通过；资源采样范围见 R04 |
| 18 | mirror 过滤与 diff、三种 shell 补全；真实 watch 事件、cursor、JSONL、0600 检查点 | 已测分支通过；已验证重启后旧 watch 游标被拒绝；mirror 周期长期运行、watch 回放容量过期和所有重连场景未验证 |
| 19 | CLI Management 文件/stdin 登录、session、0600 会话存储、logout 删除会话 | 已测分支通过；受限 diagnostics 用户管理用户/watch 均被拒绝；OIDC 浏览器登录、刷新和会话全生命周期未完成验收 |
| 20 | 用户启停、组成员增删、策略附加/解除；OIDC 增量修改保留字段与 secret 脱敏；用户/组/策略/密钥/会话列表 | 已测分支通过；非管理员全权限矩阵、全部 Access Key/role-session 写入动作未验证 |
| 21 | 本地 KMS 配置/start/create/status/rotate/schedule-deletion/cancel-deletion；设置查询、重启后 KMS 解密 | 已测分支通过；外部 KMS、原生事件目标、全部设置持久化未完成验收 |
| 22 | system/health/storage/monitoring/diagnostics/logs/audit-logs 查询 | 查询通过；下载、GC 实际回收、scanner、directory、原生 multipart/legalhold 写入未完成验收 |
| 23 | ObjectParts 整数续页/无 ObjectParts 分支、Metadata header-map 的独立 HTTP 验证 | 客户端所测协议分支通过；真实 attributes 不支持；copy-part 真实请求被远端拒绝（退出 1），未进入 Complete。SSE-C/全部校验字段组合未验证 |
| 24 | website/logging/request-payment/accelerate 的真实 set 调用 | 均返回不支持；后续 get/clear 业务流程受阻 |
| 25 | analytics/inventory/metrics/intelligent-tiering 的真实 set 调用 | 均返回不支持；后续按 ID CRUD 和报表执行受阻 |
| 26 | restore、Select、torrent 真实调用 | restore/torrent 不支持；Select 返回 NETWORK_ERROR/3，错误分类仍有缺口。未获得真实 Records/Stats/End 成功流 |
| 27 | annotation、原地加密更新、ABAC 真实调用；误路由安全回归 | 不支持；普通对象误覆盖已修复。功能验收仍不通过 |
| 28 | V1 ListObjects、旧 Get/PutBucketLifecycle、旧 Get/PutBucketNotification | 旧 lifecycle 往返通过；V1 列表和旧 notification 不支持 |
| 29 | 366 help、100 skeleton；静态映射与新增可复现运行记录 | 入口核验通过；不代表 100 S3 / 114 管理路由全字段、全授权和全业务验收 |

## R01–R08 及后续修复的证据

| 项目 | 本轮证据 | 状态 |
|---|---|---|
| R01 | 独立 HTTP 返回两页 ListBuckets、空 token 结束、重复 token 拒绝；经服务级 du 调用 | 所测分支通过 |
| R02 | 失效 alias 默认 endpoint + 显式覆盖；region/path/timeout/connect-timeout/page-size；对象删除才带 bypass；真实历史清桶 | 所测分支通过；本轮专用路径未分别复测 TLS CA 组合 |
| R03 | 第一次成功、第二次 403，历史删除和 mirror 保留 completed=1、unstarted=1、outcome_unknown；真实 SIGINT 返回 130 并保留已确认删除 | 所测分支通过；未穷举本地 I/O/每个取消时机 |
| R04 | 两桶各 60000 条记录，排除全部对象仍触发跨桶 100000 总预算；23 项 CLI 单元测试包含 64 MiB/记录边界；10/400 空页 RSS 采样 | 所测分支通过。峰值样本分别 10224/15872 KiB，约增加 5.5 MiB；10ms 采样不是硬峰值，不能代表最大对象页或所有内存路径 |
| R05 | 未完成上传先 ListParts 后按 16 字节应用 min=8/max=20；服务级重复 include 同时保留 txt/csv | 所测分支通过 |
| R06 | version enable/suspend、lock clear、legalhold enable/disable 拒绝未知值参数；event file/arn 冲突；watch cursor-file 参数冲突 | 所测分支通过 |
| R07 | find/tree/du 的列表 403 保留退出 4 及 snapshot 阶段 | 所测分支通过；list-parts/中止/全部网络错误阶段未穷举 |
| R08 | rm/rb 帮助包含历史清理和不支持 concurrency 的边界；IAM/OIDC/KMS 帮助包含位置参数；366 help 实际运行 | 通过；旧验收记录保留为历史 |
| Metadata | 扩展字段触发模型化 HeadObject；混合大小写 x-amz-meta 头；data.result.Metadata 与 data.metadata 一致 | 独立 HTTP 通过 |
| 生命周期独立设置 | add/remove/export/import 保留 TransitionDefaultMinimumObjectSize 请求头，XML 中不混入该设置 | 独立 HTTP 通过；未枚举全部旧 envelope/冲突文件格式 |
| ObjectParts | 第二页发送整数 x-amz-part-number-marker；不带 ObjectParts 的属性页成功结束 | 独立 HTTP 通过，真实后端不支持 |
| retention | --default 配置文件入口不泄漏已消费 flag；clear --bypass 发送治理绕过头 | 独立 HTTP 通过，真实保护流程受阻 |
| watch | 拒绝 cursor-file `-` 和 cursor 冲突；实际事件/文件权限见步骤 18 | 已测分支通过 |
| JSON stdin | 模型化 input-json stdin、Management login 文件 stdin 通过；双 JSON 来源和 JSON/body 争用 stdin 在联网前拒绝；CORS stdin 到达远端但后端拒绝 | 所测分支通过，未穷举全部命令组合 |
| KMS/OIDC/mirror | 本地 KMS 便利字段、OIDC 保留现值、mirror 连接覆盖见上述真实/故障测试 | 已测分支通过 |

## 后续验收条件

28 个失败场景详见 JSON；主要是后端未实现，另有 Management `block_public_access` 请求模型遗漏、copy-part 远端拒绝和 Select 错误分类。缺失 API 的后续命令常因首个前置操作失败而未执行，表内已标“受阻”，不计作通过。

外部 AWS、外部 OIDC/KMS、长期并发和全部故障恢复、全部管理写入与下载、所有参数组合仍没有本轮运行证据。需补齐对应服务能力或测试环境后继续验收；本轮未修改系统安装二进制，也未发布“全兼容”版本。
