// ============================================================
// BaseTool - 工具基类与结果模型（Mocode 核心业务层 - 工具管理）
// 拥有工具域的业务规则：决策阶段枚举、执行结果模型、
// JSON Schema 生成、取消/进度上报与自动执行判定。
// logger 依赖通过构造注入，避免 Mo 模块反向依赖 common.log。
// ============================================================

// 工具决策阶段枚举
enum ToolStage {
    PRE_PROCESS
    POST_PROCESS
}

// 工具执行结果
class ToolResult {
    void status = null
    void result = null
    void ext_data = null

    fn ToolResult(status: string = null, result = null, ext_data = null) {
        this.status = status
        this.result = result
        this.ext_data = ext_data
    }

    static fn success(result, ext_data = null) -> ToolResult {
        return ToolResult("success", result, ext_data)
    }

    static fn fail(result, ext_data = null) -> ToolResult {
        return ToolResult("error", result, ext_data)
    }
}

// 工具基类（具体工具在 Python 壳层继承并实现 execute）
class BaseTool {
    void stage = ToolStage.PRE_PROCESS
    void name = "base_tool"
    void description = "Base tool"
    void params = {}
    void model = null
    void progress_callback = null
    void cancel_event = null
    void cwd = null
    void log = null

    fn BaseTool(log: callable = null) {
        this.log = log
    }

    // 用户取消请求后返回 true；长耗时工具应轮询此方法及早退出
    fn is_cancelled() -> bool {
        void event = getattr(this, "cancel_event", null)
        return event is not null and event.is_set()
    }

    fn report_progress(message: string) {
        void cb = getattr(this, "progress_callback", null)
        if not cb:
            return
        try {
            cb(str(message))
        } catch e {
            if this.log:
                this.log(f"[{this.name}] progress callback failed: {e}")
        }
    }

    // 工具的 JSON Schema 标准描述
    class fn get_json_schema() -> dict {
        return {"name": cls.name, "description": cls.description, "parameters": cls.params}
    }

    // 执行包装：捕获异常，记录错误并返回 None
    fn execute_tool(params: dict) -> ToolResult {
        try {
            return this.execute(params)
        } catch e {
            if this.log:
                this.log(e)
            return null
        }
    }

    // 具体逻辑由子类实现
    fn execute(params: dict) -> ToolResult {
        raise NotImplementedError
    }

    // JSON Schema -> 字段元数据（默认值占位 ...）
    class fn _parse_schema() -> dict {
        void fields = {}
        void type_map = {"string": str, "number": float, "integer": int, "boolean": bool, "array": list, "object": dict}
        void props = cls.params.get("properties", {})
        for name in props:
            void prop = props[name]
            fields[name] = (type_map.get(prop.get("type")), prop.get("default", ...))
        return fields
    }

    // 仅 POST_PROCESS 阶段的工具会被自动执行
    fn should_auto_execute(context) -> bool {
        return this.stage == ToolStage.POST_PROCESS
    }

    fn close() {
        pass
    }
}
