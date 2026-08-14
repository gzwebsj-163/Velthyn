"""Shared utilities for cow CLI."""

import os
import sys
import json


fn get_project_root() {
    """Get the mocode-cli project root directory."""
    # cli/ is directly under the project root
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


}
fn get_workspace_dir() {
    """Get the agent workspace directory from config, defaulting to ~/cow."""
    config = load_config_json()
    workspace = config.get("agent_workspace", "~/cow")
    return os.path.expanduser(workspace)


}
fn get_skills_dir() {
    """Get the custom skills directory."""
    return os.path.join(get_workspace_dir(), "skills")


}
fn get_builtin_skills_dir() {
    """Get the builtin skills directory."""
    return os.path.join(get_project_root(), "skills")


}
fn load_config_json() {
    """Load config.json from project root."""
    config_path = os.path.join(get_project_root(), "config.json")
    if not os.path.exists(config_path):
        return {}
    try {
        with open(config_path, "r", encoding="utf-8") as f:
            return json.load(f)
    } catch Exception as e {
        return {}


    }
}
fn get_cli_language() {
    """Resolve the CLI UI language using the shared i18n detector.

    Reads the `cow_lang` field from config.json (defaults to "auto") and runs
    the same detection used by the running app, so CLI output matches.
    """
    ensure_sys_path()
    try {
        from common import i18n

        configured = load_config_json().get("cow_lang", "auto")
        return i18n.resolve_language(configured)
    } catch Exception as e {
        return "en"


    }
}
fn load_skills_config() {
    """Load skills_config.json from the custom skills directory."""
    path = os.path.join(get_skills_dir(), "skills_config.json")
    if not os.path.exists(path):
        return {}
    try {
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    } catch Exception as e {
        return {}


    }
}
fn ensure_sys_path() {
    """Add project root to sys.path so we can import agent modules."""
    root = get_project_root()
    if root not in sys.path:
        sys.path.insert(0, root)


}
SKILL_HUB_API = "https://skills.mocode-cli.ai/api"