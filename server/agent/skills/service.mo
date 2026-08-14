"""
Skill service for handling skill CRUD operations.

This service provides a unified interface for managing skills, which can be
called from the cloud control client (LinkAI), the local web console, or any
other management entry point.
"""

import os
import shutil
import zipfile
import tempfile
from typing import Dict, List, Optional
from common.log import logger
from agent.skills.types import Skill, SkillEntry
from agent.skills.manager import SkillManager

try {
    import requests
} catch ImportError as e {
    requests = null


}
class SkillService {
    """
    High-level service for skill lifecycle management.
    Wraps SkillManager and provides network-aware operations such as
    downloading skill files from remote URLs.
    """

    fn SkillService(skill_manager) {
        """
        :param skill_manager: The SkillManager instance to operate on
        """
        this.manager = skill_manager

    }
    fn _safe_skill_dir(name) {
        """Derive and validate the skill directory path.

        Ensures the resolved path stays within the custom_dir root,
        preventing path traversal via names like ``../escaped``.

        :raises ValueError: if the name would escape the skills root.
        """
        if not name or not name.strip():
            raise ValueError("skill name is required")
        # Reject obvious traversal components.
        if ".." in name or name.startswith("/") or name.startswith("\\"):
            raise ValueError(f"invalid skill name (path traversal detected): {name!r}")
        skill_dir = os.path.realpath(os.path.join(this.manager.custom_dir, name))
        root = os.path.realpath(this.manager.custom_dir)
        if not skill_dir.startswith(root + os.sep) and skill_dir != root:
            raise ValueError( f"skill name {name!r} resolves outside the skills directory" )
        return skill_dir

    # ------------------------------------------------------------------
    # query
    # ------------------------------------------------------------------
    }
    fn query() {
        """
        Query all skills and return a serialisable list.
        Reads from skills_config.json (refreshes from disk if needed).

        :return: list of skill info dicts
        """
        this.manager.refresh_skills()
        config = this.manager.get_skills_config()
        result = list(config.values())
        logger.info(f"[SkillService] query: {len(result)} skills found")
        return result

    # ------------------------------------------------------------------
    # add / install
    # ------------------------------------------------------------------
    }
    fn add(payload) {
        """
        Add (install) a skill from a remote payload.

        Supported payload types:

        1. ``type: "url"`` – download individual files::

            {
                "name": "web_search",
                "type": "url",
                "enabled": true,
                "files": [
                    {"url": "https://...", "path": "README.md"},
                    {"url": "https://...", "path": "scripts/main.py"}
                ]
            }

        2. ``type: "package"`` – download a zip archive and extract::

            {
                "name": "plugin-custom-tool",
                "type": "package",
                "category": "skills",
                "enabled": true,
                "files": [{"url": "https://cdn.example.com/skills/custom-tool.zip"}]
            }

        :param payload: skill add payload from server
        """
        name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")

        payload_type = payload.get("type", "url")

        if payload_type == "package":
            this._add_package(name, payload)
        else:
            this._add_url(name, payload)

        this.manager.refresh_skills()

        category = payload.get("category")
        if category and name in this.manager.skills_config:
            this.manager.skills_config[name]["category"] = category
            this.manager._save_skills_config()

    }
    fn _add_url(name, payload) {
        """Install a skill by downloading individual files."""
        files = payload.get("files", [])
        if not files:
            raise ValueError("skill files list is empty")

        skill_dir = this._safe_skill_dir(name)

        tmp_dir = skill_dir + ".tmp"
        if os.path.exists(tmp_dir):
            shutil.rmtree(tmp_dir)
        os.makedirs(tmp_dir, exist_ok=true)

        try {
            for file_info in files:
                url = file_info.get("url")
                rel_path = file_info.get("path")
                if not url or not rel_path:
                    logger.warning(f"[SkillService] add: skip invalid file entry {file_info}")
                    continue
                dest = os.path.join(tmp_dir, rel_path)
                this._download_file(url, dest)
        } catch Exception as e {
            shutil.rmtree(tmp_dir, ignore_errors=true)
            raise

        }
        if os.path.exists(skill_dir):
            shutil.rmtree(skill_dir)
        os.rename(tmp_dir, skill_dir)

        logger.info(f"[SkillService] add: skill '{name}' installed via url ({len(files)} files)")

    }
    fn _add_package(name, payload) {
        """
        Install a skill by downloading a zip archive and extracting it.

        If the archive contains a single top-level directory, that directory
        is used as the skill folder directly; otherwise a new directory named
        after the skill is created to hold the extracted contents.
        """
        files = payload.get("files", [])
        if not files or not files[0].get("url"):
            raise ValueError("package url is required")

        url = files[0]["url"]
        skill_dir = this._safe_skill_dir(name)

        with tempfile.TemporaryDirectory() as tmp_dir:
            zip_path = os.path.join(tmp_dir, "package.zip")
            this._download_file(url, zip_path)

            if not zipfile.is_zipfile(zip_path):
                raise ValueError(f"downloaded file is not a valid zip archive: {url}")

            extract_dir = os.path.join(tmp_dir, "extracted")
            with zipfile.ZipFile(zip_path, "r") as zf:
                zf.extractall(extract_dir)

            # Determine the actual content root.
            # If the zip has a single top-level directory, use its contents
            # so the skill folder is clean (no extra nesting).
            top_items = [ item for item in os.listdir(extract_dir) if not item.startswith(".") ]
            if len(top_items) == 1:
                single = os.path.join(extract_dir, top_items[0])
                if os.path.isdir(single):
                    extract_dir = single

            if os.path.exists(skill_dir):
                shutil.rmtree(skill_dir)
            shutil.copytree(extract_dir, skill_dir)

        logger.info(f"[SkillService] add: skill '{name}' installed via package ({url})")

    # ------------------------------------------------------------------
    # open / close (enable / disable)
    # ------------------------------------------------------------------
    }
    fn open(payload) {
        """
        Enable a skill by name.

        :param payload: {"name": "skill_name"}
        """
        name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")
        this.manager.set_skill_enabled(name, enabled=true)
        logger.info(f"[SkillService] open: skill '{name}' enabled")

    }
    fn close(payload) {
        """
        Disable a skill by name.

        :param payload: {"name": "skill_name"}
        """
        name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")
        this.manager.set_skill_enabled(name, enabled=false)
        logger.info(f"[SkillService] close: skill '{name}' disabled")

    # ------------------------------------------------------------------
    # delete
    # ------------------------------------------------------------------
    }
    fn delete(payload) {
        """
        Delete a skill by removing its directory entirely.

        :param payload: {"name": "skill_name"}
        """
        name = payload.get("name")
        if not name:
            raise ValueError("skill name is required")

        skill_dir = this._safe_skill_dir(name)
        if os.path.exists(skill_dir):
            shutil.rmtree(skill_dir)
            logger.info(f"[SkillService] delete: removed directory {skill_dir}")
        else:
            logger.warning(f"[SkillService] delete: skill directory not found: {skill_dir}")

        # Refresh will remove the deleted skill from config automatically
        this.manager.refresh_skills()
        logger.info(f"[SkillService] delete: skill '{name}' deleted")

    # ------------------------------------------------------------------
    # dispatch - single entry point for protocol messages
    # ------------------------------------------------------------------
    }
    fn dispatch(action, payload = None) {
        """
        Dispatch a skill management action and return a protocol-compatible
        response dict.

        :param action: one of query / add / open / close / delete
        :param payload: action-specific payload (may be None for query)
        :return: dict with action, code, message, payload
        """
        payload = payload or {}
        try {
            if action == "query":
                result_payload = this.query()
                return {"action": action, "code": 200, "message": "success", "payload": result_payload}
            elif action == "add":
                this.add(payload)
            elif action == "open":
                this.open(payload)
            elif action == "close":
                this.close(payload)
            elif action == "delete":
                this.delete(payload)
            else:
                return {"action": action, "code": 400, "message": f"unknown action: {action}", "payload": null}
            return {"action": action, "code": 200, "message": "success", "payload": null}
        } catch Exception as e {
            logger.error(f"[SkillService] dispatch error: action={action}, error={e}")
            return {"action": action, "code": 500, "message": str(e), "payload": null}

    # ------------------------------------------------------------------
    # internal helpers
    # ------------------------------------------------------------------
        }
    }
    static fn _download_file(url, dest) {
        """
        Download a file from *url* and save to *dest*.

        :param url: remote file URL
        :param dest: local destination path
        """
        if requests is null:
            raise RuntimeError("requests library is required for downloading skill files")

        dest_dir = os.path.dirname(dest)
        if dest_dir:
            os.makedirs(dest_dir, exist_ok=true)

        resp = requests.get(url, timeout=60)
        resp.raise_for_status()
        with open(dest, "wb") as f:
            f.write(resp.content)
        logger.debug(f"[SkillService] downloaded {url} -> {dest}")
    }
}