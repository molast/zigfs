# ZigFS 单机 S3 与 IAM 完整权限实施计划

> 状态：实施基线，尚未完成实现。日期：2026-10-29。
> 本文用于持续执行、交接与验收。勾选必须附代码与测试证据；已有 CRUD 不代表权限闭环完成。
> 用户要求：完整串联 S3、User、Group、Access Keys、IAM Policies；覆盖相关 Go/Zig 单测；后端变更涉及前端时同步完善。权限系统只面向单机，不引入多机同步、分布式锁或分布式一致性设计。

## 1. 目标与完成定义

从 Admin 表单、Go BFF、Zig Management API、持久化、身份认证到每一个实际 S3 操作，使用同一套真实身份与授权规则。创建、绑定、修改、禁用、解绑、删除、到期和重启恢复，都必须影响实际访问结果。

必须同时完成：

- 用户/组分配策略后，实际请求获得对应权限；无授权默认拒绝，显式 Deny 优先。
- Access Key 不得绕过所属用户的权限边界；临时凭证、预签名、POST、复制、分片和批量操作不得成为旁路。
- 组成员可以按策略共享资源，不能仍以“桶必须由自己创建”代替 IAM。
- 用户登录、管理接口与 S3 数据接口都有明确的身份、会话和授权边界。
- Identity Policy、Bucket Policy、角色信任策略分别使用正确语义；条件必须读取真实上下文。
- 权限数据由 ZigFS 持久化管理；Go 不能直接读写数据目录；前端不能成为授权依据。
- Go、Zig 的权限相关逻辑可独立测试；真实 HTTP/S3 集成测试证明链路一致。
- 前端能操作和解释后端实际支持的权限能力，不保留与实现冲突的开关、文案或“看似保存成功”的功能。

“完整”不能以放宽 JSON 校验、增加可保存字段或隐藏错误代替实现。以下阶段必须保留到验收；尚未实现的项目明确列出，不能删掉清单后声称完成。

## 2. 当前代码基线与已确认断点

| 领域 | 当前证据/入口 | 当前状态与待补问题 |
| --- | --- | --- |
| 用户、组 | `zigfs/src/application/identity_store.zig` | 有 CRUD、密码哈希、策略与组关联，保存到 `.zigfs/system/identities.json`；缺稳定主体 ID、身份版本和完整登录/授权关联 |
| 策略 | `zigfs/src/application/policy_store.zig` | 八个默认 JSON 位于 ZigFS，首次初始化后可修改/删除；运行数据为 `.zigfs/system/policies.json` |
| 策略引用 | `zigfs/src/transport/management.zig` | 已有关联校验；被用户/组引用的策略删除返回冲突；需覆盖全部新增引用和原子性 |
| 凭证 | `zigfs/src/application/credential_service.zig` | 有期限、禁用、用户归属、Key 内联策略、动态用户/组读取；`inherit_policy=false` 时跳过用户/组策略，形成权限上限绕过 |
| IAM 求值 | `zigfs/src/auth/iam_policy.zig` | 已实现部分 Action/Resource/Condition/变量语法；需要逐项验证 AWS/S3 语义，不能视为完全兼容 |
| S3 请求上下文 | `zigfs/src/transport/iam_context.zig` | 有身份、时间、连接 IP、签名、部分参数/请求头；没有完整资源标签、组织、角色、会话上下文 |
| 桶访问 | `zigfs/src/transport/s3.zig::ensureBucketOwner` | IAM 判定之后仍检查 owner，阻断策略允许的用户/组共享；匿名访问有独立路径，需要统一规则 |
| 管理端预签名 | `zigfs/src/transport/management.zig` | 检查 Key 策略但仍要求桶 owner 匹配；需与 S3 的资源共享语义一致 |
| POST 上传 | `zigfs/src/transport/s3.zig::servePostPolicyUpload` | 独立认证/求值/写入路径；必须专项验证 owner、策略、表单字段、正文与其他上传路径一致 |
| 用户登录 | `zigfs/src/transport/http.zig`、`auth/management_session.zig` | 当前管理登录只匹配配置中的管理员；已创建用户的密码没有接入管理登录，会话不携带用户主体 |
| 对象标签 | `zigfs/src/domain/object.zig`、`transport/s3_protocol.zig` | 未见完整对象标签模型与 S3 Tagging 操作；Bucket 的 `tags_json` 不能代替 Object Tagging |
| Bucket Policy | `transport/s3_protocol.zig` | 未有完整 Get/Put/DeleteBucketPolicy 路径；现有 private/readonly/public 设置不等价于 JSON Bucket Policy |
| 角色/组织 | 当前 Identity 模型 | 没有真实模型、信任策略或 AssumeRole 链路，不能为 Condition 伪造值 |
| Go BFF | `zigfs-admin/server/internal/{router,handler,service,zigclient,contract,port}` | CRUD 已有接口；需审查登录身份、授权信息透传以及所有直接管理操作，防止复用管理员身份绕权 |
| Web | `zigfs-admin/web/src/features/{identities,access-keys,policies}` | 已有操作入口；需与最终权限语义、管理能力、登录身份和资源可见性同步 |
| 测试 | `conformance/user_access_keys.py` 与相邻 Zig/Go 测试 | 有基础链路覆盖；部分现有测试固化旧的 owner 隔离和不继承时提权行为，必须更正预期并保留新的拒绝用例 |

以上是本次代码核查结果，不是全部审计结论。实施 P0 时继续补充函数级清单。

## 3. 必须固定的授权语义

### 3.1 主体与权限来源

- 区分部署管理员、普通用户、用户组、角色、角色会话、长期 Key、临时 Key、匿名请求。
- Group 只聚合用户权限，不作为可登录/可签名主体；禁用组移除其授权贡献，不等同于禁用其所有用户。
- 用户直属策略与所有启用组的策略合并求值：允许取并集，任意适用 Deny 优先。
- 用户没有任何适用 Allow 时默认拒绝；用户 disabled/deleted、Key disabled/deleted/expired、会话 revoked/expired 均拒绝。
- 用户派生 Key 的权限不得超过父用户。使用主账户权限表示没有额外 Key 限制；自定义 Key 策略表示在父权限基础上进一步限制，不能取代父权限。
- 旧 coarse policy 位图与 JSON 策略的关系明确迁移：不能因为存在 JSON 就意外放开旧限制，也不能错误地拦截新的细粒度 Action。
- 配置中的部署管理员与同名普通用户严格区分；客户端提交 owner/username/principal 字段不能指定高权限身份。
- 主体使用不可复用的稳定 ID；删除后同名重建不得继承旧 Key、会话、信任关系和 Bucket Policy 授权。

### 3.2 Identity 与资源策略

- Identity Policy 绑定用户、组、角色；Bucket Policy 绑定桶并支持 Principal/NotPrincipal；Role Trust Policy 控制谁能 AssumeRole。
- 不把三种策略交给同一个无类型校验器，也不把 Principal 当成无效字段直接忽略。
- 显式 Deny 在所有适用策略中优先；权限边界、Key 限制、会话策略不能被资源策略绕开。
- 固定本地账户模型，再按 AWS/S3 规则列出同账户用户、跨账户主体、角色 ARN、角色会话 ARN、匿名 Principal 的决策表。资源策略与身份策略不能一律相交或一律相并。
- 角色主体与会话主体的资源授权差异必须有测试；组织只是策略上下文/治理数据，不代表另一个集群。
- 桶所有权是资源元数据及必要的所有权规则，不是所有 S3 Action 的唯一授权依据。
- S3 API 返回的资源拥有者应是真实 owner，不是本次访问者。
- ListBuckets 的权限和返回范围单独定义：遵循选定的 S3 账户模型，控制台“可访问桶列表”可另做过滤接口，不能混淆 `s3:ListAllMyBuckets` 与 `s3:ListBucket`。

### 3.3 时效、并发与故障

- 单机进程内锁/事务协调授权数据；定义统一锁顺序，避免身份、策略、凭证、对象锁之间死锁。
- 权限变更提交后，新请求必须使用新版本；已签发会话/预签名不得无限缓存旧权限。
- 定义长传输、复制、分片完成、批量删除与撤权的并发边界。禁止校验与实际写入间出现可利用的资源/标签替换。
- 身份/策略/密钥数据损坏、缺失引用、存储不可用时拒绝访问，不能退回管理员/默认宽权限。
- 原子替换、文件同步、重启恢复和迁移必须保持引用完整。不是多机问题，不引入共识协议或跨节点缓存。

## 4. 实施顺序与任务清单

### P0：操作—Action—资源—上下文清单与测试基线

- [ ] 枚举每个 S3 operation、Management route、Go route；列出 Action、资源类型、附加授权、匿名策略、请求上下文、资源上下文、对应测试。
- [ ] 单独列出 HEAD、带 versionId、CopyObject、UploadPartCopy、POST Policy、DeleteObjects、分片完成/中止，避免凭 HTTP method 猜权限。
- [ ] 对照 `docs/api/s3-api-coverage.md` 和 `s3-compatibility.md`，标记已实现、缺权限、缺存储/协议、外部服务依赖；所有未支持能力保留跟踪项。
- [ ] 审计八个默认 JSON 的每个 Action：S3、admin、kms、sts 各自对应哪个实现；不能把文档存在当成能力已实现。
- [ ] 固定标准参考版本与语义用例来源；为每个修复先加入能暴露现状的失败测试。
- [ ] 建立权限专用测试入口和覆盖清单，记录现有通过用例以及必须改正的旧预期。

交付：操作矩阵、缺口列表、测试基线。后续新增操作必须更新矩阵。

### P1：身份、引用与存储生命周期

- [ ] 为 User/Group/Role/Key/Session/Account/Organization 设计稳定 ID、显示名、状态、版本、创建/更新时间和引用关系。
- [ ] 用户策略绑定、组成员、组策略绑定在单机原子事务/快照中提交；校验重复、缺失、非法跨账户引用和容量上限。
- [ ] 普通 PATCH 区分字段缺失、空值、空数组、false；省略字段不得清空关联；同名竞争与乐观并发版本冲突返回稳定错误。
- [ ] 明确删除规则：被引用策略/角色/组/组织返回依赖冲突或执行显式原子解绑；不进行隐式级联提权。前端展示影响与引用。
- [ ] 删除/禁用用户使所有派生身份失效；删除组只移除该组贡献；同名重建无旧授权。
- [ ] 八个默认策略只初始化一次，编辑和删除持久有效；初始化缺失与系统文件丢失/损坏必须可区分，不能在损坏后重新补宽权限。
- [ ] 迁移现有用户名引用、`user:<name>` owner、凭证格式及策略文件；提供备份、版本检测、回滚限制和无静默提权规则。
- [ ] 验证重启、崩溃写入中断、保存失败、孤立引用、重复 ID 和损坏 JSON 的恢复行为。

### P2：统一策略解析与求值

- [ ] 独立策略类型：Identity、Bucket Resource、Role Trust、Key Restriction、Session、Permission Boundary；明确每类允许的字段及默认行为。
- [ ] 校验 Version、Statement 对象/数组、Sid、Effect、Action/NotAction、Resource/NotResource、Principal/NotPrincipal、Condition；冲突字段、重复 JSON key、错误类型、非法 ARN 均有定义。
- [ ] 明确通配符、大小写、ARN 各段匹配、变量转义、缺失变量、无匹配语句、无 Allow、多策略 Deny 优先；对照标准修复当前实现差异。
- [ ] 覆盖 String/Arn/Numeric/Date/Bool/Binary/IP/Null 全操作符及否定、IfExists、ForAnyValue、ForAllValues；验证缺失/空集合、多值、AND/OR/NOR。
- [ ] 日期覆盖 UTC、偏移、精度、非法输入；IP 覆盖 IPv4、IPv6、CIDR、映射地址；数字避免精度/非有限值边界错误。
- [ ] 为上下文建立类型与适用 Action 注册表。保存期检查语法和支持情况，运行期检查真实值；“支持但该请求不存在”与“功能未实现”分开处理。
- [ ] 输出结构化授权结果及原因码，可供测试和审计；不能在公开错误里泄漏其他用户策略或秘密。
- [ ] 评估解析深度、语句数、字符串长度、变量膨胀和匹配复杂度上限，防止策略计算耗尽资源。

### P3：User → Group → Access Key 权限链

- [ ] 无论 `inherit_policy` 值如何，用户 Key 都加载并执行用户/启用组的权限上限。
- [ ] 自定义 Key JSON 与父授权相交；明确空 JSON、空 Statement、删除限制、coarse policy 与继承开关的 API 语义。
- [ ] 管理员创建用户 Key 也不能赋予超出用户边界的权限；请求 owner 字段不可信。
- [ ] 实现凭证生成、秘密只展示一次、存储加密、轮换、到期、撤销、禁用/启用、查询脱敏；临时凭证校验 token 与父会话链。
- [ ] 策略修改、组解绑/禁用/删除、用户禁用、Key 修改均在下一次认证生效；已有预签名 URL 同样受当前权限约束。
- [ ] 提供只读有效权限/权限来源诊断接口，显示用户直属、组来源、Key 限制及 Deny 来源；诊断接口本身受管理权限保护。

### P4：S3 统一授权入口与资源共享

- [ ] 用明确的认证主体和授权结果替换各 handler 的 owner-only 判断；不得用特殊用户名/空 owner 字符串表示“管理员放行”。
- [ ] 所有已实现 S3 操作经过统一 Action/resource/context 判定；不存在未授权的 handler 直通路径。
- [ ] CreateBucket、ListBuckets、桶配置/版本/生命周期/配额/删除、对象读写/HEAD/删除分别映射正确 Action；未实现配额等操作有独立实现任务。
- [ ] 版本对象使用版本 Action 与真实 versionId；删除标记、null version、历史版本不能混淆。
- [ ] CopyObject/UploadPartCopy 分别检查源读取与目标写入，源/目标/版本/标签上下文不能混用；补齐未实现的复制分片能力。
- [ ] Multipart 的创建、上传、列出、完成、中止都重新授权；已创建 upload ID 不能当永久通行证。
- [ ] DeleteObjects 逐项求值、逐项结果，包括版本删除；未授权项不能受其他已授权项带动执行。
- [ ] POST 同时校验签名、POST policy 和 IAM；不能信任未绑定的表单字段/伪造头；流式/分块上传、校验失败不留下可访问对象。
- [ ] 预签名生成与访问分开：生成者有权使用指定 Key，消费时再次验证当前权限及实际上下文；过期、禁用、撤权立即影响消费。
- [ ] 匿名 public/readonly 迁移为可解释的资源策略语义；显式拒绝优先，管理写入能力不得匿名开放。
- [ ] 管理端目录操作、对象上传/下载、预签名、分片等不能绕过同一个数据授权内核。

### P5：Bucket Policy、ACL/所有权与公共访问

- [ ] 实现并持久化 Get/Put/DeleteBucketPolicy，校验桶内 ARN、Principal、权限及冲突；增加对应 IAM Action 与 S3 协议响应。
- [ ] 资源策略参与用户、角色、会话、匿名的统一决策，覆盖 NotPrincipal、Principal 通配符和条件限制。
- [ ] 定义账户/桶/对象所有权模型以及 Block Public Access 行为；公共策略、ACL 与管理端 access policy 设置不能相互覆盖失控。
- [ ] 对照完整 S3 权限矩阵处理 Get/PutBucketAcl、Get/PutObjectAcl、Object Ownership、版本对象 ACL；若采用禁用 ACL 模式，实现其协议语义和错误，不伪装支持。
- [ ] 策略误配置导致锁定时，保留明确、受审计的部署管理员恢复入口；不能普通用户可用。
- [ ] Web 增加 Bucket Policy/公共访问管理、验证、引用和影响提示；不能只保留 private/readonly/public 三个选项冒充完整策略。

### P6：真实上下文、对象标签与属性授权

- [ ] 身份上下文：稳定 userid、username、PrincipalArn/Type/Account、主体标签、会话来源及临时凭证信息。
- [ ] 请求上下文：连接 IP、真实 TLS/协议版本、时间、区域、认证类型、签名版本/年龄、token issue time；仅可信代理配置允许转发事实覆盖，默认不信任 X-Forwarded-*。
- [ ] 对象标签完整模型：每版本独立存储，校验键值/数量/编码/重复项，支持持久化、备份、GC 与恢复。
- [ ] 实现 Get/Put/DeleteObjectTagging 及版本变体；上传 x-amz-tagging、复制标签指令、分片完成标签、POST 标签都读取实际落盘的数据。
- [ ] 实现 `s3:ExistingObjectTag/<key>`、`s3:RequestObjectTag/<key>`、`s3:RequestObjectTagKeys`，严格按 S3 适用操作提供；不能把请求标签当已有标签。
- [ ] 已有标签读取与访问/修改在一致的对象版本/锁范围内，覆盖覆盖写、并发改标签、复制源和删除后的重建。
- [ ] Bucket/Principal/Resource tags 按各自标准键及适用操作接入，禁止混用命名空间；标签写入本身也需授权，避免用户改标签提权。
- [ ] 补齐真实 S3 上下文：LocationConstraint、prefix/delimiter/max-keys、versionid、copy-source、metadata/tagging directive、SSE/KMS、storage class、ACL/grants、Object Lock/保留期/合法保留、MFA 等。
- [ ] 每个上下文键绑定其实际业务实现；没有加密/保留/MFA/标签后端时，先实现业务与校验，再允许依赖该键的授权。
- [ ] Web 同步对象/版本标签编辑、主体标签、相关配置与权限提示。

### P7：角色、组织、STS 与默认策略涉及的能力

这些是本地身份/授权数据，不涉及多机。不能为了接受对应 Condition 而填固定值。

- [ ] 实现本地 Account/Organization/组织路径/成员关系；稳定 ID、管理权限、迁移、删除限制与持久化。
- [ ] 提供组织上下文（例如 PrincipalOrgID/Paths，以及确有资源所属组织时的 ResourceOrgID/Paths）；无组织主体按缺失值语义处理。
- [ ] 实现 Role：信任策略、权限策略、权限边界、最大会话期限、状态、主体 ID/ARN、关联管理接口。
- [ ] 实现 STS AssumeRole：调用者授权、目标信任、ExternalId、SourceIdentity、SessionName、SessionTags/TransitiveTags、会话策略、期限和角色链约束。
- [ ] 派生临时 AK/SK/Token 记录不可伪造的父身份/角色/会话链；撤销、父禁用、角色修改与重启后均可重新授权。
- [ ] token/session context 不能由普通 S3 头/参数声明；跨账户与同账户信任规则分别验证。
- [ ] `sts:AssumeRole` 默认语句必须真正对应 STS 行为，不是普通上传/下载的附加许可。
- [ ] 为 consoleAdmin/diagnostics 的 admin Actions 建立准确管理操作矩阵；为 KMS 三个默认策略建立实际密钥管理/数据加密能力与调用权限。
- [ ] KMS、MFA、Object Lock 等若依赖尚无的子系统，拆成明确前置实现任务与验收，不算“策略已完整”后遗留。
- [ ] Web 增加角色、信任关系、会话/撤销、组织/标签等所需管理入口，与本地实际模型一致。

### P8：用户登录、管理授权与 Go BFF

- [ ] 普通用户可通过已有密码登录；验证哈希、禁用状态、限流、错误不枚举用户、密码修改后旧会话失效。
- [ ] 会话带签名保护的主体 ID、身份版本、期限、用途；不再“有任意有效 token 就按配置管理员处理”。
- [ ] 每次管理请求重新校验主体状态和所需 admin/S3 权限；管理员、诊断用户、普通数据用户能力区分。
- [ ] 列出全部管理路由的操作权限、资源范围、自助范围；用户不能修改自己的组/策略/角色以提升权限。
- [ ] Go 保留真实调用者身份并转交 Zig；禁止普通用户请求使用 BFF 的管理员凭证执行。
- [ ] 所有资源查询/列表/详情/编辑/删除检查归属与授权；ID、名称、URL 路径、body owner 都可能伪造。
- [ ] 授权由 Zig 最终执行；Go 的会话检查、参数校验、错误映射与能力展示不能取代授权，也不能形成相反规则。
- [ ] 管理侧预签名/分片/目录等直接调用数据服务时保持相同限制；禁止“UI 无按钮但直接请求成功”。
- [ ] Go contracts/ports/client/service/handler/router 全链同步字段、错误、版本和可选值语义；OpenAPI 同步。
- [ ] 审查 cookie、CSRF、CORS、会话退出/撤销、secret 日志脱敏及授权失败审计。

### P9：前端联动完成清单

沿用 `zigfs-admin/web/AGENTS.md`：实际 shadcn/ui 组件、紧凑 Dialog、固定底部动作、表单主体滚动、全局 top-center toast、共享 AlertDialog。

- [ ] 登录页支持普通用户；全局 Session 明确当前主体/能力；退出、过期、禁用、撤权时清理旧数据与 UI 状态。
- [ ] 路由、侧栏和按钮根据能力展示；后端 403 仍需正确处理。无权查看的资源不得通过旧缓存/链接泄漏。
- [ ] User：直属策略、所属组、启用状态、密码、标签、稳定 ID、有效权限来源和派生 Key 一致显示/更新。
- [ ] Group：成员、策略、启用状态与影响范围；添加/移除成员后刷新用户详情，禁用组不错误显示用户全禁用。
- [ ] Policies：完整 JSON 编辑/校验、资源/条件/Principal 摘要、NotAction/NotResource 标签、引用列表、删除冲突；默认策略与自定义策略同样可管理。
- [ ] Access Keys：明确“继承/进一步限制”语义；切换不能放宽父权限；创建/编辑/列表/详情使用同一字段和校验。
- [ ] Key 秘密只在创建/轮换成功时显示和导出；列表和详情脱敏；日期时间、到期/禁用状态与服务器一致。
- [ ] Bucket/Object：策略允许的共享资源可见；Bucket Policy、公共访问、对象版本标签、所有权/ACL/保留相关能力与后端同步。
- [ ] Role/Organization/Session：按 P7 新增必要入口，不能仅有后端字段却无法配置/撤销。
- [ ] 有效权限/模拟器展示上下文、匹配策略来源和拒绝原因，不把“一次模拟允许”描述成所有请求都允许。
- [ ] 删除确认展示引用与影响；并发更新冲突保留草稿；失败不关闭表单、不显示成功 toast；重新获取服务端真实状态。
- [ ] 前端 TypeScript 类型、API client、能力缓存失效和所有表单交互测试同步；避免双重校验拒绝后端已支持的合法 JSON。

### P10：审计、迁移、性能与最终验收

- [ ] 审计身份、Key/会话 ID、操作、资源、策略版本、结果、原因码和 request ID；不记录 SK、Token、密码或完整敏感签名 URL。
- [ ] 记录权限变更前后影响、操作者与关联引用；审计查看受权限保护。
- [ ] 缓存只优化解析/读取，版本变更可靠失效；不能延迟撤权。先证明正确性，再测单机压力和锁竞争。
- [ ] 旧权限数据迁移、备份恢复、格式版本与回滚限制写入运维文档；迁移失败不得降级为全权限。
- [ ] 更新 API、兼容性、默认策略说明、部署/恢复和已知限制；所有“支持”都有测试链接。
- [ ] 完成下述 Go/Zig/端到端矩阵；不得因旧测试依赖越权行为而保留漏洞。

## 5. 测试设计：权限实现必须可测

### 5.1 可测试性约束

- 策略编译/求值是纯逻辑：输入明确的策略集合、主体、Action、Resource、Context，输出结构化 Decision，不能隐式读当前时间/全局管理员。
- 认证与授权分开；验证签名/密码成功不代表授权成功。
- Clock、随机源、存储端口、身份/策略解析器、会话与凭证依赖可注入；到期边界测试不依赖 sleep 或真实秘密。
- 每个业务入口都能断言“拒绝时没有发生存储写入/外部调用”；使用 spy/fake 观察调用次数与参数。
- 单测使用独立临时目录、固定测试数据和可控失败注入；集成测试用隔离的 loopback 端口与数据目录，不读写开发服务。
- 失败注入覆盖读失败、写失败、fsync/replace 失败、解密失败、无效引用；内存分配失败路径按 Zig 既有测试方式覆盖。
- 安全敏感授权分支必须有对应测试编号。行覆盖率只能辅助，不以任意百分比取代完整允许/拒绝矩阵。

### 5.2 Zig 单测矩阵

| 编号 | 模块/层次 | 必须覆盖的用例 |
| --- | --- | --- |
| Z01 | `auth/iam_policy.zig` | 所有合法/非法字段组合、策略类型、Statement 对象/数组、空文档/空语句、重复字段、深度/大小上限 |
| Z02 | 策略匹配 | Action 大小写、Resource 大小写、ARN、`*`/`?`、NotAction/NotResource、Principal/NotPrincipal、单值/数组、变量注入与缺失变量 |
| Z03 | Condition | 每种操作符及否定、IfExists、集合量词；键缺失、空集合、多值 AND/OR/NOR、Null、非法类型、日期/IP/数值边界 |
| Z04 | 决策合并 | 无 Allow、单 Allow、多 Allow、任意来源 Deny、Key/Session/Boundary 限制、资源策略与不同 Principal 的规则 |
| Z05 | 身份存储 | 名称/ID 校验、唯一性、PATCH 缺失字段、关联存在性、组同步、冲突更新、原子提交/失败、删除/同名重建、损坏恢复 |
| Z06 | 凭证服务 | 用户无策略、组允许/拒绝、禁用组、移除成员、不继承仍受父限制、Key 内联策略缩权、coarse 迁移、跨用户 owner 伪造 |
| Z07 | 凭证生命周期 | 启停、删除、准确到期边界、临时 token 缺失/错误、轮换、父禁用、角色变化、重启恢复、秘密清零和返回脱敏 |
| Z08 | 管理会话 | 管理员与同名用户、密码哈希/校验、disabled、密码变更、token 篡改/到期/用途混淆、旧会话撤销、主体版本 |
| Z09 | 请求上下文 | IP/TLS 真实来源、可信代理、转发头伪造、重复 header/query、签名类型/年龄、URL 解码、POST 字段、body buffer 生命周期 |
| Z10 | S3 handler | 每个 operation 的正/负授权；无权限时不访问/不写入存储；匿名、头签名、query 签名、POST 路径一致 |
| Z11 | 组合操作 | copy 源/目标独立拒绝、版本隔离、分片撤权后完成失败、批量逐项拒绝、预签名创建与消费、流式上传失败清理 |
| Z12 | 资源策略 | 同账户/跨账户/角色/会话/匿名、公共访问限制、错误 Principal、显式 Deny、所有权/ACL、共享桶不受旧 owner 门禁阻断 |
| Z13 | 标签/ABAC | 对象版本标签生命周期、请求/已有标签区分、缺标签、改标签提权、复制/分片标签、读标签与写操作并发一致性 |
| Z14 | STS/组织 | 信任与调用权限双检查、ExternalId、SourceIdentity、SessionTags、期限/链长度、会话限制、组织迁移/退出、父撤权 |
| Z15 | 管理路由 | 每个路由的所需 Action、普通用户越权、资源范围、自助范围、直接调用 Zig 也不能绕过 BFF |
| Z16 | 持久化与迁移 | 旧格式读取、ID/owner 引用迁移、策略默认初始化、损坏不重置、备份恢复、原子失败、崩溃恢复、一致的拒绝行为 |
| Z17 | admin/KMS/MFA/保留 | 默认策略对应操作实际允许/拒绝；密钥使用/管理分离，MFA 状态不可伪造，Retention/LegalHold/Bypass 权限分别验证 |

实施位置：优先在 `zigfs/src/auth/`、`application/`、`domain/`、`metadata/` 与 `transport/` 对应模块旁添加测试。新增模块必须导出/引用到 `zig build test` 的测试根，避免“写了测试但未执行”。

### 5.3 Go 单测矩阵

| 编号 | 层次 | 必须覆盖的用例 |
| --- | --- | --- |
| G01 | Contract/JSON | 身份/角色/标签/策略字段序列化；字段缺失与 false/空数组区别；不返回 password_hash、SK、Token；创建秘密响应例外明确 |
| G02 | Zig client | URL/路径编码、真实 token/身份透传、超时取消、连接失败、响应解析、401/403/404/409/422/5xx 映射、非 JSON 错误 |
| G03 | Service | 所有用户/组/策略/Key/角色/会话操作参数；无权/非法输入时不发起变更；后端拒绝不可被改写为成功；不自行提升主体 |
| G04 | Handler | 请求体/路径/查询校验、PATCH 语义、body owner 伪造、恶意 ID、重复/超大字段、错误状态码和统一响应格式 |
| G05 | Router/Middleware | 所有私有路由未登录拒绝；过期/伪造/禁用会话；普通用户管理越权；自助接口跨用户访问；cookie/CSRF/CORS |
| G06 | 登录与会话 | 普通用户登录成功/失败、管理员与同名用户隔离、logout/撤销、密码修改、会话变更、身份错误不得回退管理员 |
| G07 | 数据操作代理 | 目录/对象/预签名/分片/桶配置使用真实调用者；生成他人 Key URL 拒绝；原始 Zig 的 403 原样保留语义 |
| G08 | 能力与 UI 数据 | 能力/有效权限接口脱敏、不同主体隔离、权限变更后更新；诊断数据不可泄漏他人策略和秘密 |
| G09 | 稳定性 | context cancellation、并发请求主体隔离、日志脱敏、无状态共享污染；相关代码执行 race 检查 |

使用 Go 标准 `testing`、`httptest` 与现有 port 接口 mock/fake，覆盖 client/service/handler/router 四层，不能只有 mock 成功响应。直接调用 Go API 的拒绝测试不可由前端按钮隐藏测试代替。

### 5.4 真实链路验收场景

每项通过 Admin/Go 创建数据，再通过真实 SigV4/STS/HTTP 操作验证；必要时绕过 Go 直接调用 Zig 验证最终防线。

1. 创建无策略用户与 Key：登录身份可识别，但没有未授予的数据/管理权限。
2. 用户直属 readonly：读取允许、写入拒绝；writeonly 反向验证，不擅自扩大默认 JSON Action。
3. 用户通过组获得指定桶读写；另一用户/组按同一资源策略共享；无授权第三方拒绝。
4. 直属 Allow 与组 Deny、组 Allow 与直属 Deny：都拒绝；多个组的允许正确合并。
5. 删除成员、禁用/删除组、解绑/修改策略：下一次请求立即反映变化，原预签名同样变化。
6. 关闭 Key 继承、传入 `s3:*`、改 coarse bits 都不能突破父权限；Key 额外 Deny 或 Resource 限制生效。
7. 用户/Key 禁用、删除、过期、轮换、父角色撤销；同名用户重建不能恢复旧凭证。
8. Bucket Policy 对用户/角色/匿名授权；显式拒绝、公有访问设置、ACL/所有权边界分别验证。
9. 请求 IP、时间、TLS、prefix、versionId、标签条件正负用例；伪造转发头、认证类型参数、Principal 标签不产生授权。
10. 标签 API 修改真实存储，ExistingObjectTag 的权限随版本和标签变化；并发修改不能读写错对象。
11. copy 源允许/目标拒绝与源拒绝/目标允许；分片中途撤权；批量混合允许/拒绝；POST 和 query 预签名不能旁路。
12. 普通用户登录后，仅可见/操作授权内容；直接请求隐藏的管理 API 仍拒绝，不能自助加组/绑策略提权。
13. AssumeRole 双授权、限制会话策略、临时 token、角色链、父撤权、组织退出；会话标签只能来自合法签发链。
14. 重启前后授权结果一致；损坏权限文件、缺引用、恢复备份、迁移失败都不降级为放行。
15. admin/diagnostics/KMS 默认策略的实际操作分别验证；不能以成功保存 JSON 作为测试结果。
16. 两个浏览器身份并存、并发变更、旧会话和旧 UI 缓存不混淆主体；秘密不出现在列表、日志和错误输出。

继续扩展 `conformance/user_access_keys.py`，按需要拆分 `iam_authorization.py`、`s3_resource_policies.py`、`sts_sessions.py` 等隔离脚本；脚本名称是建议，不表示已经存在。覆盖真实 SDK（boto3/awscli/MinIO 客户端）的可重复用例，并记录兼容性差异。

### 5.5 前端交互验收

- 创建/编辑/删除 User、Group、Policy、Key 后，列表、详情、关联选择器和有效权限同步更新。
- 400/401/403/409/存储失败分别验证：错误 toast 可见，草稿保留，无假成功；401 触发正确会话处理。
- 所有 JSON 策略形态、条件、否定字段和 Principal 正确显示；前端校验不错误拒绝合法后端文档。
- 角色/组织/对象标签/Bucket Policy 新入口可完整配置、修改和撤销，不靠手工改本地文件。
- 权限撤销后路由/菜单/列表刷新，不能继续使用之前缓存的受保护数据。
- 密钥创建弹窗只展示一次秘密；日期时间和时区转换正确；键盘、窄屏、明暗主题、紧凑弹窗与 top-center toast 正常。

## 6. 文件与接口变更落点

| 层 | 现有主要落点 | 新增/调整内容 |
| --- | --- | --- |
| Zig 身份与策略 | `application/identity_store.zig`、`policy_store.zig`、`credential_service.zig` | 稳定主体、引用事务、权限来源、凭证边界；按职责拆分 account/role/session 等模块 |
| Zig 求值与认证 | `auth/iam_policy.zig`、`management_session.zig`、`sigv4.zig` | 类型化策略、决策器、真实用户会话、STS 签发与验证 |
| Zig 存储 | `domain/`、`metadata/`、`ports/`、`backend/` | 标签/角色/会话/资源策略的可测试端口、格式版本、恢复与原子性 |
| Zig HTTP/S3 | `transport/http.zig`、`management.zig`、`s3.zig`、`iam_context.zig`、`s3_protocol.zig` | 统一身份/授权入口、完整操作映射、标签与 Bucket Policy/STS 协议 |
| Go | `zigfs-admin/server/internal/{contract,port,zigclient,service,handler,router}` | 身份和新模型透传、管理边界、全部错误路径与测试 |
| Web | `src/api/client.ts`、`src/types/api.ts`、`src/App.tsx`、`src/routes.ts`、`src/features/` | 会话/能力、现有表单语义修正、新管理入口、资源可见性与关联刷新 |
| 文档 | `docs/api/*.yaml`、`docs/api/s3-*.md`、`docs/operations.md`、`docs/known-limitations.md` | 契约、Action/context 矩阵、迁移与实际兼容性 |
| 回归 | `conformance/` 与各模块相邻测试 | 可独立运行的权限测试集和真实链路回归 |

前端或 BFF 新增字段必须与 Zig 契约同一阶段交付；不存在“后端先改完但 UI 永远使用旧语义”的完成状态。

## 7. 验证命令与证据要求

在对应目录运行：

```sh
# zigfs/
zig fmt --check src
zig build test
zig build

# zigfs-admin/server/
go test ./...
go test -race ./...
go test -coverprofile=/tmp/zigfs-admin-auth-coverage.out ./...
go build -o /tmp/zigfs-admin-permissions-qa ./cmd/admin

# zigfs-admin/web/
pnpm run build

# 仓库根目录；隔离服务，不使用开发数据
python3 conformance/user_access_keys.py --admin-bin /tmp/zigfs-admin-permissions-qa
git diff --check
```

新增集成脚本和前端测试框架后把实际命令补入本节。Zig 如当前工具链不提供稳定覆盖率报告，记录测试枚举与关键决策分支映射，不杜撰覆盖率。Go 覆盖率低的权限分支必须逐项解释/补测；`go test -race` 不替代业务权限测试。

每阶段完成必须记录：变更文件、对应清单编号、测试名/命令/结果、行为变化、存储/API 兼容影响、前端验证、剩余阻塞。真实集成测试通过前，不用“单测全绿”宣称整条授权链已通。

## 8. 执行与交接规则

1. 顺序：P0 → P1/P2 → P3/P4 → P5/P6 → P7/P8 → P9 → P10。前端与 Go 变更随对应后端阶段同步，P9 是最终整体核验，不是延后所有 UI 工作。
2. 不一次性重写所有权限代码。每个可审查小批次包含：失败用例、实现、单测、必要集成、契约/前端同步和文档进度。
3. 不能因为任务时间长而删除对象标签、管理登录、资源策略、角色/会话等项。遇到产品语义分歧，记录具体问题与依赖，继续不依赖该决策的任务。
4. 本文是持续执行清单；上下文切换后先读本文与进度记录，再核对实际 Git/测试结果，不把聊天里的“完成”当唯一证据。
5. 不覆盖用户现有变更、不重置工作区、不将未完成事项标为已完成。

### 进度记录

| 阶段 | 状态 | 证据/下一步 |
| --- | --- | --- |
| 实施计划 | 已编写，待执行核对 | 当前文档；代码基线来自本次仓库核查 |
| P0 | 未完成 | 下一步：生成完整 S3/Management/Go 路由授权矩阵，建立失败回归 |
| P1–P10 | 未完成 | 按本清单实施；已有局部功能需重新验证，不能整阶段直接勾选 |

### 每次交接填写

- 已完成清单编号与对应代码：
- 本轮测试命令及结果：
- 当前进行中的具体任务：
- 已确定的语义/兼容性决策：
- 尚待确定的问题及其依赖范围：
- 失败测试、复现方式与隔离测试数据位置：
- 下一步最小可执行动作：

## 9. 最终完成门槛

- [ ] 所有 S3/管理操作都有 Action/resource/context 映射及正负授权测试；矩阵没有被跳过的隐式直通路径。
- [ ] 用户、组、Key、角色、会话、资源策略和条件使用真实持久化数据；变更/撤销/重启都生效。
- [ ] 所有列出的权限相关 Go/Zig 单测、集成与前端验收有结果；失败和未实现项目不隐藏。
- [ ] 八个默认策略的权限含义与实际能力可逐项解释和验证。
- [ ] 数据迁移、恢复、管理员恢复入口、日志脱敏、并发语义与错误处理完成。
- [ ] 前端可完成相应数据管理，展示与后端权限一致；Go BFF 和管理 API 均无法绕权。
- [ ] 用户得到一份已实现/剩余差异/验证证据清单，才可判断是否达到“完整权限”；不能仅以本计划写完或 CRUD 可用作为完成。
