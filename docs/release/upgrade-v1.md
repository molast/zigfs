# V1 升级运行手册

本手册用于把已有 ZigFS V1 数据根切换到 `v0.1.0-rc.1`。V1 不执行在线迁移，升级边界是
完整数据根的备份和新进程启动验证。

## 升级前

### 支持元数据检查点的版本

包含元数据自动维护的版本在启动恢复完成后会写入检查点并启用格式 required-feature
flag bit 0，随后回收历史 journal 与已结束 multipart 标记。这是恢复协议升级：即使
没有接收新的业务写入，首次启动也可能改变回退边界。务必先停机备份完整数据根。
主版本仍为 1，但不支持该 feature flag 的历史二进制会以 `UnsupportedFlags` 拒绝打开。
不要清除 flag 或删除 `checkpoint.meta`；需要回退时恢复升级前完整备份。

1. 记录当前服务版本、配置文件摘要、数据根路径和最近一次健康状态。
2. 停止 Admin 写操作和所有 S3 写入，确认没有 Multipart 上传仍在进行。
3. 优雅停止旧 ZigFS，确认旧进程已释放 `.zigfs/instance.lock`。
4. 对整个 `ZIGFS_DATA_ROOT` 做静态备份，保留权限、时间、稀疏文件和隐藏目录。

```bash
rsync -a --numeric-ids data/ /backup/zigfs-v1-before-rc1/
```

备份后应离线保留 `format.meta`、全部 `metadata/`、`.zigfs/journal/`、`objects/`、
`.zigfs/system/credential-master.key`，并记录备份校验结果。

## 启动新版本

1. 使用 RC 二进制和原有 `ZIGFS_DATA_ROOT` 配置启动隔离实例；首次验证建议使用隔离端口。
2. 等待 `/health/ready` 返回 `200`。如果返回 `503`，先读取 `recovery_required` 原因，
   不删除或手工修改数据文件。
3. 验证 Bucket/Object 数量、对象大小、ETag、Range、Multipart 状态和 Credential 解密。
4. 只读验证通过后，再切换生产端口或流量。

示例：

```bash
./zigfs --env-file /secure/zigfs/rc.env
curl --fail http://127.0.0.1:19000/health/ready
```

使用已有凭证执行 S3 Head/Get/List；使用 Management Token 执行 Bucket、Storage、System
和 Health 只读请求。不要在升级验证期间创建或删除生产对象。

## 兼容与拒绝矩阵

| 检查 | 预期 |
|---|---|
| `format.meta` 主版本 `1` | 允许打开 |
| 已知 Payload minor 小于或等于当前版本 | 兼容读取 |
| 未知主版本 | 启动失败，文件保持不变 |
| 未来 Payload minor | 读取失败，服务保持 Not Ready |
| checksum、长度、Magic 或 Master Key 错误 | 启动失败或 `recovery_required` |
| 索引目录丢失 | 全量重建，不影响事实数据 |

没有自动迁移脚本，也不能把新版本启动失败归因于“索引需要清理”。保留原目录和日志，
按 [回滚手册](rollback-v1.md) 恢复。

## 升级完成标准

- `/health/live` 和 `/health/ready` 成功。
- S3 Head/Get/List、Range 和至少一个 Multipart 只读检查通过。
- Management Health、Storage、System 和 Settings 返回预期脱敏信息。
- 旧版本备份可在隔离数据根启动并通过相同只读检查。
- 记录 RC 服务版本 `0.1.0`、配置摘要、备份位置和验证时间。
