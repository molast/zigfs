# ZigFS CLI（`zc`）设计参考：基于 RustFS `rc`

> 状态：设计输入文档 / 命令覆盖与行为约定（非已实现功能说明）  
> 核对日期：2026-11-16；上游基线：RustFS CLI `main` 的 README 与命令参考（可变分支，非固定 Release）  
> 命令前缀暂定：`zc`  
> 参考来源：RustFS CLI（`rc`）官方参考 + AWS S3 API / botocore 操作模型；单机 S3 覆盖见第 2.2 节。
> 注意：以下是以 RustFS `rc` 的当前公开命令目录为基线整理的设计清单，不意味着 ZigFS 应一比一实现其所有 RustFS 专有 Admin API。参数可能随上游版本变化；实现时应将本文件与所引用的官方页面核对。

## 0. 范围、来源与实现状态

- **本次范围**：补齐单机 S3 指令设计；多机/复制拓扑明确排除，云专属协议单列可选适配。第 2.2 节的范围裁定优先于旧参考段落和旧版服务端支持表。
- **上游参考**：第 2、3 节以 RustFS 已公开文档为参考，将命令前缀改写为 `zc`，不代表 ZigFS 已实现，也不承诺与上游逐参数兼容。
- **ZigFS 建议**：第 1 节、第 2.1.5 节、第 2.2 节和第 3.9 节提出本项目的设计约定或扩展；其他段落中的建议亦明确标注，尚需实现与验证。
- **当前 CLI**：步骤 01–03 已完成：全局参数、帮助/版本、bucket/object 注册框架、传统别名、JSON 与退出码。程序版本使用 `zc --version` / `-V`；`zc version` 已保留为 Bucket 版本管理别名，目前执行返回 7。alias set/list/info/remove/export/import 与本地连接配置已可用；HTTP/SigV4 与首批 8 个 s3api 操作子集已接入；高层 S3 命令和管理操作仍待实现；支持清单见 [CLI README](../zigfs-cli/README.md)。
- **服务端能力**：标准 S3、ZigFS Management 和 RustFS Admin 是不同协议。CLI 不得把其中一个协议的能力当作另一个协议的支持证明，不得直接访问 ZigFS 数据目录。
- 本文补齐命令家族、重要参数和执行约定，不复制上游全部帮助文本。上游页面之间也可能存在滞后，例如 `object.md` 仍描述单源复制，`cp.md` 已列出多源复制；有差异时记录差异，实施前核对对应版本的 parser 和测试。
- 旧版 [S3 覆盖表](api/s3-api-coverage.md) 与近期功能文档可能不同步。支持状态应联合核对当前代码、[Management 契约](api/zigfs-management-v1.openapi.yaml)及专项文档，不能仅凭旧表判定未实现。

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
| `-H, --header NAME:VALUE` | 上游限定为参与签名的 `x-amz-*` 请求头；禁止覆盖客户端管理的认证/Host 等头 |

建议：全局选项应放在命令之前或之后都能解析；输出 JSON 时 stdout 只输出机器可读数据，诊断日志写 stderr。

### 1.3 配置、凭据与连接（ZigFS 建议）

- 配置路径：`--config FILE` > `ZC_CONFIG_FILE` > `$XDG_CONFIG_HOME/zc/config.toml`，未设置 XDG 时使用 `~/.config/zc/config.toml`。配置带 `schema_version`；写入采用原子替换，Unix 凭据文件权限为 `0600`。
- 连接参数优先级：显式命令参数 > `ZC_*` 环境变量 > 选中 alias > 默认值。凭据按整组解析，AK/SK/Session Token 不得从不同来源拼接；缺项应报错。
- 建议环境变量：`ZC_ACCESS_KEY_ID`、`ZC_SECRET_ACCESS_KEY`、`ZC_SESSION_TOKEN`、`ZC_REGION`；默认不隐式读取 AWS profile，后续支持时通过显式 `--profile NAME` 选择并定义优先级。
- 支持非回显交互、`--secret-key-from-env NAME` / `--secret-key-file FILE`；保留位置参数仅作兼容。list/info/debug 默认脱敏，导出凭据必须显式确认。
- S3 采用 SigV4；上游 alias 的 `--signature v2` 不作为 ZigFS 支持承诺。region、path-style/virtual-host-style 必须与服务端能力匹配。
- 建议连接选项：`--connect-timeout SECONDS`、`--timeout SECONDS`、`--ca-cert FILE`、`--insecure`。默认校验证书；`--insecure` 仅影响本次或明确配置的 alias，不能自动重试为不安全连接。
- Management endpoint 与 S3 endpoint 分开配置。管理认证方式必须与 Management 契约匹配，不能照搬 RustFS Admin 的 AK/SK 签名。管理 token 的存储、失效和刷新应独立定义。

### 1.4 输出与退出码（ZigFS 建议）

| 退出码 | 含义 |
|---|---|
| `0` | 成功 |
| `1` | 一般错误或批量部分失败 |
| `2` | 参数、配置或路径错误 |
| `3` | 网络错误、超时或可重试服务错误 |
| `4` | 认证失败或权限不足 |
| `5` | 资源不存在 |
| `6` | 冲突、前置条件失败 |
| `7` | 功能不支持 |
| `130` | 用户中断 |

- `--json` 等价于 `--format json`，与显式 `--format human` 冲突时拒绝执行。quiet 不得破坏 JSON 结构。
- 普通命令输出一个版本化 JSON 文档；watch/metrics 等流式命令使用 JSON Lines，并逐条带版本和类型。建议字段包括 `schema_version`、`type`、`status`、`data`；错误包含稳定 `code`、脱敏 `message`、可用时的 `request_id`。
- stdout 输出结果，stderr 输出错误及诊断；JSON 模式下错误也应结构化。分页未完成、扫描截断、批量部分失败必须显式报告，不能以空列表或退出码 0 伪装完整成功。
- `cat`、`head`、下载到 stdout、SQL 查询结果和补全脚本属于原始内容输出，不套 JSON 信封；不支持的 `--json` 组合应拒绝，不得把正文与 JSON 混合。
- `--help` 不发网络请求；子命令帮助必须描述参数互斥、默认值、单位、示例和权限。未知选项不得忽略。

### 1.5 路径、分页与危险操作（ZigFS 建议）

- 显式 `./` 或绝对路径表示本地路径；远端首段须匹配 alias。歧义路径报错，不应猜测后开始写入。`--` 终止选项解析；对象 Key 保留大小写、连续斜杠等原始语义，URL 编码只在协议边界执行。
- 目录/prefix 的尾斜杠、目标拼接和多源重名必须有确定规则；执行前检查同源同目标、目标位于源内和键映射冲突。
- 下载拒绝绝对路径、`..` 越界、符号链接逃逸及本地路径碰撞；不要规范化远端 Key 后静默覆盖另一个对象。
- list/find/tree/du/递归传输默认消费完整分页，内存使用有界。用户限制结果数量时输出截断标记和可用的 continuation token。
- `--dry-run` 可读取和验证，但不能创建对象、multipart upload 或修改配置；不能验证的服务端条件应标为未知。
- 破坏性命令提供明确确认；JSON 模式或非 TTY 不弹交互，缺少所需 `--yes` 即报参数错误。`--force` 不绕过权限、retention 或 legal hold。
- `rb --dangerous` 必须同时具有 `--force --yes`；先列出清理范围，再有界处理版本、删除标记和未完成分片。扫描失败或并发新增对象时报告未完成，不无限循环删除。

---

## 2. RustFS README 的 30 项传统命令概览

下列 30 项来自 RustFS CLI README 的 Command Overview，不是上游全部命令数量。第 2.1 节补充推荐分组与额外入口。建议 ZigFS 采用 `bucket` / `object` 分组为规范入口，传统短命令作为别名。

### 01. `zc alias` — 管理连接别名

```text
zc alias set <ALIAS> <ENDPOINT> <ACCESS_KEY> <SECRET_KEY> [OPTIONS]
zc alias list [-l|--long]
zc alias remove <ALIAS>
zc alias export [ALIAS]... [--output FILE] [--include-credentials --acknowledge-credentials]
zc alias import <FILE> [--replace]
zc alias info <ALIAS>  # ZigFS 建议扩展
```

参数：
- `<ALIAS>`：别名名称。
- `<ENDPOINT>`：S3 endpoint URL，例如 `http://127.0.0.1:9000`。
- `<ACCESS_KEY>` / `<SECRET_KEY>`：访问凭据。
- 上游选项：`--region REGION`、`--signature v4|v2`、`--bucket-lookup auto|path|dns`、`--insecure`。ZigFS 仅计划支持 SigV4。
- `remove/export/import` 已是上游功能；`info`、安全凭据输入、`--session-token TOKEN`、显式 profile 属于本文 ZigFS 建议。
- export 默认不含凭据；明文凭据导出须同时传入两项确认参数。覆盖导出文件须显式 `--force`；import 先验证整个文件，默认拒绝同名冲突，`--replace` 才允许替换。

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
zc cp [OPTIONS] <SOURCE>... <TARGET>
```

参数：
- `<SOURCE>`：本地文件、目录或远端 `ALIAS/BUCKET/KEY`。
- `<TARGET>`：本地目标或远端 `ALIAS/BUCKET[/PREFIX]`。
- `-r, --recursive`：递归复制目录/prefix。
- `--dry-run`：显示计划，不执行（支持时）。
- `--no-progress`：禁用进度显示。
- 上游详细参考支持多源，最后一个路径为目标；多源目标必须是目录或远端 prefix。
- 上游重要选项：`--overwrite`、`--preserve`、`--content-type TYPE`、`--storage-class CLASS`、`--include GLOB`、`--exclude GLOB`、`--newer-than AGE`、`--older-than AGE`、`--rewind TIME`、`--version-id ID` / `--vid ID`。
- 执行控制：`--concurrency N`、`--rate-limit RATE`、`--retry-attempts N`、`--retry-initial-backoff-ms MS`、`--retry-max-backoff-ms MS`、`--continue-on-error`、`--fail-empty`、`--summary`、`--portable-names`。
- 上游加密参数：`--enc-s3 TARGET`、`--enc-kms TARGET=KEY_ID`，匹配目标对象或目标 prefix；具体支持范围按 encryption reference，不以通配 `--enc-*` 暗示支持 SSE-C。
- 指定源版本不能与递归、多源、本地源或 rewind 混用；目标写入产生自己的新版本。exclude 优先于 include；continue-on-error 不改变最终失败退出码。
- 上游批量复制对 JSON 存在组合限制；ZigFS 应按第 1.4 节定义自己的输出契约，不能直接宣称完全兼容。

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
- 上游还支持 `get`、`get-json`、`set-json`、`links`，不是 ZigFS 独有扩展。JSON 入口须与 ZigFS policy 结构及权限明确对应；写入前说明是替换还是合并策略。

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
- `list <BUCKET>` / `get <BUCKET>`：读取配置。
- `set <BUCKET> <FILE>`：从 XML/JSON 配置文件设置；上游也支持 `<FILE>` 为 `-` 从 stdin 读取，或 `set <BUCKET> --file FILE`。
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
- `rule add <BUCKET> [OPTIONS]`
- `rule edit <BUCKET> --id <RULE-ID> [OPTIONS]`
- `rule list <BUCKET>`
- `rule remove <BUCKET> [--id ID|--all]`
- `rule export <BUCKET>`：输出至 stdout，使用 shell 重定向保存文件。
- `rule import <BUCKET> <FILE>`

**tier（远端 tier 本次排除，仅保留上游参考）**
- `tier add <PROVIDER> <TIER-NAME> <ALIAS> [OPTIONS]`（上游示例：`rustfs WARM local`）。
- `tier list <ALIAS>`
- `tier info <TIER-NAME> <ALIAS>`
- `tier remove <TIER-NAME> <ALIAS> [--force]`
- `tier edit`：上游公开目录确认存在；具体位置参数在锁定实现版本后按 `rc ilm tier edit --help` 核对，不沿用未经验证的参数顺序。

**restore**
- `restore <ALIAS/BUCKET/KEY> --days N [OPTIONS]`

生命周期规则参数由 S3 Lifecycle schema 定义，常见字段包括 ID、Filter/Prefix、Status、Expiration、Transition、NoncurrentVersionExpiration、AbortIncompleteMultipartUpload。具体 flag/JSON 格式应以 ZigFS schema 文档定义。

### 25. `zc replicate` — Bucket 复制规则（本次排除，仅上游参考）

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

## 2.1 分组入口、遗漏命令与传输工作流补充

### 2.1.1 推荐入口与兼容映射

| 规范入口 | 传统/兼容入口 |
|---|---|
| `bucket list/create/remove` | `ls/mb/rb` |
| `bucket event/cors/version/quota/anonymous` | 对应同名顶级命令 |
| `bucket lifecycle` / `bucket replication` | `ilm` / `replicate` |
| `bucket encryption` / `bucket lock` | encryption 无本文确认的顶级别名；lock 可用 `retention --default` |
| `object list/copy/move/remove` | `ls/cp/mv/rm` |
| `object stat/show/head/find/tree/share` | `stat/cat/head/find/tree/share` |
| `object retention` / `object legalhold` | `retention` / `legalhold`；上游另接受 `object legal-hold` |
| `get` / `put` | 方向受限的下载/上传入口，共用 copy 引擎 |

上表为上游入口参考。ZigFS 建议把同义入口接到同一 handler，不维护行为不同的两套实现。`ls ALIAS/` 与 `ls ALIAS/BUCKET` 的分派按路径层级决定。

### 2.1.2 Bucket 默认加密

```text
zc bucket encryption info <ALIAS/BUCKET>
zc bucket encryption set <ALIAS/BUCKET> --mode sse-s3
zc bucket encryption set <ALIAS/BUCKET> --mode sse-kms --key-id <KEY_ID>
zc bucket encryption clear <ALIAS/BUCKET>
```

这是上游已公开的命令家族。仅影响未来写入，不会重写、解密或重新加密已有对象。ZigFS 接入标准 S3 Bucket Encryption API；SSE-S3/SSE-KMS 支持范围见 [SSE-S3](api/sse-s3.md) 和 [SSE-KMS](api/sse-kms.md)。对象上传参数与 Bucket 默认设置应分别描述，不能因为支持 KMS 管理就推断支持所有 SSE 模式。

### 2.1.3 Object Lock、Retention 与 Legal Hold

```text
zc bucket lock info <ALIAS/BUCKET>
zc bucket lock set <ALIAS/BUCKET> --mode governance|compliance (--days N|--years N)
zc bucket lock clear <ALIAS/BUCKET>

zc object retention info <ALIAS/BUCKET/KEY> [--version-id ID]
zc object retention set <governance|compliance> <VALIDITY> <ALIAS/BUCKET/KEY> [--version-id ID] [--bypass]
zc object retention clear <ALIAS/BUCKET/KEY> [--version-id ID] [--bypass]

zc retention info --default <ALIAS/BUCKET>
zc retention set --default <governance|compliance> <Nd|Ny> <ALIAS/BUCKET>
zc retention clear --default <ALIAS/BUCKET>

zc object legalhold <info|set|clear> <ALIAS/BUCKET/KEY> [--version-id ID]
```

- 上游 `--vid` 是 `--version-id` 的别名；空 Version ID 非法，字面量 `null` 须与未传参数区分。
- `VALIDITY` 为正数天/年或 RFC 3339 UTC 时间；Bucket 默认仅接受天/年。`--days` 与 `--years` 互斥。
- Object Lock 在创建 Bucket 时启用并要求版本控制；clear 默认 retention 不等于关闭 Object Lock，也不修改既有版本的 retention。
- legalhold set/clear 分别写 ON/OFF；governance bypass 必须显式请求且通过服务端授权，不能绕过有效的 compliance 保留。
- 这些是上游标准 S3 工作流参考。ZigFS 是否开放标准接口须单独验证；已有 Management legal-hold 修改接口不能证明标准 S3 retention/lock/legalhold 全量兼容。原生入口见第 3.9 节。

### 2.1.4 `get`、`put` 与 `sql`

```text
zc get <ALIAS/BUCKET/KEY> <LOCAL_PATH> [OPTIONS]
zc put <LOCAL_PATH> <ALIAS/BUCKET[/KEY]> [OPTIONS]
zc sql <ALIAS/BUCKET/KEY> --query <SQL> [OPTIONS]
```

- get/put 是上游已有方向受限入口；ZigFS 建议复用 cp 的参数校验、加密、传输和输出实现。方向错误应在请求前拒绝。
- sql 对应 S3 Select，选项为 `--input-format csv|json|parquet`、`--output-format csv|json`、`--compression none|gzip|bzip2`；默认分别为 csv、csv、none，支持范围由后端决定。
- SQL 已纳入第 2.2 节单机 S3 补齐规划（P4）；未接入 SelectObjectContent 前明确返回不支持，不用本地查询冒充服务端执行。
- 上游 README 另指向 Iceberg table catalog 工作流；它属于独立产品能力，本文不规划 `zc table`，也不宣称覆盖 RustFS 所有专用扩展。

### 2.1.5 Multipart、恢复、校验与镜像（ZigFS 建议）

这些是业务命令完成前必须定义的行为，不是当前 `zc` 已有选项，也不是上游逐参数兼容声明。

| 能力 | 建议选项/入口 | 执行约定 |
|---|---|---|
| 自动分片 | `cp/put/pipe --multipart-threshold SIZE --part-size SIZE --max-parts N` | 在上传前校验服务端尺寸及分片上限；未知长度 stdin 使用有界缓冲，不读完整输入到内存 |
| 断点续传 | `cp/put --resume` | 记录 endpoint/bucket/key/uploadId、源标识及 part 布局；先 ListParts 核对，源变化或布局变化须拒绝继续 |
| 分片排查 | `multipart list <BUCKET>`、`multipart parts <OBJECT> --upload-id ID`、`multipart abort <OBJECT> --upload-id ID --yes` | 建议的标准 S3 扩展命令，分页列出和精确清理；与第 3.9 节原生管理入口区分 |
| 校验 | `--checksum ALGORITHM` | 按服务端支持计算并校验；ETag 不统一等于 MD5，尤其是 multipart 和加密对象 |
| 条件写入 | `--if-match ETAG` / `--if-none-match VALUE` | 明确条件作用于源还是目标；412 为冲突，不自动改为无条件覆盖 |
| 元数据 | `--metadata KEY=VALUE`、`--metadata-directive copy|replace` | 明确用户 metadata 与 Content-Type 等系统头的范围；S3 Copy 保留/替换语义单独实现 |
| 并发和重试 | 第 06 项执行控制选项 | 并发、限速和重试预算作用于整次命令；只重试已分类、可安全重放的请求 |
| 中断 | Ctrl+C | 停止调度，保留可恢复状态，报告剩余分片；stdin 不可重放时不能承诺恢复 |

- 同端点复制优先 CopyObject；跨端点复制使用各自凭据下载再上传。源版本/ETag 应固定，防止复制过程中读到变化后的内容。
- CompleteMultipartUpload 超时可能已成功，先核对远端结果再决定恢复；不要直接重建上传或重复删除源。
- `mv` 只在对应目标确认写入成功后删除源，目标成功但源删除失败应报告部分完成。禁止在不支持源版本/条件保护时宣称原子移动。
- `diff/mirror` 要定义比较依据：size、mtime、可验证 checksum；不能无条件将跨端点 ETag 当作内容哈希。列举或鉴权失败时禁止执行 mirror 删除阶段。
- mirror 默认不删除，`--remove` 显式开启；dry-run 报告新增/覆盖/删除。源目标重叠、同源同目标和目标命名冲突需在变更前拒绝。
- watch 重连应说明重复事件、顺序和丢失窗口；没有服务器游标保障时不能承诺无损或 exactly-once。通知配置可用也不代表实时事件流可用。

## 2.2 单机 S3 操作覆盖与完整协议入口（ZigFS 新增设计）

本节是后续逐步实现的 **S3 API → CLI 入口清单**，补充 RustFS 命令目录未覆盖的操作。所有命令均为规划，不要求服务端现在已支持；实现时依次完成协议、权限、错误语义和验收。

### 2.2.1 范围与核对基线

- **单机规划**：普通 Bucket/Object、访问控制、配置、版本、分片、查询、归档恢复和报表配置均登记，不因当前 ZigFS 缺少后端能力而从命令设计中删除。同一实例不同 Bucket 之间的 copy、日志/报表投递不属于多机。
- **排除多机**：Bucket replication（包括先不细分的同站复制规则）、site replication、远端 tier、集群 heal/pool/expand/decommission/rebalance 不纳入本次实现。第 2、3 节保留的对应语法仅供来源追溯，不能据此加入实施清单。
- **云端可选**：S3 Express、Metadata/Tables、Object Lambda 不是因为“多机”而排除；它们依赖 AWS 专属资源和端点，保留协议级入口设计，作为连接 AWS 时的可选适配，不要求单机 ZigFS 模拟云平台。Accelerate、Requester Pays、CloudWatch 等配置同样不能在本地伪装实际服务能力。
- 核对基线为 2026-11-16 下载的 botocore `s3/2006-03-01/service-2.json`：共 **116** 个 operation。另补充模型外的 Browser POST/POST Policy 工作流。覆盖结论仅针对这份模型快照，不宣称覆盖未来新增接口或独立 `s3control` / `s3tables` 服务的所有操作。
- 模型 SHA-256：`84c3a4e6ac1c80ed49cb1ddf1f548ea7f51d8a41acbfa0f198b9ba0028d784e8`。上游为可变分支；下次更新必须重新比较 operation 集合及输入 shape，不能只核对顶级命令数量。

核对统计：96 项单机规划、4 项旧协议兼容、13 项云端可选、3 项复制拓扑排除；合计 116 项，每个 operation 只登记一次。

### 2.2.2 命名和完整参数入口

表内省略 `zc` 前缀；`BUCKET` 为 `ALIAS/BUCKET`，`OBJECT` 为 `ALIAS/BUCKET/KEY`。noun-first 命令提供常用参数；复杂配置使用 `--file FILE|-`，禁止为了简化界面而丢弃合法 S3 字段。

同一能力在前文使用 `info/list`、本表使用 `get` 时，保留为同一读取 handler 的别名（例如 Bucket version/encryption 的 info 与 get）。完整配置 `set --file` 与前文简写参数互斥；tag clear 表示删除整套标签，tag remove --key 是读改写便利操作。

同时规划一个完整协议入口：

```text
zc s3api <operation-kebab-case> <ALIAS> --input-json <FILE|-> [--body FILE|-] [--output FILE|-]
zc s3api <operation-kebab-case> --help
zc s3api <operation-kebab-case> --generate-input-skeleton
```

- operation 名称由表中的 AWS operation 转为 kebab-case，例如 `get-object-attributes`、`upload-part-copy`。单机规划、旧协议兼容和云端可选行均有该入口；排除行不注册。它是本项目设计，不宣称与 `aws s3api` 命令行逐参数相同。
- input JSON 使用对应模型输入 shape 的字段名和结构（如 `Bucket`、`Key`、`VersionId`），覆盖全部适用的 query/header/body 字段及嵌套配置；客户端负责类型检查、必填项、枚举、XML/JSON 序列化、URI 编码及签名，不能把 JSON 原文直接发送给 S3 XML 接口。
- `--generate-input-skeleton` 展示已锁定模型的结构，不填入真实凭据；帮助列出必填项和字段约束。未知字段、互斥参数及端点不适用字段应报错，不静默丢弃。
- 流式二进制输入通过 `--body`，与 JSON 中同一 body 字段互斥；blob 字段遵循明确的 base64 编码规则。GetObject/Torrent/annotation 等正文可写 `--output`，元信息不得混入正文。Select 的事件流须解码 Records/Stats/Progress/End/Error，不能当普通 XML 解析。
- 高层命令和 s3api 共用请求层、鉴权、脱敏及错误映射。s3api **不绕过** 破坏性确认、排除列表或权限检查；需要确认的操作额外使用 `--yes`。
- 高层 `--file` 是对应配置正文，s3api `--input-json` 是完整请求结构，两者不能混淆。例如 policy set 文件是 Policy 文档，而 PutBucketPolicy 请求结构包含 Bucket 和字符串形式 Policy。
- 不支持的服务端操作/字段返回明确错误；“提供入口”不代表服务器支持。云端可选入口需要显式配置正确的服务端点与认证模式，不能把 Express 会话当作普通 ZigFS token。

### 2.2.3 逐操作映射

| S3 operation | 规划 CLI 入口（省略 `zc`） | 范围 |
|---|---|---|
| `AbortMultipartUpload` | `multipart abort <OBJECT> --upload-id ID --yes` | 单机规划 |
| `CompleteMultipartUpload` | `multipart complete <OBJECT> --upload-id ID --file FILE` | 单机规划 |
| `CopyObject` | `object copy <SOURCE> <TARGET>` | 单机规划 |
| `CreateBucket` | `bucket create <BUCKET>` | 单机规划 |
| `CreateBucketMetadataConfiguration` | `s3api create-bucket-metadata-configuration` | 云端可选：S3 Metadata/Tables |
| `CreateBucketMetadataTableConfiguration` | `s3api create-bucket-metadata-table-configuration` | 云端可选：S3 Metadata/Tables |
| `CreateMultipartUpload` | `multipart create <OBJECT>` | 单机规划 |
| `CreateSession` | `s3api create-session` | 云端可选：S3 Express |
| `DeleteBucket` | `bucket remove <BUCKET>` | 单机规划 |
| `DeleteBucketAnalyticsConfiguration` | `bucket analytics remove <BUCKET> --id ID` | 单机规划 |
| `DeleteBucketCors` | `bucket cors clear <BUCKET>` | 单机规划 |
| `DeleteBucketEncryption` | `bucket encryption clear <BUCKET>` | 单机规划 |
| `DeleteBucketIntelligentTieringConfiguration` | `bucket intelligent-tiering remove <BUCKET> --id ID` | 单机规划 |
| `DeleteBucketInventoryConfiguration` | `bucket inventory remove <BUCKET> --id ID` | 单机规划 |
| `DeleteBucketLifecycle` | `bucket lifecycle clear <BUCKET>` | 单机规划 |
| `DeleteBucketMetadataConfiguration` | `s3api delete-bucket-metadata-configuration` | 云端可选：S3 Metadata/Tables |
| `DeleteBucketMetadataTableConfiguration` | `s3api delete-bucket-metadata-table-configuration` | 云端可选：S3 Metadata/Tables |
| `DeleteBucketMetricsConfiguration` | `bucket metrics remove <BUCKET> --id ID` | 单机规划 |
| `DeleteBucketOwnershipControls` | `bucket ownership clear <BUCKET>` | 单机规划 |
| `DeleteBucketPolicy` | `bucket policy clear <BUCKET>` | 单机规划 |
| `DeleteBucketReplication` | `不注册；原 replicate 仅保留来源说明` | 排除：复制拓扑 |
| `DeleteBucketTagging` | `bucket tag clear <BUCKET>` | 单机规划 |
| `DeleteBucketWebsite` | `bucket website clear <BUCKET>` | 单机规划 |
| `DeleteObject` | `object remove <OBJECT> [--version-id ID]` | 单机规划 |
| `DeleteObjectAnnotation` | `object annotation clear <OBJECT> --name NAME` | 单机规划 |
| `DeleteObjectTagging` | `object tag clear <OBJECT>` | 单机规划 |
| `DeleteObjects` | `object remove-batch <BUCKET> --file FILE` | 单机规划 |
| `DeletePublicAccessBlock` | `bucket public-access-block clear <BUCKET>` | 单机规划 |
| `GetBucketAbac` | `bucket abac get <BUCKET>` | 单机规划 |
| `GetBucketAccelerateConfiguration` | `bucket accelerate get <BUCKET>` | 单机规划 |
| `GetBucketAcl` | `bucket acl get <BUCKET>` | 单机规划 |
| `GetBucketAnalyticsConfiguration` | `bucket analytics get <BUCKET> --id ID` | 单机规划 |
| `GetBucketCors` | `bucket cors get <BUCKET>` | 单机规划 |
| `GetBucketEncryption` | `bucket encryption get <BUCKET>` | 单机规划 |
| `GetBucketIntelligentTieringConfiguration` | `bucket intelligent-tiering get <BUCKET> --id ID` | 单机规划 |
| `GetBucketInventoryConfiguration` | `bucket inventory get <BUCKET> --id ID` | 单机规划 |
| `GetBucketLifecycle` | `s3api get-bucket-lifecycle` | 旧协议兼容 |
| `GetBucketLifecycleConfiguration` | `bucket lifecycle get <BUCKET>` | 单机规划 |
| `GetBucketLocation` | `bucket location <BUCKET>` | 单机规划 |
| `GetBucketLogging` | `bucket logging get <BUCKET>` | 单机规划 |
| `GetBucketMetadataConfiguration` | `s3api get-bucket-metadata-configuration` | 云端可选：S3 Metadata/Tables |
| `GetBucketMetadataTableConfiguration` | `s3api get-bucket-metadata-table-configuration` | 云端可选：S3 Metadata/Tables |
| `GetBucketMetricsConfiguration` | `bucket metrics get <BUCKET> --id ID` | 单机规划 |
| `GetBucketNotification` | `s3api get-bucket-notification` | 旧协议兼容 |
| `GetBucketNotificationConfiguration` | `bucket notification get <BUCKET>` | 单机规划 |
| `GetBucketOwnershipControls` | `bucket ownership get <BUCKET>` | 单机规划 |
| `GetBucketPolicy` | `bucket policy get <BUCKET>` | 单机规划 |
| `GetBucketPolicyStatus` | `bucket policy status <BUCKET>` | 单机规划 |
| `GetBucketReplication` | `不注册；原 replicate 仅保留来源说明` | 排除：复制拓扑 |
| `GetBucketRequestPayment` | `bucket request-payment get <BUCKET>` | 单机规划 |
| `GetBucketTagging` | `bucket tag get <BUCKET>` | 单机规划 |
| `GetBucketVersioning` | `bucket version get <BUCKET>` | 单机规划 |
| `GetBucketWebsite` | `bucket website get <BUCKET>` | 单机规划 |
| `GetObject` | `object get <OBJECT> <LOCAL\|->` | 单机规划 |
| `GetObjectAcl` | `object acl get <OBJECT>` | 单机规划 |
| `GetObjectAnnotation` | `object annotation get <OBJECT> --name NAME` | 单机规划 |
| `GetObjectAttributes` | `object attributes <OBJECT> --attributes LIST` | 单机规划 |
| `GetObjectLegalHold` | `object legalhold info <OBJECT>` | 单机规划 |
| `GetObjectLockConfiguration` | `bucket lock info <BUCKET>` | 单机规划 |
| `GetObjectRetention` | `object retention info <OBJECT>` | 单机规划 |
| `GetObjectTagging` | `object tag get <OBJECT>` | 单机规划 |
| `GetObjectTorrent` | `object torrent <OBJECT> --output FILE` | 单机规划 |
| `GetPublicAccessBlock` | `bucket public-access-block get <BUCKET>` | 单机规划 |
| `HeadBucket` | `bucket stat <BUCKET>` | 单机规划 |
| `HeadObject` | `object stat <OBJECT>` | 单机规划 |
| `ListBucketAnalyticsConfigurations` | `bucket analytics list <BUCKET>` | 单机规划 |
| `ListBucketIntelligentTieringConfigurations` | `bucket intelligent-tiering list <BUCKET>` | 单机规划 |
| `ListBucketInventoryConfigurations` | `bucket inventory list <BUCKET>` | 单机规划 |
| `ListBucketMetricsConfigurations` | `bucket metrics list <BUCKET>` | 单机规划 |
| `ListBuckets` | `bucket list <ALIAS>` | 单机规划 |
| `ListDirectoryBuckets` | `s3api list-directory-buckets` | 云端可选：S3 Express |
| `ListMultipartUploads` | `multipart list <BUCKET>` | 单机规划 |
| `ListObjectAnnotations` | `object annotation list <OBJECT>` | 单机规划 |
| `ListObjectVersions` | `bucket version list <BUCKET>` | 单机规划 |
| `ListObjects` | `object list <BUCKET> --list-api v1` | 单机规划 |
| `ListObjectsV2` | `object list <BUCKET> --list-api v2` | 单机规划 |
| `ListParts` | `multipart parts <OBJECT> --upload-id ID` | 单机规划 |
| `PutBucketAbac` | `bucket abac set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketAccelerateConfiguration` | `bucket accelerate set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketAcl` | `bucket acl set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketAnalyticsConfiguration` | `bucket analytics set <BUCKET> --id ID --file FILE` | 单机规划 |
| `PutBucketCors` | `bucket cors set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketEncryption` | `bucket encryption set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketIntelligentTieringConfiguration` | `bucket intelligent-tiering set <BUCKET> --id ID --file FILE` | 单机规划 |
| `PutBucketInventoryConfiguration` | `bucket inventory set <BUCKET> --id ID --file FILE` | 单机规划 |
| `PutBucketLifecycle` | `s3api put-bucket-lifecycle` | 旧协议兼容 |
| `PutBucketLifecycleConfiguration` | `bucket lifecycle set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketLogging` | `bucket logging set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketMetricsConfiguration` | `bucket metrics set <BUCKET> --id ID --file FILE` | 单机规划 |
| `PutBucketNotification` | `s3api put-bucket-notification` | 旧协议兼容 |
| `PutBucketNotificationConfiguration` | `bucket notification set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketOwnershipControls` | `bucket ownership set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketPolicy` | `bucket policy set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketReplication` | `不注册；原 replicate 仅保留来源说明` | 排除：复制拓扑 |
| `PutBucketRequestPayment` | `bucket request-payment set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketTagging` | `bucket tag set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketVersioning` | `bucket version set <BUCKET> --file FILE` | 单机规划 |
| `PutBucketWebsite` | `bucket website set <BUCKET> --file FILE` | 单机规划 |
| `PutObject` | `object put <LOCAL> <OBJECT>` | 单机规划 |
| `PutObjectAcl` | `object acl set <OBJECT> --file FILE` | 单机规划 |
| `PutObjectAnnotation` | `object annotation set <OBJECT> --name NAME --file FILE` | 单机规划 |
| `PutObjectLegalHold` | `object legalhold set <OBJECT> --file FILE` | 单机规划 |
| `PutObjectLockConfiguration` | `bucket lock set <BUCKET> --file FILE` | 单机规划 |
| `PutObjectRetention` | `object retention set <OBJECT> --file FILE` | 单机规划 |
| `PutObjectTagging` | `object tag set <OBJECT> --file FILE` | 单机规划 |
| `PutPublicAccessBlock` | `bucket public-access-block set <BUCKET> --file FILE` | 单机规划 |
| `RenameObject` | `s3api rename-object` | 云端可选：S3 Express |
| `RestoreObject` | `object restore <OBJECT> --file FILE` | 单机规划 |
| `SelectObjectContent` | `sql <OBJECT> --query SQL` | 单机规划 |
| `UpdateBucketMetadataAnnotationTableConfiguration` | `s3api update-bucket-metadata-annotation-table-configuration` | 云端可选：S3 Metadata/Tables |
| `UpdateBucketMetadataInventoryTableConfiguration` | `s3api update-bucket-metadata-inventory-table-configuration` | 云端可选：S3 Metadata/Tables |
| `UpdateBucketMetadataJournalTableConfiguration` | `s3api update-bucket-metadata-journal-table-configuration` | 云端可选：S3 Metadata/Tables |
| `UpdateObjectEncryption` | `object encryption update <OBJECT> --file FILE` | 单机规划 |
| `UploadPart` | `multipart upload-part <OBJECT> --upload-id ID --part-number N --body FILE` | 单机规划 |
| `UploadPartCopy` | `multipart copy-part <SOURCE> <TARGET> --upload-id ID --part-number N` | 单机规划 |
| `WriteGetObjectResponse` | `s3api write-get-object-response` | 云端可选：Object Lambda |

### 2.2.4 配置类命令的执行约定

- ACL：Bucket/Object 分开读取和设置，支持完整 AccessControlPolicy 或 `--acl` canned ACL；二者互斥。grant 的 grantee 类型与权限按 schema 校验。S3 无 DeleteBucketAcl/DeleteObjectAcl，不设计虚假的 clear API；对象 ACL 支持版本选择。
- Policy：`bucket policy get/set/clear/status` 独立于 anonymous 便利入口；set 替换整份策略。Public Access Block 四个布尔字段、OwnershipControls、ABAC 是不同配置，不能仅通过更改 policy 模拟。
- ABAC：Get/PutBucketAbac 已登记；AWS 启用后涉及 `s3control` 的 TagResource/UntagResource，不能继续宣称 Put/DeleteBucketTagging 完成同一工作流。独立服务操作另行适配，当前帮助须指出该依赖。
- Website：支持 IndexDocument、ErrorDocument、RoutingRules、RedirectAllRequestsTo 及互斥关系；清除 Website 不删除 Bucket 对象。
- Logging：get/set 覆盖目标 Bucket、prefix、授予及目标对象键格式。关闭使用空的 BucketLoggingStatus；S3 没有 DeleteBucketLogging。单机可使用同实例目标 Bucket。
- Notification：完整配置 get/set 与 event add/remove 便利操作并存。清空用空配置 PUT，没有 DELETE API；增量修改是读改写，应提示并发覆盖风险。AWS SNS/SQS/Lambda/EventBridge 与 ZigFS Webhook/MQTT 不能互换。
- Analytics/Inventory/Metrics/Intelligent-Tiering：按 ID 执行 list/get/set/remove；不能用一次 set 替换所有 ID。支持完整过滤器、目标、格式、周期、版本范围和 tiering 等嵌套字段，list 消费分页。单机报表可投递同实例 Bucket，外部 AWS 目标需单独适配。
- RequestPayment：set Payer；Accelerate：set Enabled/Suspended；Versioning：set Status/MFADelete，不能发明不存在的 DELETE API。MFA 设备和验证码通过受保护输入，不写日志。
- Lifecycle：完整 get/set/clear 覆盖 Filter（Prefix/Tag/Size/And）、Expiration、Transition、NoncurrentVersionExpiration/Transition、ExpiredObjectDeleteMarker、AbortIncompleteMultipartUpload；本地存储级别可以规划，远端 tier 不在本次范围。旧 Get/PutBucketLifecycle 仍使用各自旧 schema，不擅自当作新版请求发送。
- Object Lock：清除默认 retention 用 PutObjectLockConfiguration 移除 Rule，不能关闭已启用的锁。Retention/LegalHold 清除也必须遵守对应 PUT 语义和权限，不虚构 DELETE API。
- Encryption：Bucket 默认加密仅影响后续写入；UpdateObjectEncryption 是独立 API，不能用 CopyObject 冒充（复制会改变版本或元数据）。SSE-C、KMS context、Bucket Key 等字段通过完整输入 shape 登记；后端不支持时明确拒绝。

### 2.2.5 对象、版本与分片完整工作流

```text
zc object attributes local/data/item --attributes ETag,Checksum,ObjectParts,StorageClass,ObjectSize
zc object remove-batch local/data --file delete.json --yes
zc multipart create local/data/large.bin
zc multipart upload-part local/data/large.bin --upload-id ID --part-number 1 --body part-1.bin
zc multipart copy-part local/data/source.bin local/data/large.bin --upload-id ID --part-number 2 --copy-source-range bytes=0-5242879
zc multipart parts local/data/large.bin --upload-id ID
zc multipart complete local/data/large.bin --upload-id ID --file parts.json
zc multipart abort local/data/large.bin --upload-id ID --yes
```

- Put/Get/Head/Copy/Delete 共用参数族但按 operation 限制：VersionId、Range/PartNumber、条件 ETag/日期、Content-Type/Encoding/Disposition/Language/Cache-Control/Expires、metadata、tagging、ACL、storage class、checksum、加密、RequestPayer、ExpectedBucketOwner。源对象条件与目标条件使用不同参数，不能混用。
- GetObject 响应覆盖参数 `response-content-*`、`response-cache-control`、`response-expires` 要参与签名；Range 只承诺服务端声明的单范围语义。HeadObject 与读取前 N 字节的 `head` 不是同一个操作。
- list v1 使用 Marker，v2 使用 ContinuationToken/StartAfter；版本列表使用 KeyMarker/VersionIdMarker，分片上传列表使用 KeyMarker/UploadIdMarker，parts 使用 PartNumberMarker。输出保留各自游标，不能混作一个 key 偏移。
- DeleteObjects 的文件含 Objects（Key、可选 VersionId）和 Quiet；最多每请求 1000 项，超出由高层分批。HTTP 200 也须解析逐项 Error。精确删除 VersionId、删除 DeleteMarker 和创建 DeleteMarker 必须区分。
- GetObjectAttributes 的 ObjectParts 也有分页；stat 不能假定一个 HEAD 已返回全部分片与 checksum 详情。
- multipart create 保存加密、metadata、tagging、checksum 配置；upload-part 和 copy-part 提交对应布局。copy-part 支持源版本、源条件和范围，只要求同一服务端可访问源 Bucket，不需要多机。
- complete 文件含按 PartNumber 排序的 ETag 及适用 checksum；S3 可能先发 HTTP 200 再在响应体返回 Error，必须读取并判定整个响应。abort 后保留诊断结果，不承诺正在飞行的 part 请求已同步消失。
- Annotation 独立于对象 metadata/tagging：支持名称、版本、分页前缀、payload 与 ObjectIfMatch；内容/数量限制按锁定模型和服务端约束。annotation clear 仅删除指定名称。
- RestoreObject 使用完整 RestoreRequest，包括恢复天数和检索选项；恢复通常异步，使用对象状态确认完成，不能把请求成功当成数据已可读。Select 使用完整 Input/OutputSerialization 和 ScanRange，简写 sql flags 不覆盖的字段由 s3api 接收。
- GetObjectTorrent 作为历史协议入口登记；后端无该能力时返回不支持，不要求部署多节点种子网络。

### 2.2.6 Browser POST 与预签名（模型外补充）

```text
zc object post <ALIAS/BUCKET> --file LOCAL_FILE --fields-file FORM_JSON
zc share post <ALIAS/BUCKET> --policy-file POLICY_JSON --expire DURATION
zc share <ALIAS/BUCKET/KEY> --method GET|PUT|DELETE|HEAD --expire DURATION [--version-id ID]
```

- `object post` 使用 multipart/form-data，将表单字段和文件发送到 Bucket，不能改用 PutObject 冒充；fields 文件包含 policy/signature 等时必须脱敏。
- `share post` 输出 URL 和签名表单字段；policy 包括 expiration、key/Content-Type 条件和 content-length-range，签名有效期受临时凭据到期限制。
- 预签名扩展须支持 multipart 的 uploadId/partNumber 与必要请求头；命令定义必须区分 URL 的方法、签名头和实际请求体，不能只拼接 query 参数。
- Presign 是客户端签名工作流，不另算 AWS operation；POST Object 不在本次 SDK operation 模型中，但属于必须登记的 S3 HTTP 工作流。

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

### 3.5 Cluster heal / pool / expand / decommission / rebalance（本次排除）

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
zc admin service-account <ls|create|update|info|rm> ...
```

### 3.7 Service / Config / Bucket Metadata / Migration / Site Replication

以下 migration/backfill 与 site replication 涉及外部源或多站点，本次排除；service/config 和本地 metadata 导入导出仍可独立规划。

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

### 3.8 上游补充 Admin 命令

```text
zc admin iam export <ALIAS> --file <FILE>
zc admin iam import <ALIAS> --file <FILE|-> [--conflict fail|overwrite] [--dry-run] [--yes]
zc admin heal mrf <status|list|get|refresh|recheck|accept-risk> <ALIAS> [OPTIONS]
zc admin integrity <readiness|inventory|audit|migrate|job|resume|pause|cancel> <ALIAS> [OPTIONS]
```

- IAM archive 包含可恢复的敏感凭据；导出权限受限，不覆盖已有文件。导入先验证格式和冲突，实际写入要求 `--yes`，未知结果不能自动重试。
- MRF 和 integrity 是 RustFS 专属恢复/完整性工作流；ZigFS 尚无本文确认的等价协议，列为参考，不通过同名空实现宣称支持。
- `admin service-account update` 应允许按契约修改策略和描述等字段；不应通过删除重建模拟更新。
- 上游 `admin expand` 的 `scale`、`decommission` 的 `decom` 是兼容别名；ZigFS 是否保留需在实现清单中明确。

### 3.9 ZigFS Management 能力映射（ZigFS 建议，全部 CLI 待实现）

下表依据当前工作区 OpenAPI；“已有契约”不等于端到端测试已通过。路径均相对于 `/_admin/v1`，请求体、鉴权和权限以契约为准，不采用 RustFS Admin 请求格式。

| 建议入口 | 当前 Management 契约 | 设计边界 |
|---|---|---|
| `admin auth login/session/logout` | `/auth/login`、`/auth/session`、`/auth/logout` | 独立于 S3 alias；token 脱敏、受限存储 |
| `admin idp openid` / OIDC 登录 | `/oidc/providers`、`/oidc/providers/{id}`、`/oidc/validate`、`/auth/oidc/*` | 区分 provider 管理与登录/刷新；CLI 回调流程另行设计 |
| `admin user/group/policy` | `/users`、`/groups`、`/policies` 及单项路径 | attach/detach、成员更新按实际 schema 映射 |
| `admin access-key list/create/update/remove` | `/access-keys`、`/access-keys/{id}`、`/users/{name}/access-keys` | 补全凭据生命周期，密钥仅在允许的响应中展示 |
| `admin role-session remove` | `/role-sessions/{access_key}` | 仅删除已吊销记录；不能当作吊销操作 |
| `admin bucket configuration get/set` | `/buckets/{name}/configuration` | 原生配置不等于所有对应 S3 API 均可用 |
| `admin object legalhold set/clear` | `/buckets/{name}/legal-hold` | 要求 key 和精确 version_id；与标准 S3 legalhold 入口分开 |
| `admin directory create/remove/cleanup` | `/buckets/{name}/directories`、`/directories/cleanup` 子路径 | 目录属于 ZigFS 扩展；remove 须区分当前对象删除与 all_versions 永久清理 |
| `admin multipart list/info/create/complete/abort` | `/buckets/{name}/multipart-uploads`、`/multipart-uploads` 及单项/complete 路径 | 与标准 S3 multipart 区分；清理须明确 UploadId |
| `admin event-destination list/set/remove` | `/event-destinations`、`/event-destinations/{name}` | Webhook/MQTT 目标凭据脱敏 |
| `admin event-subscription get/set` | `/buckets/{name}/event-subscriptions` | 使用 ZigFS 订阅模型，不伪装 SNS/SQS/Lambda 配置 |
| `admin storage info/scanner/gc` | `/storage`、`/storage/scanner`、`/storage/gc` | GC 是变更操作；不能直接删数据文件 |
| `admin monitoring` / `admin diagnostics get/set` | `/monitoring`、`/monitoring/diagnostics` | 区分监控快照与诊断配置变更 |
| `admin system` / `admin health` | `/system`、`/health` | 认证探测与公共 ping/ready 分开 |
| `admin settings` | `/settings` 及 listener/authentication/display/region/instance/network 子路径 | 依各端点提供读取/更新；不虚构通用 DELETE/import |
| `admin logs` / `admin audit-logs` | `/settings/logs`、`/settings/audit-logs` 及 query/download 子路径；`/audit-events`、`/audit-events/options` | 区分配置、查询、下载，分页和范围必须有界 |
| `admin kms clear-cache` / `admin kms key rotate` | `/settings/kms/clear-cache`、`/settings/kms/keys/action` | 补充上游清单未覆盖的 ZigFS 操作；根据后端能力启用 |

KMS 的 describe/rotate/schedule-deletion/cancel-deletion/delete 应映射到契约枚举；ZigFS 当前七天待删除语义不等于上游 `--pending-window-days 7..30`，也不代表到期自动删除。服务 restart/stop、MFA、cluster pool/heal、site replication、IAM archive 等在接入前必须先确认本项目对应端点，不能因为第 3 节列出名称就启用。

相关设计来源：[事件目标](api/event-destinations.md)、[Bucket 订阅](api/bucket-event-subscriptions.md)、[日志](api/system-logs.md)、[KMS 权限](api/kms-console-permissions.md)、[存储回收](storage-reclamation.md)。

## 4. 按指令优先级分步实施

本节是后续开发的执行顺序。**步骤 01–03 已验收完成，其余步骤尚未执行**；进度与验证证据记录在第 4.8 节，文档规划本身不计入功能完成。

### 4.1 执行规则与依赖

1. 默认按照步骤编号执行，先完成单机常用工作流，再补齐配置、运维和完整协议；P5 云端可选不阻塞单机交付。
2. 每步先核对当前服务端 API、请求/响应 schema 和权限，再实现 CLI。服务端不支持时登记具体缺口并补协议与测试；该命令保持未完成，不以返回 NotSupported 视为验收通过。
3. 单个能力受服务端阻塞时，可继续没有该依赖的下一步；记录跳过原因、依赖接口和回补条件，不让一个高级能力阻塞所有基础命令。
4. 高层命令、传统别名和 `s3api` 共用请求层；每实现一个 S3 operation，同步登记对应 `s3api` 输入/输出与参数覆盖，不在最后另写一套客户端。
5. 必要的权限检查、版本选择、分页、错误解析和危险操作确认随所属命令交付，不能延后到“收尾优化”。基础上传先限定单对象范围；分片、递归和批量在后续步骤验收后再开放。
6. 每个步骤都须通过第 4.8 节检查，才将状态改为已完成。涉及数据变更的联调用隔离测试 Bucket 和测试凭据，不能清理用户现有数据。

主要依赖链：`01 → 02 → 03 → 04 → 05 → 06 → 07 → 08`。此后按编号推进；版本化批量删除依赖 10，带删除的 mirror 依赖 08/10/17，所有原生管理写操作依赖 19，云端可选依赖完整请求层与独立端点适配。

### 4.2 P0：先打通基本文件工作流（步骤 01–08）

| 步骤 | 状态 | 实施命令 / 工作 | 前置依赖 | 本步验收结果 |
|---|---|---|---|---|
| 01 | 已完成 | parser、全局参数、help、`--version`、错误与输出框架；定义 bucket/object 分组及别名注册 | 无 | 消除 `zc version` 冲突；帮助不联网；参数前后置、`--`、错误退出码及 JSON 可解析 |
| 02 | 已完成 | `alias set/list/info/remove/export/import`；配置路径、原子写、安全凭据输入、region、TLS | 01 | alias 往返导入导出；默认脱敏；冲突不部分写入；AK/SK/token 不混源 |
| 03 | 已完成 | HTTP/SigV4、流式请求、XML/JSON 编解码、错误映射；`s3api` 分派、input JSON、skeleton | 02 | 签名与 Session Token 正确；特殊 Key 编码；超时/重试有界；未知字段拒绝；仅注册已接入操作 |
| 04 | 已完成 | `bucket list/create/stat/location/remove`、`object list --list-api v2`；`ls/mb/rb` 基础别名 | 03 | 创建→列举→Head/Location→空桶删除；完整分页；非空桶拒绝；尚不开放强制清理 |
| 05 | 已完成 | `object put/get/stat/show/head`、`put/get/cat/head/stat`、本地↔远端单对象 `cp` | 04 | 二进制与零字节往返一致；Range、条件读取、metadata/checksum；正文与诊断分离；流式有界内存 |
| 06 | 已完成 | 同实例 `object copy`、`mv`、单对象 `rm`、`object remove-batch`；覆盖与 dry-run | 05 | Copy 条件/metadata 生效；目标确认成功才删除源；批量 200 响应内逐项 Error 判失败；先限定无版本场景 |

| 07 | 已完成 | `multipart create/upload-part/parts/list/complete/abort`；自动分片、`--resume`、`pipe` | 05–06 | 大文件完整往返；中断恢复核对源与 parts；Complete 体内 Error/未知结果处理；stdin 不假装可恢复 |
| 08 | 已完成 | 递归/多源 `cp/mv/rm`、筛选、并发/限速/重试、summary、普通空桶清理与 `rb --dangerous` | 06–07 | 路径冲突与越界拒绝；规划分页失败零写入，执行失败汇总部分完成；删除有界；版本化桶暂拒绝强制清理，待 10 补齐 |

**P0 里程碑**：一个全新 alias 能完成创建 Bucket、单对象/大文件上传下载、同实例复制移动和受控清理；核心操作已同时接入高层命令和 s3api。跨端点迁移不属于本次验收。

### 4.3 P1：版本、权限与常用 Bucket 配置（步骤 09–16）

| 步骤 | 状态 | 实施命令 / 工作 | 前置依赖 | 本步验收结果 |
|---|---|---|---|---|
| 09 | 待执行 | `share` GET/PUT/DELETE/HEAD、multipart 预签名、`share post`、`object post` | 05/07 | 临时凭据有效期上限；签名 query/header；POST Policy 条件及表单上传；正文与输出契约正确 |
| 10 | 待执行 | `bucket version get/enable/suspend/set/list`；所有适用命令的 `--version-id`；版本化 rm/rb | 06–08 | Enabled/Suspended、null 版本、DeleteMarker、精确恢复/复制、批量 VersionId；强制清桶不跳过历史版本 |
| 11 | 待执行 | `bucket policy get/set/clear/status`、`anonymous`；Bucket/Object ACL、Public Access Block、Ownership | 03/10 | 最小权限与显式 Deny；配置替换/清除语义；权限变更实测影响访问；不把所有入口简化为匿名策略 |
| 12 | 待执行 | `tag`、`bucket tag`、`object tag`；`bucket cors get/set/clear` | 10–11 | Bucket/对象/精确版本标签隔离；完整配置往返；指定标签删除不误清其他标签；CORS 实际响应验证 |
| 13 | 待执行 | `bucket encryption get/set/clear`；上传/复制/分片的 SSE-S3/SSE-KMS 字段 | 05/07/11 | 默认设置与请求覆盖分离；已有对象不被默认设置重写；无权访问密钥失败；密钥材料脱敏 |
| 14 | 待执行 | `bucket lock info/set/clear`、`object retention`、`object legalhold` 及兼容别名 | 10–11 | 创建锁定桶、版本保护、governance bypass 权限、compliance 不可削弱；清默认规则不关闭锁 |
| 15 | 待执行 | `bucket lifecycle get/set/clear`、`ilm rule add/edit/list/remove/export/import` | 10/12/14 | Prefix/Tag/Size/And 规则和过期版本/分片清理；规则保存与后台实际执行分别验证；仅本地 tier |
| 16 | 待执行 | `bucket notification get/set`、`event`、`quota` | 11–12；原生后端需 19 | S3 通知与 ZigFS 订阅模型分开；空配置清除；并发读改写风险说明；配额须验证写入限制，不仅配置成功 |

**P1 里程碑**：版本与数据保护贯穿已有命令；常用配置有真实协议和行为验证。quota 或原生事件若依赖 Management 登录，可先完成步骤 19 再回补，不把 S3 签名凭据直接当管理会话。

### 4.4 P2：搜索、差异和运维便利命令（步骤 17–18）

| 步骤 | 状态 | 实施命令 / 工作 | 前置依赖 | 本步验收结果 |
|---|---|---|---|---|
| 17 | 待执行 | `find/tree/du/diff`、`ping/ready` | 04–05/10；管理快照需 19 | 全分页、有界内存；du 明示扫描来源/截断；没有 fallback 授权不扫描；liveness/readiness 分开 |
| 18 | 待执行 | `mirror`、`watch`、`completions` | 08/10/17；watch 需事件流协议 | 本地↔单实例及同实例 Bucket 同步；先比较后删除；列表失败禁止删除；事件重连限制明确；补全只列已开放命令 |

**P2 里程碑**：常用脚本可稳定处理大列表、同步计划与部分失败。跨站同步、无损事件流和 exactly-once 不属于本次承诺；服务端没有事件流时 watch 保持待实现。

### 4.5 P3：ZigFS 单机管理（步骤 19–22）

| 步骤 | 状态 | 实施命令 / 工作 | 前置依赖 | 本步验收结果 |
|---|---|---|---|---|
| 19 | 待执行 | `admin auth login/session/logout`、OIDC 登录适配；独立 Management endpoint/client | 01–03 | 管理 token 安全存储/过期；退出失效；与 S3 alias 认证分离；无管理权限不能写配置 |
| 20 | 待执行 | `admin user/group/policy/access-key`、OIDC provider、role-session；service-account 按实际契约接入 | 19 | 创建/更新/禁用/删除及关联权限；一次性凭据响应；会话记录删除不冒充吊销；不存在端点的入口不启用 |
| 21 | 待执行 | `admin settings/config`、`admin kms`、Bucket configuration、event-destination/subscription | 19–20 | 类型/权限验证；KMS 后端能力、rotate/delete 状态机；配置持久化；事件目标测试；回补步骤 13/16 原生依赖 |
| 22 | 待执行 | `admin system/health/storage/scanner/gc/monitoring/diagnostics/logs/audit-logs`、directory/multipart/legalhold 原生入口 | 19/21 | 有界查询/下载、脱敏、GC 真实回收；审计记录；保护状态与 S3 一致；不读写数据目录 |

**P3 里程碑**：第 3.9 节当前已有单机 Management 契约有对应 CLI 工作流。`admin service` 的本地 restart/stop 等仅在存在明确服务端契约后单独接入；RustFS cluster、MFA 和 IAM archive 不借用名称伪装支持。

### 4.6 P4：单机 S3 API 完整补齐（步骤 23–29）

| 步骤 | 状态 | 实施命令 / 工作 | 前置依赖 | 本步验收结果 |
|---|---|---|---|---|
| 23 | 待执行 | `multipart copy-part`、`object attributes`；剩余条件、checksum、metadata、SSE-C 等输入字段 | 07/10/13 | 源版本/范围/条件正确；Attributes ObjectParts 分页；源目标加密分离；字段支持逐项登记 |
| 24 | 待执行 | `bucket website/logging/request-payment/accelerate` | 11/19 | 完整 get/set/clear（仅存在 DELETE 的配置）；网站/日志实际行为和本地适用性；计费/全球加速单列云端验收，不冒充本地功能 |
| 25 | 待执行 | `bucket analytics/inventory/metrics/intelligent-tiering` 四操作族 | 12/15/24 | 按 ID 的 list/get/set/remove 和分页；同实例报表投递与后台执行；云指标/存储级别能力另列限制 |
| 26 | 待执行 | `object restore`、`sql` / SelectObjectContent、历史 `object torrent` | 05/15/23 | 本地归档恢复异步状态；Select 事件流错误/统计/结束；历史接口有协议实现才算完成，不搭建多机网络 |
| 27 | 待执行 | `object annotation get/set/clear/list`、`object encryption update`、`bucket abac get/set` | 10–13/23 | annotation 版本/分页/条件隔离；原地加密更新不改变版本冒充；ABAC 授权实测，云端 TagResource 依赖单列 |
| 28 | 待执行 | `object list --list-api v1`；旧 Get/PutBucketLifecycle、Get/PutBucketNotification | 04/15–16 | Marker 与 V2 token 分开；旧请求/响应 schema 独立验证，不改名转发新版协议 |
| 29 | 待执行 | 对照第 2.2.3 节逐项收口高层入口、s3api、所有输入字段及测试记录 | 01–28 的适用步骤 | 96 项单机规划与 4 项旧协议兼容逐项有结论；无遗漏/重复；未通过项列为缺口，不发布“全兼容”声明 |

**P4 里程碑**：完成单机适用能力和旧协议的逐项验收。96 项是命令规划分类，并不表示每个字段都能在本机提供 AWS 服务；例如 Accelerate、外部 CloudWatch、ABAC 的 s3control 标签操作必须标记云端依赖。报告分别列出本地通过、仅远端通过、待实现和不适用，不能将远端通过计入 ZigFS 服务端兼容率。

### 4.7 P5：云端可选适配与排除范围（步骤 30）

| 步骤 | 状态 | 实施命令 / 工作 | 前置依赖 | 本步验收结果 |
|---|---|---|---|---|
| 30 | 可选 / 未排期 | 13 项云专属 s3api：S3 Express、Metadata/Tables、Object Lambda；前述配置的 AWS 专属依赖 | 03/29；独立云端凭据与测试资源 | 端点/认证/会话/资源依赖独立适配；远端实测单列结果；不要求本机模拟云平台 |

- **不执行**：Bucket replication、远端 tier、外部源 migration/backfill、site replication、cluster heal/pool/expand/decommission/rebalance。第 2.2.3 节的 3 个复制 API 不注册。
- **不计入 S3 补齐**：RustFS MRF/integrity、IAM archive、独立 s3control/s3tables 服务的全部 API；如果某工作流依赖这些服务，只在对应步骤登记明确依赖，不自动扩大本次范围。
- 本地目录与单实例同步、同实例跨 Bucket copy/copy-part、同实例报表目标仍在范围内，不能因为含“复制”或“目标 Bucket”字样就按多机排除。

### 4.8 每一步的完成条件与进度登记

将步骤状态从“待执行”改为“进行中”或“受阻”时，应补充实际进度；只有以下条件全部满足才能标记“已完成”：

- [ ] 本步命令、别名、帮助、默认值与互斥参数已实现；未支持的组合显式报错。
- [ ] 后端 API、权限和服务版本已核对；适用的高层入口与 s3api 共用协议实现。
- [ ] 正常、非法参数、权限拒绝、不存在资源、网络失败场景已验证；本步涉及时覆盖分页、版本和部分失败。
- [ ] JSON/JSONL、stdout/stderr、退出码及敏感数据脱敏符合第 1 节；危险操作有 dry-run 或明确确认。
- [ ] 在 `zigfs-cli/` 执行 `zig build test` 和 `zig build` 通过，并运行本步对应的隔离实例集成测试；测试路径和命令已记录。
- [ ] 修改服务端时执行对应 `zigfs/` 测试；仅涉及 Go BFF 时增加相关 Go 测试。未修改的模块不以无关测试替代 CLI 验收。
- [ ] 同步更新 `zigfs-cli/README.md`、命令支持清单及必要的协议文档，记录验证版本和仍存限制。

每步完成后在下表追加一行，测试证据使用仓库路径或可复现命令；没有运行的测试明确标注未运行，不填“通过”。

| 步骤 | 状态 | 已交付命令 / operation | 服务端依赖 / 剩余缺口 | 测试文件与执行结果 | 完成日期 |
|---|---|---|---|---|---|
| 01 | 已完成 | help、--version、全局参数、bucket/object 和传统别名注册、JSON/退出码 | 无服务端依赖；业务命令仅帮助可用，执行返回 7 | `zigfs-cli/src/cli.zig` 单元测试；在 `zigfs-cli/` 执行 `zig build test`、`zig build`、`python3 tests/cli_smoke.py` 均通过（Zig 0.17.0）；离线子进程验证，无需实例 | 2026-11-16 |
| 02 | 已完成 | alias set/list/info/remove/export/import；配置选择、原子写、凭据输入、连接参数与优先级解析 | 本地操作，无网络请求；TLS 握手、CA 信任和远端凭据有效性待步骤 03；TOML 子集及 POSIX 提示范围见 CLI README | `zigfs-cli/src/alias.zig` 单元测试；`zig build test`、`zig build`、`python3 tests/cli_smoke.py`、`python3 tests/alias_smoke.py` 通过（Zig 0.17.0，隔离配置与 PTY 验证） | 2026-11-16 |
| 03 | 已完成 | HTTP/libcurl、SigV4、流式传输、XML/JSON、错误映射与 s3api；CreateBucket/ListBuckets/HeadBucket/GetBucketLocation/ListObjectsV2/HeadObject/GetObject/PutObject 的声明子集 | 高层入口、完整分页和高级字段待后续步骤；仅注册已验证入口；没有 AWS 实测，支持字段见 CLI README | `zig build test`、`zig build`；`tests/cli_smoke.py`、`tests/alias_smoke.py`；`tests/s3api_integration.py`：真实隔离 ZigFS 12 MiB 往返/临时凭据，独立 HTTP 签名/异常测试及本地 TLS 证书测试均通过；`./build.sh` 生成的 ReleaseSafe `zc` 通过同组回归（Zig 0.17.0，libcurl 8.7.1） | 2026-11-16 |
| 04 | 已完成 | bucket list/create/stat/location/remove、object list v2、ls/mb/rb；共享请求层补齐 DeleteBucket | 默认全量分页、逐页释放内存、匿名磁盘暂存后输出单份 JSON；最多 100000 页、token 最多 64 KiB，超限/重复/失败明确报错；仅空桶删除，需 --yes 或 --dry-run；force、ignore-existing、创建时 versioning/lock 暂拒绝；无 AWS 实测 | Zig 单元测试、CLI/alias 子进程测试通过；真实隔离 ZigFS：创建/列举/Head/Location/删除、对象两页与前缀列表、权限和非空保护；独立 HTTP：Bucket 两页、第二页失败、重复 token、DELETE 不重试；Debug/ReleaseSafe 均通过现有 HTTP/TLS 全量回归 | 2026-11-16 |
| 05 | 已完成 | object put/get/stat/show/head；put/get/cat/head/stat、本地↔远端单对象 cp；共享请求层补齐 SHA256 上传字段、metadata/读取响应头；下载原子落盘及显式覆盖 | Get/Head 的 ChecksumMode=ENABLED 返回完整内容 SHA256；自动校验与 --checksum-sha256 HEX 均已真实联调；分段对象按需流式计算摘要，增加一次完整读取。head 行模式有界扫描整个响应；远端复制、stdin、递归、版本及其余校验算法留后续步骤 | Zig 单元/别名注册测试、CLI/alias 子进程测试通过；真实 ZigFS：12 MiB/零字节/长行/特殊 Key、SHA256 上传及错误摘要拒绝、显式摘要下载、metadata、Range、ETag/日期条件、权限、覆盖保护；HTTP fixture：自动校验成功/缺失/不匹配、断流重试后校验和原文件保护；ReleaseSafe 全量及 HTTP/TLS 回归通过 | 2026-11-16 |
| 06 | 已完成 | 同 alias 的 object copy/move、cp/mv，object remove/rm、object remove-batch --file；CopyObject/DeleteObject/DeleteObjects/GetBucketVersioning 接入 s3api | 限未版本化桶；Enabled/Suspended/版本状态读取失败拒绝；文件 1 MiB、最多 1000 个唯一 Key、Quiet=false，无 VersionId；不同 alias 拒绝。mv 非事务，服务端缺少条件 DeleteObject，最终源检查与删除存在并发竞态，使用时须避免并发写入；大批次分块待 08 | Zig 单元与 CLI/alias 测试通过；真实 ZigFS：复制/移动/删除、特殊 Key、metadata REPLACE、源/目标条件、dry-run、权限、1000 项批量及 Enabled/Suspended 拒绝；独立签名 fixture：复制 200 内嵌 Error/缺 ETag 不删除源、对象变化检测、删除源失败明确未完成、批量逐项 Error/缺回执及写请求不重试；ReleaseSafe 全量及 TLS 回归通过 | 2026-11-16 |
| 07 | 已完成 | multipart create/upload-part/parts/list/complete/abort；put/cp 自动分片、--resume、pipe；对应 6 个 S3 operation 共用请求层 | Complete 支持 If-Match/If-None-Match 并在最终发布锁内校验代次，自动分片/pipe 默认防覆盖；仅文件可恢复，stdin 不可恢复；保留 creating/uploading/completing/completed 状态，未知完成结果不自动重试；高级 checksum/tagging/加密/copy-part 留相应后续步骤 | Zig 单元、CLI/alias 子进程、Debug 与本地 ReleaseSafe 全量回归通过；真实 ZigFS：分页分片生命周期、12 MiB/零字节自动上传、空/二进制 pipe；转发真实服务的故障代理：分片响应丢失后恢复、源/布局/远端分片变化拒绝、损坏记录与并发锁、Complete 已生效但响应丢失时拒绝重试；独立签名 fixture：Complete 200 内嵌 Error/缺 ETag、UploadPart 缺 ETag及写请求不重试；TLS 回归通过 | 2026-11-16 |
| 08 | 已完成 | 递归/多源 cp/mv/rm、筛选、并发/限速/共享重试预算、summary；remove-batch 分块；rb --force/--dangerous | mv 限同 alias 远端；下载路径限安全 ASCII；不支持版本化清桶、批量恢复；继承步骤 06/07 的服务端限制；规划最多 100000 项/64 MiB 计量数据 | Zig 单元、CLI/alias 子进程、Debug/ReleaseSafe 集成回归通过；真实 ZigFS：递归往返、分页筛选、冲突/越界/符号链接、移动删除、1001 项分块、强制清桶及待完成上传/版本保护；独立 HTTP：规划失败零写入、并发、共享重试、限速、SIGINT、逐 Key 删除结果汇总 | 2026-11-16 |

步骤 04 使用说明与输出 schema 见 `zigfs-cli/README.md`。列表失败时不输出不完整结果；磁盘暂存空间随结果量增长，内存按单页与有界 token 摘要集合控制。超时按每页请求（含重试）计算。非列表 Bucket 操作暂复用 s3api 输出 envelope；dry-run 只预览，不检查远端存在性/权限。真实对象分页与独立 Bucket 分页 fixture 均已验证，不将 fixture 当作真实服务联调的替代。

步骤 05：上传默认使用 `If-None-Match: *` 拒绝覆盖；覆盖须 `--overwrite --yes`。文件下载仅在传输及所选校验成功后原子发布，失败保留已有目标；cat/head/get 到 stdout 保持原始字节，失败时可能已输出部分正文，错误只写 stderr。上传支持重复 `--metadata KEY=VALUE`、Content-Type 等字段；下载支持 Range/offset/length、ETag 和日期条件。详情与示例见 `zigfs-cli/README.md`。

**步骤 05 服务端回补已完成**：GetObject/HeadObject 的 `ChecksumMode=ENABLED` 返回 Base64 `x-amz-checksum-sha256` 与 `x-amz-checksum-type: FULL_OBJECT`；CLI `get --checksum SHA256` 自动校验通过后才原子发布本地文件，`stat --checksum SHA256` 可读取摘要。普通对象复用已存储的完整明文摘要；分段对象的元数据摘要属于清单，不能冒充内容摘要，因此按需在同一读租约内流式计算完整内容 SHA256，不改存储格式。分段对象的校验 GET 多一次完整读取，校验 HEAD 也需完整读取；未请求校验及 Range 响应不返回该摘要。真实 ZigFS 验证 12 MiB/零字节、未显式上传校验字段的对象、分片及空分片自动下载校验；服务端测试覆盖加密分段对象与指定版本在重启后的摘要。独立故障测试继续覆盖缺失/错误校验头及断流后恢复，失败保留原文件。

步骤 06 用法：`cp/mv ALIAS/BUCKET/KEY ALIAS/BUCKET/KEY`；`rm OBJECT --yes`；`object remove-batch ALIAS/BUCKET --file FILE --yes`。批量文件为 `{"Objects":[{"Key":"a"}],"Quiet":false}`；可用 `--keys-file` 传 JSON 字符串数组。删除/移动须 `--yes`，或 `--dry-run` 只预览。复制默认拒绝覆盖；`--overwrite --yes` 才允许替换。源条件使用 `--source-if-*`，目标条件使用 `--if-match/--if-none-match`；metadata/content 修改须指定 `--metadata-directive REPLACE`。

步骤 06 不将 HTTP 200 等同于业务成功：CopyObject 必须有正确结果根和 ETag；DeleteObjects 必须逐项完整回执，Error 返回非零并保留脱敏逐项结果，缺失/重复回执报告结果不确定。高层输出中批量失败详情位于 `error.cause.error.result`；直接 s3api 位于 `error.result`。写请求不自动重试。移动在复制后验证目标和源，再执行删除；复制完成后的失败报告 `MOVE_INCOMPLETE` 和阶段信息，保留目标，删除请求失败时不能承诺源仍存在。GetBucketVersioning 检查需要相应读取权限，并非原子锁；条件删除/事务性移动仍需服务端能力。CLI 当前范围与限制详见 `zigfs-cli/README.md` 的步骤 06。

步骤 07：`multipart complete --file` 接受 `{"Parts":[{"PartNumber":1,"ETag":"..."}]}`，严格递增、最多 10000 项。`multipart list/parts` 默认完整分页；累积编码页结果最多 16 MiB/10000 页，超限或异常明确失败且不输出不完整列表。原始 s3api 列表仍为单页。UploadPart/Create/Complete/Abort 均不自动重试；完成必须验证结果根和 ETag，不能将 HTTP 200 直接算作成功。

自动上传默认阈值 64 MiB、分片 16 MiB，支持字节/KiB/MiB/GiB、5 MiB–5 GiB 分片、最多 10000 片与 5 TiB 对象；`--part-size/--max-parts/--state-file/--resume` 显式选择分片流程。上传按文件区间流式传输，初始单次扫描绑定完整源 SHA256 和各片摘要，每片发送前核对摘要、Complete 前再次核对完整源。恢复记录默认 `SOURCE.zc-upload.json`，原子写、0600 权限和进程锁，记录源/目标/连接身份/布局/已确认 ETag；恢复须先 ListParts 比对。未确认分片重新上传，已确认分片被改写则拒绝恢复，不把 ETag 当作 MD5。只有 uploading 可恢复；creating/completing/completed 不会自动重新提交。成功保留 completed 记录；源变化、参数变化、未知服务端结果的处理细节见 CLI README。

`pipe` 始终使用分片，以 64 KiB 缓冲读取 stdin，仅临时落盘当前一片，支持空输入；拒绝 `--resume/--state-file/--multipart-threshold`，不会把不可重放的输入伪装成可恢复。失败保留远端待完成上传，报告已知 UploadId；可用 `multipart abort OBJECT --upload-id ID --yes` 显式清理。完整用例、边界和恢复操作见 `zigfs-cli/README.md` 的步骤 07。

**步骤 07 服务端回补已完成**：CompleteMultipartUpload 已接受 If-Match/If-None-Match；先判断请求条件，再把预期对象代次或不存在状态传入最终发布，在对象写锁与元数据锁内校验，避免检查后并发覆盖。条件不满足或观察后目标变化返回 412 PreconditionFailed，不发布新对象，保留待完成分片；条件请求不能通过历史完成回执绕过检查。自动分片/pipe 默认发送 `If-None-Match: *`，显式覆盖仍需 `--overwrite --yes`，可附加 `--if-match` 限定目标 ETag。手动 complete 可显式指定两种条件，不指定时保持 S3 无条件语义；不支持条件的旧服务端明确失败，不退化。恢复指纹包含发布条件，旧格式或覆盖策略变化拒绝恢复；完成结果未知仍不自动重试。服务端应用测试覆盖观察后代次变化与分片保留；真实 ZigFS 回归覆盖缺失/已存在目标、陈旧/匹配 ETag、并发创建/条件替换均仅一个成功、恢复策略变化拒绝、pipe 防覆盖及批量自动分片。

步骤 08：完整用法及输出见 `zigfs-cli/README.md` 的步骤 08。递归源尾部 `/` 表示复制内容，否则嵌套源 basename；多源目标必须是远端 prefix 或已存在的本地目录。include/exclude 支持跨 `/` 的字节通配符 `*`、`?`，exclude 优先；本地下载拒绝非 ASCII、不安全路径、符号链接和大小写冲突。规划完整消费分页并校验后才写入；规划失败 completed=0，dry-run 可读取远端但不修改。最多扫描/执行 100000 项，路径/任务/token 计量数据最多 64 MiB（不含分配器与 JSON/map 开销），深度最多 128。

并发 1–32，默认 1；分波调度，默认失败停止后续波次，已启动任务可完成。`--continue-on-error` 不改变最终失败状态。`--retry-attempts N` 的 N−1 次重试由整个批量命令共享（含规划），仅 GET/HEAD 重试。限速按配置 worker 数及收发两方向均分，空闲额度不重分配，不限制服务端内部复制流量。Ctrl+C 返回 130，停止调度并取消 HTTP，但已提交写操作结果可能不确定。

批量输出单份 summary；planned/completed/failed/not_started 以任务计数，一个最多 1000 Key 的删除分块是一个任务；delete_confirmed/delete_failed/delete_outcome_unknown 按 Key 计数。known_object_bytes 不是网络流量。错误保留最多 1000 项/8 MiB，单项详情超过 1 MiB 明确截断。remove-batch 现支持最多 100000 Key/64 MiB 输入；不超过 1000 项且无显式批量控制时仍保留步骤 06 的 1 MiB 限制和输出格式。

`rb --force --yes` 仅清理未版本化桶；存在待完成分片时必须额外指定 `--dangerous`（隐含 force），规划时即检查，任一中止/删除失败均不删桶。拒绝 Enabled/Suspended/未知/不可读版本状态。批量移动仍非事务，自动分片默认条件防覆盖，显式替换要求 `--overwrite --yes`；批量恢复、版本化清理未开放。本地目录、远端对象及桶版本状态在操作期间应保持稳定，预检查不提供锁或快照。所有上述验证由自动化完成，无需用户逐条手测。

后续执行从 **步骤 09（预签名分享与 POST Policy 上传）** 开始；每次任务应指定步骤编号或命令范围，避免把整份规划一次性标记为完成。

### 4.9 自动化自测责任与环境边界

CLI 常规开发由实现者完成自动化自测后交付，默认不要求用户逐条手动测试；实现者负责准备隔离环境、运行测试、修复失败并记录证据。

| 测试层级 | 必须验证的适用内容 |
|---|---|
| 单元测试 | 参数解析、签名、配置读写、序列化、错误映射 |
| 可执行文件测试 | 实际启动 zc，检查退出码、stdout/stderr、JSON、非交互行为及敏感数据脱敏 |
| 真实服务集成测试 | 自动启动隔离 ZigFS 实例，验证上传/下载/删除、权限、版本、分片等已实现工作流 |
| 异常与恢复测试 | 超时、连接中断、进程中断、恢复、权限拒绝、部分失败及危险操作确认 |

- 纯本地步骤（如帮助、alias 配置）使用独立临时配置目录和测试凭据，不要求启动无关服务；网络业务步骤必须验证真实 ZigFS，不以 mock 通过代替集成测试。
- 测试数据目录、端口、Bucket 和凭据与用户环境隔离。仅清理由测试创建且明确归属的资源，不读写用户现有凭据，不删除真实数据；产物和日志不得泄漏密钥。
- 有交互的终端流程优先用 PTY 自动化验证，不能直接将人工操作作为默认验收方式。
- 真实 AWS、第三方 OIDC/KMS、浏览器交互登录等依赖外部环境或凭据。条件不具备时记录未验证范围、原因和补测条件；可以继续独立工作，但不能把受阻能力标为完整验收通过。
- 每次交付说明已运行的测试及结果、实际服务/工具链版本、未覆盖项和限制。自动化测试通过不代表不存在任何缺陷；mock、真实 ZigFS 和外部服务结果分别登记。

## 5. 文档与实现时的注意点

1. **30 项是 RustFS CLI README 的 command overview 数量，不是全部 CLI 命令数**，也并非 30 个纯 S3 API；其中 `admin`、`ping`、`ready`、`du`、`completions` 等属于管理/运维/本地 CLI 功能。
2. RustFS 新文档推荐 `rc bucket` 与 `rc object` 这类 noun-first 入口；其旧式命令如 `rc mb`、`rc cp` 是 legacy-compatible forms。ZigFS 可以设计 `zc bucket create` / `zc object copy` 为规范命令，并用 `zc mb` / `zc cp` 作为 alias。
3. 对于每个参数，应在 ZigFS 实现中区分：CLI parser 参数、S3 HTTP query/header、JSON/XML request body、ZigFS Admin API 参数。
4. 不支持的 S3 API 应返回可解释错误（例如 `NotImplemented`），不要伪装成功。
5. 所有危险操作（删 bucket、mirror 删除目标、KMS 立即删 key、服务停止等）应具备 `--dry-run` 或明确确认机制。
6. 文档中的某些 options 是 RustFS 当前 CLI 的实际 options，另一些已明确标注为 ZigFS 设计建议/扩展，编码时勿将二者误认成上游完整原样。

### 5.1 实现与发布验收

每个上线命令须登记：规范入口与别名、参数/互斥项、后端 API 与权限、输出 schema、退出码、分页和部分失败规则、危险操作确认、服务版本限制及测试位置。

- parser 测试：全局参数前后置、`--`、非法组合、缺少参数、路径歧义、子命令帮助。
- 协议与鉴权测试：签名、Session Token、最小权限与显式 Deny、编码、分页、错误映射、敏感值脱敏。
- 工作流测试：上传/下载/复制/移动、版本选择、multipart 中断恢复、网络失败后的未知结果、批量部分失败。
- 自动化测试：非 TTY 不等待输入、JSON/JSONL 可解析、stdout/stderr 分离、稳定退出码。
- 变更前 dry-run 不写入；删除/覆盖只发生在明确目标范围内。验证记录须区分 mock、真实 ZigFS 与上游兼容测试。

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

### 补充详细参考与实施时复核入口

以下均为可变 `main` 分支；正式实现时应记录具体 commit/tag，并在版本升级时复核兼容差异。

- [Alias](https://github.com/rustfs/cli/blob/main/docs/reference/rc/alias.md)
- [Copy](https://github.com/rustfs/cli/blob/main/docs/reference/rc/cp.md)
- [Lifecycle](https://github.com/rustfs/cli/blob/main/docs/reference/rc/ilm.md)
- [Retention](https://github.com/rustfs/cli/blob/main/docs/reference/rc/retention.md)
- [Legal Hold](https://github.com/rustfs/cli/blob/main/docs/reference/rc/legalhold.md)
- [S3 Select](https://github.com/rustfs/cli/blob/main/docs/reference/rc/sql.md)
- [Encryption](https://github.com/rustfs/cli/blob/main/docs/reference/rc/encryption.md)
- [JSON 输出契约](https://github.com/rustfs/cli/blob/main/docs/reference/rc/output.md)
- [mc 兼容范围](https://github.com/rustfs/cli/blob/main/docs/reference/rc/mc-compatibility.md)

### S3 覆盖基线

- [AWS S3 API 操作目录](https://docs.aws.amazon.com/AmazonS3/latest/API/API_Operations_Amazon_Simple_Storage_Service.html)
- [本次核对的 botocore S3 操作模型](https://github.com/boto/botocore/blob/develop/botocore/data/s3/2006-03-01/service-2.json)
- [Browser POST Object](https://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPOST.html)
- [POST Policy](https://docs.aws.amazon.com/AmazonS3/latest/API/sigv4-HTTPPOSTConstructPolicy.html)
