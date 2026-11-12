# ZigFS CLI（`zc`）设计参考：基于 RustFS `rc`

> 状态：设计输入文档 / 初始兼容参考  
> 命令前缀暂定：`zc`  
> 参考来源：RustFS CLI（`rc`）官方 README 与命令参考。  
> 注意：以下是以 RustFS `rc` 的当前公开命令目录为基线整理的设计清单，不意味着 ZigFS 应一比一实现其所有 RustFS 专有 Admin API。参数可能随上游版本变化；实现时应将本文件与所引用的官方页面核对。

## 1. 设计约定

### 1.1 命令路径

远端资源使用：

```text
ALIAS/BUCKET/KEY
ALIAS/BUCKET
ALIAS/
```

- `ALIAS`：由 `zc alias set` 配置的端点和凭据名称。
- `BUCKET`：Bucket 名。
- `KEY`：对象 Key，可包含 `/`。
- `PATH`：远端 bucket/object/prefix 或本地路径，具体由命令解释。

### 1.2 全局参数（建议 `zc` 统一）

| 参数 | 含义 |
|---|---|
| `-h, --help` | 显示帮助 |
| `-V, --version` | 显示 CLI 版本 |
| `--format auto\|human\|json` | 输出格式 |
| `--json` | JSON 输出（适用命令） |
| `--no-color` | 禁用终端颜色 |
| `--no-progress` | 禁用进度条 |
| `-q, --quiet` | 仅输出错误或关键结果 |
| `--debug` | 调试日志 |
| `-H, --header NAME:VALUE` | 附加请求头（S3 请求场景） |

建议：全局选项应放在命令之前或之后都能解析；输出 JSON 时 stdout 只输出机器可读数据，诊断日志写 stderr。

---

## 2. RustFS `rc` 的 30 个顶级命令

下列 30 项来自 RustFS CLI README 的 Command Overview（传统顶级命令形式）。RustFS 新版文档也提供 `bucket` / `object` 等 noun-first 分组；ZigFS 可考虑把分组形式作为主设计，保留传统短命令作为别名。

### 01. `zc alias` — 管理连接别名

```text
zc alias set <ALIAS> <ENDPOINT> <ACCESS_KEY> <SECRET_KEY> [OPTIONS]
zc alias list
zc alias remove <ALIAS>
zc alias info <ALIAS>
```

参数：
- `<ALIAS>`：别名名称。
- `<ENDPOINT>`：S3 endpoint URL，例如 `http://127.0.0.1:9000`。
- `<ACCESS_KEY>` / `<SECRET_KEY>`：访问凭据。
- 可扩展选项：`--region REGION`、`--path-style`、`--secure`、`--session-token TOKEN`、`--profile NAME`。
- 官方 README 明确示例为 `alias set`、`alias list`；`remove/info` 是建议的 ZigFS 配套管理操作，标注为设计扩展。

### 02. `zc admin` — RustFS/ZigFS 管理操作（厂商专有）

`admin` 下的子命令较多，详见第 3 节。它不是通用 S3 API；ZigFS 应只实现自身服务的管理 API。

### 03. `zc ls` — 列 Bucket / 对象

```text
zc ls [OPTIONS] <ALIAS[/BUCKET[/PREFIX]]>
```

参数/选项：
- `<PATH>`：别名、bucket 或 prefix 路径。
- `--recursive, -r`：递归列出。
- `--versions`：显示对象版本（支持时）。
- `--summarize`：仅显示汇总。
- `--json`：结构化输出。

### 04. `zc mb` — 创建 Bucket

```text
zc mb [OPTIONS] <ALIAS/BUCKET>
```

选项：
- `--ignore-existing`：Bucket 已存在时不报错。
- `--region REGION`：指定 Bucket region/location constraint。
- `--with-versioning`：创建后启用版本控制。
- `--with-lock`：创建时启用 Object Lock（隐含版本控制）。

### 05. `zc rb` — 删除 Bucket

```text
zc rb [OPTIONS] <ALIAS/BUCKET>
```

选项：
- `--force`：执行强制清理/删除流程。
- `--dangerous`：允许清理已发现的 multipart uploads（高风险能力）。
- `--yes`：确认危险操作。
- 设计要求：默认拒绝非空 Bucket 删除；危险选项应有明确确认和提示。

### 06. `zc cp` — 复制/上传/下载对象

```text
zc cp [OPTIONS] <SOURCE> <TARGET>
```

参数：
- `<SOURCE>`：本地文件、目录或远端 `ALIAS/BUCKET/KEY`。
- `<TARGET>`：本地目标或远端 `ALIAS/BUCKET[/PREFIX]`。
- `-r, --recursive`：递归复制目录/prefix。
- `--dry-run`：显示计划，不执行（支持时）。
- `--no-progress`：禁用进度显示。
- 加密相关参数可按实现加入 `--enc-*`（RustFS 文档将加密工作流关联到 bucket encryption、cp/mv/pipe 参数）。

### 07. `zc mv` — 移动对象

```text
zc mv [OPTIONS] <SOURCE> <TARGET>
```

参数与 `cp` 类似；远端对象移动通常是 copy + delete。
- `-r, --recursive`
- `--dry-run`
- `--enc-*`（服务端支持时）

### 08. `zc rm` — 删除对象

```text
zc rm [OPTIONS] <PATH>...
```

选项：
- `-r, --recursive`：删除 prefix 下对象。
- `--versions`：针对对象版本操作（若支持）。
- `--force`：跳过部分确认（仍需防止误删）。
- `--dry-run`：预览删除计划（若支持）。

### 09. `zc cat` — 输出对象内容

```text
zc cat <ALIAS/BUCKET/KEY> [OPTIONS]
```

参数/选项：
- 对象路径。
- `--offset N` / `--length N`：建议扩展，用于 Range 读取。
- `--version-id ID`：指定版本（服务端支持时）。

### 10. `zc head` — 输出对象开头内容

```text
zc head [OPTIONS] <ALIAS/BUCKET/KEY>
```

选项：
- `--lines N`：读取前 N 行。
- `--bytes N`：读取前 N 字节。
- `--version-id ID`：对象版本（可选）。

### 11. `zc stat` — 查看对象元数据

```text
zc stat [OPTIONS] <ALIAS/BUCKET/KEY>
```

参数：
- 对象路径。
- `--version-id ID`：指定对象版本。
- 输出通常包含 size、ETag、Last-Modified、Content-Type、metadata 等（以服务端响应为准）。

### 12. `zc find` — 搜索对象

```text
zc find [OPTIONS] <ALIAS/BUCKET[/PREFIX]>
```

RustFS README 示例参数：
- `--name GLOB`：按名称模式筛选。
- `--newer DURATION`：按更新时间筛选。
- 建议支持 `--older DURATION`、`--regex`、`--max-depth N` 作为 ZigFS 扩展，需明确标记非上游兼容。

### 13. `zc anonymous` — 管理匿名访问规则

```text
zc anonymous <COMMAND> <ALIAS/BUCKET[/PREFIX]>
```

子命令：
- `list <PATH>`：列出匿名访问规则。
- `set <ACCESS> <PATH>`：设置访问级别（README 示例 `public`）。
- RustFS README 示例：`anonymous list`、`anonymous set public`。
- 可扩展 JSON 规则入口 `set-json/get-json`，需要与 ZigFS policy 结构明确对应。

### 14. `zc diff` — 比较两个位置

```text
zc diff [OPTIONS] <SOURCE> <TARGET>
```

参数：
- `<SOURCE>`、`<TARGET>`：本地路径或远端路径。
- 建议选项：`--recursive`、`--json`、`--size-only`、`--ignore-times`（按实际实现定义）。

### 15. `zc mirror` — 镜像同步

```text
zc mirror [OPTIONS] <SOURCE> <TARGET>
```

参数：
- 源、目标可为本地目录或 S3 prefix。
- 建议选项：`--watch`、`--remove`（目标删除源端不存在对象）、`--dry-run`、`--overwrite`、`--exclude GLOB`、`--include GLOB`。
- 重要：`--remove` 属于破坏性参数，应默认关闭并支持 dry-run。

### 16. `zc tree` — 树状列出对象

```text
zc tree [OPTIONS] <ALIAS/BUCKET[/PREFIX]>
```

参数/选项：
- `-L, --level N`：限制深度（RustFS README 示例 `-L 3`）。
- `--versions`：版本化视图（若支持）。
- `--json`：树状结构输出。

### 17. `zc share` — 生成预签名 URL

```text
zc share [OPTIONS] <ALIAS/BUCKET/KEY>
```

参数/选项：
- `--expire DURATION`：URL 有效期（RustFS README 示例 `24h`）。
- `--method GET|PUT`：建议扩展，服务端签名能力支持时。
- `--version-id ID`：指定版本（建议扩展）。

### 18. `zc event` — Bucket 事件通知

```text
zc event <COMMAND> <ALIAS/BUCKET>
```

子命令（RustFS 文档形式）：
- `add <BUCKET> [OPTIONS]`：添加事件通知配置。
- `list <BUCKET>`：列出通知配置。
- `remove <BUCKET> [OPTIONS]`：移除配置。
- 参数按通知配置定义：事件类型、目标 ARN/endpoint、ID、过滤前缀/后缀等。

### 19. `zc cors` — Bucket CORS

```text
zc cors <COMMAND> <ALIAS/BUCKET>
```

子命令：
- `list <BUCKET>`
- `set <BUCKET> <FILE>`：从 XML/JSON 配置文件设置（RustFS bucket 文档示例）。
- `remove <BUCKET>`
- 配置字段遵循 CORS Rule：AllowedOrigins、AllowedMethods、AllowedHeaders、ExposeHeaders、MaxAgeSeconds。

### 20. `zc pipe` — 从 stdin 上传

```text
zc pipe [OPTIONS] <ALIAS/BUCKET/KEY>
```

参数/选项：
- stdin 作为对象内容。
- `--content-type TYPE`
- `--metadata KEY=VALUE`（可重复）
- `--enc-*`（加密场景，服务端支持时）。
- 可选 `--size N`（流式/分段实现所需时）。

### 21. `zc version` — Bucket 版本控制与对象版本

```text
zc version <COMMAND> <ALIAS/BUCKET[/KEY]>
```

子命令：
- `enable <BUCKET>`：开启版本控制。
- `suspend <BUCKET>`：暂停版本控制。
- `info <BUCKET>`：查看版本控制状态。
- `list <OBJECT>`：列出对象版本（RustFS bucket reference 包含 list）。
- 可按对象版本进一步支持 `--version-id`。

### 22. `zc tag` — Bucket / Object 标签

```text
zc tag <COMMAND> <ALIAS/BUCKET[/KEY]>
```

建议/通用 S3 语义子命令：
- `list <PATH>`：列标签。
- `set <PATH> --tag KEY=VALUE...`：设置标签。
- `remove <PATH> --key KEY...`：删除指定标签。
- `clear <PATH>`：清空标签。
- 标签数量、字符集和大小约束以 S3 服务实现为准。

### 23. `zc quota` — Bucket 配额

```text
zc quota <COMMAND> <ALIAS/BUCKET>
```

子命令：
- `set <BUCKET> --size SIZE`：设置容量配额。
- `info <BUCKET>`：查看配额。
- `clear <BUCKET>`：清除配额。
- 注意：quota 不是所有 S3 兼容服务都支持；应通过 capability 探测或返回清晰的 NotSupported。

### 24. `zc ilm` — 生命周期规则 / Storage Tier / Restore

```text
zc ilm <SUBCOMMAND> ...
```

子命令（RustFS README overview）：

**rule**
- `rule add <BUCKET> <FILE|OPTIONS>`
- `rule edit <BUCKET> <RULE-ID> <FILE|OPTIONS>`
- `rule list <BUCKET>`
- `rule remove <BUCKET> [--id ID|--all]`
- `rule export <BUCKET> [FILE]`
- `rule import <BUCKET> <FILE>`

**tier**
- `tier add <ALIAS> [OPTIONS]`
- `tier edit <ALIAS> <TIER-NAME> [OPTIONS]`
- `tier list <ALIAS>`
- `tier info <ALIAS> <TIER-NAME>`
- `tier remove <ALIAS> <TIER-NAME>`

**restore**
- `restore <ALIAS/BUCKET/KEY> --days N [OPTIONS]`

生命周期规则参数由 S3 Lifecycle schema 定义，常见字段包括 ID、Filter/Prefix、Status、Expiration、Transition、NoncurrentVersionExpiration、AbortIncompleteMultipartUpload。具体 flag/JSON 格式应以 ZigFS schema 文档定义。

### 25. `zc replicate` — Bucket 复制规则

```text
zc replicate <COMMAND> <ALIAS/BUCKET> [OPTIONS]
```

子命令：
- `add`：添加规则。
- `update`：更新规则。
- `list`：列规则。
- `status`：查看状态/指标。
- `diff`：查看复制差异。
- `remove`：删除规则（可用 `--id ID` / `--all`）。
- `export`：导出 JSON。
- `import <FILE>`：导入 JSON。
- `check`：检查配置。
- `resync`：重新同步（RustFS bucket reference 列出该操作）。
常见参数：`--remote-bucket ALIAS/BUCKET`、`--priority N`、`--replicate delete,delete-marker,existing-objects`、`--insecure`、`--ca-cert FILE`。

### 26. `zc watch` — 实时对象事件

```text
zc watch [OPTIONS] <ALIAS/BUCKET[/PREFIX]>
```

参数：
- bucket/prefix。
- `--events EVENT,...`：筛选事件类型（建议）。
- `--prefix PREFIX` / `--suffix SUFFIX`：筛选 key（建议）。
- `--json`：JSON Lines 输出。
- 应以服务端支持的事件流协议为准，不等同于 S3 Bucket Notification 配置。

### 27. `zc completions` — Shell 自动补全

```text
zc completions <SHELL>
```

参数：
- `<SHELL>`：`bash`、`zsh`、`fish`、`powershell`、`elvish`（具体支持列表由 CLI 框架决定）。
- 输出补全脚本至 stdout，安装由用户完成。

### 28. `zc ping` — 服务存活检查

```text
zc ping <ALIAS> [--timeout SECONDS]
```

参数：
- `<ALIAS>`：目标服务别名。
- `--timeout SECONDS`：超时秒数；RustFS ops reference 默认 5 秒，允许 1–300 秒。

### 29. `zc ready` — 服务依赖就绪检查

```text
zc ready <ALIAS> [--timeout SECONDS]
```

参数同 `ping`。检查 readiness endpoint；建议定义可机器判断的退出码。

### 30. `zc du` — 存储用量统计

```text
zc du <ALIAS[/BUCKET[/PREFIX]]> [OPTIONS]
```

参数/选项：
- `<PATH>`：服务、bucket 或 prefix。
- `--fallback`：允许在服务端快照不可用时执行客户端分页扫描（RustFS 文档中特别要求显式授权）。
- `--versions`：统计版本对象（支持时）。
- `--incomplete`：纳入未完成 multipart upload（README 示例中出现）。
- JSON 输出应说明数据来源和快照时间；全桶扫描可能昂贵。

---

## 3. `zc admin` 子命令设计清单

RustFS `rc admin` 是 RustFS Admin API 客户端，并非 S3 API。下面的命令家族按 RustFS 官方 admin reference 归纳。ZigFS 应根据自身 admin API 的实际能力决定实现范围。

### 3.1 Account / MFA

```text
zc admin account info <ALIAS>
zc admin account passwd <ALIAS> [--current-password-from-env NAME|--current-password-file PATH] [--new-password-from-env NAME|--new-password-file PATH]
zc admin account mfa status <ALIAS>
zc admin account mfa enroll <ALIAS> [--no-qr]
zc admin account mfa activate <ALIAS> [--code CODE|--code-from-env NAME] [--output-file PATH]
zc admin account mfa disable <ALIAS> [--code CODE|--code-from-env NAME] [--password-from-env NAME|--password-file PATH]
zc admin account mfa recovery-codes <ALIAS> [--code CODE|--code-from-env NAME] [--output-file PATH]
```

### 3.2 Diagnostics / Info / Scanner / Metrics

```text
zc admin diagnostics <health|cluster|extensions> <ALIAS>
zc admin diagnostics client-devnull <ALIAS> [--size SIZE] [--timeout DURATION] [--concurrency N] --yes
zc admin info <cluster|server|disk|storage> <ALIAS> [OPTIONS]
zc admin scanner status <ALIAS>
zc admin metrics <ALIAS> [OPTIONS]
```

### 3.3 Identity Provider（OpenID）

```text
zc admin idp openid list <ALIAS>
zc admin idp openid get <ALIAS> <PROVIDER_ID>
zc admin idp openid validate <ALIAS> <PROVIDER_ID> --config-url URL --client-id ID
zc admin idp openid set <ALIAS> <PROVIDER_ID> [OPTIONS]
zc admin idp openid update <ALIAS> <PROVIDER_ID> [OPTIONS]
zc admin idp openid enable <ALIAS> <PROVIDER_ID> [--dry-run]
zc admin idp openid disable <ALIAS> <PROVIDER_ID> [--dry-run]
```

### 3.4 KMS

```text
zc admin kms status <ALIAS>
zc admin kms configure <ALIAS> (--config-file PATH|--stdin)
zc admin kms reconfigure <ALIAS> (--config-file PATH|--stdin)
zc admin kms start <ALIAS>
zc admin kms restart <ALIAS> --yes
zc admin kms stop <ALIAS> --yes
zc admin kms roundtrip <ALIAS> <BUCKET> [--key-id KEY_ID] --yes
zc admin kms key list <ALIAS> [--limit N] [--marker TOKEN]
zc admin kms key status <ALIAS> [KEY_ID]
zc admin kms key create <ALIAS> [--name NAME] [--description TEXT] [--tag KEY=VALUE]...
zc admin kms key delete <ALIAS> <KEY_ID> [--pending-window-days 7..30] --yes
zc admin kms key delete <ALIAS> <KEY_ID> --immediate --yes --confirm-immediate
zc admin kms key cancel-deletion <ALIAS> <KEY_ID>
```

### 3.5 Cluster heal / pool / expand / decommission / rebalance

```text
zc admin heal <status|start|stop> <ALIAS> [OPTIONS]
zc admin pool <list|status> <ALIAS> [POOL] [OPTIONS]
zc admin expand <start|status|stop> <ALIAS>
zc admin decommission <start|cancel|clear> <ALIAS> <POOL> [OPTIONS]
zc admin decommission status <ALIAS> [POOL] [OPTIONS]
zc admin rebalance <start|status|stop> <ALIAS>
```

### 3.6 IAM User / Policy / Group / Service Account / Access Key

```text
zc admin user <ls|add|info|rm|enable|disable> ...
zc admin user passwd <ALIAS> <ACCESS_KEY> [--password-from-env NAME|--password-file PATH]
zc admin user mfa status <ALIAS> <ACCESS_KEY>
zc admin user mfa reset <ALIAS> <ACCESS_KEY> [--yes]

zc admin policy <ls|create|info|rm|attach|detach|entities> ...
zc admin policy detach <ALIAS> <POLICY>... (--user USER|--group GROUP)
zc admin policy entities <ALIAS> [--user USER]... [--group GROUP]... [--policy POLICY]...

zc admin access-key info <ALIAS> <ACCESS_KEY>
zc admin access-key ls <ALIAS> [--provider builtin|ldap|openid]... [--user USER]... [--all] [OPTIONS]

zc admin group <ls|add|info|rm|enable|disable|add-members|rm-members> ...
zc admin service-account <ls|create|info|rm> ...
```

### 3.7 Service / Config / Bucket Metadata / Migration / Site Replication

```text
zc admin service <restart|stop|freeze|unfreeze> <ALIAS>

zc admin config <get|set|delete|help|history|restore|export|import> ...
zc admin config module-switch <get|set> ...

zc admin bucket-metadata <export|import> <ALIAS> ...

zc admin bucket migration set <ALIAS>/<BUCKET> --provider <s3|aws|minio|rustfs|r2|gcs> [--endpoint URL] --region R --source-bucket B [OPTIONS] [--dry-run]
zc admin bucket migration <get|rm|status> <ALIAS>/<BUCKET> [--watch [--interval SECONDS]]
zc admin bucket migration backfill start <ALIAS>/<BUCKET> [--prefix P] [--skip-existing always|etag_or_size] [--dry-run]
zc admin bucket migration backfill <cancel|status> <ALIAS>/<BUCKET> [--watch [--interval SECONDS]]

zc admin replicate add <ALIAS> <ALIAS> [<ALIAS>...]
zc admin replicate <info|status> <ALIAS> [OPTIONS]
zc admin replicate edit <ALIAS> --site <DEPLOYMENT_ID|NAME> [EDIT OPTIONS] --yes
zc admin replicate resync <start|cancel> <ALIAS> --site <DEPLOYMENT_ID|NAME> --yes
zc admin replicate resync status <ALIAS> --site <DEPLOYMENT_ID|NAME>
zc admin replicate remove <ALIAS> (--all|--site NAME)
```

---

## 4. ZigFS 实现优先级建议

### P0 — CLI 框架与基本 S3 工作流
- `alias`, `ls`, `mb`, `rb`, `cp`, `mv`, `rm`, `stat`, `cat`, `head`
- 统一 endpoint、region、path-style / virtual-host-style、签名版本、凭据解析。
- 基础输出模式 human/json、退出码、错误映射。

### P1 — Bucket 配置 / 对象辅助
- `share`, `version`, `tag`, `cors`, `event`, `anonymous`, `find`, `tree`, `pipe`
- Bucket/Object configuration APIs 应按功能 capability 明确支持矩阵。

### P2 — 运维辅助
- `ping`, `ready`, `du`, `watch`, `diff`, `mirror`, `completions`
- mirror/diff 需要谨慎处理删除、覆盖、并发和断点恢复。

### P3 — ZigFS 专属管理 CLI
- `admin user/policy/group/service-account/access-key`
- `admin config`, `admin kms`, `admin heal`, `admin info`, `admin service`
- 不照搬 RustFS 的子命令名或 API 语义，基于 ZigFS admin API 实际定义。

## 5. 文档与实现时的注意点

1. **30 个顶级命令是 RustFS CLI README 的 command overview 数量**，并非 30 个纯 S3 API；其中 `admin`、`ping`、`ready`、`du`、`completions` 等属于管理/运维/本地 CLI 功能。
2. RustFS 新文档推荐 `rc bucket` 与 `rc object` 这类 noun-first 入口；其旧式命令如 `rc mb`、`rc cp` 是 legacy-compatible forms。ZigFS 可以设计 `zc bucket create` / `zc object copy` 为规范命令，并用 `zc mb` / `zc cp` 作为 alias。
3. 对于每个参数，应在 ZigFS 实现中区分：CLI parser 参数、S3 HTTP query/header、JSON/XML request body、ZigFS Admin API 参数。
4. 不支持的 S3 API 应返回可解释错误（例如 `NotImplemented`），不要伪装成功。
5. 所有危险操作（删 bucket、mirror 删除目标、KMS 立即删 key、服务停止等）应具备 `--dry-run` 或明确确认机制。
6. 文档中的某些 options 是 RustFS 当前 CLI 的实际 options，另一些已明确标注为 ZigFS 设计建议/扩展，编码时勿将二者误认成上游完整原样。

## 6. 官方参考链接

- RustFS CLI 项目 README（命令概览、示例、admin 子命令摘要）  
  https://github.com/rustfs/cli/blob/main/README.md
- RustFS CLI Reference（推荐 noun-first groups、global options、path format）  
  https://github.com/rustfs/cli/blob/main/docs/reference/rc/README.md
- RustFS Bucket Reference（bucket 子命令与选项）  
  https://github.com/rustfs/cli/blob/main/docs/reference/rc/bucket.md
- RustFS Object Reference（object 子命令与通用参数）  
  https://github.com/rustfs/cli/blob/main/docs/reference/rc/object.md
- RustFS Admin Reference（admin syntax 与子命令参数）  
  https://github.com/rustfs/cli/blob/main/docs/reference/rc/admin.md
- RustFS Operational Utilities Reference（ping / ready / du）  
  https://github.com/rustfs/cli/blob/main/docs/reference/rc/ops.md
- RustFS CLI 官方安装与 quick start  
  https://docs.rustfs.com/en/operations/rc
