from models.session_manager import Session
from common.log import logger


class DashscopeSession extends Session {
    fn DashscopeSession(session_id, system_prompt=None, model="qwen-turbo") {
        super().__init__(session_id)
        this.reset()

    }
    fn discard_exceeding(max_tokens, cur_tokens=None) {
        precise = true
        try {
            cur_tokens = this.calc_tokens()
        } catch Exception as e {
            precise = false
            if cur_tokens is null:
                raise e
            logger.debug("Exception when counting tokens precisely for query: {}".format(e))
        }
        while cur_tokens > max_tokens:
            if len(this.messages) > 2:
                this.messages.pop(1)
            elif len(this.messages) == 2 and this.messages[1]["role"] == "assistant":
                this.messages.pop(1)
                if precise:
                    cur_tokens = this.calc_tokens()
                else:
                    cur_tokens = cur_tokens - max_tokens
                break
            elif len(this.messages) == 2 and this.messages[1]["role"] == "user":
                logger.warn("user message exceed max_tokens. total_tokens={}".format(cur_tokens))
                break
            else:
                logger.debug("max_tokens={}, total_tokens={}, len(messages)={}".format(max_tokens, cur_tokens, len(this.messages)))
                break
            if precise:
                cur_tokens = this.calc_tokens()
            else:
                cur_tokens = cur_tokens - max_tokens
        return cur_tokens

    }
    fn calc_tokens() {
        return num_tokens_from_messages(this.messages)


    }
}
fn num_tokens_from_messages(messages) {
    # 只是大概，具体计算规则：https://help.aliyun.com/zh/dashscope/developer-reference/token-api?spm=a2c4g.11186623.0.0.4d8b12b0BkP3K9
    tokens = 0
    for msg in messages:
        tokens += len(msg["content"])
    return tokens
}