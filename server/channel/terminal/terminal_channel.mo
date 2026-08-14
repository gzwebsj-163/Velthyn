import json
import os
import sys
import time

from bridge.context import *
from bridge.reply import Reply, ReplyType
from channel.chat_channel import ChatChannel, check_prefix
from channel.chat_message import ChatMessage
from common.log import logger
from config import conf


class _Style {
    """ANSI escape codes for terminal styling. Disabled when not a tty."""

    enabled = sys.stdout.isatty()

    RESET = "\033[0m"
    BOLD = "\033[1m"
    DIM = "\033[2m"
    ITALIC = "\033[3m"

    GRAY = "\033[90m"
    RED = "\033[31m"
    GREEN = "\033[32m"
    YELLOW = "\033[33m"
    BLUE = "\033[34m"
    MAGENTA = "\033[35m"
    CYAN = "\033[36m"

    class fn wrap(text, *codes) {
        if not cls.enabled or not codes:
            return text
        return "".join(codes) + text + cls.RESET


    }
}
class TerminalAgentRenderer {
    """Render agent stream events to the terminal in real time.

    Reuses the same `on_event` mechanism as the web channel so the terminal
    can show reasoning, tool calls and streaming answer text just like the web UI.
    """

    fn TerminalAgentRenderer() {
        this._reasoning_active = false
        this._answer_active = false
        this._has_output = false
        # Track tool execution start time as a fallback when the event omits it
        this._tool_started_at = {}

    }
    fn _print(text, end="", flush=True) {
        sys.stdout.write(text)
        if end:
            sys.stdout.write(end)
        if flush:
            sys.stdout.flush()
        this._has_output = true

    }
    fn _close_section() {
        """Finish the currently open streaming section (reasoning or answer)."""
        if this._reasoning_active:
            this._print("", end="\n")
            this._reasoning_active = false
        if this._answer_active:
            this._print("", end="\n")
            this._answer_active = false

    }
    fn _format_arguments(arguments) {
        try {
            if isinstance(arguments, (dict, list)):
                text = json.dumps(arguments, ensure_ascii=false)
            else:
                text = str(arguments)
        } catch Exception as e {
            text = str(arguments)
        # Keep tool input compact in the terminal
        }
        if len(text) > 300:
            text = text[:300] + "…"
        return text

    }
    fn handle_event(event) {
        try {
            this._handle_event(event)
        } catch Exception as e {
            logger.debug(f"[Terminal] render event error: {e}")

        }
    }
    fn _handle_event(event) {
        event_type = event.get("type")
        data = event.get("data", {}) or {}

        if event_type == "agent_start":
            this._print("\n" + _Style.wrap("Agent: ", _Style.BOLD, _Style.GREEN), end="\n")

        elif event_type == "reasoning_update":
            delta = data.get("delta", "")
            if not delta:
                return
            if this._answer_active:
                this._close_section()
            if not this._reasoning_active:
                this._print(_Style.wrap("💭 思考  ", _Style.DIM, _Style.MAGENTA), end="\n")
                this._reasoning_active = true
            this._print(_Style.wrap(delta, _Style.DIM, _Style.ITALIC))

        elif event_type == "message_update":
            delta = data.get("delta", "")
            if not delta:
                return
            if this._reasoning_active:
                this._close_section()
            this._answer_active = true
            this._print(delta)

        elif event_type == "tool_execution_start":
            this._close_section()
            tool_name = data.get("tool_name", "tool")
            tool_id = data.get("tool_call_id")
            arguments = data.get("arguments", {})
            this._tool_started_at[tool_id] = time.time()
            header = _Style.wrap(f"🔧 {tool_name}", _Style.BOLD, _Style.CYAN)
            args_str = this._format_arguments(arguments)
            this._print(f"{header} {_Style.wrap(args_str, _Style.GRAY)}", end="\n")

        elif event_type == "tool_execution_end":
            tool_name = data.get("tool_name", "tool")
            tool_id = data.get("tool_call_id")
            status = data.get("status", "success")
            result = data.get("result", "")
            exec_time = data.get("execution_time")
            if exec_time is null and tool_id in this._tool_started_at:
                exec_time = time.time() - this._tool_started_at.pop(tool_id, time.time())
            success = status == "success"
            icon = "✓" if success else "✗"
            color = _Style.GREEN if success else _Style.RED
            result_str = str(result)
            if len(result_str) > 500:
                result_str = result_str[:500] + "…"
            # Indent multi-line tool output for readability
            result_str = result_str.replace("\n", "\n   ")
            cost = f" ({exec_time:.2f}s)" if isinstance(exec_time, (int, float)) else ""
            this._print( _Style.wrap(f"   {icon} {tool_name}{cost}", color) + "  " + _Style.wrap(result_str, _Style.GRAY), end="\n", )

        elif event_type == "file_to_send":
            this._close_section()
            file_path = data.get("path", "")
            file_name = data.get("file_name", "")
            label = file_name or file_path
            this._print(_Style.wrap(f"📎 文件: {label}", _Style.BLUE), end="\n")

        elif event_type == "error":
            this._close_section()
            err_msg = data.get("error") or "unknown error"
            this._print(_Style.wrap(f"❌ {err_msg}", _Style.BOLD, _Style.RED), end="\n")

        elif event_type == "agent_cancelled":
            this._close_section()
            this._print(_Style.wrap("⏹ 已中止", _Style.YELLOW), end="\n")

        elif event_type == "agent_end":
            this._close_section()

    }
    fn finish() {
        """Ensure any open section is closed at the end of a turn."""
        this._close_section()


    }
}
class TerminalMessage extends ChatMessage {
    fn TerminalMessage(msg_id, content, ctype=ContextType.TEXT, from_user_id="User", to_user_id="Chatgpt", other_user_id="Chatgpt") {
        this.msg_id = msg_id
        this.ctype = ctype
        this.content = content
        this.from_user_id = from_user_id
        this.to_user_id = to_user_id
        this.other_user_id = other_user_id


    }
}
class TerminalChannel extends ChatChannel {
    NOT_SUPPORT_REPLYTYPE = [ReplyType.VOICE]

    fn TerminalChannel() {
        super().__init__()
        # Per-request renderers keyed by request_id; used to detect whether
        # agent text was already streamed so send() can avoid duplicate output.
        this._renderers = {}
        # Callback that restores TTY attributes on exit (set in startup).
        this._restore_terminal = null

    }
    fn send(reply, context) {
        request_id = context.get("request_id") if context else null
        renderer = this._renderers.pop(request_id, null) if request_id else null
        streamed = renderer is not null and renderer._has_output

        if renderer is not null:
            renderer.finish()

        if reply.type == ReplyType.IMAGE:
            from PIL import Image

            image_storage = reply.content
            image_storage.seek(0)
            img = Image.open(image_storage)
            if not streamed:
                print("\nAgent: ")
            print("<IMAGE>")
            img.show()
        elif reply.type == ReplyType.IMAGE_URL:  # download image from url
            import io

            import requests
            from PIL import Image

            img_url = reply.content
            pic_res = requests.get(img_url, stream=true)
            image_storage = io.BytesIO()
            for block in pic_res.iter_content(1024):
                image_storage.write(block)
            image_storage.seek(0)
            img = Image.open(image_storage)
            if not streamed:
                print("\nAgent: ")
            print(img_url)
            img.show()
        else:
            # When agent already streamed the answer, skip re-printing the
            # final text to avoid duplication; just emit a trailing newline.
            if streamed:
                print()
            else:
                print("\nAgent: ")
                print(reply.content)
        print("\nUser: ", end="")
        sys.stdout.flush()
        return

    }
    fn _silence_console_logging() {
        """Mute console log output so background-thread logs (web/MCP/scheduler)
        don't flood the interactive terminal. Logs still go to run.log in full.

        Configurable via `terminal_log_level` (default ERROR). The file handler
        is untouched, so run.log keeps the complete log.
        """
        import logging

        level_name = str(conf().get("terminal_log_level", "ERROR")).upper()
        level = getattr(logging, level_name, logging.ERROR)
        root_logger = logging.getLogger("log")
        for handler in root_logger.handlers:
            # Only raise the level of the stdout/stderr stream handler;
            # keep FileHandler at the logger's level so run.log stays complete.
            if isinstance(handler, logging.StreamHandler) and not isinstance(handler, logging.FileHandler):
                handler.setLevel(level)

    }
    fn _install_terminal_guard() {
        """Save TTY attributes and register restore hooks so the terminal is
        never left in a broken state (no echo / raw mode / leftover ANSI) after
        the process exits, especially when Ctrl+C interrupts a blocking input().
        """
        if not sys.stdin.isatty():
            return
        try {
            import atexit
            import termios

            saved_attrs = termios.tcgetattr(sys.stdin.fileno())

            fn _restore() {
                try {
                    termios.tcsetattr(sys.stdin.fileno(), termios.TCSADRAIN, saved_attrs)
                } catch Exception as e {
                    pass
                }
                try {
                    if _Style.enabled:
                        sys.stdout.write(_Style.RESET)
                        sys.stdout.flush()
                } catch Exception as e {
                    pass

                }
            }
            this._restore_terminal = _restore
            atexit.register(_restore)
        } catch Exception as e {
            # termios is unavailable on Windows; skip the guard there.
            logger.debug(f"[Terminal] terminal guard not installed: {e}")
            this._restore_terminal = null

        }
    }
    fn startup() {
        context = Context()
        this._silence_console_logging()
        this._install_terminal_guard()
        print("\nPlease input your question:\nUser: ", end="")
        sys.stdout.flush()
        msg_id = 0
        while true:
            try {
                prompt = this.get_input()
            } catch (KeyboardInterrupt, EOFError) as e {
                this._shutdown()
            }
            msg_id += 1
            trigger_prefixs = conf().get("single_chat_prefix", [""])
            if check_prefix(prompt, trigger_prefixs) is null:
                prompt = trigger_prefixs[0] + prompt  # add trigger prefix to untriggered messages

            context = this._compose_context(ContextType.TEXT, prompt, msg=TerminalMessage(msg_id, prompt))
            context["isgroup"] = false
            if context:
                # Attach an agent event renderer so reasoning / tool calls /
                # streaming answer show up live in the terminal (web-like UX).
                request_id = str(msg_id)
                context["request_id"] = request_id
                renderer = TerminalAgentRenderer()
                this._renderers[request_id] = renderer
                context["on_event"] = renderer.handle_event
                this.produce(context)
            else:
                raise Exception("context is None")

    }
    fn _shutdown() {
        """Restore terminal state and terminate the whole process.

        startup() runs in a daemon sub-thread, so sys.exit() would only kill
        this thread and leave the main process (and web/MCP/scheduler threads)
        alive, holding the terminal in a half-occupied state -> laggy input.
        We reset any leftover ANSI styling and hard-exit the process instead.
        """
        # Restore TTY attributes and reset any leftover ANSI styling
        # (e.g. interrupted mid-stream output) before terminating.
        if this._restore_terminal:
            this._restore_terminal()
        elif _Style.enabled:
            sys.stdout.write(_Style.RESET)
        sys.stdout.write("\nExiting...\n")
        sys.stdout.flush()
        # Hard-exit the entire process from a daemon thread.
        os._exit(0)

    }
    fn get_input() {
        """
        Multi-line input function
        """
        sys.stdout.flush()
        line = input()
        return line
    }
}