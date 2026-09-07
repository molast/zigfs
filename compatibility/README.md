# ZigFS 外部客户端兼容性 Runner

`run.sh` 启动一个隔离的 ZigFS 实例，通过 ZigFS Management API 创建临时 AK/SK，然后执行
AWS CLI、MinIO Client (`mc`)、rclone 和原生 Node HTTP 的 S3 回归。Runner 不启动 Admin，
也不会把 Access Key、Secret Key 或 Session Token 写入 JSON/Markdown 报告。

```bash
./compatibility/run.sh
```

默认会检测 PATH 中的 `aws`、`mc` 和 `rclone`。缺失客户端记为 `Skipped`；客户端命令不支持
某个 S3 能力记为 `Unsupported`；协议、状态码或内容校验错误记为 `Failed`。报告默认写入
`compatibility/reports/latest.json` 和同名 `.md` 文件，该目录已加入 `.gitignore`。

常用参数：

```text
--client aws|mc|rclone|http|aws-sdk|all
--endpoint http://127.0.0.1:9000
--data-root /path/to/data
--report /path/to/report.json
--skip-start --access-key AK --secret-key SK
--keep-data
```

自动启动模式使用临时 YAML，默认监听 `127.0.0.1:19080`，成功后删除数据目录；失败时保留
ZigFS 日志到 `<report>.zigfs.log`。`--skip-start` 适用于已经运行的 ZigFS，但必须显式提供
AK/SK（也可以使用 `ZIGFS_ACCESS_KEY`、`ZIGFS_SECRET_KEY` 和 `ZIGFS_SESSION_TOKEN`）。

每个客户端的测试包括 Bucket 创建/删除、Object 上传/下载、内容校验、List、Head、
Presigned GET、CopyObject，以及客户端可用时的批量删除或 Multipart 路径。原生 HTTP 还覆盖
SHA256 Flexible Checksum Header；signed streaming Trailer、POST Policy 和没有稳定 CLI 入口
的能力会单独记录为 `Unsupported`，不会伪造 `Passed`。

报告中的 `command` 字段只包含可复现命令和临时文件路径，不包含凭证；`server.config` 记录
实际使用的 endpoint、Region、metrics、缓冲区和数据根模式。报告 schema 为
`phase9-compatibility-v1`，可由 CI 读取 `status`、每个 client 的 `tests[].status` 和
`reason/error` 字段。
