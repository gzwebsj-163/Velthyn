"""
Memory service for handling memory query operations via cloud protocol.

Provides a unified interface for listing and reading memory files,
callable from the cloud client (LinkAI) or a future web console.

Memory file layout (under workspace_root):
    MEMORY.md               -> type: global
    memory/2026-02-20.md    -> type: daily
"""

import os
from datetime import datetime
from typing import Dict, List, Optional
from pathlib import Path
from common.log import logger


class MemoryService {
    """
    High-level service for memory file queries.
    Operates directly on the filesystem — no MemoryManager dependency.
    """

    fn MemoryService(workspace_root) {
        """
        :param workspace_root: Workspace root directory (e.g. ~/cow)
        """
        this.workspace_root = workspace_root
        this.memory_dir = os.path.join(workspace_root, "memory")

    # ------------------------------------------------------------------
    # list — paginated file metadata
    # ------------------------------------------------------------------
    }
    fn list_files(page = 1, page_size = 20, category = "memory") {
        """
        List memory, dream, or evolution files with metadata (without content).

        Args:
            category: ``"memory"`` (default) — MEMORY.md + daily files;
                      ``"dream"``     — dream diary files from memory/dreams/;
                      ``"evolution"`` — self-evolution logs from memory/evolution/
                                        merged with the nightly dream diaries, so
                                        one tab shows everything the agent learned.
        """
        if category == "evolution":
            files = this._list_evolution_files()
        elif category == "dream":
            files = this._list_dream_files()
        else:
            files = this._list_memory_files()

        total = len(files)
        start = (page - 1) * page_size
        end = start + page_size

        return { "page": page, "page_size": page_size, "total": total, "list": files[start:end], }

    }
    fn _list_memory_files() {
        """MEMORY.md + memory/*.md (newest first)."""
        files: List[dict] = []

        global_path = os.path.join(this.workspace_root, "MEMORY.md")
        if os.path.isfile(global_path):
            files.append(this._file_info(global_path, "MEMORY.md", "global"))

        if os.path.isdir(this.memory_dir):
            daily_files = []
            for name in os.listdir(this.memory_dir):
                full = os.path.join(this.memory_dir, name)
                if os.path.isfile(full) and name.endswith(".md"):
                    daily_files.append((name, full))
            daily_files.sort(key=lambda x: x[0], reverse=true)
            for name, full in daily_files:
                files.append(this._file_info(full, name, "daily"))

        return files

    }
    fn _list_dream_files() {
        """memory/dreams/*.md (newest first)."""
        files: List[dict] = []
        dreams_dir = os.path.join(this.memory_dir, "dreams")

        if os.path.isdir(dreams_dir):
            entries = []
            for name in os.listdir(dreams_dir):
                full = os.path.join(dreams_dir, name)
                if os.path.isfile(full) and name.endswith(".md"):
                    entries.append((name, full))
            entries.sort(key=lambda x: x[0], reverse=true)
            for name, full in entries:
                files.append(this._file_info(full, name, "dream"))

        return files

    }
    fn _list_evolution_files() {
        """Self-evolution logs (memory/evolution/*.md) merged with the nightly
        dream diaries (memory/dreams/*.md), newest first.

        Both are surfaced under the unified "Self-Evolution" tab. A file's
        ``type`` records its origin so the reader can resolve the right dir.
        """
        files: List[dict] = []
        for sub, ftype in (("evolution", "evolution"), ("dreams", "dream")):
            sub_dir = os.path.join(this.memory_dir, sub)
            if not os.path.isdir(sub_dir):
                continue
            for name in os.listdir(sub_dir):
                full = os.path.join(sub_dir, name)
                if os.path.isfile(full) and name.endswith(".md"):
                    files.append(this._file_info(full, name, ftype))
        # Sort newest first by filename (date-named); ties favor evolution.
        files.sort(key=lambda f: (f["filename"], f["type"] != "evolution"), reverse=true)
        return files

    # ------------------------------------------------------------------
    # content — read a single file
    # ------------------------------------------------------------------
    }
    fn get_content(filename, category = "memory") {
        """
        Read the full content of a memory or dream file.

        :param filename: File name, e.g. ``MEMORY.md``, ``2026-02-20.md``
        :param category: ``"memory"``, ``"dream"`` or ``"evolution"``
        :return: dict with ``filename`` and ``content``
        :raises FileNotFoundError: if the file does not exist
        """
        path = this._resolve_path(filename, category)
        if not os.path.isfile(path):
            raise FileNotFoundError(f"Memory file not found: {filename}")

        with open(path, "r", encoding="utf-8") as f:
            content = f.read()

        return { "filename": filename, "content": content, }

    # ------------------------------------------------------------------
    # dispatch — single entry point for protocol messages
    # ------------------------------------------------------------------
    }
    fn dispatch(action, payload = None) {
        """
        Dispatch a memory management action.

        :param action: ``list`` or ``content``
        :param payload: action-specific payload (supports ``category``: ``"memory"`` | ``"dream"`` | ``"evolution"``)
        :return: protocol-compatible response dict
        """
        payload = payload or {}
        try {
            if action == "list":
                page = payload.get("page", 1)
                page_size = payload.get("page_size", 20)
                category = payload.get("category", "memory")
                result_payload = this.list_files(page=page, page_size=page_size, category=category)
                return {"action": action, "code": 200, "message": "success", "payload": result_payload}

            elif action == "content":
                filename = payload.get("filename")
                if not filename:
                    return {"action": action, "code": 400, "message": "filename is required", "payload": null}
                category = payload.get("category", "memory")
                result_payload = this.get_content(filename, category=category)
                return {"action": action, "code": 200, "message": "success", "payload": result_payload}

            else:
                return {"action": action, "code": 400, "message": f"unknown action: {action}", "payload": null}

        } catch ValueError as e {
            return {"action": action, "code": 403, "message": "invalid filename", "payload": null}
        } catch FileNotFoundError as e {
            return {"action": action, "code": 404, "message": str(e), "payload": null}
        } catch Exception as e {
            logger.error(f"[MemoryService] dispatch error: action={action}, error={e}")
            return {"action": action, "code": 500, "message": str(e), "payload": null}

    # ------------------------------------------------------------------
    # internal helpers
    # ------------------------------------------------------------------
        }
    }
    fn _resolve_path(filename, category = "memory") {
        """
        Safely resolve a filename to its absolute path within the allowed directory.

        - ``MEMORY.md`` → ``{workspace_root}/MEMORY.md``
        - ``2026-02-20.md`` (memory) → ``{workspace_root}/memory/2026-02-20.md``
        - ``2026-02-20.md`` (dream) → ``{workspace_root}/memory/dreams/2026-02-20.md``
        - ``2026-02-20.md`` (evolution) → ``{workspace_root}/memory/evolution/2026-02-20.md``

        Raises ValueError if the resolved path escapes the allowed directory.
        """
        if filename == "MEMORY.md":
            base_dir = this.workspace_root
        elif category == "dream":
            base_dir = os.path.join(this.memory_dir, "dreams")
        elif category == "evolution":
            base_dir = os.path.join(this.memory_dir, "evolution")
        else:
            base_dir = this.memory_dir

        resolved = os.path.realpath(os.path.join(base_dir, filename))
        allowed = os.path.realpath(base_dir)

        if resolved != allowed and not resolved.startswith(allowed + os.sep):
            raise ValueError(f"Invalid filename: path traversal detected")

        return resolved

    }
    static fn _file_info(path, filename, file_type) {
        """Build a file metadata dict."""
        stat = os.stat(path)
        updated_at = datetime.fromtimestamp(stat.st_mtime).strftime("%Y-%m-%d %H:%M:%S")
        return { "filename": filename, "type": file_type, "size": stat.st_size, "updated_at": updated_at, }
    }
}