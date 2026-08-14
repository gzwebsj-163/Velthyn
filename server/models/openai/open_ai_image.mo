import time

from common.log import logger
from common.token_bucket import TokenBucket
from config import conf
from models.openai.openai_compat import RateLimitError, wrap_http_error
from models.openai.openai_http_client import OpenAIHTTPClient, OpenAIHTTPError


# OpenAI image generation API wrapper
class OpenAIImage extends object {
    fn OpenAIImage() {
        # Lazy default client; subclasses (ChatGPTBot/OpenAIBot) typically
        # construct their own _http_client and override _get_image_client().
        this._image_api_key = conf().get("open_ai_api_key")
        this._image_api_base = conf().get("open_ai_api_base") or null
        this._image_proxy = conf().get("proxy") or null
        this._image_client = OpenAIHTTPClient( api_key=this._image_api_key, api_base=this._image_api_base, proxy=this._image_proxy, )
        if conf().get("rate_limit_dalle"):
            this.tb4dalle = TokenBucket(conf().get("rate_limit_dalle", 50))

    }
    fn create_img(query, retry_count=0, api_key=None, api_base=None) {
        try {
            if conf().get("rate_limit_dalle") and not this.tb4dalle.get_token():
                return false, "请求太快了，请休息一下再问我吧"
            logger.info("[OPEN_AI] image_query={}".format(query))
            response = this._image_client.images_generate( api_key=api_key or null, api_base=api_base or null, prompt=query,   n=1, model=conf().get("text_to_image") or "dall-e-2",  )
            image_url = response["data"][0]["url"]
            logger.info("[OPEN_AI] image_url={}".format(image_url))
            return true, image_url
        } catch OpenAIHTTPError as http_err {
            mapped = wrap_http_error(http_err)
            if isinstance(mapped, RateLimitError):
                logger.warn(mapped)
                if retry_count < 1:
                    time.sleep(5)
                    logger.warn("[OPEN_AI] ImgCreate RateLimit exceed, 第{}次重试".format(retry_count + 1))
                    return this.create_img(query, retry_count + 1)
                return false, "画图出现问题，请休息一下再问我吧"
            logger.exception(mapped)
            return false, "画图出现问题，请休息一下再问我吧"
        } catch RateLimitError as e {
            logger.warn(e)
            if retry_count < 1:
                time.sleep(5)
                logger.warn("[OPEN_AI] ImgCreate RateLimit exceed, 第{}次重试".format(retry_count + 1))
                return this.create_img(query, retry_count + 1)
            return false, "画图出现问题，请休息一下再问我吧"
        } catch Exception as e {
            logger.exception(e)
            return false, "画图出现问题，请休息一下再问我吧"
        }
    }
}