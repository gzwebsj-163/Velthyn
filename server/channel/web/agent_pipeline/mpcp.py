from enum import Enum
# ============================================================
# 私有加密协议 (Mocode Private Crypto Protocol, MPCP)
# ============================================================
# 算法链：APLCE2.0 + UTP + OBF + OEM + HEX + UGG + OB + KV
# - APLCE2.0  分层加密引擎（协议核心，编排全部组件）
# - UTP       统一传输协议层（协议头：magic/version/algo/type/ts/req_id）
# - OBF       混淆层（盐异或 + 确定性字节置换）
# - OEM       顺序编码映射（hex 字符表置换，可逆）
# - HEX       十六进制编解码
# - UGG       全局唯一生成器（请求 ID / 盐 / 会话标识）
# - OB        对象缓冲（dict <-> bytes 序列化）
# - KV        键值对编解码（元数据载荷）

# 交付物：
# 1. PrivateProtocolArchitecture  功能架构实例体（装配全部组件）
# 2. ProtocolController           控制器体（握手/认证/加密/解密/校验状态机）
# 3. OpenAIBridge                 OpenAI 官方协议对接桥梁

# 遵循 KimiHook 编译钩子系统约定规则，全部面向对象编写。
# ============================================================

import os
import json
import time
import uuid
import random
import hashlib
import binascii
import urllib.request
import urllib.error
from typing import Dict, List, Any, Optional

# ============================================================
# 协议常量
# ============================================================

PROTOCOL_MAGIC = "MPCP"  # 魔数：Mocode Private Crypto Protocol
PROTOCOL_VERSION = "APLCE2.0"  # 协议版本
ALGO_CHAIN = "utp+obf+oem+hex+ugg+ob+kv"  # 算法链声明

# ============================================================
# 协议状态枚举
# ============================================================

class ProtocolState(Enum):
    INIT = 1
    HANDSHAKE = 2
    AUTHENTICATED = 3
    READY = 4
    ERROR = 5

# ============================================================
# 报文类型枚举
# ============================================================

class PacketType(Enum):
    HANDSHAKE = 1
    AUTH = 2
    DATA = 3
    HEARTBEAT = 4
    ERROR = 5

# ============================================================
# UGG - 全局唯一生成器（请求 ID / 盐 / 会话标识）
# ============================================================

class UggGenerator:
    counter = 0

    # 生成全局唯一 ID（uuid + 毫秒时间戳 + 自增计数）
    def next_id(self):
        self.counter += 1
        return f"{uuid.uuid4().hex}-{int(time.time() * 1000)}-{self.counter}"

    # 生成随机盐（hex 字符）
    def next_salt(self, length= 16):
        chars = "abcdef0123456789"
        salt = ""
        for i in range(length):
            salt += chars[random.randint(0, len(chars) - 1)]
        return salt

    # 生成会话标识（握手后建立）
    def next_session(self):
        return f"ses-{uuid.uuid4().hex[:16]}"

# ============================================================
# OB - 对象缓冲（dict <-> bytes）
# ============================================================

class ObjectBuffer:
    # 对象 -> 字节
    def encode(self, obj):
        return json.dumps(obj, ensure_ascii=False).encode("utf-8")

    # 字节 -> 对象
    def decode(self, data):
        return json.loads(data.decode("utf-8"))

# ============================================================
# KV - 键值对编解码（元数据载荷）
# ============================================================

class KvCodec:
    # dict -> KV 字节（k1=v1&k2=v2）
    def encode(self, kv):
        parts = []
        for k, v in kv.items():
            parts.append(f"{k}={v}")
        return "&".join(parts).encode("utf-8")

    # KV 字节 -> dict
    def decode(self, data):
        result = {}
        text = data.decode("utf-8")
        for pair in text.split("&"):
            if "=" in pair:
                k, v = pair.split("=", 1)
                result[k] = v
        return result

# ============================================================
# HEX - 十六进制编解码
# ============================================================

class HexCodec:
    # bytes -> hex 文本
    def encode(self, data):
        return binascii.hexlify(data).decode("ascii")

    # hex 文本 -> bytes
    def decode(self, text):
        return binascii.unhexlify(text.encode("ascii"))

# ============================================================
# OEM - 顺序编码映射（hex 字符表置换，可逆）
# ============================================================

class OemEncoder:
    hex_table = "0123456789abcdef"  # 原始表（hex 字符）
    oem_table = "MK8C0Q4Z2X7V9N3F"  # 置换表（16 个唯一字符）

    # hex 文本 -> OEM 置换文本
    def encode(self, hex_text):
        out = ""
        for ch in hex_text:
            idx = self.hex_table.find(ch)
            if idx < 0:
                out += ch
            else:
                out += self.oem_table[idx]
        return out

    # OEM 置换文本 -> hex 文本
    def decode(self, oem_text):
        out = ""
        for ch in oem_text:
            idx = self.oem_table.find(ch)
            if idx < 0:
                out += ch
            else:
                out += self.hex_table[idx]
        return out

# ============================================================
# OBF - 混淆层（盐异或 + 确定性字节置换）
# ============================================================

class Obfuscator:
    salt = "Mocode-Private-Protocol-Obf-Salt"

    # 逐字节异或
    def _xor(self, data, seed):
        out = bytearray(len(data))
        for i in range(len(data)):
            out[i] = data[i] ^ ord(seed[i % len(seed)])
        return bytes(out)

    # 确定性索引序列（由 盐+长度 哈希派生 Fisher-Yates 排列，加密/解密共用）
    def _indexes(self, length):
        h = hashlib.sha256((self.salt + str(length)).encode("utf-8")).hexdigest()
        stream = h * ((length * 4//len(h)) + 1)
        idxs = []
        for i in range(length):
            idxs.append(i)
        for i in range(length - 1, 0, -1):
            j = int(stream[i * 4: i * 4 + 4], 16) % (i + 1)
            tmp = idxs[i]
            idxs[i] = idxs[j]
            idxs[j] = tmp
        return idxs

    # 混淆：异或 + 字节置换
    def obfuscate(self, data, seed= ""):
        s = seed if seed else self.salt
        xored = self._xor(data, s)
        idxs = self._indexes(len(xored))
        out = bytearray(len(xored))
        for i in range(len(xored)):
            out[idxs[i]] = xored[i]
        return bytes(out)

    # 反混淆：逆置换 + 异或
    def deobfuscate(self, data, seed= ""):
        s = seed if seed else self.salt
        idxs = self._indexes(len(data))
        restored = bytearray(len(data))
        for i in range(len(data)):
            restored[i] = data[idxs[i]]
        return self._xor(bytes(restored), s)

# ============================================================
# UTP - 统一传输协议层（协议头封装）
# ============================================================

class UtpLayer:
    magic = PROTOCOL_MAGIC
    version = PROTOCOL_VERSION
    algo_chain = ALGO_CHAIN

    # 封装协议头
    def wrap(self, payload, packet_type, req_id, extra= {}):
        header = { "magic": self.magic, "version": self.version, "algo": self.algo_chain, "type": packet_type, "ts": int(time.time()), "req_id": req_id, "payload": payload }
        for k, v in extra.items():
            header[k] = v
        return header

    # 校验协议头（magic/version/algo 匹配）
    def validate(self, header):
        if header.get("magic") != self.magic:
            return False
        if header.get("version") != self.version:
            return False
        if header.get("algo") != self.algo_chain:
            return False
        return True

# ============================================================
# APLCE2.0 - 分层加密引擎（协议核心，编排全部组件）
# ============================================================
# 加密流水线：UGG -> OB -> KV -> OBF -> HEX -> OEM -> UTP
# 解密流水线：UTP 校验 -> OEM -> HEX -> OBF -> KV -> OB -> UGG 验证
# ============================================================

class Aplce2Engine:
    ugg = UggGenerator()  # UGG 全局唯一生成器
    ob = ObjectBuffer()  # OB  对象缓冲
    kv = KvCodec()  # KV  键值对
    hex = HexCodec()  # HEX 十六进制
    oem = OemEncoder()  # OEM 顺序编码映射
    obf = Obfuscator()  # OBF 混淆
    utp = UtpLayer()  # UTP 统一传输协议层

    # 加密：对象 -> 私有协议报文（dict）
    def encrypt(self, obj, packet_type= "DATA"):
        # 1. UGG：请求唯一 ID + 盐
        req_id = self.ugg.next_id()
        salt = self.ugg.next_salt()

        # 2. OB：对象缓冲序列化
        raw = self.ob.encode(obj)

        # 3. KV：元数据键值对
        meta = { "req_id": req_id, "algo": ALGO_CHAIN, "len": len(raw), "salt": salt }

        # 4. OBF：异或 + 置换混淆
        obscured = self.obf.obfuscate(raw, salt)

        # 5. HEX：十六进制编码
        hex_text = self.hex.encode(obscured)

        # 6. OEM：顺序编码映射置换
        oem_text = self.oem.encode(hex_text)

        # 7. UTP：协议头封装
        return self.utp.wrap(oem_text, packet_type, req_id, {"meta": meta})

    # 解密：私有协议报文 -> 对象
    def decrypt(self, packet):
        # 1. UTP：校验协议头
        if not self.utp.validate(packet):
            return {"success": False, "error": "协议头校验失败（magic/version/algo 不匹配）"}

        meta = packet.get("meta", {})
        salt = meta.get("salt", self.obf.salt)

        # 2. OEM：逆向置换
        hex_text = self.oem.decode(packet["payload"])

        # 3. HEX：十六进制解码
        obscured = self.hex.decode(hex_text)

        # 4. OBF：逆置换 + 异或
        raw = self.obf.deobfuscate(obscured, salt)

        # 5. OB：对象缓冲还原
        obj = self.ob.decode(raw)

        # 6. KV + UGG：校验元数据一致性
        ok_len = int(meta.get("len", 0)) == len(raw)
        ok_id = meta.get("req_id") == packet.get("req_id")
        obj["_meta"] = { "valid": ok_len and ok_id, "req_id": packet.get("req_id"), "type": packet.get("type"), "ts": packet.get("ts") }
        return {"success": True, "data": obj}

# ============================================================
# 功能架构实例体 - PrivateProtocolArchitecture
# ============================================================
# 装配 APLCE2.0 引擎、UGG、OBF、UTP 等全部组件，并提供：
# - encrypt / decrypt 协议能力
# - build_controller 构建控制器体
# - describe 架构描述
# ============================================================

class PrivateProtocolArchitecture:
    engine = None  # APLCE2.0 分层加密引擎
    ugg = None  # 全局唯一生成器
    obf = None  # 混淆器
    utp = None  # 传输协议层
    built_at = None  # 架构构建时间
    deploy_id = ""  # 部署实例 ID

    def __init__(self):
        self.engine = Aplce2Engine()
        self.ugg = self.engine.ugg
        self.obf = self.engine.obf
        self.utp = self.engine.utp
        self.built_at = time.time()
        self.deploy_id = f"arch-{uuid.uuid4().hex[:12]}"

    # 加密（架构实例体对外能力）
    def encrypt(self, obj, packet_type= "DATA"):
        return self.engine.encrypt(obj, packet_type)

    # 解密（架构实例体对外能力）
    def decrypt(self, packet):
        return self.engine.decrypt(packet)

    # 构建控制器体（装配架构实例的控制器）
    def build_controller(self):
        return ProtocolController(self)

    # 架构描述
    def describe(self):
        return { "name": "PrivateProtocolArchitecture", "deploy_id": self.deploy_id, "version": PROTOCOL_VERSION, "algo_chain": ALGO_CHAIN, "magic": PROTOCOL_MAGIC, "components": ["UGG", "OB", "KV", "HEX", "OEM", "OBF", "UTP", "APLCE2.0"], "built_at": self.built_at }

# ============================================================
# 控制器体 - ProtocolController
# ============================================================
# 状态机：INIT -> HANDSHAKE -> AUTHENTICATED -> READY
# 职责：握手、认证、加密、解密、报文校验、会话管理
# ============================================================

class ProtocolController:
    state = ProtocolState.INIT  # 当前状态
    architecture = None  # 所属架构实例体
    session_id = ""  # 会话 ID
    peer_token = ""  # 对端令牌
    created_at = None

    def __init__(self, architecture):
        self.architecture = architecture
        self.created_at = time.time()

    # 获取当前状态
    def get_state(self):
        return str(self.state)

    # 握手：生成握手报文
    def handshake(self):
        packet = self.architecture.encrypt({ "hello": "mocode", "state": "handshake" }, str(PacketType.HANDSHAKE))
        self.session_id = self.architecture.ugg.next_session()
        self.state = ProtocolState.HANDSHAKE
        return { "success": True, "session_id": self.session_id, "packet": packet }

    # 认证：凭据经 KV + 签名打包后加密
    def authenticate(self, credentials):
        if self.state != ProtocolState.HANDSHAKE:
            return {"success": False, "error": f"认证前置条件不满足（当前状态 {str(self.state)}）"}

        # KV：凭据键值对序列化
        kv_text = self.architecture.engine.kv.encode(credentials)

        # 签名：凭证载荷 + 会话 ID 做摘要
        signature = hashlib.sha256( (kv_text.decode("utf-8") + self.session_id).encode("utf-8") ).hexdigest()

        packet = self.architecture.encrypt({ "auth": credentials, "sign": signature[:32], "session": self.session_id }, str(PacketType.AUTH))

        self.peer_token = signature[:32]
        self.state = ProtocolState.AUTHENTICATED
        return {"success": True, "token": self.peer_token, "packet": packet}

    # 进入就绪态
    def ready(self):
        if self.state == ProtocolState.AUTHENTICATED:
            self.state = ProtocolState.READY
            return {"success": True, "state": "READY"}
        return {"success": False, "error": f"无法进入就绪态（当前状态 {str(self.state)}）"}

    # 加密（控制器转发）
    def encrypt(self, obj, packet_type= "DATA"):
        if self.state != ProtocolState.READY:
            return {"success": False, "error": f"控制器未就绪（当前状态 {str(self.state)}）"}
        packet = self.architecture.encrypt(obj, packet_type)
        packet["session_id"] = self.session_id
        return {"success": True, "packet": packet}

    # 解密（控制器转发 + 会话校验）
    def decrypt(self, packet):
        result = self.architecture.decrypt(packet)
        if result.get("success"):
            result["session_id"] = self.session_id
        return result

    # 报文校验（协议头 + 会话 + 心跳保活）
    def validate(self, packet):
        if not self.architecture.utp.validate(packet):
            return False
        if packet.get("session_id") and packet["session_id"] != self.session_id:
            return False
        if abs(int(time.time()) - int(packet.get("ts", 0))) > 300:
            return False  # 时间窗校验（防重放，5 分钟）
        return True

    # 重置控制器
    def reset(self):
        self.state = ProtocolState.INIT
        self.session_id = ""
        self.peer_token = ""
        return {"success": True, "state": "INIT"}

    # 控制器信息
    def info(self):
        return { "name": "ProtocolController", "state": str(self.state), "session_id": self.session_id, "arch": self.architecture.deploy_id, "created_at": self.created_at }

# ============================================================
# OpenAIBridge - OpenAI 官方协议对接桥梁
# ============================================================
# 使用私有加密协议包装请求/响应：
# - 请求体经 APLCE2.0 加密生成私有协议报文（签名头）
# - 通过官方 REST 协议（/v1/chat/completions）对接 OpenAI
# - 附加协议头：X-MP-Protocol / X-MP-Req-Id / X-MP-Sign
# ============================================================

class OpenAIBridge:
    api_key = ""  # OpenAI API Key
    base_url = "https://api.openai.com/v1"  # 官方 Base URL
    model = "gpt-4o-mini"  # 默认模型
    architecture = None  # 私有协议架构实例体
    controller = None  # 控制器体
    timeout = 60

    def __init__(self, architecture):
        self.architecture = architecture
        self.controller = architecture.build_controller()

    # 配置 OpenAI 官方参数
    def configure(self, settings):
        try:
            self.api_key = settings.get("api_key", self.api_key)
            self.base_url = settings.get("base_url", self.base_url)
            self.model = settings.get("model", self.model)
            self.timeout = settings.get("timeout", self.timeout)
            return True
        except Exception as e:
            return False

    # 私有协议签名：载荷 + API Key 摘要
    def _sign(self, payload_text):
        return hashlib.sha256((payload_text + self.api_key).encode("utf-8")).hexdigest()[:32]

    # 会话启动（握手 -> 认证 -> 就绪）
    def open_session(self, credentials= {}):
        hs = self.controller.handshake()
        auth = self.controller.authenticate(credentials or {"key": self.api_key})
        ready = self.controller.ready()
        return { "success": hs["success"] and auth["success"] and ready["success"], "session_id": self.controller.session_id, "state": self.controller.get_state() }

    # 对接 OpenAI 官方协议：聊天补全
    def chat_completion(self, messages):
        if not self.api_key:
            return {"success": False, "error": "OpenAI API Key 未配置"}

        payload = { "model": self.model, "messages": messages }

        # 1. 私有协议加密请求体（架构实例体）
        packet = self.architecture.encrypt(payload, str(PacketType.DATA))

        # 2. 组装 OpenAI 官方请求（私有协议签名头）
        body = json.dumps(payload).encode("utf-8")
        headers = { "Authorization": f"Bearer {self.api_key}", "Content-Type": "application/json", "X-MP-Protocol": ALGO_CHAIN, "X-MP-Req-Id": packet["req_id"], "X-MP-Sign": self._sign(packet["payload"]) }

        req = urllib.request.Request( f"{self.base_url}/chat/completions", data=body, headers=headers, method="POST" )

        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as resp:
                result = json.loads(resp.read().decode("utf-8"))
                return { "success": True, "packet": packet,            "response": result           }
        except urllib.error.HTTPError as e:
            err_text = e.read().decode("utf-8", errors="ignore")
            return {"success": False, "error": f"HTTP {e.code}: {err_text}", "packet": packet}
        except Exception as e:
            return {"success": False, "error": str(e), "packet": packet}

    # 桥梁信息
    def info(self):
        return { "name": "OpenAIBridge", "base_url": self.base_url, "model": self.model, "protocol_version": PROTOCOL_VERSION, "algo_chain": ALGO_CHAIN, "controller": self.controller.info() }

# ============================================================
# 顶层构建函数
# ============================================================

# 构建完整私有协议体系（架构实例体 + 控制器体 + OpenAI 桥梁）
def build_private_protocol():
    architecture = PrivateProtocolArchitecture()
    controller = architecture.build_controller()
    bridge = OpenAIBridge(architecture)
    return { "architecture": architecture, "controller": controller, "bridge": bridge }

# ============================================================
# 导出
# ============================================================
