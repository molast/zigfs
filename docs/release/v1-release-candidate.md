# ZigFS 0.1 Release Candidate

## 发布身份

| 项目 | 值 |
|---|---|
| Release Candidate 标签 | `v0.1.0-rc.1` |
| ZigFS 服务版本 | `0.1.0` |
| ZigFS 磁盘格式主版本 | `1` |
| Management API OpenAPI 版本 | `1.0.0` |
| SDK 共享向量 | `v1`, `vector_revision: 2` |
| 发布日期 | `2026-09-07` |

`v0.1.0-rc.1` 是 0.1 系列的候选版本，不是正式 `1.0.0`。服务启动日志、Management
System API 和 Admin 页面显示的版本仍是 `0.1.0`。磁盘格式、API 契约和 SDK 契约中的
`V1`/`1.0.0` 是各自独立的兼容版本，不代表 ZigFS 服务已经进入 1.0。

## 发布内容

发布包至少包含：

- `zigfs/zig-out/bin/zigfs`：ZigFS S3/Data、Management 和 Health 服务。
- `zigfs/config.example.yaml`：带默认值的 YAML 配置模板。
- `zigfs-admin/server` 与 `zigfs-admin/web/dist`：可选的 Admin BFF 和 Web Console。
- `docs/api/`、`docs/operations.md`、`docs/backup-and-recovery.md` 和本目录的发布材料。

发布包不得包含真实 `config.yaml`、Access Key、Secret Key、Session Token、测试报告中的
凭证，或 `.docs/` 文件。ZigFS 不创建或依赖 SQLite、数据库文件或外部元数据服务。

## 构建与验证

在仓库根目录执行：

```bash
cd zigfs
zig build -Doptimize=ReleaseSafe
zig build test

cd ../zigfs-admin/server
go test ./...
go build -trimpath -o ../../dist/zigfs-admin ./cmd/admin

cd ../web
pnpm install --frozen-lockfile
pnpm run build
```

SDK 一致性和外部客户端矩阵：

```bash
cd ../..
./conformance/run.sh
./compatibility/run.sh
```

Benchmark 只用于记录当前环境基线，不作为脱离硬件、构建模式和并发度的性能承诺：

```bash
node benchmarks/run.mjs --profile smoke --output /tmp/zigfs-v0.1.0-rc.1-benchmark.json
```

所有输出报告都应检查是否包含凭证，并将报告写入发布目录之外的临时路径。

## 全新数据目录

1. 复制 `zigfs/config.example.yaml` 到受限权限目录，修改管理员密码、Session Secret、
   `storage.data_root` 和客户端实际可访问的 `s3.public_endpoint`。
2. 确认 `server.api_address`、Metrics 地址和 Admin 地址没有端口冲突。默认端口为：
   `9000` S3/Management/Health、`9001` Admin、`9090` Metrics。
3. 启动 ZigFS；首次启动会创建完整数据根、`format.meta`、实例身份和 Credential Master Key。

```bash
cd zigfs
./zig-out/bin/zigfs --config /secure/zigfs/config.yaml
curl --fail http://127.0.0.1:9000/health/ready
```

也可以使用根目录的 `./start.sh`；选择 Admin 时脚本会先确认 ZigFS Ready，再启动 Admin。
Admin 退出时不会停止启动脚本之前已经存在的 ZigFS。

## 已有 V1 数据目录

V1 数据目录是整个 `storage.data_root`，包括：

- `metadata/`：Bucket、Object、Multipart、Credential 版本化记录。
- `.zigfs/journal/`：Intent、Commit、Abort Journal。
- `objects/`：按 Data Generation 保存的对象数据。
- `.zigfs/system/`：格式信息、实例身份和 `credential-master.key`。
- `.zigfs/indexes/`：可丢弃加速层，启动时总是从 Metadata 全量重建。

RC 的启动行为如下：

| 数据状态 | 行为 |
|---|---|
| 已有 V1、已提交记录完整 | 直接打开并重建索引，不执行迁移脚本 |
| Object/Credential 已知旧 minor（例如 V1.0） | 按兼容读取规则加载，缺省新增字段使用兼容值 |
| 未知磁盘主版本 | 拒绝启动，原始文件不覆盖 |
| 未来 Object/Credential Payload minor | 拒绝读取并保持 Not Ready |
| Magic、长度、checksum、Journal 或 Master Key 损坏 | 启动失败或进入 `recovery_required`，不自动修复 |
| 只有 `.zigfs/indexes/` 丢失或损坏 | 丢弃索引并从事实数据重建 |

V1 没有跨版本自动迁移。启动不会把未知格式转换成当前格式，也不会为了绕过错误删除
Metadata、Journal、Object Data 或 Master Key。格式和 Payload 的兼容边界以实现和
`docs/backup-and-recovery.md` 为准。

## 升级与回滚

升级前必须停止写入并备份整个 `storage.data_root`，不能只复制 `objects/` 或 `metadata/`。
详细步骤见：

- [V1 升级运行手册](upgrade-v1.md)
- [V1 回滚运行手册](rollback-v1.md)
- [备份与恢复](../backup-and-recovery.md)

升级失败时保留失败目录和日志，将完整备份恢复到新的数据根，用旧版本二进制和原配置启动。
在 `/health/ready`、S3 Head/Get/List 和 Management 只读接口验证前，不切回生产流量。

## 发布前安全边界

- 只在受限权限下保存 YAML 配置和 Master Key。
- 不把 AK/SK、Session Token、管理员密码或 Session Secret 写入日志、Benchmark 或兼容性报告。
- Release Candidate 仍建议在隔离网络中运行；对外部署前必须更换所有默认管理员配置。
- Admin 是可选网页客户端；移除 Admin 不影响 ZigFS S3/Data 和 Management API。
