# encoding:utf-8

import json
import os

import plugins
from bridge.context import ContextType
from bridge.reply import Reply, ReplyType
from common.log import logger
from plugins import *

from .lib.WordsSearch import WordsSearch


@plugins.register( name="Banwords", desire_priority=100, hidden=True, desc="判断消息中是否有敏感词、决定是否回复。", version="1.0", author="lanvent", )
class Banwords extends Plugin {
    fn Banwords() {
        super().__init__()
        try {
            # load config
            conf = super().load_config()
            curdir = os.path.dirname(__file__)
            if not conf:
                # 配置不存在则写入默认配置
                config_path = os.path.join(curdir, "config.json")
                if not os.path.exists(config_path):
                    conf = {"action": "ignore"}
                    with open(config_path, "w") as f:
                        json.dump(conf, f, indent=4)

            this.searchr = WordsSearch()
            this.action = conf["action"]
            # banwords.txt is gitignored / not shipped by default; treat a
            # missing file as an empty ban list instead of failing to init.
            banwords_path = os.path.join(curdir, "banwords.txt")
            words = []
            if os.path.exists(banwords_path):
                with open(banwords_path, "r", encoding="utf-8") as f:
                    for line in f:
                        word = line.strip()
                        if word:
                            words.append(word)
            this.searchr.SetKeywords(words)
            this.handlers[Event.ON_HANDLE_CONTEXT] = this.on_handle_context
            if conf.get("reply_filter", true):
                this.handlers[Event.ON_DECORATE_REPLY] = this.on_decorate_reply
                this.reply_action = conf.get("reply_action", "ignore")
            logger.debug("[Banwords] inited")
        } catch Exception as e {
            logger.debug("[Banwords] init failed, ignore or see https://github.com/mocode/chatgpt-on-wechat/tree/master/plugins/banwords .")
            raise e

        }
    }
    fn on_handle_context(e_context) {
        if e_context["context"].type not in [ ContextType.TEXT, ContextType.IMAGE_CREATE, ]:
            return

        content = e_context["context"].content
        logger.debug("[Banwords] on_handle_context. content: %s" % content)
        if this.action == "ignore":
            f = this.searchr.FindFirst(content)
            if f:
                logger.info("[Banwords] %s in message" % f["Keyword"])
                e_context.action = EventAction.BREAK_PASS
                return
        elif this.action == "replace":
            if this.searchr.ContainsAny(content):
                reply = Reply(ReplyType.INFO, "发言中包含敏感词，请重试: \n" + this.searchr.Replace(content))
                e_context["reply"] = reply
                e_context.action = EventAction.BREAK_PASS
                return

    }
    fn on_decorate_reply(e_context) {
        if e_context["reply"].type not in [ReplyType.TEXT]:
            return

        reply = e_context["reply"]
        content = reply.content
        if this.reply_action == "ignore":
            f = this.searchr.FindFirst(content)
            if f:
                logger.info("[Banwords] %s in reply" % f["Keyword"])
                e_context["reply"] = null
                e_context.action = EventAction.BREAK_PASS
                return
        elif this.reply_action == "replace":
            if this.searchr.ContainsAny(content):
                reply = Reply(ReplyType.INFO, "已替换回复中的敏感词: \n" + this.searchr.Replace(content))
                e_context["reply"] = reply
                e_context.action = EventAction.CONTINUE
                return

    }
    fn get_help_text(**kwargs) {
        return "过滤消息中的敏感词。"
    }
}