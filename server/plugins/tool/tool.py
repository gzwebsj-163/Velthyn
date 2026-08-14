from chatgpt_tool_hub.apps import AppFactory
from chatgpt_tool_hub.apps.app import App
from chatgpt_tool_hub.tools.tool_register import main_tool_register

import plugins
from bridge.bridge import Bridge
from bridge.context import ContextType
from bridge.reply import Reply, ReplyType
from common import const
from config import conf, get_appdata_dir
from plugins import *


@plugins.register( name="tool", desc="Arming your ChatGPT bot with various tools", version="0.5", author="goldfishh", desire_priority=0, )
class Tool(Plugin):
    def __init__(self):
        super().__init__()
        self.handlers[Event.ON_HANDLE_CONTEXT] = self.on_handle_context
        self.app = self._reset_app()
        if not self.tool_config.get("tools"):
            logger.warn("[tool] init failed, ignore ")
            raise Exception("config.json not found")
        logger.info("[tool] inited")


    def get_help_text(self, verbose=False, **kwargs):
        help_text = "这是一个能让chatgpt联网，搜索，数字运算的插件，将赋予强大且丰富的扩展能力。"
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        if not verbose:
            return help_text
        help_text += "\n使用说明：\n"
        help_text += f"{trigger_prefix}tool " + "命令: 根据给出的{命令}模型来选择使用哪些工具尽力为你得到结果。\n"
        help_text += f"{trigger_prefix}tool 工具名 " + "命令: 根据给出的{命令}使用指定工具尽力为你得到结果。\n"
        help_text += f"{trigger_prefix}tool reset: 重置工具。\n\n"

        help_text += f"已加载工具列表: \n"
        for idx, tool in enumerate(main_tool_register.get_registered_tool_names()):
            if idx != 0:
                help_text += ", "
            help_text += f"{tool}"
        return help_text

    def on_handle_context(self, e_context):
        if e_context["context"].type != ContextType.TEXT:
            return

        # 暂时不支持未来扩展的bot
        if Bridge().get_bot_type("chat") not in ( const.OPENAI, const.CHATGPT, const.OPEN_AI, const.CHATGPTONAZURE, const.LINKAI, ):
            return

        content = e_context["context"].content
        content_list = e_context["context"].content.split(maxsplit=1)

        if not content or len(content_list) < 1:
            e_context.action = EventAction.CONTINUE
            return

        logger.debug("[tool] on_handle_context. content: %s" % content)
        reply = Reply()
        reply.type = ReplyType.TEXT
        trigger_prefix = conf().get("plugin_trigger_prefix", "$")
        # todo: 有些工具必须要api-key，需要修改config文件，所以这里没有实现query增删tool的功能
        if content.startswith(f"{trigger_prefix}tool"):
            if len(content_list) == 1:
                logger.debug("[tool]: get help")
                reply.content = self.get_help_text()
                e_context["reply"] = reply
                e_context.action = EventAction.BREAK_PASS
                return
            elif len(content_list) > 1:
                if content_list[1].strip() == "reset":
                    logger.debug("[tool]: reset config")
                    self.app = self._reset_app()
                    reply.content = "重置工具成功"
                    e_context["reply"] = reply
                    e_context.action = EventAction.BREAK_PASS
                    return
                elif content_list[1].startswith("reset"):
                    logger.debug("[tool]: remind")
                    e_context["context"].content = "请你随机用一种聊天风格，提醒用户：如果想重置tool插件，reset之后不要加任何字符"

                    e_context.action = EventAction.BREAK
                    return
                query = content_list[1].strip()

                use_one_tool = False
                for tool_name in main_tool_register.get_registered_tool_names():
                    if query.startswith(tool_name):
                        use_one_tool = True
                        query = query[len(tool_name):]
                        break

                # Don't modify bot name
                all_sessions = Bridge().get_bot("chat").sessions
                user_session = all_sessions.session_query(query, e_context["context"]["session_id"]).messages

                logger.debug("[tool]: just-go")
                try:
                    if use_one_tool:
                        _func, _ = main_tool_register.get_registered_tool()[tool_name]
                        tool = _func(**self.app_kwargs)
                        _reply = tool.run(query)
                    else:
                        # chatgpt-tool-hub will reply you with many tools
                        _reply = self.app.ask(query, user_session)
                    e_context.action = EventAction.BREAK_PASS
                    all_sessions.session_reply(_reply, e_context["context"]["session_id"])
                except Exception as e:
                    logger.exception(e)
                    logger.error(str(e))

                    e_context["context"].content = "请你随机用一种聊天风格，提醒用户：这个问题tool插件暂时无法处理"
                    reply.type = ReplyType.ERROR
                    e_context.action = EventAction.BREAK
                    return

                reply.content = _reply
                e_context["reply"] = reply
        return

    def _read_json(self):
        default_config = {"tools": [], "kwargs": {}}
        return super().load_config() or default_config

    def _build_tool_kwargs(self, kwargs):
        tool_model_name = kwargs.get("model_name")
        request_timeout = kwargs.get("request_timeout")

        return {  "log": False,   "debug": kwargs.get("debug", False),   "no_default": kwargs.get("no_default", False),   "think_depth": kwargs.get("think_depth", 2),   "proxy": conf().get("proxy", ""),   "request_timeout": request_timeout if request_timeout else conf().get("request_timeout", 120), "temperature": kwargs.get("temperature", 0),    "llm_api_key": conf().get("open_ai_api_key", ""),   "llm_api_base_url": conf().get("open_ai_api_base", "https://api.openai.com/v1"),   "deployment_id": conf().get("azure_deployment_id", ""),    "model_name": tool_model_name if tool_model_name else conf().get("model", const.GPT35),   "arxiv_simple": kwargs.get("arxiv_simple", True),   "arxiv_top_k_results": kwargs.get("arxiv_top_k_results", 2),   "arxiv_sort_by": kwargs.get("arxiv_sort_by", "relevance"),   "arxiv_sort_order": kwargs.get("arxiv_sort_order", "descending"),   "arxiv_output_type": kwargs.get("arxiv_output_type", "text"),    "bing_subscription_key": kwargs.get("bing_subscription_key", ""), "bing_search_url": kwargs.get("bing_search_url", "https://api.bing.microsoft.com/v7.0/search"),   "bing_search_top_k_results": kwargs.get("bing_search_top_k_results", 2),   "bing_search_simple": kwargs.get("bing_search_simple", True),   "bing_search_output_type": kwargs.get("bing_search_output_type", "text"),    "email_nickname_mapping": kwargs.get("email_nickname_mapping", "{}"),   "email_smtp_host": kwargs.get("email_smtp_host", ""),   "email_smtp_port": kwargs.get("email_smtp_port", ""),   "email_sender": kwargs.get("email_sender", ""),   "email_authorization_code": kwargs.get("email_authorization_code", ""),    "google_api_key": kwargs.get("google_api_key", ""), "google_cse_id": kwargs.get("google_cse_id", ""), "google_simple": kwargs.get("google_simple", True),    "google_output_type": kwargs.get("google_output_type", "text"),    "finance_news_filter": kwargs.get("finance_news_filter", False),   "finance_news_filter_list": kwargs.get("finance_news_filter_list", []),   "finance_news_simple": kwargs.get("finance_news_simple", True),    "finance_news_repeat_news": kwargs.get("finance_news_repeat_news", False),    "morning_news_api_key": kwargs.get("morning_news_api_key", ""),    "morning_news_simple": kwargs.get("morning_news_simple", True),    "morning_news_output_type": kwargs.get("morning_news_output_type", "text"),    "news_api_key": kwargs.get("news_api_key", ""),  "searxng_search_host": kwargs.get("searxng_search_host", ""), "searxng_search_top_k_results": kwargs.get("searxng_search_top_k_results", 2),   "searxng_search_output_type": kwargs.get("searxng_search_output_type", "text"),    "sms_nickname_mapping": kwargs.get("sms_nickname_mapping", "{}"),   "sms_username": kwargs.get("sms_username", ""),   "sms_apikey": kwargs.get("sms_apikey", ""),    "stt_api_key": kwargs.get("stt_api_key", ""),   "stt_api_region": kwargs.get("stt_api_region", ""),   "stt_recognition_language": kwargs.get("stt_recognition_language", "zh-CN"),    "tts_api_key": kwargs.get("tts_api_key", ""),   "tts_api_region": kwargs.get("tts_api_region", ""),   "tts_auto_detect": kwargs.get("tts_auto_detect", True),   "tts_speech_id": kwargs.get("tts_speech_id", "zh-CN-XiaozhenNeural"),    "summary_max_segment_length": kwargs.get("summary_max_segment_length", 2500),    "terminal_nsfc_filter": kwargs.get("terminal_nsfc_filter", True),   "terminal_return_err_output": kwargs.get("terminal_return_err_output", True),   "terminal_timeout": kwargs.get("terminal_timeout", 20),    "caption_api_key": kwargs.get("caption_api_key", ""),    "browser_use_summary": kwargs.get("browser_use_summary", True),    "url_get_use_summary": kwargs.get("url_get_use_summary", True),    "wikipedia_top_k_results": kwargs.get("wikipedia_top_k_results", 2),    "wolfram_alpha_appid": kwargs.get("wolfram_alpha_appid", ""), }

    def _filter_tool_list(self, tool_list):
        valid_list = []
        for tool in tool_list:
            if tool in main_tool_register.get_registered_tool_names():
                valid_list.append(tool)
            else:
                logger.warning("[tool] filter invalid tool: " + repr(tool))
        return valid_list

    def _reset_app(self):
        self.tool_config = self._read_json()
        self.app_kwargs = self._build_tool_kwargs(self.tool_config.get("kwargs", {}))

        app = AppFactory()
        app.init_env(**self.app_kwargs)
        # filter not support tool
        tool_list = self._filter_tool_list(self.tool_config.get("tools", []))

        return app.create_app(tools_list=tool_list, **self.app_kwargs)