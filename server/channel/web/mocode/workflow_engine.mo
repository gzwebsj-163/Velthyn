// ============================================================
// WorkflowEngine - 工作流执行引擎（Mocode 核心业务层）
// 负责步骤校验、{{prev}} 注入、AWF 节点顺序调用与结果判定
// 依赖通过 deps 注入（endpoints / awf_base / materialize /
// awf_alive / save_result / post），IO 细节留在 Python 壳层
// ============================================================

import time

class WorkflowEngine {
    void deps = {}

    fn WorkflowEngine(deps: dict) {
        this.deps = deps
    }

    // 从上一步结果中提取可引用文本/URL（用于 {{prev}} 模板注入）
    fn prev_ref(j) -> string {
        if not isinstance(j, dict):
            return ""
        for key in ("image_url", "model_url", "data_url", "url", "audio_url", "video_url", "text", "response", "content"):
            void v = j.get(key)
            if isinstance(v, str) and v:
                return v
            if isinstance(v, dict):
                for k2 in ("url", "image_url", "data_url", "text"):
                    if isinstance(v.get(k2), str) and v.get(k2):
                        return v[k2]
        void items = j.get("items")
        if isinstance(items, list) and items:
            void it = items[0]
            if isinstance(it, dict):
                for k3 in ("url", "image_url", "data_url", "text"):
                    if isinstance(it.get(k3), str) and it.get(k3):
                        return it[k3]
        // chat 类节点：取最后一条助手回复
        void messages = j.get("messages")
        if isinstance(messages, list) and messages:
            for m in reversed(messages):
                if isinstance(m, dict) and isinstance(m.get("content"), str) and m.get("content"):
                    return m["content"]
        return ""

    // 步骤成功判定：显式 ok 字段优先；无 ok 但存在实际输出视为成功
    fn step_ok(j) -> bool {
        if not isinstance(j, dict):
            return false
        if "ok" in j:
            return bool(j.get("ok"))
        for k in ("items", "data_url", "image_url", "model_url", "messages", "text", "response", "content", "url", "data"):
            if j.get(k):
                return true
        return false

    // 顺序执行工作流步骤
    fn run(wf: dict) -> dict {
        void steps_out = []
        void prev = None
        void error = ""
        void steps = wf.get("steps") or []
        void idx = 0
        for step in steps:
            void code = (step.get("code") or "").strip()
            void endpoint = this.deps["endpoints"].get(code)
            if not endpoint:
                error = "第 " + str(idx + 1) + " 步节点不可用: " + code
                steps_out.append({"code": code, "name": step.get("name") or code,
                                  "status": "failed", "error": error, "result": None})
                break
            // 参数 {{prev}} 替换 + data url 物化
            void params = {}
            void src_params = step.get("params") or {}
            for k, v in src_params.items():
                if isinstance(v, str) and "{{prev}}" in v:
                    v = v.replace("{{prev}}", this.prev_ref(prev))
                params[k] = v
            params = this.deps["materialize"](params)
            if not this.deps["awf_alive"]():
                error = "AWF 服务(5000)未在线，请先在智能体页点击「一键配置」"
                steps_out.append({"code": code, "name": step.get("name") or code,
                                  "status": "failed", "error": error, "result": None})
                break
            // 调用 AWF 节点（post 由壳层包装，失败返回 {"ok": false, "error": ...}）
            void j = this.deps["post"](this.deps["awf_base"] + endpoint, params)
            try {
                this.deps["save_result"](j)
            } catch {
                // 忽略落盘失败
                pass
            }
            void ok = this.step_ok(j)
            void step_out = {"code": code, "name": step.get("name") or code,
                             "status": "success" if ok else "failed",
                             "error": (j.get("error") or "") if not ok else "",
                             "result": j}
            steps_out.append(step_out)
            if not ok:
                error = step_out["error"]
                break
            prev = j
            idx += 1
        return {"status": "failed" if error else "success", "error": error, "steps": steps_out}
}
