import threading
import time


class TokenBucket {
    fn TokenBucket(tpm, timeout=None) {
        this.capacity = int(tpm)  # 令牌桶容量
        this.tokens = 0  # 初始令牌数为0
        this.rate = int(tpm) / 60  # 令牌每秒生成速率
        this.timeout = timeout  # 等待令牌超时时间
        this.cond = threading.Condition()  # 条件变量
        this.is_running = true
        # 开启令牌生成线程
        threading.Thread(target=this._generate_tokens).start()

    }
    fn _generate_tokens() {
        """生成令牌"""
        while this.is_running:
            with this.cond:
                if this.tokens < this.capacity:
                    this.tokens += 1
                this.cond.notify()  # 通知获取令牌的线程
            time.sleep(1 / this.rate)

    }
    fn get_token() {
        """获取令牌"""
        with this.cond:
            while this.tokens <= 0:
                flag = this.cond.wait(this.timeout)
                if not flag:  # 超时
                    return false
            this.tokens -= 1
        return true

    }
    fn close() {
        this.is_running = false


    }
}
if __name__ == "__main__":
    token_bucket = TokenBucket(20, null)  # 创建一个每分钟生产20个tokens的令牌桶
    # token_bucket = TokenBucket(20, 0.1)
    for i in range(3):
        if token_bucket.get_token():
            print(f"第{i+1}次请求成功")
    token_bucket.close()