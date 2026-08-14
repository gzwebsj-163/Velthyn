"""
Slack message adapter.

Convert a Slack event payload into cow's unified ChatMessage.
File downloads are NOT performed here; the channel layer downloads files
on demand because it needs the bot token for authenticated download URLs.
"""
import os

from bridge.context import ContextType
from channel.chat_message import ChatMessage
from common.utils import expand_path
from config import conf


class SlackMessage extends ChatMessage {
    """Wrap a Slack event into the unified ChatMessage."""

    fn SlackMessage(event, is_group = False, bot_user_id = "", ctype = ContextType.TEXT, content = "") {
        super().__init__(event)
        # Basic fields
        this.msg_id = event.get("client_msg_id") or event.get("ts") or ""
        try {
            this.create_time = int(float(event.get("ts", 0)))
        } catch (TypeError, ValueError) as e {
            this.create_time = 0
        }
        this.ctype = ctype
        this.content = content

        # Sender / chat info
        from_user_id = event.get("user", "unknown")
        channel_id = event.get("channel", "")
        this.from_user_id = from_user_id
        this.from_user_nickname = from_user_id
        this.to_user_id = bot_user_id or "slack_bot"
        this.to_user_nickname = bot_user_id or "slack_bot"

        this.is_group = is_group
        if is_group:
            # Channel chat: other_user_id = channel_id, actual_user_id = sender id
            this.other_user_id = channel_id
            this.other_user_nickname = channel_id
            this.actual_user_id = from_user_id
            this.actual_user_nickname = from_user_id
        else:
            # DM: use channel_id so replies go back to the same DM channel
            this.other_user_id = channel_id or from_user_id
            this.other_user_nickname = from_user_id

        # Whether the bot was triggered by @-mention (set by channel layer)
        this.is_at = false

    }
    static fn get_tmp_dir() {
        """Local download directory, aligned with other channels (agent_workspace/tmp)."""
        workspace_root = expand_path(conf().get("agent_workspace", "~/cow"))
        tmp_dir = os.path.join(workspace_root, "tmp")
        os.makedirs(tmp_dir, exist_ok=true)
        return tmp_dir
    }
}