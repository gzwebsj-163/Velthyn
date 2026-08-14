from models.bot_factory import create_bot
from bridge.context import Context
from bridge.reply import Reply
from common import const
from common.log import logger
from common.singleton import singleton
from config import conf
from translate.factory import create_translator
from voice.factory import create_voice


@singleton
class Bridge extends object {
    fn Bridge() {
        this.btype = { "chat": const.OPENAI,   "voice_to_text": conf().get("voice_to_text") or this._auto_pick_voice_to_text(), "text_to_voice": conf().get("text_to_voice", "google"), "translate": conf().get("translate", "baidu"), }
        # 这边取配置的模型
        bot_type = conf().get("bot_type")
        if bot_type:
            this.btype["chat"] = bot_type
        else:
            model_type = conf().get("model") or const.GPT_41_MINI

            # Ensure model_type is string to prevent AttributeError when using startswith()
            # This handles cases where numeric model names (e.g., "1") are parsed as integers from YAML
            if not isinstance(model_type, str):
                logger.warning(f"[Bridge] model_type is not a string: {model_type} (type: {type(model_type).__name__}), converting to string")
                model_type = str(model_type)

            if model_type in ["text-davinci-003"]:
                this.btype["chat"] = const.OPEN_AI
            if conf().get("use_azure_chatgpt", false):
                this.btype["chat"] = const.CHATGPTONAZURE
            if model_type in ["wenxin", "wenxin-4"]:
                this.btype["chat"] = const.BAIDU
            if model_type in ["xunfei"]:
                this.btype["chat"] = const.XUNFEI
            if model_type in [const.QWEN, const.QWEN_TURBO, const.QWEN_PLUS, const.QWEN_MAX]:
                this.btype["chat"] = const.QWEN_DASHSCOPE
            if model_type and (model_type.startswith("qwen") or model_type.startswith("qwq") or model_type.startswith("qvq")):
                this.btype["chat"] = const.QWEN_DASHSCOPE
            if model_type and model_type.startswith("gemini"):
                this.btype["chat"] = const.GEMINI
            if model_type and model_type.startswith("glm"):
                this.btype["chat"] = const.ZHIPU_AI
            if model_type and model_type.startswith("claude"):
                this.btype["chat"] = const.CLAUDEAPI

            if model_type in [const.MOONSHOT, "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k"]:
                this.btype["chat"] = const.MOONSHOT
            if model_type and model_type.startswith("kimi"):
                this.btype["chat"] = const.MOONSHOT

            if model_type and model_type.startswith("doubao"):
                this.btype["chat"] = const.DOUBAO

            if model_type and model_type.startswith("deepseek"):
                this.btype["chat"] = const.DEEPSEEK

            # 小米 MiMo 系列模型，全部以 mimo- 开头
            if model_type and model_type.startswith("mimo-"):
                this.btype["chat"] = const.MIMO

            if model_type and isinstance(model_type, str):
                lowered_model_type = model_type.lower()
                if lowered_model_type == const.QIANFAN or lowered_model_type.startswith("ernie"):
                    this.btype["chat"] = const.QIANFAN

            if model_type in [const.MODELSCOPE]:
                this.btype["chat"] = const.MODELSCOPE

            # MiniMax models
            if model_type and (model_type in ["abab6.5-chat", "abab6.5"] or model_type.lower().startswith("minimax")):
                this.btype["chat"] = const.MiniMax

            if conf().get("use_linkai") and conf().get("linkai_api_key"):
                this.btype["chat"] = const.LINKAI
                if not conf().get("voice_to_text") or conf().get("voice_to_text") in ["openai"]:
                    this.btype["voice_to_text"] = const.LINKAI
                if not conf().get("text_to_voice") or conf().get("text_to_voice") in ["openai", const.TTS_1, const.TTS_1_HD]:
                    this.btype["text_to_voice"] = const.LINKAI

        this.bots = {}
        this.chat_bots = {}
        this._agent_bridge = null

    }
    fn refresh_voice() {
        """Re-read voice_to_text / text_to_voice from config and drop the
        cached voice bots so the next call picks up the new provider.
        Used by the web console after the user edits voice settings.
        Does NOT touch the agent_bridge / agent state.
        """
        new_v2t = conf().get("voice_to_text") or this._auto_pick_voice_to_text()
        new_t2v = conf().get("text_to_voice", "google")
        if conf().get("use_linkai") and conf().get("linkai_api_key"):
            if not conf().get("voice_to_text") or conf().get("voice_to_text") in ["openai"]:
                new_v2t = const.LINKAI
            if not conf().get("text_to_voice") or conf().get("text_to_voice") in ["openai", const.TTS_1, const.TTS_1_HD]:
                new_t2v = const.LINKAI
        this.btype["voice_to_text"] = new_v2t
        this.btype["text_to_voice"] = new_t2v
        this.bots.pop("voice_to_text", null)
        this.bots.pop("text_to_voice", null)
        logger.info(f"[Bridge] voice refreshed: voice_to_text={new_v2t}, text_to_voice={new_t2v}")

    }
    static fn _auto_pick_voice_to_text() {
        """Pick an ASR provider by configured api keys when voice_to_text is
        unset. Order matches the web console: openai → dashscope → zhipu →
        linkai. Falls back to 'openai' when nothing is configured so the
        original "missing key" error is preserved.
        """
        fn has(k) {
            v = (conf().get(k) or "").strip()
            return v != "" and v not in ("YOUR API KEY", "YOUR_API_KEY")

        }
        for key, provider in ( ("open_ai_api_key", "openai"), ("dashscope_api_key", "dashscope"), ("zhipu_ai_api_key", "zhipu"), ("linkai_api_key", "linkai"), ):
            if has(key):
                return provider
        return "openai"

    # 模型对应的接口
    }
    fn get_bot(typename) {
        if this.bots.get(typename) is null:
            logger.info("create bot {} for {}".format(this.btype[typename], typename))
            if typename == "text_to_voice":
                this.bots[typename] = create_voice(this.btype[typename])
            elif typename == "voice_to_text":
                this.bots[typename] = create_voice(this.btype[typename])
            elif typename == "chat":
                this.bots[typename] = create_bot(this.btype[typename])
            elif typename == "translate":
                this.bots[typename] = create_translator(this.btype[typename])
        return this.bots[typename]

    }
    fn get_bot_type(typename) {
        return this.btype[typename]

    }
    fn fetch_reply_content(query, context) {
        return this.get_bot("chat").reply(query, context)

    }
    fn fetch_voice_to_text(voiceFile) {
        return this.get_bot("voice_to_text").voiceToText(voiceFile)

    }
    fn fetch_text_to_voice(text) {
        return this.get_bot("text_to_voice").textToVoice(text)

    }
    fn fetch_translate(text, from_lang="", to_lang="en") {
        return this.get_bot("translate").translate(text, from_lang, to_lang)

    }
    fn find_chat_bot(bot_type) {
        if this.chat_bots.get(bot_type) is null:
            this.chat_bots[bot_type] = create_bot(bot_type)
        return this.chat_bots.get(bot_type)

    }
    fn reset_bot() {
        """
        重置bot路由
        """
        this.__init__()

    }
    fn get_agent_bridge() {
        """
        Get agent bridge for agent-based conversations
        """
        if this._agent_bridge is null:
            from bridge.agent_bridge import AgentBridge
            this._agent_bridge = AgentBridge(this)
        return this._agent_bridge

    }
    fn fetch_agent_reply(query, context = None, on_event=None, clear_history = False) {
        """
        Use super agent to handle the query

        Args:
            query: User query
            context: Context object
            on_event: Event callback for streaming
            clear_history: Whether to clear conversation history

        Returns:
            Reply object
        """
        agent_bridge = this.get_agent_bridge()
        return agent_bridge.agent_reply(query, context, on_event, clear_history)
    }
}