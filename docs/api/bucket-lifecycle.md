# Bucket 生命周期规则与标签过滤

Admin 的 Bucket → Lifecycle 支持新增、编辑、删除、启停和刷新规则。标签位于“更多配置”，支持添加和删除，编辑时回显；每次提交仅标记首个无效标签字段。规则经 BFF 的 Bucket 配置接口转交 ZigFS，不在 Admin 中执行或落盘。

支持当前版本按天数或已有配置中的日期过期、非当前版本按天数过期，以及单独的过期删除标记处理。当前不支持存储层迁移。

## 与对象版本管理的联动

- 当前对象过期沿用 Bucket 的版本控制语义；启用版本控制时生成删除标记，原对象成为历史版本。
- `NoncurrentDays` 从该版本被相邻较新版本替代的时间开始计算，不使用旧版本自己的上传或修改时间。较新版本可以是普通对象、恢复操作创建的新版本，或删除标记。
- 对历史版本，到期时间为上述时间加指定天数，再向上取整到 UTC 零点。例如 11 月 13 日 15:00 UTC 成为历史版本，配置 1 天，则最早在 11 月 15 日 00:00 UTC 的扫描中删除。
- 每个历史版本分别使用它的直接后继版本时间；扫描中使用同一份版本快照，避免本轮删除较新历史版本后影响较老版本的计时。
- `NewerNoncurrentVersions=N` 保留最近 N 个非当前数据版本；其余版本还必须满足天数和过滤条件才会永久删除。删除标记不占此保留名额。
- 恢复旧版本会创建新的当前版本，原历史版本不会因此获得新的修改时间；原当前版本从恢复操作发生时开始计算历史保留期。
- 时间来源直接使用持久化版本历史，不新增存储字段，已有 Bucket 和重启后的服务均使用相同逻辑。实际执行依赖后台扫描，默认间隔 5 分钟。

## 标签过滤语义

- 匹配对象标签，不是 Bucket 标签或对象自定义 metadata。
- 前缀和所有标签同时匹配（AND）。标签名称和值均区分大小写，保留空格，不自动 trim。
- 空标签值有效，但对象必须存在该名称且值为空；缺失标签不匹配。
- 无标签条件时保留原来的前缀过滤行为。
- 非当前版本使用该历史版本自己的标签，不使用最新版本标签。
- 最多 10 个标签；名称不能为空且唯一，名称最多 128 UTF-8 字节，值最多 256 UTF-8 字节，不能包含控制字符。与当前 ZigFS 对象标签存储的字节上限保持一致。
- 按 S3 规则，标签过滤不能和 ExpiredObjectDeleteMarker 组合，包含 true 或 false 的配置均拒绝。界面互斥禁用相应选项，接口返回无效生命周期 XML，不覆盖旧规则。
- 标签读取失败会停止本次扫描并报告错误，不会当作无条件匹配。标签更新在后续扫描中重新读取；配置保存不立即执行删除。

## XML 格式

同一格式用于 S3 `PUT/GET /{bucket}?lifecycle` 和 Management/BFF Bucket configuration 的 `lifecycle_configuration` 字段。

单标签且无前缀：

```xml
<Filter><Tag><Key>ttl</Key><Value>short</Value></Tag></Filter>
```

前缀加标签或多个标签：

```xml
<LifecycleConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
  <Rule>
    <ID>expire-temporary</ID>
    <Status>Enabled</Status>
    <Filter>
      <And>
        <Prefix>temp/</Prefix>
        <Tag><Key>ttl</Key><Value>short</Value></Tag>
        <Tag><Key>reviewed</Key><Value></Value></Tag>
      </And>
    </Filter>
    <Expiration><Days>7</Days></Expiration>
  </Rule>
</LifecycleConfiguration>
```

`And` 必须有至少两个条件，只允许一个 Prefix 和名称不重复的 Tag。XML 特殊字符由 Admin 转义，读取后还原原值。规则仍保存在 ZigFS Bucket 元数据中，重启后保留。实际过期删除沿用 ILM 事件投递，详见 [Bucket 事件订阅](bucket-event-subscriptions.md)。

## 验证

- `cd zigfs && zig build test`：解析、无效过滤器、AND 匹配、真实当前/历史版本删除和非匹配保留，以及覆盖/恢复/删除标记后的历史计时、UTC 零点边界、多个历史版本和最近 N 个版本保留。
- Web 构建及 `node --test scripts/i18n.test.mjs`：标签 XML 序列化、转义、多语言及首个错误。
- 根目录 `python3 conformance/bucket_event_delivery.py`：隔离服务下真实 S3 标签更新、生命周期扫描、非匹配对象保留及 ILM 消息投递。
