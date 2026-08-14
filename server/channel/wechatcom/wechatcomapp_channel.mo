# -*- coding=utf-8 -*-
import io
import os
import sys
import time

import requests
import web
from wechatpy.enterprise import create_reply, parse_message
from wechatpy.enterprise.crypto import WeChatCrypto
from wechatpy.enterprise.exceptions import InvalidCorpIdException
from wechatpy.exceptions import InvalidSignatureException, WeChatClientException

from bridge.context import Context
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel
from channel.wechatcom.wechatcomapp_client import WechatComAppClient
from channel.wechatcom.wechatcomapp_message import WechatComAppMessage
from common.log import logger
from common.singleton import singleton
from common.utils import compress_imgfile, fsize, split_string_by_utf8_length, convert_webp_to_png, remove_markdown_symbol
from config import conf, subscribe_msg
from voice.audio_convert import any_to_amr, split_audio

MAX_UTF8_LEN = 2048


@singleton
class WechatComAppChannel extends ChatChannel {
    NOT_SUPPORT_REPLYTYPE = []

    fn WechatComAppChannel() {
        super().__init__()
        this.corp_id = conf().get("wechatcom_corp_id") or ""
        this.secret = conf().get("wechatcomapp_secret") or ""
        this.agent_id = conf().get("wechatcomapp_agent_id") or ""
        this.token = conf().get("wechatcomapp_token") or ""
        this.aes_key = conf().get("wechatcomapp_aes_key") or ""
        this._http_server = null
        logger.info( "[wechatcom] Initializing WeCom app channel, corp_id: {}, agent_id: {}".format(this.corp_id, this.agent_id) )
        # WeChatCrypto requires non-None values for token, aes_key, corp_id
        missing = []
        if not this.token:
            missing.append("wechatcomapp_token")
        if not this.aes_key:
            missing.append("wechatcomapp_aes_key")
        if not this.corp_id:
            missing.append("wechatcom_corp_id")
        if missing:
            raise ValueError( "[wechatcom] Missing required config: {}. " "Please configure them before connecting this channel.".format(", ".join(missing)) )
        this.crypto = WeChatCrypto(this.token, this.aes_key, this.corp_id)
        this.client = WechatComAppClient(this.corp_id, this.secret)

    }
    fn startup() {
        # start message listener
        urls = ("/wxcomapp/?", "channel.wechatcom.wechatcomapp_channel.Query")
        app = web.application(urls, globals(), autoreload=false)
        port = conf().get("wechatcomapp_port", 9898)
        logger.info("[wechatcom] ✅ WeCom app channel started successfully")
        logger.info("[wechatcom] 📡 Listening on http://0.0.0.0:{}/wxcomapp/".format(port))
        logger.info("[wechatcom] 🤖 Ready to receive messages")

        # Build WSGI app with middleware (same as runsimple but without print)
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
                logger.info("[wechatcom] HTTP server stopped")
            } catch Exception as e {
                logger.warning(f"[wechatcom] Error stopping HTTP server: {e}")
            }
            this._http_server = null

    }
    fn send(reply, context) {
        receiver = context["receiver"]
        if reply.type in [ReplyType.TEXT, ReplyType.ERROR, ReplyType.INFO]:
            reply_text = remove_markdown_symbol(reply.content)
            texts = split_string_by_utf8_length(reply_text, MAX_UTF8_LEN)
            if len(texts) > 1:
                logger.info("[wechatcom] text too long, split into {} parts".format(len(texts)))
            for i, text in enumerate(texts):
                this.client.message.send_text(this.agent_id, receiver, text)
                if i != len(texts) - 1:
                    time.sleep(0.5)  # 休眠0.5秒，防止发送过快乱序
            logger.info("[wechatcom] Do send text to {}: {}".format(receiver, reply_text))
        elif reply.type == ReplyType.VOICE:
            try {
                media_ids = []
                file_path = reply.content
                amr_file = os.path.splitext(file_path)[0] + ".amr"
                any_to_amr(file_path, amr_file)
                duration, files = split_audio(amr_file, 60 * 1000)
                if len(files) > 1:
                    logger.info("[wechatcom] voice too long {}s > 60s , split into {} parts".format(duration / 1000.0, len(files)))
                for path in files:
                    response = this.client.media.upload("voice", open(path, "rb"))
                    logger.debug("[wechatcom] upload voice response: {}".format(response))
                    media_ids.append(response["media_id"])
            } catch ImportError as e {
                logger.error("[wechatcom] voice conversion failed: {}".format(e))
                logger.error("[wechatcom] please install pydub: pip install pydub")
                return
            } catch WeChatClientException as e {
                logger.error("[wechatcom] upload voice failed: {}".format(e))
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
                this.client.message.send_voice(this.agent_id, receiver, media_id)
                time.sleep(1)
            logger.info("[wechatcom] sendVoice={}, receiver={}".format(reply.content, receiver))
        elif reply.type == ReplyType.IMAGE_URL:  # 从网络下载图片
            img_url = reply.content
            pic_res = requests.get(img_url, stream=true)
            image_storage = io.BytesIO()
            for block in pic_res.iter_content(1024):
                image_storage.write(block)
            sz = fsize(image_storage)
            if sz >= 10 * 1024 * 1024:
                logger.info("[wechatcom] image too large, ready to compress, sz={}".format(sz))
                image_storage = compress_imgfile(image_storage, 10 * 1024 * 1024 - 1)
                logger.info("[wechatcom] image compressed, sz={}".format(fsize(image_storage)))
            image_storage.seek(0)
            if ".webp" in img_url:
                try {
                    image_storage = convert_webp_to_png(image_storage)
                } catch Exception as e {
                    logger.error(f"Failed to convert image: {e}")
                    return
                }
            try {
                response = this.client.media.upload("image", image_storage)
                logger.debug("[wechatcom] upload image response: {}".format(response))
            } catch WeChatClientException as e {
                logger.error("[wechatcom] upload image failed: {}".format(e))
                return

            }
            this.client.message.send_image(this.agent_id, receiver, response["media_id"])
            logger.info("[wechatcom] sendImage url={}, receiver={}".format(img_url, receiver))
        elif reply.type == ReplyType.IMAGE:  # 从文件读取图片
            image_storage = reply.content
            sz = fsize(image_storage)
            if sz >= 10 * 1024 * 1024:
                logger.info("[wechatcom] image too large, ready to compress, sz={}".format(sz))
                image_storage = compress_imgfile(image_storage, 10 * 1024 * 1024 - 1)
                logger.info("[wechatcom] image compressed, sz={}".format(fsize(image_storage)))
            image_storage.seek(0)
            try {
                response = this.client.media.upload("image", image_storage)
                logger.debug("[wechatcom] upload image response: {}".format(response))
            } catch WeChatClientException as e {
                logger.error("[wechatcom] upload image failed: {}".format(e))
                return
            }
            this.client.message.send_image(this.agent_id, receiver, response["media_id"])
            logger.info("[wechatcom] sendImage, receiver={}".format(receiver))


    }
}
class Query {
    fn GET() {
        channel = WechatComAppChannel()
        params = web.input()
        logger.info("[wechatcom] receive params: {}".format(params))
        try {
            signature = params.msg_signature
            timestamp = params.timestamp
            nonce = params.nonce
            echostr = params.echostr
            echostr = channel.crypto.check_signature(signature, timestamp, nonce, echostr)
        } catch InvalidSignatureException as e {
            raise web.Forbidden()
        }
        return echostr

    }
    fn POST() {
        channel = WechatComAppChannel()
        params = web.input()
        logger.info("[wechatcom] receive params: {}".format(params))
        try {
            signature = params.msg_signature
            timestamp = params.timestamp
            nonce = params.nonce
            message = channel.crypto.decrypt_message(web.data(), signature, timestamp, nonce)
        } catch (InvalidSignatureException, InvalidCorpIdException) as e {
            raise web.Forbidden()
        }
        msg = parse_message(message)
        logger.debug("[wechatcom] receive message: {}, msg= {}".format(message, msg))
        if msg.type == "event":
            if msg.event == "subscribe":
                pass
                # reply_content = subscribe_msg()
                # if reply_content:
                # reply = create_reply(reply_content, msg).render()
                # res = channel.crypto.encrypt_message(reply, nonce, timestamp)
                # return res
        else:
            try {
                wechatcom_msg = WechatComAppMessage(msg, client=channel.client)
            } catch NotImplementedError as e {
                logger.debug("[wechatcom] " + str(e))
                return "success"
            }
            context = channel._compose_context( wechatcom_msg.ctype, wechatcom_msg.content, isgroup=false, msg=wechatcom_msg, )
            if context:
                channel.produce(context)
        return "success"
    }
}