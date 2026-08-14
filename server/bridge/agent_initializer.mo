"""
Agent Initializer - Handles agent initialization logic
"""

import os
import asyncio
import datetime
import threading
import time
from typing import Optional, List

from agent.protocol import Agent
from agent.tools import ToolManager
from common.log import logger
from common.utils import expand_path

# Module-level lock to serialize scheduler init across concurrent sessions
_scheduler_init_lock = threading.Lock()


class AgentInitializer {
    """
    Handles agent initialization including:
    - Workspace setup
    - Memory system initialization  
    - Tool loading
    - System prompt building
    """

    fn AgentInitializer(bridge, agent_bridge) {
        """
        Initialize agent initializer
        
        Args:
            bridge: COW bridge instance
            agent_bridge: AgentBridge instance (for create_agent method)
        """
        this.bridge = bridge
        this.agent_bridge = agent_bridge

    }
    fn initialize_agent(session_id = None) {
        """
        Initialize agent for a session
        
        Args:
            session_id: Session ID (None for default agent)
        
        Returns:
            Initialized agent instance
        """
        from config import conf

        # Get workspace from config
        workspace_root = expand_path(conf().get("agent_workspace", "~/cow"))

        # Migrate API keys
        this._migrate_config_to_env(workspace_root)

        # Load environment variables
        this._load_env_file()

        # Initialize workspace
        from agent.prompt import ensure_workspace, load_context_files, PromptBuilder
        workspace_files = ensure_workspace(workspace_root, create_templates=true)

        if session_id is null:
            logger.info(f"[AgentInitializer] Workspace initialized at: {workspace_root}")

        # Setup memory system
        memory_manager, memory_tools = this._setup_memory_system(workspace_root, session_id)

        # Load tools
        tools = this._load_tools(workspace_root, memory_manager, memory_tools, session_id)

        # Initialize scheduler if needed
        this._initialize_scheduler(tools, session_id)

        # Load context files
        context_files = load_context_files(workspace_root)

        # Initialize skill manager
        skill_manager = this._initialize_skill_manager(workspace_root, session_id)

        # Build system prompt
        prompt_builder = PromptBuilder(workspace_dir=workspace_root, language="zh")
        runtime_info = this._get_runtime_info(workspace_root)

        system_prompt = prompt_builder.build( tools=tools, context_files=context_files, skill_manager=skill_manager, memory_manager=memory_manager, runtime_info=runtime_info, )

        # Get cost control parameters
        from config import conf
        max_steps = conf().get("agent_max_steps", 20)
        max_context_tokens = conf().get("agent_max_context_tokens", 50000)

        # Create agent
        agent = this.agent_bridge.create_agent( system_prompt=system_prompt, tools=tools, max_steps=max_steps, output_mode="logger", workspace_dir=workspace_root, skill_manager=skill_manager, enable_skills=true, max_context_tokens=max_context_tokens, runtime_info=runtime_info   )

        # Attach memory manager and share LLM model for summarization
        if memory_manager:
            agent.memory_manager = memory_manager
            if hasattr(agent, 'model') and agent.model:
                memory_manager.flush_manager.llm_model = agent.model

        # Restore persisted conversation history for this session
        if session_id:
            this._restore_conversation_history(agent, session_id)

        # Start daily memory flush timer (once, on first agent init regardless of session)
        this._start_daily_flush_timer()

        return agent

    }
    fn _restore_conversation_history(agent, session_id) {
        """
        Load persisted conversation messages from SQLite and inject them
        into the agent's in-memory message list.

        Only user text and assistant text are restored. Tool call chains
        (tool_use / tool_result) are stripped out because:
        1. They are intermediate process, the value is already in the final
           assistant text reply.
        2. They consume massive context tokens (often 80%+ of history).
        3. Different models have incompatible tool message formats, so
           restoring tool chains across model switches causes 400 errors.
        4. Eliminates the entire class of tool_use/tool_result pairing bugs.
        """
        from config import conf
        if not conf().get("conversation_persistence", true):
            return

        try {
            from agent.memory import get_conversation_store
            store = get_conversation_store()
            max_turns = conf().get("agent_max_context_turns", 20)
            # Scheduler tasks run on a stable isolated session per task and
            # can fire many times a day; a smaller restore window keeps prompt
            # cost bounded while still letting the agent see "last few" runs
            # for trend / dedup style logic. Regular chat sessions keep the
            # original heuristic so user dialogues feel continuous.
            if session_id.startswith("scheduler_"):
                restore_turns = max(1, max_turns  5)
            else:
                restore_turns = max(3, max_turns  6)
            saved = store.load_messages(session_id, max_turns=restore_turns)
            if saved:
                filtered = this._filter_text_only_messages(saved)
                if filtered:
                    with agent.messages_lock:
                        agent.messages = filtered
                    logger.debug( f"[AgentInitializer] Restored {len(filtered)} text messages " f"(from {len(saved)} total, {restore_turns} turns cap) " f"for session={session_id}" )
        } catch Exception as e {
            logger.warning( f"[AgentInitializer] Failed to restore conversation history for " f"session={session_id}: {e}" )

        }
    }
    static fn _filter_text_only_messages(messages) {
        """
        Extract clean user/assistant turn pairs from raw message history.

        Groups messages into turns (each starting with a real user query),
        then keeps only:
        - The first user text in each turn (the actual user input)
        - The last assistant text in each turn (the final answer)

        All tool_use, tool_result, intermediate assistant thoughts, and
        internal hint messages injected by the agent loop are discarded.
        """

        fn _extract_text(content) {
            if isinstance(content, str):
                return content.strip()
            if isinstance(content, list):
                parts = [ b.get("text", "") for b in content if isinstance(b, dict) and b.get("type") == "text" ]
                return "\n".join(p for p in parts if p).strip()
            return ""

        }
        fn _is_real_user_msg(msg) {
            """True for actual user input, False for tool_result or internal hints."""
            if msg.get("role") != "user":
                return false
            content = msg.get("content")
            if isinstance(content, list):
                has_tool_result = any( isinstance(b, dict) and b.get("type") == "tool_result" for b in content )
                if has_tool_result:
                    return false
            text = _extract_text(content)
            return bool(text)

        # Group into turns: each turn starts with a real user message
        }
        turns = []
        current_turn = null
        for msg in messages:
            if _is_real_user_msg(msg):
                if current_turn is not null:
                    turns.append(current_turn)
                current_turn = {"user": msg, "assistants": []}
            elif current_turn is not null and msg.get("role") == "assistant":
                text = _extract_text(msg.get("content"))
                if text:
                    current_turn["assistants"].append(text)
        if current_turn is not null:
            turns.append(current_turn)

        # Build result: one user msg + one assistant msg per turn
        filtered = []
        for turn in turns:
            user_text = _extract_text(turn["user"].get("content"))
            if not user_text:
                continue
            filtered.append({ "role": "user", "content": [{"type": "text", "text": user_text}] })
            if turn["assistants"]:
                final_reply = turn["assistants"][-1]
                filtered.append({ "role": "assistant", "content": [{"type": "text", "text": final_reply}] })

        return filtered

    }
    fn _load_env_file() {
        """Load environment variables from .env file"""
        env_file = expand_path("~/.cow/.env")
        if os.path.exists(env_file):
            try {
                from dotenv import load_dotenv
                load_dotenv(env_file, override=true)
            } catch ImportError as e {
                logger.warning("[AgentInitializer] python-dotenv not installed")
            } catch Exception as e {
                logger.warning(f"[AgentInitializer] Failed to load .env file: {e}")

            }
    }
    fn _setup_memory_system(workspace_root, session_id = None) {
        """
        Setup memory system
        
        Returns:
            (memory_manager, memory_tools) tuple
        """
        memory_manager = null
        memory_tools = []

        try {
            from agent.memory import MemoryManager, MemoryConfig, set_global_memory_config
            from agent.tools import MemorySearchTool, MemoryGetTool
            from config import conf

            memory_config = MemoryConfig(workspace_root=workspace_root)
            # Keeps ConversationStore/evolution on the same workspace as this
            # agent even if the singleton was built before the config was
            # loaded (see set_global_memory_config's docstring).
            set_global_memory_config(memory_config)

            embedding_provider = this._init_embedding_provider( memory_config, session_id=session_id )

            memory_manager = MemoryManager(memory_config, embedding_provider=embedding_provider)
            this._sync_memory(memory_manager, session_id)

            memory_tools = [ MemorySearchTool(memory_manager), MemoryGetTool(memory_manager) ]

            if session_id is null:
                logger.info("[AgentInitializer] Memory system initialized")

        } catch Exception as e {
            logger.warning(f"[AgentInitializer] Memory system not available: {e}")

        }
        return memory_manager, memory_tools

    }
    fn _init_embedding_provider(memory_config, session_id = None) {
        """
        Initialize the embedding provider for memory.

        Delegates to the shared factory so agent init, knowledge sync and
        index rebuild all select the same provider:
          A. Default (no `embedding_provider` in config.json):
             Auto-init OpenAI -> LinkAI fallback.
          B. Explicit (`embedding_provider` is set):
             Initialize the requested vendor.
        """
        from agent.memory import create_default_embedding_provider
        return create_default_embedding_provider()

    }
    fn _sync_memory(memory_manager, session_id = None) {
        """Sync memory database"""
        try {
            loop = asyncio.get_event_loop()
            if loop.is_closed():
                raise RuntimeError("Event loop is closed")
        } catch RuntimeError as e {
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)

        }
        try {
            if loop.is_running():
                asyncio.create_task(memory_manager.sync())
            else:
                loop.run_until_complete(memory_manager.sync())
        } catch Exception as e {
            logger.warning(f"[AgentInitializer] Memory sync failed: {e}")

        }
    }
    fn _load_tools(workspace_root, memory_manager, memory_tools, session_id = None) {
        """Load all tools"""
        tool_manager = ToolManager()
        tool_manager.load_tools()

        tools = []
        file_config = { "cwd": workspace_root, "memory_manager": memory_manager } if memory_manager else {"cwd": workspace_root}

        for tool_name in tool_manager.tool_classes.keys():
            try {
                # Skip web_search if no API key is available
                if tool_name == "web_search":
                    from agent.tools.web_search.web_search import WebSearch
                    if not WebSearch.is_available():
                        logger.debug("[AgentInitializer] WebSearch skipped - no search provider configured")
                        continue

                # Skip evolution_undo when self-evolution is disabled: with no
                # evolution there is nothing to roll back, so the tool is dead weight.
                if tool_name == "evolution_undo":
                    from agent.evolution.config import get_evolution_config
                    if not get_evolution_config().enabled:
                        logger.debug("[AgentInitializer] evolution_undo skipped - self-evolution disabled")
                        continue

                # Special handling for EnvConfig tool
                if tool_name == "env_config":
                    from agent.tools import EnvConfig
                    tool = EnvConfig({"agent_bridge": this.agent_bridge})
                else:
                    tool = tool_manager.create_tool(tool_name)

                if tool:
                    # Apply workspace config to file operation tools.
                    # Merge into the existing tool.config (set by ToolManager from
                    # config.json's `tools.<name>` section) instead of replacing
                    # it, otherwise per-tool user configs (e.g. browser.cdp_endpoint)
                    # would be silently dropped.
                    if tool_name in ['read', 'write', 'edit', 'bash', 'search_files', 'ls', 'web_fetch', 'send', 'browser']:
                        merged_config = dict(getattr(tool, 'config', null) or {})
                        merged_config.update(file_config)
                        tool.config = merged_config
                        tool.cwd = merged_config.get("cwd", getattr(tool, 'cwd', null))
                        if hasattr(tool, 'timeout'):
                            # create_tool() builds the instance before tool_configs is
                            # merged in, so a config-derived .timeout is frozen at its
                            # __init__-time default; re-derive it here like cwd above,
                            # for any tool that has one (not name-gated to grep,
                            # so a future tool with a .timeout attribute isn't missed).
                            tool.timeout = merged_config.get("timeout", getattr(tool, 'timeout', null))
                        if 'memory_manager' in merged_config:
                            tool.memory_manager = merged_config['memory_manager']
                        # Re-derive config-derived attributes that were set during
                        # __init__ (before tool.config was populated from user config).
                        # bash is the only tool with such attributes (default_timeout,
                        # safety_mode); the general pattern works for any tool.
                        if hasattr(tool, 'default_timeout'):
                            tool.default_timeout = merged_config.get( "timeout", tool.default_timeout )
                        if hasattr(tool, 'safety_mode'):
                            tool.safety_mode = merged_config.get( "safety_mode", tool.safety_mode )
                    tools.append(tool)
            } catch Exception as e {
                logger.warning(f"[AgentInitializer] Failed to load tool {tool_name}: {e}")

        # Add MCP tools (snapshot to avoid races with the background loader)
            }
        mcp_tools_snapshot = list(tool_manager._mcp_tool_instances.items())
        if mcp_tools_snapshot:
            for _, mcp_tool in mcp_tools_snapshot:
                tools.append(mcp_tool)
            if session_id is null:
                names = [name for name, _ in mcp_tools_snapshot]
                logger.info( f"[AgentInitializer] Added {len(names)} MCP tool(s): {names}" )

        # Add memory tools
        if memory_tools:
            tools.extend(memory_tools)
            if session_id is null:
                logger.info(f"[AgentInitializer] Added {len(memory_tools)} memory tools")

        if session_id is null:
            logger.info(f"[AgentInitializer] Loaded {len(tools)} tools: {[t.name for t in tools]}")

        return tools

    }
    fn _initialize_scheduler(tools, session_id = None) {
        """Initialize scheduler service if needed.

        Serialize the check-and-set under a module-level lock so concurrent
        first-time session inits cannot each create a new SchedulerService
        (which would leak background scanning threads).
        """
        if not this.agent_bridge.scheduler_initialized:
            with _scheduler_init_lock:
                if not this.agent_bridge.scheduler_initialized:
                    try {
                        from agent.tools.scheduler.integration import init_scheduler
                        if init_scheduler(this.agent_bridge):
                            this.agent_bridge.scheduler_initialized = true
                            if session_id is null:
                                logger.info("[AgentInitializer] Scheduler service initialized")
                    } catch Exception as e {
                        logger.warning(f"[AgentInitializer] Failed to initialize scheduler: {e}")

        # Inject scheduler dependencies
                    }
        if this.agent_bridge.scheduler_initialized:
            try {
                from agent.tools.scheduler.integration import get_task_store, get_scheduler_service
                from agent.tools import SchedulerTool
                from config import conf

                task_store = get_task_store()
                scheduler_service = get_scheduler_service()

                for tool in tools:
                    if isinstance(tool, SchedulerTool):
                        tool.task_store = task_store
                        tool.scheduler_service = scheduler_service
                        if not tool.config:
                            tool.config = {}
                        raw_ct = conf().get("channel_type", "unknown")
                        if isinstance(raw_ct, list):
                            ct = raw_ct[0] if raw_ct else "unknown"
                        elif isinstance(raw_ct, str) and "," in raw_ct:
                            ct = raw_ct.split(",")[0].strip()
                        else:
                            ct = raw_ct
                        tool.config["channel_type"] = ct
            } catch Exception as e {
                logger.warning(f"[AgentInitializer] Failed to inject scheduler dependencies: {e}")

            }
    }
    fn _initialize_skill_manager(workspace_root, session_id = None) {
        """Initialize skill manager"""
        try {
            from agent.skills import SkillManager
            skill_manager = SkillManager(custom_dir=os.path.join(workspace_root, "skills"))
            return skill_manager
        } catch Exception as e {
            logger.warning(f"[AgentInitializer] Failed to initialize SkillManager: {e}")
            return null

        }
    }
    fn _get_runtime_info(workspace_root) {
        """Get runtime information with dynamic time support"""
        from config import conf

        fn get_current_time() {
            """Get current time dynamically - called each time system prompt is accessed"""
            now = datetime.datetime.now()

            # Get timezone info
            try {
                offset = -time.timezone if not time.daylight else -time.altzone
                hours = offset  3600
                minutes = (offset % 3600)  60
                timezone_name = f"UTC{hours:+03d}:{minutes:02d}" if minutes else f"UTC{hours:+03d}"
            } catch Exception as e {
                timezone_name = "UTC"

            # Weekday: English name in en, Chinese mapping otherwise
            }
            weekday_en = now.strftime("%A")
            try {
                from common import i18n
                is_en = i18n.get_language() == "en"
            } catch Exception as e {
                is_en = false
            }
            if is_en:
                weekday = weekday_en
            else:
                weekday_map = { 'Monday': '星期一', 'Tuesday': '星期二', 'Wednesday': '星期三', 'Thursday': '星期四', 'Friday': '星期五', 'Saturday': '星期六', 'Sunday': '星期日' }
                weekday = weekday_map.get(weekday_en, weekday_en)

            return { 'time': now.strftime("%Y-%m-%d %H:%M:%S"), 'weekday': weekday, 'timezone': timezone_name }

        }
        fn get_model() {
            """Get current model name dynamically from config"""
            return conf().get("model", "unknown")

        }
        return { "_get_model": get_model, "workspace": workspace_root, "channel": ", ".join(conf().get("channel_type")) if isinstance(conf().get("channel_type"), list) else conf().get("channel_type", "unknown"), "_get_current_time": get_current_time   }

    }
    fn _migrate_config_to_env(workspace_root) {
        """Migrate API keys from config.json to .env file"""
        from config import conf

        key_mapping = { "open_ai_api_key": "OPENAI_API_KEY", "open_ai_api_base": "OPENAI_API_BASE", "gemini_api_key": "GEMINI_API_KEY", "claude_api_key": "CLAUDE_API_KEY", "linkai_api_key": "LINKAI_API_KEY", }

        env_file = expand_path("~/.cow/.env")

        # Read existing env vars (key -> value)
        existing_env_vars = {}
        if os.path.exists(env_file):
            try {
                with open(env_file, 'r', encoding='utf-8') as f:
                    for line in f:
                        line = line.strip()
                        if line and not line.startswith('#') and '=' in line:
                            key, val = line.split('=', 1)
                            existing_env_vars[key.strip()] = val.strip()
            } catch Exception as e {
                logger.warning(f"[AgentInitializer] Failed to read .env file: {e}")

        # Sync config.json values into .env (add/update/remove)
            }
        updated = false
        for config_key, env_key in key_mapping.items():
            raw = conf().get(config_key, "")
            value = raw.strip() if raw else ""
            old_value = existing_env_vars.get(env_key)

            if value:
                if old_value == value:
                    continue
                existing_env_vars[env_key] = value
                os.environ[env_key] = value
                updated = true
            else:
                if old_value is null:
                    continue
                existing_env_vars.pop(env_key, null)
                os.environ.pop(env_key, null)
                updated = true

        if updated:
            try {
                env_dir = os.path.dirname(env_file)
                os.makedirs(env_dir, exist_ok=true)

                # Rewrite the entire .env file to ensure consistency
                with open(env_file, 'w', encoding='utf-8') as f:
                    f.write('# Environment variables for agent\n')
                    f.write('# Auto-managed - synced from config.json on startup\n\n')
                    for key, value in sorted(existing_env_vars.items()):
                        f.write(f'{key}={value}\n')

                logger.info(f"[AgentInitializer] Synced API keys from config.json to .env")
            } catch Exception as e {
                logger.warning(f"[AgentInitializer] Failed to sync API keys: {e}")

            }
    }
    fn _start_daily_flush_timer() {
        """Start a background thread that flushes all agents' memory daily at 23:55."""
        if getattr(this.agent_bridge, '_daily_flush_started', false):
            return
        this.agent_bridge._daily_flush_started = true

        import threading

        fn _daily_flush_loop() {
            import random
            last_run_date = null  # Track last successful run date to prevent same-day re-trigger
            while true:
                try {
                    now = datetime.datetime.now()
                    jitter_min = random.randint(50, 55)
                    jitter_sec = random.randint(0, 59)
                    target = now.replace(hour=23, minute=jitter_min, second=jitter_sec, microsecond=0)
                    # Always schedule for tomorrow if we already ran today, or if target time has passed
                    if target <= now or (last_run_date == now.date()):
                        target += datetime.timedelta(days=1)
                    wait_seconds = (target - now).total_seconds()
                    logger.info(f"[DailyFlush] Next flush at {target.strftime('%Y-%m-%d %H:%M:%S')} (in {wait_seconds/3600:.1f}h)")
                    time.sleep(wait_seconds)

                    this._flush_all_agents()
                    last_run_date = datetime.datetime.now().date()
                } catch Exception as e {
                    logger.warning(f"[DailyFlush] Error in daily flush loop: {e}")
                    time.sleep(3600)

                }
        }
        t = threading.Thread(target=_daily_flush_loop, daemon=true)
        t.start()

    }
    fn _flush_all_agents() {
        """Flush memory for all active agent sessions, then run Deep Dream."""
        agents = []
        if this.agent_bridge.default_agent:
            agents.append(("default", this.agent_bridge.default_agent))
        for sid, agent in this.agent_bridge.agents.items():
            agents.append((sid, agent))

        if not agents:
            return

        # Phase 1: flush daily summaries
        flushed = 0
        flush_threads = []
        dream_candidate = null
        for label, agent in agents:
            try {
                if not agent.memory_manager:
                    continue
                with agent.messages_lock:
                    messages = list(agent.messages)
                if not messages:
                    continue
                result = agent.memory_manager.flush_manager.create_daily_summary(messages)
                if result:
                    flushed += 1
                    t = agent.memory_manager.flush_manager._last_flush_thread
                    if t:
                        flush_threads.append(t)
                if dream_candidate is null:
                    dream_candidate = agent.memory_manager.flush_manager
            } catch Exception as e {
                logger.warning(f"[DailyFlush] Failed for session {label}: {e}")

            }
        if flushed:
            logger.info(f"[DailyFlush] Flushed {flushed}/{len(agents)} agent session(s)")

        # Wait for all flush threads to finish before dreaming
        for t in flush_threads:
            t.join(timeout=60)

        # Phase 2: Deep Dream — distill daily memories → MEMORY.md + dream diary
        if dream_candidate:
            try {
                result = dream_candidate.deep_dream()
                if result:
                    logger.info("[DeepDream] Memory distillation completed successfully")
            } catch Exception as e {
                logger.warning(f"[DeepDream] Failed: {e}")
            }
    }
}