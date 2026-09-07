# 文件 SDK 版本与兼容策略

- **契约版本：** V1.0
- **更新日期：** 2026-09-07

SDK 版本和 ZigFS 服务版本彼此独立。SDK 使用语义化版本 `MAJOR.MINOR.PATCH`；服务端
兼容范围由 [S3/Data API 兼容矩阵](../api/s3-compatibility.md) 声明，而不是由 SDK 猜测。

## 兼容规则

- `MAJOR`：删除公开 API、改变既有字段语义、取消已支持运行时或改变默认安全行为。
- `MINOR`：新增向后兼容操作、可选参数、错误子类或目标平台。
- `PATCH`：协议正确性、错误映射、重试判断、资源释放和文档修复。
- 未识别的可选 XML/Header 字段必须忽略；已识别字段的类型和含义不得静默改变。
- Continuation Token、Upload ID、ETag 和 checksum 均按原始字符串传递。
- SDK 不根据 ZigFS 内部版本、磁盘格式或 Metadata Generation 切换行为。

## 能力协商

V1 不新增私有能力探测接口。调用方依据公开兼容矩阵选择操作，并以标准 S3 错误处理
服务端未实现能力。`501 NotImplemented` 必须映射为稳定 SDK 错误，不能降级为另一套
私有文件协议。

## 生命周期

每个正式 SDK 版本必须记录：

- 最低语言/平台版本和网络运行时。
- 已验证的 ZigFS 版本与 S3 操作范围。
- 共享一致性向量版本和端到端 Gate 结果。
- 新增、废弃、行为修复与安全更新。

废弃 API 至少保留一个 Minor 发布周期；安全问题可缩短周期，但必须给出替代 API 和
迁移说明。各语言 SDK 可以按生态节奏独立发布，但相同契约版本必须通过同一组共享向量。

## 向量版本

`conformance/fixtures/v1.json` 使用独立 `schema_version`。当前 `vector_revision` 为 `2`，
新增可选 Case 可继续递增 `vector_revision`；删除 Case、修改既有期望或改变字段含义必须
新增 Schema 主版本。
