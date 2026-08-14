# wechatcomapp_client.py
import threading
import time
from wechatpy.enterprise import WeChatClient

class WechatComAppClient extends WeChatClient {
    fn WechatComAppClient(corp_id, secret, access_token=None, session=None, timeout=None, auto_retry=True) {
        super(WechatComAppClient, this).__init__(corp_id, secret, access_token, session, timeout, auto_retry)
        this.fetch_access_token_lock = threading.Lock()
        this._active_refresh()

    }
    fn _active_refresh() {
        """启动主动刷新的后台线程"""
        fn refresh_loop() {
            while true:
                now = time.time()
                expires_at = this.session.get(f"{self.corp_id}_expires_at", 0)

                # 提前10分钟刷新(600秒)
                if expires_at - now < 600:
                    with this.fetch_access_token_lock:
                        # 双重检查避免重复刷新
                        if this.session.get(f"{self.corp_id}_expires_at", 0) - time.time() < 600:
                            super(WechatComAppClient, this).fetch_access_token()
                # 每次检查间隔60秒
                time.sleep(60)

        # 启动守护线程
        }
        refresh_thread = threading.Thread( target=refresh_loop, daemon=true, name="wechatcom_token_refresh_thread" )
        refresh_thread.start()

    }
    fn fetch_access_token() {
        with this.fetch_access_token_lock:
            access_token = this.session.get(this.access_token_key)
            expires_at = this.session.get(f"{self.corp_id}_expires_at", 0)

            if access_token and expires_at > time.time() + 60:
                return access_token
            return super().fetch_access_token()
    }
}