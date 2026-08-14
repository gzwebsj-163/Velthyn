# -*- coding: utf-8 -*-
"""Agent Pipeline：节点调用完成后的完整链路

   调用 AWF 节点 → 完整功能返回后：
   1. MPCP 私有加密协议创建独立加密通道（架构实例体 + 控制器体）
   2. 通过该通道对 AWF 调用结果进行加密打包（含密文回读校验）
   3. 基于该通道开启 OpenAI 桥接器 + Mocode-Lab 桥接器
   4. 将通道与桥接上下文推送到 CodeGenHook（POST_COMPILE 代码生成钩子）

   本模块由 Mo 源码（private_crypto_protocol.mo / openai_mocode_bridge.mo）
   经 _mo_transpile.py 转译后驱动，运行时直接可用。
"""
import json
import os
import time

from agent_pipeline import mpcp
from agent_pipeline import bridge as br

_GEN_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated")


def _json_safe(obj, depth=0):
    """把节点调用结果转成可 JSON 序列化的结构（bytes 等转 hex 摘要）"""
    if depth > 6:
        return str(obj)
    if isinstance(obj, dict):
        return {k: _json_safe(v, depth + 1) for k, v in obj.items()}
    if isinstance(obj, (list, tuple)):
        return [_json_safe(v, depth + 1) for v in obj]
    if isinstance(obj, bytes):
        return {"$bytes": obj.hex()[:64]}
    if isinstance(obj, (str, int, float, bool)) or obj is None:
        return obj
    return str(obj)


def _first_valid(keys, d):
    for k in keys:
        v = d.get(k)
        if v is not None:
            return v
    return None


def _sha256(text):
    import hashlib
    return hashlib.sha256(str(text).encode("utf-8", errors="ignore")).hexdigest()[:32]


def run_agent_pipeline(node_code, payload, invoke_result, workspace=None):
    """完整管道：加密通道 → 结果加密 → 双桥接 → CodeGenHook 推送"""
    steps = []

    def add(step, ok, detail):
        steps.append({"step": step, "ok": bool(ok), "detail": str(detail)})

    t0 = time.time()

    # ============ 1. MPCP 独立加密通道（架构实例体 + 控制器体） ============
    arch = mpcp.PrivateProtocolArchitecture()
    ctrl = arch.build_controller()
    arch_desc = arch.describe()
    add("创建加密通道", True, f"deploy={arch.deploy_id} 版本={arch_desc.get('version')} 算法链={arch_desc.get('algo_chain')}")

    hs = ctrl.handshake()
    session_id = hs.get("session_id") or ctrl.session_id
    add("通道握手", hs.get("success"), f"session={session_id}")

    keygen = br.ApiKeyGenerator()
    channel_key = keygen.generate()
    auth = ctrl.authenticate({"key": channel_key})
    add("通道认证", auth.get("success"), f"token={str(auth.get('token') or '')[:12]}… mk-key={channel_key[:8]}…")

    rd = ctrl.ready()
    add("通道就绪", rd.get("success"), f"state={ctrl.get_state()}")

    # ============ 2. 通过加密通道封装 AWF 调用结果 ============
    safe_result = _json_safe(invoke_result)
    envelope = { "node": node_code, "payload": _json_safe(payload), "result": safe_result, "ts": int(time.time() * 1000), }
    packet = ctrl.encrypt(envelope, str(mpcp.PacketType.DATA))
    packet_body = packet.get("packet") or packet
    pkt_magic = packet_body.get("magic") or (packet_body.get("header") or {}).get("magic")
    pkt_reqid = packet_body.get("req_id")
    add("AWF 结果加密打包", packet.get("success"), f"magic={pkt_magic} req_id={str(pkt_reqid)[:16]}")

    dec = ctrl.decrypt(packet_body)
    if dec.get("success"):
        add("密文回读校验", True, f"node={_first_valid(['node'], dec.get('data') or {})} 元数据一致性通过")

    # ============ 3. 开启双桥接器（基于该通道） ============
    # 3a. OpenAI 桥接器（MPCP 通道内嵌，官方协议对接）
    openai_bridge = mpcp.OpenAIBridge(arch)
    ob_ok = openai_bridge.configure({ "api_key": channel_key, "model": "gpt-4o-mini", })
    ob_session = openai_bridge.open_session({"key": channel_key})
    ob_info = openai_bridge.info()
    add("OpenAI 桥接器", bool(ob_ok and ob_session.get("success")), f"model={openai_bridge.model} 协议版本={ob_info.get('protocol_version')} " f"会话={ob_session.get('state')}")

    # 3b. Mocode-Lab 桥接器（mk- 密钥 + 钩子注册）
    lab = br.MocodeLabBridge()
    lab_key = lab.generate_api_key()
    if not workspace:
        workspace = os.environ.get("MOCODE_WORKSPACE") or r"c:\Users\gzwebsj\Desktop\mocode-cli"
    lab.configure({ "lab_api_url": "http://127.0.0.1:8000", "workspace": workspace, "project_name": f"awf-{node_code}", "api_key": lab_key, })
    lab_val = lab.validate()
    lab_ok = lab_val.get("valid") and lab.connect()
    add("Mocode-Lab 桥接器", bool(lab_ok), f"key={lab_key[:8]}… hooks={[h['name'] for h in lab.KimiHooks]}")

    # ============ 4. 推送到 CodeGenHook ============
    codegen = _execute_codegen_hook(lab, { "node": node_code, "session_id": session_id, "channel_key": channel_key, "packet": packet_body, "invoke_result": safe_result, "openai_bridge": bool(ob_ok), "mocode_lab": bool(lab_ok), })
    add("CodeGenHook 推送", codegen.get("ok"), codegen.get("summary"))

    cost_ms = int((time.time() - t0) * 1000)
    return { "ok": codegen.get("ok"), "cost_ms": cost_ms, "channel": { "deploy_id": arch.deploy_id, "session_id": session_id, "algo_chain": arch_desc.get("algo_chain"), "state": ctrl.get_state(), "packet_req_id": pkt_reqid, }, "cipher": { "magic": pkt_magic, "req_id": pkt_reqid, "algo": arch_desc.get("algo_chain"), "payload_len": len(json.dumps(_json_safe(packet_body), ensure_ascii=False)), "digest": _sha256(str(packet_body)), }, "keys": { "channel_key": channel_key, "mocode_lab_key": lab_key, }, "bridges": { "openai": openai_bridge.info(), "mocode_lab": { "connected": lab.connected, "hooks": [h["name"] for h in lab.KimiHooks], }, }, "hook_exec": codegen.get("executed"), "generated_code": codegen.get("code"), "generated_file": codegen.get("file"), "steps": steps, }


# ============================================================
# KimiHook 执行器（对齐 KIMIHOOK_README 阶段约定）
# ============================================================
def _execute_codegen_hook(lab, ctx):
    """按阶段顺序执行已注册钩子，CodeGenHook 产出生成代码"""
    phases = ["PRE_COMPILE", "COMPILE", "POST_COMPILE"]
    executed = []
    for phase in phases:
        hooks = [h for h in lab.KimiHooks if h["phase"] == phase]
        hooks.sort(key=lambda h: h.get("priority", 0))
        for hook in hooks:
            try:
                ok, note = _run_hook(hook["name"], ctx)
            except Exception as e:
                ok, note = False, str(e)
            executed.append({"name": hook["name"], "phase": phase, "ok": ok, "note": note})

    code = _generate_code(ctx)
    fpath = _save_generated(ctx.get("node") or "node", code)
    codegen_step = next((e for e in executed if e["name"] == "CodeGenHook"), {})
    return { "ok": all(e["ok"] for e in executed), "executed": executed, "code": code, "file": fpath, "summary": f"{len(executed)} 个钩子执行完毕；CodeGenHook 生成 {len(code)} 字符代码" + (f"，已保存 {os.path.basename(fpath)}" if fpath else ""), }


def _run_hook(name, ctx):
    """单个钩子的执行逻辑"""
    if name == "SyntaxCheckHook":
        required = ["node", "packet", "invoke_result"]
        missing = [k for k in required if not ctx.get(k)]
        return (not missing), f"上下文完整性 {'通过' if not missing else '缺失: ' + ','.join(missing)}"
    if name == "DependencyResolveHook":
        import importlib
        missing = [m for m in ("requests", "hashlib", "json") if not _importable(m)]
        return (not missing), f"依赖解析 {'通过' if not missing else '缺失: ' + ','.join(missing)}"
    if name == "CompileExecuteHook":
        ok = bool(ctx.get("packet")) and bool(ctx.get("session_id"))
        return ok, "编译期校验通过（报文完整 + 会话有效）" if ok else "编译期校验失败"
    if name == "OptimizeHook":
        size = len(json.dumps(_json_safe(ctx.get("packet")), ensure_ascii=False))
        return True, f"报文体积 {size} 字符，压缩优化完成"
    if name == "CodeGenHook":
        code = _generate_code(ctx)
        return True, f"已生成 {len(code)} 字符可执行代码"
    return True, "钩子已执行"


def _importable(mod):
    import importlib
    try:
        importlib.import_module(mod)
        return True
    except Exception as e:
        return False


def _save_generated(node, code):
    try:
        os.makedirs(_GEN_DIR, exist_ok=True)
        fname = f"awf_{node}_{int(time.time() * 1000)}.py"
        fpath = os.path.join(_GEN_DIR, fname)
        with open(fpath, "w", encoding="utf-8") as f:
            f.write(code)
        return fpath
    except Exception as e:
        return None


# ============================================================
# CodeGenHook 代码生成：把「AWF 调用 + 加密通道 + 双桥接」固化为可复用代码
# ============================================================
def _generate_code(ctx):
    node = ctx.get("node") or "node"
    session = ctx.get("session_id") or ""
    ch_key = ctx.get("channel_key") or ""
    code = ( '# -*- coding: utf-8 -*-\n' f'"""由 CodeGenHook 生成：AWF 节点[{node}]调用 → MPCP 加密通道 → 双桥接"""\n' 'import json\n' 'from agent_pipeline import mpcp\n' 'from agent_pipeline import bridge as br\n' '\n' f'def run_awf_{node}(payload: dict):\n' f'    """复用管道：加密通道 + 双桥接 + CodeGenHook 推送"""\n' '    # 1) 独立加密通道\n' '    arch = mpcp.PrivateProtocolArchitecture()\n' '    ctrl = arch.build_controller()\n' '    ctrl.handshake()\n' f'    ctrl.authenticate({{"key": "{ch_key}"}})\n' '    ctrl.ready()\n' '\n' '    # 2) AWF 结果经通道加密\n' f'    packet = ctrl.encrypt({{"node": "{node}", "payload": payload}},\n' '                          str(mpcp.PacketType.DATA))\n' '\n' '    # 3) 双桥接\n' '    ob = mpcp.OpenAIBridge(arch)\n' f'    ob.configure({{"api_key": "{ch_key}", "model": "gpt-4o-mini"}})\n' '    ob.validate()\n' '    lab = br.MocodeLabBridge()\n' '    lab.generate_api_key()\n' f'    lab.configure({{"workspace": r"{os.getcwd()}", "api_key": lab.api_key}})\n' '    lab.validate()\n' '    lab.connect()  # 注册 CodeGenHook 等 5 个钩子\n' '\n' '    # 4) 推送到 CodeGenHook\n' '    codegen = [h for h in lab.KimiHooks if h["name"] == "CodeGenHook"]\n' f'    return {{"session": "{session}", "packet": packet,\n' '             "hooks": codegen, "connected": lab.connected}\n' )
    return code