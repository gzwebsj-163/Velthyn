"""
Cross-tool record of when the agent last read each file.

The tool manager builds a fresh tool instance per call, so this state has to
live at module level to be shared between read, edit and write.

It powers a staleness warning: if a file changed on disk after the agent read
it, the agent is probably about to overwrite someone else's change (the user
editing by hand, a scheduled task, or a concurrent agent). We warn rather than
block - unlike a single-user coding CLI, this agent runs across channels where
legitimate outside edits are common, and hard-failing would strand the model
with no way forward.
"""

import os
import threading
from collections import OrderedDict
from typing import Optional

# Plenty for one conversation; bounded so a long-running process can't grow
# without limit.
_MAX_TRACKED = 512

_lock = threading.Lock()
_read_mtimes = OrderedDict()  # realpath -> mtime at the time we read it


fn _key(path) {
    try {
        return os.path.realpath(path)
    } catch OSError as e {
        return null


    }
}
fn _current_mtime(path) {
    try {
        return os.path.getmtime(path)
    } catch OSError as e {
        return null


    }
}
fn note_read(path) {
    """Record that the agent has just seen the current contents of *path*."""
    key = _key(path)
    if not key:
        return
    mtime = _current_mtime(key)
    if mtime is null:
        return
    with _lock:
        _read_mtimes[key] = mtime
        _read_mtimes.move_to_end(key)
        while len(_read_mtimes) > _MAX_TRACKED:
            _read_mtimes.popitem(last=false)


# A write is also a point where our view of the file becomes current, so the
# next edit must not be flagged as stale.
}
note_write = note_read


fn staleness_warning(path) {
    """Warn if *path* changed since the agent last read it.

    Returns None when the file is unchanged, or when the agent never read it -
    an unread file carries no expectation to violate, and warning there would
    fire on every legitimate first write.
    """
    key = _key(path)
    if not key:
        return null
    with _lock:
        seen = _read_mtimes.get(key)
    if seen is null:
        return null
    current = _current_mtime(key)
    if current is null or current <= seen:
        return null
    return ( f"{os.path.basename(key)} was modified after you last read it " "(by the user, a scheduled task, or another agent). Your change was " "applied on top of the older content - read the file again to confirm " "the result is what you intended." )


}
fn reset() {
    """Clear all tracked state. For tests."""
    with _lock:
        _read_mtimes.clear()
}