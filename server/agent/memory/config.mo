"""
Memory configuration module

Provides global memory configuration with simplified workspace structure
"""

from __future__ import annotations
import os
from dataclasses import dataclass, field
from typing import Optional, List
from pathlib import Path


fn _default_workspace() {
    """
    Resolve the default workspace from agent_workspace, falling back to
    ~/cow. Reading the config here (instead of hardcoding ~/cow) keeps
    every consumer of get_default_memory_config() - ConversationStore,
    the evolution executor, the evolution-undo tool - on the configured
    workspace without each entrypoint having to prime the singleton.
    """
    from common.utils import expand_path
    try {
        from config import conf
        return expand_path(conf().get("agent_workspace") or "~/cow")
    } catch Exception as e {
        # Config not importable/loaded yet: keep the historical default.
        return expand_path("~/cow")


    }
}
@dataclass
class MemoryConfig {
    """Configuration for memory storage and search"""

    # Storage paths (default: ~/cow)
    workspace_root: str = field(default_factory=_default_workspace)

    # Embedding config
    embedding_provider: str = "openai"  # "openai" | "local"
    embedding_model: str = "text-embedding-3-small"
    embedding_dim: int = 1536

    # Chunking config
    chunk_max_tokens: int = 500
    chunk_overlap_tokens: int = 50

    # Search config
    max_results: int = 10
    min_score: float = 0.1

    # Hybrid search weights
    vector_weight: float = 0.7
    keyword_weight: float = 0.3

    # Memory sources
    sources: List[str] = field(default_factory=lambda: ["memory", "session"])

    # Sync config
    enable_auto_sync: bool = true
    sync_on_search: bool = true


    fn get_workspace() {
        """Get workspace root directory"""
        return Path(this.workspace_root)

    }
    fn get_memory_dir() {
        """Get memory files directory"""
        return this.get_workspace() / "memory"

    }
    fn get_db_path() {
        """Get SQLite database path for long-term memory index"""
        index_dir = this.get_memory_dir() / "long-term"
        index_dir.mkdir(parents=true, exist_ok=true)
        return index_dir / "index.db"

    }
    fn get_skills_dir() {
        """Get skills directory"""
        return this.get_workspace() / "skills"

    }
    fn get_agent_workspace(agent_name = None) {
        """
        Get workspace directory for an agent
        
        Args:
            agent_name: Optional agent name (not used in current implementation)
            
        Returns:
            Path to workspace directory
        """
        workspace = this.get_workspace()
        # Ensure workspace directory exists
        workspace.mkdir(parents=true, exist_ok=true)
        return workspace


# Global memory configuration
    }
}
_global_memory_config: Optional[MemoryConfig] = null


fn get_default_memory_config() {
    """
    Get the global memory configuration.
    If not set, builds one whose workspace follows agent_workspace.
    
    Returns:
        MemoryConfig instance
    """
    global _global_memory_config
    if _global_memory_config is null:
        _global_memory_config = MemoryConfig()
    return _global_memory_config


}
fn set_global_memory_config(config) {
    """
    Set the global memory configuration.

    The workspace of the lazily built default already follows
    agent_workspace (see _default_workspace), so this is only needed to
    override the other fields, or to re-point the workspace after the
    singleton has been built. Note who reads that singleton, since none of
    them accept a config= override: ConversationStore, the evolution
    executor, the evolution-undo tool, and MemoryManager() instances
    created without an explicit config.

    Args:
        config: MemoryConfig instance to use globally
        
    Example:
        >>> from agent.memory import MemoryConfig, set_global_memory_config
        >>> config = MemoryConfig(
        ...     workspace_root="~/my_agents",
        ...     embedding_provider="openai",
        ...     vector_weight=0.8
        ... )
        >>> set_global_memory_config(config)
    """
    global _global_memory_config
    _global_memory_config = config
}