# Bucket 事件订阅与投递

事件页支持订阅列表、新增、编辑、删除和刷新。每条订阅选择一个已配置的 Webhook 或 MQTT 目标，至少选择一种事件，并可设置对象 key 的前缀和后缀。匹配使用原始 key、区分大小写，前后缀同时满足才投递；同一次操作命中同一目标的多条规则时只投递一次，`configurationId` 使用首条匹配规则的 ID。投递过程不区分协议，由统一 Sender 适配器发送。

与完整 63 项 EventName 的逐项差异见[事件推送覆盖核对](event-notification-coverage.md)。

## 实际事件来源

| 分类 | 事件名 | 触发条件 |
| --- | --- | --- |
| PUT | ObjectCreated:Put | 成功写入对象 |
| PUT | ObjectCreated:Copy | 成功复制对象到目标 Bucket |
| PUT | ObjectCreated:CompleteMultipartUpload | 成功提交分片上传；上传单个分片不产生事件 |
| PUT | ObjectCreated:Post | 表单上传成功提交对象 |
| GET | ObjectAccessed:Head | S3 HEAD 成功返回对象元信息 |
| GET | ObjectAccessed:Get | S3 GET 完成响应写入，包括 Range 请求 |
| DELETE | ObjectRemoved:Delete | 实际删除对象或指定版本；不存在的对象不通知 |
| DELETE | ObjectRemoved:DeleteMarkerCreated | 版本化 Bucket 创建删除标记 |
| ILM | LifecycleExpiration:Delete | 生命周期实际删除过期对象或历史版本 |
| ILM | LifecycleExpiration:DeleteMarkerCreated | 生命周期为过期对象创建删除标记 |
| ILM | LifecycleDelMarkerExpiration:Delete | 生命周期清理过期删除标记 |
| SCANNER | Scanner:LargeVersions | 同一 key 的数据版本累计逻辑大小超过 1 TiB，不计删除标记 |
| SCANNER | Scanner:ManyVersions | 同一 key 的版本（包含删除标记）超过 1000 |
| SCANNER | Scanner:BigPrefix | 同一前缀下的直接子目录超过 10000 |

ILM 仅用于生命周期过期删除。对象列表、失败操作、条件 GET 的 304、Admin 日志轮询不产生上述通知。GET 通知表示服务端完成响应写入，不保证客户端已保存文件。SCANNER 在存储扫描任务中执行，仅检查已订阅 SCANNER 的 Bucket；告警状态保存在 `.zigfs/events/scanner-state/<bucket UUID>.json`，持续超限不重复通知，恢复到阈值以内后再次超限会重新通知。订阅新增前已保存的告警状态不会重放。

## 五类订阅约定

- PUT：PutObject、CopyObject、PostObject 和 CompleteMultipartUpload。CreateMultipartUpload、UploadPart 不产生对象创建完成通知。
- GET：GetObject 和 HeadObject；GetObjectRetention、GetObjectLegalHold 属于此类，但当前没有独立 S3 接口与通知，不把 HEAD 中携带的字段冒充为这些事件。
- DELETE：普通删除、指定版本删除和创建删除标记。DeleteObjects 对每个成功删除的对象产生相应通知；失败项和未实际删除的项不发事件，不额外重复发送汇总事件。
- ILM：生命周期过期删除、创建和清理删除标记。
- SCANNER：版本数量、所有数据版本累计逻辑大小、直接子目录数量告警。默认阈值分别为 1000、1 TiB、10000，超过阈值触发，当前为服务端固定阈值。

旧版 Scanner:ManySubfolders 已改名为 Scanner:BigPrefix；消费者应更新事件名判断。旧队列保留原始事件名。已持久化的同一前缀告警视为同一告警，升级不会重复通知。

## 管理接口

`GET/PUT /_admin/v1/buckets/{name}/event-subscriptions`，BFF 对应 `/api/v1/buckets/{name}/event-subscriptions`。要求 `admin:*` 管理权限，不是 S3 NotificationConfiguration API。

```json
{"items":[{"id":"subscription-1","destination":"WEBHOOK_1","prefix":"photos/","suffix":".jpg","events":["PUT","DELETE"]}]}
```

仅接受 PUT、GET、DELETE、ILM、SCANNER。REPLICA 已移除，新请求包含它会返回 InvalidEventSubscription。读取旧配置时过滤 REPLICA，保留混合规则中的其他事件；仅含 REPLICA 的规则不再返回或执行，下次保存时持久化清理结果。本地 CopyObject（含覆盖和恢复历史版本）仍产生 PUT / ObjectCreated:Copy。

PUT 整体替换列表；清空发送 `{"items":[]}`。最多 100 条，ID 唯一且为 1–64 个字母、数字或连字符，事件不得重复。前后缀各最多 1024 UTF-8 字节，不能包含 NUL。新增订阅必须指定现有目标，否则返回 `InvalidEventDestination`（400）。历史无目标的规则可读取和保留，但不投递；在编辑弹窗中绑定目标即可启用。并发修改以最后一次成功保存为准。

配置位于 `data/.zigfs/config/bucket-subscriptions/<bucket UUID>.json`，原子写入，重启保留。同名 Bucket 删除重建后不继承旧规则。删除订阅不撤销已经进入队列的事件。被订阅引用的目标不可删除，返回 `EventDestinationInUse`（409）。BFF 不直接访问数据目录。

## 消息格式

```json
{
  "event_id": "evt_随机UUID",
  "eventCategory": "PUT",
  "Records": [{
    "eventVersion": "2.1",
    "eventSource": "zigfs:s3",
    "awsRegion": "us-east-1",
    "eventTime": "2026-11-13T00:00:00.000Z",
    "eventName": "ObjectCreated:Put",
    "s3": {
      "s3SchemaVersion": "1.0",
      "configurationId": "subscription-1",
      "bucket": {"name": "photos", "arn": "arn:aws:s3:::photos", "id": "bucketUUID"},
      "object": {"key": "photos%2Fa+b.jpg", "size": 1024, "eTag": "md5", "versionId": "null", "sequencer": "1"}
    }
  }]
}
```

`object.key` 使用 form URL 编码（空格为 `+`，斜杠为 `%2F`），消费端需要解码。未知 size 为 null；删除/扫描事件的 eTag 为空，sequencer 为 0，不能据此推断事件顺序。对象创建/读取的 sequencer 为元数据 generation 的十六进制值。此格式参考 S3 Records，属于 ZigFS 扩展，不宣称完整 AWS 通知协议兼容。

## 队列与故障恢复

- 事件先原子写入本地队列并同步文件和父目录，后台通过统一 `Targets.deliver` 发送。请求线程不访问远程目标，但需要等待本地入队。
- 默认位置：`data/.zigfs/events/queues/<目标名称>/<event_id>.json`。指定 queue_directory 时为 `data/<queue_directory>/<目标名称>/`。
- 每个目标每轮最多处理 64 条，单次网络超时为 5 秒；一轮结束暂停 1 秒。不保证消息顺序；较慢目标可能延迟同一后台任务中的其他目标。
- 成功后移除并同步队列。超时、不可用、限流使用指数退避，基准为目标重连间隔，最大 300 秒；重启后继续。
- 认证、配置或其他永久错误保留记录并暂停该记录；目标配置改变后重新尝试。损坏记录隔离为 `.json.corrupt` 并记录服务日志。
- 重试保留 event_id；远程成功而本地尚未删除时发生崩溃可能重复发送，消费端必须按 event_id 幂等。MQTT QoS 不代替业务幂等。
- 有待投递记录时禁止修改队列目录，返回 `EventQueueNotEmpty`（409）。删除并重建同名目标使用新的 generation，旧队列记录不会发送给新目标；旧记录在同目录扫描时清除，废弃自定义目录需运维清理。
- 队列达到 queue_limit、磁盘失败或入队失败时记录服务错误，不回滚已经成功的对象操作。对象提交与事件入队不是同一事务，两者之间崩溃存在通知丢失窗口。因此不承诺 exactly-once 或无条件不丢失。

## 验证

`zig build test`、`go test ./...`、Web TypeScript/Vite 构建及 i18n 检查。构建 ZigFS 后，在仓库根目录运行 `python3 conformance/bucket_event_delivery.py`，使用临时数据与本地 Webhook/MQTT 模拟服务验证真实 S3 操作、过滤、去重、失败重试、配置修正和重启续投。
