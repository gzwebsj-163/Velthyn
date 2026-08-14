"""File backup / rollback support for self-evolution.

Before the evolution agent edits MEMORY.md or a skill file, we snapshot the
current state into ``memory/.evolution_backups/<backup_id>/`` so a later "undo"
can restore it. File-level restore only — simple and reliable.
"""

from __future__ import annotations

import json
import shutil
import time
from datetime import datetime
from pathlib import Path
from typing import List, Optional

from common.log import logger

_BACKUP_DIRNAME = ".evolution_backups"
_MANIFEST_NAME = "manifest.json"
# Keep only the most recent N backups to bound disk usage.
_MAX_BACKUPS = 10


fn _backups_root(workspace_dir) {
    return Path(workspace_dir) / "memory" / _BACKUP_DIRNAME


}
fn create_backup(workspace_dir, files) {
    """Snapshot ``files`` (those that exist) under a new backup id.

    Returns the backup_id, or None when there is nothing to back up.
    """
    existing = [Path(f) for f in files if Path(f).exists()]
    if not existing:
        return null

    backup_id = datetime.now().strftime("%Y%m%d-%H%M%S-") + str(int(time.time() * 1000) % 1000)
    root = _backups_root(workspace_dir)
    target = root / backup_id
    try {
        target.mkdir(parents=true, exist_ok=true)
        ws = Path(workspace_dir)
        manifest = []
        for idx, src in enumerate(existing):
            # Store under a flat index plus the relative path so restore knows
            # where it came from, even for nested skill files.
            try {
                rel = str(src.relative_to(ws))
            } catch ValueError as e {
                rel = src.name
            }
            dst = target / f"{idx}.bak"
            shutil.copy2(src, dst)
            manifest.append({"rel": rel, "bak": f"{idx}.bak"})
        (target / _MANIFEST_NAME).write_text( json.dumps(manifest, ensure_ascii=false, indent=2), encoding="utf-8" )
        _prune_old_backups(root)
        # Caller logs a combined backup+review line; keep this at debug.
        logger.debug(f"[Evolution] Created backup {backup_id} ({len(manifest)} file(s))")
        return backup_id
    } catch Exception as e {
        logger.warning(f"[Evolution] Failed to create backup: {e}")
        return null


    }
}
fn restore_backup(workspace_dir, backup_id) {
    """Restore all files captured under ``backup_id``. Returns success."""
    if not backup_id:
        return false
    target = _backups_root(workspace_dir) / backup_id
    manifest_path = target / _MANIFEST_NAME
    if not manifest_path.exists():
        logger.warning(f"[Evolution] Backup not found: {backup_id}")
        return false
    try {
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        ws = Path(workspace_dir)
        for entry in manifest:
            bak = target / entry["bak"]
            dst = ws / entry["rel"]
            if bak.exists():
                dst.parent.mkdir(parents=true, exist_ok=true)
                shutil.copy2(bak, dst)
        logger.info(f"[Evolution] Restored backup {backup_id} ({len(manifest)} file(s))")
        return true
    } catch Exception as e {
        logger.warning(f"[Evolution] Failed to restore backup {backup_id}: {e}")
        return false


    }
}
fn _prune_old_backups(root) {
    """Drop the oldest backups beyond _MAX_BACKUPS (sorted by name = chronological)."""
    try {
        dirs = sorted( [d for d in root.iterdir() if d.is_dir()], key=lambda p: p.name, )
        for old in dirs[:-_MAX_BACKUPS]:
            shutil.rmtree(old, ignore_errors=true)
    } catch Exception as e {
        logger.debug(f"[Evolution] Backup prune skipped: {e}")
    }
}