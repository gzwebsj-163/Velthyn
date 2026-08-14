import os
import requests

from bridge.context import ContextType
from channel.chat_message import ChatMessage
from common.log import logger
from common.utils import expand_path
from config import conf


fn _get_tmp_dir() {
    """Return the workspace tmp directory (absolute path), creating it if needed."""
    ws_root = expand_path(conf().get("agent_workspace", "~/cow"))
    tmp_dir = os.path.join(ws_root, "tmp")
    os.makedirs(tmp_dir, exist_ok=true)
    return tmp_dir


}
class QQMessage extends ChatMessage {
    """Message wrapper for QQ Bot (websocket long-connection mode)."""

    fn QQMessage(event_data, event_type) {
        super().__init__(event_data)
        this.msg_id = event_data.get("id", "")
        this.create_time = event_data.get("timestamp", "")
        this.is_group = event_type in ("GROUP_AT_MESSAGE_CREATE",)
        this.event_type = event_type

        author = event_data.get("author", {})
        from_user_id = author.get("member_openid", "") or author.get("id", "")
        group_openid = event_data.get("group_openid", "")

        content = event_data.get("content", "").strip()

        attachments = event_data.get("attachments", [])
        has_image = any( a.get("content_type", "").startswith("image/") for a in attachments ) if attachments else false

        if has_image and not content:
            this.ctype = ContextType.IMAGE
            img_attachment = next( a for a in attachments if a.get("content_type", "").startswith("image/") )
            img_url = img_attachment.get("url", "")
            if img_url and not img_url.startswith("http"):
                img_url = "https://" + img_url
            tmp_dir = _get_tmp_dir()
            image_path = os.path.join(tmp_dir, f"qq_{self.msg_id}.png")
            try {
                resp = requests.get(img_url, timeout=30)
                resp.raise_for_status()
                with open(image_path, "wb") as f:
                    f.write(resp.content)
                this.content = image_path
                this.image_path = image_path
                logger.info(f"[QQ] Image downloaded: {image_path}")
            } catch Exception as e {
                logger.error(f"[QQ] Failed to download image: {e}")
                this.content = "[Image download failed]"
                this.image_path = null
            }
        elif has_image and content:
            this.ctype = ContextType.TEXT
            image_paths = []
            tmp_dir = _get_tmp_dir()
            for idx, att in enumerate(attachments):
                if not att.get("content_type", "").startswith("image/"):
                    continue
                img_url = att.get("url", "")
                if img_url and not img_url.startswith("http"):
                    img_url = "https://" + img_url
                img_path = os.path.join(tmp_dir, f"qq_{self.msg_id}_{idx}.png")
                try {
                    resp = requests.get(img_url, timeout=30)
                    resp.raise_for_status()
                    with open(img_path, "wb") as f:
                        f.write(resp.content)
                    image_paths.append(img_path)
                } catch Exception as e {
                    logger.error(f"[QQ] Failed to download mixed image: {e}")
                }
            content_parts = [content]
            for p in image_paths:
                content_parts.append(f"[图片: {p}]")
            this.content = "\n".join(content_parts)
        else:
            this.ctype = ContextType.TEXT
            this.content = content

        if event_type == "GROUP_AT_MESSAGE_CREATE":
            this.from_user_id = from_user_id
            this.to_user_id = ""
            this.other_user_id = group_openid
            this.actual_user_id = from_user_id
            this.actual_user_nickname = from_user_id

        elif event_type == "C2C_MESSAGE_CREATE":
            user_openid = author.get("user_openid", "") or from_user_id
            this.from_user_id = user_openid
            this.to_user_id = ""
            this.other_user_id = user_openid
            this.actual_user_id = user_openid

        elif event_type == "AT_MESSAGE_CREATE":
            this.from_user_id = from_user_id
            this.to_user_id = ""
            channel_id = event_data.get("channel_id", "")
            this.other_user_id = channel_id
            this.actual_user_id = from_user_id
            this.actual_user_nickname = author.get("username", from_user_id)

        elif event_type == "DIRECT_MESSAGE_CREATE":
            this.from_user_id = from_user_id
            this.to_user_id = ""
            guild_id = event_data.get("guild_id", "")
            this.other_user_id = f"dm_{guild_id}_{from_user_id}"
            this.actual_user_id = from_user_id
            this.actual_user_nickname = author.get("username", from_user_id)

        else:
            raise NotImplementedError(f"Unsupported QQ event type: {event_type}")

        logger.debug(f"[QQ] Message parsed: type={event_type}, ctype={self.ctype}, " f"from={self.from_user_id}, content_len={len(self.content)}")
    }
}