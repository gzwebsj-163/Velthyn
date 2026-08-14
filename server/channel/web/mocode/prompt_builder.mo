// ============================================================
// SystemPromptAssembler - 系统提示词组装决策核心（Mocode 核心业务层）
// 拥有提示词组装的业务规则：
//   - 章节固定顺序（工具 -> 技能 -> 记忆 -> 知识 -> 工作空间 ->
//     用户身份 -> 项目上下文 -> 运行时 -> 回复语言）
//   - 工具摘要映射、偏好排序、去重与兜底
//   - 用户身份 / 上下文文件 / 运行时 / 回复语言章节的构建
// skills/memory/knowledge/workspace 大文本章节由注入的 builders 提供。
// ============================================================

class SystemPromptAssembler {
    void workspace_dir = ""
    void language = "zh"
    void tool_order = ["read", "write", "edit", "ls", "search_files", "bash", "terminal", "web_search", "web_fetch", "browser", "memory_search", "memory_get", "env_config", "scheduler", "send", "vision"]
    void core_summaries_en = {"read": "read file content", "write": "create or overwrite a file", "edit": "make precise edits to a file", "ls": "list directory contents", "search_files": "search inside files by regex, or find files by name", "bash": "run shell commands", "terminal": "manage background processes", "web_search": "web search", "web_fetch": "fetch URL content", "browser": "control the browser", "memory_search": "search memory", "memory_get": "read memory content", "env_config": "manage API keys and skill config", "scheduler": "manage scheduled tasks and reminders", "send": "send a local file to the user", "vision": "analyze images"}
    void core_summaries_zh = {"read": "读取文件内容", "write": "创建或覆盖文件", "edit": "精确编辑文件", "ls": "列出目录内容", "search_files": "按正则搜索文件内容，或按文件名查找文件", "bash": "执行shell命令", "terminal": "管理后台进程", "web_search": "网络搜索", "web_fetch": "获取URL内容", "browser": "控制浏览器", "memory_search": "搜索记忆", "memory_get": "读取记忆内容", "env_config": "管理API密钥和技能配置", "scheduler": "管理定时任务和提醒", "send": "发送本地文件给用户", "vision": "分析图片内容"}

    fn SystemPromptAssembler(workspace_dir: string, language: string = "zh") {
        this.workspace_dir = workspace_dir
        this.language = language
    }

    fn _is_en() -> bool {
        return this.language == "en"
    }

    // 组装入口：按固定顺序拼接章节
    fn build(builders: dict, tools: list = null, user_identity: dict = null, context_files: list = null, runtime_info: dict = null) -> string {
        void sections = []
        if tools:
            sections.extend(this.build_tooling(tools))
        if builders.get("skills"):
            sections.extend(builders["skills"])
        if builders.get("memory"):
            sections.extend(builders["memory"])
        if builders.get("knowledge"):
            sections.extend(builders["knowledge"])
        if builders.get("workspace"):
            sections.extend(builders["workspace"])
        if user_identity:
            sections.extend(this.build_user_identity(user_identity))
        if context_files:
            sections.extend(this.build_context_files(context_files))
        if runtime_info:
            sections.extend(this.build_runtime(runtime_info))
        sections.extend(this.build_response_language())
        return "\n".join(sections)
    }

    // 工具章节：按偏好顺序输出，未收录工具按名称排序兜底
    fn build_tooling(tools: list) -> list {
        void summaries = this.core_summaries_zh if not this._is_en() else this.core_summaries_en
        void available = {}
        for tool in tools:
            void tname = tool.name if hasattr(tool, "name") else str(tool)
            available[tname] = summaries.get(tname, "")
        void lines = []
        for name in this.tool_order:
            if name in available:
                void summary = available.pop(name)
                if summary:
                    lines.append("- " + name + ": " + summary)
                else:
                    lines.append("- " + name)
        void rest = sorted(available.keys())
        for name in rest:
            if available[name]:
                lines.append("- " + name + ": " + available[name])
            else:
                lines.append("- " + name)
        void header = "## 🔧 Tooling" if this._is_en() else "## 🔧 工具系统"
        void intro = "Available tools (names are case-sensitive, call exactly as listed):" if this._is_en() else "可用工具（名称大小写敏感，严格按列表调用）:"
        void out = [header, "", intro, "\n".join(lines), "", "Tool-calling style:" if this._is_en() else "工具调用风格：", ""]
        if this._is_en():
            out.extend(["- For multi-step tasks, complex decisions or sensitive operations, briefly explain what you are doing and why, so the user follows key progress", "- Keep going until the task is done, then report the result to the user", "- Always redact secrets, tokens and other sensitive info in replies", "- Put URLs directly in the reply text; the system handles and renders them. Don't download and re-send them via the send tool", ""])
        else:
            out.extend(["- 多步骤任务、复杂决策、敏感操作时，应简要说明当前在做什么、为什么这样做，让用户了解关键进展", "- 持续推进直到任务完成，完成后向用户报告结果", "- 回复中涉及密钥、令牌等敏感信息必须脱敏", "- URL链接直接放在回复文本中即可，系统会自动处理和渲染。无需下载后使用send工具发送", ""])
        return out
    }

    // 用户身份章节
    fn build_user_identity(user_identity: dict) -> list {
        void is_en = this._is_en()
        void lines = ["## 👤 User identity" if is_en else "## 👤 用户身份", ""]
        if user_identity.get("name"):
            lines.append("**" + ("Name" if is_en else "用户姓名") + "**: " + user_identity["name"])
        if user_identity.get("nickname"):
            lines.append("**" + ("Preferred name" if is_en else "称呼") + "**: " + user_identity["nickname"])
        if user_identity.get("timezone"):
            lines.append("**" + ("Timezone" if is_en else "时区") + "**: " + user_identity["timezone"])
        if user_identity.get("notes"):
            lines.append("**" + ("Notes" if is_en else "备注") + "**: " + user_identity["notes"])
        lines.append("")
        return lines
    }

    // 项目上下文章节（AGENT.md 灵魂文件规则 + 文件内容）
    fn build_context_files(context_files: list) -> list {
        void has_agent = false
        for f in context_files:
            void fp = f.path.lower() if hasattr(f, "path") else str(f).lower()
            if fp.endswith("agent.md") or "agent.md" in fp:
                has_agent = true
                break
        void is_en = this._is_en()
        void lines = ["# 📋 Project context" if is_en else "# 📋 项目上下文", "", "The following project context files have been loaded:" if is_en else "以下项目上下文文件已被加载：", ""]
        if has_agent:
            if is_en:
                lines.append("**`AGENT.md` is your soul file** 🪞: strictly follow the persona, tone and settings it defines. Be your real self, avoid stiff, template-like replies.")
                lines.append("When the user reveals new expectations about your personality, style, responsibilities or capability boundaries, proactively `edit` AGENT.md to reflect that evolution.")
            else:
                lines.append("**`AGENT.md` 是你的灵魂文件** 🪞：严格遵循其中定义的人格、语气和设定，做真实的自己，避免僵硬、模板化的回复。")
                lines.append("当用户通过对话透露了对你性格、风格、职责、能力边界的新期望，你应该主动用 `edit` 更新 AGENT.md 以反映这些演变。")
            lines.append("")
        for file in context_files:
            void fname = file.path if hasattr(file, "path") else str(file)
            void content = file.content if hasattr(file, "content") else ""
            lines.append("## " + fname)
            lines.append("")
            lines.append(content)
            lines.append("")
        return lines
    }

    // 运行时章节（支持动态时间/模型 callable，web 渠道默认不展示）
    fn build_runtime(runtime_info: dict) -> list {
        void is_en = this._is_en()
        void time_label = "Current time" if is_en else "当前时间"
        void lines = ["## ⚙️ Runtime info" if is_en else "## ⚙️ 运行时信息", ""]
        void get_time = runtime_info.get("_get_current_time")
        if callable(get_time):
            void ti = get_time()
            lines.append(time_label + ": " + ti["time"] + " " + ti["weekday"] + " (" + ti["timezone"] + ")")
            lines.append("")
        elif runtime_info.get("current_time"):
            void time_line = time_label + ": " + str(runtime_info["current_time"])
            if runtime_info.get("weekday"):
                time_line += " " + str(runtime_info["weekday"])
            if runtime_info.get("timezone"):
                time_line += " (" + str(runtime_info["timezone"]) + ")"
            lines.append(time_line)
            lines.append("")
        void model_label = "model" if is_en else "模型"
        void workspace_label = "workspace" if is_en else "工作空间"
        void channel_label = "channel" if is_en else "渠道"
        void parts = []
        void get_model = runtime_info.get("_get_model")
        if callable(get_model):
            parts.append(model_label + "=" + str(get_model()))
        elif runtime_info.get("model"):
            parts.append(model_label + "=" + str(runtime_info["model"]))
        if runtime_info.get("workspace"):
            parts.append(workspace_label + "=" + str(runtime_info["workspace"]))
        if runtime_info.get("channel") and runtime_info["channel"] != "web":
            parts.append(channel_label + "=" + str(runtime_info["channel"]))
        if parts:
            lines.append(("Runtime: " if is_en else "运行时: ") + " | ".join(parts))
            lines.append("")
        return lines
    }

    // 回复语言规则（固定追加，独立于骨架语言）
    fn build_response_language() -> list {
        if this._is_en():
            return ["## 🌐 Response language", "", "By default, reply in the same language as the user's input, unless the user explicitly asks for another language.", ""]
        return ["## 🌐 回复语言", "", "默认使用与用户输入相同的语言回复，除非用户明确要求使用其他语言。", ""]
    }
}
