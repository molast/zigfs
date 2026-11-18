# 对象详情面板

对象详情以侧栏展示，包含对象信息、元数据，以及始终可见的生成链接区域。标签、版本、预览分别使用独立弹窗。

## 信息和元数据

- 通过 `/api/v1/objects/presign` 签发 `HEAD`，读取 S3 响应头，不下载对象正文。
- 对象信息显示名称、大小、Content-Type、ETag、修改时间、合法保留和保留策略。
- 元数据展示 Content-Type 及 `x-amz-meta-*` 自定义元数据。无数据或读取失败时不根据扩展名伪造 MIME 类型。
- 无浏览器凭据的预签名请求使用 `credentials: omit`；S3 对象响应通过 CORS expose headers 暴露实际元数据。
- 合法保留通过 `PATCH /api/v1/buckets/{name}/legal-hold` 转发到同名 Management API。请求包含 `key`、`version_id`、`enabled`，支持 `false` 和字符串 `null`。沿用 ZigFS 现有 `admin:*` 管理权限与 `SetObjectLegalHold` 审计。
- 保留策略目前为只读展示。

## 标签

弹窗仅显示标签 key、标签值两个输入框，以及右下角的“添加”按钮。每次添加一个标签，合并对象已有标签后通过 PUT tagging 保存，不覆盖或清空已有标签。保存成功后弹窗保持打开，输入框清空，标签在头部以 `key: value` 展示。点击标签右侧 × 立即保存删除，删除最后一个标签使用 DELETE tagging；请求失败保留原标签和输入。每个对象最多 10 项。空值允许；名称必填且不能与已有标签重名。名称最多 128 UTF-8 字节，值最多 256 字节，不能包含控制字符。

GET、PUT、DELETE tagging 均可携带真实 `version_id`。前端 XML 转义标签内容；保存失败保留输入，首次校验仅标记一个错误。

## 版本

版本数据从 `GET /api/v1/buckets/{name}/versions?prefix=...` 读取，再精确匹配完整对象 Key，避免将同前缀的其他对象计入。列表显示版本数、总大小、版本 ID、当前标识、修改时间及大小排序；删除标记不计入数据大小。

- 未开启版本控制时上传的对象具有 `null` 版本，UI 保留该真实值。
- 开启版本控制后重复上传生成新版本，历史版本保留。
- 恢复操作经确认后使用 CopyObject：`copy_source_version_id` 指向选中的历史版本，目标不携带版本号。启用版本控制时生成新版本并成为当前版本，不移动或删除历史版本。暂停版本控制时遵循 S3 的 null 版本写入规则。
- 预览、下载、永久删除均绑定所选版本 ID，包含字符串 `null`。
- 删除标记仅提供删除操作。不能预览、下载或作为复制源。
- CopyObject 的 HTTP 200 响应仍会检查 XML 错误，成功后重新读取版本列表与当前对象元数据。

## 预览与链接

图片通过签名 URL 按需加载，支持最大化。其他文件提供浏览器原生下载，不在 JavaScript 中读取完整文件或生成 Blob。

普通对象 GET 链接使用 SigV4 查询参数：`X-Amz-Algorithm`、`X-Amz-Content-Sha256=UNSIGNED-PAYLOAD`、`X-Amz-Credential`、`X-Amz-Date`、`X-Amz-Expires`、`X-Amz-SignedHeaders`、`X-Amz-Signature`，以及控制台会话签发的 `X-Amz-Security-Token`。同时携带 SDK GetObject 参数 `x-amz-checksum-mode=ENABLED`、`x-id=GetObject`。所有参数均在签名前加入；修改参数会导致签名校验失败。版本下载保留 `versionId` 和 `response-content-disposition=attachment`。校验和模式参数不触发下载前扫描整个对象，也不将 multipart 的内部指纹冒充完整文件校验和。

链接默认 0 天 2 小时 0 分钟，有效期大于零且不超过 7 天。控制台会话签发的链接实际有效期还受会话到期时间限制，`expires_at` 返回该实际期限。链接访问时仍检查身份和权限；UI 不承诺固定的退出登录失效行为。

## 验证

- `cd zigfs && zig build test && zig build`
- `cd zigfs-admin/server && go test ./...`
- `cd zigfs-admin/web && pnpm run build`
- `/usr/bin/python3 conformance/object_details.py`：使用隔离数据目录验证 HEAD、方法绑定、版本标签、从 null 版本恢复、合法保留和链接到期时间。
