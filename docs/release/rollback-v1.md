# V1 回滚运行手册

回滚用于 RC 启动失败、恢复状态异常或只读校验不通过的情况。回滚以完整数据根为单位，
不能只恢复 `objects/`、`metadata/` 或索引目录。

## 步骤

1. 立即停止 S3 写入、Admin 操作和流量导入。
2. 停止 RC ZigFS，保留 RC 的完整日志、进程输出和失败数据目录，不在原目录上反复尝试。
3. 将失败目录重命名或复制到独立的诊断路径，确保它仍包含所有原始文件。
4. 将升级前的完整备份恢复到新的数据根，例如 `/srv/zigfs-rollback/data`。
5. 使用旧版本 `zigfs` 二进制、原版本配置和新的 `storage.data_root` 启动。

```bash
./zigfs-previous --config /secure/zigfs/rollback-config.yaml
curl --fail http://127.0.0.1:19000/health/ready
```

6. 通过 S3 Head/Get/List、Range 和 Multipart 只读检查，以及 Management Health、Storage、
   System 检查恢复结果。
7. 验证通过后再切换生产端口；保留 RC 失败目录、日志和备份审计记录。

## 不要做的操作

- 不要删除 `.zigfs/journal/`、`.zigfs/system/credential-master.key` 或单条 Metadata 记录。
- 不要用空的 `format.meta` 覆盖原格式文件。
- 不要把旧版本直接启动到未经验证的 RC 数据目录，也不要混用两套版本的配置。
- 不要在恢复前让 Admin 或客户端重新开始写入。

如果完整备份本身无法启动，服务必须保持 Not Ready；保留两套目录并进入离线恢复流程，
不要尝试通过删除文件绕过格式或 checksum 错误。

## 回滚完成标准

- 旧版本以独占锁启动，`/health/ready` 返回 `200`。
- 关键 Bucket/Object 的数量、大小、ETag 和可读性与备份记录一致。
- Master Key 可解密 Credential，旧版本能继续验证已存在的 AK/SK。
- 记录使用的旧版本、数据根、备份校验、验证命令和恢复时间。
