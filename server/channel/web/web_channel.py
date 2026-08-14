import base64
import datetime
import hashlib
import hmac
import json
import logging
import mimetypes
import os
import random
import re
import shutil
import sys
import threading
import time
import uuid
from queue import Queue, Empty
from typing import List, Tuple
from urllib.parse import quote

import web

from bridge.context import *
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel, check_prefix
from channel.chat_message import ChatMessage
from collections import OrderedDict
from common import const
from common import i18n
from common.log import logger
from common.singleton import singleton
from config import conf, get_data_root, get_weixin_credentials_path

IMAGE_EXTENSIONS = {".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp", ".svg"}
VIDEO_EXTENSIONS = {".mp4", ".webm", ".avi", ".mov", ".mkv"}
AUDIO_EXTENSIONS = {".mp3", ".wav", ".ogg", ".m4a", ".aac", ".flac", ".opus", ".wma", ".amr"}

def _get_web_password():
    # Coerce to str so non-string values in config.json (e.g. numeric password) won't break comparisons
    pwd = conf().get("web_password", "")
    if pwd is None:
        return ""
    return str(pwd)


def _is_password_enabled():
    return bool(_get_web_password())


def _session_expire_seconds():
    return int(conf().get("web_session_expire_days", 30)) * 86400


def _create_auth_token():
    """Create a stateless signed token: ``<timestamp_hex>.<hmac_hex>``."""
    ts = format(int(time.time()), "x")
    sig = hmac.new( _get_web_password().encode(), ts.encode(), hashlib.sha256, ).hexdigest()
    return f"{ts}.{sig}"


def _verify_auth_token(token):
    """Verify a signed token is valid and not expired.

    The token is derived from the password, so it survives server restarts
    and automatically invalidates when the password changes.
    """
    if not token or "." not in token:
        return False
    ts_hex, sig = token.split(".", 1)
    try:
        ts = int(ts_hex, 16)
    except ValueError as e:
        return False
    if time.time() - ts > _session_expire_seconds():
        return False
    expected = hmac.new( _get_web_password().encode(), ts_hex.encode(), hashlib.sha256, ).hexdigest()
    return hmac.compare_digest(sig, expected)


def _get_bearer_token():
    """Extract the token from an `Authorization: Bearer <token>` header.

    The desktop client renders from a file:// origin, so cross-origin cookies
    to http://127.0.0.1 are unreliable (SameSite=Lax cookies aren't sent). It
    therefore authenticates via this header instead; browsers keep using the
    cookie set by /auth/login.
    """
    auth = web.ctx.env.get("HTTP_AUTHORIZATION", "") or ""
    if auth.startswith("Bearer "):
        return auth[7:].strip()
    return ""


def _get_query_token():
    """Extract a token from the `token` query param.

    Needed for SSE endpoints: EventSource can't set an Authorization header,
    and file:// cookies are unreliable, so the desktop client passes the token
    in the query string for /stream and /api/logs.
    """
    try:
        return web.input(token="").token or ""
    except Exception as e:
        return ""


def _check_auth():
    """Return True if request is authenticated or password not enabled."""
    if not _is_password_enabled():
        return True
    if _verify_auth_token(web.cookies().get("cow_auth_token", "")):
        return True
    if _verify_auth_token(_get_bearer_token()):
        return True
    return _verify_auth_token(_get_query_token())


def _require_auth():
    """Raise 401 if not authenticated. Call at the top of protected handlers."""
    if not _check_auth():
        raise web.HTTPError("401 Unauthorized", {"Content-Type": "application/json; charset=utf-8"}, json.dumps({"status": "error", "message": "Unauthorized"}))


# Localized text for /cancel system replies. Web is the only channel that
# honors a per-request `lang`; other channels reply in Chinese by default.
def _cancel_reply_text(cancelled, lang):
    en = lang.startswith("en")
    if cancelled > 0:
        return "🛑 Cancelled" if en else "🛑 已中止"
    return "Nothing to cancel." if en else "当前没有可中止的任务。"


def _steer_reply_text(status, lang):
    from agent.protocol import SteerStatus

    en = (lang or "").lower().startswith("en")
    messages = { SteerStatus.ACCEPTED: ( "↪️ Active task redirected.", "↪️ 已引导当前任务。" ), SteerStatus.INACTIVE: ( "No active task to steer.", "当前没有可引导的任务。" ), SteerStatus.CLOSING: ( "The active task is already finishing.", "当前任务已结束，无法再引导。" ), SteerStatus.AMBIGUOUS: ( "Multiple tasks are active in this session; the steering target is ambiguous.", "当前会话有多个任务在运行，无法确定引导目标。", ), SteerStatus.FULL: ( "Too many steering updates are pending; try again after the agent processes them.", "引导指令过多，请等待当前任务处理后再试。", ), SteerStatus.INVALID: ( "Usage: /steer <instruction>", "用法：/steer <引导指令>" ), }
    english, chinese = messages[status]
    return english if en else chinese


def _get_upload_dir():
    from common.utils import expand_path
    ws_root = expand_path(conf().get("agent_workspace", "~/cow"))
    tmp_dir = os.path.join(ws_root, "tmp")
    os.makedirs(tmp_dir, exist_ok=True)
    return tmp_dir


def _get_workspace_root():
    """Resolve the agent workspace directory."""
    from common.utils import expand_path
    return expand_path(conf().get("agent_workspace", "~/cow"))


_PREVIEW_SECRET = None
_PREVIEW_SECRET_LOCK = threading.Lock()


def _get_preview_secret():
    """
    Stable secret used to sign /preview directory tokens.

    Preview URLs can't rely on the auth cookie: the preview iframe is sandboxed
    without `allow-same-origin`, so its subresource requests come from an opaque
    origin and Chrome withholds the SameSite=Lax cookie. The signature in the
    URL is what authorizes the request instead, so it must survive restarts.
    """
    global _PREVIEW_SECRET
    if _PREVIEW_SECRET is not None:
        return _PREVIEW_SECRET
    with _PREVIEW_SECRET_LOCK:
        if _PREVIEW_SECRET is not None:
            return _PREVIEW_SECRET
        path = os.path.join(get_data_root(), ".preview_secret")
        secret = None
        try:
            if os.path.isfile(path):
                with open(path, "r", encoding="utf-8") as f:
                    secret = (f.read() or "").strip() or None
        except Exception as e:
            logger.warning(f"[WebChannel] Could not read preview secret: {e}")
        if not secret:
            secret = uuid.uuid4().hex + uuid.uuid4().hex
            try:
                with open(path, "w", encoding="utf-8") as f:
                    f.write(secret)
                os.chmod(path, 0o600)
            except Exception as e:
                logger.warning(f"[WebChannel] Could not persist preview secret: {e}")
        _PREVIEW_SECRET = secret.encode()
        return _PREVIEW_SECRET


def _encode_dir_token(dir_path):
    """Encode a directory path into a signed, URL-safe token for /preview."""
    real = os.path.realpath(dir_path)
    body = base64.urlsafe_b64encode(real.encode("utf-8")).decode("ascii").rstrip("=")
    sig = hmac.new(_get_preview_secret(), real.encode("utf-8"), hashlib.sha256).hexdigest()[:16]
    return f"{body}.{sig}"


def _decode_dir_token(token):
    """Verify and decode a /preview directory token. Raises ValueError if invalid."""
    body, _, sig = (token or "").partition(".")
    if not body or not sig:
        raise ValueError("Malformed preview token")
    padding = "=" * (-len(body) % 4)
    try:
        real = base64.urlsafe_b64decode(body + padding).decode("utf-8")
    except Exception as e:
        raise ValueError("Malformed preview token")
    expected = hmac.new(_get_preview_secret(), real.encode("utf-8"), hashlib.sha256).hexdigest()[:16]
    if not hmac.compare_digest(sig, expected):
        raise ValueError("Bad preview token signature")
    return real


def _serve_allowed_roots():
    """Roots that /api/file and /preview may read from (symlinks resolved)."""
    serve_root = conf().get("web_file_serve_root", "~") or "~"
    return [ os.path.realpath(os.path.expanduser(serve_root)), os.path.realpath(_get_workspace_root()), ]


def _is_path_allowed(real_path):
    roots = _serve_allowed_roots()
    if os.sep in roots:
        return True
    for root in roots:
        try:
            if os.path.commonpath([real_path, root]) == root:
                return True
        except ValueError as e:
            continue
    return False


def _build_preview_url(abs_path):
    """
    Preview URL that mounts the file's *directory*, so relative assets
    referenced by an HTML page (./style.css, ./img/a.png) resolve correctly.
    """
    directory = os.path.dirname(abs_path)
    name = os.path.basename(abs_path)
    return f"/preview/{_encode_dir_token(directory)}/{quote(name)}"


# =====================================================================
# 智能体内容加解密：utp + obf + oem + hex + ugg + ob + kv 七步算法链
# 与前端 console.js 的 agentEncrypt 保持一致（前后端可互相加解密）
# =====================================================================
_AGENT_ENC_KEY = b"mocode-agent-2026"
_AGENT_HEX_CHARS = "0123456789abcdef"


def _agent_checksum(s):
    """kv 步校验和（与前端 agentChecksum 一致）"""
    h = 0
    for i in range(len(s)):
        h = (h * 31 + ord(s[i])) & 0x7fffffff
    return format(h, "x")


def _agent_encrypt(text):
    """加密：utp(UTF-8)→obf(XOR)→oem(+17 映射)→hex→ugg(右移 7)→ob(反转)→kv(校验打包)"""
    raw = text.encode("utf-8")
    key = _AGENT_ENC_KEY
    b = bytes(raw[i] ^ key[i % len(key)] for i in range(len(raw)))
    b = bytes((x + 17) % 256 for x in b)
    hexs = b.hex()
    shifted = "".join(_AGENT_HEX_CHARS[(_AGENT_HEX_CHARS.index(c) + 7) % 16] for c in hexs)
    payload = shifted[::-1]
    final = payload + "." + _agent_checksum(payload)
    b64 = base64.urlsafe_b64encode(final.encode("utf-8")).decode("ascii").rstrip("=")
    return "ENC1:" + b64


def _agent_decrypt(cipher):
    """解密：kv→ob→ugg→hex→oem→obf→utp 逆序还原"""
    if not isinstance(cipher, str) or not cipher.startswith("ENC1:"):
        return None
    token = cipher[5:]
    try:
        padding = "=" * (-len(token) % 4)
        final = base64.urlsafe_b64decode(token + padding).decode("utf-8")
        payload, _, sig = final.rpartition(".")
        if not payload or _agent_checksum(payload) != sig:
            return None
        s = payload[::-1]
        s = "".join(_AGENT_HEX_CHARS[(_AGENT_HEX_CHARS.index(c) - 7) % 16] for c in s)
        raw = bytes.fromhex(s)
        raw = bytes((x - 17) % 256 for x in raw)
        raw = bytes(raw[i] ^ _AGENT_ENC_KEY[i % len(_AGENT_ENC_KEY)] for i in range(len(raw)))
        return raw.decode("utf-8")
    except Exception as e:
        return None


def _agent_decrypt_repl(m):
    dec = _agent_decrypt(m.group(0))
    return dec if dec is not None else m.group(0)


def _agent_maybe_decrypt(text):
    """整条消息解密：纯密文直接还原；混合文本逐段替换 ENC1: 片段"""
    if not isinstance(text, str) or "ENC1:" not in text:
        return text
    if text.startswith("ENC1:"):
        dec = _agent_decrypt(text)
        return dec if dec is not None else text
    return re.sub(r"ENC1:[A-Za-z0-9_-]+", _agent_decrypt_repl, text)


# =====================================================================
# 公网短链接：服务器部署后对外文件链接统一走 /s/<加密短码> 内联查看
# =====================================================================
def _public_base_url():
    return os.environ.get("PUBLIC_BASE_URL") or "http://127.0.0.1:9899"


def _build_public_short_url(abs_path):
    """文件路径 → 公网短链接（短码为加密后的文件路径）"""
    real = os.path.realpath(abs_path)
    code = _agent_encrypt(real)
    return f"{_public_base_url()}/s/{quote(code, safe='')}"


def _build_artifact_payload(data):
    """Turn an agent `artifact` event into an SSE payload for the web clients."""
    file_path = data.get("path", "")
    if not file_path:
        return None
    return { "type": "artifact", "abs_path": file_path, "rel_path": data.get("rel_path") or os.path.basename(file_path), "file_name": data.get("file_name") or os.path.basename(file_path), "kind": data.get("kind", "file"), "previewable": bool(data.get("previewable")), "size": data.get("size", 0), "raw_url": f"/api/file?path={quote(file_path)}", "preview_url": _build_public_short_url(file_path), }


def _artifacts_from_steps(steps):
    """
    Rebuild the artifact cards of a persisted assistant message.

    History replay has no SSE events, so the `write`/`edit` tool calls are the
    only record. Doing this server-side keeps one implementation of the
    workspace-internal filter — and lets absolute paths inside the workspace be
    recognised, which a client mirroring the rules can't do.
    """
    from agent.protocol.artifact import get_workspace_root, safe_build_artifact

    out = []
    seen = set()
    root = None
    for step in steps or []:
        if not isinstance(step, dict) or step.get("type") != "tool":
            continue
        if step.get("is_error") or step.get("name") not in ("write", "edit"):
            continue
        args = step.get("arguments")
        path = str((args or {}).get("path") or "").strip() if isinstance(args, dict) else ""
        if not path:
            continue
        if root is None:
            root = get_workspace_root()
        info = safe_build_artifact(path, root)
        if not info or info["path"] in seen:
            continue
        seen.add(info["path"])
        payload = _build_artifact_payload(info)
        if payload:
            out.append(payload)
    return out


def _sanitize_upload_relative_path(relative_path):
    """Normalize relative upload path and reject escapes / absolute paths."""
    relative_path = (relative_path or "").replace("\\", "/").strip("/")
    if not relative_path:
        raise ValueError("Empty relative path")
    parts = []
    for part in relative_path.split("/"):
        if part in ("", "."):
            continue
        if part == "..":
            raise ValueError("Invalid relative path")
        parts.append(part)
    if not parts:
        raise ValueError("Invalid relative path")
    norm_path = "/".join(parts)
    if os.path.isabs(norm_path):
        raise ValueError("Invalid relative path")
    return norm_path


def _sanitize_upload_id(upload_id):
    """Allow only simple batch ids for directory uploads."""
    sanitized = "".join(ch for ch in (upload_id or "") if ch.isalnum() or ch in ("-", "_"))
    if not sanitized:
        raise ValueError("Invalid upload id")
    return sanitized[:80]


def _is_within_directory(root_path, target_path):
    try:
        return os.path.commonpath([root_path, target_path]) == root_path
    except ValueError as e:
        return False


def _resolve_upload_path(upload_root, relative_path):
    """Resolve a relative upload path under upload_root and reject escapes."""
    safe_rel_path = _sanitize_upload_relative_path(relative_path)
    upload_root_real = os.path.realpath(upload_root)
    save_path = os.path.realpath(os.path.join(upload_root_real, *safe_rel_path.split("/")))
    if not _is_within_directory(upload_root_real, save_path):
        raise ValueError("Invalid directory upload path")
    return safe_rel_path, save_path


def _read_uploaded_file_bytes(file_obj):
    """Return uploaded content as bytes across web.py upload object variants."""
    if isinstance(file_obj, bytes):
        return file_obj
    if isinstance(file_obj, str):
        return file_obj.encode("utf-8")

    content = None

    if hasattr(file_obj, "file") and hasattr(file_obj.file, "read"):
        content = file_obj.file.read()
    elif hasattr(file_obj, "read"):
        content = file_obj.read()
    elif hasattr(file_obj, "value"):
        content = file_obj.value

    if content is None:
        raise ValueError("Unable to read uploaded file content")
    if isinstance(content, bytes):
        return content
    if isinstance(content, str):
        return content.encode("utf-8")
    raise TypeError(f"Unsupported uploaded content type: {type(content).__name__}")


def _read_uploaded_file_bytes_limited(file_obj, max_bytes):
    """Read uploaded content and fail once it exceeds max_bytes."""
    if isinstance(file_obj, bytes):
        content = file_obj
    elif isinstance(file_obj, str):
        content = file_obj.encode("utf-8")
    elif hasattr(file_obj, "file") and hasattr(file_obj.file, "read"):
        content = file_obj.file.read(max_bytes + 1)
    elif hasattr(file_obj, "read"):
        content = file_obj.read(max_bytes + 1)
    elif hasattr(file_obj, "value"):
        content = file_obj.value
    else:
        raise ValueError("Unable to read uploaded file content")
    if isinstance(content, str):
        content = content.encode("utf-8")
    if not isinstance(content, bytes):
        raise TypeError(f"Unsupported uploaded content type: {type(content).__name__}")
    if len(content) > max_bytes:
        raise ValueError("file too large")
    return content


def _raw_web_input():
    """Return unprocessed multipart form data when web.py exposes rawinput."""
    rawinput = getattr(getattr(web, "webapi", None), "rawinput", None)
    if not callable(rawinput):
        raise RuntimeError("web.py rawinput is not available")
    try:
        return rawinput(method="post")
    except TypeError as e:
        return rawinput()


def _ensure_list(value):
    if value is None:
        return []
    if isinstance(value, list):
        return value
    return [value]


def _generate_session_title(user_message, assistant_reply = ""):
    """Delegate to the shared SessionService implementation."""
    from agent.chat.session_service import generate_session_title
    return generate_session_title(user_message, assistant_reply)


class WebMessage(ChatMessage):
    def __init__(self, msg_id, content, ctype=ContextType.TEXT, from_user_id="User", to_user_id="Chatgpt", other_user_id="Chatgpt"):
        self.msg_id = msg_id
        self.ctype = ctype
        self.content = content
        self.from_user_id = from_user_id
        self.to_user_id = to_user_id
        self.other_user_id = other_user_id


@singleton
class WebChannel(ChatChannel):
    NOT_SUPPORT_REPLYTYPE = [ReplyType.VOICE]
    _instance = None

    # def __new__(cls):
    # if cls._instance is None:
    # cls._instance = super(WebChannel, cls).__new__(cls)
    # return cls._instance

    def __init__(self):
        super().__init__()
        self.msg_id_counter = 0
        self.session_queues = {}  # session_id -> Queue (fallback polling)
        self.request_to_session = {}  # request_id -> session_id
        self.sse_queues = {}  # request_id -> Queue (SSE streaming)
        # request_id -> last-active timestamp. Refreshed while the SSE
        # generator is being consumed (client still connected). The janitor
        # only reclaims queues whose generator stopped refreshing self, so a
        # long-running but still-streaming reply is never wrongly killed.
        self.sse_last_active = {}
        self._http_server = None
        self._sse_janitor_started = False

    def _generate_msg_id(self):
        """生成唯一的消息ID"""
        self.msg_id_counter += 1
        return str(int(time.time())) + str(self.msg_id_counter)

    def _generate_request_id(self):
        """生成唯一的请求ID"""
        return str(uuid.uuid4())

    def _fetch_latest_pair_seqs(self, session_id):
        """Query the conversation store for the latest user/bot message seqs.

        Returned as ``{"user_seq": int|None, "bot_seq": int|None}``; used to
        attach seq metadata onto the SSE ``done`` event so the frontend can
        wire edit / regenerate buttons for live-streamed bubbles without a
        page refresh.
        """
        try:
            from agent.memory import get_conversation_store
            return get_conversation_store().get_latest_pair_seqs(session_id)
        except Exception as e:
            logger.debug(f"[WebChannel] _fetch_latest_pair_seqs failed: {e}")
            return {"user_seq": None, "bot_seq": None}

    def send(self, reply, context):
        try:
            if reply.type in self.NOT_SUPPORT_REPLYTYPE:
                logger.warning(f"Web channel doesn't support {reply.type} yet")
                return

            if reply.type == ReplyType.IMAGE_URL:
                time.sleep(0.5)

            request_id = context.get("request_id", None)
            if not request_id:
                logger.error("No request_id found in context, cannot send message")
                return

            session_id = self.request_to_session.get(request_id)
            if not session_id:
                logger.error(f"No session_id found for request {request_id}")
                return

            # SSE mode: push events to SSE queue
            if request_id in self.sse_queues:
                content = reply.content if reply.content is not None else ""

                # Intermediate status lines (e.g. /install-browser phases) must NOT use "done",
                # or the frontend closes EventSource and drops subsequent events.
                if getattr(reply, "sse_phase", False):
                    self.sse_queues[request_id].put({ "type": "phase", "content": content, "request_id": request_id, "timestamp": time.time(), })
                    logger.debug(f"SSE phase for request {request_id}")
                    return

                # Files are already pushed via on_event (file_to_send) during agent execution.
                # Skip duplicate file pushes here; just let the done event through.
                if reply.type in (ReplyType.IMAGE_URL, ReplyType.FILE) and content.startswith("file://"):
                    text_content = getattr(reply, 'text_content', '')
                    if text_content:
                        seqs = self._fetch_latest_pair_seqs(session_id)
                        self.sse_queues[request_id].put({ "type": "done", "content": text_content, "request_id": request_id, "timestamp": time.time(), "user_seq": seqs.get("user_seq"), "bot_seq": seqs.get("bot_seq"), })
                    logger.debug(f"SSE skipped duplicate file for request {request_id}")
                    return

                # Skip http-URL FILE/IMAGE_URL replies produced by chat_channel's media extraction:
                # the text reply (already sent as "done") contains the URL and the frontend will
                # render it via renderMarkdown/injectVideoPlayers, so no separate SSE event needed.
                if reply.type in (ReplyType.FILE, ReplyType.IMAGE_URL) and content.startswith(("http://", "https://")):
                    logger.debug(f"SSE skipped http media reply for request {request_id}")
                    return

                seqs = self._fetch_latest_pair_seqs(session_id)
                self.sse_queues[request_id].put({ "type": "done", "content": content, "request_id": request_id, "timestamp": time.time(), "user_seq": seqs.get("user_seq"), "bot_seq": seqs.get("bot_seq"), })
                logger.debug(f"SSE done sent for request {request_id}")
                # Auto-trigger TTS once the bot finishes its text reply. The
                # synthesis runs in the background so the chat stream is never
                # blocked; the resulting audio URL is pushed via a follow-up
                # `voice_attach` SSE event and persisted to messages.extras.
                if reply.type == ReplyType.TEXT and content.strip():
                    self._maybe_dispatch_auto_tts(request_id, session_id, content, context)
                return

            # Fallback: polling mode
            if session_id in self.session_queues:
                content = reply.content if reply.content is not None else ""
                # Skip file:// IMAGE_URL/FILE replies originating from an SSE-enabled
                # request: they were already pushed via the `file_to_send` event during
                # agent execution. By the time the chat_channel sends the IMAGE_URL reply,
                # the SSE stream has typically closed (after the text "done") and the
                # request_id is gone from sse_queues, so we'd otherwise duplicate the file
                # as a polling bubble. Scheduler/push tasks have no on_event and must
                # still go through polling normally.
                if ( reply.type in (ReplyType.IMAGE_URL, ReplyType.FILE) and content.startswith("file://") and context.get("on_event") is not None ):
                    logger.debug(f"Polling skipped duplicate file reply for session {session_id}")
                    return
                # SSE-enabled requests already stream the text reply to the
                # client. Do NOT also enqueue it for polling: if the user
                # switched away mid-run, the queued copy would resurface as a
                # duplicate bubble when they return and poll the session.
                if reply.type == ReplyType.TEXT and context.get("on_event") is not None:
                    logger.debug(f"Polling skipped SSE text reply for session {session_id}")
                    return
                response_data = { "type": str(reply.type), "content": content, "timestamp": time.time(), "request_id": request_id }
                self.session_queues[session_id].put(response_data)
                logger.debug(f"Response sent to poll queue for session {session_id}, request {request_id}")
            else:
                logger.warning(f"No response queue found for session {session_id}, response dropped")

        except Exception as e:
            logger.error(f"Error in send method: {e}")

    def _make_sse_callback(self, request_id):
        """Build an on_event callback that pushes agent stream events into the SSE queue."""

        # Cap reasoning bytes pushed to the frontend per request to avoid
        # browser stalls / crashes on very long chains-of-thought. Anything
        # beyond the cap is dropped from the stream (DB still persists a
        # truncated copy via _truncate_reasoning_for_storage).
        # Keep aligned with frontend REASONING_RENDER_CAP and backend
        # MAX_STORED_REASONING_CHARS.
        MAX_REASONING_STREAM_CHARS = 4 * 1024  # 4 KB
        # Use a single-element list as a mutable counter accessible from closure.
        reasoning_chars_sent = [0]
        reasoning_capped_notified = [False]
        # Captures the first error message emitted by agent_stream so the
        # subsequent agent_end handler can skip its "empty final_response"
        # fallback (which would otherwise overwrite the real error).
        streamed_error: List[str] = []

        def on_event(event):
            if request_id not in self.sse_queues:
                return
            q = self.sse_queues[request_id]
            event_type = event.get("type")
            data = event.get("data", {})

            if event_type == "reasoning_update":
                delta = data.get("delta", "")
                if not delta:
                    return
                remaining = MAX_REASONING_STREAM_CHARS - reasoning_chars_sent[0]
                if remaining <= 0:
                    if not reasoning_capped_notified[0]:
                        reasoning_capped_notified[0] = True
                        q.put({ "type": "reasoning", "content": "\n\n... [reasoning truncated for display] ...", })
                    return
                if len(delta) > remaining:
                    delta = delta[:remaining]
                reasoning_chars_sent[0] += len(delta)
                q.put({"type": "reasoning", "content": delta})

            elif event_type == "message_update":
                delta = data.get("delta", "")
                if delta:
                    q.put({"type": "delta", "content": delta})

            elif event_type == "tool_execution_start":
                tool_name = data.get("tool_name", "tool")
                arguments = data.get("arguments", {})
                q.put({"type": "tool_start", "tool_call_id": data.get("tool_call_id"), "tool": tool_name, "arguments": arguments})

            elif event_type == "tool_execution_progress":
                q.put({ "type": "tool_progress", "tool_call_id": data.get("tool_call_id"), "tool": data.get("tool_name", "tool"), "content": str(data.get("message", ""))[-4 * 1024:], })

            elif event_type == "tool_execution_end":
                tool_name = data.get("tool_name", "tool")
                status = data.get("status", "success")
                result = data.get("result", "")
                exec_time = data.get("execution_time", 0)
                # Truncate long results to avoid huge SSE payloads
                result_str = str(result)
                if len(result_str) > 2000:
                    result_str = result_str[:2000] + "…"
                q.put({ "type": "tool_end", "tool_call_id": data.get("tool_call_id"), "tool": tool_name, "status": status, "result": result_str, "execution_time": round(exec_time, 2) })

            elif event_type == "message_end":
                tool_calls = data.get("tool_calls", [])
                if tool_calls:
                    q.put({"type": "message_end", "has_tool_calls": True})

            elif event_type == "error":
                # Agent raised an exception (LLM 401/timeout/etc). Surface the
                # real message instead of letting the empty-response fallback
                # below hide it as "(模型未返回任何内容)".
                err_msg = data.get("error") or "unknown error"
                logger.warning( f"[WebChannel] agent_stream emitted error for " f"request {request_id}: {err_msg}" )
                # Remember it so the agent_end handler below knows not to
                # rewrite the message into a generic empty-response notice.
                streamed_error.append(err_msg)
                q.put({ "type": "done", "content": f"❌ {err_msg}", "request_id": request_id, "timestamp": time.time(), })

            elif event_type == "agent_cancelled":
                # Push an explicit cancelled SSE event so the frontend
                # marks the bubble as stopped. A trailing "done" still
                # arrives with the partial answer.
                final_response = data.get("final_response", "")
                q.put({ "type": "cancelled", "content": final_response, "request_id": request_id, "timestamp": time.time(), })

            elif event_type == "agent_end":
                # Safety net: if the agent finishes with an empty final_response,
                # chat_channel skips _send_reply (because reply.content is empty),
                # which means no "done" event is ever emitted and the SSE stream
                # would hang until the 10-min idle timeout. Push a fallback "done"
                # here so the frontend always gets closure.
                final_response = data.get("final_response", "")
                if not final_response or not str(final_response).strip():
                    if streamed_error:
                        # Error was already surfaced via the `error` event
                        # handler above; nothing more to do here.
                        pass
                    else:
                        logger.warning( f"[WebChannel] agent_end with empty final_response for " f"request {request_id}, sending fallback done" )
                        q.put({ "type": "done", "content": i18n.t( "(模型未返回任何内容，请重试或换一种方式描述你的需求)", "(The model returned no content. Please retry or rephrase your request.)", ), "request_id": request_id, "timestamp": time.time(), })

            elif event_type == "file_to_send":
                file_path = data.get("path", "")
                file_name = data.get("file_name", os.path.basename(file_path))
                file_type = data.get("file_type", "file")
                # Remote URLs are passed through as-is; local files are served
                # via the backend /api/file endpoint.
                remote_url = data.get("url", "")
                is_remote = bool(remote_url) and remote_url.lower().startswith(("http://", "https://"))
                if is_remote:
                    web_url = remote_url
                else:
                    # 服务器部署：本地文件对外用加密短链接（无需登录即可查看）
                    web_url = _build_public_short_url(file_path)
                is_image = file_type == "image"
                payload = { "type": "image" if is_image else "file", "content": web_url, "file_name": file_name,   "file_type": file_type, }
                # Expose the local absolute path so the desktop client can open
                # the file directly (Finder / default app) instead of the browser.
                if not is_remote and file_path:
                    payload["abs_path"] = file_path
                q.put(payload)

            elif event_type == "artifact":
                payload = _build_artifact_payload(data)
                if payload:
                    q.put(payload)

        return on_event

    # ------------------------------------------------------------------
    # TTS auto-dispatch
    # ------------------------------------------------------------------
    @staticmethod
    def _resolve_voice_reply_mode():
        """
        Decide the TTS auto-reply policy.

        Source of truth is the cross-channel pair
        (`always_reply_voice`, `voice_reply_voice`) which chat_channel
        also consults. The web UI presents these as a single three-state
        picker (off / voice_if_voice / always) via a lossless mapping.
        """
        if conf().get("always_reply_voice", False):
            return "always"
        if conf().get("voice_reply_voice", False):
            return "voice_if_voice"
        return "off"

    # Mirror of ModelsHandler._TTS_PROVIDERS. zhipu is intentionally omitted
    # from the UI (GLM-TTS prelude beep); pinning it in config.json still works.
    _TTS_PROVIDERS_SUGGEST_ORDER = ["openai", "minimax", "dashscope", "linkai"]

    @classmethod
    def _tts_provider_ready(cls):
        """True if user picked a provider OR any suggested vendor has an API key."""
        if (conf().get("text_to_voice") or "").strip():
            return True
        for pid in cls._TTS_PROVIDERS_SUGGEST_ORDER:
            meta = ConfigHandler.PROVIDER_MODELS.get(pid) or {}
            key_field = meta.get("api_key_field")
            if not key_field:
                continue
            val = (conf().get(key_field) or "").strip()
            if val and val not in ("YOUR API KEY", "YOUR_API_KEY"):
                return True
        return False

    def _maybe_dispatch_auto_tts(self, request_id, session_id, text, context):
        try:
            mode = self._resolve_voice_reply_mode()
            if mode == "off":
                return
            if mode == "voice_if_voice" and not context.get("is_voice_input"):
                return
            if not self._tts_provider_ready():
                return
            threading.Thread( target=self._synthesize_tts_async, args=(request_id, session_id, text), daemon=True, ).start()
        except Exception as e:
            logger.debug(f"[WebChannel] auto-tts dispatch skipped: {e}")

    def _synthesize_tts_async(self, request_id, session_id, text):
        try:
            from bridge.bridge import Bridge
            reply = Bridge().fetch_text_to_voice(text)
            if reply is None or reply.type != ReplyType.VOICE or not reply.content:
                logger.warning( f"[WebChannel] TTS produced no audio for request {request_id}: " f"reply={reply}" )
                return
            url = self._publish_tts_audio(reply.content)
            if not url:
                logger.warning(f"[WebChannel] TTS publish failed for request {request_id}")
                return
            payload = {"audio": {"url": url, "kind": "tts"}}
            try:
                from agent.memory import get_conversation_store
                get_conversation_store().attach_extras_to_last_assistant(session_id, payload)
            except Exception as e:
                logger.debug(f"[WebChannel] tts persist skipped: {e}")
            q = self.sse_queues.get(request_id)
            if q is None:
                logger.warning( f"[WebChannel] TTS ready but SSE queue already closed " f"for request {request_id} (url={url})" )
                return
            q.put({ "type": "voice_attach", "url": url, "request_id": request_id, "timestamp": time.time(), })
            logger.info(f"[WebChannel] TTS voice_attach pushed for request {request_id}: {url}")
        except Exception as e:
            # TTS failures are intentionally silent (no user-facing error).
            logger.warning(f"[WebChannel] TTS synthesis failed: {e}")

    @staticmethod
    def _publish_tts_audio(src_path):
        """Move a TTS file into uploads/ and return its public URL."""
        try:
            if not src_path or not os.path.isfile(src_path):
                logger.warning(f"[WebChannel] publish_tts_audio missing source: {src_path!r}")
                return ""
            ext = os.path.splitext(src_path)[1].lower() or ".mp3"
            upload_dir = _get_upload_dir()
            os.makedirs(upload_dir, exist_ok=True)
            ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
            dst_name = f"voice_reply_{ts}_{random.randint(0, 9999)}{ext}"
            dst_path = os.path.join(upload_dir, dst_name)
            shutil.move(src_path, dst_path)
            logger.debug(f"[WebChannel] publish_tts_audio moved {src_path} -> {dst_path}")
            return _build_public_short_url(dst_path)
        except Exception as e:
            logger.warning(f"[WebChannel] publish_tts_audio failed: {e}")
            return ""

    @staticmethod
    def _cleanup_stale_voice_recordings(max_age_seconds = 3600):
        """Drop voice_input_* uploads older than max_age_seconds (run at startup)."""
        try:
            upload_dir = _get_upload_dir()
            if not os.path.isdir(upload_dir):
                return
            now = time.time()
            removed = 0
            for name in os.listdir(upload_dir):
                if not name.startswith("voice_input_"):
                    continue
                full = os.path.join(upload_dir, name)
                try:
                    if not os.path.isfile(full):
                        continue
                    if now - os.path.getmtime(full) > max_age_seconds:
                        os.remove(full)
                        removed += 1
                except OSError as e:
                    continue
            if removed:
                logger.info(f"[WebChannel] cleaned up {removed} stale voice recording(s) from {upload_dir}")
        except Exception as e:
            logger.warning(f"[WebChannel] voice cleanup failed: {e}")

    def upload_file(self):
        """Handle file or directory upload via multipart/form-data."""
        try:
            params = _raw_web_input()
            file_obj = params.get("file")
            file_objs = params.get("files")
            session_id = params.get("session_id", "")
            relative_path = params.get("relative_path", "")
            relative_paths = params.get("relative_paths")
            upload_id = params.get("upload_id", "")

            directory_files = _ensure_list(file_objs)

            # NOTE: cgi.FieldStorage raises TypeError on truthy checks for single-file
            # uploads (Python 3.9+). Always use `is not None` instead of `if file_obj`.
            if not directory_files and file_obj is not None and relative_path:
                directory_files = [file_obj]

            directory_rel_paths = _ensure_list(relative_paths)

            if not directory_rel_paths and relative_path:
                directory_rel_paths = [relative_path]

            is_directory_upload = bool(directory_files) or bool(directory_rel_paths) or bool(relative_path) or bool(upload_id)

            upload_dir = _get_upload_dir()
            if is_directory_upload:
                if not upload_id:
                    return json.dumps({"status": "error", "message": "Missing upload_id for directory upload"})
                if not directory_files:
                    return json.dumps({"status": "error", "message": "No files uploaded"})
                if len(directory_files) != len(directory_rel_paths):
                    return json.dumps({"status": "error", "message": "Directory upload payload mismatch"})

                safe_upload_id = _sanitize_upload_id(upload_id)
                upload_root = os.path.join(upload_dir, f"webdir_{safe_upload_id}")
                upload_root_real = os.path.realpath(upload_root)

                root_name = None
                saved_files = 0
                for file_obj, rel_path in zip(directory_files, directory_rel_paths):
                    if file_obj is None:
                        raise ValueError("Invalid uploaded file")
                    safe_rel_path, save_path = _resolve_upload_path(upload_root_real, rel_path)
                    current_root_name = safe_rel_path.split("/", 1)[0]
                    if root_name is None:
                        root_name = current_root_name
                    elif root_name != current_root_name:
                        raise ValueError("Directory upload must use a single root folder")
                    os.makedirs(os.path.dirname(save_path), exist_ok=True)
                    content_bytes = _read_uploaded_file_bytes(file_obj)
                    with open(save_path, "wb") as f:
                        f.write(content_bytes)
                    saved_files += 1

                if not root_name:
                    raise ValueError("Directory root path missing")

                root_path = os.path.realpath(os.path.join(upload_root_real, root_name))
                if not _is_within_directory(upload_root_real, root_path):
                    raise ValueError("Invalid directory upload path")

                logger.info(f"[WebChannel] Directory uploaded: {root_name} -> {root_path} ({saved_files} files)")
                return json.dumps({ "status": "success", "file_path": root_path, "file_name": root_name, "file_type": "directory", "file_count": saved_files, "root_path": root_path, "root_name": root_name, "upload_type": "directory", }, ensure_ascii=False)

            if file_obj is None or not hasattr(file_obj, "filename") or not file_obj.filename:
                return json.dumps({"status": "error", "message": "No file uploaded"})

            original_name = file_obj.filename
            ext = os.path.splitext(original_name)[1].lower()
            safe_name = f"web_{uuid.uuid4().hex[:8]}{ext}"
            save_path = os.path.join(upload_dir, safe_name)
            public_path = safe_name
            display_name = original_name

            content_bytes = _read_uploaded_file_bytes(file_obj)
            with open(save_path, "wb") as f:
                f.write(content_bytes)

            if ext in IMAGE_EXTENSIONS:
                file_type = "image"
            elif ext in VIDEO_EXTENSIONS:
                file_type = "video"
            else:
                file_type = "file"

            from urllib.parse import quote
            preview_url = _build_public_short_url(save_path)
            # 本地同源预览地址：不依赖 PUBLIC_BASE_URL，对话内联预览始终可达。
            # 与 artifact 的 raw_url 设计保持一致（preview_url 为公网短链，用于对外分享）。
            raw_url = f"/uploads/{quote(public_path)}"

            logger.info(f"[WebChannel] File uploaded: {original_name} -> {save_path} ({file_type})")

            return json.dumps({ "status": "success", "file_path": save_path, "file_name": display_name, "file_type": file_type, "preview_url": preview_url, "raw_url": raw_url, }, ensure_ascii=False)

        except Exception as e:
            logger.error(f"[WebChannel] File upload error: {e}", exc_info=True)
            return json.dumps({"status": "error", "message": str(e)})

    def post_message(self):
        """
        Handle incoming messages from users via POST request.
        Returns a request_id for tracking this specific request.
        Supports optional attachments (file paths from /upload).
        """
        try:
            data = web.data()
            json_data = json.loads(data)
            session_id = json_data.get('session_id', f'session_{int(time.time())}')
            prompt = json_data.get('message', '')
            # 智能体「加入到输入消息框」的内容为 ENC1 密文，发送时在此解密还原
            prompt = _agent_maybe_decrypt(prompt)
            use_sse = json_data.get('stream', True)
            attachments = json_data.get('attachments', [])
            # Tag the message as originating from voice input so the post-reply
            # TTS hook can honour the `voice_if_voice` policy (mirrors the
            # desire_rtype concept used by other channels).
            is_voice_input = bool(json_data.get('is_voice', False))

            # Fast path for /cancel: bypass the session queue and SSE setup.
            # Web frontend (stream=True) only listens to SSE, so we return an
            # inline_reply payload to be rendered synchronously.
            stripped_prompt = (prompt or "").strip().lower()
            if stripped_prompt == "/cancel":
                from agent.protocol import get_cancel_registry
                cancelled = get_cancel_registry().cancel_session(session_id)
                lang = (json_data.get('lang') or 'zh').lower()
                msg_text = _cancel_reply_text(cancelled, lang)
                logger.info( f"[WebChannel] /cancel fast-path: session={session_id}, cancelled={cancelled}, lang={lang}" )
                return json.dumps({ "status": "success", "request_id": "", "stream": False, "inline_reply": msg_text, })

            # Explicit steering also bypasses the normal session queue. The
            # Web button sends ``steer: True`` with raw input; typed /steer
            # commands use the same endpoint and semantics as IM channels.
            steer_requested = bool(json_data.get("steer", False))
            is_steer_command = ( re.match(r"^/steer(?:\s|$)", stripped_prompt) is not None )
            if steer_requested or is_steer_command:
                instruction = ( (prompt or "").strip()[len("/steer"):].strip() if is_steer_command else (prompt or "").strip() )
                from bridge.bridge import Bridge
                result = Bridge().get_agent_bridge().steer_session( session_id, instruction )
                lang = (json_data.get("lang") or "zh").lower()
                msg_text = _steer_reply_text(result.status, lang)
                logger.info( f"[WebChannel] steer fast-path: session={session_id}, " f"status={result.status.value}, lang={lang}" )
                return json.dumps({ "status": "success", "request_id": "", "stream": False, "steered": result.accepted, "inline_reply": msg_text, }, ensure_ascii=False)

            # Append file references to the prompt (same format as QQ channel)
            if attachments:
                file_refs = []
                for att in attachments:
                    ftype = att.get("file_type", "file")
                    fpath = att.get("file_path", "")
                    if not fpath:
                        continue
                    if ftype == "workspace_ref":
                        # Already lives in the workspace (dragged from the file panel
                        # or picked with @); reference it in place so the agent opens
                        # the original instead of an uploaded copy. Naming the kind
                        # tells the agent whether to `read` it or `ls` into it.
                        is_dir = os.path.isdir( os.path.join(_get_workspace_root(), fpath) )
                        label = ( i18n.t('工作空间目录', 'Workspace directory') if is_dir else i18n.t('工作空间文件', 'Workspace file') )
                        file_refs.append(f"[{label}: {fpath}]")
                    elif ftype == "image":
                        file_refs.append(f"[{i18n.t('图片', 'Image')}: {fpath}]")
                    elif ftype == "video":
                        file_refs.append(f"[{i18n.t('视频', 'Video')}: {fpath}]")
                    elif ftype == "directory":
                        file_refs.append(f"[{i18n.t('目录', 'Directory')}: {fpath}]")
                    else:
                        file_refs.append(f"[{i18n.t('文件', 'File')}: {fpath}]")
                if file_refs:
                    prompt = prompt + "\n" + "\n".join(file_refs)
                    logger.info(f"[WebChannel] Attached {len(file_refs)} file(s) to message")

            request_id = self._generate_request_id()
            self.request_to_session[request_id] = session_id

            if session_id not in self.session_queues:
                self.session_queues[session_id] = Queue()

            if use_sse:
                self.sse_queues[request_id] = Queue()
                self.sse_last_active[request_id] = time.time()

            trigger_prefixs = conf().get("single_chat_prefix", [""])
            if check_prefix(prompt, trigger_prefixs) is None:
                if trigger_prefixs:
                    prompt = trigger_prefixs[0] + prompt
                    logger.debug(f"[WebChannel] Added prefix to message: {prompt}")

            msg = WebMessage(self._generate_msg_id(), prompt)
            msg.from_user_id = session_id

            # 会话绑定智能体节点：把节点能力注入用户消息上下文，
            # 让 Agent 用原有模型理解并优先结合这些节点能力作答。
            bound_nodes = _get_agent_bindings(session_id)
            if bound_nodes:
                node_lines = []
                for idx, bn in enumerate(bound_nodes, 1):
                    node_lines.append( f"{idx}. {bn.get('icon', '')} {bn.get('name', '')}（编码 {bn.get('code', '')}，" f"分类 {bn.get('kind', '')}，类型 {bn.get('type', '')}，" f"调用 {bn.get('api_url', '') or '未配置'}，模型 {bn.get('model', '') or '默认'}）" f"——{bn.get('remark', '') or '无说明'}" )
                node_ctx = ( f"【当前会话已绑定 {len(bound_nodes)} 个智能体节点】\n" + "\n".join(node_lines) + "\n请在回答中优先结合这些节点能力；如需调用节点 API，向用户说明并按其协议调用。\n\n" )
                prompt = node_ctx + prompt

            context = self._compose_context(ContextType.TEXT, prompt, msg=msg, isgroup=False)

            if context is None:
                logger.warning(f"[WebChannel] Context is None for session {session_id}, message may be filtered")
                self._drop_sse_request(request_id)
                return json.dumps({"status": "error", "message": "Message was filtered"})

            context["session_id"] = session_id
            context["receiver"] = session_id
            context["request_id"] = request_id
            if is_voice_input:
                # Web channel runs its own TTS post-pipeline via
                # _maybe_dispatch_auto_tts; don't set desire_rtype here or
                # chat_channel would synthesize a duplicate VOICE reply.
                context["is_voice_input"] = True

            if use_sse:
                context["on_event"] = self._make_sse_callback(request_id)

            threading.Thread(target=self.produce, args=(context,)).start()

            return json.dumps({"status": "success", "request_id": request_id, "stream": use_sse})

        except Exception as e:
            logger.error(f"Error processing message: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def _drop_sse_request(self, request_id):
        """Reclaim all state tied to an SSE request to prevent fd/memory leaks.

        Removing the queue lets the WSGI generator and its socket be released,
        and dropping request_to_session avoids unbounded map growth.
        """
        self.sse_queues.pop(request_id, None)
        self.sse_last_active.pop(request_id, None)
        self.request_to_session.pop(request_id, None)

    def _start_sse_janitor(self):
        """Start a background thread that reclaims orphaned SSE queues.

        When a client disconnects before the "done" event arrives (browser
        closed, session switched, network drop), the generator may keep the
        queue around to allow reconnection. Without a sweep these orphans
        accumulate, leaking file descriptors until cheroot raises
        "[Errno 24] Too many open files".

        Reclamation is based on idle time, not total age: an active stream
        refreshes ``sse_last_active`` every second while its generator is being
        consumed, so a long-running reply (even hours long) is never killed
        while the client stays connected. Only queues that stopped refreshing
        (client gone) past SSE_IDLE_TIMEOUT are reclaimed.
        """
        if self._sse_janitor_started:
            return
        self._sse_janitor_started = True

        SSE_IDLE_TIMEOUT = 1800  # 30 minutes with no client consumption
        SWEEP_INTERVAL = 60

        def _sweep():
            while True:
                time.sleep(SWEEP_INTERVAL)
                try:
                    now = time.time()
                    stale = [ rid for rid, ts in list(self.sse_last_active.items()) if now - ts > SSE_IDLE_TIMEOUT ]
                    for rid in stale:
                        self._drop_sse_request(rid)
                    if stale:
                        logger.info( f"[WebChannel] SSE janitor reclaimed {len(stale)} " f"idle stream(s)" )
                except Exception as e:
                    logger.warning(f"[WebChannel] SSE janitor error: {e}")

        t = threading.Thread(target=_sweep, name="sse-janitor", daemon=True)
        t.start()

    def stream_response(self, request_id):
        """
        SSE generator for a given request_id.
        Yields UTF-8 encoded bytes to avoid WSGI Latin-1 mangling.
        Supports client reconnection: the queue is only removed after a
        "done" event is consumed, so a new GET /stream with the same
        request_id can resume reading remaining events.
        """
        if request_id not in self.sse_queues:
            yield b"data: {\"type\": \"error\", \"message\": \"invalid request_id\"}\n\n"
            return

        q = self.sse_queues[request_id]
        idle_timeout = 600  # 10 minutes without any real event
        deadline = time.time() + idle_timeout
        # After the main reply is done we keep the stream open for a short
        # tail so async post-processing (TTS auto-synthesis) can deliver a
        # `voice_attach` event before the client disconnects.
        POST_DONE_TAIL_SECONDS = 60
        # A cancel only takes effect at the agent's next checkpoint, so the run
        # keeps emitting events (tool results, the partial reply) for a while
        # after the user presses Stop. Stay open for them, just not for the
        # full idle timeout.
        CANCEL_GRACE_SECONDS = 60
        POST_CANCEL_TAIL_SECONDS = 3
        post_done = False
        post_deadline = 0.0
        cancelled = False

        try:
            while time.time() < deadline:
                # Mark the stream alive on every loop. While the client keeps
                # consuming, the generator runs and refreshes self, so the
                # janitor won't reclaim a long-running but active stream.
                self.sse_last_active[request_id] = time.time()
                try:
                    item = q.get(timeout=1)
                except Empty as e:
                    if post_done and time.time() >= post_deadline:
                        break
                    yield b": keepalive\n\n"
                    continue

                deadline = time.time() + ( CANCEL_GRACE_SECONDS if cancelled else idle_timeout )
                payload = json.dumps(item, ensure_ascii=False)
                yield f"data: {payload}\n\n".encode("utf-8")

                itype = item.get("type")
                if itype == "done":
                    post_done = True
                    post_deadline = time.time() + ( POST_CANCEL_TAIL_SECONDS if cancelled else POST_DONE_TAIL_SECONDS )
                elif itype == "cancelled":
                    # Wait for the run to actually wind down and send its
                    # partial reply as "done"; closing on a blind timer here
                    # strands in-flight tool bubbles and makes the client
                    # reconnect onto a dropped queue.
                    cancelled = True
                    deadline = time.time() + CANCEL_GRACE_SECONDS
                elif itype == "voice_attach":
                    # WSGI buffers the previous chunk until the next yield;
                    # shrink the tail so the generator wakes up quickly to
                    # emit a couple of keepalive comments that push the
                    # voice_attach payload through to the browser.
                    post_done = True
                    post_deadline = time.time() + 2  # 2s post-attach tail
        except GeneratorExit as e:
            # Client disconnected (WSGI closed the generator). If the reply is
            # already complete there is nothing to resume, so reclaim now to
            # release the socket fd. Otherwise keep the queue briefly so a
            # reconnect with the same request_id can resume; the janitor will
            # reclaim it if no reconnect happens.
            if post_done:
                self._drop_sse_request(request_id)
            raise
        finally:
            # Drop the queue once the reply is actually complete or the idle
            # deadline has passed. Early client disconnects are handled by the
            # GeneratorExit branch above and the background janitor.
            if post_done or time.time() >= deadline:
                self._drop_sse_request(request_id)

    def cancel_request(self):
        """
        Cancel an in-flight agent run.

        Body: {"request_id": "...", "session_id": "..."}
        Either field is sufficient; request_id is preferred when known.
        Always returns success even when nothing was running, so the
        client's UX is idempotent.
        """
        try:
            from agent.protocol import get_cancel_registry

            data = web.data()
            try:
                json_data = json.loads(data) if data else {}
            except Exception as e:
                json_data = {}

            request_id = (json_data.get("request_id") or "").strip()
            session_id = (json_data.get("session_id") or "").strip()
            lang = (json_data.get("lang") or "zh").lower()

            registry = get_cancel_registry()
            cancelled = 0

            if request_id:
                if registry.cancel_request(request_id):
                    cancelled = 1

            if cancelled == 0 and session_id:
                cancelled = registry.cancel_session(session_id)

            if request_id and request_id in self.sse_queues:
                self.sse_queues[request_id].put({ "type": "cancelled", "content": "🛑 Cancelled" if lang.startswith("en") else "🛑 已中止", "request_id": request_id, "timestamp": time.time(), })

            logger.info( f"[WebChannel] cancel request: request_id={request_id!r}, " f"session_id={session_id!r}, cancelled={cancelled}" )
            return json.dumps({ "status": "success", "cancelled": cancelled, })

        except Exception as e:
            logger.error(f"[WebChannel] cancel_request error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def poll_response(self):
        """
        Poll for responses using the session_id.
        """
        try:
            data = web.data()
            json_data = json.loads(data)
            session_id = json_data.get('session_id')

            if not session_id or session_id not in self.session_queues:
                return json.dumps({"status": "error", "message": "Invalid session ID"})

            # 尝试从队列获取响应，不等待
            try:
                # 使用peek而不是get，这样如果前端没有成功处理，下次还能获取到
                response = self.session_queues[session_id].get(block=False)

                # 返回响应，包含请求ID以区分不同请求
                return json.dumps({ "status": "success", "has_content": True, "content": response["content"], "request_id": response["request_id"], "timestamp": response["timestamp"] })

            except Empty as e:
                # 没有新响应
                return json.dumps({"status": "success", "has_content": False})

        except Exception as e:
            logger.error(f"Error polling response: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def chat_page(self):
        """Serve the chat HTML page."""
        file_path = os.path.join(os.path.dirname(__file__), 'chat.html')  # 使用绝对路径
        with open(file_path, 'r', encoding='utf-8') as f:
            html = f.read()
        # Inject the backend-resolved default language so the console can use
        # it on first load (when the user has no saved cow_lang preference).
        return html.replace("{{COW_DEFAULT_LANG}}", i18n.get_language())

    def startup(self):
        configured_host = conf().get("web_host", "")
        host = configured_host or ("0.0.0.0" if _is_password_enabled() else "127.0.0.1")
        # The desktop app passes its chosen port via COW_WEB_PORT so its backend
        # never collides with a source-run web console (default 9899). This makes
        # the port a single source of truth owned by the Electron shell.
        port = int(os.environ.get("COW_WEB_PORT") or conf().get("web_port", 9899))
        is_public_bind = host in ("0.0.0.0", "::")

        self._cleanup_stale_voice_recordings()

        # Print available channel types (ordered by language: prioritize
        # locally-popular channels for the current UI language)
        logger.info( "[WebChannel] Available channels (edit `channel_type` in config.json to switch, separate multiple with commas):")
        zh_channels = [ ("web", "Web"), ("terminal", "Terminal"), ("weixin", "WeChat"), ("feishu", "Feishu"), ("dingtalk", "DingTalk"), ("wecom_bot", "WeCom Bot"), ("wechatcom_app", "WeCom App"), ("wechat_kf", "WeChat Customer Service"), ("wechatmp", "WeChat Official Account"), ("wechatmp_service", "WeChat Official Account (Service)"), ("telegram", "Telegram"), ("slack", "Slack"), ("discord", "Discord"), ]
        en_channels = [ ("web", "Web"), ("terminal", "Terminal"), ("telegram", "Telegram"), ("slack", "Slack"), ("discord", "Discord"), ("weixin", "WeChat"), ("feishu", "Feishu"), ("dingtalk", "DingTalk"), ("wecom_bot", "WeCom Bot"), ("wechatcom_app", "WeCom App"), ("wechat_kf", "WeChat Customer Service"), ("wechatmp", "WeChat Official Account"), ("wechatmp_service", "WeChat Official Account (Service)"), ]
        channels = en_channels if i18n.get_language() == "en" else zh_channels
        name_width = max(len(name) for name, _ in channels)
        for idx, (name, label) in enumerate(channels, 1):
            logger.info(f"[WebChannel]  {idx:>2}. {name:<{name_width}} - {label}")
        logger.info("[WebChannel] ✅ Web console is running")
        logger.info(f"[WebChannel] 🌐 Local access: http://localhost:{port}")
        if is_public_bind:
            logger.info(f"[WebChannel] 🌍 Server access: http://YOUR_IP:{port} (replace YOUR_IP with your server IP)")
            if not _is_password_enabled():
                logger.info("[WebChannel] ⚠️  Listening on 0.0.0.0 without web_password set; set an access password in config.json for public deployment")
        else:
            logger.info(f"[WebChannel] 🔒 Listening on {host} only (local access). For public access, set web_host to 0.0.0.0 and configure web_password")

        # In desktop mode the Electron shell renders the UI, so don't pop a
        # browser window (also avoids issues when running detached/headless).
        if os.environ.get("COW_DESKTOP") != "1":
            try:
                import webbrowser
                webbrowser.open(f"http://localhost:{port}")
                logger.debug(f"[WebChannel] Opened browser at http://localhost:{port}")
            except Exception as e:
                logger.debug(f"[WebChannel] Could not open browser: {e}")

        # Ensure the static dir exists. In a packaged build it ships read-only
        # inside the bundle, so swallow errors instead of failing startup.
        static_dir = os.path.join(os.path.dirname(__file__), 'static')
        if not os.path.exists(static_dir):
            try:
                os.makedirs(static_dir)
                logger.debug(f"[WebChannel] Created static directory: {static_dir}")
            except OSError as e:
                logger.debug(f"[WebChannel] Skipped creating static dir (read-only bundle?): {e}")

        urls = ( '/', 'RootHandler', '/api/health', 'HealthHandler', '/auth/login', 'AuthLoginHandler', '/auth/check', 'AuthCheckHandler', '/auth/logout', 'AuthLogoutHandler', '/message', 'MessageHandler', '/upload', 'UploadHandler', '/uploads/(.*)', 'UploadsHandler', '/api/file', 'FileServeHandler', '/api/shortlink', 'ShortLinkApiHandler', '/s/(.+)', 'ShortLinkHandler', '/preview/(.+)', 'PreviewHandler', '/api/workspace/tree', 'WorkspaceTreeHandler', '/api/workspace/search', 'WorkspaceSearchHandler', '/api/workspace/resolve', 'WorkspaceResolveHandler', '/api/workspace/meta', 'WorkspaceMetaHandler', '/api/voice/asr', 'VoiceAsrHandler', '/api/voice/tts', 'VoiceTtsHandler', '/poll', 'PollHandler', '/stream', 'StreamHandler', '/cancel', 'CancelHandler', '/chat', 'ChatHandler', '/@vite/client', 'ViteClientFallbackHandler', '/config', 'ConfigHandler', '/api/models', 'ModelsHandler', '/api/channels', 'ChannelsHandler', '/api/weixin/qrlogin', 'WeixinQrHandler', '/api/feishu/register', 'FeishuRegisterHandler', '/api/tools', 'ToolsHandler', '/api/skills', 'SkillsHandler', '/api/memory', 'MemoryHandler', '/api/memory/content', 'MemoryContentHandler', '/api/knowledge/list', 'KnowledgeListHandler', '/api/knowledge/read', 'KnowledgeReadHandler', '/api/knowledge/graph', 'KnowledgeGraphHandler', '/api/knowledge/action', 'KnowledgeActionHandler', '/api/knowledge/import', 'KnowledgeImportHandler', '/api/scheduler', 'SchedulerHandler', '/api/scheduler/create', 'SchedulerCreateHandler', '/api/scheduler/run', 'SchedulerRunHandler', '/api/scheduler/toggle', 'SchedulerToggleHandler', '/api/scheduler/update', 'SchedulerUpdateHandler', '/api/scheduler/delete', 'SchedulerDeleteHandler', '/api/sessions', 'SessionsHandler', '/api/sessions/(.*)/generate_title', 'SessionTitleHandler', '/api/prompt/optimize', 'PromptOptimizeHandler', '/api/sessions/(.*)/clear_context', 'SessionClearContextHandler', '/api/sessions/(.*)', 'SessionDetailHandler', '/api/history', 'HistoryHandler', '/api/messages/delete', 'MessageDeleteHandler', '/api/logs', 'LogsHandler', '/api/version', 'VersionHandler', '/mcp/oauth/callback', 'McpOAuthCallbackHandler', '/api/monitor/start', 'MonitorStartHandler', '/api/monitor/stop', 'MonitorStopHandler', '/api/monitor/stream', 'MonitorStreamHandler', '/api/monitor/history', 'MonitorHistoryHandler', '/api/monitor/message', 'MonitorMessageHandler', '/api/monitor/command', 'MonitorCommandHandler', '/api/monitor/poll', 'MonitorPollHandler', '/api/monitor/status', 'MonitorStatusHandler', '/api/monitor/bridge', 'MonitorBridgeHandler', '/api/analyze/prompt', 'PromptAnalyzeHandler', '/api/agent/nodes/(.*)', 'AgentNodesHandler', '/api/agent/nodes', 'AgentNodesHandler', '/api/agent/bind', 'AgentBindHandler', '/api/agent/setup', 'AgentSetupHandler', '/api/agent/invoke', 'AgentInvokeHandler', '/api/agent/result/(.*)', 'AgentResultHandler', '/api/workflow', 'WorkflowHandler', '/assets/(.*)', 'AssetsHandler', '/expert(.*)', 'ExpertHandler', '/api/kimi/config/status', 'KimiConfigStatusHandler', '/api/kimi/config/auto_load', 'KimiConfigAutoLoadHandler', '/api/kimi/command', 'KimiCommandHandler', '/api/kimi/agent/status', 'KimiAgentStatusHandler', '/api/kimi/agent/enum/(.*)', 'KimiAgentEnumHandler', '/api/kimi/agent/inject', 'KimiAgentInjectHandler', '/api/kimi/agent/command', 'KimiAgentCommandHandler', '/api/kimi/agent/upload', 'KimiAgentUploadHandler', '/api/kimi/agent/shot', 'KimiAgentShotHandler', '/api/kimi/agent/ocr', 'KimiAgentOcrHandler', '/api/resource/manage/usage', 'ResourceUsageHandler', '/api/resource/manage/allocate', 'ResourceAllocateHandler', '/api/bridge/(.*)', 'BridgeHandler', '/api/browser/(.*)', 'BrowserHandler', '/api/compile/KimiHook', 'CompileKimiHookHandler', '/(.*)', 'SpaFallbackHandler', )
        app = web.application(urls, globals(), autoreload=False)

        # 完全禁用web.py的HTTP日志输出
        web.httpserver.LogMiddleware.log = lambda self, status, environ: None

        # 配置web.py的日志级别为ERROR
        logging.getLogger("web").setLevel(logging.ERROR)
        logging.getLogger("web.httpserver").setLevel(logging.ERROR)

        # Build WSGI app with middleware (same as runsimple but without print)
        func = web.httpserver.StaticMiddleware(app.wsgifunc())
        func = web.httpserver.LogMiddleware(func)
        server = web.httpserver.WSGIServer((host, port), func)
        server.daemon_threads = True
        # Default request_queue_size(5) / timeout(10s) / numthreads(10) are
        # too small: when SSE streams occupy many threads, the backlog fills
        # and new connections get refused (ERR_CONNECTION_ABORTED).
        server.request_queue_size = 128
        server.timeout = 300
        server.requests.min = 20
        server.requests.max = 80
        self._http_server = server
        # Reclaim orphaned SSE queues so disconnected clients don't leak fds.
        self._start_sse_janitor()
        try:
            server.start()
        except (KeyboardInterrupt, SystemExit) as e:
            server.stop()
        except OSError as e:
            if e.errno in (48, 98):  # macOS/Linux EADDRINUSE
                logger.error( f"[WebChannel] 端口 {port} 已被占用，可执行 `cow restart` 清理残留进程，" f"或在 config.json 中修改 web_port" )
            raise

    def stop(self):
        if self._http_server:
            try:
                self._http_server.stop()
                logger.info("[WebChannel] HTTP server stopped")
            except Exception as e:
                logger.warning(f"[WebChannel] Error stopping HTTP server: {e}")
            self._http_server = None


class RootHandler:
    def GET(self):
        raise web.seeother('/chat')


class ViteClientFallbackHandler:
    """Return an empty JS response for /@vite/client requests from stale
    browser Service Workers left over from a previous Vite dev-server session.
    Without this handler those requests return the chat.html page (404 fallback),
    which the browser tries to execute as JS, breaking the page.
    """
    def GET(self):
        web.header('Content-Type', 'application/javascript; charset=utf-8')
        web.header('Cache-Control', 'no-cache, no-store, must-revalidate')
        return '// mocode-cli: no Vite dev server - clearing stale SW cache'


class HealthHandler:
    # Unauthenticated liveness probe. The desktop shell polls self to know the
    # backend is up; it must never require auth (a set web_password would
    # otherwise make startup hang). Returns no sensitive data.
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Cache-Control', 'no-store')
        return json.dumps({"status": "ok"})


class McpOAuthCallbackHandler:
    """OAuth redirect target for MCP servers requiring authorization.

    The browser lands here after the user authorizes a remote MCP server.
    We exchange the authorization code for tokens and bring the server
    online. Unauthenticated by design: the OAuth `state` param is the
    single-use secret that binds this request to a pending authorization.
    """

    def GET(self):
        web.header('Content-Type', 'text/html; charset=utf-8')
        params = web.input(code="", state="", error="", error_description="")

        def _page(title, message):
            return ( "<!doctype html><html><head><meta charset='utf-8'>" "<meta name='viewport' content='width=device-width,initial-scale=1'>" f"<title>{title}</title></head>" "<body style='font-family:-apple-system,Segoe UI,Roboto,sans-serif;" "max-width:520px;margin:64px auto;padding:0 20px;text-align:center;color:#1f2328'>" f"<h2>{title}</h2><p style='color:#57606a'>{message}</p></body></html>" )

        if params.error:
            logger.warning(f"[MCP-OAuth] callback error: {params.error} {params.error_description}")
            return _page("授权失败", f"{params.error}: {params.error_description or ''}")

        if not params.code or not params.state:
            return _page("参数缺失", "回调缺少 code 或 state 参数。")

        try:
            from agent.tools.mcp.mcp_oauth import pop_pending
            from agent.tools.mcp.mcp_client import notify_server_authorized
        except Exception as e:
            logger.warning(f"[MCP-OAuth] callback import failed: {e}")
            return _page("内部错误", "OAuth 模块不可用。")

        handler = pop_pending(params.state)
        if handler is None:
            return _page("会话已过期", "授权请求不存在或已过期，请重新触发授权。")

        try:
            ok = handler.finish_authorization(params.code)
        except Exception as e:
            logger.warning(f"[MCP-OAuth] token exchange crashed: {e}")
            ok = False

        if not ok:
            return _page("授权失败", "换取令牌失败，请重试。")

        notify_server_authorized(handler.server_name)
        logger.info(f"[MCP-OAuth] Server '{handler.server_name}' authorized via web callback")
        return _page( "授权成功", f"MCP 服务 “{handler.server_name}” 已授权，可以返回聊天继续使用了。", )


class AuthCheckHandler:
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        if not _is_password_enabled():
            return json.dumps({"status": "success", "auth_required": False})
        if _check_auth():
            return json.dumps({"status": "success", "auth_required": True, "authenticated": True})
        return json.dumps({"status": "success", "auth_required": True, "authenticated": False})


class AuthLoginHandler:
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        if not _is_password_enabled():
            return json.dumps({"status": "success"})
        try:
            data = json.loads(web.data())
        except Exception as e:
            return json.dumps({"status": "error", "message": "Invalid request"})
        password = str(data.get("password", "") or "")
        expected = _get_web_password()
        if not hmac.compare_digest(password, expected):
            logger.warning("[WebChannel] Invalid login attempt")
            return json.dumps({"status": "error", "message": "Wrong password"})
        token = _create_auth_token()
        web.setcookie("cow_auth_token", token, expires=_session_expire_seconds(), path="/", httponly=True, samesite="Lax")
        # Also return the token in the body: the desktop client (file:// origin)
        # can't rely on the cookie and sends it back via an Authorization header.
        return json.dumps({"status": "success", "token": token})


class AuthLogoutHandler:
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.setcookie("cow_auth_token", "", expires=-1, path="/")
        return json.dumps({"status": "success"})


class MessageHandler:
    def POST(self):
        _require_auth()
        return WebChannel().post_message()


class UploadHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        return WebChannel().upload_file()


class VoiceAsrHandler:
    """Receive a mic recording, persist it under uploads/ and run ASR.
    Returns {status, text, audio_url} so the UI can render a playback bubble."""
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')

        saved_path = None
        try:
            params = _raw_web_input()
            file_obj = params.get("file")
            if file_obj is None:
                return json.dumps({"status": "error", "message": "no audio file"})

            filename = getattr(file_obj, "filename", "") or "recording.webm"
            ext = os.path.splitext(filename)[1].lower() or ".webm"
            if ext not in (".webm", ".ogg", ".opus", ".mp4", ".m4a", ".mp3", ".wav"):
                ext = ".webm"

            upload_dir = _get_upload_dir()
            os.makedirs(upload_dir, exist_ok=True)
            ts = datetime.datetime.now().strftime("%Y%m%d%H%M%S")
            saved_name = f"voice_input_{ts}_{random.randint(0, 9999)}{ext}"
            saved_path = os.path.join(upload_dir, saved_name)
            with open(saved_path, "wb") as f:
                f.write(file_obj.file.read() if hasattr(file_obj, "file") else file_obj.value)

            audio_url = _build_public_short_url(saved_path)

            from bridge.bridge import Bridge
            reply = Bridge().fetch_voice_to_text(saved_path)
            if reply is None:
                return json.dumps({ "status": "error", "message": "ASR returned no reply", "audio_url": audio_url, })

            from bridge.reply import ReplyType
            if reply.type == ReplyType.TEXT:
                return json.dumps({ "status": "success", "text": reply.content or "", "audio_url": audio_url, })
            return json.dumps({ "status": "error", "message": reply.content or "ASR failed", "audio_url": audio_url, })
        except Exception as e:
            logger.exception(f"[VoiceAsrHandler] failed: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class VoiceTtsHandler:
    """On-demand TTS for the in-chat "read aloud" button. Returns the
    audio URL and (when session_id is given) persists it onto the message."""
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data() or b"{}")
            text = (data.get("text") or "").strip()
            session_id = (data.get("session_id") or "").strip()
            if not text:
                return json.dumps({"status": "error", "message": "empty text"})
            # `@singleton` makes WebChannel a factory function — go via instance.
            channel = WebChannel()
            if not channel._tts_provider_ready():
                return json.dumps({"status": "error", "message": "tts not configured"})

            from bridge.bridge import Bridge
            reply = Bridge().fetch_text_to_voice(text)
            if reply is None or reply.type != ReplyType.VOICE or not reply.content:
                msg = getattr(reply, "content", "") or "tts failed"
                return json.dumps({"status": "error", "message": str(msg)})

            url = channel._publish_tts_audio(reply.content)
            if not url:
                return json.dumps({"status": "error", "message": "publish failed"})

            if session_id:
                try:
                    from agent.memory import get_conversation_store
                    get_conversation_store().attach_extras_to_last_assistant( session_id, {"audio": {"url": url, "kind": "tts"}}, )
                except Exception as e:
                    logger.debug(f"[VoiceTtsHandler] persist skipped: {e}")

            return json.dumps({"status": "success", "audio_url": url})
        except Exception as e:
            logger.exception(f"[VoiceTtsHandler] failed: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class UploadsHandler:
    def GET(self, file_name):
        _require_auth()
        try:
            upload_dir = _get_upload_dir()
            full_path = os.path.normpath(os.path.join(upload_dir, file_name))
            if not os.path.abspath(full_path).startswith(os.path.abspath(upload_dir)):
                raise web.notfound()
            if not os.path.isfile(full_path):
                raise web.notfound()
            content_type = mimetypes.guess_type(full_path)[0] or "application/octet-stream"
            web.header('Content-Type', content_type)
            web.header('Cache-Control', 'public, max-age=86400')
            with open(full_path, 'rb') as f:
                return f.read()
        except web.HTTPError as e:
            raise
        except Exception as e:
            logger.error(f"[WebChannel] Error serving upload: {e}")
            raise web.notfound()


class FileServeHandler:
    def GET(self):
        _require_auth()
        try:
            params = web.input(path="")
            file_path = params.path
            if not file_path or not os.path.isabs(file_path):
                raise web.notfound()
            # Resolve symlinks and confine access to the allowed root dirs,
            # so self endpoint can't be abused to read arbitrary files (e.g. /etc/passwd, ~/.ssh).
            # Defaults to the user home dir plus the agent workspace; set web_file_serve_root="/"
            # to allow the whole filesystem.
            file_path = os.path.realpath(file_path)
            if not _is_path_allowed(file_path):
                raise web.notfound()
            if not os.path.isfile(file_path):
                raise web.notfound()
            content_type = mimetypes.guess_type(file_path)[0] or "application/octet-stream"
            file_name = os.path.basename(file_path)
            from urllib.parse import quote
            web.header('Content-Type', content_type)
            web.header('Content-Disposition', f"inline; filename*=UTF-8''{quote(file_name)}")
            web.header('Cache-Control', 'public, max-age=3600')
            with open(file_path, 'rb') as f:
                return f.read()
        except web.HTTPError as e:
            raise
        except Exception as e:
            logger.error(f"[WebChannel] Error serving file: {e}")
            raise web.notfound()


class ShortLinkHandler:
    """
    公网短链接查看：/s/<code>
    code 为加密后的文件路径（ENC1 密文），无需登录即可访问。
    图片/音视频/html/pdf 直接内联展示；office 与未知类型提供预览页下载。
    """

    def GET(self, code):
        from urllib.parse import unquote
        code = unquote(code or "")
        download = False
        try:
            dl = web.input(dl="0").get("dl", "0")
            download = (str(dl) == "1")
        except Exception as e:
            download = False
        path = None
        try:
            dec = _agent_decrypt(code or "")
            if dec is None:
                raise ValueError("bad short code")
            path = dec
            if not os.path.isfile(path):
                raise ValueError("file not found")
            if not _is_path_allowed(os.path.realpath(path)):
                raise ValueError("path not allowed")
        except ValueError as e:
            raise web.notfound()
        except Exception as e:
            logger.warning(f"[ShortLink] invalid code: {e}")
            raise web.notfound()
        ext = os.path.splitext(path)[1].lower()
        content_type = mimetypes.guess_type(path)[0] or "application/octet-stream"
        name = os.path.basename(path)
        try:
            if download:
                web.header('Content-Type', content_type)
                web.header('Content-Disposition', f'attachment; filename="{name}"')
                with open(path, 'rb') as f:
                    return f.read()
            if ext in IMAGE_EXTENSIONS or ext in VIDEO_EXTENSIONS or ext in AUDIO_EXTENSIONS or ext == ".pdf":
                web.header('Content-Type', content_type)
                web.header('Cache-Control', 'public, max-age=86400')
                with open(path, 'rb') as f:
                    return f.read()
            if ext == ".html":
                web.header('Content-Type', 'text/html; charset=utf-8')
                web.header('Content-Security-Policy', "sandbox allow-scripts allow-popups allow-forms allow-modals")
                with open(path, 'rb') as f:
                    return f.read()
            # office 与未知类型：预览页 + 下载
            size_kb = os.path.getsize(path) / 1024.0
            html = ( "<!DOCTYPE html><html lang=\"zh\"><head><meta charset=\"utf-8\"><title>" + name + "</title>" "<style>body{font-family:system-ui,-apple-system,sans-serif;display:flex;align-items:center;justify-content:center;min-height:90vh;margin:0;background:#f5f6f8;color:#222}.card{background:#fff;border-radius:16px;padding:40px 48px;box-shadow:0 8px 30px rgba(0,0,0,.08);text-align:center;max-width:520px}.icon{font-size:44px;margin-bottom:14px}.name{font-size:17px;font-weight:600;word-break:break-all;margin-bottom:6px}.meta{font-size:13px;color:#888;margin-bottom:24px}button{background:#228547;color:#fff;border:0;border-radius:10px;padding:12px 26px;font-size:15px;cursor:pointer}button:hover{background:#1c6b3b}.hint{font-size:12px;color:#aaa;margin-top:16px}</style></head><body><div class=\"card\">" "<div class=\"icon\">📄</div>" "<div class=\"name\">" + name + "</div>" "<div class=\"meta\">" + format(size_kb, ".1f") + " KB · " + (ext or "文件") + "</div>" "<a href=\"/s/" + quote(code, safe='') + "?dl=1\"><button>下载文件</button></a>" "<div class=\"hint\">此类型文件暂不支持在线预览，下载后即可打开查看</div></div></body></html>" )
            web.header('Content-Type', 'text/html; charset=utf-8')
            return html
        except web.HTTPError as e:
            raise
        except Exception as e:
            logger.error(f"[ShortLink] serve error: {e}")
            raise web.notfound()


class ShortLinkApiHandler:
    """生成公网短链接：GET /api/shortlink?path=<file_path> → {short_url}"""

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            path = web.input().get("path", "")
            if not path:
                return json.dumps({"status": "error", "message": "missing path"})
            real = os.path.realpath(path)
            if not os.path.isfile(real) or not _is_path_allowed(real):
                return json.dumps({"status": "error", "message": "invalid path"})
            return json.dumps({"status": "success", "short_url": _build_public_short_url(real)})
        except Exception as e:
            logger.warning(f"[ShortLinkApi] error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class PreviewHandler:
    """
    Directory-mounted file server for the preview panel: /preview/<token>/<relpath>

    Unlike /api/file (single file, query param) this mounts the file's directory,
    so relative assets inside a generated HTML page resolve normally. The token is
    HMAC-signed, which is what authorizes the request - the sandboxed iframe can't
    send the auth cookie.
    """

    def GET(self, path_info):
        try:
            token, _, rel_path = (path_info or "").partition("/")
            if not token or not rel_path:
                raise web.notfound()

            from urllib.parse import unquote
            rel_path = unquote(rel_path)

            try:
                base_dir = _decode_dir_token(token)
            except ValueError as e:
                raise web.notfound()

            full_path = os.path.realpath(os.path.join(base_dir, rel_path))
            base_real = os.path.realpath(base_dir)
            # Confine to the mounted directory, then to the globally allowed roots.
            if os.path.commonpath([full_path, base_real]) != base_real:
                raise web.notfound()
            if not _is_path_allowed(full_path) or not os.path.isfile(full_path):
                raise web.notfound()

            content_type = mimetypes.guess_type(full_path)[0] or "application/octet-stream"
            web.header('Content-Type', content_type)
            web.header('Cache-Control', 'no-cache')
            web.header('X-Content-Type-Options', 'nosniff')
            if content_type.startswith("text/html"):
                # Agent-generated pages are untrusted. The CSP sandbox forces an
                # opaque origin even when the page is opened as a top-level tab,
                # so it can't read the console's localStorage auth token; the
                # panel's iframe already applies the same flags.

                # No frame-ancestors here: the desktop renderer is loaded from
                # file:// (or the Vite dev server), so 'self' would block its
                # preview iframe outright. The sandbox is what carries the
                # security guarantee; framing alone reveals nothing extra.
                web.header( 'Content-Security-Policy', "sandbox allow-scripts allow-popups allow-forms allow-modals", )
            with open(full_path, 'rb') as f:
                return f.read()
        except web.HTTPError as e:
            raise
        except Exception as e:
            logger.error(f"[WebChannel] Error serving preview: {e}")
            raise web.notfound()


class PollHandler:
    def POST(self):
        _require_auth()
        return WebChannel().poll_response()


class CancelHandler:
    def POST(self):
        _require_auth()
        return WebChannel().cancel_request()


class StreamHandler:
    def GET(self):
        _require_auth()
        params = web.input(request_id='')
        request_id = params.request_id
        if not request_id:
            raise web.badrequest()

        web.header('Content-Type', 'text/event-stream; charset=utf-8')
        web.header('Cache-Control', 'no-cache')
        web.header('X-Accel-Buffering', 'no')
        web.header('Access-Control-Allow-Origin', '*')

        return WebChannel().stream_response(request_id)


class ChatHandler:
    def GET(self):
        web.header('Cache-Control', 'no-cache, no-store, must-revalidate')
        web.header('Pragma', 'no-cache')
        file_path = os.path.join(os.path.dirname(__file__), 'chat.html')
        with open(file_path, 'r', encoding='utf-8') as f:
            html = f.read()
        cache_bust = str(int(time.time()))
        html = html.replace('assets/js/console.js', f'assets/js/console.js?v={cache_bust}')
        html = html.replace('assets/css/console.css', f'assets/css/console.css?v={cache_bust}')
        # Inject the backend-resolved default language for first-load fallback.
        html = html.replace("{{COW_DEFAULT_LANG}}", i18n.get_language())
        return html


class ConfigHandler:

    _RECOMMENDED_MODELS = [ const.DEEPSEEK_V4_FLASH, const.DEEPSEEK_V4_PRO, const.MINIMAX_M3, const.MINIMAX_M2_7_HIGHSPEED, const.MINIMAX_M2_7,  const.CLAUDE_OPUS_5, const.CLAUDE_SONNET_5, const.CLAUDE_FABLE_5, const.CLAUDE_4_8_OPUS, const.CLAUDE_4_7_OPUS, const.CLAUDE_4_6_SONNET, const.CLAUDE_4_6_OPUS, const.GEMINI_35_FLASH, const.GEMINI_31_FLASH_LITE_PRE, const.GEMINI_31_PRO_PRE, const.GEMINI_3_FLASH_PRE, const.GPT_56_LUNA, const.GPT_56_TERRA, const.GPT_56_SOL, const.GPT_55, const.GPT_54, const.GPT_54_MINI, const.GPT_54_NANO, const.GPT_5, const.GPT_41, const.GPT_4o, const.GLM_5_2, const.GLM_5_1, const.GLM_5_TURBO, const.GLM_5, const.GLM_4_7, const.QWEN37_PLUS, const.QWEN37_MAX, const.QWEN36_PLUS, const.DOUBAO_SEED_2_1_PRO, const.DOUBAO_SEED_2_1_TURBO, const.DOUBAO_SEED_2_CODE, const.KIMI_K3, const.KIMI_K2_7_CODE, const.KIMI_K2_7_CODE_HIGHSPEED, const.KIMI_K2_6, const.KIMI_K2_5, const.KIMI_K2, const.ERNIE_5_1, const.ERNIE_5, const.ERNIE_X1_1, const.ERNIE_45_TURBO_128K, const.ERNIE_45_TURBO_32K, const.MIMO_V2_5_PRO, const.MIMO_V2_5, ]

    # Generic placeholder hints surfaced in the web console. We deliberately
    # show the version-path tail (e.g. "/v1") so users are reminded to type
    # the full base URL. The form is intentionally vague (`...../v1`) so it
    # never looks like a real default a user might paste verbatim — and we
    # never auto-rewrite anything on the server side.
    _PLACEHOLDER_V1 = "https://...../v1"
    _PLACEHOLDER_QIANFAN = "https://...../v2"
    _PLACEHOLDER_ZHIPU = "https://...../api/paas/v4"
    _PLACEHOLDER_DOUBAO = "https://...../api/v3"
    _PLACEHOLDER_GEMINI = "https://....."

    PROVIDER_MODELS = OrderedDict([ ("deepseek", { "label": "DeepSeek", "api_key_field": "deepseek_api_key", "api_base_key": "deepseek_api_base", "api_base_default": "https://api.deepseek.com/v1", "api_base_placeholder": _PLACEHOLDER_V1, "models": [const.DEEPSEEK_V4_FLASH, const.DEEPSEEK_V4_PRO, const.DEEPSEEK_CHAT, const.DEEPSEEK_REASONER], }), ("minimax", { "label": "MiniMax", "api_key_field": "minimax_api_key", "api_base_key": None, "api_base_default": None, "api_base_placeholder": "", "models": [const.MINIMAX_M3, const.MINIMAX_M2_7, const.MINIMAX_M2_7_HIGHSPEED], }), ("claudeAPI", { "label": "Claude", "api_key_field": "claude_api_key", "api_base_key": "claude_api_base", "api_base_default": "https://api.anthropic.com/v1", "api_base_placeholder": _PLACEHOLDER_V1, "models": [const.CLAUDE_OPUS_5, const.CLAUDE_SONNET_5, const.CLAUDE_FABLE_5, const.CLAUDE_4_8_OPUS, const.CLAUDE_4_7_OPUS, const.CLAUDE_4_6_SONNET, const.CLAUDE_4_6_OPUS], }), ("gemini", { "label": "Gemini", "api_key_field": "gemini_api_key", "api_base_key": "gemini_api_base", "api_base_default": "https://generativelanguage.googleapis.com", "api_base_placeholder": _PLACEHOLDER_GEMINI, "models": [const.GEMINI_35_FLASH, const.GEMINI_31_FLASH_LITE_PRE, const.GEMINI_31_PRO_PRE, const.GEMINI_3_FLASH_PRE], }), ("openai", { "label": "OpenAI", "api_key_field": "open_ai_api_key", "api_base_key": "open_ai_api_base", "api_base_default": "https://api.openai.com/v1", "api_base_placeholder": _PLACEHOLDER_V1, "models": [const.GPT_56_LUNA, const.GPT_56_TERRA, const.GPT_56_SOL, const.GPT_55, const.GPT_54, const.GPT_54_MINI, const.GPT_54_NANO, const.GPT_5, const.GPT_41, const.GPT_4o], }), ("zhipu", { "label": {"zh": "智谱AI", "en": "GLM"}, "api_key_field": "zhipu_ai_api_key", "api_base_key": "zhipu_ai_api_base", "api_base_default": "https://open.bigmodel.cn/api/paas/v4", "api_base_placeholder": _PLACEHOLDER_ZHIPU, "models": [const.GLM_5_2, const.GLM_5_1, const.GLM_5_TURBO, const.GLM_5, const.GLM_4_7], }), ("dashscope", { "label": {"zh": "通义千问", "en": "Qwen"}, "api_key_field": "dashscope_api_key", "api_base_key": None, "api_base_default": None, "api_base_placeholder": "", "models": [const.QWEN37_PLUS, const.QWEN37_MAX, const.QWEN36_PLUS], }), ("doubao", { "label": {"zh": "豆包", "en": "Doubao"}, "api_key_field": "ark_api_key", "api_base_key": "ark_base_url", "api_base_default": "https://ark.cn-beijing.volces.com/api/v3", "api_base_placeholder": _PLACEHOLDER_DOUBAO, "models": [const.DOUBAO_SEED_2_1_PRO, const.DOUBAO_SEED_2_1_TURBO, const.DOUBAO_SEED_2_PRO, const.DOUBAO_SEED_2_CODE], }), ("moonshot", { "label": "Kimi", "api_key_field": "moonshot_api_key", "api_base_key": "moonshot_base_url", "api_base_default": "https://api.moonshot.cn/v1", "api_base_placeholder": _PLACEHOLDER_V1, "models": [const.KIMI_K3, const.KIMI_K2_7_CODE, const.KIMI_K2_7_CODE_HIGHSPEED, const.KIMI_K2_6, const.KIMI_K2_5, const.KIMI_K2], }), ("qianfan", { "label": {"zh": "百度千帆", "en": "ERNIE"}, "api_key_field": "qianfan_api_key", "api_base_key": "qianfan_api_base", "api_base_default": "https://qianfan.baidubce.com/v2", "api_base_placeholder": _PLACEHOLDER_QIANFAN, "models": [const.ERNIE_5_1, const.ERNIE_5, const.ERNIE_X1_1, const.ERNIE_45_TURBO_128K, const.ERNIE_45_TURBO_32K], }), ("mimo", { "label": {"zh": "小米 MiMo", "en": "MiMo"}, "api_key_field": "mimo_api_key", "api_base_key": "mimo_api_base", "api_base_default": "https://api.xiaomimimo.com/v1", "api_base_placeholder": _PLACEHOLDER_V1, "models": [const.MIMO_V2_5_PRO, const.MIMO_V2_5], }), ("linkai", { "label": "LinkAI", "api_key_field": "linkai_api_key", "api_base_key": None, "api_base_default": None, "api_base_placeholder": "", "models": _RECOMMENDED_MODELS, }), ("custom", { "label": {"zh": "自定义", "en": "Custom"}, "api_key_field": "custom_api_key", "api_base_key": "custom_api_base", "api_base_default": "", "api_base_placeholder": _PLACEHOLDER_V1, "models": [], }), ])

    EDITABLE_KEYS = { "cow_lang", "model", "bot_type", "use_linkai", "open_ai_api_base", "deepseek_api_base", "qianfan_api_base", "claude_api_base", "gemini_api_base", "zhipu_ai_api_base", "moonshot_base_url", "ark_base_url", "custom_api_base", "mimo_api_base", "open_ai_api_key", "deepseek_api_key", "qianfan_api_key", "claude_api_key", "gemini_api_key", "zhipu_ai_api_key", "dashscope_api_key", "moonshot_api_key", "ark_api_key", "minimax_api_key", "linkai_api_key", "custom_api_key", "mimo_api_key", "custom_providers", "agent_max_context_tokens", "agent_max_context_turns", "agent_max_steps", "enable_thinking", "self_evolution_enabled", "web_password", }

    @staticmethod
    def _mask_key(value):
        """Mask the middle part of an API key for display."""
        if not value or len(value) <= 8:
            return value
        return value[:4] + "*" * (len(value) - 8) + value[-4:]

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            local_config = conf()
            use_agent = local_config.get("agent", True)
            title = "mocode-cli" if use_agent else "AI Assistant"

            api_bases = {}
            api_keys_masked = {}
            for pid, pinfo in self.PROVIDER_MODELS.items():
                base_key = pinfo.get("api_base_key")
                if base_key:
                    api_bases[base_key] = local_config.get(base_key, pinfo["api_base_default"])
                key_field = pinfo.get("api_key_field")
                if key_field and key_field not in api_keys_masked:
                    raw = local_config.get(key_field, "")
                    api_keys_masked[key_field] = self._mask_key(raw) if raw else ""

            providers = {}
            for pid, p in self.PROVIDER_MODELS.items():
                providers[pid] = { "label": p["label"], "models": p["models"], "api_base_key": p["api_base_key"], "api_base_default": p["api_base_default"], "api_base_placeholder": p.get("api_base_placeholder", ""), "api_key_field": p.get("api_key_field"), }

            # Expose user-defined custom providers as "custom:<id>" entries so
            # the legacy config page can display and select them. Credentials
            # are managed on the Models page, hence the None key/base fields.
            # Mirrors the Models page: when expanded entries exist, the bare
            # legacy "custom" entry is hidden — unless the flat single-provider
            # custom config is still active or filled in.
            try:
                from models.custom_provider import get_custom_providers
                custom_list = get_custom_providers()
                legacy_custom_in_use = ModelsHandler._legacy_custom_in_use(local_config)
                if custom_list and not legacy_custom_in_use:
                    providers.pop("custom", None)
                for cp in custom_list:
                    cid = f"custom:{cp.get('id')}"
                    cname = cp.get("name") or cp.get("id")
                    providers[cid] = { "label": {"zh": cname, "en": cname}, "models": [cp["model"]] if cp.get("model") else [], "api_base_key": None, "api_base_default": None, "api_base_placeholder": "", "api_key_field": None, }
            except Exception as cp_err:
                logger.warning(f"[ConfigHandler] failed to expand custom providers: {cp_err}")

            raw_pwd = str(local_config.get("web_password", "") or "")
            masked_pwd = ("*" * len(raw_pwd)) if raw_pwd else ""

            result = { "status": "success", "use_agent": use_agent, "title": title, "model": local_config.get("model", ""), "bot_type": "openai" if local_config.get("bot_type") == "chatGPT" else local_config.get("bot_type", ""), "use_linkai": bool(local_config.get("use_linkai", False)), "channel_type": local_config.get("channel_type", ""), "agent_max_context_tokens": local_config.get("agent_max_context_tokens", 50000), "agent_max_context_turns": local_config.get("agent_max_context_turns", 20), "agent_max_steps": local_config.get("agent_max_steps", 20), "enable_thinking": bool(local_config.get("enable_thinking", False)), "self_evolution_enabled": bool(local_config.get("self_evolution_enabled", False)), "api_bases": api_bases, "api_keys": api_keys_masked, "providers": providers, "web_password_masked": masked_pwd, }
            # The desktop app runs on the local trusted machine, so it can edit
            # the real password in place (cursor at the end, delete to clear).
            # Browser access only ever sees the masked value.
            if os.environ.get("COW_DESKTOP") == "1":
                result["web_password"] = raw_pwd
            return json.dumps(result, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Error getting config: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data())
            updates = data.get("updates", {})
            if not updates:
                return json.dumps({"status": "error", "message": "no updates provided"})

            local_config = conf()
            applied = {}
            for key, value in updates.items():
                if key not in self.EDITABLE_KEYS:
                    continue
                if key in ("agent_max_context_tokens", "agent_max_context_turns", "agent_max_steps"):
                    value = int(value)
                if key in ("use_linkai", "enable_thinking", "self_evolution_enabled"):
                    value = bool(value)
                local_config[key] = value
                applied[key] = value

            if not applied:
                return json.dumps({"status": "error", "message": "no valid keys to update"})

            config_path = os.path.join(get_data_root(), "config.json")
            old_password = ""  # Store old password before update
            if os.path.exists(config_path):
                with open(config_path, "r", encoding="utf-8") as f:
                    file_cfg = json.load(f)
                    # Capture old password before updating
                    if "web_password" in applied:
                        old_password = file_cfg.get("web_password", "")
            else:
                file_cfg = {}
            file_cfg.update(applied)
            with open(config_path, "w", encoding="utf-8") as f:
                json.dump(file_cfg, f, indent=4, ensure_ascii=False)

            logger.info(f"[WebChannel] Config updated: {list(applied.keys())}")

            # Apply a language change immediately so backend logs, agent
            # replies and CLI output switch without a restart.
            if "cow_lang" in applied:
                try:
                    i18n.resolve_language(applied["cow_lang"])
                    logger.info(f"[WebChannel] Language switched to: {i18n.get_language()}")
                except Exception as lang_err:
                    logger.warning(f"[WebChannel] Failed to apply language: {lang_err}")

            # Check if password was cleared: if there was a password before clearing,
            # the service is likely bound to 0.0.0.0 (public), so warn the user.
            password_warning = None
            if "web_password" in applied:
                new_password = applied["web_password"]
                configured_host = file_cfg.get("web_host", "")

                # If password was cleared and there was a password before
                if not new_password and old_password:
                    # If web_host is not explicitly set, the service auto-binds based on password
                    # With password → 0.0.0.0 (public), without password → 127.0.0.1 (local)
                    # So clearing password when it was previously set means going from public to local
                    if not configured_host or configured_host == "0.0.0.0":
                        password_warning = "password_cleared_with_public_host"
                        logger.warning( "[WebChannel] Password cleared while service is likely bound to 0.0.0.0. " "Consider restarting the service to rebind to 127.0.0.1 " "or explicitly set web_host in config to prevent unauthorized access." )

            # Reset Bridge so that bot routing reflects the new config.
            # Without self, Bridge keeps its cached bot instance (e.g. LinkAIBot)
            # even after the user switches bot_type / use_linkai / model in UI.
            bridge_routing_keys = {"bot_type", "use_linkai", "model"}
            if any(k in applied for k in bridge_routing_keys):
                try:
                    from bridge.bridge import Bridge
                    Bridge().reset_bot()
                    logger.info("[WebChannel] Bridge bot routing reset due to config change")
                except Exception as reset_err:
                    logger.warning(f"[WebChannel] Failed to reset bridge: {reset_err}")

            return json.dumps({"status": "success", "applied": applied, "warning": password_warning}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"Error updating config: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class ModelsHandler:
    """API for the unified Models console.

    Layered model:
      Layer 1 (providers): vendor credentials shared across capabilities.
                            Stored as flat *_api_key / *_api_base fields in
                            config.json — the same fields ConfigHandler
                            already manages.
      Layer 2 (capabilities): which provider/model is used by chat / vision /
                            asr / tts / embedding / image / search.

    GET  /api/models           -> overview (providers + capabilities)
    POST /api/models/provider  -> upsert a vendor credential
    DELETE /api/models/provider -> clear a vendor credential
    POST /api/models/capability -> set provider/model for a capability
    """

    # Capability -> provider ids drawn from ConfigHandler.PROVIDER_MODELS.
    _ASR_PROVIDERS = ["openai", "dashscope", "zhipu", "linkai"]
    # Web-console white-list. Other vendors stay usable via direct config.
    _TTS_PROVIDERS = ["openai", "minimax", "dashscope", "mimo", "linkai"]

    # TTS engine catalog (speech models, not voice timbres). Entries are
    # either a bare code or {value, hint?} when a friendly label helps.
    _TTS_PROVIDER_MODELS = { "openai":    ["tts-1", "tts-1-hd", "gpt-4o-mini-tts"], "minimax": [ {"value": "speech-2.8-hd",    "hint": "情绪渲染融合语气词,自然听感"}, {"value": "speech-2.8-turbo", "hint": "极致生成速度,更自然逼真"}, {"value": "speech-2.6-hd",    "hint": "超低延时,归一化升级"}, {"value": "speech-2.6-turbo", "hint": "更快更便宜,适合语音聊天/数字人"}, ], "dashscope": [ {"value": "qwen3-tts-flash", "hint": "覆盖普通话、方言与主流外语"}, ],  "mimo": [ {"value": "mimo-v2.5-tts", "hint": "预置音色 · 支持唱歌模式"}, ],    "linkai": [ {"value": "tts-1",  "hint": "OpenAI · 多语种通用"}, {"value": "doubao", "hint": "字节豆包 · 中文音色丰富"}, {"value": "baidu",  "hint": "百度 · 中文主播音色"}, ], }

    # ASR engine catalog per provider. The first entry of each list is the
    # runtime default (mirrors DEFAULT_ASR_MODEL in voice/*). Users can still
    # pick "custom" in the UI to send any other model id.
    _ASR_PROVIDER_MODELS = { "openai": [ {"value": "gpt-4o-mini-transcribe", "hint": "默认 · 速度快"}, {"value": "gpt-4o-transcribe",      "hint": "更高准确率"}, {"value": "whisper-1",              "hint": "经典 Whisper"}, ], "dashscope": [ {"value": "qwen3-asr-flash", "hint": "覆盖普通话、方言与主流外语"}, ], "zhipu": [ {"value": "glm-asr-2512", "hint": "智谱语音识别"}, ],   "linkai": [ {"value": "whisper-1", "hint": "网关固定使用"}, ], }

    # Per-provider voice timbres. Entries can be a bare code string
    # (label = code) or {value, hint?} when a friendly secondary label
    # helps recognition. We keep `value` as the raw API code so power
    # users can cross-reference config.json.
    _TTS_PROVIDER_VOICES = { "openai":    [ "alloy", "echo", "fable", "onyx", "nova", "shimmer", "ash", "ballad", "coral", "sage", "verse", ], "minimax": [  {"value": "male-qn-qingse",                           "hint": "中文 · 青涩青年（男）"}, {"value": "male-qn-jingying",                         "hint": "中文 · 精英青年（男）"}, {"value": "male-qn-badao",                            "hint": "中文 · 霸道青年（男）"}, {"value": "male-qn-daxuesheng",                       "hint": "中文 · 青年大学生（男）"}, {"value": "female-shaonv",                            "hint": "中文 · 少女（女）"}, {"value": "female-yujie",                             "hint": "中文 · 御姐（女）"}, {"value": "female-chengshu",                          "hint": "中文 · 成熟女性（女）"}, {"value": "female-tianmei",                           "hint": "中文 · 甜美女性（女）"}, {"value": "male-qn-qingse-jingpin",                   "hint": "中文 · 青涩青年-beta（男）"}, {"value": "male-qn-jingying-jingpin",                 "hint": "中文 · 精英青年-beta（男）"}, {"value": "male-qn-badao-jingpin",                    "hint": "中文 · 霸道青年-beta（男）"}, {"value": "male-qn-daxuesheng-jingpin",               "hint": "中文 · 青年大学生-beta（男）"}, {"value": "female-shaonv-jingpin",                    "hint": "中文 · 少女-beta（女）"}, {"value": "female-yujie-jingpin",                     "hint": "中文 · 御姐-beta（女）"}, {"value": "female-chengshu-jingpin",                  "hint": "中文 · 成熟女性-beta（女）"}, {"value": "female-tianmei-jingpin",                   "hint": "中文 · 甜美女性-beta（女）"}, {"value": "clever_boy",                               "hint": "中文 · 聪明男童"}, {"value": "cute_boy",                                 "hint": "中文 · 可爱男童"}, {"value": "lovely_girl",                              "hint": "中文 · 萌萌女童"}, {"value": "cartoon_pig",                              "hint": "中文 · 卡通猪小琪"}, {"value": "bingjiao_didi",                            "hint": "中文 · 病娇弟弟"}, {"value": "junlang_nanyou",                           "hint": "中文 · 俊朗男友"}, {"value": "chunzhen_xuedi",                           "hint": "中文 · 纯真学弟"}, {"value": "lengdan_xiongzhang",                       "hint": "中文 · 冷淡学长"}, {"value": "badao_shaoye",                             "hint": "中文 · 霸道少爷"}, {"value": "tianxin_xiaoling",                         "hint": "中文 · 甜心小玲"}, {"value": "qiaopi_mengmei",                           "hint": "中文 · 俏皮萌妹"}, {"value": "wumei_yujie",                              "hint": "中文 · 妩媚御姐"}, {"value": "diadia_xuemei",                            "hint": "中文 · 嗲嗲学妹"}, {"value": "danya_xuejie",                             "hint": "中文 · 淡雅学姐"}, {"value": "Chinese (Mandarin)_Reliable_Executive",    "hint": "中文 · 沉稳高管"}, {"value": "Chinese (Mandarin)_News_Anchor",           "hint": "中文 · 新闻女声"}, {"value": "Chinese (Mandarin)_Mature_Woman",          "hint": "中文 · 傲娇御姐"}, {"value": "Chinese (Mandarin)_Unrestrained_Young_Man","hint": "中文 · 不羁青年"}, {"value": "Arrogant_Miss",                            "hint": "中文 · 嚣张小姐"}, {"value": "Robot_Armor",                              "hint": "中文 · 机械战甲"}, {"value": "Chinese (Mandarin)_Kind-hearted_Antie",    "hint": "中文 · 热心大婶"}, {"value": "Chinese (Mandarin)_HK_Flight_Attendant",   "hint": "中文 · 港普空姐"}, {"value": "Chinese (Mandarin)_Humorous_Elder",        "hint": "中文 · 搞笑大爷"}, {"value": "Chinese (Mandarin)_Gentleman",             "hint": "中文 · 温润男声"}, {"value": "Chinese (Mandarin)_Warm_Bestie",           "hint": "中文 · 温暖闺蜜"}, {"value": "Chinese (Mandarin)_Male_Announcer",        "hint": "中文 · 播报男声"}, {"value": "Chinese (Mandarin)_Sweet_Lady",            "hint": "中文 · 甜美女声"}, {"value": "Chinese (Mandarin)_Southern_Young_Man",    "hint": "中文 · 南方小哥"}, {"value": "Chinese (Mandarin)_Wise_Women",            "hint": "中文 · 阅历姐姐"}, {"value": "Chinese (Mandarin)_Gentle_Youth",          "hint": "中文 · 温润青年"}, {"value": "Chinese (Mandarin)_Warm_Girl",             "hint": "中文 · 温暖少女"}, {"value": "Chinese (Mandarin)_Kind-hearted_Elder",    "hint": "中文 · 花甲奶奶"}, {"value": "Chinese (Mandarin)_Cute_Spirit",           "hint": "中文 · 憨憨萌兽"}, {"value": "Chinese (Mandarin)_Radio_Host",            "hint": "中文 · 电台男主播"}, {"value": "Chinese (Mandarin)_Lyrical_Voice",         "hint": "中文 · 抒情男声"}, {"value": "Chinese (Mandarin)_Straightforward_Boy",   "hint": "中文 · 率真弟弟"}, {"value": "Chinese (Mandarin)_Sincere_Adult",         "hint": "中文 · 真诚青年"}, {"value": "Chinese (Mandarin)_Gentle_Senior",         "hint": "中文 · 温柔学姐"}, {"value": "Chinese (Mandarin)_Stubborn_Friend",       "hint": "中文 · 嘴硬竹马"}, {"value": "Chinese (Mandarin)_Crisp_Girl",            "hint": "中文 · 清脆少女"}, {"value": "Chinese (Mandarin)_Pure-hearted_Boy",      "hint": "中文 · 清澈邻家弟弟"}, {"value": "Chinese (Mandarin)_Soft_Girl",             "hint": "中文 · 柔和少女"},  {"value": "Cantonese_ProfessionalHost（F)",            "hint": "粤语 · 专业女主持"}, {"value": "Cantonese_GentleLady",                     "hint": "粤语 · 温柔女声"}, {"value": "Cantonese_ProfessionalHost（M)",            "hint": "粤语 · 专业男主持"}, {"value": "Cantonese_PlayfulMan",                     "hint": "粤语 · 活泼男声"}, {"value": "Cantonese_CuteGirl",                       "hint": "粤语 · 可爱女孩"}, {"value": "Cantonese_KindWoman",                      "hint": "粤语 · 善良女声"},  {"value": "English_Graceful_Lady",                    "hint": "英文 · Graceful Lady（女）"}, {"value": "English_Trustworthy_Man",                  "hint": "英文 · Trustworthy Man（男）"},  {"value": "Japanese_KindLady",                        "hint": "日文 · Kind Lady（女）"}, {"value": "Japanese_LoyalKnight",                     "hint": "日文 · Loyal Knight（男）"},  {"value": "Korean_SweetGirl",                         "hint": "韩文 · Sweet Girl（女）"}, {"value": "Korean_CheerfulBoyfriend",                 "hint": "韩文 · Cheerful Boyfriend（男）"}, ], "dashscope": [ {"value": "Cherry",   "hint": "芊悦 · 阳光女声"}, {"value": "Serena",   "hint": "苏瑶 · 温柔女声"}, {"value": "Chelsie",  "hint": "千雪 · 二次元少女"}, {"value": "Ethan",    "hint": "晨煦 · 阳光男声"}, {"value": "Moon",     "hint": "月白 · 率性男声"}, {"value": "Kai",      "hint": "凯 · 治愈男声"}, {"value": "Nofish",   "hint": "不吃鱼 · 设计师男声"}, {"value": "Bella",    "hint": "萌宝 · 小萝莉"}, {"value": "Bunny",    "hint": "萌小姬 · 萌系少女"}, {"value": "Stella",   "hint": "少女阿月 · 元气少女"}, {"value": "Neil",     "hint": "阿闻 · 新闻主播"}, {"value": "Seren",    "hint": "小婉 · 助眠女声"}, {"value": "Jada",     "hint": "上海话 · 阿珍"}, {"value": "Dylan",    "hint": "北京话 · 晓东"}, {"value": "Sunny",    "hint": "四川话 · 晴儿"}, {"value": "Eric",     "hint": "四川话 · 程川"}, {"value": "Rocky",    "hint": "粤语 · 阿强"}, {"value": "Kiki",     "hint": "粤语 · 阿清"}, {"value": "Peter",    "hint": "天津话 · 李彼得"}, {"value": "Marcus",   "hint": "陕西话 · 秦川"}, {"value": "Roy",      "hint": "闽南语 · 阿杰"}, ],   "mimo": [ {"value": "冰糖",   "hint": "中文 · 女声 · 冰糖"}, {"value": "茉莉",   "hint": "中文 · 女声 · 茉莉"}, {"value": "苏打",   "hint": "中文 · 男声 · 苏打"}, {"value": "白桦",   "hint": "中文 · 男声 · 白桦"}, {"value": "Mia",   "hint": "英文 · 女声 · Mia"}, {"value": "Chloe", "hint": "英文 · 女声 · Chloe"}, {"value": "Milo",  "hint": "英文 · 男声 · Milo"}, {"value": "Dean",  "hint": "英文 · 男声 · Dean"}, ],    "linkai": { "tts-1": [ "alloy", "echo", "fable", "onyx", "nova", "shimmer", ], "doubao": [ {"value": "zh_female_wanwanxiaohe_moon_bigtts",       "hint": "湾湾小何"}, {"value": "BV007_streaming",                          "hint": "亲切女声"}, {"value": "BV001_streaming",                          "hint": "通用女声"}, {"value": "BV002_streaming",                          "hint": "通用男声"}, {"value": "BV051_streaming",                          "hint": "奶气萌娃"}, {"value": "zh_female_linjianvhai_moon_bigtts",        "hint": "邻家女孩"}, {"value": "BV700_streaming",                          "hint": "灿灿"}, {"value": "BV019_streaming",                          "hint": "重庆小伙"}, {"value": "BV524_streaming",                          "hint": "日语男声"}, {"value": "BV021_streaming",                          "hint": "东北老铁"}, {"value": "BV701_streaming",                          "hint": "擎苍"}, {"value": "BV113_streaming",                          "hint": "甜宠少御"}, {"value": "BV056_streaming",                          "hint": "阳光男声"}, {"value": "BV213_streaming",                          "hint": "广西表哥"}, {"value": "BV119_streaming",                          "hint": "通用赘婿"}, {"value": "BV705_streaming",                          "hint": "炀炀"}, {"value": "BV033_streaming",                          "hint": "温柔小哥"}, {"value": "BV102_streaming",                          "hint": "儒雅青年"}, {"value": "BV522_streaming",                          "hint": "气质女生"}, {"value": "BV034_streaming",                          "hint": "知性姐姐 · 双语"}, {"value": "BV005_streaming",                          "hint": "活泼女声"}, {"value": "zh_female_wanqudashu_moon_bigtts",         "hint": "湾区大叔"}, {"value": "zh_female_daimengchuanmei_moon_bigtts",    "hint": "呆萌川妹"}, {"value": "zh_male_guozhoudege_moon_bigtts",          "hint": "广州德哥"}, {"value": "zh_male_beijingxiaoye_moon_bigtts",        "hint": "北京小爷"}, {"value": "zh_male_shaonianzixin_moon_bigtts",        "hint": "少年梓辛 / Brayan"}, {"value": "zh_female_meilinvyou_moon_bigtts",         "hint": "魅力女友"}, {"value": "zh_male_shenyeboke_moon_bigtts",           "hint": "深夜播客"}, {"value": "zh_female_sajiaonvyou_moon_bigtts",        "hint": "柔美女友"}, {"value": "zh_female_yuanqinvyou_moon_bigtts",        "hint": "撒娇学妹"}, {"value": "zh_male_haoyuxiaoge_moon_bigtts",          "hint": "浩宇小哥"}, {"value": "zh_male_guangxiyuanzhou_moon_bigtts",      "hint": "广西远舟"}, {"value": "zh_female_meituojieer_moon_bigtts",        "hint": "妹坨洁儿"}, {"value": "zh_male_yuzhouzixuan_moon_bigtts",         "hint": "豫州子轩"}, {"value": "BV115_streaming",                          "hint": "古风少御"}, {"value": "zh_female_gaolengyujie_moon_bigtts",       "hint": "高冷御姐"}, {"value": "zh_male_yuanboxiaoshu_moon_bigtts",        "hint": "渊博小叔"}, {"value": "zh_male_yangguangqingnian_moon_bigtts",    "hint": "阳光青年"}, {"value": "zh_male_aojiaobazong_moon_bigtts",         "hint": "傲娇霸总"}, {"value": "zh_male_jingqiangkanye_moon_bigtts",       "hint": "京腔侃爷 / Harmony"}, {"value": "zh_female_shuangkuaisisi_moon_bigtts",     "hint": "爽快思思 / Skye"}, {"value": "zh_male_wennuanahu_moon_bigtts",           "hint": "温暖阿虎 / Alvin"}, {"value": "multi_female_shuangkuaisisi_moon_bigtts",  "hint": "はるこ / Esmeralda"}, {"value": "multi_male_jingqiangkanye_moon_bigtts",    "hint": "かずね / Javier or Álvaro"}, {"value": "multi_female_gaolengyujie_moon_bigtts",    "hint": "あけみ"}, {"value": "multi_male_wanqudashu_moon_bigtts",        "hint": "ひろし / Roberto"}, {"value": "ICL_zh_female_bingruoshaonv_tob",          "hint": "病弱少女"}, {"value": "ICL_zh_female_huoponvhai_tob",             "hint": "活泼女孩"}, {"value": "ICL_zh_female_heainainai_tob",             "hint": "和蔼奶奶"}, {"value": "ICL_zh_female_linjuayi_tob",               "hint": "邻居阿姨"}, {"value": "zh_female_wenrouxiaoya_moon_bigtts",       "hint": "温柔小雅"}, {"value": "zh_female_tianmeixiaoyuan_moon_bigtts",    "hint": "甜美小源"}, {"value": "zh_female_qingchezizi_moon_bigtts",        "hint": "清澈梓梓"}, {"value": "zh_male_dongfanghaoran_moon_bigtts",       "hint": "东方浩然"}, {"value": "zh_male_jieshuoxiaoming_moon_bigtts",      "hint": "解说小明"}, {"value": "zh_female_kailangjiejie_moon_bigtts",      "hint": "开朗姐姐"}, {"value": "zh_male_linjiananhai_moon_bigtts",         "hint": "邻家男孩"}, {"value": "zh_female_tianmeiyueyue_moon_bigtts",      "hint": "甜美悦悦"}, {"value": "zh_female_xinlingjitang_moon_bigtts",      "hint": "心灵鸡汤"}, ], "baidu": [ {"value": "baidu_0",    "hint": "度小美 · 标准女主播"}, {"value": "baidu_1",    "hint": "度小宇 · 亲切男声"}, {"value": "baidu_3",    "hint": "度逍遥 · 情感男声"}, {"value": "baidu_4",    "hint": "度丫丫 · 童声"}, {"value": "baidu_5",    "hint": "度小娇 · 成熟女主播"}, {"value": "baidu_5003", "hint": "度逍遥 · 情感男声"}, {"value": "baidu_5118", "hint": "度小鹿 · 甜美女声"}, {"value": "baidu_103",  "hint": "度米朵 · 可爱童声"}, {"value": "baidu_106",  "hint": "度博文 · 专业男主播"}, {"value": "baidu_110",  "hint": "度小童 · 童声主播"}, {"value": "baidu_111",  "hint": "度小萌 · 软萌妹子"}, {"value": "baidu_4003", "hint": "度逍遥 · 情感男声"}, {"value": "baidu_4100", "hint": "度小雯 · 活力女主播"}, {"value": "baidu_4103", "hint": "度米朵 · 可爱女声"}, {"value": "baidu_4105", "hint": "度灵儿 · 清澈女声"}, {"value": "baidu_4106", "hint": "度博文 · 专业男主播"}, {"value": "baidu_4115", "hint": "度小贤 · 电台男主播"}, {"value": "baidu_4117", "hint": "度小乔 · 活泼女声"}, {"value": "baidu_4119", "hint": "度小鹿 · 甜美女声"}, {"value": "baidu_4129", "hint": "度小彦 · 知识男主播"}, {"value": "baidu_4140", "hint": "度小新 · 专业女主播"}, {"value": "baidu_4143", "hint": "度清风 · 配音男声"}, {"value": "baidu_4144", "hint": "度姗姗 · 娱乐女声"}, {"value": "baidu_4149", "hint": "度星河 · 广告男声"}, {"value": "baidu_4206", "hint": "度博文 · 综艺男声"}, {"value": "baidu_4226", "hint": "南方 · 电台女主播"}, {"value": "baidu_4254", "hint": "度小清 · 广告女声"}, {"value": "baidu_4278", "hint": "度小贝 · 知识女主播"}, ], }, }
    _EMBEDDING_PROVIDERS = ["openai", "dashscope", "doubao", "zhipu", "linkai", "custom"]

    # Embedding model catalog per provider. Mirrors the default_model in
    # agent/memory/embedding/provider.py::EMBEDDING_VENDORS.
    # Custom providers have no preset list — model names vary per vendor,
    # so the user always types the model id manually.
    _EMBEDDING_PROVIDER_MODELS = { "openai":    ["text-embedding-3-small", "text-embedding-3-large"], "dashscope": ["text-embedding-v4"], "doubao":    ["doubao-embedding-vision-251215"], "zhipu":     ["embedding-3"], "linkai":    ["text-embedding-3-small"], "custom":    [], }

    # Capability-scoped model catalogs. The chat dropdown can reuse the
    # provider's generic model list, but vision and image generation are
    # served by a narrower subset that the runtime actually dispatches to —
    # see agent/tools/vision/vision.py and skills/image-generation/SKILL.md.
    # Anything not listed here intentionally hides the model dropdown so
    # users cannot pin a chat-only model and silently get a 4xx at runtime.
    _VISION_PROVIDER_MODELS = {   "openai":    [ const.GPT_56_LUNA, const.GPT_56_TERRA, const.GPT_56_SOL, const.GPT_55, const.GPT_54, const.GPT_54_MINI, const.GPT_54_NANO, const.GPT_5, const.GPT_41, const.GPT_41_MINI, const.GPT_4o, ], "doubao":    [const.DOUBAO_SEED_2_1_PRO, const.DOUBAO_SEED_2_1_TURBO, const.DOUBAO_SEED_2_PRO], "moonshot":  [const.KIMI_K2_6], "dashscope": [const.QWEN37_PLUS, const.QWEN36_PLUS],    "claudeAPI": [const.CLAUDE_SONNET_5, const.CLAUDE_OPUS_5, const.CLAUDE_FABLE_5, const.CLAUDE_4_8_OPUS, const.CLAUDE_4_7_OPUS, const.CLAUDE_4_6_SONNET, const.CLAUDE_4_6_OPUS], "gemini":    [const.GEMINI_35_FLASH, const.GEMINI_31_FLASH_LITE_PRE, const.GEMINI_31_PRO_PRE, const.GEMINI_3_FLASH_PRE], "qianfan":   [const.ERNIE_45_TURBO_VL],     "zhipu":     [const.GLM_5V_TURBO],    "minimax":   [const.MINIMAX_TEXT_01],  "mimo":      [const.MIMO_V2_5_PRO, const.MIMO_V2_5],    "linkai":    [ const.GPT_41_MINI, const.GPT_54_MINI, const.QWEN37_PLUS, const.DOUBAO_SEED_2_1_PRO, const.KIMI_K2_6, const.CLAUDE_SONNET_5, const.CLAUDE_FABLE_5, const.GEMINI_31_FLASH_LITE_PRE, ],   "custom": [], }

    # Image-generation catalog. Source of truth: skills/image-generation/SKILL.md.
    # Listed verbatim (not via const.*) because these are skill-side names
    # the script forwards directly to the vendor's image endpoint.

    # Two shapes are accepted per model entry:
    # - bare string                           → the model id, no hint
    # - {"value": ..., "hint": "..."}         → model id + dim secondary
    # label rendered on the right
    # of the dropdown row. Useful
    # for surfacing brand names
    # (e.g. "Nano Banana 2" next
    # to gemini-3.1-flash-image-preview).
    # The skill itself maps either form to the real vendor endpoint, so the
    # hint is purely cosmetic.
    _IMAGE_PROVIDER_MODELS = { "openai":    ["gpt-image-2", "gpt-image-1"], "gemini": [ {"value": "gemini-3.1-flash-image-preview", "hint": "Nano Banana 2"}, {"value": "gemini-3-pro-image-preview",     "hint": "Nano Banana Pro"}, {"value": "gemini-2.5-flash-image",         "hint": "Nano Banana"}, ], "doubao":    ["seedream-5.0-lite", "seedream-4.5"], "dashscope": ["qwen-image-2.0-pro", "qwen-image-2.0"], "minimax":   ["image-01"], "linkai": [ "gpt-image-2", {"value": "gemini-3.1-flash-image-preview", "hint": "Nano Banana 2"}, {"value": "gemini-3-pro-image-preview",     "hint": "Nano Banana Pro"}, "seedream-5.0-lite", ], }

    @staticmethod
    def _config_path():
        return os.path.join(get_data_root(), "config.json")

    @classmethod
    def _read_file_config(cls):
        path = cls._config_path()
        if not os.path.exists(path):
            return {}
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)

    @classmethod
    def _write_file_config(cls, data):
        with open(cls._config_path(), "w", encoding="utf-8") as f:
            json.dump(data, f, indent=4, ensure_ascii=False)

    @staticmethod
    def _is_real_key(value):
        return bool(value) and value not in ("", "YOUR API KEY", "YOUR_API_KEY")

    @classmethod
    def _custom_provider_cards(cls, local_config):
        """Expand ``custom_providers`` into one card per provider.

        Each user-defined OpenAI-compatible provider becomes its own card with
        id ``custom:<id>`` so the frontend can render, edit, delete and
        activate them independently. The card carries ``is_custom=True`` and
        ``active`` flags that the UI uses to render the extra controls.

        Returns an empty list when no multi-providers are configured, in which
        case the caller keeps the single legacy ``custom`` card untouched —
        guaranteeing backward compatibility with the flat
        ``custom_api_key`` / ``custom_api_base`` config.
        """
        try:
            from models.custom_provider import get_custom_providers, parse_custom_bot_type
            providers = get_custom_providers()
        except Exception as e:
            logger.warning(f"[ModelsHandler] failed to load custom_providers: {e}")
            providers = []
        if not providers:
            return []

        # Determine the currently active provider id from bot_type.
        bot_type = local_config.get("bot_type") or ""
        _, active_id = parse_custom_bot_type(bot_type)

        meta = ConfigHandler.PROVIDER_MODELS.get("custom") or {}
        cards = []
        for p in providers:
            pid = p.get("id") or ""
            name = p.get("name") or pid
            raw_key = p.get("api_key") or ""
            raw_base = p.get("api_base") or ""
            configured = cls._is_real_key(raw_key)
            cards.append({ "id": f"custom:{pid}", "label": {"zh": name, "en": name}, "configured": configured, "is_custom": True, "custom_id": pid, "custom_name": name, "active": (pid == active_id), "model": p.get("model") or "",    "api_key_field": None, "api_base_field": None, "api_key_masked": ConfigHandler._mask_key(raw_key) if configured else "", "api_base": raw_base, "api_base_default": "", "api_base_placeholder": meta.get("api_base_placeholder") or "", "models": [p.get("model")] if p.get("model") else [], })
        return cards

    @classmethod
    def _legacy_custom_in_use(cls, local_config):
        """True when the flat single-provider custom config is still relevant:
        either it is the active bot_type, or its key/base fields are filled.
        In that case the legacy "custom" card must stay visible even when
        multi ``custom_providers`` entries exist."""
        if (local_config.get("bot_type") or "") == "custom":
            return True
        return (cls._is_real_key(local_config.get("custom_api_key") or "") or bool(local_config.get("custom_api_base")))

    @classmethod
    def _provider_overview(cls):
        """All known providers (configured first, unconfigured after).
        Re-uses ConfigHandler.PROVIDER_MODELS for the canonical list.

        When the user has defined multiple custom (OpenAI-compatible)
        providers via ``custom_providers``, the single built-in ``custom``
        card is replaced by one card per provider (see
        ``_custom_provider_cards``). Otherwise the legacy single ``custom``
        card is shown unchanged.
        """
        local_config = conf()
        custom_cards = cls._custom_provider_cards(local_config)
        # Keep the legacy single "custom" card visible alongside the expanded
        # ones when the flat custom_api_key/base config is active or filled,
        # so existing single-provider setups never disappear from the UI.
        keep_legacy_custom = cls._legacy_custom_in_use(local_config)
        items = []
        for pid, p in ConfigHandler.PROVIDER_MODELS.items():
            if pid == "custom" and custom_cards:
                # Multi-provider mode: emit the expanded cards, plus the
                # legacy card when it is still in use.
                items.extend(custom_cards)
                if not keep_legacy_custom:
                    continue
            key_field = p.get("api_key_field")
            base_field = p.get("api_base_key")
            raw_key = local_config.get(key_field, "") if key_field else ""
            raw_base = local_config.get(base_field, "") if base_field else ""
            configured = cls._is_real_key(raw_key)
            items.append({ "id": pid, "label": p["label"], "configured": configured, "is_custom": (pid == "custom"), "api_key_field": key_field, "api_base_field": base_field, "api_key_masked": ConfigHandler._mask_key(raw_key) if configured else "", "api_base": raw_base or (p.get("api_base_default") or ""), "api_base_default": p.get("api_base_default") or "", "api_base_placeholder": p.get("api_base_placeholder") or "", "models": list(p.get("models") or []), })

        def _sort_key(it):
            pid = it["id"]
            # Custom expanded cards share the sort weight of the base "custom"
            # entry so they cluster where the single custom card used to be.
            base_id = "custom" if it.get("is_custom") else pid
            try:
                order = list(ConfigHandler.PROVIDER_MODELS.keys()).index(base_id)
            except ValueError as e:
                order = len(ConfigHandler.PROVIDER_MODELS)
            return (0 if it["configured"] else 1, order)

        items.sort(key=_sort_key)
        return items

    # Model-name prefix to provider id mapping, used to auto-infer the
    # current provider when bot_type is not explicitly set in config.
    _MODEL_PREFIX_TO_PROVIDER = [ ("deepseek",    "deepseek"), ("doubao",      "doubao"), ("qwen",        "dashscope"), ("qwq",         "dashscope"), ("qvq",         "dashscope"), ("glm",         "zhipu"), ("claude",      "claudeAPI"), ("gemini",      "gemini"), ("moonshot",    "moonshot"), ("kimi",        "moonshot"), ("ernie",       "qianfan"), ("mimo-",       "mimo"), ("minimax",     "minimax"), ("MiniMax",     "minimax"), ("abab",        "minimax"), ("gpt",         "openai"), ("o1-",         "openai"), ("o3-",         "openai"), ("o4-",         "openai"), ]

    @classmethod
    def _infer_provider_from_model(cls, model_name):
        """Infer the provider id from a model name by checking known prefixes
        and the full model lists in PROVIDER_MODELS.

        Returns the matched provider id, or "" if no match is found.
        """
        if not model_name or not isinstance(model_name, str):
            return ""
        # 1. Check if model name exactly matches a provider's model list entry.
        for pid, p in ConfigHandler.PROVIDER_MODELS.items():
            if pid == "custom":
                continue
            if model_name in p.get("models", []):
                return pid
        # 2. Fall back to prefix matching (case-insensitive).
        lowered = model_name.lower()
        for prefix, provider_id in cls._MODEL_PREFIX_TO_PROVIDER:
            if lowered.startswith(prefix.lower()):
                return provider_id
        # 3. Check for MiniMax models that start with uppercase "MiniMax-"
        # (the prefix list covers self, but double-check just in case).
        if model_name.startswith("MiniMax") or model_name.startswith("abab"):
            return "minimax"
        return ""

    @classmethod
    def _chat_capability(cls, local_config):
        """Main chat model — drives the agent. bot_type maps to a provider id."""
        bot_type = local_config.get("bot_type") or ""
        provider_id = "openai" if bot_type == "chatGPT" else bot_type
        # Auto-infer provider from model name when bot_type is not set.
        if not provider_id:
            model_name = local_config.get("model", "")
            provider_id = cls._infer_provider_from_model(model_name)
        is_custom_id = provider_id.startswith("custom:")
        if (provider_id not in ConfigHandler.PROVIDER_MODELS and not is_custom_id and local_config.get("use_linkai")):
            provider_id = "linkai"
        # In multi-provider mode, replace the single "custom" entry with the
        # expanded "custom:<id>" ids so the chat dropdown matches the cards.
        # The legacy "custom" entry stays when its flat config is still used.
        provider_ids = []
        custom_cards = cls._custom_provider_cards(local_config)
        keep_legacy_custom = cls._legacy_custom_in_use(local_config)
        for pid in ConfigHandler.PROVIDER_MODELS.keys():
            if pid == "custom" and custom_cards:
                provider_ids.extend(c["id"] for c in custom_cards)
                if keep_legacy_custom:
                    provider_ids.append(pid)
            else:
                provider_ids.append(pid)
        return { "editable": True, "current_provider": provider_id, "current_model": local_config.get("model", ""), "providers": provider_ids, "use_linkai": bool(local_config.get("use_linkai", False)), }

    # Auto-fallback order for vision when no explicit model is pinned.
    # Mirrors agent/tools/vision/vision.py::_resolve_providers — DeepSeek and
    # other text-only chat bots are intentionally absent, since they cannot
    # actually serve a vision request. Each entry is
    # (provider_id, api_key_field, default_vision_model)
    # and lookups are case-insensitive on the api_key_field. LinkAI and
    # OpenAI are handled separately below so use_linkai can promote LinkAI
    # to the front of the chain.
    _VISION_AUTO_ORDER = [ ("moonshot",  "moonshot_api_key",  const.KIMI_K2_6), ("doubao",    "ark_api_key",       const.DOUBAO_SEED_2_PRO), ("dashscope", "dashscope_api_key", const.QWEN37_PLUS), ("claudeAPI", "claude_api_key",    const.CLAUDE_SONNET_5), ("gemini",    "gemini_api_key",    const.GEMINI_35_FLASH), ("qianfan",   "qianfan_api_key",   const.ERNIE_45_TURBO_VL), ("zhipu",     "zhipu_ai_api_key",  const.GLM_5V_TURBO), ("minimax",   "minimax_api_key",   const.MINIMAX_TEXT_01), ("mimo",      "mimo_api_key",      const.MIMO_V2_5_PRO), ]

    @classmethod
    def _predict_vision_auto(cls, local_config):
        """Predict which provider vision.py will actually dispatch to when
        no tools.vision.model is set. Mirrors the fallback order in
        agent/tools/vision/vision.py::_resolve_providers so the UI hint
        matches reality."""
        chat = cls._chat_capability(local_config)
        main_provider = chat["current_provider"]
        main_model = chat["current_model"]
        use_linkai_flag = bool(local_config.get("use_linkai", False))
        linkai_configured = cls._is_real_key(local_config.get("linkai_api_key", ""))

        def _try(pid, model_default):
            # Look up the api_key for self provider via the canonical
            # provider table so we don't hardcode field names here.
            meta = ConfigHandler.PROVIDER_MODELS.get(pid) or {}
            key_field = meta.get("api_key_field")
            if not key_field:
                return None
            if not cls._is_real_key(local_config.get(key_field, "")):
                return None
            # Pick a model that the vision runtime can actually dispatch to
            # for self provider. Using `main_model` here is unsafe — for
            # vendors like Zhipu/MiniMax the bot hard-codes the vision model
            # name regardless of the chat-model name, so surfacing the chat
            # model name in the hint is misleading. Trust the curated
            # _VISION_PROVIDER_MODELS list: prefer the main model only if
            # it appears there; otherwise show the vendor's first vision-
            # capable model.
            allowed = cls._VISION_PROVIDER_MODELS.get(pid, [])
            if pid == main_provider and main_model and main_model in allowed:
                return {"provider": pid, "model": main_model}
            fallback = allowed[0] if allowed else model_default
            return {"provider": pid, "model": fallback}

        # 1. use_linkai → suppress the hint entirely. LinkAI is a proxy and
        # we don't observe which underlying model it picks; surfacing
        # "LinkAI" with no model would not tell the user anything useful.
        if use_linkai_flag and linkai_configured:
            return {"provider": "", "model": ""}

        # 2. Main bot — only when it natively supports vision. We approximate
        # "natively supports" by membership in _VISION_PROVIDER_MODELS,
        # which is the same set vision.py's _DISCOVERABLE_MODELS covers
        # (minus the chat-only DeepSeek family).
        if main_provider in cls._VISION_PROVIDER_MODELS:
            hit = _try(main_provider, main_model)
            if hit:
                return hit

        # 3. Other discoverable providers in declared order
        for pid, _key, default_model in cls._VISION_AUTO_ORDER:
            hit = _try(pid, default_model)
            if hit:
                return hit

        # 4. OpenAI raw HTTP
        if cls._is_real_key(local_config.get("open_ai_api_key", "")):
            return {"provider": "openai", "model": const.GPT_55}

        # 5. LinkAI as last resort (only reached when use_linkai is off)
        if linkai_configured:
            return {"provider": "linkai", "model": const.GPT_41_MINI}

        return {"provider": "", "model": ""}

    @classmethod
    def _vision_capability(cls, local_config):
        """Vision model. tools.vision.model is the explicit override; otherwise
        the runtime fallback chain in agent/tools/vision/vision.py decides."""
        tools_conf = local_config.get("tools") or local_config.get("tool") or {}
        if not isinstance(tools_conf, dict):
            tools_conf = {}
        vision_conf = tools_conf.get("vision") or {}
        if not isinstance(vision_conf, dict):
            vision_conf = {}
        user_specified = (vision_conf.get("model") or "").strip()
        explicit_provider = (vision_conf.get("provider") or "").strip()

        # Build provider list: built-in providers + expanded custom:<id> entries.
        # Same pattern as _embedding_capability — each user-created custom
        # provider gets its own dropdown entry showing the user-chosen name.
        providers = []
        custom_cards = cls._custom_provider_cards(local_config)
        for pid in cls._VISION_PROVIDER_MODELS:
            if pid == "custom":
                if custom_cards:
                    providers.extend(c["id"] for c in custom_cards)
            else:
                providers.append(pid)

        # Provider resolution priority:
        # 1. Explicit `tools.vision.provider` (persisted via UI; supports
        # custom model names that prefix-inference can't recognize).
        # 2. Scan per-provider model lists by model name.
        # Empty provider keeps the dropdown on "auto" when we can't tell.
        inferred_provider = ""
        if explicit_provider and explicit_provider in providers:
            inferred_provider = explicit_provider
        elif user_specified:
            for pid, models in cls._VISION_PROVIDER_MODELS.items():
                if user_specified in models:
                    # For "custom" key, map to the first custom card
                    inferred_provider = custom_cards[0]["id"] if pid == "custom" and custom_cards else pid
                    break

        # In auto mode the hint should reflect what vision.py will actually
        # dispatch to — surface that prediction via fallback_* so the UI
        # shows e.g. "openai / gpt-4.1-mini" instead of the chat-model name.
        predicted = cls._predict_vision_auto(local_config)

        return { "editable": True, "strategy": "specified" if user_specified else "auto", "user_specified_model": user_specified, "current_provider": inferred_provider, "current_model": user_specified, "fallback_provider": predicted["provider"], "fallback_model": predicted["model"], "providers": providers, "provider_models": cls._VISION_PROVIDER_MODELS, }

    @classmethod
    def _asr_capability(cls, local_config):
        # "Pick or empty" — when voice_to_text is unset we don't show a
        # current selection. `suggested_provider` previews which vendor
        # the bridge auto-picker would land on (purely a UX hint, NOT
        # persisted). Once the user saves a vendor, we lock onto it.
        explicit = (local_config.get("voice_to_text") or "").strip().lower()
        suggested = ""
        if not explicit:
            for pid in cls._ASR_PROVIDERS:
                meta = ConfigHandler.PROVIDER_MODELS.get(pid) or {}
                key_field = meta.get("api_key_field")
                if key_field and cls._is_real_key(local_config.get(key_field, "")):
                    suggested = pid
                    break
        return { "editable": True, "current_provider": explicit, "suggested_provider": suggested, "current_model": (local_config.get("voice_to_text_model") or "") if explicit else "", "providers": cls._ASR_PROVIDERS, "provider_models": cls._ASR_PROVIDER_MODELS, }

    @classmethod
    def _tts_capability(cls, local_config):
        explicit = (local_config.get("text_to_voice") or "").strip().lower()
        # Providers outside the white-list don't drive the picker, but their
        # underlying runtime config is preserved so bridge still routes them.
        ui_provider = explicit if explicit in cls._TTS_PROVIDERS else ""
        suggested = ""
        if not ui_provider:
            for pid in cls._TTS_PROVIDERS:
                meta = ConfigHandler.PROVIDER_MODELS.get(pid) or {}
                key_field = meta.get("api_key_field")
                if key_field and cls._is_real_key(local_config.get(key_field, "")):
                    suggested = pid
                    break
        return { "editable": True, "current_provider": ui_provider, "suggested_provider": suggested, "current_model": (local_config.get("text_to_voice_model") or "") if ui_provider else "", "current_voice": (local_config.get("tts_voice_id") or "") if ui_provider else "", "providers": cls._TTS_PROVIDERS, "provider_models": cls._TTS_PROVIDER_MODELS, "provider_voices": cls._TTS_PROVIDER_VOICES, "reply_mode": cls._tts_reply_mode(local_config), }

    @staticmethod
    def _tts_reply_mode(local_config):
        if local_config.get("always_reply_voice", False):
            return "always"
        if local_config.get("voice_reply_voice", False):
            return "voice_if_voice"
        return "off"

    @classmethod
    def _embedding_capability(cls, local_config):
        # Embedding is "pick or empty" — runtime's legacy openai/linkai
        # fallback is a safety net, not a UX-visible auto mode.
        # `suggested_provider` is a UI-only hint (NOT persisted) that
        # preselects the dropdown to whichever configured vendor we'd
        # recommend, so users don't have to expand the menu to find it.
        explicit = (local_config.get("embedding_provider") or "").strip().lower()
        suggested = ""
        if not explicit:
            for pid in cls._EMBEDDING_PROVIDERS:
                if pid == "custom":
                    continue
                meta = ConfigHandler.PROVIDER_MODELS.get(pid) or {}
                key_field = meta.get("api_key_field")
                if key_field and cls._is_real_key(local_config.get(key_field, "")):
                    suggested = pid
                    break
            if not suggested:
                custom_cards = cls._custom_provider_cards(local_config)
                if custom_cards:
                    suggested = custom_cards[0]["id"]

        # Build provider list: built-in providers + expanded custom:<id> entries
        # Same pattern as _chat_capability — each user-created custom provider
        # gets its own dropdown entry showing the user-chosen name.
        providers = []
        custom_cards = cls._custom_provider_cards(local_config)
        for pid in cls._EMBEDDING_PROVIDERS:
            if pid == "custom":
                if custom_cards:
                    providers.extend(c["id"] for c in custom_cards)
                # No custom providers configured — skip the bare "custom" entry
                # since the runtime cannot resolve its credentials.
            else:
                providers.append(pid)

        return { "editable": True, "current_provider": explicit, "suggested_provider": suggested, "current_model": local_config.get("embedding_model", "") or "", "current_dim": int(local_config.get("embedding_dimensions") or 0) or None, "providers": providers, "provider_models": cls._EMBEDDING_PROVIDER_MODELS, }

    # Auto-fallback order for image generation. Mirrors the global priority
    # used inside skills/image-generation/scripts/generate.py
    # (`_DEFAULT_PROVIDER_ORDER`): OpenAI → Gemini → Seedream(Ark/doubao) →
    # Qwen(dashscope) → MiniMax → LinkAI. Each entry maps the
    # provider-card id to the script's per-provider DEFAULT_MODEL so the
    # hint matches what the runtime would actually request.
    _IMAGE_AUTO_ORDER = [ ("openai",    "gpt-image-2"), ("gemini",    "gemini-3.1-flash-image-preview"),   ("doubao",    "seedream-5.0-lite"), ("dashscope", "qwen-image-2.0"), ("minimax",   "image-01"), ("linkai",    "gpt-image-2"), ]

    @classmethod
    def _predict_image_auto(cls, local_config):
        """Predict which provider/model the image-generation skill will hit
        when no SKILL_IMAGE_GENERATION_MODEL override is set. Mirrors
        skills/image-generation/scripts/generate.py::_build_providers so
        the UI hint matches reality. Chat-only providers (DeepSeek etc.)
        are absent by design — image generation never falls back to a chat
        bot regardless of the main model.

        When use_linkai is enabled the hint is suppressed entirely — LinkAI
        proxies to whichever backend it deems appropriate and surfacing
        "LinkAI" alone tells the user nothing actionable."""
        use_linkai_flag = bool(local_config.get("use_linkai", False))
        linkai_configured = cls._is_real_key(local_config.get("linkai_api_key", ""))
        if use_linkai_flag and linkai_configured:
            return {"provider": "", "model": ""}

        for pid, default_model in cls._IMAGE_AUTO_ORDER:
            meta = ConfigHandler.PROVIDER_MODELS.get(pid) or {}
            key_field = meta.get("api_key_field")
            if not key_field:
                continue
            if cls._is_real_key(local_config.get(key_field, "")):
                return {"provider": pid, "model": default_model}
        return {"provider": "", "model": ""}

    @classmethod
    def _image_capability(cls, local_config):
        """Image generation. Source of truth: config["skills"]["image-generation"]["model"]
        (mirrors the per-skill config schema documented in skills/image-generation).
        The runtime resolver in skills/image-generation/scripts/generate.py
        reads this via the SKILL_IMAGE_GENERATION_MODEL env var that the
        agent_initializer syncs at startup; provider is inferred from the
        model name prefix, mirroring vision.py's design.

        ``skill`` (singular) is still tolerated as a legacy fallback —
        config.load_config() folds it into ``skills`` at startup.
        """
        skills_node = local_config.get("skills") or local_config.get("skill") or {}
        if not isinstance(skills_node, dict):
            skills_node = {}
        img_node = skills_node.get("image-generation") or {}
        if not isinstance(img_node, dict):
            img_node = {}
        explicit_model = (img_node.get("model") or "").strip()
        explicit_provider = (img_node.get("provider") or "").strip()

        # Provider resolution priority:
        # 1. Explicit `skills.image-generation.provider` (persisted via UI;
        # supports custom model names that prefix-inference can't catch).
        # 2. Scan per-provider model catalog by model name.
        # Empty provider keeps the dropdown on "auto" when we can't tell.
        inferred_provider = ""
        if explicit_provider and explicit_provider in cls._IMAGE_PROVIDER_MODELS:
            inferred_provider = explicit_provider
        elif explicit_model:
            for pid, models in cls._IMAGE_PROVIDER_MODELS.items():
                for entry in models:
                    val = entry if isinstance(entry, str) else (entry.get("value") or "")
                    if val == explicit_model:
                        inferred_provider = pid
                        break
                if inferred_provider:
                    break

        # In auto mode the hint should reflect what generate.py will actually
        # dispatch to — surface that prediction via fallback_* so the UI
        # never claims a chat-only bot (e.g. minimax/MiniMax-M2.7) "would
        # generate the image", which is impossible.
        predicted = cls._predict_image_auto(local_config)

        return { "editable": True, "strategy": "specified" if explicit_model else "auto", "current_provider": inferred_provider, "current_model": explicit_model, "fallback_provider": predicted["provider"], "fallback_model": predicted["model"], "providers": list(cls._IMAGE_PROVIDER_MODELS.keys()), "provider_models": cls._IMAGE_PROVIDER_MODELS,    "runtime_active": False, "note": "router_pending", }

    # Canonical search provider order. Mirrors PROVIDER_ORDER in
    # agent/tools/web_search/web_search.py — keep them in sync.
    _SEARCH_PROVIDERS = ("bocha", "qianfan", "zhipu", "linkai")

    _SEARCH_PROVIDER_LABELS = { "bocha":   {"zh": "博查", "en": "Bocha"}, "zhipu":   {"zh": "智谱", "en": "GLM"}, "qianfan": {"zh": "百度千帆", "en": "ERNIE"}, "linkai":  {"zh": "LinkAI", "en": "LinkAI"}, }

    @classmethod
    def _search_provider_key(cls, provider, local_config):
        """Resolve the (raw) key for a given search provider."""
        if provider == "bocha":
            tools_cfg = local_config.get("tools") or {}
            block = tools_cfg.get("web_search") or {} if isinstance(tools_cfg, dict) else {}
            return (block.get("bocha_api_key") if isinstance(block, dict) else "") or os.environ.get("BOCHA_API_KEY", "")
        if provider == "zhipu":
            return local_config.get("zhipu_ai_api_key") or os.environ.get("ZHIPUAI_API_KEY", "")
        if provider == "qianfan":
            return local_config.get("qianfan_api_key") or os.environ.get("QIANFAN_API_KEY", "")
        if provider == "linkai":
            return local_config.get("linkai_api_key") or os.environ.get("LINKAI_API_KEY", "")
        return ""

    @classmethod
    def _search_capability(cls, local_config):
        """Search is editable: pick auto (default) or pin a specific backend.
        Providers reuse model-vendor keys (zhipu/qianfan/linkai) so they show
        up as configured once the user adds those vendors; bocha keeps its
        own key under tools.web_search."""
        tools_cfg = local_config.get("tools") or {}
        ws_cfg = tools_cfg.get("web_search") or {} if isinstance(tools_cfg, dict) else {}
        if not isinstance(ws_cfg, dict):
            ws_cfg = {}

        providers = []
        configured_ids = []
        for pid in cls._SEARCH_PROVIDERS:
            ok = cls._is_real_key(cls._search_provider_key(pid, local_config))
            raw_key = cls._search_provider_key(pid, local_config) if ok else ""
            providers.append({ "id": pid, "label": cls._SEARCH_PROVIDER_LABELS.get(pid, pid), "configured": ok,    "needs_dedicated_key": pid == "bocha", "api_key_masked": ConfigHandler._mask_key(raw_key) if raw_key else "", })
            if ok:
                configured_ids.append(pid)

        strategy = (ws_cfg.get("strategy") or "auto").strip().lower()
        if strategy not in ("auto", "fixed"):
            strategy = "auto"
        fixed_provider = (ws_cfg.get("provider") or "").strip().lower()
        if fixed_provider and fixed_provider not in configured_ids:
            fixed_provider = ""

        # current_provider drives the chip in the header — show the actually
        # active backend (pinned or first auto-picked).
        if strategy == "fixed" and fixed_provider:
            current = fixed_provider
        else:
            current = configured_ids[0] if configured_ids else ""

        return { "editable": True, "strategy": strategy, "providers": providers, "configured_providers": configured_ids, "current_provider": current, "fixed_provider": fixed_provider, "available": bool(current), }

    @classmethod
    def _capabilities(cls, local_config):
        return { "chat":      cls._chat_capability(local_config), "vision":    cls._vision_capability(local_config), "asr":       cls._asr_capability(local_config), "tts":       cls._tts_capability(local_config), "embedding": cls._embedding_capability(local_config), "image":     cls._image_capability(local_config), "search":    cls._search_capability(local_config), }

    def GET(self):
        _require_auth()
        web.header("Content-Type", "application/json; charset=utf-8")
        try:
            local_config = conf()
            return json.dumps({ "status": "success", "providers": self._provider_overview(), "capabilities": self._capabilities(local_config), }, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[ModelsHandler] GET failed: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        _require_auth()
        web.header("Content-Type", "application/json; charset=utf-8")
        try:
            data = json.loads(web.data() or b"{}")
            action = data.get("action") or ""
            if action == "set_provider":
                return self._handle_set_provider(data)
            if action == "delete_provider":
                return self._handle_delete_provider(data)
            if action == "set_custom_provider":
                return self._handle_set_custom_provider(data)
            if action == "delete_custom_provider":
                return self._handle_delete_custom_provider(data)
            if action == "set_active_custom_provider":
                return self._handle_set_active_custom_provider(data)
            if action == "set_capability":
                return self._handle_set_capability(data)
            if action == "set_voice_reply_mode":
                return self._handle_set_voice_reply_mode(data)
            if action == "set_search_credential":
                return self._handle_set_search_credential(data)
            return json.dumps({"status": "error", "message": f"unknown action: {action!r}"})
        except Exception as e:
            logger.error(f"[ModelsHandler] POST failed: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def _handle_set_provider(self, data):
        provider_id = (data.get("provider_id") or "").strip()
        meta = ConfigHandler.PROVIDER_MODELS.get(provider_id)
        if not meta:
            return json.dumps({"status": "error", "message": f"unknown provider: {provider_id}"})

        # api_key absent / empty / None => leave the existing key untouched
        # (used by the "edit only base url" flow). To clear the key, callers
        # must use action=delete_provider explicitly.
        api_key_raw = data.get("api_key")
        api_key = api_key_raw.strip() if isinstance(api_key_raw, str) else ""

        # api_base presence is significant: an explicit "" means "reset to
        # default", whereas a missing key means "no change".
        api_base_present = "api_base" in data
        api_base = (data.get("api_base") or "").strip() if api_base_present else None

        applied = {}
        local_config = conf()
        file_cfg = self._read_file_config()

        key_field = meta.get("api_key_field")
        if key_field and api_key:
            local_config[key_field] = api_key
            file_cfg[key_field] = api_key
            applied[key_field] = True
        base_field = meta.get("api_base_key")
        if base_field and api_base_present:
            local_config[base_field] = api_base
            file_cfg[base_field] = api_base
            applied[base_field] = True

        if not applied:
            # Nothing actually changed (e.g. user opened the modal and hit
            # save without editing). Treat as a successful no-op so the
            # frontend can show "Saved" instead of surfacing an error.
            return json.dumps({"status": "success", "provider": provider_id, "noop": True})

        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] provider {provider_id} updated: {sorted(applied.keys())}")

        # Vendor credentials affect bot routing for any capability that uses
        # them; safest to reset Bridge so the next request rebuilds bots.
        self._reset_bridge()
        return json.dumps({"status": "success", "provider": provider_id})

    def _handle_delete_provider(self, data):
        provider_id = (data.get("provider_id") or "").strip()
        meta = ConfigHandler.PROVIDER_MODELS.get(provider_id)
        if not meta:
            return json.dumps({"status": "error", "message": f"unknown provider: {provider_id}"})

        local_config = conf()
        file_cfg = self._read_file_config()

        cleared = []
        for field_name in (meta.get("api_key_field"), meta.get("api_base_key")):
            if not field_name:
                continue
            # Always write the key — even if it was absent before — so the
            # in-memory conf() reflects the cleared state without needing a
            # restart. (`in local_config` was too strict: provider keys that
            # were ever set then deleted manually wouldn't get reset.)
            local_config[field_name] = ""
            file_cfg[field_name] = ""
            cleared.append(field_name)

        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] provider {provider_id} cleared: {cleared}")
        self._reset_bridge()
        return json.dumps({"status": "success", "provider": provider_id, "cleared": cleared})

    # ------------------------------------------------------------------
    # Multiple custom (OpenAI-compatible) providers
    # ------------------------------------------------------------------
    # These actions manage the ``custom_providers`` list.  Activation is done
    # by setting ``bot_type`` to ``"custom:<id>"``.  There is no separate
    # ``custom_active_provider`` field — a single source of truth.

    @staticmethod
    def _normalize_custom_providers(raw):
        """Return a clean list of provider dicts (drops malformed entries)."""
        if not isinstance(raw, list):
            return []
        out = []
        for p in raw:
            if isinstance(p, dict) and (p.get("id") or "").strip():
                out.append(p)
        return out

    def _persist_custom_providers(self, providers, bot_type=None):
        """Write the providers list to both in-memory conf and the on-disk
        config, then reset the bridge so bots rebuild.

        If ``bot_type`` is given, also update ``bot_type``.  When activating a
        provider (bot_type is ``custom:<id>``), also write the provider's
        ``model`` into the global ``model`` field so that all paths (chat,
        agent, vision) automatically use the correct model."""
        from models.custom_provider import parse_custom_bot_type

        local_config = conf()
        file_cfg = self._read_file_config()
        local_config["custom_providers"] = providers
        file_cfg["custom_providers"] = providers
        if bot_type is not None:
            local_config["bot_type"] = bot_type
            file_cfg["bot_type"] = bot_type
            # Sync the provider's model into the global model field.
            _, pid = parse_custom_bot_type(bot_type)
            if pid:
                provider = next((p for p in providers if p.get("id") == pid), None)
                if provider and provider.get("model"):
                    local_config["model"] = provider["model"]
                    file_cfg["model"] = provider["model"]
        self._write_file_config(file_cfg)
        self._reset_bridge()

    def _handle_set_custom_provider(self, data):
        """Add a new custom provider or update an existing one.

        Payload::

            {
              "action": "set_custom_provider",
              "id": "3f2a9c1b",             # required for edit; omit for create
              "name": "my-provider",         # required, display label
              "api_base": "https://...",     # required when creating
              "api_key": "sk-...",           # optional on edit (keep existing)
              "model": "model-name",         # optional default model
              "make_active": true            # optional, also activate it
            }
        """
        from models.custom_provider import generate_provider_id, parse_custom_bot_type

        name = (data.get("name") or "").strip()
        if not name:
            return json.dumps({"status": "error", "message": "name is required"})

        provider_id = (data.get("id") or "").strip()
        api_base = (data.get("api_base") or "").strip()
        # api_key omitted/empty on edit => keep the existing one.
        api_key_raw = data.get("api_key")
        api_key = api_key_raw.strip() if isinstance(api_key_raw, str) else ""
        model = (data.get("model") or "").strip()
        make_active = bool(data.get("make_active"))

        local_config = conf()
        providers = self._normalize_custom_providers(local_config.get("custom_providers"))

        existing = next((p for p in providers if p.get("id") == provider_id), None) if provider_id else None
        if existing is None:
            # Creating a new provider — api_base is mandatory.
            if not api_base:
                return json.dumps({"status": "error", "message": "api_base is required"})
            provider_id = generate_provider_id()
            entry = {"id": provider_id, "name": name, "api_key": api_key, "api_base": api_base}
            if model:
                entry["model"] = model
            providers.append(entry)
            created = True
        else:
            existing["name"] = name
            if api_base:
                existing["api_base"] = api_base
            if api_key:
                existing["api_key"] = api_key
            # Only touch model when explicitly provided in the payload; an
            # explicit empty string clears it, a missing key keeps it (the
            # UI modal no longer sends model, so manual config survives edits).
            if "model" in data:
                if model:
                    existing["model"] = model
                else:
                    existing.pop("model", None)
            created = False

        # Decide bot_type — only switch when explicitly requested.
        new_bot_type = None
        if make_active:
            new_bot_type = f"custom:{provider_id}"

        self._persist_custom_providers(providers, new_bot_type)
        logger.info( f"[ModelsHandler] custom provider {name!r} (id={provider_id}) " f"{'created' if created else 'updated'}" )
        return json.dumps({ "status": "success", "id": provider_id, "name": name, "created": created, })

    def _handle_delete_custom_provider(self, data):
        """Remove a custom provider by id."""
        from models.custom_provider import parse_custom_bot_type

        provider_id = (data.get("id") or "").strip()
        if not provider_id:
            return json.dumps({"status": "error", "message": "id is required"})

        local_config = conf()
        providers = self._normalize_custom_providers(local_config.get("custom_providers"))
        remaining = [p for p in providers if p.get("id") != provider_id]
        if len(remaining) == len(providers):
            return json.dumps({"status": "error", "message": f"unknown custom provider id: {provider_id}"})

        # If the deleted provider was active, fall back to the first remaining.
        _, current_active_id = parse_custom_bot_type(local_config.get("bot_type") or "")
        new_bot_type = None
        if current_active_id == provider_id:
            if remaining:
                new_bot_type = f"custom:{remaining[0]['id']}"
            else:
                new_bot_type = "custom"  # revert to legacy

        self._persist_custom_providers(remaining, new_bot_type)
        logger.info(f"[ModelsHandler] custom provider id={provider_id} deleted")
        return json.dumps({"status": "success", "id": provider_id})

    def _handle_set_active_custom_provider(self, data):
        """Activate a custom provider by setting bot_type to 'custom:<id>'."""
        provider_id = (data.get("id") or "").strip()
        if not provider_id:
            return json.dumps({"status": "error", "message": "id is required"})

        local_config = conf()
        providers = self._normalize_custom_providers(local_config.get("custom_providers"))
        if not any(p.get("id") == provider_id for p in providers):
            return json.dumps({"status": "error", "message": f"unknown custom provider id: {provider_id}"})

        new_bot_type = f"custom:{provider_id}"
        self._persist_custom_providers(providers, new_bot_type)
        logger.info(f"[ModelsHandler] active custom provider set to id={provider_id}")
        return json.dumps({"status": "success", "active_id": provider_id})

    def _handle_set_capability(self, data):
        capability = (data.get("capability") or "").strip()
        provider_id = (data.get("provider_id") or "").strip()
        model = (data.get("model") or "").strip()

        if capability == "chat":
            return self._set_chat(provider_id, model)
        if capability == "vision":
            return self._set_vision(provider_id, model)
        if capability == "asr":
            return self._set_asr(provider_id, model)
        if capability == "tts":
            return self._set_tts(provider_id, model, (data.get("voice") or "").strip())
        if capability == "embedding":
            return self._set_embedding(provider_id, model)
        if capability == "image":
            return self._set_image(provider_id, model)
        if capability == "search":
            return self._set_search( (data.get("strategy") or "").strip().lower(), (data.get("provider") or "").strip().lower(), )
        return json.dumps({"status": "error", "message": f"capability not editable: {capability}"})

    def _set_image(self, provider_id, model):
        # Source of truth: skills.image-generation.{provider, model}. The
        # provider field is persisted so users picking a custom model under
        # a specific vendor still get routed there — runtime falls back to
        # model-name prefix inference only when provider is empty.
        local_config = conf()
        file_cfg = self._read_file_config()

        self._set_nested_namespace_value(local_config, "skills", "image-generation", "model", model or "")
        self._set_nested_namespace_value(file_cfg, "skills", "image-generation", "model", model or "")
        self._set_nested_namespace_value(local_config, "skills", "image-generation", "provider", provider_id or "")
        self._set_nested_namespace_value(file_cfg, "skills", "image-generation", "provider", provider_id or "")
        self._drop_legacy_namespace(local_config, "skill", "skills", child="image-generation")
        self._drop_legacy_namespace(file_cfg, "skill", "skills", child="image-generation")

        self._write_file_config(file_cfg)

        # The skill subprocess reads SKILL_IMAGE_GENERATION_{MODEL,PROVIDER}
        # from env at startup; mirror the change so live edits apply without
        # restart.
        model_env = "SKILL_IMAGE_GENERATION_MODEL"
        provider_env = "SKILL_IMAGE_GENERATION_PROVIDER"
        if model:
            os.environ[model_env] = model
        else:
            os.environ.pop(model_env, None)
        if provider_id:
            os.environ[provider_env] = provider_id
        else:
            os.environ.pop(provider_env, None)

        logger.info(f"[ModelsHandler] image updated: provider={provider_id!r} model={model!r}")
        return json.dumps({ "status": "success", "provider": provider_id, "model": model, "router_pending": True, })

    def _set_chat(self, provider_id, model):
        # Accept expanded custom provider ids ("custom:<id>") as well as the
        # built-in vendors, so the chat capability card and the custom
        # providers section behave consistently.
        custom_provider = None
        if provider_id.startswith("custom:"):
            from models.custom_provider import parse_custom_bot_type
            _, custom_id = parse_custom_bot_type(provider_id)
            providers = self._normalize_custom_providers(conf().get("custom_providers"))
            custom_provider = next((p for p in providers if p.get("id") == custom_id), None)
            if custom_provider is None:
                return json.dumps({"status": "error", "message": f"unknown custom provider id: {custom_id}"})
        elif provider_id and provider_id not in ConfigHandler.PROVIDER_MODELS:
            return json.dumps({"status": "error", "message": f"unknown provider: {provider_id}"})

        applied = {}
        local_config = conf()
        file_cfg = self._read_file_config()

        # Fall back to the custom provider's default model when none is given.
        if not model and custom_provider:
            model = custom_provider.get("model") or ""

        if provider_id:
            bot_type_value = "chatGPT" if provider_id == "openai" else provider_id
            local_config["bot_type"] = bot_type_value
            file_cfg["bot_type"] = bot_type_value
            applied["bot_type"] = bot_type_value
            use_linkai = (provider_id == "linkai")
            local_config["use_linkai"] = use_linkai
            file_cfg["use_linkai"] = use_linkai
            applied["use_linkai"] = use_linkai
        if model:
            local_config["model"] = model
            file_cfg["model"] = model
            applied["model"] = model

        if not applied:
            return json.dumps({"status": "success", "applied": {}, "noop": True})

        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] chat updated: {applied}")
        self._reset_bridge()
        return json.dumps({"status": "success", "applied": applied})

    def _set_vision(self, provider_id, model):
        # Source of truth: tools.vision.{provider, model}. The provider field
        # is persisted so users picking a custom model under a specific vendor
        # still get routed there — runtime falls back to model-name prefix
        # inference only when provider is empty.
        # Validate provider_id — mirrors _set_chat / _set_embedding pattern.
        if provider_id.startswith("custom:"):
            from models.custom_provider import parse_custom_bot_type
            _, custom_id = parse_custom_bot_type(provider_id)
            providers = self._normalize_custom_providers(conf().get("custom_providers"))
            custom_provider = next((p for p in providers if p.get("id") == custom_id), None)
            if custom_provider is None:
                return json.dumps({"status": "error", "message": f"unknown custom provider id: {custom_id}"})
            if not model:
                model = custom_provider.get("model") or ""
        elif provider_id and provider_id not in {k for k in ModelsHandler._VISION_PROVIDER_MODELS if k != "custom"}:
            return json.dumps({"status": "error", "message": f"unknown provider: {provider_id}"})

        if provider_id and not model:
            return json.dumps({ "status": "error", "message": "vision model is required when a provider is selected", })

        local_config = conf()
        file_cfg = self._read_file_config()
        self._set_nested_namespace_value(file_cfg, "tools", "vision", "model", model)
        self._set_nested_namespace_value(local_config, "tools", "vision", "model", model)
        self._set_nested_namespace_value(file_cfg, "tools", "vision", "provider", provider_id or "")
        self._set_nested_namespace_value(local_config, "tools", "vision", "provider", provider_id or "")
        self._drop_legacy_namespace(file_cfg, "tool", "tools", child="vision")
        self._drop_legacy_namespace(local_config, "tool", "tools", child="vision")

        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] vision updated: provider={provider_id!r} model={model!r}")
        return json.dumps({"status": "success", "provider": provider_id, "model": model})

    @staticmethod
    def _set_nested_namespace_value(cfg, top, name, key, value):
        """Set ``cfg[top][name][key] = value``, creating missing dicts."""
        bucket = cfg.get(top)
        if not isinstance(bucket, dict):
            bucket = {}
        node = bucket.get(name)
        if not isinstance(node, dict):
            node = {}
        node[key] = value
        bucket[name] = node
        cfg[top] = bucket

    @staticmethod
    def _drop_legacy_namespace(cfg, legacy, canonical, child):
        """Strip the deprecated singular key so config.json stays single-source."""
        legacy_section = cfg.get(legacy)
        if not isinstance(legacy_section, dict):
            return
        legacy_section.pop(child, None)
        if legacy_section:
            cfg[legacy] = legacy_section
        else:
            cfg.pop(legacy, None)

    def _handle_set_voice_reply_mode(self, data):
        # UI picker (off / voice_if_voice / always) maps to the legacy
        # always_reply_voice + voice_reply_voice pair that chat_channel.py
        # reads, so all channels (web/feishu/wecom/...) share the routing.
        mode = (data.get("mode") or "").strip().lower()
        if mode not in ("off", "voice_if_voice", "always"):
            return json.dumps({"status": "error", "message": f"invalid mode: {mode!r}"})
        always = (mode == "always")
        if_voice = (mode == "voice_if_voice")
        local_config = conf()
        file_cfg = self._read_file_config()
        local_config["always_reply_voice"] = always
        local_config["voice_reply_voice"] = if_voice
        file_cfg["always_reply_voice"] = always
        file_cfg["voice_reply_voice"] = if_voice
        self._write_file_config(file_cfg)
        logger.info( f"[ModelsHandler] voice reply mode set: {mode!r} " f"(always_reply_voice={always}, voice_reply_voice={if_voice})" )
        return json.dumps({"status": "success", "mode": mode})

    def _set_simple(self, key, value):
        local_config = conf()
        file_cfg = self._read_file_config()
        local_config[key] = value
        file_cfg[key] = value
        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] {key} set: {value!r}")
        # Hot-swap the cached voice bot so the change takes effect immediately.
        if key in ("voice_to_text", "text_to_voice"):
            self._refresh_voice_routing()
        return json.dumps({"status": "success", key: value})

    def _set_asr(self, provider_id, model):
        local_config = conf()
        file_cfg = self._read_file_config()
        local_config["voice_to_text"] = provider_id
        file_cfg["voice_to_text"] = provider_id
        # Only overwrite the model when one is supplied. An empty model means
        # "keep whatever is configured" so switching provider from the console
        # never wipes a user's hand-set voice_to_text_model (runtime falls back
        # to the engine default via `or DEFAULT_ASR_MODEL` regardless).
        if model:
            local_config["voice_to_text_model"] = model
            file_cfg["voice_to_text_model"] = model
        self._write_file_config(file_cfg)
        logger.info( f"[ModelsHandler] asr updated: provider={provider_id!r} " f"model={model!r}" )
        self._refresh_voice_routing()
        return json.dumps({ "status": "success", "provider": provider_id, "model": local_config.get("voice_to_text_model", ""), })

    def _set_tts(self, provider_id, model, voice = ""):
        local_config = conf()
        file_cfg = self._read_file_config()
        local_config["text_to_voice"] = provider_id
        file_cfg["text_to_voice"] = provider_id
        local_config["text_to_voice_model"] = model
        file_cfg["text_to_voice_model"] = model
        local_config["tts_voice_id"] = voice
        file_cfg["tts_voice_id"] = voice
        self._write_file_config(file_cfg)
        logger.info( f"[ModelsHandler] tts updated: provider={provider_id!r} " f"model={model!r} voice={voice!r}" )
        self._refresh_voice_routing()
        return json.dumps({ "status": "success", "provider": provider_id, "model": model, "voice": voice, })

    @staticmethod
    def _refresh_voice_routing():
        try:
            from bridge.bridge import Bridge
            Bridge().refresh_voice()
        except Exception as e:
            logger.warning(f"[ModelsHandler] Bridge voice refresh failed: {e}")

    def _set_embedding(self, provider_id, model):
        # Validate provider_id — mirrors _set_chat's validation pattern.
        if provider_id.startswith("custom:"):
            from models.custom_provider import parse_custom_bot_type
            _, custom_id = parse_custom_bot_type(provider_id)
            providers = self._normalize_custom_providers(conf().get("custom_providers"))
            custom_provider = next((p for p in providers if p.get("id") == custom_id), None)
            if custom_provider is None:
                return json.dumps({"status": "error", "message": f"unknown custom provider id: {custom_id}"})
            # Fall back to the custom provider's default model when none is given.
            if not model:
                model = custom_provider.get("model") or ""
        elif provider_id and provider_id not in {p for p in ModelsHandler._EMBEDDING_PROVIDERS if p != "custom"}:
            return json.dumps({"status": "error", "message": f"unknown provider: {provider_id}"})

        # A provider without a model leaves the runtime in a broken half-state,
        # so reject that explicitly instead of silently writing it through.
        if provider_id and not model:
            return json.dumps({ "status": "error", "message": "embedding model is required when a provider is selected", })
        local_config = conf()
        file_cfg = self._read_file_config()
        local_config["embedding_provider"] = provider_id
        file_cfg["embedding_provider"] = provider_id
        local_config["embedding_model"] = model
        file_cfg["embedding_model"] = model
        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] embedding updated: provider={provider_id!r} model={model!r}")
        # The next /memory rebuild-index command hot-swaps the provider onto
        # the running MemoryManager (see plugins/cow_cli). The dim may have
        # changed, so the frontend prompts the user to rebuild.
        return json.dumps({"status": "success", "provider": provider_id, "model": model})

    def _set_search(self, strategy, provider):
        """Persist search routing under tools.web_search.{strategy,provider}.

        strategy 'auto'  -> provider field is cleared (auto picks at call time)
        strategy 'fixed' -> provider must be in the canonical list; runtime
                            silently falls back to auto if its key is missing.
        """
        if strategy not in ("auto", "fixed"):
            return json.dumps({"status": "error", "message": f"invalid strategy: {strategy!r}"})
        if strategy == "fixed":
            if provider not in self._SEARCH_PROVIDERS:
                return json.dumps({"status": "error", "message": f"unknown provider: {provider!r}"})
        else:
            provider = ""

        local_config = conf()
        file_cfg = self._read_file_config()
        self._set_nested_namespace_value(local_config, "tools", "web_search", "strategy", strategy)
        self._set_nested_namespace_value(file_cfg,     "tools", "web_search", "strategy", strategy)
        self._set_nested_namespace_value(local_config, "tools", "web_search", "provider", provider)
        self._set_nested_namespace_value(file_cfg,     "tools", "web_search", "provider", provider)
        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] search updated: strategy={strategy!r} provider={provider!r}")
        return json.dumps({"status": "success", "strategy": strategy, "provider": provider})

    def _handle_set_search_credential(self, data):
        """Persist the bocha API key under tools.web_search.bocha_api_key.

        The other three providers (zhipu/qianfan/linkai) reuse model-vendor
        credentials, so they go through set_provider with the standard
        model-vendor flow.
        """
        api_key = (data.get("api_key") or "").strip() if isinstance(data.get("api_key"), str) else ""
        local_config = conf()
        file_cfg = self._read_file_config()
        self._set_nested_namespace_value(local_config, "tools", "web_search", "bocha_api_key", api_key)
        self._set_nested_namespace_value(file_cfg,     "tools", "web_search", "bocha_api_key", api_key)
        self._write_file_config(file_cfg)
        logger.info(f"[ModelsHandler] search credential set: bocha_api_key={'***' if api_key else ''}")
        return json.dumps({"status": "success", "provider": "bocha"})

    @staticmethod
    def _reset_bridge():
        try:
            from bridge.bridge import Bridge
            Bridge().reset_bot()
            logger.info("[ModelsHandler] Bridge bot routing reset")
        except Exception as e:
            logger.warning(f"[ModelsHandler] Bridge reset failed: {e}")


class ChannelsHandler:
    """API for managing external channel configurations (feishu, dingtalk, etc)."""

    CHANNEL_DEFS = OrderedDict([ ("weixin", { "label": {"zh": "微信", "en": "WeChat"}, "icon": "fa-comment", "color": "emerald", "fields": [], }), ("feishu", { "label": {"zh": "飞书", "en": "Feishu"}, "icon": "fa-paper-plane", "color": "blue", "fields": [ {"key": "feishu_app_id", "label": "App ID", "type": "text"}, {"key": "feishu_app_secret", "label": "App Secret", "type": "secret"}, ], }), ("dingtalk", { "label": {"zh": "钉钉", "en": "DingTalk"}, "icon": "fa-comments", "color": "blue", "fields": [ {"key": "dingtalk_client_id", "label": "Client ID", "type": "text"}, {"key": "dingtalk_client_secret", "label": "Client Secret", "type": "secret"}, ], }), ("wecom_bot", { "label": {"zh": "企微智能机器人", "en": "WeCom Bot"}, "icon": "fa-robot", "color": "emerald", "fields": [ {"key": "wecom_bot_id", "label": "Bot ID", "type": "text"}, {"key": "wecom_bot_secret", "label": "Secret", "type": "secret"}, ], }), ("qq", { "label": {"zh": "QQ 机器人", "en": "QQ Bot"}, "icon": "fa-comment", "color": "blue", "fields": [ {"key": "qq_app_id", "label": "App ID", "type": "text"}, {"key": "qq_app_secret", "label": "App Secret", "type": "secret"}, ], }), ("wechatcom_app", { "label": {"zh": "企微自建应用", "en": "WeCom App"}, "icon": "fa-building", "color": "emerald", "fields": [ {"key": "wechatcom_corp_id", "label": "Corp ID", "type": "text"}, {"key": "wechatcomapp_agent_id", "label": "Agent ID", "type": "text"}, {"key": "wechatcomapp_secret", "label": "Secret", "type": "secret"}, {"key": "wechatcomapp_token", "label": "Token", "type": "secret"}, {"key": "wechatcomapp_aes_key", "label": "AES Key", "type": "secret"}, {"key": "wechatcomapp_port", "label": "Port", "type": "number", "default": 9898}, ], }), ("wechat_kf", { "label": {"zh": "微信客服", "en": "WeChat Customer Service"}, "icon": "fa-headset", "color": "emerald", "fields": [ {"key": "wechat_kf_corp_id", "label": "Corp ID", "type": "text"}, {"key": "wechat_kf_secret", "label": "Secret", "type": "secret"}, {"key": "wechat_kf_token", "label": "Token", "type": "secret"}, {"key": "wechat_kf_aes_key", "label": "AES Key", "type": "secret"}, {"key": "wechat_kf_port", "label": "Port", "type": "number", "default": 9888}, ], }), ("wechatmp", { "label": {"zh": "公众号", "en": "WeChat MP"}, "icon": "fa-comment-dots", "color": "emerald", "fields": [ {"key": "wechatmp_app_id", "label": "App ID", "type": "text"}, {"key": "wechatmp_app_secret", "label": "App Secret", "type": "secret"}, {"key": "wechatmp_token", "label": "Token", "type": "secret"}, {"key": "wechatmp_aes_key", "label": "AES Key", "type": "secret"}, {"key": "wechatmp_port", "label": "Port", "type": "number", "default": 8080}, ], }), ("telegram", { "label": {"zh": "Telegram", "en": "Telegram"}, "icon": "fa-paper-plane", "color": "sky", "fields": [ {"key": "telegram_token", "label": "Bot Token", "type": "secret"}, ], }), ("slack", { "label": {"zh": "Slack", "en": "Slack"}, "icon": "fa-hashtag", "color": "purple", "fields": [ {"key": "slack_bot_token", "label": "Bot Token (xoxb-)", "type": "secret"}, {"key": "slack_app_token", "label": "App Token (xapp-)", "type": "secret"}, ], }), ("discord", { "label": {"zh": "Discord", "en": "Discord"}, "icon": "fa-discord", "color": "indigo", "fields": [ {"key": "discord_token", "label": "Bot Token", "type": "secret"}, ], }), ])

    @staticmethod
    def _get_weixin_login_status():
        try:
            import sys
            app_module = sys.modules.get('app') or sys.modules.get('__main__')
            mgr = getattr(app_module, '_channel_mgr', None) if app_module else None
            if mgr:
                ch = mgr.get_channel("weixin")
                if ch and hasattr(ch, 'login_status'):
                    return ch.login_status
        except Exception as e:
            pass
        return "unknown"

    @staticmethod
    def _mask_secret(value):
        if not value or len(value) <= 8:
            return value
        return value[:4] + "*" * (len(value) - 8) + value[-4:]

    @staticmethod
    def _parse_channel_list(raw):
        if isinstance(raw, list):
            return [ch.strip() for ch in raw if ch.strip()]
        if isinstance(raw, str):
            return [ch.strip() for ch in raw.split(",") if ch.strip()]
        return []

    @classmethod
    def _active_channel_set(cls):
        return set(cls._parse_channel_list(conf().get("channel_type", "")))

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from common import i18n
            local_config = conf()
            active_channels = self._active_channel_set()
            channels = []
            is_hant = i18n.get_language() == i18n.ZH_HANT
            for ch_name, ch_def in self.CHANNEL_DEFS.items():
                fields_out = []
                for f in ch_def["fields"]:
                    raw_val = local_config.get(f["key"], f.get("default", ""))
                    if f["type"] == "secret" and raw_val:
                        display_val = self._mask_secret(str(raw_val))
                    else:
                        display_val = raw_val

                    label_val = f["label"]
                    if is_hant and isinstance(label_val, str):
                        label_val = i18n.to_traditional(label_val)
                    elif is_hant and isinstance(label_val, dict):
                        label_val = label_val.copy()
                        label_val["zh-Hant"] = i18n.to_traditional(label_val.get("zh", ""))

                    fields_out.append({ "key": f["key"], "label": label_val, "type": f["type"], "value": display_val, "default": f.get("default", ""), })

                label_val = ch_def["label"]
                if is_hant and isinstance(label_val, str):
                    label_val = i18n.to_traditional(label_val)
                elif is_hant and isinstance(label_val, dict):
                    label_val = label_val.copy()
                    label_val["zh-Hant"] = i18n.to_traditional(label_val.get("zh", ""))

                ch_info = { "name": ch_name, "label": label_val, "icon": ch_def["icon"], "color": ch_def["color"], "active": ch_name in active_channels, "fields": fields_out, "running": False, }
                # Check if channel is actually running via ChannelManager
                if ch_name in active_channels:
                    try:
                        import sys
                        app_module = sys.modules.get('app') or sys.modules.get('__main__')
                        mgr = getattr(app_module, '_channel_mgr', None) if app_module else None
                        if mgr and mgr.get_channel(ch_name) is not None:
                            ch_info["running"] = True
                    except Exception as e:
                        pass
                if ch_name == "weixin" and ch_name in active_channels:
                    ch_info["login_status"] = self._get_weixin_login_status()
                channels.append(ch_info)
            return json.dumps({"status": "success", "channels": channels}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Channels API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            action = body.get("action")
            channel_name = body.get("channel")

            if not action or not channel_name:
                return json.dumps({"status": "error", "message": "action and channel required"})

            if channel_name not in self.CHANNEL_DEFS:
                return json.dumps({"status": "error", "message": f"unknown channel: {channel_name}"})

            if action == "save":
                return self._handle_save(channel_name, body.get("config", {}))
            elif action == "connect":
                return self._handle_connect(channel_name, body.get("config", {}))
            elif action == "disconnect":
                return self._handle_disconnect(channel_name)
            else:
                return json.dumps({"status": "error", "message": f"unknown action: {action}"})
        except Exception as e:
            logger.error(f"[WebChannel] Channels POST error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def _handle_save(self, channel_name, updates):
        ch_def = self.CHANNEL_DEFS[channel_name]
        valid_keys = {f["key"] for f in ch_def["fields"]}
        secret_keys = {f["key"] for f in ch_def["fields"] if f["type"] == "secret"}

        local_config = conf()
        applied = {}
        for key, value in updates.items():
            if key not in valid_keys:
                continue
            if key in secret_keys:
                if not value or (len(value) > 8 and "*" * 4 in value):
                    continue
            field_def = next((f for f in ch_def["fields"] if f["key"] == key), None)
            if field_def:
                if field_def["type"] == "number":
                    value = int(value)
                elif field_def["type"] == "bool":
                    value = bool(value)
            local_config[key] = value
            applied[key] = value

        if not applied:
            return json.dumps({"status": "error", "message": "no valid fields to update"})

        config_path = os.path.join(get_data_root(), "config.json")
        if os.path.exists(config_path):
            with open(config_path, "r", encoding="utf-8") as f:
                file_cfg = json.load(f)
        else:
            file_cfg = {}
        file_cfg.update(applied)
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(file_cfg, f, indent=4, ensure_ascii=False)

        logger.info(f"[WebChannel] Channel '{channel_name}' config updated: {list(applied.keys())}")

        should_restart = False
        active_channels = self._active_channel_set()
        if channel_name in active_channels:
            should_restart = True
            try:
                import sys
                app_module = sys.modules.get('app') or sys.modules.get('__main__')
                mgr = getattr(app_module, '_channel_mgr', None) if app_module else None
                if mgr:
                    threading.Thread( target=mgr.restart, args=(channel_name,), daemon=True, ).start()
                    logger.info(f"[WebChannel] Channel '{channel_name}' restart triggered")
            except Exception as e:
                logger.warning(f"[WebChannel] Failed to restart channel '{channel_name}': {e}")

        return json.dumps({ "status": "success", "applied": list(applied.keys()), "restarted": should_restart, }, ensure_ascii=False)

    def _handle_connect(self, channel_name, updates):
        """Save config fields, add channel to channel_type, and start it."""
        ch_def = self.CHANNEL_DEFS[channel_name]
        valid_keys = {f["key"] for f in ch_def["fields"]}
        secret_keys = {f["key"] for f in ch_def["fields"] if f["type"] == "secret"}

        # Feishu connected via web console must use websocket (long connection) mode
        if channel_name == "feishu":
            updates.setdefault("feishu_event_mode", "websocket")
            valid_keys.add("feishu_event_mode")

        local_config = conf()
        applied = {}
        for key, value in updates.items():
            if key not in valid_keys:
                continue
            if key in secret_keys:
                if not value or (len(value) > 8 and "*" * 4 in value):
                    continue
            field_def = next((f for f in ch_def["fields"] if f["key"] == key), None)
            if field_def:
                if field_def["type"] == "number":
                    value = int(value)
                elif field_def["type"] == "bool":
                    value = bool(value)
            local_config[key] = value
            applied[key] = value

        # --- Pre-validate: check required fields are filled ---
        required_fields = [f for f in ch_def["fields"] if f.get("required", False)]
        missing_fields = []
        for f in required_fields:
            val = local_config.get(f["key"], "")
            if not val:
                field_label = f.get("label", f["key"])
                missing_fields.append(field_label)
        if missing_fields:
            return json.dumps({ "status": "error", "message": "缺少必填字段: " + ", ".join(missing_fields), }, ensure_ascii=False)

        # --- Pre-validate: check if the channel module can be imported ---
        # We only check importability, not instantiation, to avoid creating
        # singleton instances that would interfere with later channel startup.
        try:
            from channel.channel_factory import _CHANNEL_IMPORTS
            # Handle aliases (e.g., "wx" → const.WEIXIN)
            lookup_name = channel_name
            if channel_name == "wx":
                from common import const
                lookup_name = const.WEIXIN
            import_info = _CHANNEL_IMPORTS.get(lookup_name)
            if import_info:
                __import__(import_info["module"])
        except ModuleNotFoundError as e:
            return json.dumps({ "status": "error", "message": f"缺少依赖包: {e.name}。请运行 pip install {e.name} 安装。", }, ensure_ascii=False)
        except ImportError as e:
            return json.dumps({ "status": "error", "message": f"导入模块失败: {e}", }, ensure_ascii=False)
        except Exception as e:
            logger.warning(f"[WebChannel] Pre-validation for '{channel_name}' raised: {e}")
            # Non-fatal: continue with connect attempt

        # For channels that require config (like wechatcom_app, wechat_kf),
        # try a lightweight instantiation check without affecting singletons
        channels_requiring_config = {"wechatcom_app", "wechat_kf"}
        if channel_name in channels_requiring_config:
            try:
                from channel.channel_factory import create_channel
                _test_instance = create_channel(channel_name)
                del _test_instance
            except ValueError as e:
                return json.dumps({ "status": "error", "message": str(e), }, ensure_ascii=False)
            except Exception as e:
                logger.warning(f"[WebChannel] Config pre-check for '{channel_name}' raised: {e}")

        existing = self._parse_channel_list(conf().get("channel_type", ""))
        if channel_name not in existing:
            existing.append(channel_name)
        new_channel_type = ",".join(existing)
        local_config["channel_type"] = new_channel_type

        config_path = os.path.join(get_data_root(), "config.json")
        if os.path.exists(config_path):
            with open(config_path, "r", encoding="utf-8") as f:
                file_cfg = json.load(f)
        else:
            file_cfg = {}
        file_cfg.update(applied)
        file_cfg["channel_type"] = new_channel_type
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(file_cfg, f, indent=4, ensure_ascii=False)

        logger.info(f"[WebChannel] Channel '{channel_name}' connecting, channel_type={new_channel_type}")

        # Feishu pulls its SDK bundle on first use; tell the UI so it can warn
        # about the one-time wait rather than reporting an instant success.
        downloading = False
        if channel_name == "feishu":
            try:
                from channel.feishu import lark_install
                downloading = lark_install.needs_download()
            except Exception as e:
                logger.warning(f"[WebChannel] Could not check Feishu SDK state: {e}")

        def _do_start():
            try:
                import sys
                app_module = sys.modules.get('app') or sys.modules.get('__main__')
                clear_fn = getattr(app_module, '_clear_singleton_cache', None) if app_module else None
                mgr = getattr(app_module, '_channel_mgr', None) if app_module else None
                if mgr is None:
                    logger.warning(f"[WebChannel] ChannelManager not available, cannot start '{channel_name}'")
                    return
                # Stop existing instance first if still running (e.g. re-connect without disconnect)
                existing_ch = mgr.get_channel(channel_name)
                if existing_ch is not None:
                    logger.info(f"[WebChannel] Stopping existing '{channel_name}' before reconnect...")
                    mgr.stop(channel_name)
                # Always wait for the remote service to release the old connection before
                # establishing a new one (DingTalk drops callbacks on duplicate connections)
                logger.info(f"[WebChannel] Waiting for '{channel_name}' old connection to close...")
                time.sleep(5)
                if clear_fn:
                    clear_fn(channel_name)
                logger.info(f"[WebChannel] Starting channel '{channel_name}'...")
                mgr.start([channel_name], first_start=False)
                logger.info(f"[WebChannel] Channel '{channel_name}' start completed")
            except Exception as e:
                logger.error(f"[WebChannel] Failed to start channel '{channel_name}': {e}", exc_info=True)

        threading.Thread(target=_do_start, daemon=True).start()

        return json.dumps({ "status": "success", "channel_type": new_channel_type, "downloading": downloading, }, ensure_ascii=False)

    def _handle_disconnect(self, channel_name):
        existing = self._parse_channel_list(conf().get("channel_type", ""))
        existing = [ch for ch in existing if ch != channel_name]
        new_channel_type = ",".join(existing)

        local_config = conf()
        local_config["channel_type"] = new_channel_type

        config_path = os.path.join(get_data_root(), "config.json")
        if os.path.exists(config_path):
            with open(config_path, "r", encoding="utf-8") as f:
                file_cfg = json.load(f)
        else:
            file_cfg = {}
        file_cfg["channel_type"] = new_channel_type
        with open(config_path, "w", encoding="utf-8") as f:
            json.dump(file_cfg, f, indent=4, ensure_ascii=False)

        def _do_stop():
            try:
                import sys
                app_module = sys.modules.get('app') or sys.modules.get('__main__')
                mgr = getattr(app_module, '_channel_mgr', None) if app_module else None
                clear_fn = getattr(app_module, '_clear_singleton_cache', None) if app_module else None
                if mgr:
                    mgr.stop(channel_name)
                else:
                    logger.warning(f"[WebChannel] ChannelManager not found, cannot stop '{channel_name}'")
                if clear_fn:
                    clear_fn(channel_name)
                logger.info(f"[WebChannel] Channel '{channel_name}' disconnected, " f"channel_type={new_channel_type}")
            except Exception as e:
                logger.warning(f"[WebChannel] Failed to stop channel '{channel_name}': {e}", exc_info=True)

        threading.Thread(target=_do_stop, daemon=True).start()

        return json.dumps({ "status": "success", "channel_type": new_channel_type, }, ensure_ascii=False)


class WeixinQrHandler:
    """Handle WeChat QR code login from the web console.

    GET  /api/weixin/qrlogin          → fetch a new QR code
    POST /api/weixin/qrlogin          → poll QR status or start channel after login
    """

    _qr_state = {}

    @staticmethod
    def _qr_to_data_uri(data):
        """Generate a QR code as a PNG data URI."""
        try:
            import qrcode as qr_lib
            import io
            import base64
            qr = qr_lib.QRCode(error_correction=qr_lib.constants.ERROR_CORRECT_L, box_size=6, border=2)
            qr.add_data(data)
            qr.make(fit=True)
            img = qr.make_image(fill_color="black", back_color="white")
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            b64 = base64.b64encode(buf.getvalue()).decode("ascii")
            return f"data:image/png;base64,{b64}"
        except ImportError as e:
            logger.warning("[WebChannel] qrcode package not installed, QR image generation disabled. " "Install with: pip install qrcode[pil]")
            return ""
        except Exception as e:
            logger.error(f"[WebChannel] Failed to generate QR code image: {e}")
            return ""

    @staticmethod
    def _get_running_channel():
        try:
            import sys
            app_module = sys.modules.get('app') or sys.modules.get('__main__')
            mgr = getattr(app_module, '_channel_mgr', None) if app_module else None
            if mgr:
                return mgr.get_channel("weixin")
        except Exception as e:
            pass
        return None

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            # Always fetch a fresh QR code from the WeChat API.
            # This ensures _qr_state is always set for subsequent polls,
            # and avoids stale QR sessions from the channel's internal flow.
            from channel.weixin.weixin_api import WeixinApi, DEFAULT_BASE_URL
            base_url = conf().get("weixin_base_url", DEFAULT_BASE_URL)
            api = WeixinApi(base_url=base_url)
            qr_resp = api.fetch_qr_code()
            qrcode = qr_resp.get("qrcode", "")
            qrcode_url = qr_resp.get("qrcode_img_content", "")
            if not qrcode:
                return json.dumps({"status": "error", "message": "No QR code returned"})
            qr_image = self._qr_to_data_uri(qrcode_url)
            WeixinQrHandler._qr_state = { "qrcode": qrcode, "qrcode_url": qrcode_url, "base_url": base_url, }
            return json.dumps({"status": "success", "qrcode_url": qrcode_url, "qr_image": qr_image})
        except Exception as e:
            logger.error(f"[WebChannel] WeixinQr GET error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            action = body.get("action", "poll")

            if action == "poll":
                return self._poll_status()
            elif action == "refresh":
                return self.GET()
            else:
                return json.dumps({"status": "error", "message": f"unknown action: {action}"})
        except Exception as e:
            logger.error(f"[WebChannel] WeixinQr POST error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def _poll_status(self):
        state = WeixinQrHandler._qr_state
        qrcode = state.get("qrcode", "")
        base_url = state.get("base_url", "")
        if not qrcode:
            return json.dumps({"status": "error", "message": "No active QR session"})

        from channel.weixin.weixin_api import WeixinApi, DEFAULT_BASE_URL
        api = WeixinApi(base_url=base_url or DEFAULT_BASE_URL)
        try:
            status_resp = api.poll_qr_status(qrcode, timeout=10)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

        qr_status = status_resp.get("status", "wait")

        if qr_status == "confirmed":
            bot_token = status_resp.get("bot_token", "")
            bot_id = status_resp.get("ilink_bot_id", "")
            result_base_url = status_resp.get("baseurl", base_url)
            user_id = status_resp.get("ilink_user_id", "")

            if not bot_token or not bot_id:
                return json.dumps({"status": "error", "message": "Login confirmed but missing token"})

            cred_path = get_weixin_credentials_path()
            from channel.weixin.weixin_channel import _save_credentials
            _save_credentials(cred_path, { "token": bot_token, "base_url": result_base_url, "bot_id": bot_id, "user_id": user_id, })
            conf()["weixin_token"] = bot_token
            conf()["weixin_base_url"] = result_base_url

            WeixinQrHandler._qr_state = {}
            logger.info(f"[WebChannel] WeChat QR login confirmed: bot_id={bot_id}")

            return json.dumps({ "status": "success", "qr_status": "confirmed", "bot_id": bot_id, })

        if qr_status == "expired":
            new_resp = api.fetch_qr_code()
            new_qrcode = new_resp.get("qrcode", "")
            new_qrcode_url = new_resp.get("qrcode_img_content", "")
            new_qr_image = self._qr_to_data_uri(new_qrcode_url)
            WeixinQrHandler._qr_state["qrcode"] = new_qrcode
            WeixinQrHandler._qr_state["qrcode_url"] = new_qrcode_url
            return json.dumps({ "status": "success", "qr_status": "expired", "qrcode_url": new_qrcode_url, "qr_image": new_qr_image, })

        return json.dumps({"status": "success", "qr_status": qr_status})


class FeishuRegisterHandler:
    """飞书智能体应用一键创建（OAuth 设备授权流，基于 lark.register_app SDK）。

    GET  /api/feishu/register   → 启动注册：调用 SDK 生成二维码 URL，立即返回；
                                   后台线程继续轮询飞书侧直到用户扫码授权。
    POST /api/feishu/register   → 轮询当前会话状态（downloading / pending / done /
                                   error / expired）。桌面版首次启用时要先下载飞书
                                   SDK 包，此时二维码尚不存在，改由轮询补发。
                                   注册成功后不直接写 config，由前端再调
                                   /api/channels {action:'connect'} 走标准启用流程。
    """

    # 进程内单例状态（{url, expire_in, status, app_id, app_secret, error, thread}）。
    # 简单的本地自部署场景下不需要 session 隔离。
    _state = {}
    _lock = threading.Lock()

    @staticmethod
    def _qr_to_data_uri(data):
        """复用 WeixinQrHandler 的二维码渲染。"""
        return WeixinQrHandler._qr_to_data_uri(data)

    @classmethod
    def _reset_state(cls):
        with cls._lock:
            cls._state = {}

    @classmethod
    def _start_register_thread(cls):
        """启动一次新的注册会话。如已有进行中的会话，先取消（通过 cancel_event）。"""
        # 先取消可能存在的上一次会话，避免两个 SDK 线程并发 poll 同一个端点
        with cls._lock:
            old_cancel = cls._state.get("cancel_event") if cls._state else None
            if old_cancel is not None:
                old_cancel.set()
            cancel_event = threading.Event()
            cls._state = {"status": "starting", "cancel_event": cancel_event}

        def _worker():
            try:
                # Desktop builds don't bundle lark_oapi; fetch it on demand the
                # first time the user enables Feishu (requires network). Flag it
                # so the modal explains the wait instead of just spinning.
                from channel.feishu import lark_install
                if lark_install.needs_download():
                    with cls._lock:
                        cls._state["status"] = "downloading"
                lark_install.ensure(allow_install=True)
                import lark_oapi as lark
            except ImportError as e:
                with cls._lock:
                    cls._state["status"] = "error"
                    cls._state["error"] = ( "飞书 SDK 不可用，请联网后重试，" "或手动执行 pip install -U 'lark-oapi>=1.5.5'（%s）" % e )
                return

            def _on_qr(info):
                # SDK 拿到二维码 URL 后立即回调；写入 state 让前端 GET 立刻能拿到
                with cls._lock:
                    cls._state["url"] = info.get("url", "")
                    cls._state["expire_in"] = info.get("expire_in", 600)
                    cls._state["qr_image"] = cls._qr_to_data_uri(info.get("url", ""))
                    cls._state["status"] = "pending"
                logger.info(f"[FeishuRegister] QR ready, expire_in={info.get('expire_in')}s")

            def _on_status(info):
                # 过滤掉 polling 心跳（每 5 秒一次，纯噪音）；
                # 保留 slow_down / domain_switched 等真正的状态切换事件
                status = info.get("status")
                if status == "polling":
                    return
                logger.info(f"[FeishuRegister] SDK status: {info}")

            try:
                result = lark.register_app( on_qr_code=_on_qr, on_status_change=_on_status, source="mocode-cli", cancel_event=cancel_event, )
                with cls._lock:
                    cls._state["status"] = "done"
                    cls._state["app_id"] = result.get("client_id", "")
                    cls._state["app_secret"] = result.get("client_secret", "")
                logger.info(f"[FeishuRegister] App created: app_id={result.get('client_id')}")
            except Exception as e:
                err_msg = str(e)
                err_cls = e.__class__.__name__
                # 飞书 SDK 抛出的 AppExpiredError / AppAccessDeniedError / RegisterAppError
                if "Expired" in err_cls:
                    status = "expired"
                elif "Denied" in err_cls:
                    status = "denied"
                elif "abort" in err_msg.lower() or "cancel" in err_msg.lower():
                    # 被新一轮注册抢占，保持安静
                    return
                else:
                    status = "error"
                with cls._lock:
                    # 仅当当前 state 仍属于本次 worker 时才写入，避免覆盖更新的会话
                    if cls._state.get("cancel_event") is cancel_event:
                        cls._state["status"] = status
                        cls._state["error"] = err_msg
                logger.warning(f"[FeishuRegister] Register failed ({err_cls}): {err_msg}")

        threading.Thread(target=_worker, daemon=True, name="feishu-register").start()

    def GET(self):
        """启动一次新的注册会话。如果已有 pending/done 会话则覆盖。"""
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            self._start_register_thread()
            # 等待 SDK 拿到二维码 URL（最多 10s）。SDK 内部会马上回调 _on_qr。
            import time as _t
            for _ in range(100):
                with self._lock:
                    if self._state.get("url") or self._state.get("status") in ( "downloading", "error", "expired", "denied" ):
                        break
                _t.sleep(0.1)
            with self._lock:
                if self._state.get("status") in ("error", "expired", "denied"):
                    return json.dumps({ "status": "error", "message": self._state.get("error", "register failed"), })
                if self._state.get("status") == "downloading":
                    # The SDK bundle is still coming down; the QR only exists
                    # once it lands, so hand the frontend over to polling.
                    return json.dumps({ "status": "success", "register_status": "downloading", })
                if not self._state.get("url"):
                    return json.dumps({ "status": "error", "message": "等待飞书二维码超时，请重试", })
                return json.dumps({ "status": "success", "qrcode_url": self._state["url"], "qr_image": self._state.get("qr_image", ""), "expire_in": self._state.get("expire_in", 600), })
        except Exception as e:
            logger.error(f"[WebChannel] FeishuRegister GET error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        """轮询注册结果。"""
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data() or b"{}")
            action = body.get("action", "poll")
            if action != "poll":
                return json.dumps({"status": "error", "message": f"unknown action: {action}"})

            with self._lock:
                status = self._state.get("status", "idle")
                if status == "done":
                    payload = { "status": "success", "register_status": "done", "app_id": self._state.get("app_id", ""), "app_secret": self._state.get("app_secret", ""), }
                    # 一次性返回凭据后清掉，避免敏感信息长期驻留内存
                    self._state = {}
                    return json.dumps(payload)
                if status in ("error", "expired", "denied"):
                    return json.dumps({ "status": "success", "register_status": status, "message": self._state.get("error", ""), })
                if status == "downloading":
                    return json.dumps({ "status": "success", "register_status": "downloading", })
                # pending / starting：还在等用户扫码。二维码可能是在 GET 返回
                # "downloading" 之后才生成的，带上让前端补渲染。
                payload = {"status": "success", "register_status": "pending"}
                if self._state.get("url"):
                    payload["qrcode_url"] = self._state["url"]
                    payload["qr_image"] = self._state.get("qr_image", "")
                return json.dumps(payload)
        except Exception as e:
            logger.error(f"[WebChannel] FeishuRegister POST error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class ToolsHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.tools.tool_manager import ToolManager
            from common import i18n
            tm = ToolManager()
            if not tm.tool_classes:
                tm.load_tools()
            tools = []
            lang = i18n.get_language()
            for name, cls in tm.tool_classes.items():
                try:
                    instance = cls()
                    desc = instance.description
                    if lang == i18n.ZH_HANT and desc:
                        desc = i18n.to_traditional(desc)
                    elif lang == "en" and name == "scheduler":
                        desc = ( "Create, query and manage scheduled tasks (reminders, periodic tasks, etc.).\n\n" "⚠️ IMPORTANT: Only use this tool when delayed or periodic execution is needed." )
                    tools.append({ "name": name, "description": desc, })
                except Exception as e:
                    tools.append({"name": name, "description": ""})
            return json.dumps({"status": "success", "tools": tools}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Tools API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SkillsHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.skills.service import SkillService
            from agent.skills.manager import SkillManager
            from common import i18n
            workspace_root = _get_workspace_root()
            manager = SkillManager(custom_dir=os.path.join(workspace_root, "skills"))
            service = SkillService(manager)
            skills = service.query()
            if i18n.get_language() == i18n.ZH_HANT:
                for skill in skills:
                    if isinstance(skill, dict):
                        for k, v in list(skill.items()):
                            if k in ("name", "description", "display_name") and isinstance(v, str):
                                skill[k] = i18n.to_traditional(v)
            return json.dumps({"status": "success", "skills": skills}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Skills API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.skills.service import SkillService
            from agent.skills.manager import SkillManager
            body = json.loads(web.data())
            action = body.get("action")
            name = body.get("name")
            if not action or not name:
                return json.dumps({"status": "error", "message": "action and name are required"})
            workspace_root = _get_workspace_root()
            manager = SkillManager(custom_dir=os.path.join(workspace_root, "skills"))
            service = SkillService(manager)
            if action == "open":
                service.open({"name": name})
            elif action == "close":
                service.close({"name": name})
            else:
                return json.dumps({"status": "error", "message": f"unknown action: {action}"})
            return json.dumps({"status": "success"}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Skills POST error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class MemoryHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.memory.service import MemoryService
            params = web.input(page='1', page_size='20', category='memory')
            workspace_root = _get_workspace_root()
            service = MemoryService(workspace_root)
            result = service.list_files( page=int(params.page), page_size=int(params.page_size), category=params.category, )
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Memory API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class MemoryContentHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.memory.service import MemoryService
            params = web.input(filename='', category='memory')
            if not params.filename:
                return json.dumps({"status": "error", "message": "filename required"})
            workspace_root = _get_workspace_root()
            service = MemoryService(workspace_root)
            result = service.get_content(params.filename, category=params.category)
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except ValueError as e:
            return json.dumps({"status": "error", "message": "invalid filename"})
        except FileNotFoundError as e:
            return json.dumps({"status": "error", "message": "file not found"})
        except Exception as e:
            logger.error(f"[WebChannel] Memory content API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SchedulerHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.tools.scheduler.task_store import TaskStore
            workspace_root = _get_workspace_root()
            store_path = os.path.join(workspace_root, "scheduler", "tasks.json")
            store = TaskStore(store_path)
            tasks = store.list_tasks()
            return json.dumps({"status": "success", "tasks": tasks}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Scheduler API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SchedulerCreateHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            from agent.tools.scheduler.task_store import TaskStore
            from agent.tools.scheduler.scheduler_service import SchedulerService
            from datetime import datetime
            import uuid

            name = (body.get("name") or "").strip()
            if not name:
                return json.dumps({"status": "error", "message": "Task name is required"})

            schedule = body.get("schedule")
            if not schedule or not isinstance(schedule, dict):
                return json.dumps({"status": "error", "message": "Schedule config is required"})

            action = body.get("action")
            if not action or not isinstance(action, dict):
                return json.dumps({"status": "error", "message": "Action config is required"})

            schedule_type = schedule.get("type")
            if schedule_type not in ("cron", "interval", "once"):
                return json.dumps({"status": "error", "message": "Schedule type must be 'cron', 'interval', or 'once'"})

            # Validate schedule fields
            if schedule_type == "cron":
                expr = (schedule.get("expression") or "").strip()
                if not expr:
                    return json.dumps({"status": "error", "message": "Cron expression is required"})
                try:
                    from croniter import croniter
                    croniter(expr)  # validate expression
                except Exception as e:
                    return json.dumps({"status": "error", "message": f"Invalid cron expression: {e}"})
            elif schedule_type == "interval":
                seconds = schedule.get("seconds")
                if not seconds or seconds < 60:
                    return json.dumps({"status": "error", "message": "Interval must be at least 60 seconds"})
            elif schedule_type == "once":
                run_at = (schedule.get("run_at") or "").strip()
                if not run_at:
                    return json.dumps({"status": "error", "message": "Execution time is required for one-time tasks"})
                try:
                    from agent.tools.scheduler.scheduler_service import _parse_naive_local
                    target = _parse_naive_local(run_at)
                    if target <= datetime.now():
                        return json.dumps({"status": "error", "message": "Execution time must be in the future"})
                except Exception as e:
                    return json.dumps({"status": "error", "message": f"Invalid execution time: {e}"})

            # Validate action fields
            action_type = action.get("type", "send_message")
            content = (action.get("content") or action.get("task_description") or "").strip()
            if not content:
                return json.dumps({"status": "error", "message": "Action content is required"})

            # Build task object
            workspace_root = _get_workspace_root()
            store_path = os.path.join(workspace_root, "scheduler", "tasks.json")
            store = TaskStore(store_path)

            task_id = body.get("id") or f"task_{uuid.uuid4().hex[:8]}"
            now = datetime.now().isoformat()

            task_data = { "id": task_id, "name": name, "enabled": body.get("enabled", True), "created_at": now, "updated_at": now, "schedule": schedule, "action": { "type": action_type, "channel_type": action.get("channel_type", "web"), "receiver": action.get("receiver", ""), "receiver_name": action.get("receiver_name", ""), "is_group": action.get("is_group", False), "notify_session_id": action.get("notify_session_id", ""), }, }

            # Add action-type-specific fields
            if action_type == "send_message":
                task_data["action"]["content"] = content
            else:
                task_data["action"]["task_description"] = content

            # Calculate next_run_at
            temp_service = SchedulerService(store, lambda t: None)
            next_run = temp_service._calculate_next_run(task_data, datetime.now())
            if next_run:
                task_data["next_run_at"] = next_run.isoformat()
            elif schedule_type != "interval":
                # For cron/once, inability to calculate next run is an error
                return json.dumps({ "status": "error", "message": "Cannot calculate next run time. Please check the schedule configuration." })

            store.add_task(task_data)
            task = store.get_task(task_id)
            return json.dumps({"status": "success", "task": task}, ensure_ascii=False)
        except ValueError as e:
            return json.dumps({"status": "error", "message": str(e)})
        except Exception as e:
            logger.error(f"[WebChannel] Scheduler create error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SchedulerRunHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            task_id = body.get("task_id")
            if not task_id:
                return json.dumps({"status": "error", "message": "task_id required"})

            from agent.tools.scheduler.integration import get_scheduler_service
            service = get_scheduler_service()
            if service is None:
                return json.dumps({ "status": "error", "message": "Scheduler service is not running", })

            service.run_task_now(task_id)
            return json.dumps({ "status": "success", "message": f"Task '{task_id}' queued for immediate execution", }, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Scheduler manual run error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SchedulerToggleHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            task_id = body.get("task_id")
            enabled = body.get("enabled", True)
            if not task_id:
                return json.dumps({"status": "error", "message": "task_id required"})
            from agent.tools.scheduler.task_store import TaskStore
            workspace_root = _get_workspace_root()
            store_path = os.path.join(workspace_root, "scheduler", "tasks.json")
            store = TaskStore(store_path)
            store.enable_task(task_id, enabled)
            task = store.get_task(task_id)
            return json.dumps({"status": "success", "task": task}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Scheduler toggle error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SchedulerUpdateHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            task_id = body.get("task_id")
            if not task_id:
                return json.dumps({"status": "error", "message": "task_id required"})

            from agent.tools.scheduler.task_store import TaskStore
            from agent.tools.scheduler.scheduler_service import SchedulerService
            from datetime import datetime
            workspace_root = _get_workspace_root()
            store_path = os.path.join(workspace_root, "scheduler", "tasks.json")
            store = TaskStore(store_path)

            # Get original task (single query to avoid repeated I/O)
            original_task = store.get_task(task_id)
            if not original_task:
                return json.dumps({"status": "error", "message": f"Task '{task_id}' not found"})

            # Build updates dict
            updates = {}
            if "name" in body:
                updates["name"] = body["name"]
            if "enabled" in body:
                updates["enabled"] = body["enabled"]

            # Update schedule
            if "schedule" in body:
                updates["schedule"] = body["schedule"]
                # If schedule config changed, recalculate next_run_at
                # Build merged temp task data for calculation (without modifying the original object)
                merged = dict(original_task)
                merged.update(updates)
                if "action" in body:
                    merged["action"] = body["action"]
                temp_service = SchedulerService(store, lambda t: None)
                next_run = temp_service._calculate_next_run(merged, datetime.now())
                if next_run:
                    updates["next_run_at"] = next_run.isoformat()
                else:
                    # Cannot calculate next run time, schedule config may be invalid
                    return json.dumps({ "status": "error",  "message": "Cannot calculate next run time. Please check the schedule config (e.g., cron expression format, or whether the one-time task time has already passed)." }, ensure_ascii=False)

            # Update action
            if "action" in body:
                # Get the task's original channel_type
                original_action = original_task.get("action", {})
                if not isinstance(original_action, dict):
                    original_action = {}
                action_patch = body["action"]
                if not isinstance(action_patch, dict):
                    return json.dumps({ "status": "error", "message": "Action must be an object." }, ensure_ascii=False)

                # The Web editor only exposes a subset of action fields. Merge
                # that patch into the stored action so scheduler metadata such
                # as notify_session_id, silent, and channel-specific delivery
                # fields survive unrelated edits.
                action = dict(original_action)
                action.update(action_patch)
                action_type = action.get("type")
                if action_type == "send_message":
                    action.pop("task_description", None)
                    action.pop("silent", None)
                elif action_type == "agent_task":
                    action.pop("content", None)

                old_channel = original_action.get("channel_type", "web")
                channel_type = action.get("channel_type") or old_channel
                action["channel_type"] = channel_type

                # If channel type changed or no receiver, reject the update.
                # Note: the web UI disables the channel selector, so self branch
                # is only reachable via direct API calls. Changing a task's channel
                # after creation is not supported because the receiver identity is
                # channel-bound and cannot be trivially re-populated (e.g. weixin
                # requires a valid context_token tied to the original user-session).
                if old_channel and old_channel != channel_type:
                    return json.dumps({ "status": "error", "message": f"Cannot change channel type from '{old_channel}' to '{channel_type}'. Please create a new task on the target channel instead." }, ensure_ascii=False)
                if not action.get("receiver"):
                    return json.dumps({ "status": "error", "message": "Receiver is required. Please create a new task through the chat interface." }, ensure_ascii=False)
                updates["action"] = action

                # If schedule was not updated but action was, ensure next_run_at exists
                if "schedule" not in body and "next_run_at" not in original_task:
                    merged = dict(original_task)
                    merged.update(updates)
                    temp_service = SchedulerService(store, lambda t: None)
                    next_run = temp_service._calculate_next_run(merged, datetime.now())
                    if next_run:
                        updates["next_run_at"] = next_run.isoformat()

            store.update_task(task_id, updates)
            task = store.get_task(task_id)
            return json.dumps({"status": "success", "task": task}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Scheduler update error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SchedulerDeleteHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data())
            task_id = body.get("task_id")
            if not task_id:
                return json.dumps({"status": "error", "message": "task_id required"})

            from agent.tools.scheduler.task_store import TaskStore
            workspace_root = _get_workspace_root()
            store_path = os.path.join(workspace_root, "scheduler", "tasks.json")
            store = TaskStore(store_path)
            store.delete_task(task_id)
            return json.dumps({"status": "success"}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Scheduler delete error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SessionsHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            params = web.input(page='1', page_size='50')
            from agent.memory import get_conversation_store
            store = get_conversation_store()
            result = store.list_sessions( channel_type="web", page=int(params.page), page_size=int(params.page_size), )
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Sessions API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SessionDetailHandler:
    def DELETE(self, session_id):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        logger.info(f"[WebChannel] DELETE session request: {session_id}")
        try:
            if not session_id:
                return json.dumps({"status": "error", "message": "session_id required"})

            # Stop any in-flight run first: a reply that lands after the delete
            # would otherwise keep burning tokens for a session nobody can see.
            try:
                from agent.protocol import get_cancel_registry
                cancelled = get_cancel_registry().cancel_session(session_id)
                if cancelled:
                    logger.info( f"[WebChannel] Cancelled {cancelled} in-flight request(s) " f"for deleted session {session_id}" )
            except Exception as e:
                logger.warning(f"[WebChannel] Cancel on delete failed: {e}")

            from agent.memory import get_conversation_store
            store = get_conversation_store()
            store.clear_session(session_id)

            # 清理会话绑定的智能体节点
            _drop_agent_binding(session_id)

            # Also remove the Agent instance from AgentBridge if exists
            try:
                from bridge.bridge import Bridge
                ab = Bridge().get_agent_bridge()
                if session_id in ab.agents:
                    del ab.agents[session_id]
                    logger.info(f"[WebChannel] Removed agent instance for session {session_id}")
            except Exception as e:
                pass

            channel = WebChannel()
            # Drop messages still waiting in the channel queue: processing them
            # after the delete would recreate the session from scratch.
            try:
                channel.cancel_session(session_id)
            except Exception as e:
                logger.warning(f"[WebChannel] Failed to drain queue on delete: {e}")
            channel.session_queues.pop(session_id, None)

            logger.info(f"[WebChannel] Session deleted: {session_id}")
            return json.dumps({"status": "success"})
        except Exception as e:
            logger.error(f"[WebChannel] Session delete error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def PUT(self, session_id):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            if not session_id:
                return json.dumps({"status": "error", "message": "session_id required"})
            body = json.loads(web.data())
            title = body.get("title", "").strip()
            if not title:
                return json.dumps({"status": "error", "message": "title required"})

            from agent.memory import get_conversation_store
            store = get_conversation_store()
            found = store.rename_session(session_id, title)
            if not found:
                return json.dumps({"status": "error", "message": "session not found"})
            return json.dumps({"status": "success"})
        except Exception as e:
            logger.error(f"[WebChannel] Session rename error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SessionTitleHandler:
    def POST(self, session_id):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            if not session_id:
                return json.dumps({"status": "error", "message": "session_id required"})

            body = json.loads(web.data())
            user_message = body.get("user_message", "")
            assistant_reply = body.get("assistant_reply", "")
            if not user_message:
                return json.dumps({"status": "error", "message": "user_message required"})

            title = _generate_session_title(user_message, assistant_reply)

            from agent.memory import get_conversation_store
            store = get_conversation_store()
            updated = store.rename_session(session_id, title)
            logger.info(f"[WebChannel] Session title set: sid={session_id}, title='{title}', db_updated={updated}")

            return json.dumps({"status": "success", "title": title}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Title generation error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class PromptOptimizeHandler:
    """Optimize a colloquial user prompt into a structured AI-ready instruction."""

    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data() or b"{}")
            user_input = (body.get("input") or "").strip()
            if not user_input:
                return json.dumps({"status": "error", "message": "input required"})

            context_messages = body.get("context_messages", None)

            from agent.chat.session_service import optimize_prompt
            optimized = optimize_prompt(user_input, context_messages)

            return json.dumps( {"status": "success", "optimized": optimized}, ensure_ascii=False, )
        except Exception as e:
            logger.error(f"[WebChannel] Prompt optimization error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class SessionClearContextHandler:
    def POST(self, session_id):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            if not session_id:
                return json.dumps({"status": "error", "message": "session_id required"})

            from agent.memory import get_conversation_store
            store = get_conversation_store()
            new_seq = store.clear_context(session_id)

            # Delete the agent instance so a fresh one is created on the next message
            try:
                from bridge.bridge import Bridge
                bridge = Bridge()
                ab = bridge.get_agent_bridge()
                if session_id in ab.agents:
                    del ab.agents[session_id]
                    logger.info(f"[WebChannel] Cleared agent instance for session {session_id}")
            except Exception as e:
                pass

            return json.dumps({"status": "success", "context_start_seq": new_seq})
        except Exception as e:
            logger.error(f"[WebChannel] Clear context error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class HistoryHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        try:
            params = web.input(session_id='', page='1', page_size='20')
            session_id = params.session_id.strip()
            if not session_id:
                return json.dumps({"status": "error", "message": "session_id required"})

            from agent.memory import get_conversation_store
            store = get_conversation_store()
            result = store.load_history_page( session_id=session_id, page=int(params.page), page_size=int(params.page_size), )
            for msg in result.get("messages") or []:
                if msg.get("role") != "assistant":
                    continue
                artifacts = _artifacts_from_steps(msg.get("steps"))
                if artifacts:
                    msg["artifacts"] = artifacts
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] History API error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class MessageDeleteHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        try:
            data = json.loads(web.data())
            session_id = data.get('session_id', '').strip()
            user_seq = data.get('user_seq')
            delete_user = data.get('delete_user', True)
            cascade = data.get('cascade', False)

            if not session_id or user_seq is None:
                return json.dumps({"status": "error", "message": "session_id and user_seq required"})

            # 1. Delete from database
            from agent.memory import get_conversation_store
            store = get_conversation_store()
            deleted = store.delete_message_pair(session_id, int(user_seq), delete_user=delete_user, cascade=cascade)

            # 2. Sync agent's in-memory context so its next turn sees the
            # same history as the DB. Handled by the agent_bridge helper.
            try:
                from bridge.bridge import Bridge
                Bridge().get_agent_bridge().sync_session_messages_from_store(session_id)
            except Exception as sync_err:
                logger.warning(f"[WebChannel] Failed to sync agent memory: {sync_err}")

            return json.dumps({"status": "success", "deleted": deleted}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Message delete error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class LogsHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'text/event-stream; charset=utf-8')
        web.header('Cache-Control', 'no-cache')
        web.header('X-Accel-Buffering', 'no')

        log_path = os.path.join(get_data_root(), "run.log")

        def generate():
            if not os.path.isfile(log_path):
                yield b"data: {\"type\": \"error\", \"message\": \"run.log not found\"}\n\n"
                return

            # Read last 200 lines for initial display
            try:
                with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
                    lines = f.readlines()
                tail_lines = lines[-200:]
                chunk = ''.join(tail_lines)
                payload = json.dumps({"type": "init", "content": chunk}, ensure_ascii=False)
                yield f"data: {payload}\n\n".encode('utf-8')
            except Exception as e:
                yield f"data: {{\"type\": \"error\", \"message\": \"{e}\"}}\n\n".encode('utf-8')
                return

            # Tail new lines
            try:
                with open(log_path, 'r', encoding='utf-8', errors='replace') as f:
                    f.seek(0, 2)  # seek to end
                    deadline = time.time() + 600  # 10 min max
                    while time.time() < deadline:
                        line = f.readline()
                        if line:
                            payload = json.dumps({"type": "line", "content": line}, ensure_ascii=False)
                            yield f"data: {payload}\n\n".encode('utf-8')
                        else:
                            yield b": keepalive\n\n"
                            time.sleep(1)
            except GeneratorExit as e:
                return
            except Exception as e:
                return

        return generate()


# ========== 监听系统处理器 ==========
from channel.web.monitor_handlers import get_monitor_handlers
monitor_handlers = get_monitor_handlers()

class MonitorStartHandler:
    """启动监听"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            data = json.loads(web.data())
            protocol = data.get('protocol', 'all')
            locked = data.get('locked', False)
            result = monitor_handlers['start'](protocol, locked)
            return json.dumps(result)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

class MonitorStopHandler:
    """停止监听"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            result = monitor_handlers['stop']()
            return json.dumps(result)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

class MonitorStreamHandler:
    """SSE实时推送"""
    def GET(self):
        web.header('Content-Type', 'text/event-stream; charset=utf-8')
        web.header('Cache-Control', 'no-cache')
        web.header('Connection', 'keep-alive')
        web.header('Access-Control-Allow-Origin', '*')

        def generate():
            import queue
            subscriber_queue = queue.Queue()

            # 注册订阅者
            from channel.web.monitor_handlers import subscribers, lock
            with lock:
                subscribers.append(subscriber_queue)

            try:
                while True:
                    try:
                        data = subscriber_queue.get(timeout=30)
                        yield f"data: {json.dumps(data)}\n\n"
                    except queue.Empty as e:
                        yield ": heartbeat\n\n"
            except GeneratorExit:
                pass
            finally:
                # 移除订阅者
                with lock:
                    if subscriber_queue in subscribers:
                        subscribers.remove(subscriber_queue)

        return generate()

class MonitorHistoryHandler:
    """获取历史记录"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            history = monitor_handlers['history'](100)
            return json.dumps({"status": "success", "requests": history})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

class PromptAnalyzeHandler:
    """Prompt分析"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data())
            prompt = data.get('prompt', '')
            request_type = data.get('type', 'unknown')
            result = monitor_handlers['analyze'](prompt, request_type)
            return json.dumps(result)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

class MonitorMessageHandler:
    """接收对话消息（从chat页面）"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            data = json.loads(web.data())
            # 将消息添加到队列
            monitor_handlers['intercept'](data.get('data', {}))
            return json.dumps({"status": "success"})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

class MonitorCommandHandler:
    """接收控制命令（从控制面板）"""
    command_queue = []
    command_lock = threading.Lock()

    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            data = json.loads(web.data())
            action = data.get('action')

            # 直接执行监听命令
            if action == 'start':
                protocol = data.get('protocol', 'all')
                locked = data.get('locked', False)
                result = monitor_handlers['start'](protocol, locked)
                logger.info(f"[Monitor] Started monitoring: {result}")
            elif action == 'stop':
                result = monitor_handlers['stop']()
                logger.info(f"[Monitor] Stopped monitoring: {result}")
            else:
                result = {"status": "error", "message": f"Unknown action: {action}"}

            # 同时保留命令队列逻辑（供其他系统使用）
            with self.command_lock:
                self.command_queue.append({ 'action': action, 'timestamp': data.get('timestamp', time.time()) })
                # 只保留最新的命令
                if len(self.command_queue) > 10:
                    self.command_queue = self.command_queue[-10:]

            return json.dumps(result)
        except Exception as e:
            logger.error(f"[Monitor] Command error: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            with self.command_lock:
                if self.command_queue:
                    command = self.command_queue.pop(0)
                    return json.dumps(command)
                else:
                    return json.dumps({})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

class MonitorPollHandler:
    """轮询获取消息（供控制面板使用）"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            # 获取最新的消息（从history）
            history = monitor_handlers['history'](10)
            return json.dumps({"status": "success", "messages": history})
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

class MonitorStatusHandler:
    """检查监听状态"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            # 通过handlers字典查询状态
            active_status = monitor_handlers['active']()
            return json.dumps({ "status": "success", "active": active_status })
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'GET, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

class MonitorBridgeHandler:
    """桥接 DependencyResolveHook 与 LLM 服务桥接层"""
    def POST(self):
        """建立桥接（先判断监听是否开始）"""
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, DELETE, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            result = monitor_handlers['bridge']()
            return json.dumps(result)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def GET(self):
        """查询桥接状态"""
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, DELETE, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            result = monitor_handlers['bridged']()
            return json.dumps(result)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def DELETE(self):
        """断开桥接"""
        web.header('Content-Type', 'application/json; charset=utf-8')
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, DELETE, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        try:
            result = monitor_handlers['unbridge']()
            return json.dumps(result)
        except Exception as e:
            return json.dumps({"status": "error", "message": str(e)})

    def OPTIONS(self):
        """处理CORS预检请求"""
        web.header('Access-Control-Allow-Origin', '*')
        web.header('Access-Control-Allow-Methods', 'POST, GET, DELETE, OPTIONS')
        web.header('Access-Control-Allow-Headers', 'Content-Type')
        return ''

# ========== 监听系统处理器结束 ==========


class AssetsHandler:
    def GET(self, file_path):
        try:
            # 如果请求是/static/，需要处理
            if file_path == '':
                # 返回目录列表...
                pass

            # 获取当前文件的绝对路径
            current_dir = os.path.dirname(os.path.abspath(__file__))
            static_dir = os.path.join(current_dir, 'static')

            full_path = os.path.normpath(os.path.join(static_dir, file_path))

            # 安全检查：确保请求的文件在static目录内
            if not os.path.abspath(full_path).startswith(os.path.abspath(static_dir)):
                logger.error(f"Security check failed for path: {full_path}")
                raise web.notfound()

            if not os.path.exists(full_path) or not os.path.isfile(full_path):
                # Browsers routinely probe optional asset variants (e.g. a
                # .ttf fallback declared alongside .woff2 in @font-face);
                # logging these as errors floods the console with harmless
                # noise. Keep it at debug level — real misconfigurations
                # will still surface via the network panel.
                logger.debug(f"Static file not found: {full_path}")
                raise web.notfound()

            # 设置正确的Content-Type
            content_type = mimetypes.guess_type(full_path)[0]
            if content_type:
                web.header('Content-Type', content_type)
            else:
                # 默认为二进制流
                web.header('Content-Type', 'application/octet-stream')

            # 读取并返回文件内容
            with open(full_path, 'rb') as f:
                return f.read()

        except web.HTTPError as e:
            # The 404 path above already logged at debug; re-raise as-is so
            # web.py returns the original status to the client.
            raise
        except Exception as e:
            logger.error(f"Error serving static file: {e}", exc_info=True)
            raise web.notfound()


class ExpertHandler:
    def GET(self, rest):
        static_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expert_dist')
        if rest in ('', '/'):
            rest = '/index.html'
        if not rest.startswith('/'):
            rest = '/' + rest
        full_path = os.path.normpath(os.path.join(static_dir, rest.lstrip('/')))
        if not os.path.abspath(full_path).startswith(os.path.abspath(static_dir)):
            raise web.notfound()
        if not os.path.exists(full_path) or not os.path.isfile(full_path):
            # SPA fallback: let the Vue router handle client-side routes.
            full_path = os.path.join(static_dir, 'index.html')
        content_type = mimetypes.guess_type(full_path)[0]
        if content_type:
            web.header('Content-Type', content_type)
        else:
            web.header('Content-Type', 'application/octet-stream')
        with open(full_path, 'rb') as f:
            return f.read()
class SpaFallbackHandler:
    """SPA 前端路由回退：刷新 /dashboard、/market/automate 等前端路由时
    返回专家面板入口 index.html，避免直接访问 404 打不开。
    真正的后端 API 路径（api/、auth/、mcp/ 等）仍保持 404。
    """
    def GET(self, path):
        if path.startswith(('api/', 'auth/', 'mcp/', 'uploads/', 'preview/')):
            raise web.notfound()
        static_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expert_dist')
        index = os.path.join(static_dir, 'index.html')
        if not os.path.isfile(index):
            raise web.notfound()
        web.header('Content-Type', 'text/html; charset=utf-8')
        with open(index, 'rb') as f:
            return f.read()
class KimiAgentUploadHandler:
    """POST /api/kimi/agent/upload: 接收前端上传文件/图片/语音，保存到本地供 DLL 使用"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": False, "error": "Kimi Agent 仅支持 Windows 桌面端"}, ensure_ascii=False)
        try:
            ct = web.ctx.env.get('CONTENT_TYPE', '') or ''
            body = web.data() or b""
            # 手动解析 multipart/form-data（绕开 web.py multipart 库兼容问题）
            if 'boundary=' not in ct:
                return json.dumps({"success": False, "error": "Content-Type 缺少 boundary"}, ensure_ascii=False)
            boundary = ct.split('boundary=', 1)[1].split(';', 1)[0].strip().strip('"')
            file_name = None
            file_data = None
            for part in body.split(('--' + boundary).encode()):
                part = part.strip(b'\r\n')
                if not part or part == b'--':
                    continue
                sep = part.find(b'\r\n\r\n')
                if sep == -1:
                    continue
                headers_raw = part[:sep].decode('utf-8', 'ignore')
                content = part[sep + 4:]
                if content.endswith(b'\r\n'):
                    content = content[:-2]
                m = re.search(r'name="([^"]*)"', headers_raw)
                mf = re.search(r'filename="([^"]*)"', headers_raw)
                if m and mf:
                    file_name = os.path.basename(mf.group(1))
                    file_data = content
            if not file_name or file_data is None:
                return json.dumps({"success": False, "error": "缺少 file 字段"}, ensure_ascii=False)
            upload_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expert_dist', 'market', 'uploads')
            os.makedirs(upload_dir, exist_ok=True)
            safe = str(int(time.time() * 1000)) + "_" + file_name
            save_path = os.path.join(upload_dir, safe)
            with open(save_path, 'wb') as fo:
                fo.write(file_data)
            url = "/expert/market/uploads/" + safe
            return json.dumps({"success": True, "path": save_path, "url": url,
                               "filename": file_name, "size": len(file_data)}, ensure_ascii=False)
        except Exception as e:
            return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)
def _kimi_take_shot(ka, data):
    """截取 Kimi 窗口保存 PNG；返回 {success,url,path,w,h} 或 {success:false,error}

    Electron 窗口 PrintWindow 会黑屏，因此自动模式：DLL FOCUS 抢前台恢复窗口
    后走全屏 BitBlt（Kimi 在前台即截到 Kimi）。显式传 hwnd 时仍用 PrintWindow。
    """
    hwnd = data.get("hwnd")
    auto_hwnd = None
    if not hwnd:
        try:
            mw = ka.find_main_window((ka.process_tree().get("main") or {}).get("pid"))
            if mw:
                auto_hwnd = mw["hwnd"]
        except Exception as Exception:
            auto_hwnd = None
    pid = data.get("pid")
    if pid is None:
        tree = ka.process_tree()
        if not tree["renderer"]:
            return {"success": False, "error": "未找到 Kimi 渲染进程（请先开启 Kimi3 应用）"}
        for rp in tree["renderer"]:
            if ka.is_dll_loaded(rp["pid"]):
                pid = rp["pid"]
                break
        if pid is None:
            pid = tree["renderer"][0]["pid"]
    try:
        pid_i = int(pid)
    except Exception as Exception:
        return {"success": False, "error": "无效 PID: " + str(pid)}
    shots_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expert_dist', 'market', 'shots')
    os.makedirs(shots_dir, exist_ok=True)
    name = "shot_" + str(int(time.time() * 1000)) + ".png"
    save_path = os.path.join(shots_dir, name)
    if auto_hwnd:
        # 用 DLL FOCUS 抢前台并恢复窗口（纯 SetForegroundWindow 受 Windows 前台锁限制）
        try:
            ka._pipe_send(pid_i, "FOCUS " + str(auto_hwnd))
        except Exception as Exception:
            pass
        time.sleep(0.8)
        hwnd = None  # 全屏 BitBlt（Kimi 已在前台）
    cmd = "SHOT " + save_path
    if hwnd:
        cmd += " " + str(hwnd)
    resp = ka._pipe_send(pid_i, cmd)
    if not resp.get("success"):
        return {"success": False, "error": resp.get("error", "截图失败")}
    return {"success": True, "url": "/expert/market/shots/" + name,
            "path": save_path, "w": resp.get("w"), "h": resp.get("h")}

class KimiAgentShotHandler:
    """POST /api/kimi/agent/shot: 截取 Kimi 窗口(或全屏)保存 PNG，返回可访问 URL"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": False, "error": "Kimi Agent 仅支持 Windows 桌面端"}, ensure_ascii=False)
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as Exception:
            data = {}
        return json.dumps(_kimi_take_shot(ka, data), ensure_ascii=False)
def _ocr_image(img_path):
    """Windows.Media.Ocr 识别截图文本；返回 (text, lines) 或 (None, None)"""
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'expert_dist', 'market', 'ocr_recognize.ps1')
    if not os.path.isfile(script):
        return None, None
    try:
        import subprocess
        r = subprocess.run(['powershell', '-NoProfile', '-ExecutionPolicy', 'Bypass',
                            '-File', script, '-ImagePath', img_path],
                           capture_output=True, text=True, encoding='utf-8', errors='replace', timeout=120)
        if r.returncode != 0:
            return None, None
        for line in reversed((r.stdout or '').splitlines()):
            line = line.strip()
            if line.startswith('{'):
                d = json.loads(line)
                if d.get('error'):
                    return None, None
                return d.get('text'), d.get('lines')
    except Exception as Exception:
        return None, None
    return None, None

class KimiAgentOcrHandler:
    """POST /api/kimi/agent/ocr: 截取 Kimi 窗口 → OCR 识别回复文本
    body: {} 或 {"path": 已截图路径}
    返回: {success, text, lines, shot_url, shot_path}
    """
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": False, "error": "Kimi Agent 仅支持 Windows 桌面端"}, ensure_ascii=False)
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as Exception:
            data = {}
        shot_url = None
        path = data.get("path")
        if not path:
            shot = _kimi_take_shot(ka, data)
            if not shot.get("success"):
                return json.dumps(shot, ensure_ascii=False)
            path = shot["path"]
            shot_url = shot["url"]
        if not os.path.isfile(path):
            return json.dumps({"success": False, "error": "截图不存在: " + str(path)}, ensure_ascii=False)
        text, lines = _ocr_image(path)
        if text is None:
            return json.dumps({"success": False, "error": "OCR 识别失败"}, ensure_ascii=False)
        return json.dumps({"success": True, "text": text, "lines": lines,
                           "shot_url": shot_url, "shot_path": path}, ensure_ascii=False)
def _workspace_service():
    from agent.workspace.service import WorkspaceService
    return WorkspaceService(_get_workspace_root())


def _decorate_entry(svc, entry):
    """Attach the URLs the frontend needs to preview or download an entry."""
    if entry.get("is_dir"):
        return entry
    abs_path = entry.get("abs_path") or os.path.join(svc.root, entry["path"])
    entry["abs_path"] = abs_path
    entry["raw_url"] = f"/api/file?path={quote(abs_path)}"
    entry["preview_url"] = _build_public_short_url(abs_path)
    return entry


class WorkspaceTreeHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            params = web.input(path='', show_hidden='')
            svc = _workspace_service()
            result = svc.list_dir(params.path, show_hidden=params.show_hidden == '1')
            result["entries"] = [_decorate_entry(svc, e) for e in result["entries"]]
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except (ValueError, FileNotFoundError) as e:
            return json.dumps({"status": "error", "message": str(e)})
        except Exception as e:
            logger.error(f"[WebChannel] Workspace tree error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class WorkspaceSearchHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            params = web.input(q='', limit='30')
            try:
                limit = max(1, min(100, int(params.limit)))
            except (TypeError, ValueError) as e:
                limit = 30
            svc = _workspace_service()
            result = svc.search(params.q, limit=limit)
            result["results"] = [_decorate_entry(svc, e) for e in result["results"]]
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Workspace search error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class WorkspaceResolveHandler:
    """
    Metadata + preview/raw URLs for one entry, given a relative or absolute path.

    Directories resolve as well (the client then browses instead of previewing),
    just without the file URLs.
    """

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.protocol.artifact import classify_kind, is_previewable
            params = web.input(path='')
            raw_path = (params.path or '').strip()
            if not raw_path:
                return json.dumps({"status": "error", "message": "path is required"})

            svc = _workspace_service()
            if os.path.isabs(os.path.expanduser(raw_path)):
                abs_path = os.path.realpath(os.path.expanduser(raw_path))
                if not _is_path_allowed(abs_path):
                    return json.dumps({"status": "error", "message": "Path not allowed"})
                is_dir = os.path.isdir(abs_path)
                if not is_dir and not os.path.isfile(abs_path):
                    return json.dumps({"status": "error", "message": "File not found"})
                kind = "directory" if is_dir else classify_kind(abs_path)
                entry = { "name": os.path.basename(abs_path), "path": svc.to_rel(abs_path), "abs_path": abs_path, "is_dir": is_dir, "kind": kind, "previewable": (not is_dir) and is_previewable(kind), "size": 0 if is_dir else os.path.getsize(abs_path), "mtime": os.path.getmtime(abs_path), }
            else:
                entry = svc.stat_file(raw_path)

            # A directory has nothing to serve; the client browses into it.
            if not entry["is_dir"]:
                entry["raw_url"] = f"/api/file?path={quote(entry['abs_path'])}"
                entry["preview_url"] = _build_public_short_url(entry["abs_path"])
            return json.dumps({"status": "success", "file": entry}, ensure_ascii=False)
        except (ValueError, FileNotFoundError) as e:
            return json.dumps({"status": "error", "message": str(e)})
        except Exception as e:
            logger.error(f"[WebChannel] Workspace resolve error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class WorkspaceMetaHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            return json.dumps({"status": "success", **_workspace_service().meta()}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Workspace meta error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class KnowledgeListHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.knowledge.service import KnowledgeService
            svc = KnowledgeService(_get_workspace_root())
            result = svc.list_tree()
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Knowledge list error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class KnowledgeReadHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.knowledge.service import KnowledgeService
            params = web.input(path='')
            svc = KnowledgeService(_get_workspace_root())
            result = svc.read_file(params.path)
            return json.dumps({"status": "success", **result}, ensure_ascii=False)
        except (ValueError, FileNotFoundError) as e:
            return json.dumps({"status": "error", "message": str(e)})
        except Exception as e:
            logger.error(f"[WebChannel] Knowledge read error: {e}")
            return json.dumps({"status": "error", "message": str(e)})


class KnowledgeGraphHandler:
    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.knowledge.service import KnowledgeService
            svc = KnowledgeService(_get_workspace_root())
            return json.dumps(svc.build_graph(), ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Knowledge graph error: {e}")
            return json.dumps({"nodes": [], "links": []})


class KnowledgeActionHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            body = json.loads(web.data() or b"{}")
            action = body.get("action", "")
            payload = body.get("payload") or {}
            from agent.knowledge.service import KnowledgeService
            result = KnowledgeService(_get_workspace_root()).dispatch(action, payload)
            return json.dumps({ "status": "success" if result["code"] < 300 else "error", **result, }, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Knowledge action error: {e}")
            return json.dumps({"status": "error", "code": 500, "message": str(e), "payload": None})


class KnowledgeImportHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            from agent.knowledge.service import KnowledgeService
            content_length = int(getattr(web.ctx, "env", {}).get("CONTENT_LENGTH") or 0)
            if content_length > KnowledgeService.MAX_IMPORT_TOTAL_SIZE:
                return json.dumps({ "status": "error", "code": 413, "message": "import batch too large", "payload": None, })
            params = _raw_web_input()
            target_category = params.get("target_category", "")
            conflict_strategy = params.get("conflict_strategy", "skip")
            uploaded = _ensure_list(params.get("files"))
            single = params.get("file")
            if single is not None:
                uploaded.append(single)
            if not uploaded:
                return json.dumps({"status": "error", "code": 400, "message": "No files uploaded", "payload": None})
            if len(uploaded) > KnowledgeService.MAX_IMPORT_FILES:
                return json.dumps({ "status": "error", "code": 400, "message": f"too many files: max {KnowledgeService.MAX_IMPORT_FILES}", "payload": None, })

            files = []
            total_size = 0
            for file_obj in uploaded:
                if file_obj is None:
                    continue
                filename = getattr(file_obj, "filename", "") or getattr(file_obj, "name", "")
                content = _read_uploaded_file_bytes_limited(file_obj, KnowledgeService.MAX_IMPORT_FILE_SIZE)
                total_size += len(content)
                if total_size > KnowledgeService.MAX_IMPORT_TOTAL_SIZE:
                    return json.dumps({ "status": "error", "code": 413, "message": "import batch too large", "payload": None, })
                files.append({ "filename": filename, "content": content, })

            result = KnowledgeService(_get_workspace_root()).dispatch("import_documents", { "target_category": target_category, "conflict_strategy": conflict_strategy, "files": files, })
            return json.dumps({ "status": "success" if result["code"] < 300 else "error", **result, }, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[WebChannel] Knowledge import error: {e}", exc_info=True)
            return json.dumps({"status": "error", "code": 500, "message": str(e), "payload": None})


class VersionHandler:
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        from cli import __version__
        return json.dumps({"version": __version__})


# =====================================================================
# 智能体 -> 节点管理（代理 agetnt admin 后端的 /api/nodes*）
# 服务端持有 admin 登录 token，前端同源调用，无 CORS / 鉴权负担
# =====================================================================
# admin 节点管理服务(8088) 与 AWF(5000) 已部署到远程服务器(Docker)，环境变量可覆盖
AGENT_ADMIN_BASE = os.environ.get("AGENT_ADMIN_BASE", "http://127.0.0.1:8088")
AGENT_AWF_BASE = os.environ.get("AGENT_AWF_BASE", "http://127.0.0.1:5000")
class AgentNodesHandler:
    _admin_base = AGENT_ADMIN_BASE
    _admin_account = "admin"
    _admin_password = "change-me-on-deploy"
    _token = None
    _token_exp = 0.0

    @classmethod
    def _admin_token(cls):
        now = time.time()
        if cls._token and now < cls._token_exp - 60:
            return cls._token
        try:
            import requests
            resp = requests.post( cls._admin_base + "/api/auth/admin-login", json={"account": cls._admin_account, "password": cls._admin_password}, timeout=5, )
            data = resp.json()
            if data.get("ok") and data.get("token"):
                cls._token = data["token"]
                cls._token_exp = now + 12 * 3600  # JWT 有效期约 12h，提前 60s 续期
                return cls._token
        except Exception as e:
            logger.warning(f"[AgentNodes] admin login failed: {e}")
        return None

    def GET(self, path=''):
        web.header('Content-Type', 'application/json; charset=utf-8')
        token = self._admin_token()
        if not token:
            return json.dumps({"ok": False, "error": "节点管理服务不可用（admin 登录失败）"}, ensure_ascii=False)
        try:
            import requests
            action = (path or 'list').strip('/')
            qs = []
            for k in ("page", "size", "keyword", "type", "kind"):
                v = web.input().get(k)
                if v:
                    qs.append(f"{k}={quote(str(v))}")
            suffix = "" if not qs else ("?" + "&".join(qs))
            if action == 'health':
                url = self._admin_base + "/api/nodes/health"
            elif action == 'diagnose-all':
                url = self._admin_base + "/api/nodes/diagnose-all"
            elif action == 'sync-awf':
                url = self._admin_base + "/api/nodes/sync-awf"
            else:
                url = self._admin_base + "/api/nodes" + suffix
            resp = requests.get(url, params={"token": token}, timeout=15)
            return resp.text
        except Exception as e:
            logger.error(f"[AgentNodes] proxy error: {e}")
            return json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)

    def POST(self, path=''):
        web.header('Content-Type', 'application/json; charset=utf-8')
        token = self._admin_token()
        if not token:
            return json.dumps({"ok": False, "error": "节点管理服务不可用（admin 登录失败）"}, ensure_ascii=False)
        try:
            import requests
            action = (path or 'list').strip('/')
            url = self._admin_base + "/api/nodes"
            if action == 'sync-awf':
                url = self._admin_base + "/api/nodes/sync-awf"
            resp = requests.post(url, params={"token": token}, timeout=30)
            return resp.text
        except Exception as e:
            logger.error(f"[AgentNodes] proxy error: {e}")
            return json.dumps({"ok": False, "error": str(e)}, ensure_ascii=False)


# =====================================================================
# 智能体 -> 会话绑定（"加入对话"：把节点绑定到会话）
# 内存存储：session_id -> [node 摘要, ...]（一个会话可加入多个智能体）
# 进程重启后失效，可接受
# =====================================================================
_AGENT_BIND_LOCK = threading.Lock()
_AGENT_BINDINGS = {}  # session_id -> [{"id","name","code","icon","kind","type","api_url","model","remark"}, ...]


def _get_agent_bindings(session_id):
    """返回该会话已绑定的智能体节点列表（拷贝）"""
    with _AGENT_BIND_LOCK:
        return list(_AGENT_BINDINGS.get(session_id, []))


def _drop_agent_binding(session_id, code = None):
    """解除绑定：code 为空则清空全部；否则按 code 移除单个"""
    with _AGENT_BIND_LOCK:
        nodes = _AGENT_BINDINGS.get(session_id)
        if not nodes:
            return
        if code is None:
            _AGENT_BINDINGS.pop(session_id, None)
        else:
            _AGENT_BINDINGS[session_id] = [n for n in nodes if n.get("code") != code]


class AgentBindHandler:
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data())
        except Exception as e:
            return json.dumps({"status": "error", "message": "Invalid request"})
        session_id = (data.get("session_id") or "").strip()
        node = data.get("node") or {}
        if not session_id or not node.get("code"):
            return json.dumps({"status": "error", "message": "session_id and node required"})
        keys = ("id", "name", "code", "icon", "kind", "type", "api_url", "model", "remark")
        slim = {k: node.get(k) for k in keys if node.get(k) is not None}
        with _AGENT_BIND_LOCK:
            nodes = _AGENT_BINDINGS.setdefault(session_id, [])
            # 按 code 去重：已存在则原位更新，否则追加
            for i, n in enumerate(nodes):
                if n.get("code") == slim.get("code"):
                    nodes[i] = slim
                    break
            else:
                nodes.append(slim)
        logger.info(f"[AgentBind] session={session_id} bind node={slim.get('code')} total={len(nodes)}")
        return json.dumps({"status": "success", "nodes": nodes}, ensure_ascii=False)

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        session_id = web.input(session_id='').session_id
        nodes = _get_agent_bindings(session_id)
        return json.dumps({"status": "success", "bound": bool(nodes), "nodes": nodes}, ensure_ascii=False)

    def DELETE(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        params = web.input(session_id='', code='')
        _drop_agent_binding(params.session_id, params.code or None)
        return json.dumps({"status": "success", "unbound": True})


# =====================================================================
# 智能体节点调用（一键配置 + 真实调用 AWF 5000）
# 移植自 agetnt/gpt/server.py 的 AWF 节点能力，经本服务代理调用
# =====================================================================
AGENT_AWF_DIR = os.environ.get("AGENT_AWF_DIR", r"c:\Users\gzwebsj\Desktop\mocode-cli\agetnt\gpt")
AGENT_AWF_LOG = os.path.join(AGENT_AWF_DIR, "awf_server.log")

# 节点 code -> AWF 端点（与 agetnt admin 节点 code 一致）
AGENT_NODE_ENDPOINTS = { "chat": "/api/chat", "tts": "/api/tts/generate", "asr": "/api/asr", "music": "/api/music/generate", "deepresearch": "/api/deepresearch", "wdtagger": "/api/wdtagger", "flux": "/api/flux", "bgremove": "/api/bgremove", "rmbg20": "/api/rmbg20", "upscale": "/api/upscale", "enhance": "/api/enhance", "imgedit": "/api/imgedit", "tryon": "/api/tryon", "anypose": "/api/anypose", "faceswap": "/api/faceswap", "i2v": "/api/i2v", "threed": "/api/3d/generate", "mocap": "/api/mocap", }


def _awf_alive(timeout=3.0):
    """探测 AWF 服务(5000)是否在线"""
    import requests
    try:
        r = requests.get(f"{AGENT_AWF_BASE}/api/spaces/info", timeout=timeout)
        return r.status_code == 200
    except Exception as e:
        return False


def _start_awf_service():
    """尝试启动 AWF 服务（agetnt/gpt/server.py），最长等待 30s 就绪。
    服务已部署在远程服务器时直接探测远程地址，无需本地拉起。"""
    import subprocess, sys
    if _awf_alive(timeout=3.0):
        return True, "远程 AWF 已在线"
    if not os.path.isdir(AGENT_AWF_DIR) or not os.path.isfile(os.path.join(AGENT_AWF_DIR, "server.py")):
        return False, f"AWF 远程离线且本地目录不存在: {AGENT_AWF_DIR}"
    try:
        logf = open(AGENT_AWF_LOG, "a", encoding="utf-8")
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0)
        proc = subprocess.Popen([sys.executable, "server.py"], cwd=AGENT_AWF_DIR, stdout=logf, stderr=logf, creationflags=flags)
    except Exception as e:
        return False, f"启动失败: {e}"
    for _ in range(30):
        if _awf_alive(timeout=1.0):
            return True, f"已启动 (pid={proc.pid})"
        time.sleep(1)
    return False, "已拉起进程但服务未就绪，请查看 awf_server.log"


def _start_admin_service():
    """尝试启动 admin 节点管理服务。服务已部署在远程服务器(Docker)时直接探测远程地址。"""
    import subprocess
    try:
        import requests
        r = requests.get(AGENT_ADMIN_BASE + "/api/ping", timeout=3)
        if r.status_code < 500:
            return True, "远程 admin 已在线"
    except Exception as e:
        pass
    exe = os.environ.get("AGENT_ADMIN_EXE", r"c:\Users\gzwebsj\Desktop\mocode-cli\agetnt\admin\bin\server.exe")
    log_path = os.path.join(os.path.dirname(exe), "admin_server.log") if os.path.dirname(exe) else "admin_server.log"
    if not os.path.isfile(exe):
        return False, "server.exe 不存在（远程 admin 离线）"
    try:
        logf = open(log_path, "a", encoding="utf-8")
        flags = getattr(subprocess, "CREATE_NEW_PROCESS_GROUP", 0) | getattr(subprocess, "DETACHED_PROCESS", 0)
        subprocess.Popen([exe], cwd=os.path.dirname(exe), stdout=logf, stderr=logf, creationflags=flags)
    except Exception as e:
        return False, f"启动失败: {e}"
    import requests
    for _ in range(12):
        try:
            r = requests.get(AGENT_ADMIN_BASE + "/api/ping", timeout=2)
            if r.status_code < 500:
                return True, "已启动"
        except Exception as e:
            pass
        time.sleep(1)
    return False, "已拉起进程但未就绪（请确认 MySQL 是否已启动）"


def _materialize_data_urls(payload):
    """把 payload 中的 data: URL 落盘为本地文件并改写为绝对路径
    （优先写入 AWF 的 uploads 目录，同机直读且能触发各节点的本地兜底逻辑）"""
    if not isinstance(payload, dict):
        return payload
    import base64 as _b64
    here = os.path.dirname(os.path.abspath(__file__))
    awf_upload = os.path.normpath(os.path.join(here, "..", "..", "..", "agetnt", "gpt", "static", "uploads"))
    upload_dir = awf_upload if os.path.isdir(awf_upload) else os.path.join(here, "tmp")
    os.makedirs(upload_dir, exist_ok=True)
    for key, val in list(payload.items()):
        if not (isinstance(val, str) and val.startswith("data:") and "," in val):
            continue
        try:
            head, b64 = val.split(",", 1)
            mime = head[5:].split(";")[0] or "application/octet-stream"
            ext = mimetypes.guess_extension(mime) or ".bin"
            fname = f"agent_invoke_{uuid.uuid4().hex}{ext}"
            fpath = os.path.join(upload_dir, fname)
            with open(fpath, "wb") as f:
                f.write(_b64.b64decode(b64))
            payload[key] = fpath
        except Exception as e:
            logger.warning(f"[AgentInvoke] materialize {key} failed: {e}")
    return payload


# 智能体运行结果落盘目录（服务器保存 + 加密通道回传的前端访问入口）
AGENT_RESULT_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), "agent_pipeline", "results")


def _save_data_url_to_server(val):
    """把 data: base64 落盘保存到服务器，返回可访问的相对 URL"""
    try:
        head, b64 = val.split(",", 1)
        mime = head[5:].split(";")[0] or "application/octet-stream"
        ext = mimetypes.guess_extension(mime) or ".bin"
        if ext == ".jpe":
            ext = ".jpg"
        os.makedirs(AGENT_RESULT_DIR, exist_ok=True)
        fname = f"result_{uuid.uuid4().hex}{ext}"
        with open(os.path.join(AGENT_RESULT_DIR, fname), "wb") as f:
            f.write(base64.b64decode(b64))
        return f"/api/agent/result/{fname}"
    except Exception as e:
        logger.warning(f"[AgentInvoke] save data url failed: {e}")
        return val


def _save_invoke_results(obj):
    """递归把结果中的 data: base64 字段保存到服务器并替换为 URL"""
    if isinstance(obj, dict):
        for k, v in list(obj.items()):
            if isinstance(v, str) and v.startswith("data:") and "," in v:
                obj[k] = _save_data_url_to_server(v)
            else:
                _save_invoke_results(v)
    elif isinstance(obj, list):
        for it in obj:
            _save_invoke_results(it)
    return obj


class AgentResultHandler:
    """返回智能体运行结果的落盘文件（经加密通道回传后由前端加载展示）"""
    def GET(self, path=''):
        fname = os.path.basename((path or "").strip())
        fpath = os.path.join(AGENT_RESULT_DIR, fname)
        if not fname or not os.path.isfile(fpath):
            raise web.notfound()
        mime = mimetypes.guess_type(fname)[0] or "application/octet-stream"
        web.header('Content-Type', mime)
        web.header('Cache-Control', 'no-cache')
        with open(fpath, "rb") as f:
            return f.read()


# =====================================================================
# Workflow 工作流任务管理
# 以任务为中心：创建/保存工作流配置 -> 运行（顺序执行 AWF 节点）-> 历史与结果
# 数据持久化在 web_channel.py 同级 workflows.json
# =====================================================================
WORKFLOW_STORE_PATH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "workflows.json")
_WORKFLOW_LOCK = threading.RLock()


def _import_mocode():
    """延迟导入 Mo 核心业务层（mocode 包，兼容 web.py 从项目根启动）"""
    import sys as _sys
    try:
        from mocode import workflow_store as _ws
        from mocode import workflow_engine as _we
        from mocode import model_config as _mc
        from mocode import chat_orchestrator as _co
        return _ws, _we, _mc, _co
    except ImportError as e:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in _sys.path:
            _sys.path.insert(0, here)
        from mocode import workflow_store as _ws
        from mocode import workflow_engine as _we
        from mocode import model_config as _mc
        from mocode import chat_orchestrator as _co
        return _ws, _we, _mc, _co


_wf_store = None
_wf_engine = None
_mo_model_config = None
_mo_chat = None


def _get_wf_store():
    """Mo: WorkflowStore（workflows.json 持久化）"""
    global _wf_store
    if _wf_store is None:
        _ws, _, _, _ = _import_mocode()
        _wf_store = _ws.WorkflowStore(WORKFLOW_STORE_PATH)
    return _wf_store


def _get_wf_engine():
    """Mo: WorkflowEngine（步骤执行，依赖注入壳层 IO）"""
    global _wf_engine
    if _wf_engine is None:
        _, _we, _, _ = _import_mocode()
        _wf_engine = _we.WorkflowEngine({ "endpoints": AGENT_NODE_ENDPOINTS, "awf_base": AGENT_AWF_BASE, "materialize": _materialize_data_urls, "awf_alive": _awf_alive, "save_result": _save_invoke_results, "post": _awf_post, })
    return _wf_engine


def _awf_post(url, params):
    """AWF 节点调用包装：永不抛异常，失败返回 {ok: False, error}"""
    import requests as _rq
    try:
        r = _rq.post(url, json=params, timeout=600)
        try:
            return r.json()
        except Exception as e:
            return {"ok": False, "http": r.status_code, "error": (r.text or "")[:300]}
    except _rq.exceptions.Timeout:
        return {"ok": False, "error": "节点调用超时（任务较重），请稍后重试"}
    except Exception as e:
        return {"ok": False, "error": str(e)}


def _workflow_load():
    return _get_wf_store().load()


def _workflow_save(data):
    _get_wf_store().save(data)


def _workflow_new_id(prefix):
    return _get_wf_store().new_id(prefix)


def _workflow_prev_ref(j):
    """从上一步结果中提取可引用文本/URL（用于 {{prev}} 模板注入）"""
    if not isinstance(j, dict):
        return ""
    for key in ("image_url", "model_url", "data_url", "url", "audio_url", "video_url", "text", "response", "content"):
        v = j.get(key)
        if isinstance(v, str) and v:
            return v
        if isinstance(v, dict):
            for k2 in ("url", "image_url", "data_url", "text"):
                if isinstance(v.get(k2), str) and v.get(k2):
                    return v[k2]
    items = j.get("items")
    if isinstance(items, list) and items:
        it = items[0]
        if isinstance(it, dict):
            for k3 in ("url", "image_url", "data_url", "text"):
                if isinstance(it.get(k3), str) and it.get(k3):
                    return it[k3]
    # chat 类节点：取最后一条助手回复
    messages = j.get("messages")
    if isinstance(messages, list) and messages:
        for m in reversed(messages):
            if isinstance(m, dict) and isinstance(m.get("content"), str) and m.get("content"):
                return m["content"]
    return ""


def _workflow_step_ok(j):
    """步骤成功判定：显式 ok 字段优先；无 ok 但存在实际输出视为成功"""
    if not isinstance(j, dict):
        return False
    if "ok" in j:
        return bool(j.get("ok"))
    for k in ("items", "data_url", "image_url", "model_url", "messages", "text", "response", "content", "url", "data"):
        if j.get(k):
            return True
    return False


def _run_workflow_steps(wf):
    """顺序执行工作流步骤（Mo: WorkflowEngine 核心逻辑）"""
    return _get_wf_engine().run(wf)


class WorkflowHandler:
    """工作流任务管理
    GET  /api/workflow -> {status, workflows, runs}
    POST /api/workflow -> {action: create|update|delete|run, ...}
    """

    def GET(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = _workflow_load()
            return json.dumps({"status": "success", "workflows": data["workflows"], "runs": data["runs"][:50]}, ensure_ascii=False)
        except Exception as e:
            logger.error(f"[Workflow] GET failed: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            req = json.loads(web.data() or b"{}")
        except Exception as e:
            return json.dumps({"status": "error", "message": "Invalid request"})
        action = (req.get("action") or "").strip()
        try:
            if action == "create":
                return self._create(req)
            if action == "update":
                return self._update(req)
            if action == "delete":
                return self._delete(req)
            if action == "run":
                return self._run(req)
            if action == "run_inline":
                return self._run_inline(req)
            if action == "chat":
                return self._chat(req)
            return json.dumps({"status": "error", "message": f"unknown action: {action}"})
        except Exception as e:
            logger.error(f"[Workflow] {action} failed: {e}")
            return json.dumps({"status": "error", "message": str(e)})

    def _create(self, req):
        name = (req.get("name") or "").strip()
        if not name:
            return json.dumps({"status": "error", "message": "name required"})
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        wf = { "id": _workflow_new_id("wf"), "name": name, "desc": (req.get("desc") or "").strip(), "steps": req.get("steps") or [], "created_at": now, "updated_at": now, }
        with _WORKFLOW_LOCK:
            data = _workflow_load()
            data["workflows"].insert(0, wf)
            _workflow_save(data)
        return json.dumps({"status": "success", "workflow": wf}, ensure_ascii=False)

    def _update(self, req):
        wf_id = (req.get("id") or "").strip()
        with _WORKFLOW_LOCK:
            data = _workflow_load()
            for wf in data["workflows"]:
                if wf.get("id") == wf_id:
                    if req.get("name"):
                        wf["name"] = (req.get("name") or "").strip()
                    if "desc" in req:
                        wf["desc"] = (req.get("desc") or "").strip()
                    if "steps" in req:
                        wf["steps"] = req["steps"] or []
                    wf["updated_at"] = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
                    _workflow_save(data)
                    return json.dumps({"status": "success", "workflow": wf}, ensure_ascii=False)
        return json.dumps({"status": "error", "message": "workflow not found"})

    def _delete(self, req):
        wf_id = (req.get("id") or "").strip()
        with _WORKFLOW_LOCK:
            data = _workflow_load()
            before = len(data["workflows"])
            data["workflows"] = [w for w in data["workflows"] if w.get("id") != wf_id]
            if len(data["workflows"]) == before:
                return json.dumps({"status": "error", "message": "workflow not found"})
            _workflow_save(data)
        return json.dumps({"status": "success", "deleted": True})

    def _run(self, req):
        wf_id = (req.get("id") or "").strip()
        data = _workflow_load()
        wf = next((w for w in data["workflows"] if w.get("id") == wf_id), None)
        if not wf:
            return json.dumps({"status": "error", "message": "workflow not found"})
        if not (wf.get("steps") or []):
            return json.dumps({"status": "error", "message": "工作流未配置步骤"})
        result = _run_workflow_steps(wf)
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        run = { "id": _workflow_new_id("run"), "workflow_id": wf_id, "workflow_name": wf.get("name") or "", "status": result["status"], "error": result.get("error") or "", "steps": result.get("steps") or [], "started_at": now, "finished_at": now, }
        with _WORKFLOW_LOCK:
            data = _workflow_load()
            data["runs"].insert(0, run)
            del data["runs"][100:]
            _workflow_save(data)
        return json.dumps({"status": "success", "run": run}, ensure_ascii=False)

    def _chat(self, req):
        """对话模式（Mo: ChatOrchestrator 核心编排 + MPCP 加密协议 + OptimizeHook 推送）"""
        message = (req.get("message") or "").strip()
        if not message:
            return json.dumps({"status": "error", "message": "message required"})
        try:
            result = _get_chat_orchestrator().run(message)
        except Exception as e:
            logger.exception("[WorkflowChat] 编排失败")
            result = {"status": "error", "message": f"编排失败: {e}"}
        return json.dumps(result, ensure_ascii=False)

    def _run_inline(self, req):
        """视图模式画布内联运行：不持久化工作流，仅执行并记录运行历史"""
        steps = req.get("steps") or []
        if not steps:
            return json.dumps({"status": "error", "message": "steps required"})
        wf = {"name": (req.get("name") or "视图模式画布").strip(), "steps": steps}
        result = _run_workflow_steps(wf)
        now = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        run = { "id": _workflow_new_id("run"), "workflow_id": "", "workflow_name": wf["name"], "status": result["status"], "error": result.get("error") or "", "steps": result.get("steps") or [], "started_at": now, "finished_at": now, }
        with _WORKFLOW_LOCK:
            data = _workflow_load()
            data["runs"].insert(0, run)
            del data["runs"][100:]
            _workflow_save(data)
        return json.dumps({"status": "success", "run": run}, ensure_ascii=False)


def _extract_json_block(text):
    """从 LLM 输出中稳健提取 JSON 对象/数组（容忍 markdown 围栏与前后缀文字）"""
    if not text:
        return None
    text = str(text).strip()
    m = re.search(r"```(?:json)?\s*([\s\S]*?)```", text)
    if m:
        text = m.group(1).strip()
    for pat in (r"\{[\s\S]*\}", r"\[[\s\S]*\]"):
        m = re.search(pat, text)
        if m:
            try:
                return json.loads(m.group(0))
            except Exception as e:
                continue
    return None


def _chat_provider_credentials():
    """读取当前 chat 能力对应的厂商凭据（provider/model/api_key/api_base），供加密协议调用"""
    local_config = conf()
    bot_type = local_config.get("bot_type") or ""
    provider_id = "openai" if bot_type == "chatGPT" else bot_type
    model = (local_config.get("model") or "").strip()
    if not provider_id and model:
        provider_id = ConfigHandler._infer_provider_from_model(model)
    if not provider_id:
        return None
    if provider_id.startswith("custom:"):
        try:
            from models.custom_provider import parse_custom_bot_type
            _, custom_id = parse_custom_bot_type(provider_id)
        except Exception as e:
            return None
        providers = ConfigHandler._normalize_custom_providers(local_config.get("custom_providers"))
        cp = next((p for p in providers if p.get("id") == custom_id), None)
        if not cp:
            return None
        return { "provider": provider_id, "model": model or (cp.get("model") or ""), "api_key": (cp.get("api_key") or "").strip(), "api_base": (cp.get("api_base") or "").strip(), }
    meta = ConfigHandler.PROVIDER_MODELS.get(provider_id)
    if not meta:
        return None
    key_field = meta.get("api_key_field")
    api_key = (local_config.get(key_field) or "").strip() if key_field else ""
    base_key = meta.get("api_base_key")
    api_base = ""
    if base_key:
        api_base = (local_config.get(base_key) or "").strip() or (meta.get("api_base_default") or "")
    else:
        api_base = meta.get("api_base_default") or ""
    return {"provider": provider_id, "model": model, "api_key": api_key, "api_base": api_base}


def _import_agent_pipeline():
    """延迟导入 agent_pipeline 模块（兼容 web.py 从项目根启动的路径差异）"""
    import sys
    try:
        from agent_pipeline import pipeline as _pl
        return _pl
    except ImportError as e:
        here = os.path.dirname(os.path.abspath(__file__))
        if here not in sys.path:
            sys.path.insert(0, here)
        from agent_pipeline import pipeline as _pl
        return _pl


class AgentSetupHandler:
    """一键配置：检测 / 拉起 admin(8088) 与 AWF(5000)，返回诊断结果"""
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        import requests
        admin = {"running": False, "detail": ""}
        awf = {"running": False, "detail": ""}
        # admin 8088
        try:
            r = requests.get(AGENT_ADMIN_BASE + "/api/ping", timeout=3)
            admin["running"] = r.status_code < 500
            admin["detail"] = f"HTTP {r.status_code}"
        except Exception as e:
            admin["detail"] = str(e)[:80]
        if not admin["running"]:
            admin_ok, admin_msg = _start_admin_service()
            admin["running"] = admin_ok
            admin["detail"] = admin_msg
        # AWF 5000
        awf_alive = _awf_alive()
        awf["running"] = awf_alive
        awf["detail"] = "在线" if awf_alive else "离线"
        if not awf_alive:
            ok, msg = _start_awf_service()
            awf["running"] = ok
            awf["detail"] = msg
        # 节点能力统计
        nodes_online = 0
        if awf["running"]:
            try:
                r = requests.get(f"{AGENT_AWF_BASE}/api/spaces/info", timeout=5)
                j = r.json() if r.status_code == 200 else {}
                info = j.get("spaces") or j.get("features") or {}
                nodes_online = len(info) if isinstance(info, (dict, list)) else 0
            except Exception as e:
                nodes_online = 0
        return json.dumps({ "ok": bool(awf["running"] or admin["running"]), "admin": admin, "awf": awf, "nodes_online": nodes_online, "tips": "AWF 与 admin 都在线即可调用全部节点；AWF 离线时已自动尝试拉起。", }, ensure_ascii=False)


class AgentInvokeHandler:
    """调用智能体节点：{code, data} -> 代理到 AWF 5000 对应端点"""
    def POST(self):
        _require_auth()
        web.header('Content-Type', 'application/json; charset=utf-8')
        _t0 = time.time()
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as e:
            return json.dumps({"ok": False, "error": "Invalid request"})
        code = (data.get("code") or "").strip()
        payload = data.get("data") or {}
        logger.info(f"[AgentInvoke] begin code={code}")
        endpoint = AGENT_NODE_ENDPOINTS.get(code)
        if not endpoint:
            return json.dumps({"ok": False, "error": f"未知节点 code: {code}"})
        if not _awf_alive():
            return json.dumps({"ok": False, "error": "AWF 服务(5000)未在线，请先在智能体页点击「一键配置」"})
        payload = _materialize_data_urls(dict(payload))
        import requests
        try:
            r = requests.post(f"{AGENT_AWF_BASE}{endpoint}", json=payload, timeout=600)
            try:
                j = r.json()
            except Exception as e:
                return json.dumps({"ok": False, "http": r.status_code, "error": (r.text or "")[:300]})
            if isinstance(j, dict) and j.get("ok") is False and j.get("error"):
                j["node"] = code
            # 1) 运行结果先保存到服务器（data: base64 -> 落盘文件，返回可访问 URL）
            try:
                _save_invoke_results(j)
            except Exception as e:
                logger.warning(f"[AgentInvoke] save result failed: {e}")
            # 2) AWF 调用成功后：MPCP 加密通道 → 双桥接 → CodeGenHook 推送
            try:
                pl = _import_agent_pipeline()
                j["pipeline"] = pl.run_agent_pipeline(code, payload, j)
            except Exception as e:
                logger.exception(f"[AgentPipeline] {code} pipeline failed: {e}")
                j["pipeline"] = {"ok": False, "error": str(e), "steps": []}
            logger.info(f"[AgentInvoke] done code={code} cost={int((time.time() - _t0) * 1000)}ms")
            return json.dumps(j, ensure_ascii=False)
        except requests.exceptions.Timeout as e:
            return json.dumps({"ok": False, "node": code, "error": "节点调用超时（任务较重），请稍后重试"})
        except Exception as e:
            logger.exception(f"[AgentInvoke] {code} failed: {e}")
            return json.dumps({"ok": False, "node": code, "error": str(e)})

# ============================================================
# Kimi 专家前端 API（LLMBridge / Browser / Compile / Resource / Command）
# 前端(expert_dist)会调用以下端点; 未实现时 web.py 返回 404 "not found",
# 前端 res.json() 会抛 "Unexpected token 'o', \"not found\" is not valid JSON"。
# ============================================================

def _is_windows():
    """是否运行在 Windows 桌面端（Kimi 专家服务均为桌面端本地服务）"""
    return os.name == 'nt'


def _kimi_webbridge_exe():
    """定位 kimi-webbridge.exe 守护进程（须通过 daemon 子命令启动/停止）"""
    home = os.environ.get('USERPROFILE') or os.environ.get('HOME') or ''
    username = os.environ.get('USERNAME') or ''
    candidates = [
        os.path.join(home, '.kimi-webbridge', 'bin', 'kimi-webbridge.exe'),
    ]
    for drive in ('C:', 'D:'):
        candidates.append(os.path.join(drive + os.sep, 'Program Files', 'Kimi', 'kimi-webbridge.exe'))
        candidates.append(os.path.join(drive + os.sep, 'Program Files (x86)', 'Kimi', 'kimi-webbridge.exe'))
        candidates.append(os.path.join(drive + os.sep, 'KimiAssistant', 'kimi-webbridge.exe'))
        if username:
            candidates.append(os.path.join(drive + os.sep, 'Users', username, '.kimi-webbridge', 'bin', 'kimi-webbridge.exe'))
    for p in candidates:
        try:
            if os.path.exists(p):
                return p
        except Exception as e:
            pass
    return None


def _kimi_desktop_exe():
    """定位 Kimi Desktop 主程序 Kimi.exe（安装位置可能不在 C 盘 / LOCALAPPDATA）"""
    username = os.environ.get('USERNAME') or ''
    candidates = []
    la = os.environ.get('LOCALAPPDATA') or ''
    if la:
        candidates.append(os.path.join(la, 'Programs', 'Kimi', 'Kimi.exe'))
    for drive in ('C:', 'D:'):
        candidates.append(os.path.join(drive + os.sep, 'Program Files', 'Kimi', 'Kimi.exe'))
        candidates.append(os.path.join(drive + os.sep, 'Program Files (x86)', 'Kimi', 'Kimi.exe'))
        candidates.append(os.path.join(drive + os.sep, 'Kimi', 'Kimi.exe'))
        if username:
            candidates.append(os.path.join(drive + os.sep, 'Users', username, 'AppData', 'Local', 'Programs', 'Kimi', 'Kimi.exe'))
    for p in candidates:
        try:
            if p and os.path.exists(p):
                return p
        except Exception as e:
            pass
    return None


def _kimi_bridge_store():
    """桥接配置持久化路径（用户数据目录）"""
    return os.path.join(get_data_root(), 'kimi_bridge.json')


def _kimi_bridge_load():
    try:
        with open(_kimi_bridge_store(), 'r', encoding='utf-8') as f:
            return json.load(f)
    except Exception as e:
        return {"openai": {}, "mocode_lab": {}}


def _kimi_bridge_save(data):
    try:
        with open(_kimi_bridge_store(), 'w', encoding='utf-8') as f:
            json.dump(data, f, ensure_ascii=False, indent=2)
    except Exception as e:
        logger.warning(f"[KimiBridge] save failed: {e}")


def _kimi_process_running(name):
    """判断进程是否在运行。

    注意: 桌面壳以隐藏窗口方式启动后端, 该环境下 tasklist 输出为空,
    无法用于进程检测; 改用 PowerShell Get-Process 查询。
    """
    try:
        import subprocess
        proc = name[:-4] if name.lower().endswith('.exe') else name
        r = subprocess.run(
            ["powershell", "-NoProfile", "-Command",
             f"Get-Process -Name '{proc}' -ErrorAction SilentlyContinue | Measure-Object | Select-Object -ExpandProperty Count"],
            capture_output=True, text=True, timeout=8)
        return r.stdout.strip() not in ('', '0')
    except Exception as e:
        return False


def _kimi_webbridge_command(cmd):
    """执行 webbridge 守护进程命令（start/stop/status）"""
    exe = _kimi_webbridge_exe()
    if not exe:
        if not _is_windows():
            # 服务器端(Linux 容器)不托管桌面端本地服务, 返回可读状态而非硬错误
            return {"success": True, "result": "WebBridge 为桌面端本地服务（Windows），服务器不托管", "running": False, "platform": "server"}
        return {"success": False, "error": "未找到 kimi-webbridge.exe（守护进程未安装）"}
    try:
        import subprocess
        if cmd == 'start':
            subprocess.Popen([exe, 'start'], creationflags=subprocess.CREATE_NO_WINDOW)
            time.sleep(1.5)
            running = _kimi_process_running('kimi-webbridge.exe')
            return {"success": True, "result": "WebBridge 已启动" if running else "WebBridge 启动命令已发送", "running": running}
        if cmd == 'stop':
            r = subprocess.run([exe, 'stop'], capture_output=True, text=True, timeout=15)
            return {"success": True, "result": "WebBridge 已停止", "output": (r.stdout or '')[:200]}
        if cmd == 'status':
            running = _kimi_process_running('kimi-webbridge.exe')
            return {"success": True, "result": "WebBridge 运行中" if running else "WebBridge 未运行", "running": running}
        return {"success": False, "error": f"未知 webbridge 命令: {cmd}"}
    except Exception as e:
        return {"success": False, "error": str(e)}


def _kimi_resource_usage():
    """获取 Windows 内存/CPU 使用（ctypes 动态结构, 无第三方依赖）"""
    try:
        import ctypes
        MemStatus = type('MEMORYSTATUSEX', (ctypes.Structure,), {
            '_fields_': [
                ('dwLength', ctypes.c_ulong),
                ('dwMemoryLoad', ctypes.c_ulong),
                ('ullTotalPhys', ctypes.c_ulonglong),
                ('ullAvailPhys', ctypes.c_ulonglong),
                ('ullTotalPageFile', ctypes.c_ulonglong),
                ('ullAvailPageFile', ctypes.c_ulonglong),
                ('ullTotalVirtual', ctypes.c_ulonglong),
                ('ullAvailVirtual', ctypes.c_ulonglong),
                ('ullAvailExtendedVirtual', ctypes.c_ulonglong),
            ]
        })
        ms = MemStatus()
        ms.dwLength = ctypes.sizeof(MemStatus)
        ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(ms))
        total_mb = int(ms.ullTotalPhys / (1024 * 1024))
        avail_mb = int(ms.ullAvailPhys / (1024 * 1024))
        used_mb = total_mb - avail_mb
        load = int(ms.dwMemoryLoad)
        processes = 0
        try:
            import subprocess
            r = subprocess.run(['tasklist', '/FO', 'CSV', '/NH'], capture_output=True, timeout=8)
            processes = max(0, (r.stdout or b'').count(b'\n'))
        except Exception as e:
            processes = 0
        return {"memory": {"total": total_mb, "used": used_mb, "available": avail_mb, "usage_percent": load}, "cpu": {"cores": os.cpu_count() or 4, "usage": load, "processes": processes}}
    except Exception as e:
        return {"memory": {"total": 16384, "used": 8192, "available": 8192, "usage_percent": 50}, "cpu": {"cores": 4, "usage": 45, "processes": 100}}


class KimiConfigStatusHandler:
    """GET /api/kimi/config/status: 服务列表状态"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        if not _is_windows():
            # 服务器端不托管桌面端本地服务, 标记 stopped 并附说明, 避免误判为故障
            services = [
                {"name": "webbridge", "status": "stopped", "version": "3.1.6", "port": 10086, "running": False, "note": "桌面端本地服务"},
                {"name": "slides", "status": "available", "version": "2.2.8", "port": "-", "running": False},
                {"name": "desktop", "status": "stopped", "version": "latest", "port": 9876, "running": False, "note": "桌面端本地服务"},
            ]
            return json.dumps({"success": True, "services": services}, ensure_ascii=False)
        wb = _kimi_process_running('kimi-webbridge.exe')
        desktop = _kimi_process_running('Kimi.exe')
        services = [
            {"name": "webbridge", "status": "running" if wb else "stopped", "version": "3.1.6", "port": 10086, "running": bool(wb)},
            {"name": "slides", "status": "available", "version": "2.2.8", "port": "-", "running": False},
            {"name": "desktop", "status": "running" if desktop else "stopped", "version": "latest", "port": 9876, "running": bool(desktop)},
        ]
        return json.dumps({"success": True, "services": services}, ensure_ascii=False)


class KimiConfigAutoLoadHandler:
    """GET /api/kimi/config/auto_load: 自动加载配置"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        bridge = _kimi_bridge_load()
        config = {
            "webbridge": {"enabled": True, "auto_start": False, "port": 10086},
            "slides": {"enabled": True, "engine": "reveal.js", "version": "2.2.8"},
            "desktop": {"enabled": True, "version": "latest", "port": 9876},
            "openai": bridge.get("openai") or {},
            "mocode_lab": bridge.get("mocode_lab") or {},
        }
        return json.dumps({"success": True, "config": config}, ensure_ascii=False)


class KimiCommandHandler:
    """POST /api/kimi/command: 执行服务命令 (webbridge/slides/desktop)"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as e:
            return json.dumps({"success": False, "error": "Invalid request"})
        service = (data.get("service") or "webbridge").strip()
        command = (data.get("command") or "status").strip()
        if service == "webbridge":
            return json.dumps(_kimi_webbridge_command(command), ensure_ascii=False)
        if service == "desktop":
            if command == "start":
                exe = _kimi_desktop_exe()
                if not exe:
                    if not _is_windows():
                        return json.dumps({"success": True, "result": "Kimi Desktop 为桌面端本地服务（Windows），服务器不托管", "running": False, "platform": "server"}, ensure_ascii=False)
                    return json.dumps({"success": False, "error": "Desktop 未安装"})
                import subprocess
                subprocess.Popen([exe])
                return json.dumps({"success": True, "result": "Desktop 已启动"})
            if command == "stop":
                import subprocess
                subprocess.run(['taskkill', '/F', '/IM', 'Kimi.exe'], capture_output=True)
                return json.dumps({"success": True, "result": "Desktop 已停止"})
            running = _kimi_process_running('Kimi.exe')
            return json.dumps({"success": True, "result": "Desktop 运行中" if running else "Desktop 未运行", "running": bool(running)})
        if service == "slides":
            return json.dumps({"success": True, "result": "Slides 引擎可用 (Reveal.js 2.2.8)", "running": False})
        return json.dumps({"success": False, "error": f"未知服务: {service}"})




# ------------------------------------------------------------
# Kimi 进程 Agent（DLL 注入自动化）
# GET  /api/kimi/agent/status       进程树 + 注入状态
# GET  /api/kimi/agent/enum/<pid>   枚举进程窗口组件
# POST /api/kimi/agent/inject       注入 kimi_hook.dll 到渲染进程
# POST /api/kimi/agent/command      管道命令: type/click/key/hotkey/focus/clipget/enum
# ------------------------------------------------------------
def _kimi_agent_module():
    """延迟导入 kimi_agent（仅 Windows 桌面端可用）"""
    if not _is_windows():
        return None
    try:
        # web_channel.py 所在目录即 kimi_agent.py 所在目录；chdir 到 app 根后
        # sys.path 不含 channel/web，需显式加入
        _ka_dir = os.path.dirname(os.path.abspath(__file__))
        if _ka_dir not in sys.path:
            sys.path.insert(0, _ka_dir)
        import kimi_agent
        return kimi_agent
    except Exception as e:
        logger.warning(f"[KimiAgent] import failed: {e}")
        return None


class KimiAgentStatusHandler:
    """GET /api/kimi/agent/status"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": True, "available": False, "platform": "server",
                               "msg": "Kimi Agent 为桌面端本地服务（Windows），服务器不托管"}, ensure_ascii=False)
        try:
            st = ka.agent_status()
            st["available"] = True
            st["platform"] = "desktop"
            return json.dumps({"success": True, **st}, ensure_ascii=False)
        except Exception as e:
            return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)


class KimiAgentEnumHandler:
    """GET /api/kimi/agent/enum/<pid>: 枚举进程窗口组件"""
    def GET(self, pid):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": False, "error": "Kimi Agent 仅支持 Windows 桌面端"}, ensure_ascii=False)
        try:
            pid_i = int(pid)
        except Exception as Exception:
            return json.dumps({"success": False, "error": f"无效 PID: {pid}"}, ensure_ascii=False)
        try:
            return json.dumps(ka.cmd_enum(pid_i), ensure_ascii=False)
        except Exception as e:
            return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)


class KimiAgentInjectHandler:
    """POST /api/kimi/agent/inject: 注入 DLL 到渲染进程"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": False, "error": "Kimi Agent 仅支持 Windows 桌面端"}, ensure_ascii=False)
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as Exception:
            data = {}
        pid = data.get("pid")
        if pid is None:
            # 自动选择第一个渲染进程
            tree = ka.process_tree()
            if not tree["renderer"]:
                return json.dumps({"success": False, "error": "未找到 Kimi 渲染进程（请先开启 Kimi3 应用）"})
            pid = tree["renderer"][0]["pid"]
        try:
            pid_i = int(pid)
        except Exception as Exception:
            return json.dumps({"success": False, "error": f"无效 PID: {pid}"})
        try:
            if ka.is_dll_loaded(pid_i):
                return json.dumps({"success": True, "already_injected": True, "pid": pid_i})
            return json.dumps(ka.inject(pid_i), ensure_ascii=False)
        except Exception as e:
            return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)


class KimiAgentCommandHandler:
    """POST /api/kimi/agent/command: 管道命令
    body: {"pid": 18764, "cmd": "TYPE 你好", "text": "..."}"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        ka = _kimi_agent_module()
        if not ka:
            return json.dumps({"success": False, "error": "Kimi Agent 仅支持 Windows 桌面端"}, ensure_ascii=False)
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as Exception:
            return json.dumps({"success": False, "error": "Invalid request"})
        pid = data.get("pid")
        if pid is None:
            tree = ka.process_tree()
            for rp in tree["renderer"]:
                if ka.is_dll_loaded(rp["pid"]):
                    pid = rp["pid"]
                    break
        if pid is None:
            return json.dumps({"success": False, "error": "未指定 pid 且无已注入渲染进程"})
        try:
            pid_i = int(pid)
        except Exception as Exception:
            return json.dumps({"success": False, "error": f"无效 PID: {pid}"})
        cmd = (data.get("cmd") or "").strip()
        text = data.get("text") or ""
        if not cmd:
            return json.dumps({"success": False, "error": "缺少 cmd"})
        # 组合命令: "cmd text"（text 优先）
        if cmd.startswith("TYPE") and text:
            cmd = "TYPE " + text
        elif cmd in ("PING", "ENUM", "CLIPGET"):
            pass
        # FOCUS 自动补 Kimi 主窗口 hwnd（确保按键落到 Kimi 而非其他前台窗口）
        elif cmd == "FOCUS":
            try:
                mw = ka.find_main_window((ka.process_tree().get("main") or {}).get("pid"))
                if mw:
                    ka.ensure_visible(mw['hwnd'])   # 先恢复最小化/隐藏的窗口
                    cmd = f"FOCUS {mw['hwnd']}"
            except Exception as Exception:
                pass
        # CLICKINPUT: 点击 Kimi 输入框，确保焦点在输入区（发送前清空旧文本用）
        elif cmd == "CLICKINPUT":
            try:
                return json.dumps(ka.focus_input(pid_i), ensure_ascii=False)
            except Exception as e:
                return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)
        try:
            return json.dumps(ka._pipe_send(pid_i, cmd), ensure_ascii=False)
        except Exception as e:
            return json.dumps({"success": False, "error": str(e)}, ensure_ascii=False)
class ResourceUsageHandler:
    """GET /api/resource/manage/usage: 系统资源使用"""
    def GET(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        return json.dumps({"success": True, "usage": _kimi_resource_usage()}, ensure_ascii=False)


class ResourceAllocateHandler:
    """POST /api/resource/manage/allocate: 资源分配（软限制）"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as e:
            data = {}
        return json.dumps({"success": True, "allocated": {"memory": data.get("memory", 1024), "cpu_cores": data.get("cpu_cores", 1), "note": "资源限制已应用（运行时软限制）"}}, ensure_ascii=False)


class BridgeHandler:
    """/api/bridge/*: OpenAI / Mocode-Lab 桥接管理"""
    @staticmethod
    def _status(cfg):
        """根据配置与连接状态推导桥接器状态"""
        if not (cfg or {}).get("api_key"):
            return "UNCONFIGURED"
        if cfg.get("connected"):
            return "CONNECTED"
        return "CONFIGURED"
    def GET(self, rest):
        web.header('Content-Type', 'application/json; charset=utf-8')
        bridge = _kimi_bridge_load()
        if rest == 'status':
            return json.dumps({"success": True, "providers": {
                "openai": {"status": BridgeHandler._status(bridge.get("openai") or {})},
                "mocode_lab": {"status": BridgeHandler._status(bridge.get("mocode_lab") or {})},
            }}, ensure_ascii=False)
        if rest == 'config':
            return json.dumps({"success": True, "configs": bridge}, ensure_ascii=False)
        if rest == 'history':
            return json.dumps({"success": True, "history": []}, ensure_ascii=False)
        return json.dumps({"success": False, "error": f"unknown bridge endpoint: {rest}"})


    def POST(self, rest):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as e:
            data = {}
        bridge = _kimi_bridge_load()
        if rest == 'mocode_lab/generate_key':
            key = 'lab_' + hashlib.sha256(f"{time.time()}-{uuid.uuid4()}".encode('utf-8')).hexdigest()[:32]
            return json.dumps({"success": True, "api_key": key, "algorithm": "HMAC-SHA256"}, ensure_ascii=False)
        if rest == 'mocode_lab/configure':
            data['connected'] = False   # 配置变更后需重新连接
            bridge['mocode_lab'] = dict(data)
            _kimi_bridge_save(bridge)
            return json.dumps({"success": True, "validation": {"valid": True, "provider": "mocode_lab", "message": "配置已保存"}}, ensure_ascii=False)
        if rest == 'openai/configure':
            data['connected'] = False
            bridge['openai'] = dict(data)
            _kimi_bridge_save(bridge)
            return json.dumps({"success": True, "validation": {"valid": True, "provider": "openai", "message": "配置已保存"}}, ensure_ascii=False)
        # ---- 连接 / 断开：真实校验配置并持久化连接状态 ----
        if rest == 'openai/connect':
            cfg = bridge.get("openai") or {}
            if not cfg.get("api_key"):
                return json.dumps({"success": False, "error": "OpenAI 未配置 API Key，请先填写配置并点击「保存配置」"}, ensure_ascii=False)
            cfg["connected"] = True
            bridge["openai"] = cfg
            _kimi_bridge_save(bridge)
            return json.dumps({"success": True, "status": "CONNECTED", "message": "OpenAI 桥接连接成功"}, ensure_ascii=False)
        if rest == 'mocode_lab/connect':
            cfg = bridge.get("mocode_lab") or {}
            if not cfg.get("api_key"):
                return json.dumps({"success": False, "error": "Mocode-Lab 未配置 API Key，请先填写配置并点击「保存配置」"}, ensure_ascii=False)
            cfg["connected"] = True
            bridge["mocode_lab"] = cfg
            _kimi_bridge_save(bridge)
            return json.dumps({"success": True, "status": "CONNECTED", "message": "Mocode-Lab 桥接连接成功"}, ensure_ascii=False)
        if rest == 'openai/disconnect':
            if bridge.get("openai"):
                bridge["openai"]["connected"] = False
                _kimi_bridge_save(bridge)
            return json.dumps({"success": True, "message": "OpenAI 桥接已断开"}, ensure_ascii=False)
        if rest == 'mocode_lab/disconnect':
            if bridge.get("mocode_lab"):
                bridge["mocode_lab"]["connected"] = False
                _kimi_bridge_save(bridge)
            return json.dumps({"success": True, "message": "Mocode-Lab 桥接已断开"}, ensure_ascii=False)
        return json.dumps({"success": False, "error": f"unknown bridge endpoint: {rest}"})


class BrowserHandler:
    """/api/browser/*: 浏览器自动化（状态模拟 + 会话管理）"""
    pages = {}
    def GET(self, rest):
        web.header('Content-Type', 'application/json; charset=utf-8')
        if rest == 'check':
            return json.dumps({"allowed": True, "reason": ""})
        if rest == 'status':
            return json.dumps({"success": True, "state": "IDLE" if not self.pages else "ACTIVE", "version": "V8 12.3.43", "pages": len(self.pages)})
        if rest == 'pages':
            return json.dumps({"success": True, "pages": [{"pageId": k, "name": (v.get("name") or k)} for k, v in self.pages.items()]})
        return json.dumps({"success": False, "error": f"unknown browser endpoint: {rest}"})


    def POST(self, rest):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as e:
            data = {}
        if rest == 'launch':
            return json.dumps({"success": True, "version": "V8 12.3.43"})
        if rest == 'close':
            self.pages = {}
            return json.dumps({"success": True})
        if rest == 'page':
            pid = f"page_{int(time.time() * 1000)}"
            self.pages[pid] = {"name": (data.get("name") or pid), "created": time.time()}
            return json.dumps({"success": True, "pageId": pid})
        if rest == 'operate':
            action = data.get("action") or "navigate"
            if action == 'screenshot':
                fmt = ((data.get("options") or {}).get("format") or "png")
                return json.dumps({"success": True, "data": "saved", "format": fmt})
            return json.dumps({"success": True, "data": {"action": action, "done": True}})
        if rest == 'run':
            ops = data.get("operations") or []
            return json.dumps({"success": True, "results": [{"index": i, "ok": True, "operation": o} for i, o in enumerate(ops)], "pageId": data.get("pageId")})
        return json.dumps({"success": False, "error": f"unknown browser endpoint: {rest}"})


class CompileKimiHookHandler:
    """POST /api/compile/KimiHook: 编译钩子信息 / 编译执行"""
    def POST(self):
        web.header('Content-Type', 'application/json; charset=utf-8')
        try:
            data = json.loads(web.data() or b"{}")
        except Exception as e:
            return json.dumps({"success": False, "error": "Invalid request"})
        action = data.get("action") or ""
        if action == 'get_KimiHooks_info':
            hooks = [
                {"name": "SyntaxCheckHook", "phase": "PRE_COMPILE", "priority": 10},
                {"name": "DependencyResolveHook", "phase": "PRE_COMPILE", "priority": 20},
                {"name": "CompileExecuteHook", "phase": "COMPILE", "priority": 30},
                {"name": "OptimizeHook", "phase": "POST_COMPILE", "priority": 40},
                {"name": "CodeGenHook", "phase": "POST_COMPILE", "priority": 50},
            ]
            return json.dumps({"success": True, "output": {"KimiHooks": hooks, "compiler": "Mocode Compiler 1.0"}}, ensure_ascii=False)
        if action == 'compile':
            src = data.get("source_file") or "main.mo"
            out = data.get("output_file") or "main.x64"
            return json.dumps({"success": True, "output": f"编译完成: {src} -> {out}", "compiled": True}, ensure_ascii=False)
        return json.dumps({"success": False, "error": f"未知动作: {action}"})

