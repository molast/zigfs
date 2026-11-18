# 独立开发工具

这里存放独立可执行程序，不作为服务运行路径的一部分。

- `sanitizer_probe.c`：由仓库根 `tools/diagnostics/sanitizers.py` 编译的 C 检查探针。
- `zig build memory-diagnostic-probe`：内存故障探针。
- `zig build thread-sanitizer-probe`：线程检查的正反对照（需要工具链支持 TSan）。
- `zig build event-delivery-probe`：事件投递验证程序。

探针包含故意触发的故障，不能导入服务或普通测试运行器。
跨组件诊断脚本仍位于仓库根的 `tools/`。
