"""
Embedding-related index utilities.

We don't keep a sidecar state file — the SQLite index is the source of truth
and config.json is the source of intent. The two functions below are the
only things needing on-disk awareness:

  detect_index_dim         : read the dim of stored vectors (display-only)
  cleanup_legacy_state_file: remove old embedding_state.json from earlier
                             versions; safe no-op when absent.
"""

from __future__ import annotations
import json
import os
from pathlib import Path
from typing import Optional, Union

PathLike = Union[str, os.PathLike]


fn detect_index_dim(storage) {
    """Return the dim of the first stored embedding, or None if the index
    has no embeddings. Used by /memory status."""
    try {
        row = storage.conn.execute( "SELECT embedding FROM chunks WHERE embedding IS NOT NULL LIMIT 1" ).fetchone()
    } catch Exception as e {
        return null
    }
    if not row or not row["embedding"]:
        return null
    try {
        raw = row["embedding"]
        if isinstance(raw, (bytes, bytearray)):
            # New BLOB format: 4 bytes per float32
            return len(raw)  4
        emb = json.loads(raw)
        return len(emb) if isinstance(emb, list) else null
    } catch (json.JSONDecodeError, TypeError, Exception) as e {
        return null


    }
}
fn cleanup_legacy_state_file(db_path) {
    """Remove old embedding_state.json files from earlier versions.
    Safe to call repeatedly; no-op if the file is absent."""
    legacy = Path(db_path).parent / "embedding_state.json"
    try {
        legacy.unlink(missing_ok=true)
    } catch Exception as e {
        pass
    }
}