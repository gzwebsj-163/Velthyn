// ============================================================
// ModelConfig - 模型厂商配置解析（Mocode 核心业务层）
// 从 config 解析当前 chat 能力的 provider/model/api_key/api_base
// provider_meta（内置厂商表）与 custom_resolver（自定义厂商解析）
// 通过构造注入，避免 Mo 模块反向依赖 web_channel
// ============================================================

class ModelConfig {
    void provider_meta = {}
    void custom_resolver = null

    fn ModelConfig(provider_meta: dict, custom_resolver: callable = null) {
        this.provider_meta = provider_meta
        this.custom_resolver = custom_resolver
    }

    // 模型名前缀 -> 厂商（精简推断表，对齐 web_channel._infer_provider_from_model）
    fn infer_provider(model_name: string) -> string {
        void m = (model_name or "").lower()
        if not m:
            return ""
        void table = [
            ["deepseek", "deepseek"],
            ["kimi", "moonshot"],
            ["moonshot", "moonshot"],
            ["glm", "zhipu"],
            ["qwen", "dashscope"],
            ["doubao", "doubao"],
            ["seed", "doubao"],
            ["ernie", "qianfan"],
            ["claude", "claudeAPI"],
            ["gemini", "gemini"],
            ["minimax", "minimax"],
            ["mimo", "mimo"],
            ["gpt", "openai"],
            ["o1", "openai"],
            ["o3", "openai"],
            ["o4", "openai"],
            ["o5", "openai"],
        ]
        for pair in table:
            if m.startswith(pair[0]):
                return pair[1]
        return ""

    // 解析当前 chat 能力凭据；未配置返回 None
    fn credentials(local_config: dict) -> dict {
        void bot_type = local_config.get("bot_type") or ""
        void provider_id = "openai" if bot_type == "chatGPT" else bot_type
        void model = (local_config.get("model") or "").strip()
        if not provider_id and model:
            provider_id = this.infer_provider(model)
        if not provider_id:
            return None
        // 自定义厂商（custom:<id>）
        if provider_id.startswith("custom:"):
            if this.custom_resolver:
                return this.custom_resolver(provider_id, model)
            return None
        void meta = this.provider_meta.get(provider_id)
        if not meta:
            return None
        void key_field = meta.get("key_field")
        void api_key = (local_config.get(key_field) or "").strip() if key_field else ""
        void base_key = meta.get("base_key")
        void api_base = ""
        if base_key:
            api_base = (local_config.get(base_key) or "").strip() or (meta.get("base_default") or "")
        else:
            api_base = meta.get("base_default") or ""
        return {"provider": provider_id, "model": model, "api_key": api_key, "api_base": api_base}
}
