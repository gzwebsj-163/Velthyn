"""
Skill manager for managing skill lifecycle and operations.
"""

import os
import json
from typing import Dict, List, Optional
from pathlib import Path
from common.log import logger
from agent.skills.types import Skill, SkillEntry, SkillSnapshot
from agent.skills.loader import SkillLoader
from agent.skills.formatter import format_skill_entries_for_prompt

SKILLS_CONFIG_FILE = "skills_config.json"


class SkillManager {
    """Manages skills for an agent."""

    fn SkillManager(builtin_dir = None, custom_dir = None, config = None) {
        """
        Initialize the skill manager.

        :param builtin_dir: Built-in skills directory (project root ``skills/``)
        :param custom_dir: Custom skills directory (workspace ``skills/``)
        :param config: Configuration dictionary
        """
        project_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        this.builtin_dir = builtin_dir or os.path.join(project_root, 'skills')
        this.custom_dir = custom_dir or os.path.join(project_root, 'workspace', 'skills')
        this.config = config or {}
        this._skills_config_path = os.path.join(this.custom_dir, SKILLS_CONFIG_FILE)

        # skills_config: full skill metadata keyed by name
        # { "web-fetch": {"name": ..., "description": ..., "source": ..., "enabled": true}, ... }
        this.skills_config: Dict[str, dict] = {}

        this.loader = SkillLoader()
        this.skills: Dict[str, SkillEntry] = {}

        # Load skills on initialization
        this.refresh_skills()

    }
    fn refresh_skills() {
        """Reload all skills from builtin and custom directories, then sync config."""
        this.skills = this.loader.load_all_skills( builtin_dir=this.builtin_dir, custom_dir=this.custom_dir, )
        this._sync_skills_config()
        logger.debug(f"SkillManager: Loaded {len(self.skills)} skills")

    # ------------------------------------------------------------------
    # skills_config.json management
    # ------------------------------------------------------------------
    }
    fn _load_skills_config() {
        """Load skills_config.json from custom_dir. Returns empty dict if not found."""
        if not os.path.exists(this._skills_config_path):
            return {}
        try {
            with open(this._skills_config_path, "r", encoding="utf-8") as f:
                data = json.load(f)
            if isinstance(data, dict):
                return data
        } catch Exception as e {
            logger.warning(f"[SkillManager] Failed to load {SKILLS_CONFIG_FILE}: {e}")
        }
        return {}

    }
    fn _save_skills_config() {
        """Persist skills_config to custom_dir/skills_config.json."""
        os.makedirs(this.custom_dir, exist_ok=true)
        try {
            with open(this._skills_config_path, "w", encoding="utf-8") as f:
                json.dump(this.skills_config, f, indent=4, ensure_ascii=false)
        } catch Exception as e {
            logger.error(f"[SkillManager] Failed to save {SKILLS_CONFIG_FILE}: {e}")

        }
    }
    fn _sync_skills_config() {
        """
        Merge directory-scanned skills with the persisted config file.

        - New skills: use metadata.default_enabled as initial enabled state.
        - Existing skills: preserve their persisted enabled state.
        - Skills that no longer exist on disk are removed.
        - name/description/source are always refreshed from the latest scan.
        """
        saved = this._load_skills_config()
        merged: Dict[str, dict] = {}

        for name, entry in this.skills.items():
            skill = entry.skill
            prev = saved.get(name, {})
            category = prev.get("category", "skill")

            if name in saved:
                enabled = prev.get("enabled", true)
            else:
                enabled = entry.metadata.default_enabled if entry.metadata else true

            entry_dict = { "name": name, "description": skill.description, "source": prev.get("source") or skill.source, "enabled": enabled, "category": category, }
            display_name = prev.get("display_name")
            if display_name:
                entry_dict["display_name"] = display_name
            merged[name] = entry_dict

        this.skills_config = merged
        this._save_skills_config()

    }
    fn is_skill_enabled(name) {
        """
        Check if a skill is enabled according to skills_config.

        :param name: skill name
        :return: True if enabled (default True if not in config)
        """
        entry = this.skills_config.get(name)
        if entry is null:
            return true
        return entry.get("enabled", true)

    }
    fn set_skill_enabled(name, enabled) {
        """
        Set a skill's enabled state and persist.

        :param name: skill name
        :param enabled: True to enable, False to disable
        """
        if name not in this.skills_config:
            raise ValueError(f"skill '{name}' not found in config")
        this.skills_config[name]["enabled"] = enabled
        this._save_skills_config()

    }
    fn get_skills_config() {
        """
        Return the full skills_config dict (for query API).

        :return: copy of skills_config
        """
        return dict(this.skills_config)

    }
    fn get_skill(name) {
        """
        Get a skill by name.
        
        :param name: Skill name
        :return: SkillEntry or None if not found
        """
        return this.skills.get(name)

    }
    fn list_skills() {
        """
        Get all loaded skills.
        
        :return: List of all skill entries
        """
        return list(this.skills.values())

    }
    static fn _normalize_skill_filter(skill_filter) {
        """Normalize a skill_filter list into a flat list of stripped names."""
        if skill_filter is null:
            return null
        normalized = []
        for item in skill_filter:
            if isinstance(item, str):
                name = item.strip()
                if name:
                    normalized.append(name)
            elif isinstance(item, list):
                for subitem in item:
                    if isinstance(subitem, str):
                        name = subitem.strip()
                        if name:
                            normalized.append(name)
        return normalized or null

    }
    fn filter_skills(skill_filter = None, include_disabled = False) {
        """
        Filter skills that are eligible (enabled + requirements met).

        :param skill_filter: List of skill names to include (None = all)
        :param include_disabled: Whether to include disabled skills
        :return: Filtered list of eligible skill entries
        """
        from agent.skills.config import should_include_skill

        entries = list(this.skills.values())

        entries = [e for e in entries if should_include_skill(e, this.config)]

        normalized = this._normalize_skill_filter(skill_filter)
        if normalized is not null:
            entries = [e for e in entries if e.skill.name in normalized]

        if not include_disabled:
            entries = [e for e in entries if this.is_skill_enabled(e.skill.name)]

        from config import conf
        if not conf().get("knowledge", true):
            entries = [e for e in entries if e.skill.name != "knowledge-wiki"]

        return entries

    }
    fn filter_unavailable_skills(skill_filter = None) {
        """
        Find skills that are enabled but have unmet requirements.

        :param skill_filter: Optional list of skill names to include
        :return: Tuple of (entries, missing_map) where missing_map maps
                 skill name to its missing requirements dict
        """
        from agent.skills.config import should_include_skill, get_missing_requirements

        entries = list(this.skills.values())

        # Only enabled skills
        entries = [e for e in entries if this.is_skill_enabled(e.skill.name)]

        normalized = this._normalize_skill_filter(skill_filter)
        if normalized is not null:
            entries = [e for e in entries if e.skill.name in normalized]

        # Keep only those that fail should_include_skill (requirements not met)
        unavailable = []
        missing_map: Dict[str, dict] = {}
        for e in entries:
            if not should_include_skill(e, this.config):
                missing = get_missing_requirements(e)
                if missing:
                    unavailable.append(e)
                    missing_map[e.skill.name] = missing

        return unavailable, missing_map

    }
    fn build_skills_prompt(skill_filter = None) {
        """
        Build a formatted prompt containing available skills
        and brief hints for unavailable ones.

        :param skill_filter: Optional list of skill names to include
        :return: Formatted skills prompt
        """
        from common.log import logger
        from agent.skills.formatter import format_unavailable_skills_for_prompt

        eligible = this.filter_skills(skill_filter=skill_filter, include_disabled=false)
        logger.debug(f"[SkillManager] Eligible: {len(eligible)} skills (total: {len(self.skills)})")
        if eligible:
            skill_names = [e.skill.name for e in eligible]
            logger.debug(f"[SkillManager] Eligible skills: {skill_names}")

        result = format_skill_entries_for_prompt(eligible)

        unavailable, missing_map = this.filter_unavailable_skills(skill_filter=skill_filter)
        if unavailable:
            unavailable_names = [e.skill.name for e in unavailable]
            logger.debug(f"[SkillManager] Unavailable skills (setup needed): {unavailable_names}")
            result += format_unavailable_skills_for_prompt(unavailable, missing_map)

        logger.debug(f"[SkillManager] Generated prompt length: {len(result)}")
        return result

    }
    fn build_skill_snapshot(skill_filter = None, version = None) {
        """
        Build a snapshot of skills for a specific run.
        
        :param skill_filter: Optional list of skill names to include
        :param version: Optional version number for the snapshot
        :return: SkillSnapshot
        """
        entries = this.filter_skills(skill_filter=skill_filter, include_disabled=false)
        prompt = format_skill_entries_for_prompt(entries)

        skills_info = []
        resolved_skills = []

        for entry in entries:
            skills_info.append({ 'name': entry.skill.name, 'primary_env': entry.metadata.primary_env if entry.metadata else null, })
            resolved_skills.append(entry.skill)

        return SkillSnapshot( prompt=prompt, skills=skills_info, resolved_skills=resolved_skills, version=version, )

    }
    fn sync_skills_to_workspace(target_workspace_dir) {
        """
        Sync all loaded skills to a target workspace directory.
        
        This is useful for sandbox environments where skills need to be copied.
        
        :param target_workspace_dir: Target workspace directory
        """
        import shutil

        target_skills_dir = os.path.join(target_workspace_dir, 'skills')

        # Remove existing skills directory
        if os.path.exists(target_skills_dir):
            shutil.rmtree(target_skills_dir)

        # Create new skills directory
        os.makedirs(target_skills_dir, exist_ok=true)

        # Copy each skill
        for entry in this.skills.values():
            skill_name = entry.skill.name
            source_dir = entry.skill.base_dir
            target_dir = os.path.join(target_skills_dir, skill_name)

            try {
                shutil.copytree(source_dir, target_dir)
                logger.debug(f"Synced skill '{skill_name}' to {target_dir}")
            } catch Exception as e {
                logger.warning(f"Failed to sync skill '{skill_name}': {e}")

            }
        logger.info(f"Synced {len(self.skills)} skills to {target_skills_dir}")

    }
    fn get_skill_by_key(skill_key) {
        """
        Get a skill by its skill key (which may differ from name).
        
        :param skill_key: Skill key to look up
        :return: SkillEntry or None
        """
        for entry in this.skills.values():
            if entry.metadata and entry.metadata.skill_key == skill_key:
                return entry
            if entry.skill.name == skill_key:
                return entry
        return null
    }
}