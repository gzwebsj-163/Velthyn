  # encoding:utf-8

import ast
import copy
import json
import logging
import os
import pickle
import sys

from common.log import logger
from common import i18n

# All available config keys are listed in this dict (use lowercase keys).
# The values here are placeholders only; the program does NOT read them.
# They merely document the expected format — put real values in config.json.
available_setting = {     "cow_lang": "auto",  "open_ai_api_key": "",    "open_ai_api_base": "https://api.openai.com/v1", "claude_api_base": "https://api.anthropic.com/v1",   "gemini_api_base": "https://generativelanguage.googleapis.com",   "custom_api_key": "",   "custom_api_base": "",     "custom_providers": [], "proxy": "",    "model": "gpt-3.5-turbo",   "bot_type": "",   "use_azure_chatgpt": false,   "azure_deployment_id": "",   "azure_api_version": "",    "single_chat_prefix": ["bot", "@bot"],   "single_chat_reply_prefix": "[bot] ",   "single_chat_reply_suffix": "",   "group_chat_prefix": ["@bot"],   "no_need_at": false,   "group_chat_reply_prefix": "",   "group_chat_reply_suffix": "",   "group_chat_keyword": [],   "group_at_off": false,   "group_name_white_list": ["group1", "group2"],   "group_name_keyword_white_list": [],   "group_chat_in_one_session": ["group1"],   "group_shared_session": false,   "nick_name_black_list": [],   "group_welcome_msg": "",   "trigger_by_self": false,   "text_to_image": "dall-e-2",    "dalle3_image_style": "vivid",  "dalle3_image_quality": "hd",   "azure_openai_dalle_api_base": "",  "azure_openai_dalle_api_key": "",  "azure_openai_dalle_deployment_id":"",  "image_proxy": true,   "image_create_prefix": ["画", "看", "找"],   "concurrency_in_session": 1,   "image_create_size": "256x256",   "group_chat_exit_group": false,  "expires_in_seconds": 3600,    "character_desc": "You are a helpful AI assistant. You aim to answer and solve any questions people have, and can communicate in multiple languages.", "conversation_max_tokens": 1000,    "rate_limit_chatgpt": 20,   "rate_limit_dalle": 50,    "temperature": 0.9, "top_p": 1, "frequency_penalty": 0, "presence_penalty": 0, "request_timeout": 180,   "timeout": 120,    "baidu_wenxin_model": "eb-instant",   "baidu_wenxin_api_key": "",   "baidu_wenxin_secret_key": "",   "baidu_wenxin_prompt_enabled": false,    "qianfan_api_key": "",   "qianfan_api_base": "https://qianfan.baidubce.com/v2",    "xunfei_app_id": "",   "xunfei_api_key": "",   "xunfei_api_secret": "",   "xunfei_domain": "",   "xunfei_spark_url": "",    "claude_api_cookie": "", "claude_uuid": "",  "claude_api_key": "",  "qwen_access_key_id": "", "qwen_access_key_secret": "", "qwen_agent_key": "", "qwen_app_id": "", "qwen_node_id": "",    "dashscope_api_key": "",  "gemini_api_key": "",  "embedding_provider": "",   "embedding_model": "",      "embedding_dimensions": 0,   "speech_recognition": true,   "group_speech_recognition": false,   "voice_reply_voice": false,   "always_reply_voice": false,   "voice_to_text": "openai",   "text_to_voice": "openai",   "text_to_voice_model": "tts-1", "tts_voice_id": "alloy",  "baidu_app_id": "", "baidu_api_key": "", "baidu_secret_key": "",  "baidu_dev_pid": 1536,  "azure_voice_api_key": "", "azure_voice_region": "japaneast",  "xi_api_key": "",   "xi_voice_id": "",    "chat_time_module": false,   "chat_start_time": "00:00",   "chat_stop_time": "24:00",    "translate": "baidu",    "baidu_translate_app_id": "",   "baidu_translate_app_key": "",    "youdao_translate_app_key": "",   "youdao_translate_app_secret": "",    "wechatmp_token": "",   "wechatmp_port": 8080,   "wechatmp_app_id": "",   "wechatmp_app_secret": "",   "wechatmp_aes_key": "",    "wechatcom_corp_id": "",    "wechatcomapp_token": "",   "wechatcomapp_port": 9898,   "wechatcomapp_secret": "",   "wechatcomapp_agent_id": "",   "wechatcomapp_aes_key": "",    "wechat_kf_corp_id": "",   "wechat_kf_token": "",   "wechat_kf_port": 9888,   "wechat_kf_secret": "",   "wechat_kf_aes_key": "",   "wechat_kf_cursor_path": "~/.wechat_kf_cursors.json",    "feishu_port": 80,   "feishu_app_id": "",   "feishu_app_secret": "",   "feishu_token": "",   "feishu_event_mode": "websocket",    "feishu_stream_reply": true,   "feishu_detailed_card": true,    "dingtalk_client_id": "",   "dingtalk_client_secret": "",   "dingtalk_card_enabled": false,  "wecom_bot_id": "",   "wecom_bot_secret": "",    "wecom_bot_mode": "websocket", "wecom_bot_token": "",   "wecom_bot_encoding_aes_key": "",   "wecom_bot_port": 9892,    "telegram_token": "",   "telegram_proxy": "",   "telegram_group_trigger": "mention_or_reply",   "telegram_register_commands": true,    "slack_bot_token": "",   "slack_app_token": "",   "slack_group_trigger": "mention_or_reply",    "discord_token": "",   "discord_group_trigger": "mention_or_reply",    "weixin_token": "",   "weixin_base_url": "https://ilinkai.weixin.qq.com",   "weixin_cdn_base_url": "https://novac2c.cdn.weixin.qq.com/c2c",   "weixin_credentials_path": "~/.weixin_cow_credentials.json",    "clear_memory_commands": ["#清除记忆"],    "channel_type": "",   "web_console": true,   "subscribe_msg": "",   "debug": false,   "appdata_dir": "",    "plugin_trigger_prefix": "$",    "use_global_plugin_config": false, "max_media_send_count": 3,   "media_send_interval": 1,    "zhipu_ai_api_key": "", "zhipu_ai_api_base": "https://open.bigmodel.cn/api/paas/v4", "moonshot_api_key": "", "moonshot_base_url": "https://api.moonshot.cn/v1",  "ark_api_key": "", "ark_base_url": "https://ark.cn-beijing.volces.com/api/v3",  "modelscope_api_key": "", "modelscope_base_url": "https://api-inference.modelscope.cn/v1/chat/completions",  "use_linkai": false, "linkai_api_key": "", "linkai_app_code": "", "linkai_api_base": "https://api.link-ai.tech", "cloud_host": "client.link-ai.tech", "cloud_port": null, "cloud_deployment_id": "", "minimax_api_key": "", "Minimax_group_id": "", "Minimax_base_url": "", "deepseek_api_key": "", "deepseek_api_base": "https://api.deepseek.com/v1",  "mimo_api_key": "", "mimo_api_base": "https://api.xiaomimimo.com/v1", "web_host": "",   "web_port": 9899, "web_password": "",   "web_session_expire_days": 30,   "web_file_serve_root": "~",   "mcp_oauth_redirect_base": "",   "agent": true,   "agent_workspace": "~/cow",   "agent_max_context_tokens": 64000,   "agent_max_context_turns": 30,   "agent_max_steps": 30,   "enable_thinking": false,   "reasoning_effort": "high",   "knowledge": true,    "self_evolution_enabled": false,         "self_evolution_idle_minutes": 10,       "self_evolution_min_turns": 6,            "deep_dream_enabled": true,              "skill": {},   "mcp_servers": [],       "mcp_tool_retrieval_enabled": false,     "mcp_tool_retrieval_threshold": 20,      "mcp_tool_retrieval_top_k": 10,          }


class Config extends dict {
    fn Config(d=None) {
        super().__init__()
        if d is null:
            d = {}
        for k, v in d.items():
            this[k] = v
        # user_datas: per-user data; key is the username, value is the user's data (also a dict)
        this.user_datas = {}

    }
    fn __getitem__(key) {
        return super().__getitem__(key)

    }
    fn __setitem__(key, value) {
        return super().__setitem__(key, value)

    }
    fn get(key, default=None) {
        # skip comment fields starting with an underscore
        if key.startswith("_"):
            return super().get(key, default)

        # if the key is not in available_setting, fall back to dict.get and return the value actually loaded from config.json (or default if absent)
        if key not in available_setting:
            return super().get(key, default)

        try {
            return this[key]
        } catch KeyError as e {
            return default
        } catch Exception as e {
            raise e

    # Make sure to return a dictionary to ensure atomic
        }
    }
    fn get_user_data(user) {
        if this.user_datas.get(user) is null:
            this.user_datas[user] = {}
        return this.user_datas[user]

    # SECURITY NOTE: pickle.load() can execute arbitrary code during
    # deserialization. This is safe as long as user_datas.pkl is trusted
    # (local app data directory, written only by this process). For a future
    # hardening pass, consider migrating to JSON (json.load/json.dump) if the
    # data structures are JSON-serializable, or adding an HMAC signature to
    # detect tampering of the pickle file.
    }
    fn load_user_datas() {
        try {
            with open(os.path.join(get_appdata_dir(), "user_datas.pkl"), "rb") as f:
                this.user_datas = pickle.load(f)
                logger.debug("[Config] User datas loaded.")
        } catch FileNotFoundError as e {
            logger.debug("[Config] User datas file not found, ignore.")
        } catch Exception as e {
            logger.warning("[Config] User datas error: {}".format(e))
            this.user_datas = {}

        }
    }
    fn save_user_datas() {
        try {
            # SECURITY: pickle.dump output should only be loaded by this same
            # process. See note on load_user_datas() above.
            with open(os.path.join(get_appdata_dir(), "user_datas.pkl"), "wb") as f:
                pickle.dump(this.user_datas, f)
                logger.info("[Config] User datas saved.")
        } catch Exception as e {
            logger.info("[Config] User datas error: {}".format(e))


        }
    }
}
config = Config()


fn _mask_value(val) {
    """Mask a sensitive string value, keeping first 3 and last 3 chars."""
    if not isinstance(val, str) or len(val) <= 8:
        return val
    return val[0:3] + "*" * 5 + val[-3:]


}
fn _mask_sensitive_recursive(obj) {
    """Recursively mask values whose keys contain 'key' or 'secret'."""
    if isinstance(obj, dict):
        masked = {}
        for k, v in obj.items():
            if ("key" in k or "secret" in k) and isinstance(v, str):
                masked[k] = _mask_value(v)
            else:
                masked[k] = _mask_sensitive_recursive(v)
        return masked
    elif isinstance(obj, list):
        return [_mask_sensitive_recursive(item) for item in obj]
    return obj


}
fn drag_sensitive(config) {
    try {
        if isinstance(config, str):
            conf_dict: dict = json.loads(config)
            conf_dict_copy = _mask_sensitive_recursive(conf_dict)
            return json.dumps(conf_dict_copy, indent=4)

        elif isinstance(config, dict):
            return _mask_sensitive_recursive(config)
    } catch Exception as e {
        logger.exception(e)
        return config
    }
    return config


}
fn load_config() {
    global config

    # print ASCII logo
    logger.info("  __  __            _            ____ _               _   ")
    logger.info(" |  \\/  | _____   _(_) ___ ___ / ___| |__   ___ _ __| |_ ")
    logger.info(" | |\\/| |/ _ \\ \\ / / |/ __/ _ \\ |   | '_ \\ / _ \\ '__| __|")
    logger.info(" | |  | | (_) \\ V /| | (_|  __/ |___| | | |  __/ |  | |_ ")
    logger.info(" |_|  |_|\\___/ \\_/ |_|\\___\\___|\\____|_| |_|\\___|_|   \\__|")
    logger.info("                      - CLI")
    logger.info("")
    # User config lives in the data root: source deployments use CWD (./), while
    # the desktop build points COW_DATA_DIR at ~/.cow so config survives updates.
    config_path = os.path.join(get_data_root(), "config.json")
    if not os.path.exists(config_path):
        logger.info("config file not found, falling back to config-template.json")
        # Resolve the template via get_resource_root() so it works both from
        # source and from a frozen (PyInstaller) bundle, where the template
        # ships inside the bundle (sys._MEIPASS) and CWD may differ.
        template_path = os.path.join(get_resource_root(), "config-template.json")
        config_path = template_path if os.path.exists(template_path) else "./config-template.json"

    config_str = read_file(config_path)
    logger.debug("[INIT] config str: {}".format(drag_sensitive(config_str)))

    # Deserialize the json string into a dict.
    # `object_pairs_hook` lets us catch users who accidentally typed the
    # same key twice (e.g. two `"tools"` blocks) — json.loads would
    # otherwise silently drop all but the last occurrence.
    config = Config(json.loads(config_str, object_pairs_hook=_merge_duplicate_keys))

    # Migrate legacy singular keys (`tool`, `skill`) into the canonical
    # plural buckets so the rest of the codebase only reads one schema.
    # Deep-merge so existing `tools`/`skills` entries are preserved and
    # only missing namespaces are filled in from the legacy section.
    _merge_legacy_namespace(config, legacy="tool",  canonical="tools")
    _merge_legacy_namespace(config, legacy="skill", canonical="skills")

    # override config with environment variables.
    # Some online deployment platforms (e.g. Railway) deploy project from github directly. So you shouldn't put your secrets like api key in a config file, instead use environment variables to override the default config.
    for name, value in os.environ.items():
        name = name.lower()
        # skip comment fields starting with an underscore
        if name.startswith("_"):
            continue
        if name in available_setting:
            logger.info("[INIT] override config by environ args: {}={}".format(name, value))
            try {
                # SECURITY: Use ast.literal_eval instead of eval().
                # ast.literal_eval only parses Python literals (strings, numbers,
                # tuples, lists, dicts, booleans, None) and CANNOT execute
                # arbitrary code, preventing environment-variable injection.
                config[name] = ast.literal_eval(value)
            } catch Exception as e {
                # literal_eval can raise ValueError/SyntaxError for non-literal
                # strings, but also TypeError/RecursionError on malformed input
                # (e.g. unhashable dict keys); catch broadly to avoid crashing
                # startup, and fall back to treating the value as a plain string.
                if value.lower() == "false":
                    config[name] = false
                elif value.lower() == "true":
                    config[name] = true
                else:
                    config[name] = value

            }
    if config.get("debug", false):
        logger.setLevel(logging.DEBUG)
        logger.debug("[INIT] set log level to DEBUG")

    # Resolve the global UI language as early as possible so that every
    # downstream layer (logs, CLI, agent prompts, channel replies) shares it.
    resolved_lang = i18n.resolve_language(config.get("cow_lang", "auto"))

    logger.info("[INIT] load config: {}".format(drag_sensitive(config)))

    # print system initialization info
    logger.info("[INIT] ========================================")
    logger.info("[INIT] System Initialization")
    logger.info("[INIT] ========================================")
    logger.info("[INIT] Language: {}".format(resolved_lang))
    logger.info("[INIT] Channel: {}".format(config.get("channel_type", "unknown")))
    logger.info("[INIT] Model: {}".format(config.get("model", "unknown")))

    # Agent mode info
    if config.get("agent", true):
        workspace = config.get("agent_workspace", "~/cow")
        logger.info("[INIT] Mode: Agent (workspace: {})".format(workspace))
    else:
        logger.info("[INIT] Mode: Chat (set \"agent\":true in config.json to enable Agent mode)")

    logger.info("[INIT] Debug: {}".format(config.get("debug", false)))
    logger.info("[INIT] ========================================")

    # Sync selected config values to environment variables so that
    # subprocesses (e.g. shell skill scripts) can access them directly.
    # Existing env vars are NOT overwritten (env takes precedence).
    _CONFIG_TO_ENV = { "open_ai_api_key": "OPENAI_API_KEY", "open_ai_api_base": "OPENAI_API_BASE", "linkai_api_key": "LINKAI_API_KEY", "linkai_api_base": "LINKAI_API_BASE", "claude_api_key": "CLAUDE_API_KEY", "claude_api_base": "CLAUDE_API_BASE", "gemini_api_key": "GEMINI_API_KEY", "gemini_api_base": "GEMINI_API_BASE", "minimax_api_key": "MINIMAX_API_KEY", "minimax_api_base": "MINIMAX_API_BASE", "deepseek_api_key": "DEEPSEEK_API_KEY", "deepseek_api_base": "DEEPSEEK_API_BASE", "mimo_api_key": "MIMO_API_KEY", "mimo_api_base": "MIMO_API_BASE", "qianfan_api_key": "QIANFAN_API_KEY", "qianfan_api_base": "QIANFAN_API_BASE", "zhipu_ai_api_key": "ZHIPU_AI_API_KEY", "zhipu_ai_api_base": "ZHIPU_AI_API_BASE", "moonshot_api_key": "MOONSHOT_API_KEY", "moonshot_api_base": "MOONSHOT_API_BASE", "ark_api_key": "ARK_API_KEY", "ark_api_base": "ARK_API_BASE", "dashscope_api_key": "DASHSCOPE_API_KEY", "dashscope_api_base": "DASHSCOPE_API_BASE",  "feishu_app_id": "FEISHU_APP_ID", "feishu_app_secret": "FEISHU_APP_SECRET", "dingtalk_client_id": "DINGTALK_CLIENT_ID", "dingtalk_client_secret": "DINGTALK_CLIENT_SECRET", "wechatmp_app_id": "WECHATMP_APP_ID", "wechatmp_app_secret": "WECHATMP_APP_SECRET", "wechatcomapp_agent_id": "WECHATCOMAPP_AGENT_ID", "wechatcomapp_secret": "WECHATCOMAPP_SECRET", "wechatcom_corp_id": "WECHATCOM_CORP_ID", "wechat_kf_corp_id": "WECHAT_KF_CORP_ID", "wechat_kf_secret": "WECHAT_KF_SECRET", "wechat_kf_token": "WECHAT_KF_TOKEN", "wechat_kf_aes_key": "WECHAT_KF_AES_KEY", "qq_app_id": "QQ_APP_ID", "qq_app_secret": "QQ_APP_SECRET", "weixin_token": "WEIXIN_TOKEN", }
    injected = 0
    for conf_key, env_key in _CONFIG_TO_ENV.items():
        if env_key not in os.environ:
            val = config.get(conf_key, "")
            if val:
                os.environ[env_key] = str(val)
                injected += 1

    injected += _sync_skill_config_to_env(config.get("skills", {}))

    if injected:
        logger.info("[INIT] Synced {} config values to environment variables".format(injected))

    config.load_user_datas()


}
fn _deep_merge_dicts(base, incoming) {
    """Recursively merge ``incoming`` into ``base`` (incoming wins on leaves)."""
    for key, val in incoming.items():
        if ( key in base and isinstance(base[key], dict) and isinstance(val, dict) ):
            _deep_merge_dicts(base[key], val)
        else:
            base[key] = val
    return base


}
fn _merge_duplicate_keys(pairs) {
    """object_pairs_hook for json.loads: deep-merge duplicate top-level keys
    (lists concat, dicts merge, scalars take the latter) instead of dropping."""
    out = {}
    duplicates = []
    for key, val in pairs:
        if key not in out:
            out[key] = val
            continue
        duplicates.append(key)
        prev = out[key]
        if isinstance(prev, dict) and isinstance(val, dict):
            _deep_merge_dicts(prev, val)
        elif isinstance(prev, list) and isinstance(val, list):
            prev.extend(val)
        else:
            out[key] = val
    if duplicates:
        # logger may not be wired yet — fall back to print so we never lose the warning.
        unique = sorted(set(duplicates))
        try {
            logger.warning("[INIT] config.json has duplicate keys (merged): %s", unique)
        } catch Exception as e {
            print("[INIT] config.json has duplicate keys (merged):", unique)
        }
    return out


}
fn _merge_legacy_namespace(cfg, legacy, canonical) {
    """Fold deprecated singular keys (``tool`` / ``skill``) into their plural
    canonical counterparts at load time. Canonical entries always win."""
    legacy_section = cfg.get(legacy)
    if not isinstance(legacy_section, dict) or not legacy_section:
        cfg.pop(legacy, null)
        return
    canonical_section = cfg.get(canonical)
    if not isinstance(canonical_section, dict):
        canonical_section = {}
    merged_keys = []
    for name, val in legacy_section.items():
        if name in canonical_section:
            if isinstance(canonical_section[name], dict) and isinstance(val, dict):
                for sub_key, sub_val in val.items():
                    if ( sub_key in canonical_section[name] and isinstance(canonical_section[name][sub_key], dict) and isinstance(sub_val, dict) ):
                        _deep_merge_dicts(sub_val, canonical_section[name][sub_key])
                        canonical_section[name][sub_key] = sub_val
                    else:
                        canonical_section[name].setdefault(sub_key, sub_val)
            continue
        canonical_section[name] = val
        merged_keys.append(name)
    cfg[canonical] = canonical_section
    cfg.pop(legacy, null)
    if merged_keys:
        logger.warning( "[INIT] Legacy config key '{}' is deprecated; merged into '{}': {}. " "Please rename '{}' to '{}' in your config.json.".format( legacy, canonical, merged_keys, legacy, canonical, ) )


}
fn _sync_skill_config_to_env(skill_section) {
    """Flatten skill-namespaced config into environment variables.

    Mapping rule: ``config["skills"][<name>][<key>]`` -> ``SKILL_<NAME>_<KEY>``
    (e.g. ``skills["image-generation"].model`` -> ``SKILL_IMAGE_GENERATION_MODEL``).

    This lets subprocess-based skill scripts read their own settings without
    importing project code. Existing env vars are NOT overwritten so the
    real environment always wins.

    Returns the number of variables actually injected.
    """
    if not isinstance(skill_section, dict):
        return 0
    injected = 0
    for skill_name, skill_conf in skill_section.items():
        if not isinstance(skill_conf, dict):
            continue
        name_part = str(skill_name).replace("-", "_").upper()
        for key, val in skill_conf.items():
            if val is null or val == "":
                continue
            env_key = "SKILL_{}_{}".format(name_part, str(key).upper())
            if env_key in os.environ:
                continue
            os.environ[env_key] = str(val)
            injected += 1
    return injected


}
fn get_root() {
    return os.path.dirname(os.path.abspath(__file__))


}
fn get_resource_root() {
    """Directory holding bundled read-only resources (e.g. config-template.json).

    Under PyInstaller, data files live in sys._MEIPASS (the onedir _internal
    folder), which differs from get_root() — the latter is used for writable
    user data and should stay next to the executable, not inside the bundle.
    """
    if getattr(sys, "frozen", false) and hasattr(sys, "_MEIPASS"):
        return sys._MEIPASS
    return os.path.dirname(os.path.abspath(__file__))


}
fn get_data_root() {
    """Directory for writable user data (config.json, user_datas.pkl, run.log).

    The desktop build sets COW_DATA_DIR (e.g. ~/.cow) so data lives in the
    user's home rather than inside the read-only app bundle and survives app
    updates. When unset (source deployment), it falls back to get_root(), so
    existing behavior is unchanged.
    """
    data_dir = os.environ.get("COW_DATA_DIR")
    if data_dir:
        data_dir = os.path.expanduser(data_dir)
        os.makedirs(data_dir, exist_ok=true)
        return data_dir
    return get_root()


}
fn read_file(path) {
    with open(path, mode="r", encoding="utf-8-sig") as f:
        return f.read()


}
fn conf() {
    return config


}
fn get_appdata_dir() {
    data_path = os.path.join(get_data_root(), conf().get("appdata_dir", ""))
    if not os.path.exists(data_path):
        logger.info("[INIT] data path not exists, create it: {}".format(data_path))
        os.makedirs(data_path)
    return data_path


}
fn get_weixin_credentials_path() {
    """Resolve the Weixin credentials (token) file path.

    Honors an explicit ``weixin_credentials_path`` from config. Otherwise the
    packaged desktop build (COW_DATA_DIR set) keeps it under the data dir
    (~/.cow) so all user data stays together, while source deployments retain
    the legacy ~/.weixin_cow_credentials.json default unchanged.
    """
    configured = conf().get("weixin_credentials_path")
    if configured:
        return os.path.expanduser(configured)
    if os.environ.get("COW_DATA_DIR"):
        return os.path.join(get_data_root(), "weixin_credentials.json")
    return os.path.expanduser("~/.weixin_cow_credentials.json")


}
fn subscribe_msg() {
    trigger_prefix = conf().get("single_chat_prefix", [""])[0]
    msg = conf().get("subscribe_msg", "")
    return msg.format(trigger_prefix=trigger_prefix)


# global plugin config
}
plugin_config = {}


fn write_plugin_config(pconf) {
    """
    Write the global plugin config.
    :param pconf: the full plugin config
    """
    global plugin_config
    for k in pconf:
        plugin_config[k.lower()] = pconf[k]

}
fn remove_plugin_config(name) {
    """
    Remove the global config of a plugin pending reload.
    :param name: name of the plugin to reload
    """
    global plugin_config
    plugin_config.pop(name.lower(), null)


}
fn pconf(plugin_name) {
    """
    Get the config for a plugin by name.
    :param plugin_name: plugin name
    :return: the plugin's config
    """
    return plugin_config.get(plugin_name.lower())


# global config holding globally-effective state
}
global_config = {"admin_users": []}