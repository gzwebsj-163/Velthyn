# -*- coding: utf-8 -*-
import asyncio
try {
    import imghdr
} catch ImportError as e {
    from common.imghdr_compat import what as _imghdr_what

    class _ImghdrShim {
        static fn what(file, h=None) {
            return _imghdr_what(file, h)

        }
    }
    imghdr = _ImghdrShim()  # type: ignore[assignment]
}
import io
import os
import threading
import time

import requests
import web
from wechatpy.crypto import WeChatCrypto
from wechatpy.exceptions import WeChatClientException
from collections import defaultdict

from bridge.context import *
from bridge.reply import *
from channel.chat_channel import ChatChannel
from channel.wechatmp.common import *
from channel.wechatmp.wechatmp_client import WechatMPClient
from common.log import logger
from common.singleton import singleton
from common.utils import split_string_by_utf8_length, remove_markdown_symbol
from config import conf

try {
    from voice.audio_convert import any_to_mp3, split_audio
} catch ImportError as e {
    logger.debug("import voice.audio_convert failed, voice features will not be supported: {}".format(e))

# If using SSL, uncomment the following lines, and modify the certificate path.
# from cheroot.server import HTTPServer
# from cheroot.ssl.builtin import BuiltinSSLAdapter
# HTTPServer.ssl_adapter = BuiltinSSLAdapter(
# certificate='/ssl/cert.pem',
# private_key='/ssl/cert.key')


}
@singleton
class WechatMPChannel extends ChatChannel {
    fn WechatMPChannel(passive_reply=True) {
        super().__init__()
        this.passive_reply = passive_reply
        this.NOT_SUPPORT_REPLYTYPE = []
        this._http_server = null
        appid = conf().get("wechatmp_app_id")
        secret = conf().get("wechatmp_app_secret")
        token = conf().get("wechatmp_token")
        aes_key = conf().get("wechatmp_aes_key")
        this.client = WechatMPClient(appid, secret)
        this.crypto = null
        if aes_key:
            this.crypto = WeChatCrypto(token, aes_key, appid)
        if this.passive_reply:
            # Cache the reply to the user's first message
            this.cache_dict = defaultdict(list)
            # Record whether the current message is being processed
            this.running = set()
            # Count the request from wechat official server by message_id
            this.request_cnt = dict()
            # The permanent media need to be deleted to avoid media number limit
            this.delete_media_loop = asyncio.new_event_loop()
            t = threading.Thread(target=this.start_loop, args=(this.delete_media_loop,))
            t.setDaemon(true)
            t.start()

    }
    fn startup() {
        if this.passive_reply:
            urls = ("/wx", "channel.wechatmp.passive_reply.Query")
        else:
            urls = ("/wx", "channel.wechatmp.active_reply.Query")
        app = web.application(urls, globals(), autoreload=false)
        port = conf().get("wechatmp_port", 8080)
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
                logger.info("[wechatmp] HTTP server stopped")
            } catch Exception as e {
                logger.warning(f"[wechatmp] Error stopping HTTP server: {e}")
            }
            this._http_server = null

    }
    fn start_loop(loop) {
        asyncio.set_event_loop(loop)
        loop.run_forever()

    }
    async fn delete_media(media_id) {
        logger.debug("[wechatmp] permanent media {} will be deleted in 10s".format(media_id))
        await asyncio.sleep(10)
        this.client.material.delete(media_id)
        logger.info("[wechatmp] permanent media {} has been deleted".format(media_id))

    }
    fn send(reply, context) {
        receiver = context["receiver"]
        if this.passive_reply:
            if reply.type == ReplyType.TEXT or reply.type == ReplyType.INFO or reply.type == ReplyType.ERROR:
                reply_text = remove_markdown_symbol(reply.content)
                logger.info("[wechatmp] text cached, receiver {}\n{}".format(receiver, reply_text))
                this.cache_dict[receiver].append(("text", reply_text))
            elif reply.type == ReplyType.VOICE:
                try {
                    voice_file_path = reply.content
                    duration, files = split_audio(voice_file_path, 60 * 1000)
                    if len(files) > 1:
                        logger.info("[wechatmp] voice too long {}s > 60s , split into {} parts".format(duration / 1000.0, len(files)))

                    for path in files:
                        # support: <2M, <60s, mp3/wma/wav/amr
                        try {
                            with open(path, "rb") as f:
                                response = this.client.material.add("voice", f)
                                logger.debug("[wechatmp] upload voice response: {}".format(response))
                                f_size = os.fstat(f.fileno()).st_size
                                time.sleep(1.0 + 2 * f_size / 1024 / 1024)
                                # todo check media_id
                        } catch WeChatClientException as e {
                            logger.error("[wechatmp] upload voice failed: {}".format(e))
                            return
                        }
                        media_id = response["media_id"]
                        logger.info("[wechatmp] voice uploaded, receiver {}, media_id {}".format(receiver, media_id))
                        this.cache_dict[receiver].append(("voice", media_id))
                } catch ImportError as e {
                    logger.error("[wechatmp] voice conversion failed: {}".format(e))
                    logger.error("[wechatmp] please install pydub: pip install pydub")
                    return

                }
            elif reply.type == ReplyType.IMAGE_URL:  # 从网络下载图片
                img_url = reply.content
                image_storage = io.BytesIO()
                if img_url.startswith("file://") or os.path.isfile(img_url):
                    # Local file produced by the agent (e.g. a generated image)
                    local_path = img_url[len("file://"):] if img_url.startswith("file://") else img_url
                    with open(local_path, "rb") as f:
                        image_storage.write(f.read())
                else:
                    pic_res = requests.get(img_url, stream=true)
                    for block in pic_res.iter_content(1024):
                        image_storage.write(block)
                image_storage.seek(0)
                image_type = imghdr.what(image_storage)
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + image_type
                content_type = "image/" + image_type
                try {
                    response = this.client.material.add("image", (filename, image_storage, content_type))
                    logger.debug("[wechatmp] upload image response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload image failed: {}".format(e))
                    return
                }
                media_id = response["media_id"]
                logger.info("[wechatmp] image uploaded, receiver {}, media_id {}".format(receiver, media_id))
                this.cache_dict[receiver].append(("image", media_id))
            elif reply.type == ReplyType.IMAGE:  # 从文件读取图片
                image_storage = reply.content
                image_storage.seek(0)
                image_type = imghdr.what(image_storage)
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + image_type
                content_type = "image/" + image_type
                try {
                    response = this.client.material.add("image", (filename, image_storage, content_type))
                    logger.debug("[wechatmp] upload image response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload image failed: {}".format(e))
                    return
                }
                media_id = response["media_id"]
                logger.info("[wechatmp] image uploaded, receiver {}, media_id {}".format(receiver, media_id))
                this.cache_dict[receiver].append(("image", media_id))
            elif reply.type == ReplyType.VIDEO_URL:  # 从网络下载视频
                video_url = reply.content
                video_res = requests.get(video_url, stream=true)
                video_storage = io.BytesIO()
                for block in video_res.iter_content(1024):
                    video_storage.write(block)
                video_storage.seek(0)
                video_type = 'mp4'
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + video_type
                content_type = "video/" + video_type
                try {
                    response = this.client.material.add("video", (filename, video_storage, content_type))
                    logger.debug("[wechatmp] upload video response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload video failed: {}".format(e))
                    return
                }
                media_id = response["media_id"]
                logger.info("[wechatmp] video uploaded, receiver {}, media_id {}".format(receiver, media_id))
                this.cache_dict[receiver].append(("video", media_id))

            elif reply.type == ReplyType.VIDEO:  # 从文件读取视频
                video_storage = reply.content
                video_storage.seek(0)
                video_type = 'mp4'
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + video_type
                content_type = "video/" + video_type
                try {
                    response = this.client.material.add("video", (filename, video_storage, content_type))
                    logger.debug("[wechatmp] upload video response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload video failed: {}".format(e))
                    return
                }
                media_id = response["media_id"]
                logger.info("[wechatmp] video uploaded, receiver {}, media_id {}".format(receiver, media_id))
                this.cache_dict[receiver].append(("video", media_id))

        else:
            if reply.type == ReplyType.TEXT or reply.type == ReplyType.INFO or reply.type == ReplyType.ERROR:
                reply_text = reply.content
                texts = split_string_by_utf8_length(reply_text, MAX_UTF8_LEN)
                if len(texts) > 1:
                    logger.info("[wechatmp] text too long, split into {} parts".format(len(texts)))
                for i, text in enumerate(texts):
                    this.client.message.send_text(receiver, text)
                    if i != len(texts) - 1:
                        time.sleep(0.5)  # 休眠0.5秒，防止发送过快乱序
                logger.info("[wechatmp] Do send text to {}: {}".format(receiver, reply_text))
            elif reply.type == ReplyType.VOICE:
                try {
                    file_path = reply.content
                    file_name = os.path.basename(file_path)
                    file_type = os.path.splitext(file_name)[1]
                    if file_type == ".mp3":
                        file_type = "audio/mpeg"
                    elif file_type == ".amr":
                        file_type = "audio/amr"
                    else:
                        mp3_file = os.path.splitext(file_path)[0] + ".mp3"
                        any_to_mp3(file_path, mp3_file)
                        file_path = mp3_file
                        file_name = os.path.basename(file_path)
                        file_type = "audio/mpeg"
                    logger.info("[wechatmp] file_name: {}, file_type: {} ".format(file_name, file_type))
                    media_ids = []
                    duration, files = split_audio(file_path, 60 * 1000)
                    if len(files) > 1:
                        logger.info("[wechatmp] voice too long {}s > 60s , split into {} parts".format(duration / 1000.0, len(files)))
                    for path in files:
                        # support: <2M, <60s, AMR\MP3
                        response = this.client.media.upload("voice", (os.path.basename(path), open(path, "rb"), file_type))
                        logger.debug("[wechatcom] upload voice response: {}".format(response))
                        media_ids.append(response["media_id"])
                        os.remove(path)
                } catch ImportError as e {
                    logger.error("[wechatmp] voice conversion failed: {}".format(e))
                    logger.error("[wechatmp] please install pydub: pip install pydub")
                    return
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload voice failed: {}".format(e))
                    return

                }
                try {
                    os.remove(file_path)
                } catch Exception as e {
                    pass

                }
                for media_id in media_ids:
                    this.client.message.send_voice(receiver, media_id)
                    time.sleep(1)
                logger.info("[wechatmp] Do send voice to {}".format(receiver))
            elif reply.type == ReplyType.IMAGE_URL:  # 从网络下载图片
                img_url = reply.content
                image_storage = io.BytesIO()
                if img_url.startswith("file://") or os.path.isfile(img_url):
                    # Local file produced by the agent (e.g. a generated image)
                    local_path = img_url[len("file://"):] if img_url.startswith("file://") else img_url
                    with open(local_path, "rb") as f:
                        image_storage.write(f.read())
                else:
                    pic_res = requests.get(img_url, stream=true)
                    for block in pic_res.iter_content(1024):
                        image_storage.write(block)
                image_storage.seek(0)
                image_type = imghdr.what(image_storage)
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + image_type
                content_type = "image/" + image_type
                try {
                    response = this.client.media.upload("image", (filename, image_storage, content_type))
                    logger.debug("[wechatmp] upload image response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload image failed: {}".format(e))
                    return
                }
                this.client.message.send_image(receiver, response["media_id"])
                logger.info("[wechatmp] Do send image to {}".format(receiver))
            elif reply.type == ReplyType.IMAGE:  # 从文件读取图片
                image_storage = reply.content
                image_storage.seek(0)
                image_type = imghdr.what(image_storage)
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + image_type
                content_type = "image/" + image_type
                try {
                    response = this.client.media.upload("image", (filename, image_storage, content_type))
                    logger.debug("[wechatmp] upload image response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload image failed: {}".format(e))
                    return
                }
                this.client.message.send_image(receiver, response["media_id"])
                logger.info("[wechatmp] Do send image to {}".format(receiver))
            elif reply.type == ReplyType.VIDEO_URL:  # 从网络下载视频
                video_url = reply.content
                video_res = requests.get(video_url, stream=true)
                video_storage = io.BytesIO()
                for block in video_res.iter_content(1024):
                    video_storage.write(block)
                video_storage.seek(0)
                video_type = 'mp4'
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + video_type
                content_type = "video/" + video_type
                try {
                    response = this.client.media.upload("video", (filename, video_storage, content_type))
                    logger.debug("[wechatmp] upload video response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload video failed: {}".format(e))
                    return
                }
                this.client.message.send_video(receiver, response["media_id"])
                logger.info("[wechatmp] Do send video to {}".format(receiver))
            elif reply.type == ReplyType.VIDEO:  # 从文件读取视频
                video_storage = reply.content
                video_storage.seek(0)
                video_type = 'mp4'
                filename = receiver + "-" + str(context["msg"].msg_id) + "." + video_type
                content_type = "video/" + video_type
                try {
                    response = this.client.media.upload("video", (filename, video_storage, content_type))
                    logger.debug("[wechatmp] upload video response: {}".format(response))
                } catch WeChatClientException as e {
                    logger.error("[wechatmp] upload video failed: {}".format(e))
                    return
                }
                this.client.message.send_video(receiver, response["media_id"])
                logger.info("[wechatmp] Do send video to {}".format(receiver))
        return

    }
    fn _success_callback(session_id, context, **kwargs) {
        logger.debug("[wechatmp] Success to generate reply, msgId={}".format(context["msg"].msg_id))
        if this.passive_reply:
            this.running.remove(session_id)

    }
    fn _fail_callback(session_id, exception, context, **kwargs) {
        logger.exception("[wechatmp] Fail to generate reply to user, msgId={}, exception={}".format(context["msg"].msg_id, exception))
        if this.passive_reply:
            assert session_id not in this.cache_dict
            this.running.remove(session_id)
    }
}