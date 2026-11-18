# Metadata Engine 接入记录

日期：2026-11-18。ZigFS 的 `MetadataRepository` 已统一使用 `pkg/metadata-engine`。
本次是开发阶段空库切换，不提供旧数据、旧目录结构或旧元数据格式兼容。

## 系统元数据接入

原 MetadataRepository 的五类业务 Store 和以下系统文档均使用同一个 EngineRepository / Runtime。
系统文档通过 `SystemStore` 路由到 13 个独立业务命名空间，实际文件集中在 `data/.zigfs.sys/`。
表中名称是数据库键，不是独立文件路径。

| 数据 | namespace | 记录键 | 内容保护 |
| --- | --- | --- | --- |
| 身份、用户组 | `identity` | `system/identities.json` | 原子集合替换 |
| IAM 策略 | `policy` | `system/policies.json` | 空集合重启后不恢复默认策略 |
| 角色、会话 | `role` | `system/roles.json` | 原子集合替换 |
| 桶策略 | `bucket_policy` | `system/bucket-policies/<bucket-id>.json` | 桶 UUID 隔离 |
| 对象标签 | `object_tag` | `system/object-tags/<digest>.json` | 按桶、对象、版本隔离；GC 清理不可达记录 |
| OIDC 提供者与会话 | `oidc` | `system/oidc-providers.enc` | AES-GCM 加密 |
| 实例、认证、网络、监听、Region、显示配置 | `settings` | `config/*.json` | 保留原有生效时机与校验 |
| 监控告警规则 | `monitoring_settings` | `config/monitoring-rules.json` | 原子替换 |
| 系统日志配置 | `log_settings` | `config/log_config.json` | 配置与正文分离 |
| 审计配置 | `audit_settings` | `config/audit_log_config.json` | 配置与正文分离 |
| 桶事件订阅 | `bucket_subscription` | `config/bucket-subscriptions/<bucket-id>.json` | 桶 UUID 隔离 |
| 事件目标配置 | `event_destination` | `config/event-destinations.enc` | AES-GCM 加密 |
| KMS 配置、历史后端及远端密钥管理信息 | `kms` | `config/kms.enc` | AES-GCM 加密；历史配置随记录保留 |

每个 namespace 有独立的内存索引，仍共享 WAL、快照和事务提交队列，没有拆成多个物理数据库。
加上原有五类核心元数据与保留的 `system`，共 19 个 namespace；ZigFS 不再向 `system` 写入业务文档。
键中的 `system/` 只是原有键名，不表示所属 namespace；保留键名也保持加密关联数据不变。
未知文档键返回 `InvalidKey`，不回退到 `system`。对象标签校验与清理只扫描 `object_tag`。

停机后可以按业务查看记录数（包含尚未回收的 tombstone）：

```sh
pkg/metadata-engine/zig-out/bin/metadata-tool namespaces data/.zigfs.sys
```

该命令只读打开引擎，但仍需取得独占锁，不能与正在运行的 ZigFS 同时打开同一目录。
旧数据根 v1/v2 明确拒绝打开；开发数据需清空后重建，无自动迁移或旧 system 分区回退。

不再读写上述旧 sidecar，不提供旧配置文件导入或回退。KMS 专用 `xl.meta` 容器和旧配置
读取路径已删除。业务修改仍由原 policy/object/KMS/logging 锁串行化，引擎负责 durable commit；
SystemStore 的完整文档替换不依赖 missing 世代，物理 tombstone 回收不会导致失效的创建条件。
身份、角色、策略仍按集合存储，本轮没有改为逐用户/逐角色记录或跨业务事务。

### 监控存储选择

- 实时采样、计数器及查询用的环形历史缓冲保存在内存；不随每次更新写 WAL 或文件。
- 历史继续使用 `.zigfs/monitoring/history-v1.json`，每 60 秒批量原子保存，最多 8,640 点、
  16 MiB，恢复和查询保留最近 24 小时。崩溃可能丢失尚未保存的约一分钟采样；保存失败会
  显示持久化异常，实时采样继续工作。
- 当前查询主要读取内存中的有限时间窗口，独立快照文件足够，不引入第二个 KV。将来需要
  更长保留期、更多维度或磁盘范围查询时，再评估分段时间序列文件或独立 KV。

在线引擎备份现在包含上述系统文档；仍不包含对象正文、密钥文件、日志正文、事件投递队列
和监控历史。完整恢复仍需完整数据根备份，不能删除整个 `.zigfs/` 目录。

## 实现结果

- 引擎目录直接为 `ZIGFS_DATA_ROOT/.zigfs.sys/`，默认 `data/.zigfs.sys/`。
  内含 WAL、快照和 LOCK，不再嵌套 metadata 子目录。
- `EngineRepository` 适配现有业务端口，统一使用引擎的记录/命名空间类型，保留业务错误映射。
  Application 在稳定地址启动 Runtime，关闭时排空并停止 Runtime，再释放引擎和目录。
- 删除旧逐条 `.record` 仓库、Intent/Commit/Abort journal、generation 文件、旧检查点、
  旧恢复器、旧扫描游标及其专用端口。业务 payload 编码、对象内容、业务查询索引及引用 GC 保留。
- 启动先恢复引擎，再重建业务索引；既有实例丢失引擎目录或 WAL 不会初始化成成功的空库。
  运行中不确定引擎写入使应用 Not Ready；恢复失败时健康端点仍可用于诊断。
- 物理 tombstone 回收和业务 read/CAS 共用状态锁；适配器在此约束下将业务 missing 映射到
  当前 missing_at 世代。普通 checkpoint 由 Runtime 调度，物理回收默认每 60 秒执行一次。
  旧目录扫描批量配置已删除。回收是阻塞式维护，不是有耗时上限的增量 GC。
- `Application.backupMetadata` 提供应用内在线元数据备份；完整 ZigFS 备份还须包含对象、
  分片、密钥、监控历史、日志及投递队列。没有新增对外 HTTP 备份接口。
- 数据根格式主版本为 3，引擎文件格式为 v3；旧格式明确拒绝，不自动迁移或重置。
- Docker 构建上下文改为仓库根，Dockerfile、docker.sh 和发布工作流包含本地 pkg 依赖；
  Dockerfile 专用 ignore 文件排除本地数据、缓存、凭证和压测结果。

此前接入阶段已确认 `zigfs/data` 是未被实例锁占用的旧格式开发数据根，按用户授权清空全部内容，
当时保留空目录。没有迁移旧身份、桶、对象或密钥。本轮 namespace 细分未再次清理用户数据。

## 验证结果

本轮分区调整重新执行引擎 73 项单测、SIGKILL 崩溃测试和 19 namespace 混合模型测试，
以及 ZigFS Debug/ReleaseSafe 333 项测试、恢复与回收进程测试。下表其他接口回归为此前接入阶段结果。

环境：macOS ARM64，Zig 0.17.0。每个实际执行的用例均少于十分钟。

| 验证 | 结果 |
| --- | --- |
| `cd zigfs && zig build test --summary all` | 333/333 通过 |
| `cd zigfs && zig build test install -Doptimize=ReleaseSafe --summary all` | 333/333 通过，发布模式二进制构建成功 |
| 新应用层测试 | 系统配置/身份/标签/OIDC 重启恢复、空策略集合保留、在线备份逐记录一致性、回收后重建、故障后 Not Ready、丢失数据库拒绝重置通过 |
| `python3 conformance/metadata_maintenance.py --tasks 1000 --all-types --timeout 120` | 19 个命名空间 1,000 个 tombstone 回收，重启通过 |
| `python3 conformance/metadata_engine_recovery.py` | 目录丢失、WAL 损坏返回 Ready 503 / Live 200；旧根格式拒绝；没有重置元数据 |
| `python conformance/multipart_segments.py --mib 10 --part-mib 5 --check-resume`（需要 boto3） | 明文/加密上传、重启续传、幂等完成、Range、校验和、复制、删除与非法元数据拒绝通过 |
| 系统配置/权限进程回归 | assume_role_login、user_access_keys、event_destinations、oidc_providers、log_configuration、listener_settings、console_session_objects 通过 |
| KMS 进程回归 | sse_kms：local/static/Vault KV2/Transit、历史后端配置、重启、轮转/删除、TLS、权限与加密配置通过 |
| 监控进程回归 | monitoring_runtime --persistence：实时遥测、定时保存、重启连续性、计数器重置、历史损坏恢复通过 |
| 格式与静态检查 | 修改的 Zig 文件通过 zig fmt；Python、shell 语法与 diff 空白检查通过 |

本轮维护用例覆盖 19 个 namespace 的 1,000 条 tombstone；回收前后均为三个文件。
逻辑字节总量从 130,160 B 降至 4,137 B，重启后为 4,367 B；回收后与重启后分配块均为
8,192 B。系统初始化和维护允许持久化有效配置，因此测试验证 GC epoch 和已回收键不再出现，
不再要求重启前后字节数完全相等。这是回收验证，不是业务吞吐基准。
离线 `namespaces` 命令另在临时库验证：19 个分区各 3 条记录，检查前后文件内容完全不变。

测试日志中的两条 multipart cleanup 警告来自预期故障注入，最终构建退出码为零且全部测试通过。
本轮没有运行完整 Linux Docker 镜像构建或 NAS/真实断电验证；这些环境结论不由本机测试替代。
没有改动 Admin 界面或对外 API 合约；业务仍通过 BFF/S3/Management 接口访问 ZigFS。

测试数量变化：移除了旧 KMS 配置格式的兼容测试及已删除 codec 的测试，新增系统元数据
重启与备份集成测试。无旧配置迁移或读取回退。

详细运行和恢复要求见 [备份与恢复](backup-and-recovery.md)，独立引擎语义见
[库说明](../pkg/metadata-engine/README.md)。
