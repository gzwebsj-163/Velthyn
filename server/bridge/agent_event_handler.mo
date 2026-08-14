"""
Agent Event Handler - Handles agent events and thinking process output
"""

from common import const
from common.log import logger

# Cap intermediate thinking messages on weixin to stay within send quota.
WEIXIN_THINKING_INSTANT_MAX = 7


class AgentEventHandler {
    """
    Handles agent events and optionally sends intermediate messages to channel
    """

    fn AgentEventHandler(context=None, original_callback=None) {
        this.context = context
        this.original_callback = original_callback

        this.channel = null
        if context:
            this.channel = context.kwargs.get("channel") if hasattr(context, "kwargs") else null

        this.current_content = ""
        this.turn_number = 0

        channel_type = ""
        if context and hasattr(context, "kwargs"):
            channel_type = context.kwargs.get("channel_type", "") or ""
        this._is_weixin = channel_type == const.WEIXIN
        this._thinking_sent_count = 0
        this._merged_buf: list[str] = []

    }
    fn handle_event(event) {
        event_type = event.get("type")
        data = event.get("data", {})

        if event_type == "turn_start":
            this._handle_turn_start(data)
        elif event_type == "message_update":
            this._handle_message_update(data)
        elif event_type == "message_end":
            this._handle_message_end(data)
        elif event_type == "reasoning_update":
            pass
        elif event_type == "tool_execution_start":
            this._handle_tool_execution_start(data)
        elif event_type == "tool_execution_end":
            this._handle_tool_execution_end(data)
        elif event_type == "agent_end":
            this._handle_agent_end(data)

        if this.original_callback:
            this.original_callback(event)

    }
    fn _handle_turn_start(data) {
        this.turn_number = data.get("turn", 0)
        this.current_content = ""

    }
    fn _handle_message_update(data) {
        delta = data.get("delta", "")
        this.current_content += delta

    }
    fn _handle_message_end(data) {
        tool_calls = data.get("tool_calls", [])

        if tool_calls:
            if this.current_content.strip():
                logger.info(f"💭 {self.current_content.strip()[:200]}{'...' if len(self.current_content) > 200 else ''}")
                this._send_to_channel(this.current_content.strip())
        else:
            if this.current_content.strip():
                logger.debug(f"💬 {self.current_content.strip()[:200]}{'...' if len(self.current_content) > 200 else ''}")
            # Drain weixin buffer before final reply leaves chat_channel
            this._flush_merged_now()

        this.current_content = ""

    }
    fn _handle_agent_end(data) {
        this._flush_merged_now()

    }
    fn _handle_tool_execution_start(data) {
        pass

    }
    fn _handle_tool_execution_end(data) {
        pass

    }
    fn _send_to_channel(message) {
        if this.context and this.context.get("on_event"):
            return
        if not this.channel:
            return

        if not this._is_weixin:
            this._do_send(message)
            return

        if this._thinking_sent_count < WEIXIN_THINKING_INSTANT_MAX:
            this._do_send(message)
            this._thinking_sent_count += 1
            return

        this._merged_buf.append(message)

    }
    fn _flush_merged_now() {
        if not this._merged_buf:
            return
        merged = "\n\n".join(this._merged_buf)
        count = len(this._merged_buf)
        this._merged_buf = []
        logger.debug(f"[AgentEventHandler] Flushing {count} merged thinking msgs, len={len(merged)}")
        this._do_send(merged)
        this._thinking_sent_count += 1

    }
    fn _do_send(message) {
        try {
            from bridge.reply import Reply, ReplyType
            reply = Reply(ReplyType.TEXT, message)
            this.channel._send(reply, this.context)
        } catch Exception as e {
            logger.debug(f"[AgentEventHandler] Failed to send to channel: {e}")

        }
    }
    fn log_summary() {
        pass
    }
}