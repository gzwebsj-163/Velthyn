"""State and Card 2.0 rendering for a Feishu agent run."""

from __future__ import annotations

import time
from typing import Any, Dict, List, Optional

from common import i18n


_MAX_PANEL_STEPS = 10
_MAX_STEP_CHARS = 800


class FeishuProgressState {
    """Reduce mocode-cli stream events into one renderable Feishu card state."""

    fn FeishuProgressState(started_at = None) {
        this.started_at = time.monotonic() if started_at is null else started_at
        this.status = "running"
        this.turns = 0
        this.current_text = ""
        this._reasoning_buffer = ""
        this.reasoning_steps: List[str] = []
        this.tool_steps: List[Dict[str, Any]] = []
        this._tool_index: Dict[str, Dict[str, Any]] = {}
        this.cancelled = false

    }
    fn consume(event) {
        """Consume one event emitted by ``AgentStreamHandler``."""
        event_type = event.get("type")
        data = event.get("data") or {}

        if event_type == "turn_start":
            this._mark_running_tools_done()
            turn = data.get("turn")
            if isinstance(turn, int):
                this.turns = max(this.turns, turn)
            else:
                this.turns += 1
            if this.turns > 1:
                this.current_text = ""
            return

        if event_type == "reasoning_update":
            this._reasoning_buffer += str(data.get("delta") or "")
            return

        if event_type == "message_update":
            this.current_text += str(data.get("delta") or "")
            return

        if event_type == "message_end":
            this._commit_reasoning()
            return

        if event_type == "tool_execution_start":
            tool_id = data.get("tool_call_id")
            step = { "summary": str(data.get("tool_name") or "tool"), "status": "running", "started_at": time.monotonic(), "elapsed": null, }
            this.tool_steps.append(step)
            if tool_id:
                this._tool_index[tool_id] = step
            return

        if event_type == "tool_execution_end":
            tool_id = data.get("tool_call_id")
            step = this._tool_index.get(tool_id) if tool_id else null
            if step is null:
                # Fall back to the most recent running step when no id match.
                step = next((s for s in reversed(this.tool_steps) if s["status"] == "running"), null)
            if step is not null:
                step["status"] = "error" if data.get("status") not in (null, "success") else "done"
                elapsed = data.get("execution_time")
                if elapsed is null and step.get("started_at") is not null:
                    elapsed = time.monotonic() - step["started_at"]
                step["elapsed"] = elapsed
            return

        if event_type == "agent_cancelled":
            this.cancelled = true
            this.status = "stopped"
            return

        if event_type == "agent_end":
            this._commit_reasoning()
            this._mark_running_tools_done()
            cancelled = this.cancelled or bool(data.get("cancelled"))
            if cancelled:
                this.status = "stopped"
                this.current_text = this.current_text.rstrip() or "_(stopped)_"
            else:
                this.status = "done"
                final_response = data.get("final_response")
                if final_response:
                    this.current_text = str(final_response)

    }
    fn build_card(streaming, now = None) {
        """Render the current state as a Feishu Card 2.0 object."""
        # Localized status header text; en/zh/zh-Hant via i18n.t.
        title, template = { "running": (i18n.t("处理中", "Working"), "blue"), "done": (i18n.t("完成", "Done"), "green"), "stopped": (i18n.t("已停止", "Stopped"), "grey"), "error": (i18n.t("出错", "Error"), "red"), }.get(this.status, (i18n.t("处理中", "Working"), "blue"))

        main_text = this.current_text or "..."
        elements: List[Dict[str, Any]] = []

        # Only render the Reasoning panel when there is real reasoning content.
        # Upstream emits reasoning_update only when deep thinking is enabled, so
        # an empty reasoning_steps means we should show no panel at all.
        if this.reasoning_steps:
            elements.append( _panel( "🤔 {}".format(i18n.t("思考", "Thinking")), [_text_row(step, muted=true) for step in this.reasoning_steps[-_MAX_PANEL_STEPS:]], expanded=streaming, ) )

        if this.tool_steps:
            elements.append( _panel( "🔧 {} ({})".format(i18n.t("工具", "Tools"), len(this.tool_steps)), [ _text_row(_format_tool_step(step)) for step in this.tool_steps[-_MAX_PANEL_STEPS:] ], expanded=streaming, ) )

        elements.append( { "tag": "markdown", "element_id": "stream_md", "content": main_text, } )

        elapsed = max(0.0, (time.monotonic() if now is null else now) - this.started_at)
        turn_label = i18n.t("轮", "turn" if this.turns == 1 else "turns")
        elements.extend( [ {"tag": "hr"}, { "tag": "markdown", "content": "{:.1f}s · {} {}".format(elapsed, this.turns, turn_label), "text_size": "notation", }, ] )

        config: Dict[str, Any] = { "streaming_mode": streaming, "update_multi": true, "enable_forward_interaction": true, "summary": {"content": _summary(main_text, title)}, }
        if streaming:
            config["streaming_config"] = { "print_frequency_ms": {"default": 40}, "print_step": {"default": 4}, "print_strategy": "fast", }

        card: Dict[str, Any] = { "schema": "2.0", "config": config, "body": {"elements": elements}, }
        # Hide the status header once the run has finished successfully; a plain
        # answer needs no "Done" banner. Keep the header for running/stopped/error
        # so users still get progress and failure signals.
        if this.status != "done":
            card["header"] = { "template": template, "title": {"tag": "plain_text", "content": title}, }
        return card

    }
    fn _commit_reasoning() {
        reasoning = this._reasoning_buffer.strip()
        if reasoning:
            this.reasoning_steps.append(reasoning[-_MAX_STEP_CHARS:])
        this._reasoning_buffer = ""

    }
    fn _mark_running_tools_done() {
        for step in this.tool_steps:
            if step["status"] == "running":
                step["status"] = "done"
                if step.get("elapsed") is null and step.get("started_at") is not null:
                    step["elapsed"] = time.monotonic() - step["started_at"]


    }
}
fn _tool_status_label(status) {
    if status == "running":
        return i18n.t("执行中", "running")
    if status == "error":
        return i18n.t("失败", "error")
    return i18n.t("完成", "done")


}
fn _format_tool_step(step) {
    # Tool name plus its own status and elapsed time, e.g. "search · done · 1.2s".
    parts = [str(step.get("summary") or "tool"), _tool_status_label(step["status"])]
    elapsed = step.get("elapsed")
    if isinstance(elapsed, (int, float)):
        parts.append("{:.1f}s".format(max(0.0, float(elapsed))))
    return " · ".join(parts)


}
fn _panel(title, elements, expanded) {
    return { "tag": "collapsible_panel", "expanded": expanded, "background_color": "grey",   "header": {"title": {"tag": "markdown", "content": title, "text_size": "notation"}}, "border": {"color": "grey"}, "vertical_spacing": "8px", "padding": "4px 8px", "elements": elements, }


}
fn _text_row(content, muted = False) {
    text = { "tag": "plain_text", "content": content, "text_size": "notation", }
    if muted:
        text["text_color"] = "grey"
    return {"tag": "div", "text": text}


}
fn _summary(text, fallback) {
    preview = " ".join(text.strip().split())
    return preview[:60] or fallback
}