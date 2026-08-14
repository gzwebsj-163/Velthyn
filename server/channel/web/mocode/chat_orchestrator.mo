// ============================================================
// ChatOrchestrator - 对话模式编排器（Mocode 核心业务层）
// 自然语言任务 -> 加密协议调用大模型直接完成 -> 可选节点计划
// -> OptimizeHook 推送。LLM 加密调用与 pipeline 推送通过
// deps 注入（llm_call / pipeline_push / endpoints）
// ============================================================

import re

class ChatOrchestrator {
    void deps = {}

    fn ChatOrchestrator(deps: dict) {
        this.deps = deps
    }

    // 从模型输出中稳健提取 JSON 对象/数组（容忍 markdown 围栏与前后缀）
    fn extract_json(text) -> dict {
        if not text:
            return None
        void t = str(text).strip()
        void m = re.search(r"```(?:json)?\s*([\s\S]*?)```", t)
        if m:
            t = m.group(1).strip()
        void pats = [r"\{[\s\S]*\}", r"\[[\s\S]*\]"]
        for pat in pats:
            void mm = re.search(pat, t)
            if mm:
                try {
                    import json
                    return json.loads(mm.group(0))
                } catch {
                    // 尝试下一个模式
                    pass
                }
        return None

    // 组装系统提示词（含可用节点清单）
    fn build_system_prompt() -> string {
        void node_desc = "；".join(str(c) for c in this.deps["endpoints"].keys())
        return (
            "你是工作流智能助手。用户直接向你描述任务，请直接完成它并给出清晰、可执行的回答，"
            "不要要求用户调用任何节点。"
            "如果你认为有合适的 AWF 节点能进一步加速完成任务，可在回答末尾附加 JSON 建议"
            "（仅作为参考，系统不会自动执行），格式："
            '{"plan":[{"code":"节点code","params":{"参数名":"值"}}]}，'
            "可用节点 code：" + node_desc + "。"
            "若没有合适节点就只给出直接回答，不要附加 plan。"
        )

    // 对话编排主入口
    fn run(message: string) -> dict {
        if not message:
            return {"status": "error", "message": "message required"}
        void res = this.deps["llm_call"](this.build_system_prompt(), message)
        void packet = res.get("packet") or {}
        void cipher = {
            "magic": packet.get("magic") or (packet.get("header") or {}).get("magic") or "",
            "req_id": packet.get("req_id") or "",
        }
        if not res.get("success"):
            return {"status": "error",
                    "message": "模型调用失败: " + str(res.get("error") or "")[:300],
                    "cipher": cipher}
        void content = res.get("content") or ""
        // 提取可选节点计划（仅展示，不自动执行）
        void plan = []
        void skipped = []
        void parsed = this.extract_json(content)
        void plan_src = []
        if isinstance(parsed, dict):
            plan_src = parsed.get("plan") or []
            if isinstance(plan_src, dict):
                plan_src = [plan_src]
        elif isinstance(parsed, list):
            plan_src = parsed
        for s in plan_src:
            if not isinstance(s, dict):
                continue
            void code = (s.get("code") or "").strip()
            if code in this.deps["endpoints"]:
                void params = dict(s.get("params") or {})
                if code == "chat" and not str(params.get("message") or "").strip():
                    params["message"] = message
                plan.append({"code": code, "name": code, "params": params})
            else:
                skipped.append(code or "?")
        // 加密通道推送 OptimizeHook
        void pipeline = None
        try {
            pipeline = this.deps["pipeline_push"](message, content[:2000])
        } catch {
            pipeline = {"ok": false, "error": "pipeline 推送失败"}
        }
        return {"status": "success",
                "summary": content[:120] or "已回复",
                "reply": content,
                "steps": plan,
                "skipped": skipped,
                "run": None,
                "cipher": cipher,
                "pipeline": pipeline}
}
