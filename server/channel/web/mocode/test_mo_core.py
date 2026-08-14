# -*- coding: utf-8 -*-
"""Mo 核心业务层冒烟测试：不依赖 web_channel，验证全部转译模块。"""
import os
import sys
import shutil
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from workflow_store import WorkflowStore
from workflow_engine import WorkflowEngine
from model_config import ModelConfig
from chat_orchestrator import ChatOrchestrator


def test_store():
    d = tempfile.mkdtemp()
    p = os.path.join(d, "workflows.json")
    store = WorkflowStore(p)
    assert store.load() == {"workflows": [], "runs": []}
    wf = {"id": store.new_id("wf"), "name": "t", "steps": [{"code": "enhance"}]}
    store.create(wf)
    assert len(store.list_workflows()) == 1
    assert store.find(wf["id"])["name"] == "t"
    upd = store.update(wf["id"], {"name": "t2", "steps": [{"code": "tts"}]})
    assert upd["name"] == "t2" and upd["steps"][0]["code"] == "tts"
    store.add_run({"id": "r1", "status": "success"})
    assert store.list_runs()[0]["status"] == "success"
    assert store.delete(wf["id"]) is True
    assert store.delete(wf["id"]) is False
    assert store.list_workflows() == []
    print("[ok] WorkflowStore")


def test_engine():
    calls = []
    deps = {
        "endpoints": {"enhance": "/api/enhance", "tts": "/api/tts/generate"},
        "awf_base": "http://127.0.0.1:5000",
        "materialize": lambda p: p,
        "awf_alive": lambda: True,
        "save_result": lambda j: None,
        "post": lambda url, params: calls.append((url, params)) or {"ok": True, "image_url": "http://x/1.jpg"},
    }
    eng = WorkflowEngine(deps)
    r = eng.run({"steps": [
        {"code": "enhance", "params": {"image": "http://a/1.jpg"}},
        {"code": "tts", "params": {"prompt": "{{prev}}"}},
    ]})
    assert r["status"] == "success", r
    assert len(r["steps"]) == 2
    # tts 的 prompt 被替换为上一输出 image_url
    assert calls[1][1]["prompt"] == "http://x/1.jpg"
    # 未知节点
    r2 = eng.run({"steps": [{"code": "nope", "params": {}}]})
    assert r2["status"] == "failed" and "不可用" in r2["error"]
    print("[ok] WorkflowEngine")


def test_model_config():
    meta = {
        "deepseek": {"key_field": "deepseek_api_key", "base_key": "deepseek_api_base", "base_default": "https://api.deepseek.com/v1"},
        "openai": {"key_field": "open_ai_api_key", "base_key": "open_ai_api_base", "base_default": "https://api.openai.com/v1"},
    }
    mc = ModelConfig(meta, custom_resolver=lambda pid, m: {"provider": pid, "model": m, "api_key": "ck", "api_base": "https://custom"})
    cred = mc.credentials({"bot_type": "deepseek", "model": "deepseek-v4-flash", "deepseek_api_key": "sk-123", "deepseek_api_base": ""})
    assert cred["provider"] == "deepseek" and cred["api_key"] == "sk-123" and cred["api_base"] == "https://api.deepseek.com/v1"
    # 未配置 bot_type，从模型名推断
    cred2 = mc.credentials({"model": "gpt-5", "open_ai_api_key": "k"})
    assert cred2["provider"] == "openai"
    # 自定义厂商
    cred3 = mc.credentials({"bot_type": "custom:abc", "model": "m"})
    assert cred3["provider"] == "custom:abc" and cred3["api_base"] == "https://custom"
    # 无凭据
    assert mc.credentials({}) is None
    print("[ok] ModelConfig")


def test_chat():
    llm_res = {"success": True, "content": '好的，已生成方案。{"plan":[{"code":"enhance","params":{"image":"x.jpg"}},{"code":"fake","params":{}}]}', "packet": {"magic": "MPCP", "req_id": "r1"}}
    pushed = {}
    deps = {
        "endpoints": {"enhance": "/api/enhance", "chat": "/api/chat"},
        "llm_call": lambda sys_p, msg: llm_res,
        "pipeline_push": lambda msg, reply: pushed.update(reply=reply) or {"ok": True, "hook_exec": [{"name": "OptimizeHook", "ok": True, "note": "ok"}]},
    }
    co = ChatOrchestrator(deps)
    r = co.run("把图片增强")
    assert r["status"] == "success"
    assert len(r["steps"]) == 1 and r["steps"][0]["code"] == "enhance"  # fake 被过滤
    assert r["skipped"] == ["fake"]
    assert r["cipher"]["magic"] == "MPCP"
    assert r["pipeline"]["ok"] is True
    # chat 节点注入 message
    llm_res["content"] = '{"plan":[{"code":"chat","params":{}}]}'
    r2 = co.run("帮我写首诗")
    assert r2["steps"][0]["params"]["message"] == "帮我写首诗"
    # 模型失败
    deps["llm_call"] = lambda s, m: {"success": False, "error": "boom"}
    r3 = co.run("x")
    assert r3["status"] == "error"
    print("[ok] ChatOrchestrator")


def test_mpcp():
    from mpcp import PrivateProtocolArchitecture, build_private_protocol
    arch = PrivateProtocolArchitecture()
    # 加解密往返
    packet = arch.encrypt({"msg": "你好", "n": 42})
    assert packet["magic"] == "MPCP" and packet["type"] == "DATA"
    dec = arch.decrypt(packet)
    assert dec["success"] and dec["data"]["msg"] == "你好" and dec["data"]["n"] == 42
    assert dec["data"]["_meta"]["valid"] is True
    # 篡改 req_id -> 一致性校验失败
    bad = dict(packet)
    bad["req_id"] = "tampered"
    assert arch.decrypt(bad)["data"]["_meta"]["valid"] is False
    # 协议头错误
    bad2 = dict(packet)
    bad2["magic"] = "XXXX"
    assert arch.decrypt(bad2)["success"] is False
    # 控制器状态机：INIT -> HANDSHAKE -> AUTHENTICATED -> READY
    ctrl = arch.build_controller()
    hs = ctrl.handshake()
    assert hs["success"] and ctrl.get_state() != "INIT"
    auth = ctrl.authenticate({"key": "sk-test"})
    assert auth["success"]
    rdy = ctrl.ready()
    assert rdy["success"]
    p = ctrl.encrypt({"hello": "world"})
    assert p["success"] and ctrl.validate(p["packet"])
    # 未就绪控制器拒绝加密
    ctrl2 = arch.build_controller()
    assert ctrl2.encrypt({"x": 1})["success"] is False
    # OpenAIBridge 会话流程
    built = build_private_protocol()
    bridge = built["bridge"]
    s = bridge.open_session({"key": "k1"})
    assert s["success"] and s["session_id"]
    assert bridge.info()["protocol_version"] == "APLCE2.0"
    # 未配置 API Key 的 chat_completion
    assert bridge.chat_completion([{"role": "user", "content": "hi"}])["success"] is False
    print("[ok] MPCP")


def test_base_tool():
    from base_tool import ToolStage, ToolResult, BaseTool
    assert ToolResult.success("ok").status == "success"
    assert ToolResult.fail("bad").status == "error"
    assert ToolResult.success("ok", {"x": 1}).ext_data == {"x": 1}

    logs = []

    class FakeTool(BaseTool):
        name = "fake"
        description = "Fake tool"
        params = {"type": "object", "properties": {"a": {"type": "string"}}}

        def execute(self, params):
            return ToolResult.success("done:" + params.get("a", ""))

    t = FakeTool(log=lambda m: logs.append(m))
    assert FakeTool.get_json_schema()["name"] == "fake"
    assert t.should_auto_execute(None) is False
    assert t.execute_tool({"a": "x"}).result == "done:x"
    assert FakeTool._parse_schema()["a"] == (str, ...)
    # execute_tool 异常返回 None 并记录日志
    logs2 = []

    class Boom(BaseTool):
        name = "boom"

        def execute(self, params):
            raise RuntimeError("boom")

    b = Boom(log=lambda m: logs2.append(m))
    assert b.execute_tool({}) is None
    assert len(logs2) == 1
    # 取消事件判定
    class CancelEvent:
        def is_set(self):
            return True

    b.cancel_event = CancelEvent()
    assert b.is_cancelled() is True
    print("[ok] BaseTool")


def test_prompt_builder():
    from prompt_builder import SystemPromptAssembler

    class Tool:
        def __init__(self, name):
            self.name = name

    class CtxFile:
        def __init__(self, path, content):
            self.path = path
            self.content = content

    zh = SystemPromptAssembler("/ws", "zh")
    # 工具排序：偏好顺序在前，其余按字母序，未收录有兜底行
    lines = zh.build_tooling([Tool("zzz_extra"), Tool("read"), Tool("bash")])
    text = "\n".join(lines)
    assert "read" in text and "bash" in text and "- zzz_extra" in text
    assert text.index("read") < text.index("bash") < text.index("zzz_extra")
    # 章节固定顺序
    builders = {"skills": ["## SKILLS"], "memory": ["## MEMORY"], "knowledge": ["## KNOWLEDGE"], "workspace": ["## WORKSPACE"]}
    full = zh.build(builders, tools=[Tool("read")], user_identity={"name": "小明"}, runtime_info={"model": "deepseek-v4-flash", "channel": "web"})
    keys = ["## 🔧 工具系统", "## SKILLS", "## MEMORY", "## KNOWLEDGE", "## WORKSPACE", "## 👤 用户身份", "## ⚙️ 运行时信息", "## 🌐 回复语言"]
    idx = {k: full.find(k) for k in keys}
    order = sorted(keys, key=lambda k: idx[k])
    assert order == keys
    assert "小明" in full
    # web 渠道默认不展示 channel；模型展示
    assert "channel=web" not in full and "模型=deepseek-v4-flash" in full
    # AGENT.md 灵魂文件规则
    en = SystemPromptAssembler("/ws", "en")
    cf = en.build_context_files([CtxFile("AGENT.md", "persona"), CtxFile("notes.md", "note")])
    ctext = "\n".join(cf)
    assert "soul file" in ctext and "persona" in ctext
    # 动态时间 callable
    rt = zh.build_runtime({"_get_current_time": lambda: {"time": "10:00", "weekday": "周一", "timezone": "Asia/Shanghai"}})
    assert "10:00" in "\n".join(rt)
    print("[ok] PromptBuilder")


def test_skill_service():
    from skill_service import SkillServiceCore
    root = tempfile.mkdtemp()
    custom_dir = os.path.join(root, "skills")
    os.makedirs(custom_dir)
    state = {"config": {}, "enabled": [], "calls": []}

    def make_deps(**over):
        d = {
            "custom_dir": custom_dir,
            "refresh_skills": lambda: state["calls"].append("refresh"),
            "get_skills_config": lambda: state["config"],
            "save_skills_config": lambda: None,
            "set_skill_enabled": lambda n, e: state["enabled"].append((n, e)),
            "download": lambda u, d: open(d, "w", encoding="utf-8").write("x"),
            "mkdir": os.makedirs,
            "rmtree": lambda p: shutil.rmtree(p, ignore_errors=True),
            "rename": os.rename,
            "exists": os.path.exists,
            "copytree": lambda s, d: shutil.copytree(s, d),
            "is_zipfile": lambda p: zipfile.is_zipfile(p),
            "extract_package": lambda z, d: zipfile.ZipFile(z).extractall(d),
            "tmp_dir": lambda: tempfile.mkdtemp(),
            "cleanup_tmp": lambda p: shutil.rmtree(p, ignore_errors=True),
            "log": lambda lv, m: state["calls"].append(("log", lv)),
        }
        d.update(over)
        return d

    svc = SkillServiceCore(make_deps())
    # dispatch 协议状态机
    r = svc.dispatch("query")
    assert r["code"] == 200 and r["payload"] == []
    r = svc.dispatch("nope")
    assert r["code"] == 400
    # open / close
    r = svc.dispatch("open", {"name": "web_search"})
    assert r["code"] == 200 and state["enabled"] == [("web_search", True)]
    r = svc.dispatch("close", {"name": "web_search"})
    assert state["enabled"][-1] == ("web_search", False)
    # 目录穿越被拒绝
    for evil in ["../evil", "/abs", "\\abs", ""]:
        try:
            svc.safe_skill_dir(evil)
            assert False, evil
        except ValueError:
            pass
    # add via url 安装并落盘
    r = svc.dispatch("add", {"name": "demo", "files": [{"url": "http://x/a.md", "path": "SKILL.md"}]})
    assert r["code"] == 200
    assert os.path.exists(os.path.join(custom_dir, "demo", "SKILL.md"))
    # delete 删除目录
    r = svc.dispatch("delete", {"name": "demo"})
    assert r["code"] == 200 and not os.path.exists(os.path.join(custom_dir, "demo"))
    # 空文件列表 -> 500
    r = svc.dispatch("add", {"name": "empty"})
    assert r["code"] == 500
    print("[ok] SkillService")


def test_memory_config():
    from memory_config import MemoryConfigCore
    mc = MemoryConfigCore("/tmp/ws")
    assert mc.memory_dir() == os.path.join("/tmp/ws", "memory")
    assert mc.db_path().endswith(os.path.join("long-term", "index.db"))
    assert mc.skills_dir() == os.path.join("/tmp/ws", "skills")
    assert mc.vector_weight == 0.7 and mc.keyword_weight == 0.3
    mc2 = MemoryConfigCore("/ws", vector_weight=0.8, keyword_weight=0.2)
    assert mc2.vector_weight == 0.8 and mc2.keyword_weight == 0.2
    print("[ok] MemoryConfig")


if __name__ == "__main__":
    test_store()
    test_engine()
    test_model_config()
    test_chat()
    test_mpcp()
    test_base_tool()
    test_prompt_builder()
    test_skill_service()
    test_memory_config()
    print("ALL MO TESTS PASSED")
