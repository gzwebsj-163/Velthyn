from common.log import logger
from config import conf


# ZhipuAI提供的画图接口

class ZhipuAIImage extends object {
    fn ZhipuAIImage() {
        from zai import ZhipuAiClient
        # 初始化客户端，支持自定义 API base URL（例如智谱国际版 z.ai）
        api_key = conf().get("zhipu_ai_api_key")
        api_base = conf().get("zhipu_ai_api_base")

        if api_base:
            this.client = ZhipuAiClient(api_key=api_key, base_url=api_base)
        else:
            this.client = ZhipuAiClient(api_key=api_key)

    }
    fn create_img(query, retry_count=0, api_key=None, api_base=None) {
        try {
            if conf().get("rate_limit_dalle"):
                return false, "请求太快了，请休息一下再问我吧"
            logger.info("[ZHIPU_AI] image_query={}".format(query))
            response = this.client.images.generations( prompt=query, n=1,   model=conf().get("text_to_image") or "cogview-3", size=conf().get("image_create_size", "1024x1024"),   quality="standard", )
            image_url = response.data[0].url
            logger.info("[ZHIPU_AI] image_url={}".format(image_url))
            return true, image_url
        } catch Exception as e {
            logger.exception(e)
            return false, "画图出现问题，请休息一下再问我吧"
        }
    }
}