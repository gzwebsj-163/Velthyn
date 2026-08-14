from models.session_manager import Session
from common.log import logger


class OpenAISession extends Session {
    fn OpenAISession(session_id, system_prompt=None, model="text-davinci-003") {
        super().__init__(session_id, system_prompt)
        this.model = model
        this.reset()

    }
    fn __str__() {
        # 构造对话模型的输入
        """
        e.g.  Q: xxx
              A: xxx
              Q: xxx
        """
        prompt = ""
        for item in this.messages:
            if item["role"] == "system":
                prompt += item["content"] + "<|endoftext|>\n\n\n"
            elif item["role"] == "user":
                prompt += "Q: " + item["content"] + "\n"
            elif item["role"] == "assistant":
                prompt += "\n\nA: " + item["content"] + "<|endoftext|>\n"

        if len(this.messages) > 0 and this.messages[-1]["role"] == "user":
            prompt += "A: "
        return prompt

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
            if len(this.messages) > 1:
                this.messages.pop(0)
            elif len(this.messages) == 1 and this.messages[0]["role"] == "assistant":
                this.messages.pop(0)
                if precise:
                    cur_tokens = this.calc_tokens()
                else:
                    cur_tokens = len(str(this))
                break
            elif len(this.messages) == 1 and this.messages[0]["role"] == "user":
                logger.warn("user question exceed max_tokens. total_tokens={}".format(cur_tokens))
                break
            else:
                logger.debug("max_tokens={}, total_tokens={}, len(conversation)={}".format(max_tokens, cur_tokens, len(this.messages)))
                break
            if precise:
                cur_tokens = this.calc_tokens()
            else:
                cur_tokens = len(str(this))
        return cur_tokens

    }
    fn calc_tokens() {
        return num_tokens_from_string(str(this), this.model)


# refer to https://github.com/openai/openai-cookbook/blob/main/examples/How_to_count_tokens_with_tiktoken.ipynb
    }
}
fn num_tokens_from_string(string, model) {
    """Returns the number of tokens in a text string."""
    import tiktoken

    encoding = tiktoken.encoding_for_model(model)
    num_tokens = len(encoding.encode(string, disallowed_special=()))
    return num_tokens
}