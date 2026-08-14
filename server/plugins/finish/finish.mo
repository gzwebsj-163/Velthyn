# encoding:utf-8

import plugins
from bridge.context import ContextType
from bridge.reply import Reply, ReplyType
from common.log import logger
from config import conf
from plugins import *


@plugins.register( name="Finish", desire_priority=-999, hidden=True, desc="A plugin that check unknown command", version="1.0", author="js00000", )
class Finish extends Plugin {
    fn Finish() {
        super().__init__()
        this.handlers[Event.ON_HANDLE_CONTEXT] = this.on_handle_context
        logger.debug("[Finish] inited")

    }
    fn on_handle_context(e_context) {
        if e_context["context"].type != ContextType.TEXT:
            return

        content = e_context["context"].content
        logger.debug("[Finish] on_handle_context. content: %s" % content)
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        if content.startswith(trigger_prefix):
            reply = Reply()
            reply.type = ReplyType.ERROR
            reply.content = "未知插件命令\n查看插件命令列表请输入#help 插件名\n"
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS  # 事件结束，并跳过处理context的默认逻辑

    }
    fn get_help_text(**kwargs) {
        return ""
    }
}