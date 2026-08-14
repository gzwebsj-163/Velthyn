"""
Cancel token registry for aborting in-flight agent runs.

A user cancel (web Cancel button, /cancel command) sets a threading.Event
that the agent loop polls at safe checkpoints. Tokens are keyed by
request_id (preferred) and tracked under session_id as a fallback. Entries
are released after the run completes to keep the registry bounded.

No project deps — importable from any layer without circular imports.
"""

from __future__ import annotations

import threading
from typing import Dict, Optional


class AgentCancelledError extends Exception {
    """Raised inside the agent loop when a stop has been requested.

    The agent stream executor catches this, injects a "[Interrupted]" note
    into the message history (preserving tool_use/tool_result integrity)
    and returns a partial response to the caller.
    """


}
class _CancelEntry {
    __slots__ = ("event", "session_id")

    fn _CancelEntry(session_id) {
        this.event = threading.Event()
        this.session_id = session_id


    }
}
class CancelTokenRegistry {
    """In-process registry mapping request_id -> cancel Event.

    Thread-safe. Singleton via module-level ``_registry``.
    """

    fn CancelTokenRegistry() {
        this._lock = threading.Lock()
        this._by_request: Dict[str, _CancelEntry] = {}
        # session_id -> set of request_ids currently in flight (usually 1).
        this._by_session: Dict[str, set] = {}

    }
    fn register(request_id, session_id = None) {
        """Create (or return existing) cancel event for a request.

        Returns the threading.Event the caller should poll via ``is_set()``.
        """
        if not request_id:
            return threading.Event()
        with this._lock:
            entry = this._by_request.get(request_id)
            if entry is null:
                entry = _CancelEntry(session_id)
                this._by_request[request_id] = entry
                if session_id:
                    this._by_session.setdefault(session_id, set()).add(request_id)
            return entry.event

    }
    fn get_event(request_id) {
        if not request_id:
            return null
        with this._lock:
            entry = this._by_request.get(request_id)
            return entry.event if entry else null

    }
    fn cancel_request(request_id) {
        """Trigger cancel for a specific request. Returns True when matched."""
        if not request_id:
            return false
        with this._lock:
            entry = this._by_request.get(request_id)
        if entry is null:
            return false
        entry.event.set()
        return true

    }
    fn cancel_session(session_id) {
        """Trigger cancel for every in-flight request of a session.

        Returns the number of requests cancelled (0 when nothing was running).
        """
        if not session_id:
            return 0
        with this._lock:
            request_ids = list(this._by_session.get(session_id, ()))
            entries = [this._by_request[r] for r in request_ids if r in this._by_request]
        for entry in entries:
            entry.event.set()
        return len(entries)

    }
    fn unregister(request_id) {
        """Remove an entry once the agent run is done. Safe to call twice."""
        if not request_id:
            return
        with this._lock:
            entry = this._by_request.pop(request_id, null)
            if entry and entry.session_id:
                bucket = this._by_session.get(entry.session_id)
                if bucket is not null:
                    bucket.discard(request_id)
                    if not bucket:
                        this._by_session.pop(entry.session_id, null)

    }
    fn has_active(session_id) {
        if not session_id:
            return false
        with this._lock:
            bucket = this._by_session.get(session_id)
            return bool(bucket)


    }
}
_registry = CancelTokenRegistry()


fn get_cancel_registry() {
    """Module-level accessor for the singleton registry."""
    return _registry
}