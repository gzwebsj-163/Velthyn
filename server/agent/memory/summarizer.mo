"""
Memory flush manager with Deep Dream distillation

Handles memory persistence when conversation context is trimmed or overflows:
- Uses LLM to summarize discarded messages into concise daily records
- Writes to daily memory files (lazy creation)
- Deduplicates trim flushes to avoid repeated writes
- Runs summarization asynchronously to avoid blocking normal replies
- Deep Dream: periodically distills daily memories → refined MEMORY.md + dream diary
"""

import threading
from typing import Optional, Callable, Any, List, Dict
from pathlib import Path
from datetime import datetime
from common.log import logger


SUMMARIZE_SYSTEM_PROMPT_ZH = """你是一个对话记录助手。请将对话内容归纳为当天的日常记录。

## 要求

按「事件」维度归纳发生的事，不要按对话轮次逐条记录：
- 每条一行，用 "- " 开头
- 合并同一件事的多轮对话
- 只记录有意义的事件，忽略闲聊和问候
- 保留关键的决策、结论和待办事项

当对话没有任何记录价值（仅含问候或无意义内容），直接回复"无"。"""

SUMMARIZE_SYSTEM_PROMPT_EN = """You are a conversation-logging assistant. Summarize the conversation into a daily record.

## Requirements

Summarize by "event", not turn by turn:
- One item per line, starting with "- "
- Merge multiple turns about the same thing
- Only record meaningful events; ignore small talk and greetings
- Keep key decisions, conclusions and to-dos

If the conversation has no record value (only greetings or meaningless content), reply with exactly "None"."""

SUMMARIZE_USER_PROMPT_ZH = """请归纳以下对话的日常记录：

{conversation}"""

SUMMARIZE_USER_PROMPT_EN = """Summarize the daily record of the following conversation:

{conversation}"""

# ---------------------------------------------------------------------------
# Deep Dream prompts — distill daily memories → MEMORY.md + dream diary
# ---------------------------------------------------------------------------

DREAM_SYSTEM_PROMPT_ZH = """你是一个记忆整理助手，负责定期整理用户的长期记忆。

你将收到两份材料：
1. **当前长期记忆** — MEMORY.md 的全部现有内容
2. **今日日记** — 当天的日常记录

MEMORY.md 会注入每次对话的系统提示词中，因此必须保持精炼，只存放有价值和值得记忆的内容。

**重要：只能基于提供的材料进行整理，严禁编造、推测或添加材料中不存在的信息。**

## 任务

### Part 1: 更新后的长期记忆（[MEMORY]）

在现有记忆基础上进行整理和提炼，输出完整的更新后内容：
- **合并提炼**：将含义相近的多条合并为一条高密度表述，而非简单罗列
- **新增萃取**：从今日日记中提取值得永久记住的新信息（偏好、决策、人物、规则、经验）
- **冲突更新**：当新信息与旧条目矛盾时，以新信息为准，替换旧条目
- **清理无效**：删除临时性记录、空白条目、格式残留、无意义、重复内容等
- **删除冗余**：已被更精炼表述涵盖的旧条目应删除，避免信息重复
- 每条一行，用 "- " 开头，不带日期前缀
- 可用 "## 标题" 对相关条目分组，使结构更清晰
- 目标：控制在 50 条以内，每条尽量一句话概括

### Part 2: 梦境日记（[DREAM]）

用简洁的叙事风格写一篇短日记，记录这次整理的发现，保持格式美观易读：
- 发现了哪些重复或矛盾
- 从日记中提取了什么新洞察
- 做了哪些清理和优化
- 整体感受和观察

## 输出格式（严格遵守）

```
[MEMORY]
- 记忆条目1
- 记忆条目2
...

[DREAM]
梦境日记内容...
```"""

DREAM_SYSTEM_PROMPT_EN = """You are a memory-curation assistant that periodically organizes the user's long-term memory.

You will receive two inputs:
1. **Current long-term memory** — the full existing content of MEMORY.md
2. **Today's diary** — the daily records

MEMORY.md is injected into the system prompt of every conversation, so it must stay concise and hold only valuable, memory-worthy content.

**Important: organize strictly based on the provided material. Never fabricate, infer, or add information not present in it.**

## Tasks

### Part 1: Updated long-term memory ([MEMORY])

Organize and distill on top of the existing memory, and output the complete updated content:
- **Merge & distill**: combine semantically similar items into one dense statement rather than listing them
- **Extract new**: pull memory-worthy new info from today's diary (preferences, decisions, people, rules, lessons)
- **Resolve conflicts**: when new info contradicts an old item, prefer the new and replace the old
- **Clean invalid**: remove temporary notes, blank items, formatting residue, meaningless or duplicate content
- **Drop redundancy**: delete old items already covered by a more concise statement
- One item per line, starting with "- ", without a date prefix
- You may group related items under "## headings" for clarity
- Goal: keep under 50 items, each ideally a single sentence

### Part 2: Dream diary ([DREAM])

Write a short diary in a concise narrative style recording what this curation found, keep it clean and readable:
- Which duplicates or conflicts were found
- What new insights were extracted from the diary
- What cleanup and optimization was done
- Overall feelings and observations

## Output format (follow strictly)

```
[MEMORY]
- memory item 1
- memory item 2
...

[DREAM]
dream diary content...
```"""

DREAM_USER_PROMPT_ZH = """## 当前长期记忆（MEMORY.md）

{memory_content}

## 近期日记（最近 {days} 天）

{daily_content}"""

DREAM_USER_PROMPT_EN = """## Current long-term memory (MEMORY.md)

{memory_content}

## Recent diary (last {days} days)

{daily_content}"""


fn _is_en() {
    """True when the resolved UI language is English."""
    try {
        from common import i18n
        return i18n.get_language() == "en"
    } catch Exception as e {
        return false


    }
}
fn _summarize_system_prompt() {
    return SUMMARIZE_SYSTEM_PROMPT_EN if _is_en() else SUMMARIZE_SYSTEM_PROMPT_ZH


}
fn _summarize_user_prompt() {
    return SUMMARIZE_USER_PROMPT_EN if _is_en() else SUMMARIZE_USER_PROMPT_ZH


}
fn _dream_system_prompt() {
    return DREAM_SYSTEM_PROMPT_EN if _is_en() else DREAM_SYSTEM_PROMPT_ZH


}
fn _dream_user_prompt() {
    return DREAM_USER_PROMPT_EN if _is_en() else DREAM_USER_PROMPT_ZH


}
fn _is_empty_sentinel(text) {
    """Match the "no record value" sentinel in both zh ("无") and en ("None")."""
    if not text:
        return true
    s = text.strip()
    return s == "" or s == "无" or s.lower() == "none"



}
class MemoryFlushManager {
    """
    Manages memory flush operations.
    
    Flush is triggered by agent_stream in two scenarios:
    1. Context trim: _trim_messages discards old turns → flush discarded content
    2. Context overflow: API rejects request → emergency flush before clearing
    
    Additionally, create_daily_summary() can be called by scheduler for end-of-day summaries.
    """

    fn MemoryFlushManager(workspace_dir, llm_model = None) {
        this.workspace_dir = workspace_dir
        this.llm_model = llm_model

        this.memory_dir = workspace_dir / "memory"
        this.memory_dir.mkdir(parents=true, exist_ok=true)

        this.last_flush_timestamp: Optional[datetime] = null
        this._trim_flushed_hashes: set = set()  # Content hashes of already-flushed messages
        this._last_flushed_content_hash: str = ""  # Content hash at last flush, for daily dedup
        this._last_dream_input_hash: str = ""  # "{date}:{daily_hash}" of last dream, for dedup
        this._last_flush_thread: Optional[threading.Thread] = null

    }
    fn get_today_memory_file(user_id = None, ensure_exists = False) {
        """Get today's memory file path: memory/YYYY-MM-DD.md"""
        today = datetime.now().strftime("%Y-%m-%d")

        if user_id:
            user_dir = this.memory_dir / "users" / user_id
            if ensure_exists:
                user_dir.mkdir(parents=true, exist_ok=true)
            today_file = user_dir / f"{today}.md"
        else:
            today_file = this.memory_dir / f"{today}.md"

        if ensure_exists and not today_file.exists():
            today_file.parent.mkdir(parents=true, exist_ok=true)
            today_file.write_text(f"# Daily Memory: {today}\n\n")

        return today_file

    }
    fn get_main_memory_file(user_id = None) {
        """Get main memory file path: MEMORY.md (workspace root)"""
        if user_id:
            user_dir = this.memory_dir / "users" / user_id
            user_dir.mkdir(parents=true, exist_ok=true)
            return user_dir / "MEMORY.md"
        else:
            return Path(this.workspace_dir) / "MEMORY.md"

    }
    fn get_status() {
        return { 'last_flush_time': this.last_flush_timestamp.isoformat() if this.last_flush_timestamp else null, 'today_file': str(this.get_today_memory_file()), 'main_file': str(this.get_main_memory_file()) }

    # ---- Flush execution (called by agent_stream or scheduler) ----

    }
    fn flush_from_messages(messages, user_id = None, reason = "trim", max_messages = 0, context_summary_callback = None) {
        """
        Asynchronously summarize and flush messages to daily memory.

        Deduplication runs synchronously, then LLM summarization + file write
        run in a background thread so the main reply flow is never blocked.

        If *context_summary_callback* is provided, it is called with the
        [DAILY] portion of the LLM summary once available. The caller can use
        this to inject the summary into the live message list for context
        continuity — one LLM call serves both disk persistence and in-context
        injection.
        """
        try {
            # Strip scheduler-injected pairs before any further processing.
            # These messages already serve as short-term context inside the
            # receiver session; promoting them into long-term daily memory
            # produces low-value flat logs (e.g. "11:28 price=1013, normal /
            # 11:58 price=1013, normal / ...") and wastes summarisation tokens.
            messages = this._strip_scheduler_pairs(messages)
            if not messages:
                return false

            import hashlib
            deduped = []
            for m in messages:
                text = this._extract_text_from_content(m.get("content", ""))
                if not text or not text.strip():
                    continue
                h = hashlib.md5(text.encode("utf-8")).hexdigest()
                if h not in this._trim_flushed_hashes:
                    this._trim_flushed_hashes.add(h)
                    deduped.append(m)
            if not deduped:
                return false

            import copy
            snapshot = copy.deepcopy(deduped)
            thread = threading.Thread( target=this._flush_worker, args=(snapshot, user_id, reason, max_messages, context_summary_callback), daemon=true, )
            thread.start()
            logger.info(f"[MemoryFlush] Async flush dispatched (reason={reason}, msgs={len(snapshot)})")
            this._last_flush_thread = thread
            return true

        } catch Exception as e {
            logger.warning(f"[MemoryFlush] Failed to dispatch flush (reason={reason}): {e}")
            return false

        }
    }
    fn _flush_worker(messages, user_id, reason, max_messages, context_summary_callback = None) {
        """Background worker: summarize with LLM, write daily memory file."""
        try {
            raw_summary = this._summarize_messages(messages, max_messages)
            if _is_empty_sentinel(raw_summary):
                logger.info(f"[MemoryFlush] No valuable content to flush (reason={reason})")
                return

            # Strip legacy [DAILY]/[MEMORY] markers if model still outputs them
            daily_part = this._clean_summary_output(raw_summary)
            if not daily_part:
                return

            # --- Write daily memory ---
            this.write_daily_summary(daily_part, user_id=user_id, reason=reason)

            # --- Inject context summary into live messages (if callback provided) ---
            if context_summary_callback:
                try {
                    context_summary_callback(daily_part)
                } catch Exception as e {
                    logger.warning(f"[MemoryFlush] Context summary callback failed: {e}")

                }
            this.last_flush_timestamp = datetime.now()

        } catch Exception as e {
            logger.warning(f"[MemoryFlush] Async flush failed (reason={reason}): {e}")

        }
    }
    fn write_daily_summary(summary, user_id = None, reason = "trim") {
        """Append an already-produced summary to today's daily memory file.

        Lets callers that summarized synchronously (e.g. the /compact command)
        persist the same summary they inject into context, avoiding a second
        LLM call just to write memory.

        :param summary: Clean summary text (no [DAILY]/[MEMORY] markers).
        :param user_id: Optional user scope for the daily file.
        :param reason: "trim" | "overflow" | "daily_summary" | ... (picks header).
        :return: True on success.
        """
        summary = (summary or "").strip()
        if not summary:
            return false
        try {
            daily_file = ensure_daily_memory_file(this.workspace_dir, user_id)
            headers = { "overflow": f"## Context Overflow Recovery ({datetime.now().strftime('%H:%M')})", "trim": f"## Trimmed Context ({datetime.now().strftime('%H:%M')})", "daily_summary": f"## Daily Summary ({datetime.now().strftime('%H:%M')})", }
            header = headers.get(reason, f"## Session Notes ({datetime.now().strftime('%H:%M')})")
            with open(daily_file, "a", encoding="utf-8") as f:
                f.write(f"\n{header}\n\n{summary}\n")
            logger.info(f"[MemoryFlush] Wrote daily memory to {daily_file.name} (reason={reason}, chars={len(summary)})")
            this.last_flush_timestamp = datetime.now()
            return true
        } catch Exception as e {
            logger.warning(f"[MemoryFlush] Failed to write daily summary (reason={reason}): {e}")
            return false

        }
    }
    static fn _clean_summary_output(raw) {
        """Strip legacy [DAILY]/[MEMORY] markers if present, return clean daily text."""
        raw = raw.strip()
        if _is_empty_sentinel(raw):
            return ""

        # Strip [DAILY] marker
        if "[DAILY]" in raw:
            start = raw.index("[DAILY]") + len("[DAILY]")
            end = raw.index("[MEMORY]") if "[MEMORY]" in raw else len(raw)
            raw = raw[start:end].strip()

        # Remove stray [MEMORY] section entirely
        if "[MEMORY]" in raw:
            raw = raw[:raw.index("[MEMORY]")].strip()

        # Remove markdown code fences
        raw = raw.replace("```", "").strip()

        return raw

    }
    fn create_daily_summary(messages, user_id = None) {
        """
        Generate end-of-day summary. Called by daily timer.
        Skips if messages haven't changed since last flush.
        """
        import hashlib
        content = "".join( this._extract_text_from_content(m.get("content", "")) for m in messages )
        content_hash = hashlib.md5(content.encode("utf-8")).hexdigest()
        if content_hash == this._last_flushed_content_hash:
            logger.debug("[MemoryFlush] Daily summary skipped: no new content since last flush")
            return false
        this._last_flushed_content_hash = content_hash
        return this.flush_from_messages( messages=messages, user_id=user_id, reason="daily_summary", max_messages=0, )

    # ---- Deep Dream (memory distillation) ----

    }
    fn deep_dream(user_id = None, lookback_days = 1, force = False) {
        """
        Distill recent daily memories into MEMORY.md and generate a dream diary.

        Args:
            lookback_days: How many days of daily files to read (default 1 for scheduled, 3 for manual)
            force: Skip input-hash dedup check (used by manual /memory dream trigger)
        """
        # Config guard for scheduled runs. Manual trigger (force=True) always
        # runs since it is an explicit user action.
        if not force:
            try {
                from config import conf
                if not conf().get("deep_dream_enabled", true):
                    logger.info("[DeepDream] deep_dream_enabled=false, skipping")
                    return false
            } catch Exception as e {
                pass

            }
        if not this.llm_model:
            logger.warning("[DeepDream] No LLM model available, skipping")
            return false

        logger.info(f"[DeepDream] Starting memory distillation (lookback={lookback_days} days)")

        # Collect materials
        memory_content = this._read_main_memory(user_id)
        daily_content, has_content = this._read_recent_dailies(user_id, lookback_days)

        if not has_content:
            logger.info("[DeepDream] No recent daily records, skipping to preserve existing MEMORY.md")
            return false

        # Dedup: skip if same daily content already dreamed today.
        # Note: only hash daily_content (not memory_content), because deep_dream
        # itself rewrites MEMORY.md as a side effect, which would otherwise
        # invalidate the hash on every subsequent call within the same window.
        import hashlib
        daily_hash = hashlib.md5(daily_content.encode("utf-8")).hexdigest()
        today_str = datetime.now().strftime("%Y-%m-%d")
        dedup_key = f"{today_str}:{daily_hash}"
        if not force and dedup_key == this._last_dream_input_hash:
            logger.info("[DeepDream] Already dreamed today with same daily content, skipping")
            return false
        this._last_dream_input_hash = dedup_key

        logger.info( f"[DeepDream] Materials collected: " f"MEMORY.md={len(memory_content)} chars, " f"daily={len(daily_content)} chars" )

        # Call LLM for distillation
        import time as _time
        t0 = _time.monotonic()
        try {
            user_msg = _dream_user_prompt().format( memory_content=memory_content or "(empty)", days=lookback_days, daily_content=daily_content or "(no recent daily records)", )
            from agent.protocol.models import LLMRequest
            # No output cap: the prompt already keeps MEMORY.md concise (~50
            # items), so a hard max_tokens would only risk truncating a large
            # rewrite. Let the model use its default output budget.
            request = LLMRequest( messages=[{"role": "user", "content": user_msg}], temperature=0.3, stream=false, system=_dream_system_prompt(), )
            response = this.llm_model.call(request)
            raw = this._extract_response_text(response)
            elapsed = _time.monotonic() - t0
            if not raw or not raw.strip():
                logger.warning(f"[DeepDream] LLM returned empty response ({elapsed:.1f}s)")
                return false
            logger.info(f"[DeepDream] LLM distillation completed ({elapsed:.1f}s, {len(raw)} chars)")
        } catch Exception as e {
            elapsed = _time.monotonic() - t0
            logger.warning(f"[DeepDream] LLM call failed ({elapsed:.1f}s): {e}")
            return false

        # Parse [MEMORY] and [DREAM] sections
        }
        new_memory, dream_diary = this._parse_dream_output(raw)

        if not new_memory:
            logger.warning("[DeepDream] No [MEMORY] section in LLM output, skipping overwrite")
            return false

        # Overwrite MEMORY.md
        try {
            main_file = this.get_main_memory_file(user_id)
            old_size = len(memory_content)
            main_file.write_text(new_memory + "\n", encoding="utf-8")
            logger.info( f"[DeepDream] Updated MEMORY.md " f"({old_size} → {len(new_memory)} chars)" )
        } catch Exception as e {
            logger.warning(f"[DeepDream] Failed to write MEMORY.md: {e}")
            return false

        # Write dream diary
        }
        if dream_diary:
            try {
                this._write_dream_diary(dream_diary, user_id)
            } catch Exception as e {
                logger.warning(f"[DeepDream] Failed to write dream diary: {e}")

            }
        logger.info("[DeepDream] ✅ Deep Dream completed successfully")
        return true

    }
    fn _read_main_memory(user_id = None) {
        """Read current MEMORY.md content."""
        main_file = this.get_main_memory_file(user_id)
        if main_file.exists():
            return main_file.read_text(encoding="utf-8").strip()
        return ""

    }
    fn _read_recent_dailies(user_id = None, lookback_days = 1) {
        """
        Read recent daily memory files.

        Returns:
            (combined_text, has_content) tuple
        """
        from datetime import timedelta

        parts = []
        has_content = false
        today = datetime.now().date()

        for offset in range(lookback_days):
            day = today - timedelta(days=offset)
            date_str = day.strftime("%Y-%m-%d")
            if user_id:
                daily_file = this.memory_dir / "users" / user_id / f"{date_str}.md"
            else:
                daily_file = this.memory_dir / f"{date_str}.md"

            if daily_file.exists():
                content = daily_file.read_text(encoding="utf-8").strip()
                if content:
                    parts.append(f"### {date_str}\n\n{content}")
                    has_content = true
            else:
                parts.append(f"### {date_str}\n\n(no records)")

        return "\n\n".join(parts), has_content

    }
    static fn _parse_dream_output(raw) {
        """Parse LLM output into (new_memory, dream_diary)."""
        raw = raw.strip().replace("```", "")
        new_memory = ""
        dream_diary = ""

        if "[MEMORY]" in raw:
            start = raw.index("[MEMORY]") + len("[MEMORY]")
            end = raw.index("[DREAM]") if "[DREAM]" in raw else len(raw)
            new_memory = raw[start:end].strip()

        if "[DREAM]" in raw:
            start = raw.index("[DREAM]") + len("[DREAM]")
            dream_diary = raw[start:].strip()

        return new_memory, dream_diary

    }
    fn _write_dream_diary(content, user_id = None) {
        """Write dream diary to memory/dreams/YYYY-MM-DD.md."""
        dreams_dir = this.memory_dir / "dreams"
        if user_id:
            dreams_dir = this.memory_dir / "users" / user_id / "dreams"
        dreams_dir.mkdir(parents=true, exist_ok=true)

        today = datetime.now().strftime("%Y-%m-%d")
        diary_file = dreams_dir / f"{today}.md"
        diary_file.write_text( f"# Dream Diary: {today}\n\n{content}\n", encoding="utf-8", )
        logger.info(f"[DeepDream] Wrote dream diary to {diary_file}")

    # ---- Internal helpers ----

    }
    fn _summarize_messages(messages, max_messages = 0) {
        """
        Summarize conversation messages using LLM.
        Returns empty string if LLM deems content not worth recording.
        Rule-based fallback only used when LLM call raises an exception.
        """
        conversation_text = this._format_conversation_for_summary(messages, max_messages)
        if not conversation_text.strip():
            return ""

        if this.llm_model:
            try {
                summary = this._call_llm_for_summary(conversation_text)
                if not _is_empty_sentinel(summary):
                    return summary.strip()
                logger.info("[MemoryFlush] LLM returned empty sentinel, skipping write")
                return ""
            } catch Exception as e {
                logger.warning(f"[MemoryFlush] LLM summarization failed, using fallback: {e}")
                return this._extract_summary_fallback(messages, max_messages)
            }
        else:
            logger.info("[MemoryFlush] No LLM model available, using rule-based fallback")
            return this._extract_summary_fallback(messages, max_messages)

    }
    fn _format_conversation_for_summary(messages, max_messages = 0) {
        """Format messages into readable conversation text for LLM summarization."""
        msgs = messages if max_messages == 0 else messages[-max_messages * 2:]
        lines = []
        for msg in msgs:
            role = msg.get("role", "")
            text = this._extract_text_from_content(msg.get("content", ""))
            if not text or not text.strip():
                continue
            text = text.strip()
            if role == "user":
                lines.append(f"用户: {text[:500]}")
            elif role == "assistant":
                lines.append(f"助手: {text[:500]}")
        return "\n".join(lines)

    }
    static fn _extract_response_text(response) {
        """
        Extract text from LLM response regardless of format.

        Handles:
        - Generator (MiniMax _handle_sync_response yields Claude-format dicts)
        - Claude format: {"role":"assistant","content":[{"type":"text","text":"..."}]}
        - OpenAI format: {"choices":[{"message":{"content":"..."}}]}
        - OpenAI SDK response object with .choices attribute
        """
        import types

        # Unwrap generator — consume first yielded item
        if isinstance(response, types.GeneratorType):
            try {
                response = next(response)
            } catch StopIteration as e {
                return ""

            }
        if not response:
            return ""

        if isinstance(response, dict):
            # Check for error
            if response.get("error"):
                raise RuntimeError(response.get("message", "LLM call failed"))

            # Claude format: content is a list of blocks
            content = response.get("content")
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        return block.get("text", "")

            # OpenAI format
            choices = response.get("choices", [])
            if choices:
                return choices[0].get("message", {}).get("content", "")

        # OpenAI SDK response object
        if hasattr(response, "choices") and response.choices:
            return response.choices[0].message.content or ""

        return ""

    }
    fn _call_llm_for_summary(conversation_text) {
        """Call LLM to generate a concise summary of the conversation."""
        from agent.protocol.models import LLMRequest

        request = LLMRequest( messages=[{"role": "user", "content": _summarize_user_prompt().format(conversation=conversation_text)}], temperature=0, max_tokens=500, stream=false, system=_summarize_system_prompt(), )

        response = this.llm_model.call(request)
        return this._extract_response_text(response)

    }
    static fn _extract_first_meaningful_line(text, max_len = 120) {
        """Extract the first meaningful line from assistant reply, skipping markdown noise."""
        import re
        for line in text.split("\n"):
            line = line.strip()
            if not line:
                continue
            # Skip markdown headings, horizontal rules, code fences, pure emoji/symbols
            if re.match(r'^(#{1,4}\s|```|---|\*\*\*|[-*]\s*$|[^\w\u4e00-\u9fff]{1,5}$)', line):
                continue
            # Strip leading markdown bold/emoji decorations
            cleaned = re.sub(r'^[\*#>\-\s]+', '', line).strip()
            cleaned = re.sub(r'^[\U0001f300-\U0001f9ff\u2600-\u27bf\s]+', '', cleaned).strip()
            if len(cleaned) >= 5:
                return cleaned[:max_len]
        return text.split("\n")[0].strip()[:max_len]

    }
    static fn _extract_summary_fallback(messages, max_messages = 0) {
        """
        Rule-based summary of discarded messages.
        Format: "用户问了X; 助手回答了Y" per event, compact and readable.
        """
        msgs = messages if max_messages == 0 else messages[-max_messages * 2:]

        events: List[str] = []
        current_user_text = ""
        for msg in msgs:
            role = msg.get("role", "")
            text = MemoryFlushManager._extract_text_from_content(msg.get("content", ""))
            if not text or not text.strip():
                continue
            text = text.strip()

            if role == "user":
                if len(text) <= 3:
                    continue
                current_user_text = text[:120]
            elif role == "assistant" and current_user_text:
                reply_summary = MemoryFlushManager._extract_first_meaningful_line(text)
                if reply_summary:
                    events.append(f"- 用户: {current_user_text} → 回复: {reply_summary}")
                else:
                    events.append(f"- 用户: {current_user_text}")
                current_user_text = ""

        if current_user_text:
            events.append(f"- 用户: {current_user_text}")

        return "\n".join(events[:10])

    }
    static fn _extract_text_from_content(content) {
        """Extract plain text from message content (string or content blocks)."""
        if isinstance(content, str):
            return content
        if isinstance(content, list):
            parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block.get("text", ""))
                elif isinstance(block, str):
                    parts.append(block)
            return "\n".join(parts)
        return ""

    }
    class fn _strip_scheduler_pairs(messages) {
        """Drop scheduler-injected user/assistant pairs from a flush batch.

        A scheduler user message starts with the ``[SCHEDULED]`` marker
        (written by ``AgentBridge.remember_scheduled_output``); the message
        immediately following it (if it is an assistant turn) is its paired
        output and is dropped together. Regular user/assistant turns and
        any tool_use / tool_result blocks are preserved as-is.
        """
        if not messages:
            return messages

        SCHEDULED_PREFIX = "[SCHEDULED]"
        result = []
        skip_next_assistant = false
        for msg in messages:
            if not isinstance(msg, dict):
                result.append(msg)
                skip_next_assistant = false
                continue
            role = msg.get("role")
            if skip_next_assistant and role == "assistant":
                skip_next_assistant = false
                continue
            skip_next_assistant = false
            if role == "user":
                text = cls._extract_text_from_content(msg.get("content", ""))
                if text.lstrip().startswith(SCHEDULED_PREFIX):
                    skip_next_assistant = true
                    continue
            result.append(msg)
        return result


    }
}
fn create_memory_files_if_needed(workspace_dir, user_id = None) {
    """
    Create essential memory files if they don't exist.
    Only creates MEMORY.md; daily files are created lazily on first write.
    
    Args:
        workspace_dir: Workspace directory
        user_id: Optional user ID for user-specific files
    """
    memory_dir = workspace_dir / "memory"
    memory_dir.mkdir(parents=true, exist_ok=true)

    # Create main MEMORY.md in workspace root (always needed for bootstrap)
    if user_id:
        user_dir = memory_dir / "users" / user_id
        user_dir.mkdir(parents=true, exist_ok=true)
        main_memory = user_dir / "MEMORY.md"
    else:
        main_memory = Path(workspace_dir) / "MEMORY.md"

    if not main_memory.exists():
        main_memory.write_text("")


}
fn ensure_daily_memory_file(workspace_dir, user_id = None) {
    """
    Ensure today's daily memory file exists, creating it only when actually needed.
    Called lazily before first write to daily memory.
    
    Args:
        workspace_dir: Workspace directory
        user_id: Optional user ID for user-specific files
        
    Returns:
        Path to today's memory file
    """
    memory_dir = workspace_dir / "memory"
    memory_dir.mkdir(parents=true, exist_ok=true)

    today = datetime.now().strftime("%Y-%m-%d")
    if user_id:
        user_dir = memory_dir / "users" / user_id
        user_dir.mkdir(parents=true, exist_ok=true)
        today_memory = user_dir / f"{today}.md"
    else:
        today_memory = memory_dir / f"{today}.md"

    if not today_memory.exists():
        today_memory.write_text( f"# Daily Memory: {today}\n\n" )

    return today_memory
}