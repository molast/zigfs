# CLI 命令接入静态复扫（2026-11-17）

**最新补全状态**：R01–R08 八项均已补写逻辑，统一 **待验证**，覆盖分页、资源生命周期、历史删除、统计过滤、参数校验、错误和文档一致性。逐项改动及限制见 [集中静态审查清单](zigfs-zc-cli-static-review.md#r01r08-补全交付2026-11-17)；下方保留各轮历史。未编译、测试、运行 CLI 或联调。

原始复扫只阅读文档、注册表、生成模型和分派代码；没有运行 CLI、编译、测试或访问服务端。以下是接入缺口，不是运行验收结论。后续补全状态见下表。

原始结论：**S3 operation 注册无遗漏，但文档中的高层命令、兼容入口和部分工作流仍有缺口。** 不能把“100 项 API 已注册”解释为“文档全部 CLI 已接入”。

## 字段处理补全交付（2026-11-17，待验证）

本轮针对下方已确认的两项字段遗漏补写实现，并覆盖各自相关分支；没有进行全仓完整审查，不据此声明全部 CLI 无遗漏。未编译、测试、执行 CLI 或联调，仅修改逻辑、文档、生成覆盖清单并格式化。

| 范围 | 实际修改 | 状态 |
|---|---|---|
| 响应元数据 | wire 提供共用 header-map 提取；匹配前缀不区分大小写，输出键小写，只保留最终 HTTP 响应块。旧 s3api 与模型化路径共用此实现 | 待验证 |
| 输出兼容 | 模型化响应按模型提取 `location: headers`，Metadata 写入 `data.result.Metadata`，同时提供旧消费者使用的 `data.metadata`；无元数据时为空对象 | 待验证 |
| 生命周期读改写 | 规则 add/edit/remove 保留服务端返回的最小转换对象大小设置，仍有规则时随 PUT 写回为独立请求头；删除最后规则/整组清除仍使用 DELETE | 待验证 |
| 生命周期文件往返 | list/export 输出 Rules 和可选 TransitionDefaultMinimumObjectSize；import 接受该格式、旧 Rules-only 文件、LifecycleConfiguration 包装及旧 CLI envelope，区分 XML 规则正文与请求头 | 待验证 |
| 冲突/缺省 | 同一文件内外层设置不一致拒绝；只有 Rules 的旧文件不自动猜测该设置，首次创建或导入时由服务端决定缺省行为 | 待验证 |

下方字段检查是修改前记录。本轮没有补全二进制 stdin/stdout 等已登记边界，也没有把静态修改当成运行验收。

## 字段链路检查历史（2026-11-17，后续实现见上表）

本轮仅静态阅读和注册名称/模型对照，未编译、运行 CLI、测试或联调，未修改业务代码。100 项 S3、114 条管理映射无漏注册，显式命令路径无重复。发现两处此前未登记的字段处理缺口：

| 优先级 | 场景 | 具体断点与影响 | 源码依据 |
|---|---|---|---|
| 中 | HeadObject/GetObject 因扩展字段转入模型化请求层，例如 SSE-C 请求字段 | 模型声明 Metadata 使用 `location: headers` 和 `x-amz-meta-` 前缀，但响应提取循环只处理 `location: header`；最终 envelope 也没有保留完整原始响应头，因此自定义元数据不会出现在模型化结果中。旧 s3api 路径已有独立 metadata 提取，不能覆盖扩展字段回退后的路径 | `modeled.zig` executeOne 响应字段循环及最终输出；`s3api.zig` executeTransfer 模型回退与 metadata 提取；模型 HeadObjectOutput/GetObjectOutput |
| 中 | `ilm rule add/edit/remove`（保留其他规则）以及 export/import | GetBucketLifecycleConfiguration 模型可返回 `TransitionDefaultMinimumObjectSize`，Put 也有同名请求头字段；高层 lifecycle 只取 Rules，编辑写回和导出/导入都未携带该设置。在提供该字段的服务端上，规则往返不能保留完整配置，未传请求头时可能应用服务端默认值 | `convenience.zig` lifecycle；模型 Get/PutBucketLifecycleConfiguration 的 TransitionDefaultMinimumObjectSize |

第一项需在共享模型响应层补齐 header-map 提取，并明确与旧输出字段的兼容关系。第二项需保留服务端返回的独立设置，给导出/导入定义可往返格式，同时兼容现有只有 Rules 的配置文件。原始 s3api 可显式提供该字段，不代表高层规则编辑已经保留它。

本轮未重新登记二进制 stdin/stdout、KMS 上游参数等已明确边界；上述两项是静态控制流确定的遗漏，实际服务端行为仍待后续集中验证。

## 三项断点补全（2026-11-17，待验证）

本轮仅补齐下方检查发现的三项断点，未编译、测试、执行 CLI 或联调。下方检查记录保留为修改前依据。

| 项目 | 本轮修改 | 状态 |
|---|---|---|
| 对象属性分页 | PartNumberMarker 统一写为整数；没有 ObjectParts 的响应作为无续页结果结束，保留已取得的属性页 | 待验证 |
| retention 默认配置 | 配置文件、input-json 与模型字段路径从规范化后的参数重新构造请求，不再传入已消费的 --default | 待验证 |
| watch 检查点 | 在连接和读取前拒绝 --cursor-file - 及与 --cursor 同用；检查点使用只读普通 JSON 文件入口，不再借用 stdin payload reader | 待验证 |

watch 检查点必须为真实文件路径；若确实要使用名称为 `-` 的文件，需显式写为 `./-`。二进制 stdin/stdout 的既有限制不属于本轮三项修改，保持原有边界。

## 最新静态检查（接续补全后，2026-11-17）

本轮只阅读源码、文档及 JSON 模型，使用只读脚本比对注册名称；未编译、运行 CLI、测试或联调，未修改业务代码。100 项 S3 operation 和 114 条管理映射仍均有入口，显式路径未发现重复。**仍有三个确定的执行/参数断点；不能据此宣布无遗漏。**

| 优先级 | 场景 | 静态发现与影响 | 源码依据 |
|---|---|---|---|
| 高 | `object attributes TARGET --attributes ObjectParts --all-pages` / 对应 s3api | 续页转换刻意排除 get-object-attributes，将 NextPartNumberMarker 写成字符串；该操作模型要求 PartNumberMarker 为整数，下一页在本地校验失败。另一个分支在响应没有 ObjectParts 时直接 InvalidResponse，而不是按无分页属性返回 | `modeled.zig` executeInput 的 cursor_result 与 PartNumberMarker 分支；模型 GetObjectAttributesRequest |
| 中 | `retention set --default TARGET --file lock.json --yes`（或 input-json / object-lock-configuration） | 外层删除 --default 并改为 bucket lock set，但原始参数路径调用 modeled.execute 时传的是原始 args，重新解析后 --default 仍在；executeInput 不接受该 flag。普通天数便利语法不经过该路径，不受此问题影响 | `convenience.zig` execute 的 default 分派及 configurable 分支 |
| 中 | `watch TARGET --cursor-file -` | 检查点读取调用支持 stdin 的 command_support.readJson，把 - 当 stdin；保存却把 - 当真实路径原子写文件。缺少一致语义或提前拒绝，可能等待 stdin，也可能写出名为 - 的文件；普通检查点路径不受影响 | `watch.zig` cursor_file 读取与 save；`command_support.zig` readBytes |

### 仍须明确的已有输入输出限制（不重复算作新注册缺口）

主文档第 2.2.2 节统一示例写 `--body FILE|-`、`--output FILE|-`，但模型化 wire.send 的 body_file 只打开普通文件，output 明确拒绝 `-`。本轮 JSON stdin 的补全不等于二进制 body stdin / binary stdout 也已接入。`pipe` 和旧 get 路径的支持同样不能代表所有模型化操作。覆盖清单虽已有组合限制说明，通用示例仍需细分或补齐这些路径。

后续建议按上述三项逐项补逻辑，再统一二进制输入输出的可用范围说明。所有结论均来自静态控制流与模型对照，不是已复现的运行失败记录。

## 本次接续补全（2026-11-17，待验证）

针对下方再次复扫的六项确定问题补写逻辑；本节记录当轮交付，下方扫描结论保留为修改前依据；后续发现见顶部最新检查。**未编译、未运行测试、未执行 CLI、未联调；仅更新源码、文档、生成覆盖清单与格式化。**

| 复扫项 | 本次处理 | 状态 |
|---|---|---|
| retention bypass | 在共享 executeOne 层将 flag 转为 BypassGovernanceRetention，覆盖高层 executeInput 路径 | 待验证 |
| mirror 连接参数 | 复制和远端删除统一传递 endpoint/region/bucket-lookup/CA/timeout/connect-timeout/insecure，与扫描一致 | 待验证 |
| stdin | 新增有界 JSON payload reader，模型化 input-json/file 与管理 JSON 文件均支持 `-`；凭据文件读取仍只读真实文件；拒绝双 JSON 来源及同次 JSON/body 争用 stdin | 待验证 |
| KMS 便利语法 | key create 接入 name/description/set-as-default 并保留 JSON；key status 无 ID 返回密钥元数据与能力，有 ID 执行 describe；配置来源互斥 | 待验证 |
| OIDC 增量更新 | 先取当前 provider，再合并 JSON/显式选项，保留未指定字段；空 secret 由服务端保留，拒绝将脱敏占位符作为新 secret 提交；直达 update 与别名统一适配 | 待验证 |
| 帮助 | 管理别名查询规范名称的路由说明；IAM/OIDC/KMS 等便利动作增加位置参数、选项和边界说明；去除根帮助中的陈旧保留状态 | 待验证 |

范围说明已同步主文档：没有独立契约的 KMS tag、restart/roundtrip、列表分页与 provider 聚合筛选不会被假装透传或标成已实现。用户专属 Access Key 使用已有 `admin user access-key list ALIAS USER`；普通 list/info 只覆盖非用户专属的永久密钥。OIDC 的读改写目前无服务端 CAS，需串行配置写入。

## 再次静态复扫（补全后，2026-11-17）

**结论修正：仍有遗漏，不能将上一轮登记解释为所有逻辑已经贯通。** 本轮只读取源码、模型和文档，并用只读脚本对照注册名称；没有编译、执行 CLI、测试或联调，也未修改业务代码。

注册层：100 项 S3 operation 均有入口；114 条管理模型路由均有入口；合并的显式命令路径未发现重复。这只说明注册齐全，不证明参数、分派和请求正确。

### 确定仍需补齐的接入问题

| 优先级 | 命令/场景 | 源码确定的缺口 | 依据 |
|---|---|---|---|
| 高 | `retention set/clear ... --bypass` | 高层配置直接调用 `executeInput`；该入口允许 bypass flag，但只有 `modeled.execute` 才将 flag 写入 `BypassGovernanceRetention` 请求字段。便利路径没有该转换，因此不会发送对应绕过头 | `convenience.zig:20`、`:148`；`modeled.zig:344`、`:347` |
| 高 | `mirror` 显式连接参数 | 扫描使用 endpoint/region/CA/timeout 等覆盖参数，复制阶段只转发 insecure 等少量选项；远端删除阶段连 insecure 也没带。可能按一个连接生成计划，再按 alias 默认连接执行变更 | `scan.zig` 的 snapshot 与 executeOnce 复制/删除分支 |
| 中 | 模型化 `s3api OP ALIAS --input-json -`，以及配置 `--file -` | modeled 路径仍调用只打开普通文件的 `wire.readJson`，把 `-` 当文件名。旧 s3api 的 readInput 和新便利命令支持 stdin，不能据此宣称所有入口统一支持 | `modeled.zig:296`、`:317`；`wire.zig` readJson；`s3api.zig` readInput |
| 中 | `admin kms key create --name/--description` | 此命令仍直接走 management，只有 JSON 请求体；文档中的字段便利参数未转换。`key status ALIAS` 也没有文档所写的可省略 KEY_ID 语义 | `convenience.zig` wanted；`admin_workflows.zig` KMS 分支；`management.zig` 查询参数白名单 |
| 中 | `admin idp openid update ... [OPTIONS]` | 只用此次选项构造正文，不先取现有配置。仅修改 display-name 等字段会缺 configuration_url/client_id；补齐必填字段后仍可能将未给出的 scopes/claims/role_policy 等恢复默认值。需完整替换语义说明或保留现值的增量适配 | `admin_workflows.zig` provider；服务端 `management.zig` Provider PATCH 替换逻辑 |
| 中 | 管理便利命令的 `--help` | 别名没有 canonical 后的管理路由说明，且统一显示 S3 的 convenience.help；IAM 成员/策略、OIDC、KMS 动作必填参数与选项没有对应帮助 | `cli.zig` helpText；`convenience.zig` help |

### 参数与范围说明仍需收口

- `admin access-key ls --provider/--user/--all` 尚无适配；底层 list 契约只列永久、非用户专属密钥，没有这些查询参数。需要跨已有列表聚合或明确缩小文档语义，不能直接透传。
- `admin kms key list --limit/--marker` 没有底层查询契约或客户端分页；create 的 tag 也无后端字段。七天待删除限制已有说明，不应再当作待补齐的 7–30 天能力。
- `admin kms restart/roundtrip` 没有同名入口，属于上游参考语法与本机工作流范围待明确；不能因为 start/stop 已存在就算完成，也不能凭名称虚构后端路由。
- 第 3.9 节仍写“全部 CLI 待实现”，与已经注册的管理路由矛盾；覆盖生成器统一输出“逻辑已补全，待验证”，无法反映本轮找到的断点。
- 多机、云专属、MFA、service-account、IAM archive 仍按原范围排除；本轮不把这些算作单机 S3 注册遗漏。

建议先补高优先级的请求字段和连接参数贯通，再统一输入、管理便利语法及帮助；上述条目是静态发现，不是运行失败记录。后续集中验证仍需覆盖其他参数组合和服务端行为。

## 缺口补全登记（同日后续）

本轮按上述复扫结果补写逻辑，**统一待验证**；仅生成模型/清单并格式化，未编译、测试、运行 CLI 或联调，未更新二进制。下面的原始审计保留为历史依据，不代表当前仍未接入。

| 原缺口 | 本轮交付 | 状态 |
|---|---|---|
| 兼容命令族 | cors、version info、bucket event/quota/anonymous、retention/legalhold、object legal-hold/find/tree、ilm restore 等映射 | 待验证 |
| 标签与通知 | 重复 tag/key、按键删除标签、通知按 ID 增删及整组清除 | 待验证 |
| 配置便利语法 | 加密、锁、保留期限、legalhold ON/OFF、quota 单位、SQL 参数、anonymous JSON/links | 待验证 |
| 生命周期 | 首条规则创建、remove --all、原始配置导入导出往返 | 待验证 |
| CORS | JSON/XML 文件与 `-` 标准输入 | 待验证 |
| 扫描与同步 | tree 层级、find GLOB/时间/正则、du 快照/服务/版本/分片、mirror 过滤和周期同步 | 待验证 |
| 管理便利入口 | IAM 启停/成员/策略、access-key info、OIDC 适配、原生 legalhold clear、KMS 动作、会话吊销别名 | 待验证 |
| watch 服务端依赖 | 成功对象事件捕获、受权限保护的游标长轮询、过滤/有限重连/游标文件/JSON Lines | 待验证 |
| 覆盖报告 | 纳入兼容入口，去除旧协议误标“复用步骤 01–09”；管理映射随 watch 增至 114 条 | 待验证 |

watch 使用进程内有限回放，重启或过期返回显式错误；mirror --watch 是周期同步。详见 [对象事件游标契约](api/object-watch.md) 和 [覆盖清单](../zigfs-cli/CLI-COVERAGE.md)。S3 配置读改写需串行操作；匿名链接不代表已经验证公开可访问。原审计排除的多机/云端及无独立契约命令仍不在范围内。

## 原始审计记录（补全前）

## 核对范围

- 第 2.2.3 节的 96 项单机规划和 4 项旧协议共 100 项，均有 `s3api` 注册和本地模型。
- Management 清单有 113 条映射；对照当前 `management.zig` 显式路由表的 100 条记录，未发现未映射的 method/path。额外映射来自 OpenAPI；这个数量不证明服务端实际都提供对应行为。
- 另外核对第 2、2.1、3.9 节及步骤 10–29 的高层入口。第 3 节仅作上游参考、没有本项目协议的命令，不直接判定为必须补齐。
- 源码依据：[CLI 注册与分派](../zigfs-cli/src/cli.zig)、[S3 映射](../zigfs-cli/src/catalog.zig)、[高层工作流](../zigfs-cli/src/workflows.zig)、[管理映射](../zigfs-cli/src/management_catalog.zig)、[扫描实现](../zigfs-cli/src/scan.zig)。

## 一、尚未注册的高层命令和兼容入口

这些入口目前不能按文档中的命令名称调用。存在底层替代方法，不等于高层入口已经实现。

| 文档入口 | 当前可用的相关入口 / 接入缺口 | 对应步骤 |
|---|---|---|
| `version info` / `bucket version info` | 只有 `bucket version get`；`version` 根别名已存在，但没有 `info` 子命令 | 10 |
| `anonymous get-json/set-json/links` | 只有 get/list/set；policy JSON 操作可走 bucket policy，links 无生成流程 | 11 |
| `tag list/remove` | 只有 get/set/clear；指定标签删除、保留其余标签的高层流程未实现 | 12 |
| `bucket tag remove` / `object tag remove` | 可替换整组配置，但没有逐键删除入口 | 12 |
| 顶级 `cors list/get/set/remove` | 已有 `bucket cors get/set/clear`，缺少传统入口映射 | 12 |
| `object retention clear` | 只有 get/info/set；清除工作流未包装，底层 PutObjectRetention 已注册，仍须遵守服务端保留规则 | 14 |
| `object legalhold clear` | 已有 enable/disable 和模型化 set；文档 clear → OFF 的入口没有注册 | 14 |
| 顶级 `retention`、`legalhold`、`object legal-hold` | 兼容命令族未注册，`retention --default` 分派未实现 | 14 |
| `ilm restore` | 已有 `object restore`，缺少传统入口及 `--days` 包装 | 15/26 |
| `event add/list/remove` | 只有 get/set/clear；按 ID 增删通知配置的工作流未实现 | 16 |
| `bucket event`、`bucket quota`、`bucket anonymous` | 已有对应顶级或 bucket notification/policy 入口，未实现文档中的分组兼容映射 | 11/16 |
| `object find`、`object tree` | 只有顶级 find/tree | 17 |

## 二、已经注册，但文档中的工作流或语法尚未接完

| 命令 | 静态确认的缺口 | 当前行为 |
|---|---|---|
| `tree` | 树形结构及 `-L/--level` 未实现 | 与 find 共用平面 entries 输出，仅 type 不同；不能只标为“树状功能待验证” |
| `find` | `--name GLOB`、`--newer` 未接入 | name 使用子串匹配；仅支持 name/min-size/max-size 等有限选项。older/regex/max-depth 属文档建议扩展 |
| `du` | 服务级路径、管理快照优先流程、`--versions`、`--incomplete` 未接入 | 当前是本地或显式 fallback 的当前对象扫描 |
| `mirror` | `--include/--exclude`、持续 `--watch` 未接入 | 已有一次性比较/复制/删除流程，不能据此认为所有规划选项完成 |
| `watch` | 真实事件流、过滤和重连逻辑未实现 | handler 直接返回 NOT_SUPPORTED；依赖服务端事件流协议，属于受阻项 |
| `sql` | `--query`、`--input-format`、`--output-format`、`--compression` 默认值转换未接入 | 已有 Select 协议和事件流处理，需使用模型字段或完整 input-json；并非缺少 Select operation |
| `bucket encryption set` | `--mode sse-s3/sse-kms --key-id` 未接入 | 只接模型字段 / 配置 JSON |
| `bucket lock set` / `object retention set` | governance/compliance 位置参数、有效期、days/years/default/vid/bypass 等便利语法未完整接入 | 需按底层 API 配置结构提交；完整长选项 `--bypass-governance-retention` 已有处理 |
| `object legalhold set` | 文档“set 自动写 ON”的语义未接入 | 模型化 set 要求 LegalHold 配置；高层 enable/disable 已接入 |
| `anonymous set public PATH` | 上游位置参数语法未接入 | 当前是 `anonymous set PATH --mode public` |
| `tag set --tag KEY=VALUE...` | 标签键值便利语法未接入 | 当前用完整配置文件或模型 JSON |
| `quota set --size SIZE` | 单位解析及 size 兼容选项未接入 | 当前用 `--max-bytes/--max-objects` |
| `ilm rule remove --all` | 删除所有规则选项未接入 | 当前 remove 强制要求 id；整组清除可走 bucket lifecycle clear |
| `ilm rule export/import` | 缺少可直接往返的配置导入导出适配 | export 直接返回 lifecycle get 的 CLI envelope，import 把文件作为配置 payload；不能把重定向的 export 输出原样导入 |
| `ilm rule add` | 初次无生命周期配置的创建分支缺失 | GET 非零直接返回，未处理“尚无配置”；完整初始化可走 bucket lifecycle set |

复杂参数的模型化入口不等同于上述便利语法。扩展字段与自动分片恢复、stdout/行截取等组合的限制继续以 CLI-COVERAGE.md 为准，本轮没有做逐字段协议正确性验收。

## 三、Management 底层路由已接，但便利入口缺少

| 文档或预期便利入口 | 实际接入形式 / 边界 |
|---|---|
| `admin idp openid ...` | 使用 `admin oidc-provider create/list/update/remove`；validate 使用 `admin oidc validate invoke`，没有原命令族适配 |
| `admin user enable/disable`、`admin group enable/disable/add-members/rm-members` | 使用对应 update 请求 JSON；没有便利命令及成员增量更新流程 |
| `admin policy attach/detach/entities` | 没有独立入口；关联修改依赖 user/group update JSON，entities 查询聚合未接入 |
| `admin access-key info` | 没有独立入口；现有 list 不等于单项 info 工作流 |
| `admin object legalhold clear` | 只有 set 入口，需自己构造对应请求正文 |
| `admin kms key status/rotate/delete/cancel-deletion` | 只有通用 key action，按 JSON action 发请求；动作命令及便利参数未包装 |
| `admin kms status/configure/reconfigure` | 已有 info/set，但没有上游名称及文件/stdin 兼容适配 |
| 规范化会话吊销入口 | 路由已映射为 `admin role-sessions revoke invoke`；不能说“没有吊销接口”，但尚未整理为一致的高层命令名称 |

`admin config` 的通用 history/restore/import、service 控制、MFA、service-account、IAM archive 等，文档已要求先确认独立契约。这些不能因为存在 settings/access-key 路由就认为语义等价，也不应不加区分列为已授权必须实现的命令。

## 四、覆盖报告本身需要收紧的地方

1. `CLI-COVERAGE.md` 的 100 项统计只检查 S3 操作注册；高层兼容入口不在这项断言里，故没有暴露上面的缺口。
2. 该报告把“没有独立高层映射”的项统一显示为“复用步骤 01–09 入口”；旧 Get/PutBucketLifecycle、Get/PutBucketNotification 实际是本批新增 s3api，不能套用这个标签。
3. 主文档第 3.9 节标题“全部 CLI 待实现”已经过时；而步骤 10–29 的“待验证”也只能描述已交付部分，不能覆盖确定尚未实现的入口。
4. 后续登记应逐命令区分：已接入待验证、别名待接入、工作流部分实现、服务端受阻、不在本次范围。无需现在执行测试即可修正这些实现状态。

建议补齐顺序：retention/legalhold/tag/event 等高层动作 → 兼容别名与配置参数转换 → tree/find/du/mirror 工作流 → 管理便利入口；watch 单列服务端依赖。多机复制、远端 tier、云端可选命令不纳入本轮遗漏。
