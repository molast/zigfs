# 文件 SDK 设计

ZigFS 多语言 SDK 只面向文件存储操作，不封装 Admin BFF API，也不提供 AK/SK 创建、禁用、删除或系统配置。

## 目标平台

- Kotlin / Android
- Swift / iOS
- TypeScript / Web
- Go、Python、Rust 等服务端语言

## 核心能力

```text
Client
├── Bucket
│   ├── create
│   ├── exists/head
│   ├── list
│   └── delete
├── Object
│   ├── put stream/file
│   ├── get stream/file
│   ├── head
│   ├── list
│   └── delete
├── Multipart
│   ├── initialize
│   ├── upload part
│   ├── complete
│   └── abort
└── Access
    ├── Signature V4
    ├── temporary credentials
    └── presigned URL
```

## 移动端与 Web 安全

长期 Secret Key 不得写入移动应用、网页包或公开配置。客户端优先使用：

1. 业务后端签发的短期凭证。
2. 业务后端或 ZigFS 授权服务生成的 Presigned PUT/GET URL。
3. 明确受限且可撤销的 Credential Policy。

AK/SK 的生成和权限配置通过 ZigFS Management API 完成，通常由 Admin 网页操作。

## 跨语言契约

- 上传下载必须使用流，不能要求整文件进入内存。
- 支持进度回调、取消、超时、断点续传和安全重试。
- Object Size、Offset、Part Size 使用 64 位整数。
- Upload ID、Continuation Token 保持不透明。
- ETag 与 checksum 不擅自转换或解释为安全摘要。
- 错误保留 S3 Error Code、HTTP Status、Request ID 和可重试标记。
- 各 SDK 使用共享兼容测试数据和端到端测试套件。
