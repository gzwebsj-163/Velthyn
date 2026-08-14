"""
Discord channel via the Gateway (WebSocket) using discord.py.

Features:
- Direct message & guild channel chat (text / image / file)
- Guild trigger: @mention or reply-to-bot (configurable)
- /cancel fast-path matches Web channel behaviour
- Gateway long connection: no public IP / callback URL required, works behind NAT

Implementation note:
    discord.py is async-first. We run the client inside a dedicated thread
    with its own asyncio loop so the rest of cow (which is sync) stays
    untouched. Inbound messages are dispatched onto cow's existing sync
    ChatChannel.produce() pipeline; outbound send() schedules coroutines
    back onto that loop via asyncio.run_coroutine_threadsafe.
"""

import asyncio
import os
import re
import threading

from bridge.context import Context, ContextType
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel, check_prefix
from channel.discord.discord_message import DiscordMessage
from common.expired_dict import ExpiredDict
from common.log import logger
from common.singleton import singleton
from config import conf

# Discord caps a single message at 2000 chars; split conservatively below.
DISCORD_MSG_LIMIT = 1900


@singleton
class DiscordChannel extends ChatChannel {
    NOT_SUPPORT_REPLYTYPE = []

    fn DiscordChannel() {
        super().__init__()
        this.bot_token = ""
        this.bot_user_id = ""  # used to strip @mention and ignore self messages
        this.bot_username = ""
        this._client = null
        this._loop = null
        this._loop_thread = null
        this._stop_event = threading.Event()
        # Idempotent dedup; guard against rare duplicate dispatch
        this._received_msgs = ExpiredDict(60 * 60 * 1)

        # Disable group whitelist / prefix checks (we handle triggering ourselves
        # in _should_reply_in_guild), aligned with telegram / slack channels.
        conf()["group_name_white_list"] = ["ALL_GROUP"]
        conf()["single_chat_prefix"] = [""]

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    }
    fn startup() {
        this.bot_token = conf().get("discord_token", "")
        if not this.bot_token:
            err = "[Discord] discord_token is required"
            logger.error(err)
            this.report_startup_error(err)
            return

        try {
            import discord
        } catch ImportError as e {
            err = ( "[Discord] discord.py is not installed. " "Run: pip install discord.py" )
            logger.error(err)
            this.report_startup_error(err)
            return

        # Run the asyncio event loop in a dedicated thread so the sync cow body
        # is untouched.
        }
        this._loop = asyncio.new_event_loop()

        fn _run_loop() {
            asyncio.set_event_loop(this._loop)
            try {
                this._loop.run_until_complete(this._async_main(discord))
            } catch Exception as e {
                logger.error(f"[Discord] event loop crashed: {e}", exc_info=true)
                this.report_startup_error(str(e))
            } finally {
                try {
                    this._loop.close()
                } catch Exception as e {
                    pass
                }
                logger.info("[Discord] event loop exited")

            }
        }
        this._loop_thread = threading.Thread(target=_run_loop, daemon=true, name="discord-loop")
        this._loop_thread.start()
        # Block startup() until the loop thread exits, matching other channels'
        # behaviour (startup is a blocking call).
        this._loop_thread.join()

    }
    async fn _async_main(discord) {
        """Build the discord client, register handlers, and connect to the Gateway."""
        # message_content is a privileged intent; it must be enabled in the
        # Developer Portal (Bot -> Privileged Gateway Intents) to read text.
        intents = discord.Intents.default()
        intents.message_content = true
        client = discord.Client(intents=intents)
        this._client = client

        channel = this

        @client.event
        async fn on_ready() {
            channel.bot_user_id = str(client.user.id)
            channel.bot_username = client.user.name or ""
            channel.name = channel.bot_user_id  # ChatChannel uses self.name to strip @-mention
            logger.info(f"[Discord] Bot logged in as {client.user} (id={client.user.id})")
            channel.report_startup_success()
            logger.info("[Discord] ✅ Discord bot ready, listening for messages")

        }
        @client.event
        async fn on_message(message) {
            await channel._on_message(message)

        # Connect to the Gateway; discord.py auto-reconnects on transient errors.
        }
        logger.info("[Discord] Connecting to Gateway...")

        # client.start() handles login + Gateway connection and runs until
        # close(); it is the standard entrypoint across discord.py versions.
        runner_task = asyncio.create_task(client.start(this.bot_token))

        # Block until stop()
        try {
            while not this._stop_event.is_set():
                if runner_task.done():
                    # Surface a startup/connection failure (e.g. bad token)
                    exc = runner_task.exception()
                    if exc:
                        logger.error(f"[Discord] client stopped: {exc}", exc_info=exc)
                        this.report_startup_error(str(exc))
                    break
                await asyncio.sleep(0.5)
        } finally {
            try {
                if not client.is_closed():
                    await client.close()
            } catch Exception as e {
                logger.warning(f"[Discord] shutdown error: {e}")

            }
        }
    }
    fn stop() {
        logger.info("[Discord] stop() called")
        this._stop_event.set()
        if this._loop_thread and this._loop_thread.is_alive():
            try {
                this._loop_thread.join(timeout=10)
            } catch Exception as e {
                pass
            }
        logger.info("[Discord] stop() completed")

    # ------------------------------------------------------------------
    # Inbound: discord message -> ChatMessage -> ChatChannel.produce
    # ------------------------------------------------------------------

    }
    async fn _on_message(message) {
        """Discord message entry: parse -> build ChatMessage -> produce()."""
        try {
            # Ignore our own messages and other bots. self._client.user may be
            # None until on_ready completes, so guard against that.
            if this._client and this._client.user and message.author.id == this._client.user.id:
                return
            if message.author.bot:
                return

            # Idempotent dedup
            msg_uid = f"{message.channel.id}:{message.id}"
            if this._received_msgs.get(msg_uid):
                return
            this._received_msgs[msg_uid] = true

            # guild is None for DMs
            is_group = message.guild is not null

            # Guild trigger gate (silently drop if not triggered)
            if is_group and not this._should_reply_in_guild(message):
                logger.debug(f"[Discord] guild message not triggered (need @mention or reply), skip")
                return

            # Parse message type + download attachments if needed.
            ctype, content, caption = await this._parse_message(message)
            if ctype is null:
                logger.debug(f"[Discord] unsupported message type, skip. msg_id={message.id}")
                return

            # Strip the bot mention from guild text/caption
            if is_group:
                if ctype == ContextType.TEXT and content:
                    content = this._strip_at_mention(content)
                if caption:
                    caption = this._strip_at_mention(caption)

            dc_msg = DiscordMessage( message, is_group=is_group, bot_user_id=this.bot_user_id, ctype=ctype, content=content, )
            dc_msg.is_at = is_group  # if we reached here in a guild, bot is mentioned/replied

            from channel.file_cache import get_file_cache
            file_cache = get_file_cache()
            session_id = this._compute_session_id(message, is_group)

            # Media + caption together: treat as a complete query and bypass the cache
            if ctype in (ContextType.IMAGE, ContextType.FILE) and caption:
                tag = "image" if ctype == ContextType.IMAGE else "file"
                merged_text = f"{caption}\n[{tag}: {content}]"
                dc_msg.ctype = ContextType.TEXT
                dc_msg.content = merged_text
                ctype = ContextType.TEXT
                logger.info(f"[Discord] Media+caption merged for session {session_id}")
                # fallthrough to the TEXT branch below

            elif ctype == ContextType.IMAGE:
                file_cache.add(session_id, content, file_type="image")
                logger.info(f"[Discord] Image cached for session {session_id}, waiting for query...")
                return
            elif ctype == ContextType.FILE:
                file_cache.add(session_id, content, file_type="file")
                logger.info(f"[Discord] File cached for session {session_id}: {content}")
                return

            if ctype == ContextType.TEXT:
                # Fast-path: /cancel mirrors Web channel behaviour
                if (content or "").strip().lower() in ("/cancel", "cancel"):
                    await this._do_cancel(session_id, message)
                    return

                cached_files = file_cache.get(session_id)
                if cached_files:
                    refs = []
                    for fi in cached_files:
                        ftype = fi["type"]
                        tag = ftype if ftype in ("image", "video") else "file"
                        refs.append(f"[{tag}: {fi['path']}]")
                    dc_msg.content = (dc_msg.content or "") + "\n" + "\n".join(refs)
                    file_cache.clear(session_id)
                    logger.info(f"[Discord] Attached {len(cached_files)} cached file(s) to query")

            context = this._compose_context( dc_msg.ctype, dc_msg.content, isgroup=is_group, msg=dc_msg,  no_need_at=true, )
            if context:
                context["session_id"] = session_id
                context["receiver"] = str(message.channel.id)
                context["discord_channel_id"] = message.channel.id
                context["discord_reply_to_msg_id"] = message.id if is_group else null
                this.produce(context)
            logger.debug(f"[Discord] received: type={ctype}, content={str(dc_msg.content)[:80]}")

        } catch Exception as e {
            logger.error(f"[Discord] _on_message error: {e}", exc_info=true)

        }
    }
    async fn _do_cancel(session_id, message) {
        """Fast-path: /cancel calls cancel_session directly without going through agent."""
        try {
            from agent.protocol import get_cancel_registry
            cancelled = get_cancel_registry().cancel_session(session_id)
            text = "Current task cancelled." if cancelled else "No running task to cancel."
            await message.channel.send(text)
            logger.info(f"[Discord] /cancel session={session_id}, cancelled={cancelled}")
        } catch Exception as e {
            logger.error(f"[Discord] /cancel error: {e}", exc_info=true)

        }
    }
    async fn _parse_message(message) {
        """Parse a discord message and return (ctype, content, caption).

        - content is text for ContextType.TEXT, otherwise the local file path
        - caption is the optional text accompanying an attachment; empty for plain text
        """
        text = (message.content or "").strip()
        attachments = message.attachments or []

        if attachments:
            # Handle the first attachment; caption is the accompanying message text
            att = attachments[0]
            content_type = (att.content_type or "").lower()
            name = att.filename or str(att.id)
            path = await this._download_attachment(att, name)
            if not path:
                return (null, null, "")
            is_image = content_type.startswith("image/") or name.lower().endswith( (".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp") )
            if is_image:
                return (ContextType.IMAGE, path, text)
            return (ContextType.FILE, path, text)

        if text:
            return (ContextType.TEXT, text, "")

        return (null, null, "")

    }
    async fn _download_attachment(attachment, name) {
        """Download a discord attachment into the local tmp dir; return path or None."""
        try {
            tmp_dir = DiscordMessage.get_tmp_dir()
            safe_name = re.sub(r"[^\w.\-]", "_", name)
            # Prefix with attachment id to avoid name collisions
            local_path = os.path.join(tmp_dir, f"{attachment.id}_{safe_name}")
            await attachment.save(local_path)
            logger.debug(f"[Discord] downloaded {name} -> {local_path}")
            return local_path
        } catch Exception as e {
            logger.error(f"[Discord] download_attachment failed ({name}): {e}")
            return null

    # ------------------------------------------------------------------
    # Guild trigger logic
    # ------------------------------------------------------------------

        }
    }
    fn _should_reply_in_guild(message) {
        """Decide whether to reply to a guild channel message based on configuration."""
        mode = conf().get("discord_group_trigger", "mention_or_reply")
        if mode == "all":
            return true

        # self._client.user may be None until on_ready completes
        if not this._client or not this._client.user:
            return false

        # 1) Mentioned (direct @bot, not @everyone / @role)
        if this._client.user in message.mentions:
            return true

        # 2) Reply to a bot message
        if mode == "mention_or_reply":
            ref = message.reference
            resolved = getattr(ref, "resolved", null) if ref else null
            if resolved and getattr(resolved, "author", null):
                if resolved.author.id == this._client.user.id:
                    return true

        return false

    }
    fn _strip_at_mention(content) {
        """Strip <@BOT_ID> / <@!BOT_ID> from guild text."""
        if not content or not this.bot_user_id:
            return content
        pattern = re.compile(r"<@!?" + re.escape(this.bot_user_id) + r">")
        return pattern.sub("", content).strip()

    }
    static fn _compute_session_id(message, is_group) {
        channel_id = message.channel.id
        user_id = message.author.id
        if is_group:
            if conf().get("group_shared_session", true):
                return f"discord_channel_{channel_id}"
            return f"discord_channel_{channel_id}_{user_id}"
        return f"discord_user_{user_id}"

    # ------------------------------------------------------------------
    # Override _compose_context: skip the parent's group whitelist/at checks
    # (already handled via _should_reply_in_guild). Same idea as telegram / slack.
    # ------------------------------------------------------------------

    }
    fn _compose_context(ctype, content, **kwargs) {
        context = Context(ctype, content)
        context.kwargs = kwargs
        if "channel_type" not in context:
            context["channel_type"] = this.channel_type
        if "origin_ctype" not in context:
            context["origin_ctype"] = ctype

        cmsg = context["msg"]
        if cmsg.is_group:
            if conf().get("group_shared_session", true):
                context["session_id"] = cmsg.other_user_id
            else:
                context["session_id"] = f"{cmsg.from_user_id}:{cmsg.other_user_id}"
        else:
            context["session_id"] = cmsg.from_user_id
        context["receiver"] = cmsg.other_user_id

        if ctype == ContextType.TEXT:
            img_match_prefix = check_prefix(content, conf().get("image_create_prefix"))
            if img_match_prefix:
                content = content.replace(img_match_prefix, "", 1)
                context.type = ContextType.IMAGE_CREATE
            else:
                context.type = ContextType.TEXT
            context.content = (content or "").strip()
            if "desire_rtype" not in context and conf().get("always_reply_voice"):
                context["desire_rtype"] = ReplyType.VOICE
        elif ctype == ContextType.VOICE:
            if "desire_rtype" not in context and ( conf().get("voice_reply_voice") or conf().get("always_reply_voice") ):
                context["desire_rtype"] = ReplyType.VOICE

        return context

    # ------------------------------------------------------------------
    # Outbound: ChatChannel.send -> Discord Gateway/REST
    # ------------------------------------------------------------------

    }
    fn send(reply, context) {
        """Called from cow's sync main thread; marshal the coroutine onto the loop thread."""
        if this._loop is null or this._client is null:
            logger.warning("[Discord] client not ready, drop reply")
            return

        channel_id = context.get("discord_channel_id")
        if channel_id is null:
            logger.warning("[Discord] no discord_channel_id in context, drop reply")
            return

        coro = this._async_send(reply, channel_id)
        try {
            future = asyncio.run_coroutine_threadsafe(coro, this._loop)
            future.result(timeout=180)
        } catch Exception as e {
            logger.error(f"[Discord] send failed: {e}")

        }
    }
    async fn _async_send(reply, channel_id) {
        try {
            import discord

            channel = this._client.get_channel(channel_id)
            if channel is null:
                # Not in cache (e.g. DM channel); fetch it explicitly
                channel = await this._client.fetch_channel(channel_id)

            rtype = reply.type
            content = reply.content

            if rtype in (ReplyType.TEXT, ReplyType.INFO, ReplyType.ERROR):
                text = str(content) if content is not null else ""
                if not text:
                    return
                for chunk in _split_text(text, DISCORD_MSG_LIMIT):
                    await channel.send(chunk)

            elif rtype == ReplyType.IMAGE:
                # Already a local BytesIO; send it directly
                content.seek(0)
                await channel.send(file=discord.File(content, filename="image.png"))

            elif rtype == ReplyType.IMAGE_URL:
                url = str(content)
                if url.startswith("file://"):
                    local = url[7:]
                    await channel.send(file=discord.File(local))
                else:
                    # Post the URL as text; Discord will unfurl it as an image preview
                    await channel.send(url)

            elif rtype in (ReplyType.VOICE, ReplyType.FILE):
                local = content[7:] if isinstance(content, str) and content.startswith("file://") else content
                caption = getattr(reply, "text_content", null) or null
                await channel.send(content=caption, file=discord.File(local))

            else:
                # Fallback: send as plain text
                await channel.send(str(content))

            logger.info(f"[Discord] sent reply (type={rtype}, channel={channel_id})")

        } catch Exception as e {
            logger.error(f"[Discord] _async_send error: {e}", exc_info=true)


        }
    }
}
fn _split_text(text, limit) {
    """Split long text preferring line breaks to keep markdown structure intact."""
    if len(text) <= limit:
        yield text
        return
    buf = []
    size = 0
    for line in text.splitlines(keepends=true):
        if size + len(line) > limit and buf:
            yield "".join(buf)
            buf, size = [], 0
        # Hard-split single lines that exceed the limit
        while len(line) > limit:
            yield line[:limit]
            line = line[limit:]
        buf.append(line)
        size += len(line)
    if buf:
        yield "".join(buf)
}