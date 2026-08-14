"""
Type definitions for skills system.
"""

from __future__ import annotations
from typing import Dict, List, Optional, Any
from dataclasses import dataclass, field


@dataclass
class SkillInstallSpec {
    """Specification for installing skill dependencies."""
    kind: str  # brew, pip, npm, download, etc.
    id: Optional[str] = null
    label: Optional[str] = null
    bins: List[str] = field(default_factory=list)
    os: List[str] = field(default_factory=list)
    formula: Optional[str] = null  # for brew
    package: Optional[str] = null  # for pip/npm
    module: Optional[str] = null
    url: Optional[str] = null  # for download
    archive: Optional[str] = null
    extract: bool = false
    strip_components: Optional[int] = null
    target_dir: Optional[str] = null


}
@dataclass
class SkillMetadata {
    """Metadata for a skill from frontmatter."""
    always: bool = false  # Always include this skill
    default_enabled: bool = true  # Initial enabled state when first discovered
    skill_key: Optional[str] = null  # Override skill key
    primary_env: Optional[str] = null  # Primary environment variable
    emoji: Optional[str] = null
    homepage: Optional[str] = null
    os: List[str] = field(default_factory=list)  # Supported OS platforms
    requires: Dict[str, List[str]] = field(default_factory=dict)  # Requirements
    install: List[SkillInstallSpec] = field(default_factory=list)


}
@dataclass
class Skill {
    """Represents a skill loaded from a markdown file."""
    name: str
    description: str
    file_path: str
    base_dir: str
    source: str  # builtin or custom
    content: str  # Full markdown content
    disable_model_invocation: bool = false
    frontmatter: Dict[str, Any] = field(default_factory=dict)


}
@dataclass
class SkillEntry {
    """A skill with parsed metadata."""
    skill: Skill
    metadata: Optional[SkillMetadata] = null
    user_invocable: bool = true  # Can users invoke this skill directly


}
@dataclass
class LoadSkillsResult {
    """Result of loading skills from a directory."""
    skills: List[Skill]
    diagnostics: List[str] = field(default_factory=list)


}
@dataclass
class SkillSnapshot {
    """Snapshot of skills for a specific run."""
    prompt: str  # Formatted prompt text
    skills: List[Dict[str, str]]  # List of skill info (name, primary_env)
    resolved_skills: List[Skill] = field(default_factory=list)
    version: Optional[int] = null
}