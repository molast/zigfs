# 内置资源

- `policies/`：初始化 IAM 策略的 JSON 文档。
- `display_timezones.txt`：控制台支持的时区列表。

`build.zig` 通过 `addAnonymousImport` 注册资源文件名，源码使用 `@embedFile` 编译进二进制。
运行时不读取此目录。用户修改的策略和配置由 metadata-engine 保存，不能写回内置资源。
新增资源应放在此目录，并同步检查 Zig 包清单和 Docker 构建上下文。
