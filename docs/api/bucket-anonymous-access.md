# Bucket 匿名访问规则

Admin 匿名访问页使用列表管理 Prefix / Access，支持新增、编辑、删除和刷新。Prefix 留空匹配所有对象，否则按字面前缀匹配，不接受 `*`、`?` 或 NUL，最长 1024 UTF-8 字节。新增时若已有完全相同的前缀（包括空前缀），覆盖该规则的 Access，并移除旧权限语句，不重复添加；其他前缀保持不变。

| Access | 对象权限 | 列表权限 |
| --- | --- | --- |
| readonly | GetObject、HeadObject、GetObjectVersion | ListBucket，仅允许匹配前缀的请求 |
| writeonly | PutObject、DeleteObject、DeleteObjectVersion、AbortMultipartUpload、ListMultipartUploadParts | ListBucketMultipartUploads，仅匹配前缀 |
| readwrite | 上述读写权限 | 对象列表和分片上传列表，仅匹配前缀 |

规则通过现有 BFF Bucket Policy 接口保存，由 ZigFS 负责授权。每条规则使用 `Principal: "*"`，对象资源为 `arn:aws:s3:::<bucket>/<prefix>*`；列表权限独立限定桶资源并附加 `StringLike / s3:prefix` 条件。前缀是字符串匹配，不自动补 `/`，例如 `photos/` 不匹配 `photos-other/`。

界面规则以 `ZigFSAnonymous<id>Objects/List/Uploads` 的 Sid 配对标识。仅完整匹配该规则格式的语句显示为可编辑规则，其他自定义语句原样保留，可在概况的自定义访问策略中管理。首次加入规则时，已有 Public / Readonly 默认读取权限也会保留，新增窄前缀规则不会收窄已有授权。删除最后一条规则保存空 Statement 策略，而不是删除 Policy 后重新启用旧的匿名默认值。

新增或编辑规则先保存策略，再关闭 Block Public Access，使规则生效；失败时显示保存错误，已写入的策略可刷新查看。管理员随后重新开启 Block Public Access 会阻止匿名访问。Block Public Access 和显式 Deny 优先；只有实际 Allow 才允许匿名请求。写规则不授予 DeleteBucket、修改策略或绕过保留期的权限。匿名 CopyObject 和 UploadPartCopy 分别检查源 Bucket 的公共访问开关与读取策略，以及目标 Bucket 的写入策略。源版本需要 GetObjectVersion。只拥有目标写权限不能读取私有源对象。

分片初始化、上传分片和完成合并要求目标 PutObject；列出分片和中止上传分别要求 ListMultipartUploadParts、AbortMultipartUpload。每次请求重新授权，撤销写权限后无法完成上传；UploadId 必须与实际 Bucket 和 key 匹配。分片列表只能查询规则允许的前缀。

批量删除校验 Content-MD5 或支持的校验和，并为每个对象独立检查 DeleteObject / DeleteObjectVersion。混合授权请求返回逐项 Deleted / Error，Quiet 模式省略成功项但保留失败项。显式 Deny、法律保留和保留期检查均不跳过，匿名请求不允许通过请求头绕过治理保留期。

新保存的 writeonly/readwrite 规则包含新增的分片和版本删除权限。旧规则仍可读取、编辑；重新保存即可升级权限语句，不自动扩大已保存策略的授权范围。所有操作复用现有对象存储及事件通知链路。

策略更新为整体替换，跨客户端并发修改以最后一次保存为准。页面提交前重新读取策略，保留当时的非托管语句。

验证：`zig build test`、Web 构建、`node --test scripts/i18n.test.mjs`、`python3 conformance/anonymous_access.py`（隔离数据目录与本机端口）。

存储格式：Bucket payload minor version 从 7 升级为 8，在固定头部偏移 84 保存 Block Public Access（0/1）。旧版本数据继续读取，按此前实际行为默认为阻止公共访问；新数据不可由旧服务版本读取。
