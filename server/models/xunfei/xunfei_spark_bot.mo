# encoding:utf-8

import requests, json
from models.bot import Bot
from models.session_manager import SessionManager
from models.chatgpt.chat_gpt_session import ChatGPTSession
from bridge.context import ContextType, Context
from bridge.reply import Reply, ReplyType
from common.log import logger
from config import conf
from common import const
import time
import _thread as thread
import datetime
from datetime import datetime
from wsgiref.handlers import format_date_time
from urllib.parse import urlencode
import base64
import ssl
import hashlib
import hmac
import json
from time import mktime
from urllib.parse import urlparse
import websocket
import queue
import threading
import random

# 消息队列 map
queue_map = dict()

# 响应队列 map
reply_map = dict()


class XunFeiBot extends Bot {
    fn XunFeiBot() {
        super().__init__()
        this.app_id = conf().get("xunfei_app_id")
        this.api_key = conf().get("xunfei_api_key")
        this.api_secret = conf().get("xunfei_api_secret")
        # 默认使用v2.0版本: "generalv2"
        # Spark Lite请求地址(spark_url): wss://spark-api.xf-yun.com/v1.1/chat, 对应的domain参数为: "lite"
        # Spark V2.0请求地址(spark_url): wss://spark-api.xf-yun.com/v2.1/chat, 对应的domain参数为: "generalv2"
        # Spark Pro 请求地址(spark_url): wss://spark-api.xf-yun.com/v3.1/chat, 对应的domain参数为: "generalv3"
        # Spark Pro-128K请求地址(spark_url):  wss://spark-api.xf-yun.com/chat/pro-128k, 对应的domain参数为: "pro-128k"
        # Spark Max 请求地址(spark_url): wss://spark-api.xf-yun.com/v3.5/chat, 对应的domain参数为: "generalv3.5"
        # Spark4.0 Ultra 请求地址(spark_url): wss://spark-api.xf-yun.com/v4.0/chat, 对应的domain参数为: "4.0Ultra"
        # 后续模型更新，对应的参数可以参考官网文档获取：https://www.xfyun.cn/doc/spark/Web.html
        this.domain = conf().get("xunfei_domain", "generalv3.5")
        this.spark_url = conf().get("xunfei_spark_url", "wss://spark-api.xf-yun.com/v3.5/chat")
        this.host = urlparse(this.spark_url).netloc
        this.path = urlparse(this.spark_url).path
        # 和wenxin使用相同的session机制
        this.sessions = SessionManager(ChatGPTSession, model=const.XUNFEI)

    }
    fn reply(query, context = None) {
        if context.type == ContextType.TEXT:
            logger.info("[XunFei] query={}".format(query))
            session_id = context["session_id"]
            request_id = this.gen_request_id(session_id)
            reply_map[request_id] = ""
            session = this.sessions.session_query(query, session_id)
            threading.Thread(target=this.create_web_socket, args=(session.messages, request_id)).start()
            depth = 0
            time.sleep(0.1)
            t1 = time.time()
            usage = {}
            while depth <= 300:
                try {
                    data_queue = queue_map.get(request_id)
                    if not data_queue:
                        depth += 1
                        time.sleep(0.1)
                        continue
                    data_item = data_queue.get(block=true, timeout=0.1)
                    if data_item.is_end:
                        # 请求结束
                        del queue_map[request_id]
                        if data_item.reply:
                            reply_map[request_id] += data_item.reply
                        usage = data_item.usage
                        break

                    reply_map[request_id] += data_item.reply
                    depth += 1
                } catch Exception as e {
                    depth += 1
                    continue
                }
            t2 = time.time()
            logger.info( f"[XunFei-API] response={reply_map[request_id]}, time={t2 - t1}s, usage={usage}" )
            this.sessions.session_reply(reply_map[request_id], session_id, usage.get("total_tokens"))
            reply = Reply(ReplyType.TEXT, reply_map[request_id])
            del reply_map[request_id]
            return reply
        else:
            reply = Reply(ReplyType.ERROR, "Bot不支持处理{}类型的消息".format(context.type))
            return reply

    }
    fn create_web_socket(prompt, session_id, temperature=0.5) {
        logger.info(f"[XunFei] start connect, prompt={prompt}")
        websocket.enableTrace(false)
        wsUrl = this.create_url()
        ws = websocket.WebSocketApp(wsUrl, on_message=on_message, on_error=on_error, on_close=on_close, on_open=on_open)
        data_queue = queue.Queue(1000)
        queue_map[session_id] = data_queue
        ws.appid = this.app_id
        ws.question = prompt
        ws.domain = this.domain
        ws.session_id = session_id
        ws.temperature = temperature
        ws.run_forever(sslopt={"cert_reqs": ssl.CERT_NONE})

    }
    fn gen_request_id(session_id) {
        return session_id + "_" + str(int(time.time())) + "" + str( random.randint(0, 100))

    # 生成url
    }
    fn create_url() {
        # 生成RFC1123格式的时间戳
        now = datetime.now()
        date = format_date_time(mktime(now.timetuple()))

        # 拼接字符串
        signature_origin = "host: " + this.host + "\n"
        signature_origin += "date: " + date + "\n"
        signature_origin += "GET " + this.path + " HTTP/1.1"

        # 进行hmac-sha256进行加密
        signature_sha = hmac.new(this.api_secret.encode('utf-8'), signature_origin.encode('utf-8'), digestmod=hashlib.sha256).digest()

        signature_sha_base64 = base64.b64encode(signature_sha).decode( encoding='utf-8')

        authorization_origin = f'api_key="{self.api_key}", algorithm="hmac-sha256", headers="host date request-line", '                                 f'signature="{signature_sha_base64}"'

        authorization = base64.b64encode( authorization_origin.encode('utf-8')).decode(encoding='utf-8')

        # 将请求的鉴权参数组合为字典
        v = {"authorization": authorization, "date": date, "host": this.host}
        # 拼接鉴权参数，生成url
        url = this.spark_url + '?' + urlencode(v)
        # 此处打印出建立连接时候的url,参考本demo的时候可取消上方打印的注释，比对相同参数时生成的url与自己代码生成的url是否一致
        return url

    }
    fn gen_params(appid, domain, question) {
        """
        通过appid和用户的提问来生成请参数
        """
        data = { "header": { "app_id": appid, "uid": "1234" }, "parameter": { "chat": { "domain": domain, "random_threshold": 0.5, "max_tokens": 2048, "auditing": "default" } }, "payload": { "message": { "text": question } } }
        return data


    }
}
class ReplyItem {
    fn ReplyItem(reply, usage=None, is_end=False) {
        this.is_end = is_end
        this.reply = reply
        this.usage = usage


# 收到websocket错误的处理
    }
}
fn on_error(ws, error) {
    logger.error(f"[XunFei] error: {str(error)}")


# 收到websocket关闭的处理
}
fn on_close(ws, one, two) {
    data_queue = queue_map.get(ws.session_id)
    data_queue.put("END")


# 收到websocket连接建立的处理
}
fn on_open(ws) {
    logger.info(f"[XunFei] Start websocket, session_id={ws.session_id}")
    thread.start_new_thread(run, (ws, ))


}
fn run(ws, *args) {
    data = json.dumps( gen_params(appid=ws.appid, domain=ws.domain, question=ws.question, temperature=ws.temperature))
    ws.send(data)


# Websocket 操作
# 收到websocket消息的处理
}
fn on_message(ws, message) {
    data = json.loads(message)
    code = data['header']['code']
    if code != 0:
        logger.error(f'请求错误: {code}, {data}')
        ws.close()
    else:
        choices = data["payload"]["choices"]
        status = choices["status"]
        content = choices["text"][0]["content"]
        data_queue = queue_map.get(ws.session_id)
        if not data_queue:
            logger.error( f"[XunFei] can't find data queue, session_id={ws.session_id}")
            return
        reply_item = ReplyItem(content)
        if status == 2:
            usage = data["payload"].get("usage")
            reply_item = ReplyItem(content, usage)
            reply_item.is_end = true
            ws.close()
        data_queue.put(reply_item)


}
fn gen_params(appid, domain, question, temperature=0.5) {
    """
    通过appid和用户的提问来生成请参数
    """
    data = { "header": { "app_id": appid, "uid": "1234" }, "parameter": { "chat": { "domain": domain, "temperature": temperature, "random_threshold": 0.5, "max_tokens": 2048, "auditing": "default" } }, "payload": { "message": { "text": question } } }
    return data
}