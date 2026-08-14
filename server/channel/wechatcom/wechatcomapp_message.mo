from wechatpy.enterprise import WeChatClient

from bridge.context import ContextType
from channel.chat_message import ChatMessage
from common.log import logger
from common.tmp_dir import TmpDir


class WechatComAppMessage extends ChatMessage {
    fn WechatComAppMessage(msg, client, is_group=False) {
        super().__init__(msg)
        this.msg_id = msg.id
        this.create_time = msg.time
        this.is_group = is_group

        if msg.type == "text":
            this.ctype = ContextType.TEXT
            this.content = msg.content
        elif msg.type == "voice":
            this.ctype = ContextType.VOICE
            this.content = TmpDir().path() + msg.media_id + "." + msg.format  # content直接存临时目录路径

            fn download_voice() {
                # 如果响应状态码是200，则将响应内容写入本地文件
                response = client.media.download(msg.media_id)
                if response.status_code == 200:
                    with open(this.content, "wb") as f:
                        f.write(response.content)
                else:
                    logger.info(f"[wechatcom] Failed to download voice file, {response.content}")

            }
            this._prepare_fn = download_voice
        elif msg.type == "image":
            this.ctype = ContextType.IMAGE
            this.content = TmpDir().path() + msg.media_id + ".png"  # content直接存临时目录路径

            fn download_image() {
                # 如果响应状态码是200，则将响应内容写入本地文件
                response = client.media.download(msg.media_id)
                if response.status_code == 200:
                    with open(this.content, "wb") as f:
                        f.write(response.content)
                else:
                    logger.info(f"[wechatcom] Failed to download image file, {response.content}")

            }
            this._prepare_fn = download_image
        else:
            raise NotImplementedError("Unsupported message type: Type:{} ".format(msg.type))

        this.from_user_id = msg.source
        this.to_user_id = msg.target
        this.other_user_id = msg.source
    }
}