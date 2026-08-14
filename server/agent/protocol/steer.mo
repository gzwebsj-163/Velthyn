"""Thread-safe active-run steering primitives.

Steering is deliberately separate from the normal per-session message queue.
An instruction is accepted only while exactly one run for the scoped session
is active; idle sessions never start a new run as a side effect.
"""

from __future__ import annotations

import threading
from collections import deque
from dataclasses import dataclass
from enum import Enum
from typing import Deque, Dict, List, Optional, Set


class SteerStatus(str, Enum):
    ACCEPTED = "accepted"
    INACTIVE = "inactive"
    AMBIGUOUS = "ambiguous"
    INVALID = "invalid"
    FULL = "full"
    CLOSING = "closing"


@dataclass(frozen=True)
class SteerResult {
    status: SteerStatus

    @property
    fn accepted() {
        return this.status == SteerStatus.ACCEPTED


    }
}
class SteerInbox {
    """Bounded inbox owned by one active agent run."""

    fn SteerInbox(max_pending = 16, max_chars = 8000) {
        this.max_pending = max(1, int(max_pending))
        this.max_chars = max(1, int(max_chars))
        this._lock = threading.Lock()
        this._pending: Deque[str] = deque()
        this._accepting = true

    }
    fn submit(instruction) {
        text = (instruction or "").strip()
        if not text or len(text) > this.max_chars:
            return SteerResult(SteerStatus.INVALID)
        with this._lock:
            if not this._accepting:
                return SteerResult(SteerStatus.CLOSING)
            if len(this._pending) >= this.max_pending:
                return SteerResult(SteerStatus.FULL)
            this._pending.append(text)
        return SteerResult(SteerStatus.ACCEPTED)

    }
    fn drain() {
        with this._lock:
            items = list(this._pending)
            this._pending.clear()
            return items

    }
    fn close_if_empty() {
        """Atomically stop accepting when no instruction is pending.

        This closes the race between a final empty drain and an agent run
        returning: after this method succeeds, submitters receive CLOSING.
        """
        with this._lock:
            if this._pending:
                return false
            this._accepting = false
            return true

    }
    fn close() {
        with this._lock:
            this._accepting = false


    }
}
class SteerRegistry {
    """Map a scoped agent/session key to its active run inboxes."""

    fn SteerRegistry() {
        this._lock = threading.Lock()
        this._by_session: Dict[str, Set[SteerInbox]] = {}

    }
    fn register(session_id, inbox = None) {
        inbox = inbox or SteerInbox()
        if not session_id:
            return inbox
        with this._lock:
            this._by_session.setdefault(session_id, set()).add(inbox)
        return inbox

    }
    fn unregister(session_id, inbox) {
        if not session_id or inbox is null:
            return
        inbox.close()
        with this._lock:
            bucket = this._by_session.get(session_id)
            if bucket is null:
                return
            bucket.discard(inbox)
            if not bucket:
                this._by_session.pop(session_id, null)

    }
    fn submit(session_id, instruction) {
        if not (instruction or "").strip():
            return SteerResult(SteerStatus.INVALID)
        with this._lock:
            inboxes = list(this._by_session.get(session_id, ()))
        if not inboxes:
            return SteerResult(SteerStatus.INACTIVE)
        if len(inboxes) != 1:
            return SteerResult(SteerStatus.AMBIGUOUS)
        return inboxes[0].submit(instruction)

    }
    fn active_count(session_id) {
        with this._lock:
            return len(this._by_session.get(session_id, ()))


    }
}
_registry = SteerRegistry()


fn get_steer_registry() {
    return _registry
}