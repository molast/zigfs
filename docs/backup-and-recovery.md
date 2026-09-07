# 备份与恢复

## 备份边界

ZigFS 不使用 SQLite 或外部元数据数据库。`storage.data_root` 下的 Metadata、Journal、
Object Data、格式信息、实例身份和 Master Key 共同组成一个一致性备份单元，不能只
备份 `objects/` 或只备份 `metadata/`。

## 推荐流程

1. 停止写入并确认 `/health/ready` 可访问，最好停止 ZigFS 以得到静态目录快照。
2. 将整个 `data_root` 复制到独立介质，保留文件权限、时间和稀疏文件属性。
3. 对副本做离线校验，并记录 ZigFS 版本、配置摘要、备份时间和存储容量。
4. 将副本恢复到新的数据目录，先以隔离端口启动并确认 `/health/ready`。
5. 用 S3 Head/Get、List 和管理只读接口核对 Bucket/Object 数量、大小和 checksum，
   验证无误后再切换流量。

Release Candidate 升级前后的具体命令和回滚边界见
[V1 升级运行手册](release/upgrade-v1.md) 与 [V1 回滚运行手册](release/rollback-v1.md)。

示例（停止服务后执行，目标路径必须是专用目录）：

```bash
rsync -a --delete data/ /backup/zigfs/$(date +%Y%m%d-%H%M%S)/
```

备份工具不应跳过 `.zigfs/system/credential-master.key`。该密钥丢失时，Credential
Secret 无法解密，即使 Object Data 仍在也不能恢复鉴权。

## 恢复语义

- 启动会校验格式文件、实例锁、Master Key、Journal 和全部已提交 Metadata。
- 未完成 Intent 会按 Journal 规则补全或回滚；暂存文件会被清理。
- `.zigfs/indexes/` 删除或内容损坏不会影响事实数据，启动会全量重建。
- 缺失或 checksum 错误的 Object Data 不会被静默替换；对应 GET 返回 `CorruptData`，
  GC 也会报告引用数据丢失。
- 不支持跨版本自动迁移未知主版本。恢复到新版本前必须先阅读对应 ADR 和发布说明。

## 不可恢复情况

如果 Metadata 或 Journal 本身损坏，服务会保持进程存活但 Not Ready。保留原始目录，
不要删除记录、Journal 或 Master Key 试图绕过恢复；使用最近的完整备份，之后再通过
S3/API 校验增量数据。
