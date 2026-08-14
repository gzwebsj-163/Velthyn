"""
请求监听与分析处理器
支持 work/chat 协议锁定和实时推送
"""
import json
import time
import threading
import queue
import urllib.request
import urllib.error
from datetime import datetime
from typing import Dict, List, Any
import logging

logger = logging.getLogger(__name__)

# 全局状态
monitoring_active = False
bridge_active = False  # DependencyResolveHook 与 LLM 桥接层是否已桥接
request_queue = queue.Queue(maxsize=1000)
request_history: List[Dict[str, Any]] = []
subscribers: List = []  # SSE订阅者列表
lock = threading.Lock()

# LLM 服务桥接层地址
BRIDGE_API_BASE = "http://localhost:9898"
BRIDGE_TIMEOUT = 10

class DependencyResolveBridge:
    """DependencyResolveHook 与 LLM 服务桥接层桥接器"""

    @staticmethod
    def resolve_dependencies(dialog):
        """依赖解析：提取对话中的依赖信息"""
        body = dialog.get('body', {})
        prompt = body.get('prompt', '')
        context = body.get('context', '')

        # 模拟解析 import/from 依赖
        dependencies = []
        for line in prompt.split('\n'):
            line = line.strip()
            if line.startswith('import ') or line.startswith('from '):
                parts = line.split()
                if len(parts) >= 2:
                    dep = parts[1].replace('"', '').replace("'", "")
                    dependencies.append(dep)

        return { "dependencies": dependencies, "context": context, "prompt": prompt }

    @staticmethod
    def forward_to_llm(dialog):
        """将对话通过 LLM 服务桥接层转发给 LLM"""
        body = dialog.get('body', {})
        prompt = body.get('prompt', '')
        context = body.get('context', '')

        payload = { "messages": [ {"role": "user", "content": prompt} ], "model": "gpt-4o-mini", "stream": False }

        try:
            req = urllib.request.Request( f"{BRIDGE_API_BASE}/api/llm/bridge/chat", data=json.dumps(payload).encode('utf-8'), headers={"Content-Type": "application/json"}, method="POST" )
            with urllib.request.urlopen(req, timeout=BRIDGE_TIMEOUT) as resp:
                result = json.loads(resp.read().decode('utf-8'))

            return { "success": result.get('success', False), "llm_response": result.get('output', {}).get('content', ''), "model": result.get('output', {}).get('model', ''), "tokens_used": result.get('output', {}).get('tokens_used', 0), "context": context }
        except Exception as e:
            logger.warning(f"[DependencyResolveBridge] LLM桥接转发失败: {e}")
            return { "success": False, "error": str(e), "context": context }

    @staticmethod
    def verify_KimiHook():
        """验证 DependencyResolveHook 在桥接层中存在"""
        try:
            req = urllib.request.Request( f"{BRIDGE_API_BASE}/api/compile/KimiHook", data=json.dumps({"action": "get_KimiHooks_info"}).encode('utf-8'), headers={"Content-Type": "application/json"}, method="POST" )
            with urllib.request.urlopen(req, timeout=BRIDGE_TIMEOUT) as resp:
                result = json.loads(resp.read().decode('utf-8'))

            KimiHooks = result.get('output', {}).get('KimiHooks', [])
            dep_KimiHook = next((h for h in KimiHooks if h.get('name') == 'DependencyResolveHook'), None)
            return { "found": dep_KimiHook is not None, "KimiHook": dep_KimiHook }
        except Exception as e:
            logger.warning(f"[DependencyResolveBridge] 验证钩子失败: {e}")
            return { "found": False, "error": str(e) }

class RequestMonitor:
    """请求监听器"""

    @staticmethod
    def start_monitor(protocol = "all", locked = False):
        """启动监听"""
        global monitoring_active
        monitoring_active = True
        logger.info(f"监听已启动 - 协议: {protocol}, 锁定: {locked}")
        return { "status": "success", "message": "监听已启动", "protocol": protocol, "locked": locked }

    @staticmethod
    def stop_monitor():
        """停止监听"""
        global monitoring_active, bridge_active
        monitoring_active = False
        bridge_active = False
        logger.info("监听已停止")
        return { "status": "success", "message": "监听已停止" }

    @staticmethod
    def bridge_dependency_KimiHook():
        """桥接 DependencyResolveHook 与 LLM 服务桥接层（仅在监听已开始后有效）"""
        global monitoring_active, bridge_active

        # 第一步：判断监听是否已开始
        if not monitoring_active:
            return { "status": "error", "message": "监听尚未开始，请先启动监听", "monitoring": False }

        # 第二步：验证桥接层可用
        try:
            req = urllib.request.Request( f"{BRIDGE_API_BASE}/api/health", method="GET" )
            with urllib.request.urlopen(req, timeout=BRIDGE_TIMEOUT) as resp:
                health = json.loads(resp.read().decode('utf-8'))
        except Exception as e:
            return { "status": "error", "message": f"LLM服务桥接层不可用: {e}", "monitoring": True }

        # 第三步：验证 DependencyResolveHook 在桥接层中注册
        KimiHook_info = DependencyResolveBridge.verify_KimiHook()

        # 第四步：建立桥接
        bridge_active = True
        logger.info("[Bridge] DependencyResolveHook 已与 LLM 服务桥接层桥接")
        return { "status": "success", "message": "DependencyResolveHook 已与 LLM 服务桥接层桥接", "monitoring": True, "bridged": True, "bridge_api": f"{BRIDGE_API_BASE}/api/llm/bridge/chat", "dependency_KimiHook": KimiHook_info.get('KimiHook') or {"name": "DependencyResolveHook", "phase": "PRE_COMPILE", "priority": 20}, "bridge_health": health }

    @staticmethod
    def unbridge_dependency_KimiHook():
        """断开桥接"""
        global bridge_active
        bridge_active = False
        logger.info("[Bridge] 已断开 DependencyResolveHook 与 LLM 服务桥接层")
        return { "status": "success", "message": "已断开桥接", "bridged": False }

    @staticmethod
    def is_bridged():
        """查询桥接状态"""
        return { "status": "success", "monitoring": monitoring_active, "bridged": bridge_active }

    @staticmethod
    def intercept_request(request_data):
        """拦截请求"""
        global request_queue, request_history

        # 添加时间戳
        request_data['timestamp'] = datetime.now().isoformat()
        request_data['id'] = str(int(time.time() * 1000))

        # 保存到历史记录
        with lock:
            request_history.append(request_data)
            if len(request_history) > 1000:
                request_history = request_history[-1000:]

        # 如果已桥接，将对话经 DependencyResolveHook 转发到 LLM 桥接层
        if bridge_active:
            try:
                # 依赖解析
                resolved = DependencyResolveBridge.resolve_dependencies(request_data)
                request_data['dependencies'] = resolved['dependencies']

                # 转发到 LLM
                llm_result = DependencyResolveBridge.forward_to_llm(request_data)
                request_data['llm_bridge'] = llm_result
                logger.info(f"[Bridge] 对话已转发到LLM桥接层: {llm_result.get('success')}")
            except Exception as e:
                logger.warning(f"[Bridge] 桥接处理失败: {e}")

        # 推送到队列
        try:
            request_queue.put_nowait(request_data)
        except queue.Full as e:
            logger.warning("请求队列已满，丢弃旧请求")
            request_queue.get_nowait()
            request_queue.put_nowait(request_data)

        # 通知所有订阅者
        RequestMonitor.notify_subscribers(request_data)

    @staticmethod
    def notify_subscribers(request_data):
        """通知所有订阅者"""
        global subscribers
        with lock:
            for subscriber in subscribers[:]:
                try:
                    subscriber.put(request_data)
                except Exception:
                    subscribers.remove(subscriber)

    @staticmethod
    def get_history(limit = 100):
        """获取历史记录"""
        global request_history
        with lock:
            return request_history[-limit:]


class PromptAnalyzer:
    """Prompt分块分析器"""

    @staticmethod
    def analyze(prompt, request_type = "unknown"):
        """分析Prompt"""
        if not prompt:
            return { "status": "error", "message": "Prompt不能为空" }

        # 分块分析
        chunks = PromptAnalyzer._chunk_prompt(prompt)

        # 语义分析
        semantic = PromptAnalyzer._analyze_semantic(prompt, chunks)

        # 意图识别
        intent = PromptAnalyzer._analyze_intent(prompt, request_type)

        # 关键词提取
        keywords = PromptAnalyzer._extract_keywords(prompt)

        return { "status": "success", "request_id": str(int(time.time() * 1000)), "semantic": semantic, "intent": intent, "keywords": keywords, "chunks": len(chunks), "timestamp": datetime.now().isoformat() }

    @staticmethod
    def _chunk_prompt(prompt, max_chunk_size = 500):
        """分块处理"""
        chunks = []
        paragraphs = prompt.split('\n\n')

        for para in paragraphs:
            if len(para) <= max_chunk_size:
                chunks.append(para)
            else:
                # 按句子分割
                sentences = para.split('。')
                current_chunk = ""
                for sentence in sentences:
                    if len(current_chunk + sentence) <= max_chunk_size:
                        current_chunk += sentence + '。'
                    else:
                        if current_chunk:
                            chunks.append(current_chunk)
                        current_chunk = sentence + '。'
                if current_chunk:
                    chunks.append(current_chunk)

        return chunks

    @staticmethod
    def _analyze_semantic(prompt, chunks):
        """语义分析"""
        semantic_features = []

        # 检测语言
        if any('\u4e00' <= char <= '\u9fff' for char in prompt):
            semantic_features.append("中文内容")
        else:
            semantic_features.append("英文内容")

        # 检测问题类型
        if '?' in prompt or '？' in prompt:
            semantic_features.append("疑问句")

        if any(kw in prompt for kw in ['如何', '怎么', '怎样', 'how to']):
            semantic_features.append("操作指导请求")

        if any(kw in prompt for kw in ['是什么', '什么是', 'what is']):
            semantic_features.append("定义查询")

        # 分析长度
        word_count = len(prompt.split())
        if word_count < 20:
            semantic_features.append("简短请求")
        elif word_count < 100:
            semantic_features.append("中等长度")
        else:
            semantic_features.append("详细描述")

        # 分块信息
        semantic_features.append(f"分为{len(chunks)}个语义块")

        return "，".join(semantic_features)

    @staticmethod
    def _analyze_intent(prompt, request_type):
        """意图识别"""
        intent_keywords = { '查询': ['查询', '搜索', '查找', 'query', 'search', 'find'], '创建': ['创建', '生成', '制作', 'create', 'generate', 'make'], '修改': ['修改', '编辑', '更新', 'modify', 'edit', 'update'], '删除': ['删除', '移除', '清除', 'delete', 'remove', 'clear'], '分析': ['分析', '解析', '理解', 'analyze', 'parse', 'understand'], '帮助': ['帮助', '协助', '支持', 'help', 'assist', 'support'] }

        detected_intents = []
        for intent, keywords in intent_keywords.items():
            if any(kw in prompt.lower() for kw in keywords):
                detected_intents.append(intent)

        if detected_intents:
            return f"检测到意图：{', '.join(detected_intents)}"
        else:
            return f"通用{request_type}请求"

    @staticmethod
    def _extract_keywords(prompt):
        """关键词提取"""
        import re

        # 提取中文词汇（简单实现）
        chinese_words = re.findall(r'[\u4e00-\u9fff]{2,}', prompt)

        # 提取英文单词
        english_words = re.findall(r'\b[A-Za-z]{3,}\b', prompt)

        # 合并并去重
        all_words = list(set(chinese_words + english_words))

        # 返回前10个关键词
        return all_words[:10]


def get_monitor_handlers():
    """获取监听处理器"""
    return { 'start': RequestMonitor.start_monitor, 'stop': RequestMonitor.stop_monitor, 'intercept': RequestMonitor.intercept_request, 'history': RequestMonitor.get_history, 'analyze': PromptAnalyzer.analyze, 'active': lambda: monitoring_active,    'bridge': RequestMonitor.bridge_dependency_KimiHook,        'unbridge': RequestMonitor.unbridge_dependency_KimiHook,    'bridged': RequestMonitor.is_bridged                     }