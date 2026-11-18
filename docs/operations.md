# ZigFS 运维手册

## 启动与就绪

生产环境应以前台进程或进程管理器运行 ZigFS，并将 `.env` 以受限
权限保存。推荐先检查：

```bash
curl --fail http://127.0.0.1:9000/health/live
curl --fail http://127.0.0.1:9000/health/ready
curl --fail http://127.0.0.1:9090/metrics
```

`live` 只代表进程和事件循环存活。`ready` 只有在格式、实例锁、存储写探针、
Journal 回放、Metadata 扫描、索引重建和密钥可用时才返回成功。启动时写探针会
创建并同步 `.zigfs/tmp/storage-ready.probe`，随后删除并同步父目录；初始化阶段
失败会返回 `StorageNotWritable` 并阻止 HTTP 服务进入 Ready。运行期的写入错误则
通过稳定的 `Unavailable`/`ServiceUnavailable` 语义返回，不能把成功响应伪装成持久化。

## 网络变更

Network 支持保存 Public URL、寻址模式、可信代理和服务监听配置。
监听地址、端口需要重启对应进程；其他网络项即时生效。
修改端口后还需核对 Public URL、代理上游、容器映射和健康检查地址。

具体流程及无法登录时的恢复步骤见 [网络配置](network-settings.md)，
常见拓扑和 Nginx 参考见 [网络部署](deployment/network.md)。

## 数据目录

`ZIGFS_DATA_ROOT` 是 ZigFS 唯一事实来源：

- `.zigfs.sys/` 保存 metadata-engine 的 WAL、快照和引擎锁，直接位于数据根下。
- `objects/` 和 `multipart/` 保存对象及上传分片实体。
- `.zigfs/format.meta` 保存数据根格式和实例身份；`.zigfs/system/` 等目录保存密钥与业务配置。
- 业务查询索引在启动时从引擎重建，不再创建旧 `.zigfs/indexes/`。
- `.zigfs/trash/` 保存 GC 已移出命名空间的待删除数据，启动继续清理。

不要手工编辑 `.zigfs.sys/`、密钥或对象文件。旧开发库不兼容，停止实例并清空专用数据根后重建。
完整备份与元数据在线备份的边界见 [备份与恢复](backup-and-recovery.md)。
第二个 ZigFS 进程不能共享同一个数据根目录。

对象删除、悬垂数据、过期 Multipart 和 16 分片 Scanner 的完整语义见
[存储扫描与文件清理架构](../zigfs/docs/storage-reclamation.md)。Admin Storage 页面可查看最近扫描
结果并触发一次完整 GC；不要手工删除物理数据文件。

## 监控与告警

Prometheus 只连接独立 Metrics Listener。至少监控 `zigfs_ready`、请求错误率、请求
延迟、恢复状态和进程 RSS。`/health/ready` 连续失败时停止流量导入，检查日志中的
`recovery_required` 原因；不要通过删除数据文件来“修复”损坏状态。

## 变更与升级

修改端口、数据根、Region、流缓冲区或 Multipart 过期时间前，先保存配置和当前
版本信息。V1 不自动迁移未知磁盘主版本；升级前必须按照备份文档制作可验证副本。
对象数据和 Metadata 的 fsync、Checksum、Metadata Commit 和 Journal 语义不能因
性能调优而关闭。

0.1 Release Candidate 的完整升级、拒绝和回滚步骤见
[docs/release/v1-release-candidate.md](release/v1-release-candidate.md)、
[升级运行手册](release/upgrade-v1.md) 和 [回滚运行手册](release/rollback-v1.md)。

## 故障排查

- `StorageNotWritable`：检查路径权限、挂载模式、容量和 inode；确认目录未被同名
  文件占用后再重启。
- `recovery_required/corrupt_journal`：保留原始目录和日志，停止写流量，按备份
  恢复或人工审计 Journal。
- `recovery_required/corrupt_record`：不要删除单条记录；恢复最近一个完整备份。
- GET 返回 `CorruptData`：Metadata 仍可能完整，但对应 Data Generation 缺失或
  checksum 不匹配，应从备份恢复对象数据并重新校验。

## Managed policy documents

ZigFS owns the policy collection in metadata-engine (`policy` namespace, key `system/policies.json`).
On first access, an absent collection is seeded atomically from the eight JSON
documents embedded from `zigfs/resources/policies/`. An existing collection,
including an empty one, is never reseeded: edits and deletions survive restart.
Include the engine in backups. Do not edit engine files to clear policies; use
the authenticated Management API instead.

Admin forwards list/get/create/update/delete through `/api/v1/policies` to
`/_admin/v1/policies`. POST creates; PATCH updates a named policy; DELETE removes
it. Names cannot be changed and duplicates return 409. Writes use a business mutex and
the shared metadata-engine durable commit queue. Documents
are limited to 256 KiB and the collection to 16 MiB. Concurrent updates use
last-write-wins semantics.

These endpoints manage JSON documents and identity assignments. IAM statements
are not interpreted in S3 authorization; existing credential permission checks
remain authoritative. Deleting an assigned policy returns 409 `PolicyInUse`;
unassign it from all users and groups first.


## Managed users and groups

`/_admin/v1/users` and `/_admin/v1/groups` provide list/create operations;
`/{name}` provides get/update/delete. The BFF forwards the same paths under
`/api/v1`. All routes require an authenticated administrator session. PATCH
replaces the full record, names cannot be changed, and duplicate names return
409. Names are 1–128 ASCII letters/digits/`_.-`; descriptions are at most 1024
UTF-8 bytes. A user/group can have up to 1024 unique policy assignments, and a
group up to 1024 unique members. References must exist in ZigFS.

ZigFS persists both collections atomically in
metadata-engine (`identity` namespace, key `system/identities.json`), with a limit of 10,000 users and
10,000 groups and 16 MiB total. Both collections are included in engine backups.
An absent record starts empty; a corrupt record returns a storage error
and is never replaced with an empty collection. Writes and policy-reference
checks use the same mutex as policy management and last-write-wins semantics.
Deleting a user removes its group memberships in the same atomic replacement;
deleting a group preserves all users.

Managed users do not grant Admin login. User access keys are managed through
`/users/{name}/access-keys` in the BFF and Management APIs. ZigFS persists them
in the existing encrypted credential store, with the reserved owner namespace
`user:<name>` so a managed user cannot collide with an administrator tenant.
The generic access-key list excludes these user credentials. User-scoped list
and update responses never return Secret Key or Session Token; save them from
the create response. Creation ignores any body-supplied owner and requires an
enabled, existing user. Scoped updates/deletes reject another user's key.

Disabling a user rejects subsequent S3 authentication with any of its keys;
re-enabling restores otherwise active, unexpired keys. Delete all keys before
deleting a user (otherwise HTTP 409 `UserAccessKeysExist`), preventing an old
key from being inherited by a recreated username. Missing/corrupt identity
storage fails closed for user credentials. The user namespace is also the S3
bucket ownership boundary; administrator buckets are not implicitly shared.

Credential creation accepts optional custom `access_key` (16–128 alphanumeric
characters), `secret_key` (32–64 printable ASCII characters), `name` (128 UTF-8
bytes), `description` (1024 UTF-8 bytes), `inherit_policy`, and a future UTC
`expires_at`. Duplicate live AKs return 409. Secrets remain encrypted in ZigFS;
all lists redact SK and session token. Omitted AK/SK are securely generated.
`expires_at` creates a dated AK/SK without a session token or 12-hour limit;
legacy `ttl_seconds` (60–43200) still creates temporary token credentials.
The two expiration inputs are mutually exclusive. The UI accepts a date and time to the minute in the browser timezone and submits
the corresponding UTC timestamp. It does not round expiry to the end of the day.

With inheritance enabled, administrator keys use administrator permissions;
managed-user keys dynamically combine directly assigned policies with policies
of enabled groups. Every authentication reloads current assignments/documents.
Allow/Deny, Action and Resource strings/arrays, and `*`/`?` matching are supported;
explicit Deny overrides all Allows, and no matching Allow denies access.
Resource checks cover normal/versioned objects, copy sources, multipart
operations, POST uploads, batch deletions and presigned requests. Existing tenant
ownership boundaries still apply. Statements may be a single object or an array;
`NotAction`, `NotResource` and policy variables such as `${aws:username}` are supported.

IAM `Condition` supports String/Arn equality and wildcard comparisons (including
negation and case-insensitive strings), Numeric/Date comparisons, Bool, Null,
IPv4/IPv6 CIDR, BinaryEquals, IfExists and ForAnyValue/ForAllValues. Different
operators/keys are ANDed; positive expected values are ORed, negative values NORed.
Explicit conditional Deny overrides Allow, including across inherited policies.

Request context includes username/userid, principal type, socket source IP, current
time/epoch, requested region, user agent/referer, authentication type, signature
version/age, list prefix/delimiter/max-keys, version ID, supported S3 request headers,
and request object tags. See `auth/iam_policy.zig::supportedKey` for the exact list.
Source IP comes from the accepted connection. The current HTTP listener reports
`aws:SecureTransport=false`; X-Forwarded-For/Proto cannot override these facts.
Presign generation defers conditions; consuming the signed URL evaluates them
against the actual S3 request. Identity policy endpoints reject Principal and
NotPrincipal (resource/trust policies), unknown operators and unavailable context
keys on save. Existing object tags, TLS version, AWS organization/role/session
context are not yet provided; this is not full AWS/MinIO IAM compatibility.
When inheritance is off, the parent user and enabled-group permissions still apply;
the credential policy/coarse bits can only restrict that parent authorization. User
enabled status is enforced regardless of the setting.

Credential metadata payload V1.3 atomically stores labels, inheritance, expiry,
and per-key JSON policy with the encrypted credential. V1.0/V1.1 records remain
readable with empty labels and inheritance disabled; V1.2 records preserve their
metadata and default to no key policy. After writing V1.3, older binaries cannot read those
records; back up data before upgrade and do not downgrade the binary alone.


User creation now requires a password of 8–1024 UTF-8 bytes. ZigFS stores only
an Argon2id PHC hash (interactive parameters, independently generated salt).
Neither password nor hash appears in list/get/create/update responses. Omit
`password` on PATCH to preserve the stored hash. Existing identity files with
no password hash remain readable. This does not enable identity-based login
or change S3 authorization.

`groups` on user create/update replaces group memberships atomically with the
user record; omitted groups preserve memberships and an empty array clears
them. Group records remain the membership source of truth. `updated_at` is
server-generated Unix time in seconds and changes when the record or membership
changes; legacy records without a known time return zero (shown as `—`).
Bulk UI operations call existing authenticated endpoints, merge memberships or
policies into the latest group record, and report partial failures through toast.


Access-key PATCH supports sparse changes to `name`, `description`, `enabled`,
`inherit_policy`, `expires_at`, `clear_expiry` and `policy_document`; omitted fields
are preserved. AK and SK remain immutable. Empty `policy_document` removes the
key-specific restriction; a valid document with an empty Statement denies all.
A configured key policy intersects inherited permissions, so it cannot widen the
parent policy. Without inheritance, a configured JSON policy replaces the coarse
permissions. Unsupported IAM constructs fail closed as described above.

Both access-key creation flows use the same shadcn/ui form and one-time secret
result dialog, with copy and JSON credential download. The main list includes
search, sorting, selection, pagination, Edit and Delete. Edits submit changed
fields only and retain draft data on failure; all feedback uses top-center toast.

## About page telemetry and release checks

The About page reads build metadata and process telemetry through ZigFS's
`/_admin/v1/system` and the Admin BFF. Build time, Git commit, Zig compiler version,
target OS/architecture and build mode are embedded in the ZigFS binary. Source
archives without `.git` can supply `zig build -Dgit-commit=<commit>`; otherwise the
commit is unavailable rather than fabricated. Rebuild and restart ZigFS to expose
these new fields, and rebuild/restart the BFF and web client after upgrading.

On Linux and macOS, memory is the ZigFS process's current RSS (not peak usage or
BFF memory). CPU is the delta of process CPU seconds divided by monotonic elapsed
seconds between 5-second samples. 100% means one core; multi-core usage may exceed
100%. The first sample displays “Sampling”; unavailable measurements remain
unavailable. No direct reads of the ZigFS data directory are performed by Admin.

“Check for updates” queries `https://api.github.com/repos/molast/zigfs/releases/latest`
from the BFF with a 10-second timeout. It compares the running ZigFS version with
the latest published stable release and links to its release notes; it does not
install updates. An SSH Git remote (`git@github.com:molast/zigfs.git`) refers to the
same repository, but release checks use GitHub's HTTPS API, not SSH credentials.
For private repositories or API rate limits, set `ZIGFS_RELEASE_TOKEN` in the BFF
environment to a GitHub token with read access to that repository. The token is
never returned to the browser. A missing release, inaccessible repository, rate
limit or network failure is reported as a failed check, not “up to date”.

## Runtime health diagnostics

`/_admin/v1/health` (BFF `/api/v1/management-health`) now includes `diagnostics`.
It retains the existing `admin:ServerInfo` authorization, including restricted
monitoring accounts. Admin never probes or reads the ZigFS data directory itself.

- `storage` probes the opened data directory using `fstat` and `fstatvfs` on Linux
  and macOS, including the mount's read-only flag. Counts describe the configured
  data filesystem, not all physical disks. An inaccessible/removed directory is
  offline; unsupported platforms report unknown/null. This is not a SMART,
  permission or write-integrity test.
- `metadata` reports initialization/recovery readiness and the live index's bucket,
  object-entry and directory counts under the index mutex. Listing counters cover
  the shared object listing service used by Management and S3, including invalid
  listing requests. No completed listing means null last-result/latency. These
  counters do not certify every stored object's integrity.
- `http` measures API connections and actual S3/management request activity.
  Failed request counts mean 5xx responses or handler/transport errors, not 4xx.
  Connection rejection counts measure runtime scheduling failures. There is no
  invented capacity limit, queue utilization or independent metacache. Monitoring
  requests themselves appear in management activity; health/metrics probes do not.

All counters reset when ZigFS restarts. The UI refreshes every 30 seconds, shows
unknown when diagnostics are unavailable, and flags offline/read-only storage,
unready metadata or a failed scanner instead of showing a green healthy summary.
The existing top-level health fields still report recovery readiness.

## Account and bucket summary status

Session responses now include nullable `account_enabled`, read from the local
IAM identity snapshot during session authorization. This requires no user-list
permission. Disabling/deleting a local user invalidates its session; the next
session check returns 401. Deployment root, OIDC and STS responses return null
and the account page names the applicable management source instead of claiming
that an external/local account is enabled. Older servers with no field show
unknown for local account status.

Bucket details load configuration, inventory and usage independently. Unavailable
configuration is shown as unknown, never Private or disabled; unavailable usage
is not shown as zero. Refresh clears previous values, and bucket navigation
remounts the details view so another bucket's data cannot appear in the summary.
