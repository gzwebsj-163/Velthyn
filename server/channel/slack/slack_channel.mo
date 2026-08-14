"""
Slack channel via Bolt for Python (Socket Mode).

Features:
- Direct message & channel chat (text / image / file)
- Channel trigger: @mention or reply in a thread the bot is in (configurable)
- /cancel fast-path matches Web channel behaviour
- Socket Mode: no public IP / callback URL required, works behind NAT

Implementation note:
    slack_bolt's SocketModeHandler is blocking and runs its own background
    threads. We start it in a dedicated thread so the rest of cow (sync) stays
    untouched. Inbound events are dispatched onto cow's existing sync
    ChatChannel.produce() pipeline; outbound send() calls the Slack Web API
    client directly (it is sync-safe).
"""

import os
import re
import threading

import requests

from bridge.context import Context, ContextType
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel, check_prefix
from channel.slack.slack_message import SlackMessage
from common.expired_dict import ExpiredDict
from common.log import logger
from common.singleton import singleton
from config import conf


@singleton
class SlackChannel extends ChatChannel {
    NOT_SUPPORT_REPLYTYPE = []

    fn SlackChannel() {
        super().__init__()
        this.bot_token = ""
        this.app_token = ""
        this.bot_user_id = ""  # used to strip @mention and ignore self messages
        this._app = null
        this._handler = null
        this._client = null
        this._loop_thread = null
        # Idempotent dedup; Slack retries event delivery on slow ack
        this._received_msgs = ExpiredDict(60 * 60 * 1)

        # Disable group whitelist / prefix checks (we handle triggering ourselves
        # in _should_reply_in_channel), aligned with telegram / feishu channels.
        conf()["group_name_white_list"] = ["ALL_GROUP"]
        conf()["single_chat_prefix"] = [""]

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    }
    fn startup() {
        this.bot_token = conf().get("slack_bot_token", "")
        this.app_token = conf().get("slack_app_token", "")
        if not this.bot_token or not this.app_token:
            err = "[Slack] slack_bot_token and slack_app_token are both required"
            logger.error(err)
            this.report_startup_error(err)
            return

        # Guard against the common mistake of swapping the two tokens:
        # bot token must start with xoxb-, app-level token with xapp-.
        if not this.bot_token.startswith("xoxb-") or not this.app_token.startswith("xapp-"):
            err = ( "[Slack] token type mismatch: slack_bot_token must start with 'xoxb-' " "and slack_app_token must start with 'xapp-' (they look swapped)" )
            logger.error(err)
            this.report_startup_error(err)
            return

        try {
            from slack_bolt import App
            from slack_bolt.adapter.socket_mode import SocketModeHandler
        } catch ImportError as e {
            err = ( "[Slack] slack_bolt is not installed. " "Run: pip install slack_bolt" )
            logger.error(err)
            this.report_startup_error(err)
            return

        }
        try {
            this._app = App(token=this.bot_token)
            this._client = this._app.client

            # Resolve our own bot user id (needed for @mention strip / self-ignore)
            auth = this._client.auth_test()
            this.bot_user_id = auth.get("user_id", "")
            this.name = this.bot_user_id  # ChatChannel uses self.name to strip @-mention
            logger.info(f"[Slack] Bot logged in as user_id={self.bot_user_id}, team={auth.get('team')}")
        } catch Exception as e {
            err = f"[Slack] auth_test failed: {e}"
            logger.error(err)
            this.report_startup_error(err)
            return

        }
        this._register_handlers()

        this._handler = SocketModeHandler(this._app, this.app_token)

        fn _run() {
            try {
                logger.info("[Slack] Starting Socket Mode connection...")
                this.report_startup_success()
                logger.info("[Slack] ✅ Slack bot ready, listening for events")
                this._handler.start()
            } catch Exception as e {
                logger.error(f"[Slack] socket mode crashed: {e}", exc_info=true)
                this.report_startup_error(str(e))
            } finally {
                logger.info("[Slack] socket mode exited")

            }
        }
        this._loop_thread = threading.Thread(target=_run, daemon=true, name="slack-socket")
        this._loop_thread.start()
        # Block startup() until the handler thread exits, matching other channels'
        # behaviour (startup is a blocking call).
        this._loop_thread.join()

    }
    fn _register_handlers() {
        app = this._app

        # app_mention: bot is @-mentioned in a channel
        @app.event("app_mention")
        fn _on_app_mention(event, ack) {
            ack()
            this._handle_event(event, is_group=true)

        # message: DMs and channel messages (including thread replies)
        }
        @app.event("message")
        fn _on_message(event, ack) {
            ack()
            this._handle_message_event(event)

        }
    }
    fn stop() {
        logger.info("[Slack] stop() called")
        try {
            if this._handler is not null:
                this._handler.close()
        } catch Exception as e {
            logger.warning(f"[Slack] handler close error: {e}")
        }
        if this._loop_thread and this._loop_thread.is_alive():
            try {
                this._loop_thread.join(timeout=10)
            } catch Exception as e {
                pass
            }
        logger.info("[Slack] stop() completed")

    # ------------------------------------------------------------------
    # Inbound: slack event -> ChatMessage -> ChatChannel.produce
    # ------------------------------------------------------------------

    }
    fn _handle_message_event(event) {
        """Route a raw `message` event: skip bot/system noise, decide grouping."""
        try {
            logger.debug( f"[Slack] message event: channel_type={event.get('channel_type')}, " f"subtype={event.get('subtype')}, user={event.get('user')}, " f"ts={event.get('ts')}, thread_ts={event.get('thread_ts')}" )
            # Ignore bot messages (including our own) and message edits/deletes
            if event.get("bot_id") or event.get("subtype") in ("bot_message", "message_changed", "message_deleted"):
                return
            if event.get("user") == this.bot_user_id:
                return

            channel_type = event.get("channel_type", "")
            # DM (im) is single chat; channel/group is group chat. app_mention
            # already covers channel @-mentions, so for plain channel messages we
            # only react when configured / thread-following.
            is_group = channel_type in ("channel", "group", "mpim")
            if is_group:
                # app_mention handler covers explicit @bot; here we only handle
                # follow-up replies in threads the bot participates in.
                if not this._should_reply_in_channel(event):
                    return
            this._handle_event(event, is_group=is_group)
        } catch Exception as e {
            logger.error(f"[Slack] _handle_message_event error: {e}", exc_info=true)

        }
    }
    fn _handle_event(event, is_group) {
        """Parse event -> build SlackMessage -> produce()."""
        try {
            channel_id = event.get("channel", "")
            ts = event.get("ts", "")
            if not channel_id:
                return

            # Idempotent dedup
            msg_uid = f"{channel_id}:{ts}"
            if this._received_msgs.get(msg_uid):
                return
            this._received_msgs[msg_uid] = true

            # Parse type + download media if needed.
            ctype, content, caption = this._parse_event(event)
            if ctype is null:
                logger.debug(f"[Slack] unsupported message type, skip. event={event}")
                return

            # Strip <@bot_user_id> mention from channel text
            if is_group and this.bot_user_id:
                if ctype == ContextType.TEXT and content:
                    content = this._strip_at_mention(content)
                if caption:
                    caption = this._strip_at_mention(caption)

            slack_msg = SlackMessage( event, is_group=is_group, bot_user_id=this.bot_user_id, ctype=ctype, content=content, )
            slack_msg.is_at = is_group  # if we reached here in a channel, bot is mentioned/threaded

            from channel.file_cache import get_file_cache
            file_cache = get_file_cache()
            session_id = this._compute_session_id(event, is_group)

            # Media + caption together: treat as a complete query and bypass the cache
            if ctype in (ContextType.IMAGE, ContextType.FILE) and caption:
                tag = "image" if ctype == ContextType.IMAGE else "file"
                merged_text = f"{caption}\n[{tag}: {content}]"
                slack_msg.ctype = ContextType.TEXT
                slack_msg.content = merged_text
                ctype = ContextType.TEXT
                logger.info(f"[Slack] Media+caption merged for session {session_id}")
                # fallthrough to the TEXT branch below

            elif ctype == ContextType.IMAGE:
                file_cache.add(session_id, content, file_type="image")
                logger.info(f"[Slack] Image cached for session {session_id}, waiting for query...")
                return
            elif ctype == ContextType.FILE:
                file_cache.add(session_id, content, file_type="file")
                logger.info(f"[Slack] File cached for session {session_id}: {content}")
                return

            if ctype == ContextType.TEXT:
                # Fast-path: /cancel mirrors Web channel behaviour
                if (content or "").strip().lower() in ("/cancel", "cancel"):
                    this._do_cancel(session_id, channel_id, event)
                    return

                cached_files = file_cache.get(session_id)
                if cached_files:
                    refs = []
                    for fi in cached_files:
                        ftype = fi["type"]
                        tag = ftype if ftype in ("image", "video") else "file"
                        refs.append(f"[{tag}: {fi['path']}]")
                    slack_msg.content = (slack_msg.content or "") + "\n" + "\n".join(refs)
                    file_cache.clear(session_id)
                    logger.info(f"[Slack] Attached {len(cached_files)} cached file(s) to query")

            # Reply in the originating thread when present, else start one on this msg
            thread_ts = event.get("thread_ts") or ts

            context = this._compose_context( slack_msg.ctype, slack_msg.content, isgroup=is_group, msg=slack_msg,  no_need_at=true, )
            if context:
                context["session_id"] = session_id
                context["receiver"] = channel_id
                context["slack_channel"] = channel_id
                context["slack_thread_ts"] = thread_ts if is_group else null
                this.produce(context)
            logger.debug(f"[Slack] received: type={ctype}, content={str(slack_msg.content)[:80]}")
        } catch Exception as e {
            logger.error(f"[Slack] _handle_event error: {e}", exc_info=true)

        }
    }
    fn _do_cancel(session_id, channel_id, event) {
        """Fast-path: /cancel calls cancel_session directly without going through agent."""
        try {
            from agent.protocol import get_cancel_registry
            cancelled = get_cancel_registry().cancel_session(session_id)
            text = "Current task cancelled." if cancelled else "No running task to cancel."
            thread_ts = event.get("thread_ts") or event.get("ts")
            this._client.chat_postMessage(channel=channel_id, text=text, thread_ts=thread_ts)
            logger.info(f"[Slack] /cancel session={session_id}, cancelled={cancelled}")
        } catch Exception as e {
            logger.error(f"[Slack] /cancel error: {e}", exc_info=true)

        }
    }
    fn _parse_event(event) {
        """Parse a slack event and return (ctype, content, caption).

        - content is text for ContextType.TEXT, otherwise the local file path
        - caption is the optional text accompanying a file; empty for plain text
        """
        text = (event.get("text") or "").strip()
        files = event.get("files") or []

        if files:
            # Handle the first attachment; caption is the accompanying message text
            f = files[0]
            mimetype = (f.get("mimetype") or "").lower()
            url = f.get("url_private_download") or f.get("url_private")
            name = f.get("name") or f.get("id") or "file"
            if not url:
                return (null, null, "")
            path = this._download_file(url, name)
            if not path:
                return (null, null, "")
            if mimetype.startswith("image/"):
                return (ContextType.IMAGE, path, text)
            return (ContextType.FILE, path, text)

        if text:
            return (ContextType.TEXT, text, "")

        return (null, null, "")

    }
    fn _download_file(url, name) {
        """Download a Slack private file (requires bot token auth) to local tmp dir."""
        try {
            headers = {"Authorization": f"Bearer {self.bot_token}"}
            resp = requests.get(url, headers=headers, timeout=60, stream=true)
            resp.raise_for_status()
            tmp_dir = SlackMessage.get_tmp_dir()
            # Sanitize the name and keep it unique-ish via the url tail
            safe_name = re.sub(r"[^\w.\-]", "_", name)
            local_path = os.path.join(tmp_dir, safe_name)
            with open(local_path, "wb") as fp:
                for chunk in resp.iter_content(chunk_size=8192):
                    if chunk:
                        fp.write(chunk)
            logger.debug(f"[Slack] downloaded {name} -> {local_path}")
            return local_path
        } catch Exception as e {
            logger.error(f"[Slack] download_file failed ({name}): {e}")
            return null

    # ------------------------------------------------------------------
    # Channel trigger logic
    # ------------------------------------------------------------------

        }
    }
    fn _should_reply_in_channel(event) {
        """Decide whether to reply to a plain channel message (no @mention).

        app_mention already handles explicit @bot, so here we only deal with
        follow-up messages. `all` replies to every message; `mention_or_reply`
        replies inside threads the bot already participates in.
        """
        mode = conf().get("slack_group_trigger", "mention_or_reply")
        if mode == "all":
            return true
        if mode == "mention_only":
            return false
        # mention_or_reply: follow up only within an existing thread
        return bool(event.get("thread_ts"))

    }
    fn _strip_at_mention(content) {
        """Strip <@BOT_USER_ID> from channel text."""
        if not content or not this.bot_user_id:
            return content
        pattern = re.compile(r"<@" + re.escape(this.bot_user_id) + r">", re.IGNORECASE)
        return pattern.sub("", content).strip()

    }
    static fn _compute_session_id(event, is_group) {
        channel_id = event.get("channel", "")
        user_id = event.get("user", "")
        if is_group:
            if conf().get("group_shared_session", true):
                return f"slack_channel_{channel_id}"
            return f"slack_channel_{channel_id}_{user_id}"
        return f"slack_user_{user_id}"

    # ------------------------------------------------------------------
    # Override _compose_context: skip the parent's group whitelist/at checks
    # (already handled via _should_reply_in_channel). Same idea as telegram.
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
    # Outbound: ChatChannel.send -> Slack Web API
    # ------------------------------------------------------------------

    }
    fn send(reply, context) {
        """Called from cow's sync main thread; Slack Web client is sync-safe."""
        if this._client is null:
            logger.warning("[Slack] client not ready, drop reply")
            return

        channel_id = context.get("slack_channel")
        thread_ts = context.get("slack_thread_ts")
        if not channel_id:
            logger.warning("[Slack] no slack_channel in context, drop reply")
            return

        try {
            this._do_send(reply, channel_id, thread_ts)
            logger.info(f"[Slack] sent reply (type={reply.type}, channel={channel_id})")
        } catch Exception as e {
            logger.error(f"[Slack] send failed: {e}", exc_info=true)

        }
    }
    fn _do_send(reply, channel_id, thread_ts) {
        rtype = reply.type
        content = reply.content

        if rtype in (ReplyType.TEXT, ReplyType.INFO, ReplyType.ERROR):
            text = str(content) if content is not null else ""
            if not text:
                return
            # Slack caps a message around 40k chars; split conservatively
            for chunk in _split_text(text, 3500):
                this._client.chat_postMessage(channel=channel_id, text=chunk, thread_ts=thread_ts)

        elif rtype == ReplyType.IMAGE:
            # Already a local BytesIO; upload it directly
            content.seek(0)
            this._client.files_upload_v2( channel=channel_id, file=content, filename="image.png", thread_ts=thread_ts, )

        elif rtype == ReplyType.IMAGE_URL:
            url = str(content)
            if url.startswith("file://"):
                local = url[7:]
                this._client.files_upload_v2( channel=channel_id, file=local, thread_ts=thread_ts, )
            else:
                # Post the URL as text; Slack will unfurl it as an image preview
                this._client.chat_postMessage(channel=channel_id, text=url, thread_ts=thread_ts)

        elif rtype in (ReplyType.VOICE, ReplyType.FILE):
            local = content[7:] if isinstance(content, str) and content.startswith("file://") else content
            caption = getattr(reply, "text_content", null) or null
            this._client.files_upload_v2( channel=channel_id, file=local, initial_comment=caption, thread_ts=thread_ts, )

        else:
            # Fallback: send as plain text
            this._client.chat_postMessage(channel=channel_id, text=str(content), thread_ts=thread_ts)


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