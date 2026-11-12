# AK/SK 凭证导出

创建 AK/SK 后，点击下载生成 `credentials.json`。全局 Access Keys 和用户下的 Access Keys 共用此导出逻辑。文件仅包含以下五个字段：

```json
{"url":"https://s3.example.com","accessKey":"实际 AK","secretKey":"实际 SK","api":"s3v4","path":"path"}
```

| 字段 | 来源与含义 |
|---|---|
| `url` | 下载时读取 ZigFS 当前配置的 S3 Public URL（`s3_public_endpoint`），保留 HTTP / HTTPS 协议；不使用 Admin 控制台地址。未提供地址时为空，由客户端另行指定 Endpoint。 |
| `accessKey` | 本次创建返回的 Access Key ID，用于标识身份。 |
| `secretKey` | 本次创建返回的 Secret Access Key，用于生成请求签名。 |
| `api` | 固定 `s3v4`，表示 AWS Signature Version 4，不是 S3 API 版本，也不表示支持 SigV2。 |
| `path` | 当前配置启用虚拟主机寻址时为 `vhost`；明确关闭时为 `path`；未提供寻址配置时为 `auto`。 |

路径式地址示例：`https://s3.example.com/my-bucket/photo.jpg`。
虚拟主机式地址示例：`https://my-bucket.s3.example.com/photo.jpg`。
虚拟主机式需要相应域名解析和服务配置。`auto` 的判断方式及这些配置项的接受情况取决于导入文件的客户端；该文件格式不是 AWS SDK 通用标准配置文件。

客户端使用 Endpoint 与寻址模式构造 URL，通过 AK/SK 生成 SigV4 签名；ZigFS 验证签名、检查策略权限并执行请求。文件中的 URL 来自管理员配置，不会根据当前浏览器地址猜测，也不会在导出时探测连通性。

读取服务配置失败时提示下载失败，保留创建结果供重试或复制，不会静默导出空地址代替失败配置。导出文件不包含 owner、expires_at 或 session_token；此五字段格式用于普通 AK/SK，不能单独表达 STS 临时凭证的 Session Token。
