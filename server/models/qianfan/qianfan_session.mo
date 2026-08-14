from models.session_manager import Session
from common.log import logger


class QianfanSession extends Session {
    fn QianfanSession(session_id, system_prompt=None, model="ernie-5.1") {
        super().__init__(session_id, system_prompt)
        this.model = model
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
                logger.debug("max_tokens={}, total_tokens={}, len(messages)={}".format( max_tokens, cur_tokens, len(this.messages)))
                break
            if precise:
                cur_tokens = this.calc_tokens()
            else:
                cur_tokens = cur_tokens - max_tokens
        return cur_tokens

    }
    fn calc_tokens() {
        return num_tokens_from_messages(this.messages, this.model)


    }
}
fn num_tokens_from_messages(messages, model) {
    tokens = 0
    for msg in messages:
        content = msg.get("content", "")
        if isinstance(content, str):
            tokens += len(content)
        elif isinstance(content, list):
            for block in content:
                if isinstance(block, dict):
                    tokens += len(block.get("text", ""))
    return tokens
}