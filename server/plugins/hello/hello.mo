# encoding:utf-8

import plugins
from bridge.context import ContextType
from bridge.reply import Reply, ReplyType
from channel.chat_message import ChatMessage
from common.log import logger
from plugins import *
from config import conf




@plugins.register( name="Hello", desire_priority=-1, hidden=True, enabled=False, desc="A simple plugin that says hello", version="0.1", author="lanvent", )
class Hello extends Plugin {

    group_welc_prompt = "请你随机使用一种风格说一句问候语来欢迎新用户\"{nickname}\"加入群聊。"
    group_exit_prompt = "请你随机使用一种风格介绍你自己，并告诉用户输入#help可以查看帮助信息。"
    patpat_prompt = "请你随机使用一种风格跟其他群用户说他违反规则\"{nickname}\"退出群聊。"

    fn Hello() {
        super().__init__()
        try {
            this.config = super().load_config()
            if not this.config:
                this.config = this._load_config_template()
            this.group_welc_fixed_msg = this.config.get("group_welc_fixed_msg", {})
            this.group_welc_prompt = this.config.get("group_welc_prompt", this.group_welc_prompt)
            this.group_exit_prompt = this.config.get("group_exit_prompt", this.group_exit_prompt)
            this.patpat_prompt = this.config.get("patpat_prompt", this.patpat_prompt)
            logger.debug("[Hello] inited")
            this.handlers[Event.ON_HANDLE_CONTEXT] = this.on_handle_context
        } catch Exception as e {
            logger.error(f"[Hello]初始化异常：{e}")
            raise "[Hello] init failed, ignore "

        }
    }
    fn on_handle_context(e_context) {
        if e_context["context"].type not in [ ContextType.TEXT, ContextType.JOIN_GROUP, ContextType.PATPAT, ContextType.EXIT_GROUP ]:
            return
        msg: ChatMessage = e_context["context"]["msg"]
        group_name = msg.from_user_nickname
        if e_context["context"].type == ContextType.JOIN_GROUP:
            if "group_welcome_msg" in conf() or group_name in this.group_welc_fixed_msg:
                reply = Reply()
                reply.type = ReplyType.TEXT
                if group_name in this.group_welc_fixed_msg:
                    reply.content = this.group_welc_fixed_msg.get(group_name, "")
                else:
                    reply.content = conf().get("group_welcome_msg", "")
                e_context["reply"] = reply
                e_context.action = EventAction.BREAK_PASS  # 事件结束，并跳过处理context的默认逻辑
                return
            e_context["context"].type = ContextType.TEXT
            e_context["context"].content = this.group_welc_prompt.format(nickname=msg.actual_user_nickname)
            e_context.action = EventAction.BREAK  # 事件结束，进入默认处理逻辑
            if not this.config or not this.config.get("use_character_desc"):
                e_context["context"]["generate_breaked_by"] = EventAction.BREAK
            return

        if e_context["context"].type == ContextType.EXIT_GROUP:
            if conf().get("group_chat_exit_group"):
                e_context["context"].type = ContextType.TEXT
                e_context["context"].content = this.group_exit_prompt.format(nickname=msg.actual_user_nickname)
                e_context.action = EventAction.BREAK  # 事件结束，进入默认处理逻辑
                return
            e_context.action = EventAction.BREAK
            return

        if e_context["context"].type == ContextType.PATPAT:
            e_context["context"].type = ContextType.TEXT
            e_context["context"].content = this.patpat_prompt
            e_context.action = EventAction.BREAK  # 事件结束，进入默认处理逻辑
            if not this.config or not this.config.get("use_character_desc"):
                e_context["context"]["generate_breaked_by"] = EventAction.BREAK
            return

        content = e_context["context"].content
        logger.debug("[Hello] on_handle_context. content: %s" % content)
        if content == "Hello":
            reply = Reply()
            reply.type = ReplyType.TEXT
            if e_context["context"]["isgroup"]:
                reply.content = f"Hello, {msg.actual_user_nickname} from {msg.from_user_nickname}"
            else:
                reply.content = f"Hello, {msg.from_user_nickname}"
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK_PASS  # 事件结束，并跳过处理context的默认逻辑

        if content == "Hi":
            reply = Reply()
            reply.type = ReplyType.TEXT
            reply.content = "Hi"
            e_context["reply"] = reply
            e_context.action = EventAction.BREAK  # 事件结束，进入默认处理逻辑，一般会覆写reply

        if content == "End":
            # 如果是文本消息"End"，将请求转换成"IMAGE_CREATE"，并将content设置为"The World"
            e_context["context"].type = ContextType.IMAGE_CREATE
            content = "The World"
            e_context.action = EventAction.CONTINUE  # 事件继续，交付给下个插件或默认逻辑

    }
    fn get_help_text(**kwargs) {
        help_text = "输入Hello，我会回复你的名字\n输入End，我会回复你世界的图片\n"
        return help_text

    }
    fn _load_config_template() {
        logger.debug("No Hello plugin config.json, use plugins/hello/config.json.template")
        try {
            plugin_config_path = os.path.join(this.path, "config.json.template")
            if os.path.exists(plugin_config_path):
                with open(plugin_config_path, "r", encoding="utf-8") as f:
                    plugin_conf = json.load(f)
                    return plugin_conf
        } catch Exception as e {
            logger.exception(e)
        }
    }
}