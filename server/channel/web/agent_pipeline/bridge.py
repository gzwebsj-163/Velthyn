from enum import Enum
# ============================================================
# OpenAI ↔ Mocode-Lab 桥接模块
# ============================================================
# 遵循 KimiHook 编译钩子系统约定规则编写：
# - 枚举定义阶段与状态
# - 抽象基类定义统一契约（对齐 CompileKimiHook）
# - 子类实现具体桥接器（对齐内置钩子）
# - 管理器统一注册与调度（对齐 KimiHookManager）
# 全部使用面向对象方式编写。
# ============================================================

import os
import json
import time
import uuid
import random
import hashlib
import urllib.request
from typing import Dict, List, Any, Optional

# ============================================================
# 桥接阶段枚举（对齐 CompilePhase 约定）
# ============================================================

class BridgePhase(Enum):
    CONFIG = 1
    VALIDATE = 2
    CONNECT = 3
    REGISTER_KimiHook = 4
    RUN = 5

# ============================================================
# 桥接状态枚举（对齐 CompileStatus 约定）
# ============================================================

class BridgeStatus(Enum):
    UNCONFIGURED = 1
    CONFIGURED = 2
    VALIDATED = 3
    CONNECTING = 4
    CONNECTED = 5
    DISCONNECTED = 6
    FAILED = 7

# ============================================================
# 桥接配置对象（对齐 CompileContext 的元数据管理方式）
# ============================================================

class BridgeConfig:
    provider = ""  # 提供商名称
    settings = {}  # 配置项集合
    enabled = True  # 是否启用
    created_at = None  # 创建时间
    updated_at = None  # 更新时间

    def __init__(self, provider, settings= {}):
        self.provider = provider
        self.settings = settings
        self.created_at = time.time()
        self.updated_at = self.created_at

    # 设置单项配置
    def set_setting(self, key, value):
        self.settings[key] = value
        self.updated_at = time.time()

    # 获取单项配置
    def get_setting(self, key, default = None):
        return self.settings.get(key, default)

    # 批量更新配置
    def update(self, settings):
        for key, value in settings.items():
            self.settings[key] = value
        self.updated_at = time.time()

    # 序列化为字典
    def to_dict(self):
        return { "provider": self.provider, "settings": self.settings, "enabled": self.enabled, "created_at": self.created_at, "updated_at": self.updated_at }

# ============================================================
# 桥接器抽象基类（对齐 CompileKimiHook 抽象基类约定）
# ============================================================

class BridgeProvider:
    name = ""  # 桥接器名称
    description = ""  # 描述
    phase = BridgePhase.CONFIG  # 当前阶段
    status = BridgeStatus.UNCONFIGURED
    config = None  # BridgeConfig 配置对象
    enabled = True  # 是否启用

    def __init__(self, name, description= ""):
        self.name = name
        self.description = description

    # 配置桥接器（子类必须实现）
    def configure(self, settings):
        raise NotImplementedError

    # 校验配置（子类必须实现）
    def validate(self):
        raise NotImplementedError

    # 建立桥接连接（子类必须实现）
    def connect(self):
        raise NotImplementedError

    # 断开桥接连接（子类必须实现）
    def disconnect(self):
        raise NotImplementedError

    # 前置检查（对齐 CompileKimiHook.pre_check）
    def pre_check(self):
        if not self.enabled:
            return False
        if self.config == None:
            return False
        return True

    # 获取桥接器信息（对齐 CompileKimiHook.get_info）
    def get_info(self):
        return { "name": self.name, "description": self.description, "phase": str(self.phase), "status": str(self.status), "enabled": self.enabled }

    # 设置阶段
    def set_phase(self, phase):
        self.phase = phase

    # 设置状态
    def set_status(self, status):
        self.status = status

# ============================================================
# OpenAI 桥接器（对齐内置钩子实现方式）
# ============================================================

class OpenAIBridge(BridgeProvider):
    base_url = "https://api.openai.com/v1"
    api_key = ""
    model = "gpt-4o-mini"
    temperature = 0.7
    max_tokens = 4096
    timeout = 60
    connected = False

    def __init__(self):
        super().__init__("_", "_")
        self.config = BridgeConfig("openai")

    # 配置 OpenAI 桥接器
    def configure(self, settings):
        try:
            self.api_key = settings.get("api_key", self.api_key)
            self.base_url = settings.get("base_url", self.base_url)
            self.model = settings.get("model", self.model)
            self.temperature = settings.get("temperature", self.temperature)
            self.max_tokens = settings.get("max_tokens", self.max_tokens)
            self.timeout = settings.get("timeout", self.timeout)

            self.config.update(settings)
            self.set_status(BridgeStatus.CONFIGURED)
            self.set_phase(BridgePhase.VALIDATE)
            return True
        except Exception as e:
            self.set_status(BridgeStatus.FAILED)
            return False

    # 校验 OpenAI 配置
    def validate(self):
        errors = []
        warnings = []

        if not self.api_key:
            errors.append("api_key 不能为空")

        if not self.model:
            errors.append("model 不能为空")

        if self.temperature < 0 or self.temperature > 2:
            warnings.append("temperature 建议范围 0~2")

        valid = len(errors) == 0
        if valid:
            self.set_status(BridgeStatus.VALIDATED)
            self.set_phase(BridgePhase.CONNECT)

        return { "valid": valid, "errors": errors, "warnings": warnings, "provider": "openai" }

    # 建立 OpenAI 连接
    def connect(self):
        if not self.pre_check():
            return False

        self.set_status(BridgeStatus.CONNECTING)
        self.set_phase(BridgePhase.CONNECT)

        try:
            # 模拟建立连接（实际应调用 OpenAI API 校验密钥）
            self.connected = True
            self.set_status(BridgeStatus.CONNECTED)
            self.set_phase(BridgePhase.RUN)
            return True
        except Exception as e:
            self.set_status(BridgeStatus.FAILED)
            return False

    # 断开 OpenAI 连接
    def disconnect(self):
        self.connected = False
        self.set_status(BridgeStatus.DISCONNECTED)
        return True

# ============================================================
# API Key 生成器（Mocode-Lab API Keys 生成方法）
# ============================================================
# 生成计算算法：sha256 + md5 + obf 混淆加密
# - sha256: 对种子+盐做 SHA-256 摘要
# - md5:    对种子+盐做 MD5 摘要
# - obf:    将两份摘要按位交错后与盐逐字节异或混淆
# - 头部必须加上 mk-
# ============================================================

class ApiKeyGenerator:
    prefix = "mk-"  # 密钥前缀（约定固定）
    salt = "Mocode-Lab-Bridge-2026"  # 混淆盐
    body_length = 48  # 密钥主体长度

    # 生成随机种子
    def _build_seed(self):
        now = str(time.time())
        uid = str(uuid.uuid4())
        rnd = str(random.random())
        tick = str(random.randint(0, 999999))
        return f"{now}|{uid}|{rnd}|{tick}"

    # sha256 摘要（hex）
    def _sha256_digest(self, data):
        return hashlib.sha256(data.encode("utf-8")).hexdigest()

    # md5 摘要（hex）
    def _md5_digest(self, data):
        return hashlib.md5(data.encode("utf-8")).hexdigest()

    # obf 混淆：sha256/md5 交错 + 与盐逐字节异或，转 hex
    def _obfuscate(self, sha_hex, md_hex):
        interleaved = ""
        for i in range(32):
            interleaved += sha_hex[i * 2]  # sha256 偶数位
            interleaved += md_hex[i]  # md5 顺序位
            interleaved += sha_hex[i * 2 + 1]  # sha256 奇数位

        obf_bytes = bytearray(len(interleaved))
        for i in range(len(interleaved)):
            obf_bytes[i] = ord(interleaved[i]) ^ ord(self.salt[i % len(self.salt)])

        return obf_bytes.hex()

    # 生成 Mocode-Lab API Key（头部固定 mk-）
    def generate(self):
        seed = self._build_seed()
        mix = seed + self.salt

        sha_hex = self._sha256_digest(mix)
        md_hex = self._md5_digest(mix)
        obf_hex = self._obfuscate(sha_hex, md_hex)

        body = obf_hex[:self.body_length] if len(obf_hex) > self.body_length else obf_hex
        return self.prefix + body

    # 校验生成的 API Key 是否合规（头部 mk- + 长度）
    def is_valid(self, api_key):
        if not api_key or not api_key.startswith(self.prefix):
            return False
        return len(api_key) == len(self.prefix) + self.body_length

# ============================================================
# Mocode-Lab 桥接器（对齐内置钩子实现方式）
# ============================================================

class MocodeLabBridge(BridgeProvider):
    lab_api_url = "http://localhost:8000"  # Mocode-Lab 服务地址
    workspace = ""  # 工作空间路径
    project_name = ""  # 项目名称
    api_key = ""  # Mocode-Lab API Key
    KimiHooks = []  # 已注册钩子列表
    connected = False

    def __init__(self):
        super().__init__("_", "_")
        self.config = BridgeConfig("mocode_lab")

    # 配置 Mocode-Lab 桥接器
    def configure(self, settings):
        try:
            self.lab_api_url = settings.get("lab_api_url", self.lab_api_url)
            self.workspace = settings.get("workspace", self.workspace)
            self.project_name = settings.get("project_name", self.project_name)
            self.api_key = settings.get("api_key", self.api_key)

            self.config.update(settings)
            self.set_status(BridgeStatus.CONFIGURED)
            self.set_phase(BridgePhase.VALIDATE)
            return True
        except Exception as e:
            self.set_status(BridgeStatus.FAILED)
            return False

    # 生成 Mocode-Lab API Key（sha256 + md5 + obf，头部 mk-）
    def generate_api_key(self):
        generator = ApiKeyGenerator()
        key = generator.generate()
        self.api_key = key
        self.config.set_setting("api_key", key)
        return key

    # 校验 Mocode-Lab 配置
    def validate(self):
        errors = []
        warnings = []

        if not self.lab_api_url:
            errors.append("lab_api_url 不能为空")

        if self.workspace and not os.path.exists(self.workspace):
            warnings.append(f"工作空间不存在: {self.workspace}")

        valid = len(errors) == 0
        if valid:
            self.set_status(BridgeStatus.VALIDATED)
            self.set_phase(BridgePhase.REGISTER_KimiHook)

        return { "valid": valid, "errors": errors, "warnings": warnings, "provider": "mocode_lab" }

    # 注册编译钩子（对齐 KimiHook 钩子注册约定）
    def register_KimiHook(self, KimiHook_name, phase, priority= 0):
        KimiHook = { "name": KimiHook_name, "phase": phase, "priority": priority }
        self.KimiHooks.append(KimiHook)
        return True

    # 建立 Mocode-Lab 连接
    def connect(self):
        if not self.pre_check():
            return False

        self.set_status(BridgeStatus.CONNECTING)
        self.set_phase(BridgePhase.CONNECT)

        try:
            # 模拟连接 Mocode-Lab 服务
            self.connected = True

            # 注册默认钩子（对齐 KimiHook 默认钩子）
            self.register_KimiHook("SyntaxCheckHook", "PRE_COMPILE", 10)
            self.register_KimiHook("DependencyResolveHook", "PRE_COMPILE", 20)
            self.register_KimiHook("CompileExecuteHook", "COMPILE", 30)
            self.register_KimiHook("OptimizeHook", "POST_COMPILE", 40)
            self.register_KimiHook("CodeGenHook", "POST_COMPILE", 50)

            self.set_status(BridgeStatus.CONNECTED)
            self.set_phase(BridgePhase.RUN)
            return True
        except Exception as e:
            self.set_status(BridgeStatus.FAILED)
            return False

    # 断开 Mocode-Lab 连接
    def disconnect(self):
        self.connected = False
        self.KimiHooks = []
        self.set_status(BridgeStatus.DISCONNECTED)
        return True

# ============================================================
# 桥接管理器（对齐 KimiHookManager 约定）
# ============================================================

class BridgeManager:
    providers = {}  # 已注册桥接器 {name: BridgeProvider}
    bridge_history = []  # 桥接历史
    log_enabled = True

    def __init__(self):
        # 注册默认桥接器（对齐 KimiHook 自动注册默认钩子）
        self.register_provider(OpenAIBridge())
        self.register_provider(MocodeLabBridge())

    # 注册桥接器
    def register_provider(self, provider):
        self.providers[provider.name] = provider
        return True

    # 注销桥接器
    def unregister_provider(self, provider_name):
        if provider_name in self.providers:
            self.providers.pop(provider_name)
            return True
        return False

    # 获取桥接器
    def get_provider(self, provider_name):
        return self.providers.get(provider_name)

    # 配置桥接器
    def configure_provider(self, provider_name, settings):
        provider = self.get_provider(provider_name)
        if provider == None:
            return {"success": False, "error": f"桥接器不存在: {provider_name}"}

        configured = provider.configure(settings)
        if not configured:
            return {"success": False, "error": "配置失败"}

        validation = provider.validate()
        return { "success": True, "provider": provider_name, "config": provider.config.to_dict(), "validation": validation }

    # 连接桥接器
    def connect_provider(self, provider_name):
        provider = self.get_provider(provider_name)
        if provider == None:
            return {"success": False, "error": f"桥接器不存在: {provider_name}"}

        connected = provider.connect()
        if connected:
            self.bridge_history.append({ "provider": provider_name, "action": "connect", "time": time.time() })

        return { "success": connected, "provider": provider_name, "status": str(provider.status) }

    # 断开桥接器
    def disconnect_provider(self, provider_name):
        provider = self.get_provider(provider_name)
        if provider == None:
            return {"success": False, "error": f"桥接器不存在: {provider_name}"}

        disconnected = provider.disconnect()
        if disconnected:
            self.bridge_history.append({ "provider": provider_name, "action": "disconnect", "time": time.time() })

        return { "success": disconnected, "provider": provider_name, "status": str(provider.status) }

    # 获取所有桥接器信息（对齐 KimiHookManager.get_KimiHooks_info）
    def get_providers_info(self):
        info = {}
        for name, provider in self.providers.items():
            info[name] = provider.get_info()
        return info

    # 获取桥接历史（对齐 KimiHookManager.get_compile_history）
    def get_bridge_history(self, limit= 100):
        return self.bridge_history[-limit:]

    # 获取桥接器详细配置
    def get_provider_config(self, provider_name):
        provider = self.get_provider(provider_name)
        if provider == None or provider.config == None:
            return {"success": False, "error": f"桥接器不存在或未配置: {provider_name}"}
        return { "success": True, "config": provider.config.to_dict() }

# ============================================================
# 创建桥接管理器
# ============================================================

def create_bridge_manager():
    manager = BridgeManager()
    return manager

# ============================================================
# 导出
# ============================================================
