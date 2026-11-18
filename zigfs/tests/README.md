# 测试代码

- `mod.zig`：`test_support` 模块入口。
- `memory_metadata_repository.zig`：测试用内存元数据仓库。
- `metadata_repository_contract.zig`：多个仓库实现共用的接口契约验证。
- `streams.zig`：测试用字节流、源和接收器。

源码中的测试通过 `@import("test_support")` 使用辅助实现；辅助模块通过 `zigfs` 引用业务
接口，复用同一份类型定义。新增独立集成测试与专用夹具也放在此目录。
模块单元测试按仓库约定仍保留在对应源码文件中，由 `zig build test` 统一执行。

现有跨组件、部分同时启动 BFF 的进程测试仍位于仓库根 `conformance/`。
测试命令与依赖见 [conformance](../../conformance/README.md)。
