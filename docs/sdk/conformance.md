# 文件 SDK 一致性测试

- **契约版本：** V1.0
- **共享向量：** `conformance/fixtures/v1.json`
- **更新日期：** 2026-09-07

一致性测试分为不依赖服务的共享向量测试和连接隔离 ZigFS 的端到端测试。实现只有同时
通过两类测试，才能声明兼容对应契约版本。

## 共享向量

每个目标语言必须验证：

- AWS 官方 S3 Signature V4 GET Object 示例签名。
- 十进制字符串到无符号 64 位 Size/Offset/Part Size 的无损转换。
- S3 XML 错误的 Code、Status、Request ID 和 Retryable 映射。
- 可重放 Body、响应是否开始、操作类型和取消状态共同决定的重试判定。
- Continuation Token、Upload ID 和 ETag 作为不透明字符串原样往返。
- ETag 必须保留双引号；Multipart ETag 的 `-part-count` 后缀也必须原样保留。
- `CRC32`、`CRC32C`、`CRC64NVME`、`SHA1`、`SHA256` 的 checksum Header 使用标准 Base64；
  `x-amz-security-token` 属于临时凭证签名输入。
- 条件 GET/HEAD 的 `304`、条件 PUT 的 `412`、CopyObject `200` XML、DeleteObjects `200` XML
  和 POST Policy 的 `200|201|204` 成功状态按共享契约处理。
- 固定大小、Chunk 和字节模式的流式测试数据，无需把整个对象载入内存。

## 端到端场景

每个 SDK Adapter 应在独立 Bucket 中运行以下顺序：

1. 创建和 Head Bucket。
2. 使用可重放流或文件流 PutObject，并以流式 GetObject 校验长度和字节模式。
3. Range GetObject 校验 `206`、`Content-Range` 和 Offset。
4. 创建多个 Object，使用 `max-keys=1` 跨页 ListObjectsV2，原样传递 Token。
5. Create、Upload Part、List Parts、Complete Multipart，下载验证拼接结果。
6. 创建另一 Multipart 并 Abort，确认后续访问返回稳定错误。
7. 对不存在 Object 解析标准 S3 XML 错误并保留 Request ID。
8. 在下载首个 Chunk 后取消，随后 Head/Get 同一对象仍成功。
9. 清理 Object 和 Bucket；失败时隔离数据目录仍由 Runner 回收。

端到端测试凭证只能由测试 Runner 临时创建。生产示例不得把长期 Secret 写入移动端或 Web。

## 当前 Adapter

| Adapter | 运行时 | 网络原语 | 64 位表示 | 状态 |
|---|---|---|---|---|
| TypeScript/Web | Node 24 执行 Web Fetch、Web Streams、Web Crypto | Fetch + ReadableStream | `bigint` | Implemented |
| Swift/iOS | Swift 6.3、Foundation、CryptoKit | URLSession + 文件/异步流 | `UInt64` | Implemented |

Node 只是 Web API 验证器的无 UI 执行宿主；Adapter 的签名、请求、流与取消代码使用
浏览器同源的 Fetch/Web Streams/Web Crypto 原语。Swift Adapter 只使用 Apple 平台标准库。

## 运行

要求已安装 Zig 0.16、Node.js 24、TypeScript 5.9、Swift 6.3 和 `curl`。不下载第三方依赖：

```bash
./conformance/run.sh
```

Runner 构建 ZigFS，在临时数据目录和 `127.0.0.1:19070` 启动实例，直接调用 ZigFS
Management API 创建测试 Credential，然后分别执行两套 S3 Adapter。端口可通过
`ZIGFS_CONFORMANCE_PORT` 修改。日志和临时凭证不会写入仓库。

## Gate 判定

- 任一共享向量、目标语言类型检查、编译或端到端场景失败，Phase 7 不得标记完成。
- 测试不调用 Admin BFF，不引入管理操作到 SDK Adapter。
- 测试不接受跳过 Range、Multipart、分页、取消或错误映射的“部分通过”。
- 新增 S3 能力时先更新兼容矩阵和共享场景，再更新各 Adapter。共享场景和错误映射的事实
  来源是 `conformance/fixtures/v1.json`，当前 `vector_revision` 为 `2`。
