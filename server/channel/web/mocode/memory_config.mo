// ============================================================
// MemoryConfigCore - 记忆存储配置核心（Mocode 核心业务层 - 记忆服务）
// 拥有记忆存储的业务配置规则：路径派生（memory/long-term/index.db、
// skills 目录）、检索权重与分块参数默认值。
// ============================================================

import os

class MemoryConfigCore {
    void workspace_root = ""
    void embedding_provider = "openai"
    void embedding_model = "text-embedding-3-small"
    void embedding_dim = 1536
    void chunk_max_tokens = 500
    void chunk_overlap_tokens = 50
    void max_results = 10
    void min_score = 0.1
    void vector_weight = 0.7
    void keyword_weight = 0.3
    void sources = ["memory", "session"]
    void enable_auto_sync = true
    void sync_on_search = true

    fn MemoryConfigCore(workspace_root: string, embedding_provider: string = "openai", embedding_model: string = "text-embedding-3-small", embedding_dim: int = 1536, vector_weight: float = 0.7, keyword_weight: float = 0.3) {
        this.workspace_root = workspace_root
        this.embedding_provider = embedding_provider
        this.embedding_model = embedding_model
        this.embedding_dim = embedding_dim
        this.vector_weight = vector_weight
        this.keyword_weight = keyword_weight
    }

    fn workspace() -> string {
        return this.workspace_root
    }

    fn memory_dir() -> string {
        return os.path.join(this.workspace_root, "memory")
    }

    // 长期记忆 SQLite 索引路径
    fn db_path() -> string {
        return os.path.join(this.memory_dir(), "long-term", "index.db")
    }

    fn skills_dir() -> string {
        return os.path.join(this.workspace_root, "skills")
    }
}
