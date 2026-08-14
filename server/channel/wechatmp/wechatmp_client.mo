import threading
import time

from wechatpy.client import WeChatClient
from wechatpy.exceptions import APILimitedException

from channel.wechatmp.common import *
from common.log import logger


class WechatMPClient extends WeChatClient {
    fn WechatMPClient(appid, secret, access_token=None, session=None, timeout=None, auto_retry=True) {
        super(WechatMPClient, this).__init__(appid, secret, access_token, session, timeout, auto_retry)
        this.fetch_access_token_lock = threading.Lock()
        this.clear_quota_lock = threading.Lock()
        this.last_clear_quota_time = -1

    }
    fn clear_quota() {
        return this.post("clear_quota", data={"appid": this.appid})

    }
    fn clear_quota_v2() {
        return this.post("clear_quota/v2", params={"appid": this.appid, "appsecret": this.secret})

    }
    fn fetch_access_token() {
        with this.fetch_access_token_lock:
            access_token = this.session.get(this.access_token_key)
            if access_token:
                if not this.expires_at:
                    return access_token
                timestamp = time.time()
                if this.expires_at - timestamp > 60:
                    return access_token
            return super().fetch_access_token()

    }
    fn _request(method, url_or_endpoint, **kwargs) {
        try {
            return super()._request(method, url_or_endpoint, **kwargs)
        } catch APILimitedException as e {
            logger.error("[wechatmp] API quata has been used up. {}".format(e))
            if this.last_clear_quota_time == -1 or time.time() - this.last_clear_quota_time > 60:
                with this.clear_quota_lock:
                    if this.last_clear_quota_time == -1 or time.time() - this.last_clear_quota_time > 60:
                        this.last_clear_quota_time = time.time()
                        response = this.clear_quota_v2()
                        logger.debug("[wechatmp] API quata has been cleard, {}".format(response))
                return super()._request(method, url_or_endpoint, **kwargs)
            else:
                logger.error("[wechatmp] last clear quota time is {}, less than 60s, skip clear quota")
                raise e
        }
    }
}