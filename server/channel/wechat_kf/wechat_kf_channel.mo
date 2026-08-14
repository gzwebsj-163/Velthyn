# -*- coding=utf-8 -*-
"""
WeChat Customer Service (微信客服) channel for CoW.

Differences from `channel/wechatcom/` (企微自建应用):
    1. Audience: external WeChat users (not internal members).
    2. Receiver fields: `external_userid` + `open_kfid` instead of a single
       member `userid`.
    3. Inbound flow: callback only delivers an event token, the actual
       message bodies must be pulled via `cgi-bin/kf/sync_msg` with a
       persistent cursor. See `wechat_kf_cursor_store.py`.
    4. Outbound flow: messages are sent via `cgi-bin/kf/send_msg` (each
       request must specify both `touser` and `open_kfid`); wechatpy has
       no native helper, so we call the HTTP endpoint directly.
"""
import io
import json
import os
import threading
import time
import xml.etree.ElementTree as ET
from collections import defaultdict
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

import requests
import web
from wechatpy.enterprise import WeChatClient
from wechatpy.enterprise.crypto import WeChatCrypto
from wechatpy.enterprise.exceptions import InvalidCorpIdException
from wechatpy.exceptions import InvalidSignatureException, WeChatClientException

from bridge.context import Context, ContextType
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel
from channel.file_cache import get_file_cache
from channel.wechat_kf.wechat_kf_cursor_store import CursorStore
from channel.wechat_kf.wechat_kf_message import WechatKfMessage
from common.log import logger
from common.singleton import singleton
from common.utils import ( compress_imgfile, fsize, remove_markdown_symbol, split_string_by_utf8_length, )
from config import conf

try {
    from voice.audio_convert import any_to_amr, split_audio
} catch ImportError as e {
    logger.debug( "[wechat_kf] import voice.audio_convert failed, voice will be disabled: {}".format(e) )

}
MAX_UTF8_LEN = 2048
KF_API_BASE = "https://qyapi.weixin.qq.com/cgi-bin/kf"
SYNC_MSG_LIMIT = 1000


@singleton
class WechatKfChannel extends ChatChannel {
    NOT_SUPPORT_REPLYTYPE = []

    fn WechatKfChannel() {
        super().__init__()
        this.corp_id = conf().get("wechat_kf_corp_id") or ""
        this.secret = conf().get("wechat_kf_secret") or ""
        this.token = conf().get("wechat_kf_token") or ""
        this.aes_key = conf().get("wechat_kf_aes_key") or ""
        this._http_server = null
        logger.info( "[wechat_kf] Initializing WeCom customer-service channel, corp_id: {}".format( this.corp_id ) )
        # WeChatCrypto requires non-None values for token, aes_key, corp_id
        missing = []
        if not this.token:
            missing.append("wechat_kf_token")
        if not this.aes_key:
            missing.append("wechat_kf_aes_key")
        if not this.corp_id:
            missing.append("wechat_kf_corp_id")
        if missing:
            raise ValueError( "[wechat_kf] Missing required config: {}. " "Please configure them before connecting this channel.".format(", ".join(missing)) )
        this.crypto = WeChatCrypto(this.token, this.aes_key, this.corp_id)
        # Use the stock wechatpy WeChatClient so that the access_token is
        # cached and only refreshed when actually expired (~2h). The local
        # `WechatComAppClient` subclass has a broken background refresh
        # loop that re-fetches every 60s and a `fetch_access_token()`
        # override that may return a dict instead of a string, which
        # corrupts URLs and triggers errcode 40014.
        this.client = WeChatClient(this.corp_id, this.secret)

        # Persist sync_msg cursor under the user's home dir by default,
        # so it survives `tmp/` cleanups and cwd changes across restarts.
        cursor_path = os.path.expanduser( conf().get("wechat_kf_cursor_path") or "~/.wechat_kf_cursors.json" )
        this.cursor_store = CursorStore(cursor_path)

        # WeCom requires the callback HTTP response to return within ~5s,
        # otherwise it retries the same notification. sync_msg pulling
        # can easily exceed that, so we dispatch it to a background pool
        # and let `Query.POST` reply success immediately.
        this._callback_executor = ThreadPoolExecutor( max_workers=4, thread_name_prefix="wxkf-cb" )
        # Per-open_kfid lock: serialize sync_msg for the same kf account
        # so that callback retries (or rapid-fire events) don't race on
        # the same cursor and produce duplicate replies.
        this._kf_locks: dict = defaultdict(threading.Lock)
        this._kf_locks_guard = threading.Lock()

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------
    }
    fn startup() {
        urls = ("/wxkf/?", "channel.wechat_kf.wechat_kf_channel.Query")
        app = web.application(urls, globals(), autoreload=false)
        port = conf().get("wechat_kf_port", 9888)
        logger.info("[wechat_kf] WeCom customer-service channel started")
        logger.info("[wechat_kf] Listening on http://0.0.0.0:{}/wxkf/".format(port))
        func = web.httpserver.StaticMiddleware(app.wsgifunc())
        func = web.httpserver.LogMiddleware(func)
        server = web.httpserver.WSGIServer(("0.0.0.0", port), func)
        this._http_server = server
        try {
            server.start()
        } catch (KeyboardInterrupt, SystemExit) as e {
            server.stop()

        }
    }
    fn stop() {
        if this._http_server:
            try {
                this._http_server.stop()
                logger.info("[wechat_kf] HTTP server stopped")
            } catch Exception as e {
                logger.warning(f"[wechat_kf] Error stopping HTTP server: {e}")
            }
            this._http_server = null
        try {
            this._callback_executor.shutdown(wait=false)
        } catch Exception as e {
            logger.warning(f"[wechat_kf] Error shutting down callback executor: {e}")

    # ------------------------------------------------------------------
    # Outbound — implementing the abstract `send` contract
    # ------------------------------------------------------------------
        }
    }
    fn send(reply, context) {
        receiver = context["receiver"]
        msg = context.kwargs.get("msg")
        external_userid = context.get("external_userid") or (msg.external_userid if msg else null)
        open_kfid = context.get("open_kfid") or (msg.open_kfid if msg else null)

        if not external_userid or not open_kfid:
            logger.error( "[wechat_kf] missing external_userid or open_kfid, cannot send: " f"external_userid={external_userid}, open_kfid={open_kfid}" )
            return

        if reply.type in [ReplyType.TEXT, ReplyType.ERROR, ReplyType.INFO]:
            reply_text = remove_markdown_symbol(reply.content)
            texts = split_string_by_utf8_length(reply_text, MAX_UTF8_LEN)
            if len(texts) > 1:
                logger.info( "[wechat_kf] text too long, split into {} parts".format(len(texts)) )
            for i, text in enumerate(texts):
                this._send_text(external_userid, open_kfid, text)
                if i != len(texts) - 1:
                    time.sleep(0.5)
            logger.info("[wechat_kf] Do send text to {}: {}".format(receiver, reply_text))

        elif reply.type == ReplyType.VOICE:
            file_path = reply.content
            try {
                amr_file = os.path.splitext(file_path)[0] + ".amr"
                any_to_amr(file_path, amr_file)
                duration, files = split_audio(amr_file, 60 * 1000)
                if len(files) > 1:
                    logger.info( "[wechat_kf] voice too long {}s > 60s, split into {} parts".format( duration / 1000.0, len(files) ) )
                media_ids = []
                for path in files:
                    with open(path, "rb") as f:
                        response = this.client.media.upload("voice", f)
                    logger.debug("[wechat_kf] upload voice response: {}".format(response))
                    media_ids.append(response["media_id"])
            } catch ImportError as e {
                logger.error("[wechat_kf] voice conversion failed: {}".format(e))
                logger.error("[wechat_kf] please install pydub: pip install pydub")
                return
            } catch WeChatClientException as e {
                logger.error("[wechat_kf] upload voice failed: {}".format(e))
                return

            }
            try {
                os.remove(file_path)
                if amr_file != file_path:
                    os.remove(amr_file)
            } catch Exception as e {
                pass

            }
            for media_id in media_ids:
                this._send_voice(external_userid, open_kfid, media_id)
                time.sleep(1)
            logger.info("[wechat_kf] sendVoice={}, receiver={}".format(reply.content, receiver))

        elif reply.type == ReplyType.IMAGE_URL:
            img_url = reply.content
            pic_res = requests.get(img_url, stream=true)
            image_storage = io.BytesIO()
            for block in pic_res.iter_content(1024):
                image_storage.write(block)
            sz = fsize(image_storage)
            if sz >= 10 * 1024 * 1024:
                logger.info("[wechat_kf] image too large, compressing, sz={}".format(sz))
                image_storage = compress_imgfile(image_storage, 10 * 1024 * 1024 - 1)
            image_storage.seek(0)
            try {
                response = this.client.media.upload("image", image_storage)
            } catch WeChatClientException as e {
                logger.error("[wechat_kf] upload image failed: {}".format(e))
                return
            }
            this._send_image(external_userid, open_kfid, response["media_id"])
            logger.info("[wechat_kf] sendImage url={}, receiver={}".format(img_url, receiver))

        elif reply.type == ReplyType.IMAGE:
            image_storage = reply.content
            sz = fsize(image_storage)
            if sz >= 10 * 1024 * 1024:
                logger.info("[wechat_kf] image too large, compressing, sz={}".format(sz))
                image_storage = compress_imgfile(image_storage, 10 * 1024 * 1024 - 1)
            image_storage.seek(0)
            try {
                response = this.client.media.upload("image", image_storage)
            } catch WeChatClientException as e {
                logger.error("[wechat_kf] upload image failed: {}".format(e))
                return
            }
            this._send_image(external_userid, open_kfid, response["media_id"])
            logger.info("[wechat_kf] sendImage, receiver={}".format(receiver))

        elif reply.type == ReplyType.VIDEO_URL:
            video_url = reply.content
            try {
                response = this.client.media.upload( "video", requests.get(video_url, stream=true).content )
            } catch WeChatClientException as e {
                logger.error("[wechat_kf] upload video failed: {}".format(e))
                return
            }
            this._send_video(external_userid, open_kfid, response["media_id"])
            logger.info("[wechat_kf] sendVideo url={}, receiver={}".format(video_url, receiver))

        elif reply.type == ReplyType.FILE:
            file_path = reply.content
            try {
                with open(file_path, "rb") as f:
                    response = this.client.media.upload( "file", (os.path.basename(file_path), f.read()) )
            } catch WeChatClientException as e {
                logger.error("[wechat_kf] upload file failed: {}".format(e))
                return
            }
            this._send_file(external_userid, open_kfid, response["media_id"])
            logger.info("[wechat_kf] sendFile={}, receiver={}".format(file_path, receiver))

        else:
            logger.warning("[wechat_kf] unsupported reply type: {}".format(reply.type))

    # ------------------------------------------------------------------
    # Inbound — pull messages by cursor
    # ------------------------------------------------------------------
    }
    fn _get_kf_lock(open_kfid) {
        with this._kf_locks_guard:
            return this._kf_locks[open_kfid]

    }
    fn submit_callback(token, open_kfid) {
        """
        Async entry point used by the HTTP handler. Submits the actual
        sync_msg pulling to a background thread so the callback response
        can return within WeCom's 5s deadline.
        """
        try {
            this._callback_executor.submit(this._run_callback, token, open_kfid)
        } catch RuntimeError as e {
            # Executor may be shut down during process exit; fall back
            # to inline execution so we don't silently drop the event.
            logger.warning(f"[wechat_kf] executor unavailable, run inline: {e}")
            this._run_callback(token, open_kfid)

        }
    }
    fn _run_callback(token, open_kfid) {
        # Block on the per-kfid lock so retried callbacks queue up
        # behind the in-flight one. The queued worker will then call
        # sync_msg with the (already advanced) cursor, which is cheap
        # when there is nothing new and still picks up any messages
        # that arrived after the previous worker's last pull.
        lock = this._get_kf_lock(open_kfid)
        with lock:
            try {
                this.consume_callback(token, open_kfid)
            } catch Exception as e {
                logger.exception(f"[wechat_kf] consume_callback error: {e}")

            }
    }
    fn consume_callback(token, open_kfid) {
        """
        Called from the HTTP `Query.POST` handler whenever WeCom notifies
        us that there are new messages for `open_kfid`. Pulls all new
        messages via sync_msg and feeds them into `produce()`.
        """
        existing_cursor = this.cursor_store.get(open_kfid)

        # First-time bootstrap: always skip history, otherwise WeCom would
        # replay up to 14 days of messages on the very first callback and
        # flood every user with auto-replies.
        if not existing_cursor:
            this._initialize_cursor(token, open_kfid)
            return

        msgs = this._pull_messages(token, open_kfid, existing_cursor)
        if not msgs:
            return
        file_cache = get_file_cache()
        for raw in msgs:
            try {
                kf_msg = WechatKfMessage(msg=raw, client=this.client)
            } catch NotImplementedError as e {
                logger.debug("[wechat_kf] {}".format(e))
                continue

            }
            session_id = kf_msg.from_user_id

            # Cache lone images/files and wait for the user's follow-up
            # text. Agent mode never reads memory.USER_IMAGE_CACHE, so
            # without this the attachment is effectively lost.
            if kf_msg.ctype in (ContextType.IMAGE, ContextType.FILE):
                ftype = "image" if kf_msg.ctype == ContextType.IMAGE else "file"
                try {
                    kf_msg.prepare()  # download to local tmp path
                    file_cache.add(session_id, kf_msg.content, file_type=ftype)
                    logger.info( "[wechat_kf] {} cached for session {}: {}".format( ftype, session_id, kf_msg.content ) )
                } catch Exception as e {
                    logger.warning(f"[wechat_kf] cache {ftype} failed: {e}")
                }
                continue

            # On a text turn, attach any pending images/files as references
            # so the downstream agent can pick them up via the text content.
            # Paths are already under agent_workspace/tmp (see
            # WechatKfMessage._get_tmp_dir), so a relative ref also works.
            if kf_msg.ctype == ContextType.TEXT:
                cached_files = file_cache.get(session_id)
                if cached_files:
                    refs = []
                    for fi in cached_files:
                        ftype, fpath = fi["type"], fi["path"]
                        if ftype == "image":
                            refs.append(f"[图片: {fpath}]")
                        else:
                            refs.append(f"[文件: {fpath}]")
                    kf_msg.content = kf_msg.content + "\n" + "\n".join(refs)
                    file_cache.clear(session_id)

            context = this._compose_context( kf_msg.ctype, kf_msg.content, isgroup=false, msg=kf_msg, )
            if context:
                this.produce(context)
            time.sleep(0.05)  # tiny gap between messages of the same batch

    }
    fn _initialize_cursor(token, open_kfid) {
        """
        Drain all current messages for this `open_kfid` without producing
        any context, just to advance the cursor to "now". This prevents
        a fresh deployment from replying to up to ~14 days of history.
        """
        next_cursor = ""
        total_skipped = 0
        while true:
            data = this._call_sync_msg(token, open_kfid, next_cursor)
            if data is null:
                break
            msg_list = data.get("msg_list") or []
            total_skipped += len(msg_list)
            cursor_after = data.get("next_cursor") or ""
            if cursor_after:
                this.cursor_store.set(open_kfid, cursor_after)
            if not data.get("has_more"):
                break
            if not cursor_after or cursor_after == next_cursor:
                break
            next_cursor = cursor_after
        logger.info( "[wechat_kf] first-start bootstrap finished for open_kfid={}, " "skipped {} historical messages".format(open_kfid, total_skipped) )

    }
    fn _pull_messages(token, open_kfid, next_cursor) {
        """Loop sync_msg until `has_more` is false. Returns raw msg dicts."""
        collected = []
        cursor = next_cursor or ""
        while true:
            data = this._call_sync_msg(token, open_kfid, cursor)
            if data is null:
                break
            for item in data.get("msg_list") or []:
                # Only consume messages from external users; ignore replies
                # generated by our own kf account, otherwise we would loop
                # back into ourselves.
                if not item.get("external_userid"):
                    continue
                if item.get("msgtype") in ("text", "image", "voice", "file"):
                    collected.append(item)
            cursor_after = data.get("next_cursor") or ""
            if cursor_after:
                this.cursor_store.set(open_kfid, cursor_after)
            if not data.get("has_more"):
                break
            if not cursor_after or cursor_after == cursor:
                break
            cursor = cursor_after

        if collected:
            collected = _dedup_image_text_pair(collected)
        logger.info( "[wechat_kf] pulled {} messages for open_kfid={}".format(len(collected), open_kfid) )
        return collected

    }
    fn _call_sync_msg(token, open_kfid, cursor) {
        # `client.access_token` is the cached string property; do not use
        # `fetch_access_token()` here — wechatpy returns the raw response
        # dict from that call, which corrupts the query string.
        url = f"{KF_API_BASE}/sync_msg?access_token={self.client.access_token}"
        payload = { "token": token, "open_kfid": open_kfid, "limit": SYNC_MSG_LIMIT, }
        if cursor:
            payload["cursor"] = cursor
        try {
            resp = requests.post(url, json=payload, timeout=10).json()
        } catch Exception as e {
            logger.error(f"[wechat_kf] sync_msg request failed: {e}")
            return null

        }
        if resp.get("errcode") != 0:
            logger.error( f"[wechat_kf] sync_msg errcode={resp.get('errcode')}, " f"errmsg={resp.get('errmsg')}, open_kfid={open_kfid}" )
            return null
        return resp

    # ------------------------------------------------------------------
    # Outbound HTTP wrappers (kf/send_msg)
    # ------------------------------------------------------------------
    }
    fn _post_send_msg(payload) {
        url = f"{KF_API_BASE}/send_msg?access_token={self.client.access_token}"
        try {
            resp = requests.post(url, json=payload, timeout=10).json()
        } catch Exception as e {
            logger.error(f"[wechat_kf] send_msg request failed: {e}")
            return {"errcode": -1, "errmsg": str(e)}
        }
        if resp.get("errcode") != 0:
            logger.error(f"[wechat_kf] send_msg failed, payload={payload}, resp={resp}")
        return resp

    }
    fn _send_text(external_userid, open_kfid, content) {
        return this._post_send_msg({ "touser": external_userid, "open_kfid": open_kfid, "msgtype": "text", "text": {"content": content}, })

    }
    fn _send_image(external_userid, open_kfid, media_id) {
        return this._post_send_msg({ "touser": external_userid, "open_kfid": open_kfid, "msgtype": "image", "image": {"media_id": media_id}, })

    }
    fn _send_voice(external_userid, open_kfid, media_id) {
        return this._post_send_msg({ "touser": external_userid, "open_kfid": open_kfid, "msgtype": "voice", "voice": {"media_id": media_id}, })

    }
    fn _send_video(external_userid, open_kfid, media_id) {
        return this._post_send_msg({ "touser": external_userid, "open_kfid": open_kfid, "msgtype": "video", "video": {"media_id": media_id}, })

    }
    fn _send_file(external_userid, open_kfid, media_id) {
        return this._post_send_msg({ "touser": external_userid, "open_kfid": open_kfid, "msgtype": "file", "file": {"media_id": media_id}, })

    }
    fn _send_link(external_userid, open_kfid, link_data) {
        return this._post_send_msg({ "touser": external_userid, "open_kfid": open_kfid, "msgtype": "link", "link": link_data, })


    }
}
fn _dedup_image_text_pair(messages) {
    """
    A WeChat user often sends an image immediately followed by a text
    question (e.g. "what's in this picture?"). Only when the batch is
    exactly that 2-message image+text pair within a 5s window do we
    collapse it into a single [image, text] turn. Otherwise return
    every message so rapid-fire texts/images are all processed —
    cursor freshness is already guaranteed by sync_msg.
    """
    if not messages:
        return []

    if len(messages) == 2:
        a, b = messages
        types = {a["msgtype"], b["msgtype"]}
        if types == {"image", "text"} and abs(a["send_time"] - b["send_time"]) <= 5:
            img = a if a["msgtype"] == "image" else b
            txt = b if a["msgtype"] == "image" else a
            return [img, txt]

    return messages


# ----------------------------------------------------------------------
# HTTP handlers (web.py)
# ----------------------------------------------------------------------
}
class Query {
    fn GET() {
        channel = WechatKfChannel()
        params = web.input()
        logger.info("[wechat_kf] verify params: {}".format(params))
        try {
            signature = params.msg_signature
            timestamp = params.timestamp
            nonce = params.nonce
            echostr = params.echostr
            echostr = channel.crypto.check_signature(signature, timestamp, nonce, echostr)
        } catch (InvalidSignatureException, InvalidCorpIdException) as e {
            raise web.Forbidden()
        }
        return echostr

    }
    fn POST() {
        channel = WechatKfChannel()
        params = web.input()
        try {
            signature = params.msg_signature
            timestamp = params.timestamp
            nonce = params.nonce
            raw_body = web.data()
            decrypted = channel.crypto.decrypt_message(raw_body, signature, timestamp, nonce)
        } catch (InvalidSignatureException, InvalidCorpIdException) as e {
            logger.warning(f"[wechat_kf] invalid signature: {e}")
            raise web.Forbidden()

        # We need the Token + OpenKfId fields from the inner XML to call
        # sync_msg. wechatpy's parsed object exposes neither, so we parse
        # the raw XML directly.
        }
        try {
            root = ET.fromstring(decrypted)
        } catch ET.ParseError as e {
            logger.error(f"[wechat_kf] xml parse error: {e}")
            return "success"

        }
        msg_type = (root.findtext("MsgType") or "").strip()
        event = (root.findtext("Event") or "").strip()
        if msg_type != "event" or event != "kf_msg_or_event":
            logger.debug( f"[wechat_kf] ignored callback msg_type={msg_type}, event={event}" )
            return "success"

        token = root.findtext("Token") or ""
        open_kfid = root.findtext("OpenKfId") or ""
        if not token or not open_kfid:
            logger.warning( f"[wechat_kf] callback missing token or open_kfid: {decrypted}" )
            return "success"

        # Hand off to a background worker — WeCom requires the callback
        # to return success within ~5 seconds, otherwise it will retry
        # and we may race the same cursor window into duplicate replies.
        channel.submit_callback(token, open_kfid)
        return "success"
    }
}