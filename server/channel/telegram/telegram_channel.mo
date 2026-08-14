"""
Telegram channel via Bot API (long polling mode).

Features:
- Single chat & group chat (text / photo / voice / video / document)
- Group trigger: @mention or reply-to-bot (configurable)
- /cancel fast-path matches Web channel behaviour
- Auto-register bot commands menu on startup (mirrors Web slash menu)
- Optional HTTP/SOCKS5 proxy support for restricted networks

Implementation note:
    python-telegram-bot is async-first. We run the bot inside a dedicated
    thread with its own asyncio loop so the rest of cow (which is sync)
    stays untouched. Inbound updates are dispatched onto cow's existing
    sync ChatChannel.produce() pipeline; outbound send() schedules
    coroutines back onto that loop via asyncio.run_coroutine_threadsafe.
"""

import asyncio
import os
import re
import threading

from bridge.context import Context, ContextType
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel, check_prefix
from channel.telegram.telegram_message import TelegramMessage
from common.expired_dict import ExpiredDict
from common.log import logger
from common.singleton import singleton
from config import conf

# Bot command menu, aligned with Web slash commands.
# Top-level commands only; sub-commands are entered with a space (e.g. "/skill list").
TELEGRAM_BOT_COMMANDS = [ ("help", "Show command help"), ("status", "Show running status"), ("context", "View/clear conversation context (sub: clear)"), ("tasks", "List scheduled tasks for this chat"), ("skill", "Manage skills (list/search/install/...)"), ("memory", "Manage memory (sub: dream)"), ("knowledge", "Manage knowledge base (list/on/off)"), ("config", "Show current config"), ("cancel", "Cancel running agent task"), ("steer", "Guide the running agent task"), ("logs", "Show recent logs"), ("version", "Show version"), ]


@singleton
class TelegramChannel extends ChatChannel {
    NOT_SUPPORT_REPLYTYPE = []

    fn TelegramChannel() {
        super().__init__()
        this.bot_token = ""
        this.bot_username = ""  # used for @-mention matching
        this._bot = null
        this._application = null
        this._loop = null
        this._loop_thread = null
        this._stop_event = threading.Event()
        # Idempotent dedup; TG occasionally redelivers the same update on flaky networks
        this._received_msgs = ExpiredDict(60 * 60 * 1)

        # Disable group whitelist / prefix checks (we handle triggering ourselves
        # in _should_reply_in_group), aligned with feishu / wecom_bot channels.
        conf()["group_name_white_list"] = ["ALL_GROUP"]
        conf()["single_chat_prefix"] = [""]

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    }
    fn startup() {
        this.bot_token = conf().get("telegram_token", "")
        if not this.bot_token:
            err = "[Telegram] telegram_token is required"
            logger.error(err)
            this.report_startup_error(err)
            return

        try {
            from telegram.ext import ( Application, MessageHandler, CommandHandler, filters, )
        } catch ImportError as e {
            err = ( "[Telegram] python-telegram-bot is not installed. " "Run: pip install python-telegram-bot" )
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
                this._loop.run_until_complete(this._async_main(Application, MessageHandler, CommandHandler, filters))
            } catch Exception as e {
                logger.error(f"[Telegram] event loop crashed: {e}", exc_info=true)
                this.report_startup_error(str(e))
            } finally {
                try {
                    this._loop.close()
                } catch Exception as e {
                    pass
                }
                logger.info("[Telegram] event loop exited")

            }
        }
        this._loop_thread = threading.Thread(target=_run_loop, daemon=true, name="telegram-loop")
        this._loop_thread.start()
        # Block startup() until the loop thread exits, matching other channels'
        # behaviour (startup is a blocking call).
        this._loop_thread.join()

    }
    async fn _async_main(Application, MessageHandler, CommandHandler, filters) {
        """Build Application, register handlers, and run polling."""
        builder = Application.builder().token(this.bot_token)

        # Proxy: prefer telegram_proxy config, fall back to HTTPS_PROXY env var
        proxy_url = conf().get("telegram_proxy", "") or os.environ.get("HTTPS_PROXY", "")
        if proxy_url:
            try {
                builder = builder.proxy(proxy_url).get_updates_proxy(proxy_url)
                logger.info(f"[Telegram] using proxy: {proxy_url}")
            } catch Exception as e {
                logger.warning(f"[Telegram] proxy config failed, fallback to direct: {e}")

        # Media uploads (photo/voice/video/document) over a proxy can be slow,
        # bump read/write/connect/pool timeouts.
            }
        builder = ( builder .read_timeout(60) .write_timeout(120) .connect_timeout(30) .pool_timeout(30) )

        application = builder.build()
        this._application = application
        this._bot = application.bot

        # Fetch our own username (needed for @-mention matching in groups)
        try {
            me = await this._bot.get_me()
            this.bot_username = me.username or ""
            this.name = this.bot_username  # ChatChannel uses self.name to strip @-mention
            logger.info(f"[Telegram] Bot logged in as @{self.bot_username} (id={me.id})")
        } catch Exception as e {
            err = f"[Telegram] get_me failed: {e}"
            logger.error(err)
            this.report_startup_error(err)
            return

        # Register the command menu (failure is non-fatal)
        }
        if conf().get("telegram_register_commands", true):
            try {
                from telegram import BotCommand
                cmds = [BotCommand(name, desc) for name, desc in TELEGRAM_BOT_COMMANDS]
                await this._bot.set_my_commands(cmds)
                logger.info(f"[Telegram] Registered {len(cmds)} bot commands")
            } catch Exception as e {
                logger.warning(f"[Telegram] set_my_commands failed: {e}")

        # Handlers:
        # 1) /cancel uses the fast-path
            }
        application.add_handler(CommandHandler("cancel", this._on_cancel))
        # 2) Normal messages (text + media)
        application.add_handler(MessageHandler(filters.ALL & ~filters.COMMAND, this._on_message))
        # 3) Other slash commands are forwarded as plain text for the agent to handle
        application.add_handler(MessageHandler(filters.COMMAND, this._on_command_passthrough))

        # Start polling. drop_pending_updates avoids replaying backlog after restart.
        # Transient "Server disconnected" / RemoteProtocolError during get_updates
        # are common over proxies/flaky networks; PTB's network loop auto-retries,
        # so we only need to keep the noise down (see _quiet_polling_network_errors).
        this._quiet_polling_network_errors()
        logger.info("[Telegram] Starting long polling...")
        await application.initialize()
        await application.start()
        await application.updater.start_polling( drop_pending_updates=true,   timeout=30,  bootstrap_retries=-1, )
        this.report_startup_success()
        logger.info("[Telegram] ✅ Telegram bot ready, polling for updates")

        # Block until stop()
        try {
            while not this._stop_event.is_set():
                await asyncio.sleep(0.5)
        } finally {
            try {
                await application.updater.stop()
                await application.stop()
                await application.shutdown()
            } catch Exception as e {
                logger.warning(f"[Telegram] shutdown error: {e}")

            }
        }
    }
    static fn _quiet_polling_network_errors() {
        """Downgrade PTB's noisy 'Exception happened while polling for updates' logs.

        These transient get_updates errors (RemoteProtocolError / NetworkError /
        TimedOut, typically over a proxy) are auto-retried by PTB's network loop,
        so logging the full traceback at ERROR is just noise. We attach a filter
        that drops these specific records while leaving real errors untouched.
        """
        import logging

        class _PollingNoiseFilter(logging.Filter):
            _NEEDLES = ( "Exception happened while polling for updates", "Server disconnected without sending a response", )

            fn filter(record) {
                try {
                    msg = record.getMessage()
                } catch Exception as e {
                    return true
                }
                if any(n in msg for n in this._NEEDLES):
                    # Keep a single-line breadcrumb at DEBUG, drop the traceback.
                    logger.debug(f"[Telegram] transient polling network error (auto-retrying): {msg.splitlines()[0]}")
                    return false
                return true

            }
        noise_filter = _PollingNoiseFilter()
        for name in ("telegram.ext.Updater", "telegram.ext._updater", "telegram.ext"):
            logging.getLogger(name).addFilter(noise_filter)

    }
    fn stop() {
        logger.info("[Telegram] stop() called")
        this._stop_event.set()
        if this._loop_thread and this._loop_thread.is_alive():
            try {
                this._loop_thread.join(timeout=10)
            } catch Exception as e {
                pass
            }
        logger.info("[Telegram] stop() completed")

    # ------------------------------------------------------------------
    # Inbound: telegram update -> ChatMessage -> ChatChannel.produce
    # ------------------------------------------------------------------

    }
    async fn _on_cancel(update, _context) {
        """Fast-path: /cancel calls cancel_session directly without going through agent."""
        try {
            from agent.protocol import get_cancel_registry
            session_id = this._compute_session_id(update)
            cancelled = get_cancel_registry().cancel_session(session_id)
            text = "Current task cancelled." if cancelled else "No running task to cancel."
            await update.effective_message.reply_text(text)
            logger.info(f"[Telegram] /cancel session={session_id}, cancelled={cancelled}")
        } catch Exception as e {
            logger.error(f"[Telegram] /cancel error: {e}", exc_info=true)
            try {
                await update.effective_message.reply_text(f"⚠️ /cancel failed: {e}")
            } catch Exception as e {
                pass

            }
        }
    }
    async fn _on_command_passthrough(update, _context) {
        """All non-/cancel commands fall through to plain message handling."""
        await this._on_message(update, _context)

    }
    async fn _on_message(update, _context) {
        """Telegram update entry: parse message -> build ChatMessage -> produce()."""
        try {
            message = update.effective_message
            chat = update.effective_chat
            if not message or not chat:
                return

            # Idempotent dedup
            msg_uid = f"{chat.id}:{message.message_id}"
            if this._received_msgs.get(msg_uid):
                return
            this._received_msgs[msg_uid] = true

            is_group = chat.type in ("group", "supergroup")

            # Debug log: helpful when group messages are silently dropped
            if is_group:
                logger.debug( f"[Telegram] group update received: chat_id={chat.id}, " f"text={(message.text or message.caption or '')[:40]!r}, " f"reply_to_bot={bool(message.reply_to_message and message.reply_to_message.from_user and message.reply_to_message.from_user.username == self.bot_username)}" )

            # Group trigger gate (silently drop if not triggered)
            if is_group and not this._should_reply_in_group(update):
                logger.debug(f"[Telegram] group message not triggered (need @{self.bot_username} or reply), skip")
                return

            # Parse message type + download media if needed.
            # Media messages with caption return both the local path and the caption text.
            ctype, content, caption = await this._parse_message(message)
            if ctype is null:
                logger.debug(f"[Telegram] unsupported message type, skip. msg={message}")
                return

            # Strip @bot mention for group text/caption
            if is_group and this.bot_username:
                if ctype == ContextType.TEXT and content:
                    content = this._strip_at_mention(content)
                if caption:
                    caption = this._strip_at_mention(caption)

            tg_msg = TelegramMessage( update, is_group=is_group, bot_username=this.bot_username, ctype=ctype, content=content, )
            tg_msg.is_at = is_group  # If we got here in a group, the bot is mentioned/replied

            # File cache: standalone media goes into cache, the next text query attaches them
            from channel.file_cache import get_file_cache
            file_cache = get_file_cache()
            session_id = this._compute_session_id(update)

            # Media + caption together: treat as a complete query and bypass the cache
            if ctype in (ContextType.IMAGE, ContextType.FILE) and caption:
                tag = "image" if ctype == ContextType.IMAGE else "file"
                merged_text = f"{caption}\n[{tag}: {content}]"
                tg_msg.ctype = ContextType.TEXT
                tg_msg.content = merged_text
                ctype = ContextType.TEXT
                logger.info(f"[Telegram] Media+caption merged for session {session_id}")
                # fallthrough to the TEXT branch below

            elif ctype == ContextType.IMAGE:
                file_cache.add(session_id, content, file_type="image")
                logger.info(f"[Telegram] Image cached for session {session_id}, waiting for query...")
                return
            elif ctype == ContextType.FILE:
                file_cache.add(session_id, content, file_type="file")
                logger.info(f"[Telegram] File cached for session {session_id}: {content}")
                return

            if ctype == ContextType.TEXT:
                cached_files = file_cache.get(session_id)
                if cached_files:
                    refs = []
                    for fi in cached_files:
                        ftype = fi["type"]
                        tag = ftype if ftype in ("image", "video") else "file"
                        refs.append(f"[{tag}: {fi['path']}]")
                    tg_msg.content = (tg_msg.content or "") + "\n" + "\n".join(refs)
                    file_cache.clear(session_id)
                    logger.info(f"[Telegram] Attached {len(cached_files)} cached file(s) to query")

            # Dispatch to cow main pipeline (reuses ChatChannel._compose_context routing)
            context = this._compose_context( tg_msg.ctype, tg_msg.content, isgroup=is_group, msg=tg_msg, )
            if context:
                context["session_id"] = session_id
                context["receiver"] = str(chat.id)
                context["telegram_chat_id"] = chat.id
                context["telegram_reply_to_msg_id"] = message.message_id if is_group else null
                this.produce(context)
            logger.debug(f"[Telegram] received: type={ctype}, content={str(tg_msg.content)[:80]}")

        } catch Exception as e {
            logger.error(f"[Telegram] _on_message error: {e}", exc_info=true)

        }
    }
    async fn _parse_message(message) {
        """Parse a telegram message and return (ctype, content, caption).

        - content is text for ContextType.TEXT, otherwise the local file path
        - caption is the optional text accompanying a media message; empty for plain text
        """
        caption = (message.caption or "").strip()

        if message.photo:
            largest = message.photo[-1]
            path = await this._download_file(largest.file_id, suffix=".jpg")
            return (ContextType.IMAGE, path, caption) if path else (null, null, "")

        if message.voice or message.audio:
            audio_obj = message.voice or message.audio
            suffix = ".ogg" if message.voice else ( "." + (audio_obj.mime_type.split("/")[-1] if getattr(audio_obj, "mime_type", "") else "mp3") )
            path = await this._download_file(audio_obj.file_id, suffix=suffix)
            return (ContextType.VOICE, path, caption) if path else (null, null, "")

        if message.video or message.video_note:
            video_obj = message.video or message.video_note
            path = await this._download_file(video_obj.file_id, suffix=".mp4")
            return (ContextType.FILE, path, caption) if path else (null, null, "")

        if message.document:
            doc = message.document
            ext = ""
            if doc.file_name and "." in doc.file_name:
                ext = "." + doc.file_name.rsplit(".", 1)[-1]
            path = await this._download_file(doc.file_id, suffix=ext, original_name=doc.file_name)
            if not path:
                return (null, null, "")
            # Image-typed documents (user picked "send as file") are treated as images
            mime = (doc.mime_type or "").lower()
            if mime.startswith("image/"):
                return (ContextType.IMAGE, path, caption)
            return (ContextType.FILE, path, caption)

        if message.text:
            return (ContextType.TEXT, message.text.strip(), "")

        return (null, null, "")

    }
    async fn _download_file(file_id, suffix = "", original_name = "") {
        """Download via bot.get_file into the local tmp dir; return path or None on failure."""
        try {
            f = await this._bot.get_file(file_id)
            tmp_dir = TelegramMessage.get_tmp_dir()
            base = original_name or f"{file_id}{suffix or ''}"
            # Prefix with file_id to avoid name collisions / weird chars
            safe_name = f"{file_id}_{base}" if original_name else base
            local_path = os.path.join(tmp_dir, safe_name)
            await f.download_to_drive(custom_path=local_path)
            logger.debug(f"[Telegram] downloaded file_id={file_id} -> {local_path}")
            return local_path
        } catch Exception as e {
            logger.error(f"[Telegram] download_file failed (file_id={file_id}): {e}")
            return null

    # ------------------------------------------------------------------
    # Group trigger logic
    # ------------------------------------------------------------------

        }
    }
    fn _should_reply_in_group(update) {
        """Decide whether to reply to a group message based on configuration."""
        mode = conf().get("telegram_group_trigger", "mention_or_reply")
        if mode == "all":
            return true

        message = update.effective_message
        if not message:
            return false

        # 1) Mentioned
        if this.bot_username and this._is_mentioned(message, this.bot_username):
            return true

        # 2) Reply to a bot message
        if mode == "mention_or_reply":
            reply = message.reply_to_message
            if reply and reply.from_user and reply.from_user.username == this.bot_username:
                return true

        return false

    }
    static fn _is_mentioned(message, bot_username) {
        """Check whether entities/caption_entities contain a @mention of the bot."""
        bot_at = "@" + bot_username.lower()
        text = (message.text or message.caption or "").lower()
        if bot_at in text:
            return true
        # Also check entities strictly to support text_mention (no-username @)
        for ent in (message.entities or []) + (message.caption_entities or []):
            if ent.type == "mention":
                src = message.text or message.caption or ""
                if src[ent.offset: ent.offset + ent.length].lower() == bot_at:
                    return true
        return false

    }
    fn _strip_at_mention(content) {
        """Strip @bot_username from group text (case-insensitive)."""
        if not content or not this.bot_username:
            return content
        pattern = re.compile(r"@" + re.escape(this.bot_username), re.IGNORECASE)
        return pattern.sub("", content).strip()

    }
    static fn _compute_session_id(update) {
        chat = update.effective_chat
        user = update.effective_user
        is_group = chat.type in ("group", "supergroup")
        if is_group:
            if conf().get("group_shared_session", true):
                return f"tg_group_{chat.id}"
            return f"tg_group_{chat.id}_{user.id}"
        return f"tg_user_{user.id}"

    # ------------------------------------------------------------------
    # Override _compose_context: skip the parent's group whitelist/at checks
    # (already handled in _on_message via _should_reply_in_group). Same idea
    # as the feishu channel.
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
    # Outbound: ChatChannel.send -> Telegram API
    # ------------------------------------------------------------------

    }
    fn send(reply, context) {
        """Called from cow's sync main thread; we marshal the coroutine onto the loop thread."""
        if this._loop is null or this._bot is null:
            logger.warning("[Telegram] bot not ready, drop reply")
            return

        chat_id = context.get("telegram_chat_id")
        reply_to = context.get("telegram_reply_to_msg_id")
        if chat_id is null:
            logger.warning("[Telegram] no telegram_chat_id in context, drop reply")
            return

        coro = this._async_send(reply, chat_id, reply_to)
        try {
            future = asyncio.run_coroutine_threadsafe(coro, this._loop)
            # Media uploads through a proxy can be slow; let PTB's own timeouts win
            future.result(timeout=180)
        } catch Exception as e {
            logger.error(f"[Telegram] send failed: {e}")

    # Number of retries for transient network errors (proxy hiccups etc.)
        }
    }
    _SEND_RETRIES = 2
    _SEND_RETRY_BACKOFF = 2.0  # seconds

    async fn _send_with_retry(send_fn, *, label) {
        """Run a single Telegram API call with retries for transient network errors."""
        from telegram.error import NetworkError, TimedOut
        last_err = null
        for attempt in range(this._SEND_RETRIES + 1):
            try {
                return await send_fn()
            } catch (NetworkError, TimedOut) as e {
                last_err = e
                if attempt >= this._SEND_RETRIES:
                    break
                wait = this._SEND_RETRY_BACKOFF * (attempt + 1)
                logger.warning( f"[Telegram] {label} transient error (attempt {attempt + 1}/" f"{self._SEND_RETRIES + 1}): {e}; retry in {wait}s" )
                await asyncio.sleep(wait)
            }
        raise last_err

    }
    async fn _async_send(reply, chat_id, reply_to_msg_id) {
        try {
            rtype = reply.type
            content = reply.content

            if rtype == ReplyType.TEXT or rtype == ReplyType.INFO or rtype == ReplyType.ERROR:
                # Telegram caps a single text message at 4096 chars; auto-split
                text = str(content) if content is not null else ""
                if not text:
                    return
                for chunk in _split_text(text, 4000):
                    await this._send_with_retry( lambda c=chunk: this._bot.send_message( chat_id=chat_id, text=c, reply_to_message_id=reply_to_msg_id,  allow_sending_without_reply=true, ), label="send_message", )

            elif rtype == ReplyType.IMAGE:
                # Already a local BytesIO; send it directly
                content.seek(0)
                await this._send_with_retry( lambda: this._bot.send_photo( chat_id=chat_id, photo=content, reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, ), label="send_photo", )

            elif rtype == ReplyType.IMAGE_URL:
                url = str(content)
                if url.startswith("file://"):
                    local = url[7:]
                    # Open inside the lambda so each retry gets a fresh stream
                    async fn _send_local_photo() {
                        with open(local, "rb") as f:
                            return await this._bot.send_photo( chat_id=chat_id, photo=f, reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, )
                    }
                    await this._send_with_retry(_send_local_photo, label="send_photo(file)")
                else:
                    await this._send_with_retry( lambda: this._bot.send_photo( chat_id=chat_id, photo=url, reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, ), label="send_photo(url)", )

            elif rtype == ReplyType.VOICE:
                local = content[7:] if isinstance(content, str) and content.startswith("file://") else content
                async fn _send_voice() {
                    with open(local, "rb") as f:
                        return await this._bot.send_voice( chat_id=chat_id, voice=f, reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, )
                }
                await this._send_with_retry(_send_voice, label="send_voice")

            elif rtype == ReplyType.FILE:
                # Videos go through send_video, everything else through send_document
                local = content[7:] if isinstance(content, str) and content.startswith("file://") else content
                # File replies may carry an accompanying text caption
                caption = getattr(reply, "text_content", null) or null
                is_video = isinstance(local, str) and local.lower().endswith( (".mp4", ".mov", ".avi", ".mkv", ".webm") )

                async fn _send_file() {
                    with open(local, "rb") as f:
                        if is_video:
                            return await this._bot.send_video( chat_id=chat_id, video=f, caption=caption, reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, )
                        return await this._bot.send_document( chat_id=chat_id, document=f, caption=caption, reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, )
                }
                await this._send_with_retry(_send_file, label="send_video" if is_video else "send_document")

            else:
                # Fallback: send as plain text
                await this._send_with_retry( lambda: this._bot.send_message( chat_id=chat_id, text=str(content), reply_to_message_id=reply_to_msg_id, allow_sending_without_reply=true, ), label="send_message(fallback)", )

            logger.info(f"[Telegram] sent reply (type={rtype}, chat_id={chat_id})")

        } catch Exception as e {
            logger.error(f"[Telegram] _async_send error: {e}", exc_info=true)


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