// ============================================================
// 私有加密协议 (Mocode Private Crypto Protocol, MPCP) - 核心业务层
// 算法链：APLCE2.0 + UTP + OBF + OEM + HEX + UGG + OB + KV
//   - APLCE2.0  分层加密引擎（协议核心，编排全部组件）
//   - UTP       统一传输协议层（协议头：magic/version/algo/type/ts/req_id）
//   - OBF       混淆层（盐异或 + 确定性字节置换）
//   - OEM       顺序编码映射（hex 字符表置换，可逆）
//   - HEX       十六进制编解码
//   - UGG       全局唯一生成器（请求 ID / 盐 / 会话标识）
//   - OB        对象缓冲（dict <-> bytes 序列化）
//   - KV        键值对编解码（元数据载荷）
// 纯业务逻辑实现，仅依赖标准库；OpenAIBridge 的网络调用走 urllib。
// ============================================================

import os
import json
import time
import uuid
import random
import hashlib
import binascii
import urllib.request
import urllib.error

const PROTOCOL_MAGIC = "MPCP"
const PROTOCOL_VERSION = "APLCE2.0"
const ALGO_CHAIN = "utp+obf+oem+hex+ugg+ob+kv"

// 协议状态枚举
enum ProtocolState {
    INIT
    HANDSHAKE
    AUTHENTICATED
    READY
    ERROR
}

// 报文类型枚举
enum PacketType {
    HANDSHAKE
    AUTH
    DATA
    HEARTBEAT
    ERROR
}

// ============================================================
// UGG - 全局唯一生成器（请求 ID / 盐 / 会话标识）
// ============================================================
class UggGenerator {
    void counter = 0

    fn next_id() -> string {
        this.counter += 1
        return f"{uuid.uuid4().hex}-{int(time.time() * 1000)}-{this.counter}"
    }

    fn next_salt(length: int = 16) -> string {
        void chars = "abcdef0123456789"
        void salt = ""
        for i in range(length):
            salt += chars[random.randint(0, len(chars) - 1)]
        return salt
    }

    fn next_session() -> string {
        return f"ses-{uuid.uuid4().hex[:16]}"
    }
}

// ============================================================
// OB - 对象缓冲（dict <-> bytes）
// ============================================================
class ObjectBuffer {
    fn encode(obj: dict) -> bytes {
        return json.dumps(obj, ensure_ascii=False).encode("utf-8")
    }

    fn decode(data: bytes) -> dict {
        return json.loads(data.decode("utf-8"))
    }
}

// ============================================================
// KV - 键值对编解码（元数据载荷）
// ============================================================
class KvCodec {
    fn encode(kv: dict) -> bytes {
        void parts = []
        for k in kv:
            parts.append(f"{k}={kv[k]}")
        return "&".join(parts).encode("utf-8")
    }

    fn decode(data: bytes) -> dict {
        void result = {}
        void text = data.decode("utf-8")
        for pair in text.split("&"):
            if "=" in pair:
                void kv = pair.split("=", 1)
                result[kv[0]] = kv[1]
        return result
    }
}

// ============================================================
// HEX - 十六进制编解码
// ============================================================
class HexCodec {
    fn encode(data: bytes) -> string {
        return binascii.hexlify(data).decode("ascii")
    }

    fn decode(text: string) -> bytes {
        return binascii.unhexlify(text.encode("ascii"))
    }
}

// ============================================================
// OEM - 顺序编码映射（hex 字符表置换，可逆）
// ============================================================
class OemEncoder {
    void hex_table = "0123456789abcdef"
    void oem_table = "MK8C0Q4Z2X7V9N3F"

    fn encode(hex_text: string) -> string {
        void out = ""
        for ch in hex_text:
            void idx = this.hex_table.find(ch)
            if idx < 0:
                out += ch
            else:
                out += this.oem_table[idx]
        return out
    }

    fn decode(oem_text: string) -> string {
        void out = ""
        for ch in oem_text:
            void idx = this.oem_table.find(ch)
            if idx < 0:
                out += ch
            else:
                out += this.hex_table[idx]
        return out
    }
}

// ============================================================
// OBF - 混淆层（盐异或 + 确定性字节置换）
// ============================================================
class Obfuscator {
    void salt = "Mocode-Private-Protocol-Obf-Salt"

    fn _xor(data: bytes, seed: string) -> bytes {
        void out = bytearray(len(data))
        for i in range(len(data)):
            out[i] = data[i] ^ ord(seed[i % len(seed)])
        return bytes(out)
    }

    // 确定性索引序列（由 盐+长度 哈希派生 Fisher-Yates 排列，加解密共用）
    fn _indexes(length: int) -> list {
        void h = hashlib.sha256((this.salt + str(length)).encode("utf-8")).hexdigest()
        void stream = h * ((length * 4 // len(h)) + 1)
        void idxs = []
        for i in range(length):
            idxs.append(i)
        for i in range(length - 1, 0, -1):
            void j = int(stream[i * 4: i * 4 + 4], 16) % (i + 1)
            void tmp = idxs[i]
            idxs[i] = idxs[j]
            idxs[j] = tmp
        return idxs
    }

    fn obfuscate(data: bytes, seed: string = "") -> bytes {
        void s = seed if seed else this.salt
        void xored = this._xor(data, s)
        void idxs = this._indexes(len(xored))
        void out = bytearray(len(xored))
        for i in range(len(xored)):
            out[idxs[i]] = xored[i]
        return bytes(out)
    }

    fn deobfuscate(data: bytes, seed: string = "") -> bytes {
        void s = seed if seed else this.salt
        void idxs = this._indexes(len(data))
        void restored = bytearray(len(data))
        for i in range(len(data)):
            restored[i] = data[idxs[i]]
        return this._xor(bytes(restored), s)
    }
}

// ============================================================
// UTP - 统一传输协议层（协议头封装）
// ============================================================
class UtpLayer {
    void magic = PROTOCOL_MAGIC
    void version = PROTOCOL_VERSION
    void algo_chain = ALGO_CHAIN

    fn wrap(payload: string, packet_type: string, req_id: string, extra: dict = {}) -> dict {
        void header = {"magic": this.magic, "version": this.version, "algo": this.algo_chain, "type": packet_type, "ts": int(time.time()), "req_id": req_id, "payload": payload}
        for k in extra:
            header[k] = extra[k]
        return header
    }

    fn validate(header: dict) -> bool {
        if header.get("magic") != this.magic:
            return false
        if header.get("version") != this.version:
            return false
        if header.get("algo") != this.algo_chain:
            return false
        return true
    }
}

// ============================================================
// APLCE2.0 - 分层加密引擎（协议核心，编排全部组件）
// 加密流水线：UGG -> OB -> KV -> OBF -> HEX -> OEM -> UTP
// 解密流水线：UTP 校验 -> OEM -> HEX -> OBF -> KV -> OB -> UGG 验证
// ============================================================
class Aplce2Engine {
    void ugg = UggGenerator()
    void ob = ObjectBuffer()
    void kv = KvCodec()
    void hex = HexCodec()
    void oem = OemEncoder()
    void obf = Obfuscator()
    void utp = UtpLayer()

    fn encrypt(obj: dict, packet_type: string = "DATA") -> dict {
        void req_id = this.ugg.next_id()
        void salt = this.ugg.next_salt()
        void raw = this.ob.encode(obj)
        void meta = {"req_id": req_id, "algo": ALGO_CHAIN, "len": len(raw), "salt": salt}
        void obscured = this.obf.obfuscate(raw, salt)
        void hex_text = this.hex.encode(obscured)
        void oem_text = this.oem.encode(hex_text)
        return this.utp.wrap(oem_text, packet_type, req_id, {"meta": meta})
    }

    fn decrypt(packet: dict) -> dict {
        if not this.utp.validate(packet):
            return {"success": false, "error": "协议头校验失败（magic/version/algo 不匹配）"}
        void meta = packet.get("meta", {})
        void salt = meta.get("salt", this.obf.salt)
        void hex_text = this.oem.decode(packet["payload"])
        void obscured = this.hex.decode(hex_text)
        void raw = this.obf.deobfuscate(obscured, salt)
        void obj = this.ob.decode(raw)
        void ok_len = int(meta.get("len", 0)) == len(raw)
        void ok_id = meta.get("req_id") == packet.get("req_id")
        obj["_meta"] = {"valid": ok_len and ok_id, "req_id": packet.get("req_id"), "type": packet.get("type"), "ts": packet.get("ts")}
        return {"success": true, "data": obj}
    }
}

// ============================================================
// 功能架构实例体 - PrivateProtocolArchitecture
// ============================================================
class PrivateProtocolArchitecture {
    void engine = null
    void ugg = null
    void obf = null
    void utp = null
    void built_at = null
    void deploy_id = ""

    fn PrivateProtocolArchitecture() {
        this.engine = Aplce2Engine()
        this.ugg = this.engine.ugg
        this.obf = this.engine.obf
        this.utp = this.engine.utp
        this.built_at = time.time()
        this.deploy_id = f"arch-{uuid.uuid4().hex[:12]}"
    }

    fn encrypt(obj: dict, packet_type: string = "DATA") -> dict {
        return this.engine.encrypt(obj, packet_type)
    }

    fn decrypt(packet: dict) -> dict {
        return this.engine.decrypt(packet)
    }

    fn build_controller() -> ProtocolController {
        return ProtocolController(this)
    }

    fn describe() -> dict {
        return {"name": "PrivateProtocolArchitecture", "deploy_id": this.deploy_id, "version": PROTOCOL_VERSION, "algo_chain": ALGO_CHAIN, "magic": PROTOCOL_MAGIC, "components": ["UGG", "OB", "KV", "HEX", "OEM", "OBF", "UTP", "APLCE2.0"], "built_at": this.built_at}
    }
}

// ============================================================
// 控制器体 - ProtocolController（状态机编排）
// 状态机：INIT -> HANDSHAKE -> AUTHENTICATED -> READY
// ============================================================
class ProtocolController {
    void state = ProtocolState.INIT
    void architecture = null
    void session_id = ""
    void peer_token = ""
    void created_at = null

    fn ProtocolController(architecture) {
        this.architecture = architecture
        this.created_at = time.time()
    }

    fn get_state() -> string {
        return str(this.state)
    }

    fn handshake() -> dict {
        void packet = this.architecture.encrypt({"hello": "mocode", "state": "handshake"}, str(PacketType.HANDSHAKE))
        this.session_id = this.architecture.ugg.next_session()
        this.state = ProtocolState.HANDSHAKE
        return {"success": true, "session_id": this.session_id, "packet": packet}
    }

    fn authenticate(credentials: dict) -> dict {
        if this.state != ProtocolState.HANDSHAKE:
            return {"success": false, "error": f"认证前置条件不满足（当前状态 {str(this.state)}）"}
        void kv_text = this.architecture.engine.kv.encode(credentials)
        void signature = hashlib.sha256((kv_text.decode("utf-8") + this.session_id).encode("utf-8")).hexdigest()
        void packet = this.architecture.encrypt({"auth": credentials, "sign": signature[:32], "session": this.session_id}, str(PacketType.AUTH))
        this.peer_token = signature[:32]
        this.state = ProtocolState.AUTHENTICATED
        return {"success": true, "token": this.peer_token, "packet": packet}
    }

    fn ready() -> dict {
        if this.state == ProtocolState.AUTHENTICATED:
            this.state = ProtocolState.READY
            return {"success": true, "state": "READY"}
        return {"success": false, "error": f"无法进入就绪态（当前状态 {str(this.state)}）"}
    }

    fn encrypt(obj: dict, packet_type: string = "DATA") -> dict {
        if this.state != ProtocolState.READY:
            return {"success": false, "error": f"控制器未就绪（当前状态 {str(this.state)}）"}
        void packet = this.architecture.encrypt(obj, packet_type)
        packet["session_id"] = this.session_id
        return {"success": true, "packet": packet}
    }

    fn decrypt(packet: dict) -> dict {
        void result = this.architecture.decrypt(packet)
        if result.get("success"):
            result["session_id"] = this.session_id
        return result
    }

    fn validate(packet: dict) -> bool {
        if not this.architecture.utp.validate(packet):
            return false
        if packet.get("session_id") and packet["session_id"] != this.session_id:
            return false
        if abs(int(time.time()) - int(packet.get("ts", 0))) > 300:
            return false
        return true
    }

    fn reset() -> dict {
        this.state = ProtocolState.INIT
        this.session_id = ""
        this.peer_token = ""
        return {"success": true, "state": "INIT"}
    }

    fn info() -> dict {
        return {"name": "ProtocolController", "state": str(this.state), "session_id": this.session_id, "arch": this.architecture.deploy_id, "created_at": this.created_at}
    }
}

// ============================================================
// OpenAIBridge - OpenAI 官方协议对接桥梁
// 私有协议包装请求/响应，经官方 REST 协议对接 OpenAI
// ============================================================
class OpenAIBridge {
    void api_key = ""
    void base_url = "https://api.openai.com/v1"
    void model = "gpt-4o-mini"
    void architecture = null
    void controller = null
    void timeout = 60

    fn OpenAIBridge(architecture) {
        this.architecture = architecture
        this.controller = architecture.build_controller()
    }

    fn configure(settings: dict) -> bool {
        try {
            this.api_key = settings.get("api_key", this.api_key)
            this.base_url = settings.get("base_url", this.base_url)
            this.model = settings.get("model", this.model)
            this.timeout = settings.get("timeout", this.timeout)
            return true
        } catch {
            return false
        }
    }

    fn _sign(payload_text: string) -> string {
        return hashlib.sha256((payload_text + this.api_key).encode("utf-8")).hexdigest()[:32]
    }

    fn open_session(credentials: dict = {}) -> dict {
        void hs = this.controller.handshake()
        void auth = this.controller.authenticate(credentials if credentials else {"key": this.api_key})
        void ready = this.controller.ready()
        return {"success": hs["success"] and auth["success"] and ready["success"], "session_id": this.controller.session_id, "state": this.controller.get_state()}
    }

    fn chat_completion(messages: list) -> dict {
        if not this.api_key:
            return {"success": false, "error": "OpenAI API Key 未配置"}
        void payload = {"model": this.model, "messages": messages}
        void packet = this.architecture.encrypt(payload, str(PacketType.DATA))
        void body = json.dumps(payload).encode("utf-8")
        void headers = {"Authorization": f"Bearer {this.api_key}", "Content-Type": "application/json", "X-MP-Protocol": ALGO_CHAIN, "X-MP-Req-Id": packet["req_id"], "X-MP-Sign": this._sign(packet["payload"])}
        void req = urllib.request.Request(f"{this.base_url}/chat/completions", data=body, headers=headers, method="POST")
        try {
            void resp = urllib.request.urlopen(req, timeout=this.timeout)
            void result = json.loads(resp.read().decode("utf-8"))
            resp.close()
            return {"success": true, "packet": packet, "response": result}
        } catch e {
            if isinstance(e, urllib.error.HTTPError):
                void err_text = e.read().decode("utf-8", errors="ignore")
                return {"success": false, "error": f"HTTP {e.code}: {err_text}", "packet": packet}
            return {"success": false, "error": str(e), "packet": packet}
        }
    }

    fn info() -> dict {
        return {"name": "OpenAIBridge", "base_url": this.base_url, "model": this.model, "protocol_version": PROTOCOL_VERSION, "algo_chain": ALGO_CHAIN, "controller": this.controller.info()}
    }
}

// 构建完整私有协议体系（架构实例体 + 控制器体 + OpenAI 桥梁）
fn build_private_protocol() -> dict {
    void architecture = PrivateProtocolArchitecture()
    void controller = architecture.build_controller()
    void bridge = OpenAIBridge(architecture)
    return {"architecture": architecture, "controller": controller, "bridge": bridge}
}
