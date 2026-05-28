# framework examples

当前示例分成两类：

- 观测与日志示例（pure framework）
- tooling / runtime substrate 示例
- 应用集成示例

## 现有示例

- `logging_demo.zig`
- `logging_method_trace_demo.zig`
- `logging_summary_trace_demo.zig`
- `logging_basic_demo.zig`
- `logging_redaction_demo.zig`
- `logging_multi_sink_demo.zig`
- `tooling_observability_demo.zig`
- `workflow_observability_demo.zig`
- `repo_health_check_demo.zig`
- `script_markdown_fetch_demo.zig`
- `business_services_demo.zig`

## 日志示例分层

### pure framework 示例

- `logging_method_trace_demo.zig`
- `logging_summary_trace_demo.zig`
- `logging_basic_demo.zig`
- `logging_redaction_demo.zig`
- `logging_multi_sink_demo.zig`
- `tooling_observability_demo.zig`
- `workflow_observability_demo.zig`

### app integration demo

- `logging_demo.zig`

`logging_demo.zig` 直接依赖 `ourclaw`，因此它属于“应用集成示例”，不应被视为 framework logging 的主入口示例。

## repo-health-check

`repo_health_check_demo.zig` 演示了一个完整的最小垂直切片：

- 使用 `defineTool(...)` 定义 Zig 原生 tool
- 通过 `ToolRegistry` 注册 tool
- 通过 `ToolRunner` 直接执行 tool
- 使用 `EffectsRuntime.file_system` 扫描目录并输出结构化 JSON

运行方式示例：

```bash
zig build test
```

若后续需要把这个示例做成独立可执行 demo，可在 `build.zig` 中追加专门的 example target。

## script-markdown-fetch

`script_markdown_fetch_demo.zig` 与 `examples/scripts/script_markdown_fetch.py` 演示了 script-backed tool 的最小闭环：

- 通过 `ScriptSpec` 描述外部脚本
- 通过 `ScriptHost` 执行 Python 脚本
- 通过 `ToolRunner` 把脚本型 tool 统一纳入 tooling runtime
- 返回结构化 JSON 结果，供 direct tool 或 command surface 复用

这个示例本身也附带 direct tool + command surface 的测试，可作为后续 script-backed tool 的最小模板。

## business-services-demo

`business_services_demo.zig` 演示了业务项目如何：

- 保持 `framework.AppContext` 作为 kernel runtime
- 使用 `ToolingRuntime` 作为 shared substrate
- 通过 `ExampleServices` 把项目自己的依赖束挂到 `CommandContext.user_data`
- 让 command handler 只依赖 `CommandContext + ServicesFacade`
