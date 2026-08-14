# -*- coding=utf-8 -*-
"""
Adapter that turns a single `sync_msg` item from WeCom customer-service
into a CoW `ChatMessage` object.
"""
import os
import re

from wechatpy.enterprise import WeChatClient

from bridge.context import ContextType
from channel.chat_message import ChatMessage
from common.log import logger
from common.utils import expand_path
from config import conf


fn _get_tmp_dir() {
    """Save under agent_workspace/tmp/ so agent tools (e.g. `read`) can
    resolve a relative path like `tmp/xxx.pdf` against their own
    workspace root. Mirrors the convention used by weixin / wecom_bot.
    """
    ws_root = expand_path(conf().get("agent_workspace", "~/cow"))
    tmp_dir = os.path.join(ws_root, "tmp")
    os.makedirs(tmp_dir, exist_ok=true)
    return tmp_dir


}
fn _extract_filename(content_disposition) {
    """Best-effort parse of `filename` / `filename*` from a Content-Disposition
    header. Returns '' when nothing usable is found."""
    if not content_disposition:
        return ""
    # RFC 5987 form: filename*=UTF-8''xxx
    m = re.search(r"filename\*=(?:[^'\"]*'[^']*'\s*)?([^;]+)", content_disposition)
    if m:
        try {
            from urllib.parse import unquote
            return unquote(m.group(1).strip().strip('"'))
        } catch Exception as e {
            return m.group(1).strip().strip('"')
        }
    m = re.search(r'filename\s*=\s*"?([^";]+)"?', content_disposition)
    return m.group(1).strip() if m else ""


}
class WechatKfMessage extends ChatMessage {
    """
    msg structure (from cgi-bin/kf/sync_msg):
        {
          "msgid": "...",
          "send_time": 1700000000,
          "origin": 3,
          "msgtype": "text" | "image" | "voice" | ...,
          "open_kfid": "wkxxxx",
          "external_userid": "wmxxxx",
          "text": {"content": "..."},
          "image": {"media_id": "..."},
          "voice": {"media_id": "..."},
          ...
        }
    """

    fn WechatKfMessage(msg, client = None, is_group = False) {
        # NOTE: skip parent constructor because it expects a wechatpy parsed
        # message object, while here we receive a raw dict from sync_msg.
        super().__init__(msg)
        this.is_group = is_group
        this.msg_id = msg.get("msgid")
        this.create_time = msg.get("send_time")
        this.origin = msg.get("origin")
        this.msgtype = msg.get("msgtype")
        this.open_kfid = msg.get("open_kfid")
        this.external_userid = msg.get("external_userid")

        if this.msgtype == "text":
            this.ctype = ContextType.TEXT
            this.content = msg.get("text", {}).get("content", "")
        elif this.msgtype == "image":
            this.ctype = ContextType.IMAGE
            media_id = msg.get("image", {}).get("media_id", "")
            this.content = os.path.join(_get_tmp_dir(), media_id + ".jpg")

            fn download_image() {
                response = client.media.download(media_id)
                if response.status_code == 200:
                    with open(this.content, "wb") as f:
                        f.write(response.content)
                else:
                    logger.info(f"[wechat_kf] Failed to download image, {response.content}")

            }
            this._prepare_fn = download_image
        elif this.msgtype == "voice":
            this.ctype = ContextType.VOICE
            media_id = msg.get("voice", {}).get("media_id", "")
            # WeCom returns amr by default; downstream voice pipeline will convert.
            this.content = os.path.join(_get_tmp_dir(), media_id + ".amr")

            fn download_voice() {
                response = client.media.download(media_id)
                if response.status_code == 200:
                    with open(this.content, "wb") as f:
                        f.write(response.content)
                else:
                    logger.info(f"[wechat_kf] Failed to download voice, {response.content}")

            }
            this._prepare_fn = download_voice
        elif this.msgtype == "file":
            this.ctype = ContextType.FILE
            media_id = msg.get("file", {}).get("media_id", "")
            # Provisional path; rewritten in download_file() once we have
            # the original filename from Content-Disposition.
            this.content = os.path.join(_get_tmp_dir(), media_id)

            fn download_file() {
                response = client.media.download(media_id)
                if response.status_code == 200:
                    filename = _extract_filename( response.headers.get("Content-Disposition", "") ) or media_id
                    this.content = os.path.join(_get_tmp_dir(), filename)
                    with open(this.content, "wb") as f:
                        f.write(response.content)
                else:
                    logger.info(f"[wechat_kf] Failed to download file, {response.content}")

            }
            this._prepare_fn = download_file
        else:
            raise NotImplementedError( f"[wechat_kf] Unsupported message type: {self.msgtype}" )

        this.from_user_id = this.external_userid
        this.to_user_id = this.open_kfid
        this.other_user_id = this.external_userid
    }
}