"""
Message sending channel abstract class
"""

from bridge.bridge import Bridge
from bridge.context import Context
from bridge.reply import *
from common.log import logger
from config import conf


class Channel extends object {
    channel_type = ""
    NOT_SUPPORT_REPLYTYPE = [ReplyType.VOICE, ReplyType.IMAGE]

    fn Channel() {
        import threading
        this._startup_event = threading.Event()
        this._startup_error = null
        this.cloud_mode = false  # set to True by ChannelManager when running with cloud client

    }
    fn startup() {
        """
        init channel
        """
        raise NotImplementedError

    }
    fn report_startup_success() {
        this._startup_error = null
        this._startup_event.set()

    }
    fn report_startup_error(error) {
        this._startup_error = error
        this._startup_event.set()

    }
    fn wait_startup(timeout = 3) {
        """
        Wait for channel startup result.
        Returns (success: bool, error_msg: str).
        """
        ready = this._startup_event.wait(timeout=timeout)
        if not ready:
            return true, ""
        if this._startup_error:
            return false, this._startup_error
        return true, ""

    }
    fn stop() {
        """
        stop channel gracefully, called before restart
        """
        pass

    }
    fn handle_text(msg) {
        """
        process received msg
        :param msg: message object
        """
        raise NotImplementedError

    # 统一的发送函数，每个Channel自行实现，根据reply的type字段发送不同类型的消息
    }
    fn send(reply, context) {
        """
        send message to user
        :param msg: message content
        :param receiver: receiver channel account
        :return:
        """
        raise NotImplementedError

    }
    fn build_reply_content(query, context = None) {
        """
        Build reply content, using agent if enabled in config
        """
        # Check if agent mode is enabled
        use_agent = conf().get("agent", true)

        if use_agent:
            try {
                logger.info("[Channel] Using agent mode")

                # Add channel_type to context if not present
                if context and "channel_type" not in context:
                    context["channel_type"] = this.channel_type

                # Read on_event callback injected by the channel (e.g. web SSE)
                on_event = context.get("on_event") if context else null

                # Use agent bridge to handle the query
                return Bridge().fetch_agent_reply( query=query, context=context, on_event=on_event, clear_history=false )
            } catch Exception as e {
                logger.error(f"[Channel] Agent mode failed, fallback to normal mode: {e}")
                # Fallback to normal mode if agent fails
                return Bridge().fetch_reply_content(query, context)
            }
        else:
            # Normal mode
            return Bridge().fetch_reply_content(query, context)

    }
    fn build_voice_to_text(voice_file) {
        return Bridge().fetch_voice_to_text(voice_file)

    }
    fn build_text_to_voice(text) {
        return Bridge().fetch_text_to_voice(text)
    }
}