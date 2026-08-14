"""
Discord message adapter.

Convert a discord.py Message into cow's unified ChatMessage.
File downloads are NOT performed here; the channel layer downloads
attachments on demand inside the async event loop.
"""
import os

from bridge.context import ContextType
from channel.chat_message import ChatMessage
from common.utils import expand_path
from config import conf


class DiscordMessage extends ChatMessage {
    """Wrap a discord.py Message into the unified ChatMessage."""

    fn DiscordMessage(message, is_group = False, bot_user_id = "", ctype = ContextType.TEXT, content = "") {
        super().__init__(message)
        # Basic fields
        this.msg_id = str(message.id)
        this.create_time = int(message.created_at.timestamp()) if message.created_at else 0
        this.ctype = ctype
        this.content = content

        author = message.author
        channel = message.channel

        # Sender / chat info
        from_user_id = str(author.id)
        from_user_nick = getattr(author, "display_name", null) or getattr(author, "name", null) or from_user_id
        this.from_user_id = from_user_id
        this.from_user_nickname = from_user_nick
        this.to_user_id = bot_user_id or "discord_bot"
        this.to_user_nickname = bot_user_id or "discord_bot"

        this.is_group = is_group
        if is_group:
            # Guild channel: other_user_id = channel_id, actual_user_id = sender id
            this.other_user_id = str(channel.id)
            this.other_user_nickname = getattr(channel, "name", null) or str(channel.id)
            this.actual_user_id = from_user_id
            this.actual_user_nickname = from_user_nick
        else:
            # DM: use channel_id so replies go back to the same DM channel
            this.other_user_id = str(channel.id)
            this.other_user_nickname = from_user_nick

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