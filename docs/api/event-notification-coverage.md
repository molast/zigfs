# 事件推送覆盖核对：63 项 EventName

核对日期：2026-11-13。基准为用户提供的 1–63 号 EventName 清单；已按五类订阅约定更新；状态依据代码触发链路，验证范围见订阅文档，不代表 63 项均经过逐项实测。

## 统计口径与结论

“已接入”要求存在成功操作后的生产者，且进入 Bucket 订阅匹配 → 持久化队列 → 统一 Sender → Webhook/MQTT 的链路。有 API、UI、日志或审计记录，不代表已支持事件推送。表中的编号仅用于与用户清单对照，ZigFS 当前没有对应的 1–63 数字枚举协议。

| 状态 | 数量 | 说明 |
| --- | ---: | --- |
| 已接入 | 14 | 存在相应事件名和触发链路；仍按大类订阅，不能逐项订阅 |
| 部分接入 | 0 | 生命周期删除语义已拆分 |
| 未接入 | 49 | 39 个具体事件、10 个通配订阅项 |
| 合计 | 63 | 其中 53 个具体事件、10 个通配订阅项 |

当前实际可发出 **14 种事件名称**，均对应下表已接入项。五类订阅约定见[订阅文档](bucket-event-subscriptions.md)。

## 逐项核对

| 编号 | 用户 EventName | 状态 | 当前通知名 / 分类 | 差异说明 |
| ---: | --- | --- | --- | --- |
| 1 | `ObjectAccessedGet` | 已接入 | `ObjectAccessed:Get` / GET | 成功 GET 完成响应写入，包括 Range；304 和失败请求不通知。 |
| 2 | `ObjectAccessedGetRetention` | 未接入 | — | 无独立 GetRetention 通知。 |
| 3 | `ObjectAccessedGetLegalHold` | 未接入 | — | 无独立 GetLegalHold 通知；详情展示保留状态不等于发事件。 |
| 4 | `ObjectAccessedHead` | 已接入 | `ObjectAccessed:Head` / GET | HEAD 成功返回对象元信息后通知。 |
| 5 | `ObjectAccessedAttributes` | 未接入 | — | 无 Attributes 通知。 |
| 6 | `ObjectCreatedCompleteMultipartUpload` | 已接入 | `ObjectCreated:CompleteMultipartUpload` / PUT | 完成分片合并并成功提交对象后通知。 |
| 7 | `ObjectCreatedCopy` | 已接入 | `ObjectCreated:Copy` / PUT | CopyObject 成功后通知；后台恢复历史版本走此事件。 |
| 8 | `ObjectCreatedPost` | 已接入 | `ObjectCreated:Post` / PUT | POST 表单上传成功提交对象后通知。 |
| 9 | `ObjectCreatedPut` | 已接入 | `ObjectCreated:Put` / PUT | 普通对象写入成功后通知；POST 表单上传已独立分类。 |
| 10 | `ObjectCreatedPutRetention` | 未接入 | — | 无独立 PutRetention 通知。 |
| 11 | `ObjectCreatedPutLegalHold` | 未接入 | — | Management 合法保留修改存在并有审计，但未进入事件队列。 |
| 12 | `ObjectTaggingPut` | 未接入 | — | 对象标签 PUT 已实现，未调用事件 Sink。 |
| 13 | `ObjectTaggingDelete` | 未接入 | — | 对象标签 DELETE 已实现，未调用事件 Sink。 |
| 14 | `ObjectRemovedDelete` | 已接入 | `ObjectRemoved:Delete` / DELETE | 实际删除对象或指定版本后通知。 |
| 15 | `ObjectRemovedDeleteMarkerCreated` | 已接入 | `ObjectRemoved:DeleteMarkerCreated` / DELETE | 普通删除在版本化 Bucket 中创建删除标记后通知。 |
| 16 | `ObjectRemovedDeleteAllVersions` | 未接入 | — | 无删除全部版本的独立事件；不能用普通 Delete 事件证明此类型已接入。 |
| 17 | `ObjectRemovedNoOP` | 未接入 | — | notifyDelete 对 deleted=false 直接返回，不发 NoOP。 |
| 18 | `BucketCreated` | 未接入 | — | Bucket 创建已实现，未接入事件 Sink。 |
| 19 | `BucketRemoved` | 未接入 | — | Bucket 删除已实现，未接入事件 Sink。 |
| 20 | `ObjectReplicationFailed` | 未接入 | — | 已按需求取消远端复制事件，不纳入后续接入范围。 |
| 21 | `ObjectReplicationComplete` | 未接入 | — | 已按需求取消远端复制事件，不纳入后续接入范围。 |
| 22 | `ObjectReplicationMissedThreshold` | 未接入 | — | 已按需求取消远端复制事件，不纳入后续接入范围。 |
| 23 | `ObjectReplicationReplicatedAfterThreshold` | 未接入 | — | 已按需求取消远端复制事件，不纳入后续接入范围。 |
| 24 | `ObjectReplicationNotTracked` | 未接入 | — | 已按需求取消远端复制事件，不纳入后续接入范围。 |
| 25 | `ObjectRestorePost` | 未接入 | — | 无 ObjectRestore:Post 通知；恢复历史版本是 CopyObject，不能视为归档恢复。 |
| 26 | `ObjectRestoreCompleted` | 未接入 | — | 无 ObjectRestore:Completed 通知。 |
| 27 | `ObjectTransitionFailed` | 未接入 | — | 已按需求取消存储转换事件，不纳入后续接入范围。 |
| 28 | `ObjectTransitionComplete` | 未接入 | — | 已按需求取消存储转换事件，不纳入后续接入范围。 |
| 29 | `ScannerManyVersions` | 已接入 | `Scanner:ManyVersions` / SCANNER | 单 key 版本总数（含删除标记）超过 1000，按越界状态去重。 |
| 30 | `ScannerLargeVersions` | 已接入 | `Scanner:LargeVersions` / SCANNER | 同一 key 数据版本累计逻辑大小超过 1 TiB，不含删除标记。 |
| 31 | `ScannerBigPrefix` | 已接入 | `Scanner:BigPrefix` / SCANNER | 同一前缀下直接子目录数超过 10000。 |
| 32 | `LifecycleDelMarkerExpirationDelete` | 已接入 | `LifecycleDelMarkerExpiration:Delete` / ILM | 生命周期清理过期删除标记。 |
| 33 | `ObjectAclPut` | 未接入 | — | 无 ObjectAclPut 通知。 |
| 34 | `LifecycleExpirationDelete` | 已接入 | `LifecycleExpiration:Delete` / ILM | 生命周期实际删除对象或历史版本。 |
| 35 | `LifecycleExpirationDeleteMarkerCreated` | 已接入 | `LifecycleExpiration:DeleteMarkerCreated` / ILM | 生命周期创建删除标记。 |
| 36 | `LifecycleTransition` | 未接入 | — | 已按需求取消生命周期存储转换事件。 |
| 37 | `IntelligentTiering` | 未接入 | — | 无智能分层事件。 |
| 38 | `ObjectAccessedAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 39 | `ObjectCreatedAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 40 | `ObjectRemovedAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 41 | `ObjectReplicationAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 42 | `ObjectRestoreAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 43 | `ObjectTaggingAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 44 | `LifecycleExpirationAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 45 | `ObjectTransitionAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 46 | `ObjectScannerAll` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 47 | `Everything` | 未接入 | — | 未支持此通配订阅项；当前只接受 PUT/GET/DELETE/ILM/SCANNER。 |
| 48 | `ObjectRemovedAbortMultipartUpload` | 未接入 | — | 中止分片上传已有操作及审计，未发独立通知。 |
| 49 | `ObjectCreatedCreateMultipartUpload` | 未接入 | — | 初始化分片上传已有操作及审计，未发独立通知。 |
| 50 | `ObjectRemovedDeleteObjects` | 未接入 | — | 批量删除已有操作及审计；无 DeleteObjects 独立事件，内部对象删除通知不能替代它。 |
| 51 | `KmsKeyCreated` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 52 | `KmsKeyRotated` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 53 | `KmsKeyEnabled` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 54 | `KmsKeyDisabled` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 55 | `KmsKeyDeletionScheduled` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 56 | `KmsKeyDeletionCancelled` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 57 | `KmsKeyDeleted` | 未接入 | — | 没有对应 KMS 通知生产者或全局事件订阅；已有密钥管理/审计不算投递支持。 |
| 58 | `KmsKeyAccessed` | 未接入 | — | 无 KMS 密钥访问通知，不能用 ListKeys/GetKey 或审计记录替代。 |
| 59 | `KmsServiceConfigured` | 未接入 | — | KMS 配置/启停功能及审计已有，未接入事件投递。 |
| 60 | `KmsServiceStarted` | 未接入 | — | KMS 配置/启停功能及审计已有，未接入事件投递。 |
| 61 | `KmsServiceStopped` | 未接入 | — | KMS 配置/启停功能及审计已有，未接入事件投递。 |
| 62 | `IamIdentityCredentialChanged` | 未接入 | — | 身份/凭据管理与审计存在，未发 CredentialChanged 通知。 |
| 63 | `IamIdentityAuthChallenge` | 未接入 | — | 未发 AuthChallenge 通知，不能用登录审计替代。 |

## 当前边界

- 按用户确认的五类订阅配置，未开放细分名称或通配选择；表中的未接入项不代表这五类全部需要立即支持。
- 批量删除按每个成功对象发 DELETE；不发送独立 DeleteObjects 汇总事件。
- 恢复历史版本发 Copy，不属于归档恢复。
- KMS/IAM 仍是独立审计链路，尚未设计全局事件订阅。
- REPLICA 和存储转换已按需求取消；历史枚举行仅用于对照，不表示待实现功能。归档恢复和智能分层目前未接入。
- 队列重试及业务提交与入队之间的故障边界见[订阅文档](bucket-event-subscriptions.md)。
