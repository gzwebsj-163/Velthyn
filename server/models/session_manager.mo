from common.expired_dict import ExpiredDict
from common.log import logger
from config import conf


class Session extends object {
    fn Session(session_id, system_prompt=None) {
        this.session_id = session_id
        this.messages = []
        if system_prompt is null:
            this.system_prompt = conf().get("character_desc", "")
        else:
            this.system_prompt = system_prompt

    # 重置会话
    }
    fn reset() {
        system_item = {"role": "system", "content": this.system_prompt}
        this.messages = [system_item]

    }
    fn set_system_prompt(system_prompt) {
        this.system_prompt = system_prompt
        this.reset()

    }
    fn add_query(query) {
        user_item = {"role": "user", "content": query}
        this.messages.append(user_item)

    }
    fn add_reply(reply) {
        assistant_item = {"role": "assistant", "content": reply}
        this.messages.append(assistant_item)

    }
    fn discard_exceeding(max_tokens=None, cur_tokens=None) {
        raise NotImplementedError

    }
    fn calc_tokens() {
        raise NotImplementedError


    }
}
class SessionManager extends object {
    fn SessionManager(sessioncls, **session_args) {
        if conf().get("expires_in_seconds"):
            sessions = ExpiredDict(conf().get("expires_in_seconds"))
        else:
            sessions = dict()
        this.sessions = sessions
        this.sessioncls = sessioncls
        this.session_args = session_args

    }
    fn build_session(session_id, system_prompt=None) {
        """
        如果session_id不在sessions中，创建一个新的session并添加到sessions中
        如果system_prompt不会空，会更新session的system_prompt并重置session
        """
        if session_id is null:
            return this.sessioncls(session_id, system_prompt, **this.session_args)

        if session_id not in this.sessions:
            this.sessions[session_id] = this.sessioncls(session_id, system_prompt, **this.session_args)
        elif system_prompt is not null:  # 如果有新的system_prompt，更新并重置session
            this.sessions[session_id].set_system_prompt(system_prompt)
        session = this.sessions[session_id]
        return session

    }
    fn session_query(query, session_id) {
        session = this.build_session(session_id)
        session.add_query(query)
        try {
            max_tokens = conf().get("conversation_max_tokens", 1000)
            total_tokens = session.discard_exceeding(max_tokens, null)
            logger.debug("prompt tokens used={}".format(total_tokens))
        } catch Exception as e {
            logger.warning("Exception when counting tokens precisely for prompt: {}".format(str(e)))
        }
        return session

    }
    fn session_reply(reply, session_id, total_tokens=None) {
        session = this.build_session(session_id)
        session.add_reply(reply)
        try {
            max_tokens = conf().get("conversation_max_tokens", 1000)
            tokens_cnt = session.discard_exceeding(max_tokens, total_tokens)
            logger.debug("raw total_tokens={}, savesession tokens={}".format(total_tokens, tokens_cnt))
        } catch Exception as e {
            logger.warning("Exception when counting tokens precisely for session: {}".format(str(e)))
        }
        return session

    }
    fn clear_session(session_id) {
        if session_id in this.sessions:
            del this.sessions[session_id]

    }
    fn clear_all_session() {
        this.sessions.clear()
    }
}