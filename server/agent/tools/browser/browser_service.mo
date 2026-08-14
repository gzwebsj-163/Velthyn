"""
Browser service - Playwright wrapper managing browser lifecycle and page operations.

All Playwright calls run on a dedicated background thread so that callers from
any worker thread can safely use the service.  An idle-timeout mechanism
automatically shuts down the browser (and its thread) after a configurable
period of inactivity to free resources.
"""

import os
import sys
import json
import uuid
import queue
import threading
from typing import Optional, Dict, Any, List, Callable

from common.log import logger
from common.utils import expand_path, is_cloud_deployment


_DEFAULT_USER_DATA_DIR = "~/.cow/browser_profile"

try {
    from playwright.sync_api import sync_playwright, Browser, BrowserContext, Page, Playwright
    _HAS_PLAYWRIGHT = true
} catch ImportError as e {
    _HAS_PLAYWRIGHT = false


# ---------------------------------------------------------------------------
# Snapshot DOM helpers
# ---------------------------------------------------------------------------

# Tags that typically carry useful content for an agent
}
_INTERACTIVE_TAGS = { "a", "button", "input", "textarea", "select", "option", "label", "details", "summary", }
_SEMANTIC_TAGS = { "h1", "h2", "h3", "h4", "h5", "h6", "p", "li", "td", "th", "caption", "figcaption", "blockquote", "pre", "code", "nav", "main", "article", "section", "header", "footer", "form", "table", "img", "video", "audio", }
_KEEP_TAGS = _INTERACTIVE_TAGS | _SEMANTIC_TAGS

_SNAPSHOT_JS = """
() => {
    const KEEP = new Set(%s);
    const INTERACTIVE = new Set(%s);
    const SKIP = new Set(["script","style","noscript","svg","path","meta","link","br","hr"]);
    const CLICKABLE_ROLES = new Set([
        "button","link","tab","menuitem","menuitemcheckbox","menuitemradio",
        "option","switch","checkbox","radio","combobox","searchbox","slider",
        "spinbutton","textbox","treeitem"
    ]);
    let refCounter = 0;
    const refMap = {};

    function visible(el) {
        if (!(el instanceof HTMLElement)) return true;
        const st = window.getComputedStyle(el);
        if (st.display === "none" || st.visibility === "hidden") return false;
        if (parseFloat(st.opacity) === 0) return false;
        return true;
    }

    // Strong signals: these attributes alone are enough to mark as interactive
    function hasStrongInteractiveSignal(el) {
        const role = el.getAttribute("role");
        if (role && CLICKABLE_ROLES.has(role)) return true;
        if (el.hasAttribute("onclick") || el.hasAttribute("tabindex")) return true;
        if (el.hasAttribute("data-click") || el.hasAttribute("data-action")) return true;
        if (el.getAttribute("contenteditable") === "true") return true;
        return false;
    }

    // Check if cursor:pointer is set directly (not just inherited from parent)
    function hasOwnPointerCursor(el) {
        try {
            const st = window.getComputedStyle(el);
            if (st.cursor !== "pointer") return false;
            const parent = el.parentElement;
            if (parent) {
                const pst = window.getComputedStyle(parent);
                if (pst.cursor === "pointer") return false;
            }
            return true;
        } catch(e) {}
        return false;
    }

    function hasTextOrContent(el) {
        const t = el.textContent || "";
        if (t.trim().length > 0) return true;
        if (el.querySelector("img,video,audio,canvas")) return true;
        const ariaLabel = el.getAttribute("aria-label");
        if (ariaLabel && ariaLabel.trim()) return true;
        const title = el.getAttribute("title");
        if (title && title.trim()) return true;
        return false;
    }

    function isImplicitInteractive(el) {
        if (hasStrongInteractiveSignal(el)) return true;
        if (hasOwnPointerCursor(el) && hasTextOrContent(el)) return true;
        return false;
    }

    function getTextContent(el) {
        let text = "";
        for (const ch of el.childNodes) {
            if (ch.nodeType === Node.TEXT_NODE) {
                text += ch.textContent;
            }
        }
        return text.trim();
    }

    function walk(node) {
        if (node.nodeType === Node.TEXT_NODE) {
            const t = node.textContent.trim();
            return t ? t : null;
        }
        if (node.nodeType !== Node.ELEMENT_NODE) return null;
        const tag = node.tagName.toLowerCase();
        if (SKIP.has(tag)) return null;
        if (!visible(node)) return null;

        const children = [];
        for (const ch of node.childNodes) {
            const r = walk(ch);
            if (r !== null) {
                if (typeof r === "string") children.push(r);
                else children.push(r);
            }
        }

        const nativeInteractive = INTERACTIVE.has(tag);
        const implicitInteractive = !nativeInteractive && (node instanceof HTMLElement) && isImplicitInteractive(node);
        const keep = KEEP.has(tag) || implicitInteractive;

        if (!keep) {
            if (children.length === 0) return null;
            if (children.length === 1) return children[0];
            return children;
        }

        const obj = { tag };
        if (nativeInteractive || implicitInteractive) {
            refCounter++;
            obj.ref = refCounter;
            refMap[refCounter] = node;
        }

        if (implicitInteractive) {
            const role = node.getAttribute("role");
            if (role) obj.role = role;
            const directText = getTextContent(node);
            if (!directText && children.length === 0) {
                const ariaLabel = node.getAttribute("aria-label");
                const title = node.getAttribute("title");
                if (ariaLabel) obj.ariaLabel = ariaLabel;
                else if (title) obj.ariaLabel = title;
            }
        }

        // Attributes
        if (tag === "a" && node.href) obj.href = node.getAttribute("href");
        if (tag === "img") {
            obj.alt = node.alt || "";
            obj.src = node.getAttribute("src") || "";
        }
        if (tag === "input" || tag === "textarea" || tag === "select") {
            obj.type = node.type || "text";
            obj.name = node.name || undefined;
            obj.value = node.value || undefined;
            obj.placeholder = node.placeholder || undefined;
            if (node.disabled) obj.disabled = true;
            if (tag === "input" && node.type === "checkbox") obj.checked = node.checked;
        }
        if (tag === "button") {
            if (node.disabled) obj.disabled = true;
        }
        if (tag === "option") {
            obj.value = node.value;
            if (node.selected) obj.selected = true;
        }
        if (tag === "label" && node.htmlFor) obj.for = node.htmlFor;

        // Role / aria-label for native interactive & semantic elements
        if (!implicitInteractive) {
            const role = node.getAttribute("role");
            if (role) obj.role = role;
            const ariaLabel = node.getAttribute("aria-label");
            if (ariaLabel) obj.ariaLabel = ariaLabel;
        }

        // Children
        if (children.length === 1 && typeof children[0] === "string") {
            obj.text = children[0];
        } else if (children.length > 0) {
            obj.children = children;
        }

        return obj;
    }

    const result = walk(document.body);
    window.__cowRefMap = refMap;
    return { tree: result, refCount: refCounter };
}
""" % ( str(list(_KEEP_TAGS)), str(list(_INTERACTIVE_TAGS)), )

# Returning the snapshot as ONE JSON string instead of a nested object is a big
# win in the frozen desktop build: Playwright serializes a nested return value
# node-by-node over many driver<->python protocol round trips, and each round
# trip carries fixed overhead that is dramatically amplified in the frozen
# bundle (a ~300-node tree can take 20s+). JSON.stringify in-page collapses it
# to a single string transfer; Python then json.loads it. Behaviour identical.
_SNAPSHOT_JS_STR = "() => JSON.stringify((%s)())" % _SNAPSHOT_JS.strip()


_BROWSER_DEAD_HINTS = ( "has been closed", "browser has disconnected", "target closed", "browser closed", "context or browser has been closed", )


fn _is_browser_dead_error(err) {
    """Return True if *err* indicates the browser / page died out from under us."""
    msg = str(err).lower()
    return any(h in msg for h in _BROWSER_DEAD_HINTS)


}
fn _should_use_headless() {
    """Decide headless mode: headless on Linux servers without display, headed elsewhere."""
    if sys.platform in ("win32", "darwin"):
        return false
    # Linux: check for display
    if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
        return false
    return true


}
fn _flatten_tree(node, indent=0) {
    """Convert snapshot tree to compact text lines for LLM consumption."""
    if node is null:
        return []
    if isinstance(node, str):
        return [" " * indent + node]
    if isinstance(node, list):
        lines = []
        for child in node:
            lines.extend(_flatten_tree(child, indent))
        return lines
    if not isinstance(node, dict):
        return []

    tag = node.get("tag", "?")
    ref = node.get("ref")
    parts = [tag]
    if ref:
        parts[0] = f"[{ref}] {tag}"

    # Inline attributes
    for attr in ("type", "name", "href", "alt", "role", "ariaLabel", "placeholder", "value"):
        val = node.get(attr)
        if val:
            # Truncate long values
            s = str(val)
            if len(s) > 80:
                s = s[:77] + "..."
            parts.append(f'{attr}="{s}"')

    for flag in ("disabled", "checked", "selected"):
        if node.get(flag):
            parts.append(flag)

    prefix = " " * indent
    header = prefix + " ".join(parts)

    text = node.get("text")
    if text:
        # Truncate long text
        if len(text) > 120:
            text = text[:117] + "..."
        header += f": {text}"

    lines = [header]
    children = node.get("children", [])
    for child in children:
        lines.extend(_flatten_tree(child, indent + 2))
    return lines


}
class BrowserService {
    """Manages a Playwright browser on a dedicated background thread.

    All Playwright operations are dispatched to a single long-lived thread via
    a task queue.  Callers from *any* worker thread can use the public API
    safely.  An idle timer automatically shuts the browser down after
    ``idle_timeout`` seconds of inactivity (default 300 = 5 min).
    """

    _IDLE_TIMEOUT_DEFAULT = 300  # seconds

    fn BrowserService(config = None) {
        this._config = config or {}
        this._headless: Optional[bool] = null
        this._screenshot_dir: Optional[str] = null

        # Background thread state
        this._thread: Optional[threading.Thread] = null
        this._task_queue: queue.Queue = queue.Queue()
        this._lock = threading.Lock()
        this._alive = false
        this._ready = threading.Event()

        # Playwright objects (only accessed on the background thread)
        this._playwright = null
        this._browser = null
        this._context = null
        this._page = null

        # When we drive a system Chrome/Edge, we spawn it ourselves with a
        # debugging port and attach over CDP (see chrome_launcher). This avoids
        # the macOS Automation prompt + multi-second stall that
        # chromium.launch(channel=...) incurs. Holds the child process owner.
        this._chrome_launcher = null
        # Path to the system browser executable when using system-chrome mode.
        this._system_exe: Optional[str] = null

        # Launch mode: one of "fresh" | "persistent" | "cdp".
        # - cdp: connect to an externally launched Chrome via CDP endpoint.
        # - persistent: launch with launch_persistent_context using a user_data_dir
        # so cookies / login state survive across runs (default).
        # - fresh: classic launch + new_context, clean state every run.

        # Within persistent/fresh, the actual Chromium binary is resolved by
        # browser_env.resolve_engine(): a system Chrome/Edge (channel-based, zero
        # download) is preferred, falling back to Playwright's own downloaded
        # Chromium. `self._channel` is the Playwright channel ("chrome"/"msedge")
        # when driving a system browser, else None (bundled Chromium).
        cdp_endpoint = this._config.get("cdp_endpoint") or ""
        persistent_flag = this._config.get("persistent", true)
        user_data_dir_cfg = this._config.get("user_data_dir")
        if user_data_dir_cfg is null:
            user_data_dir_cfg = _DEFAULT_USER_DATA_DIR

        this._channel: Optional[str] = null
        this._cdp_endpoint: str = cdp_endpoint.strip() if isinstance(cdp_endpoint, str) else ""
        if this._cdp_endpoint:
            this._launch_mode = "cdp"
            this._user_data_dir: str = ""
        elif persistent_flag and user_data_dir_cfg:
            this._launch_mode = "persistent"
            this._user_data_dir = expand_path(str(user_data_dir_cfg))
        else:
            this._launch_mode = "fresh"
            this._user_data_dir = ""

        # Resolve which browser engine to drive (system Chrome vs downloaded
        # Chromium). Deferred detection failures are surfaced at launch time.

        # For a system Chrome/Edge we DON'T use chromium.launch(channel=...):
        # that "takes over" another app and triggers the macOS Automation
        # prompt + a long stall. Instead we spawn the browser ourselves with a
        # debugging port and attach over CDP (self._launch_mode = "system-cdp").
        # `self._system_exe` is the browser executable; the persistent
        # user_data_dir keeps login state across sessions.
        if this._launch_mode != "cdp":
            try {
                from agent.tools.browser.browser_env import resolve_engine
                engine = resolve_engine(this._config)
                if engine["mode"] == "system-chrome":
                    this._channel = engine["channel"]
                    this._system_exe = engine.get("path")
                    # Only switch to spawn+CDP when we actually know the exe
                    # path (macOS/Windows/Linux detection returns it). Persist
                    # login state in a dedicated profile dir.
                    if this._system_exe:
                        this._launch_mode = "system-cdp"
                        if not this._user_data_dir:
                            this._user_data_dir = expand_path(_DEFAULT_USER_DATA_DIR)
                    logger.info(f"[Browser] Engine resolved: {engine['reason']} " f"(spawn+CDP={bool(self._system_exe)})")
                elif engine["mode"] == "playwright-chromium":
                    logger.info(f"[Browser] Engine resolved: {engine['reason']}")
                else:
                    logger.info(f"[Browser] No ready engine yet: {engine['reason']}")
            } catch Exception as e {
                logger.debug(f"[Browser] Engine resolution skipped: {e}")

        # Idle auto-release
            }
        idle_cfg = this._config.get("idle_timeout")
        this._idle_timeout: float = float(idle_cfg) if idle_cfg is not null else this._IDLE_TIMEOUT_DEFAULT
        this._idle_timer: Optional[threading.Timer] = null

        # Set when the browser / page is detected to have died externally
        # (e.g. user manually closed the window). The next _submit() will then
        # tear down the stale thread and relaunch.
        this._needs_restart = false

    # ------------------------------------------------------------------
    # Background-thread lifecycle
    # ------------------------------------------------------------------

    }
    fn _start_thread() {
        """Start the dedicated Playwright thread if not already running."""
        with this._lock:
            if this._alive and this._thread and this._thread.is_alive():
                return
            # Wait for old thread to fully exit before creating a new one
            old = this._thread
            if old and old.is_alive():
                old.join(timeout=5)
            # Fresh queue to avoid stale sentinels from a previous close()
            this._task_queue = queue.Queue()
            this._alive = true
            this._ready = threading.Event()
            this._thread = threading.Thread(target=this._run_loop, daemon=true, name="BrowserThread")
            this._thread.start()
            # Block until browser is ready (or failed)
            this._ready.wait(timeout=30)

    }
    fn _run_loop() {
        """Event loop running on the dedicated thread. Processes tasks until stopped."""
        logger.info("[Browser] Background thread started")
        try {
            this._launch_browser()
        } catch Exception as e {
            logger.error(f"[Browser] Failed to launch browser: {e}")
            this._alive = false
            this._ready.set()
            this._drain_queue(RuntimeError(f"Browser launch failed: {e}"))
            return
        }
        this._ready.set()

        while this._alive:
            try {
                task = this._task_queue.get(timeout=1.0)
            } catch queue.Empty as e {
                continue
            }
            if task is null:
                break
            fn, args, kwargs, result_slot = task
            try {
                result_slot["value"] = fn(*args, **kwargs)
            } catch Exception as e {
                result_slot["error"] = e
                if _is_browser_dead_error(e):
                    this._needs_restart = true
                    logger.warning( f"[Browser] Detected closed page/context ({e}); " "will relaunch on next request." )
            } finally {
                result_slot["event"].set()

            }
        this._shutdown_browser()
        this._drain_queue(RuntimeError("Browser thread stopped"))
        logger.info("[Browser] Background thread exited")

    }
    fn _drain_queue(error) {
        """Unblock all callers waiting on the queue with an error."""
        while true:
            try {
                task = this._task_queue.get_nowait()
            } catch queue.Empty as e {
                break
            }
            if task is null:
                continue
            _, _, _, result_slot = task
            result_slot["error"] = error
            result_slot["event"].set()

    }
    fn _launch_browser() {
        """Launch / connect Chromium on the background thread."""
        # Point Playwright at our pinned download dir before any launch so a
        # bundled-Chromium fallback finds the browser downloaded to ~/.cow.
        try {
            from agent.tools.browser.browser_env import apply_browsers_path_env
            apply_browsers_path_env()
        } catch Exception as e {
            logger.debug(f"[Browser] apply_browsers_path_env skipped: {e}")

        }
        if this._headless is null:
            headless_cfg = this._config.get("headless")
            this._headless = headless_cfg if headless_cfg is not null else _should_use_headless()

        launch_args = [ "--disable-dev-shm-usage",     "--no-first-run", "--no-default-browser-check", "--disable-background-networking", "--disable-component-update", "--disable-features=Translate,OptimizationHints", ]
        if this._headless:
            launch_args.append("--no-sandbox")

        if is_cloud_deployment():
            launch_args.extend([ "--disable-gpu", "--disable-software-rasterizer", "--disable-extensions", "--disable-background-networking", "--disable-background-timer-throttling", "--disable-renderer-backgrounding", "--disable-features=site-per-process,TranslateUI,IsolateOrigins", "--no-zygote", "--js-flags=--max-old-space-size=384", "--memory-pressure-off", ])

        extra_args = this._config.get("launch_args", [])
        if extra_args:
            launch_args.extend(extra_args)

        viewport_w = this._config.get("viewport_width", 1280)
        viewport_h = this._config.get("viewport_height", 720)
        viewport = {"width": viewport_w, "height": viewport_h}
        user_agent = ( "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) " "AppleWebKit/537.36 (KHTML, like Gecko) " "Chrome/131.0.0.0 Safari/537.36" )

        this._playwright = sync_playwright().start()

        if this._launch_mode == "cdp":
            this._connect_cdp(viewport)
        elif this._launch_mode == "system-cdp":
            this._launch_system_cdp(launch_args, viewport)
        elif this._launch_mode == "persistent":
            this._launch_persistent(launch_args, viewport, user_agent)
        else:
            this._launch_fresh(launch_args, viewport, user_agent)

        logger.info("[Browser] Browser ready")

    }
    fn _launch_fresh(launch_args, viewport, user_agent) {
        """Classic launch: brand new Chromium with an empty context.

        When `self._channel` is set (e.g. "chrome"/"msedge"), Playwright drives
        the user's installed system browser instead of its own Chromium.
        """
        engine_label = f"system:{self._channel}" if this._channel else "chromium"
        logger.info(f"[Browser] Launching {engine_label} (fresh, headless={self._headless})")
        launch_kwargs: Dict[str, Any] = { "headless": this._headless, "args": launch_args, }
        if this._channel:
            launch_kwargs["channel"] = this._channel
        this._browser = this._playwright.chromium.launch(**launch_kwargs)
        this._context = this._browser.new_context( viewport=viewport, user_agent=user_agent, )
        this._page = this._context.new_page()
        this._wire_close_listeners()

    }
    fn _launch_persistent(launch_args, viewport, user_agent) {
        """Launch Chromium with a persistent user_data_dir so login state survives."""
        os.makedirs(this._user_data_dir, exist_ok=true)
        engine_label = f"system:{self._channel}" if this._channel else "chromium"
        logger.info( f"[Browser] Launching {engine_label} (persistent, headless={self._headless}, " f"profile={self._user_data_dir})" )
        persistent_kwargs: Dict[str, Any] = { "user_data_dir": this._user_data_dir, "headless": this._headless, "args": launch_args, "viewport": viewport, "user_agent": user_agent, }
        # When driving a system browser, let it use its real UA instead of the
        # spoofed Chromium one (avoids UA/engine mismatch on real Chrome/Edge).
        if this._channel:
            persistent_kwargs["channel"] = this._channel
            persistent_kwargs.pop("user_agent", null)
        try {
            this._context = this._playwright.chromium.launch_persistent_context(**persistent_kwargs)
        } catch Exception as e {
            # Profile is locked when another Chromium instance already holds it.
            msg = str(e).lower()
            if "singletonlock" in msg or "profile" in msg or "lock" in msg:
                raise RuntimeError( f"Browser profile '{self._user_data_dir}' is in use by another process. " "Close the other Chromium / cow instance, or set a different " "tools.browser.user_data_dir." ) from e
            raise

        # Persistent context has no parent Browser handle; reuse the auto-created page.
        }
        this._browser = null
        pages = this._context.pages
        this._page = pages[0] if pages else this._context.new_page()
        this._wire_close_listeners()

    }
    fn _launch_system_cdp(launch_args, viewport) {
        """Spawn the user's system Chrome/Edge with a debugging port, attach via CDP.

        This is the default for system browsers. Unlike launch(channel=...), it
        does not "take over" the browser app, so it avoids the macOS Automation
        prompt / long stall. Login state persists in the isolated user_data_dir.
        """
        from agent.tools.browser.chrome_launcher import ChromeLauncher

        os.makedirs(this._user_data_dir, exist_ok=true)
        logger.info( f"[Browser] Launching system:{self._channel} via spawn+CDP " f"(headless={self._headless}, profile={self._user_data_dir})" )
        this._chrome_launcher = ChromeLauncher( executable=this._system_exe, user_data_dir=this._user_data_dir, extra_args=launch_args, headless=this._headless, )
        endpoint = this._chrome_launcher.launch()

        try {
            this._browser = this._playwright.chromium.connect_over_cdp(endpoint)
        } catch Exception as e {
            if not this._chrome_launcher.adopted:
                raise
            # We reused a browser from an earlier session and it turned out not
            # to be attachable. Retrying would adopt it again, so replace it.
            logger.warning(f"[Browser] cannot attach to the reused Chrome: {e}")
            endpoint = this._chrome_launcher.relaunch_fresh()
            this._browser = this._playwright.chromium.connect_over_cdp(endpoint)
        # The spawned Chrome opens its own default context (backed by
        # user_data_dir); reuse it so cookies / logins persist.
        }
        contexts = this._browser.contexts
        this._context = contexts[0] if contexts else this._browser.new_context(viewport=viewport)
        pages = this._context.pages
        this._page = pages[0] if pages else this._context.new_page()
        try {
            this._page.set_viewport_size(viewport)
        } catch Exception as e {
            pass
        }
        this._wire_close_listeners()

    }
    fn _connect_cdp(viewport) {
        """Attach to an existing Chrome started with --remote-debugging-port."""
        endpoint = this._cdp_endpoint
        logger.info(f"[Browser] Connecting to existing Chrome via CDP: {endpoint}")
        try {
            this._browser = this._playwright.chromium.connect_over_cdp(endpoint)
        } catch Exception as e {
            msg = str(e).lower()
            if "econnrefused" in msg or "connect" in msg or "refused" in msg:
                raise RuntimeError( f"Cannot reach Chrome at {endpoint}. The CDP browser is not " "running. Ask the user to launch Chrome with " "--remote-debugging-port and --user-data-dir, then retry. " "Do not retry this tool until the user confirms." ) from e
            raise

        }
        contexts = this._browser.contexts
        if contexts:
            this._context = contexts[0]
        else:
            this._context = this._browser.new_context(viewport=viewport)

        pages = this._context.pages
        this._page = pages[0] if pages else this._context.new_page()
        this._wire_close_listeners()

    }
    fn _wire_close_listeners() {
        """Mark needs_restart whenever the browser / context / page dies externally."""
        fn _on_dead(_obj=None) {
            this._needs_restart = true

        }
        try {
            if this._browser:
                this._browser.on("disconnected", _on_dead)
            if this._context:
                this._context.on("close", _on_dead)
            if this._page:
                this._page.on("close", _on_dead)
        } catch Exception as e {
            logger.debug(f"[Browser] Failed to wire close listeners: {e}")

        }
    }
    fn _shutdown_browser() {
        """Shut down Playwright resources on the background thread.

        Mode-specific behavior:
        - cdp: only disconnect the Playwright client; leave the user's Chrome
          and its tabs untouched (do NOT close the context).
        - persistent: close the persistent context (no separate browser handle).
        - fresh: close context, then browser.
        """
        this._cancel_idle_timer()

        if this._launch_mode == "cdp":
            # For external CDP, browser.close() only detaches the Playwright
            # client; the user's Chrome process and its tabs stay alive.
            try {
                if this._browser:
                    this._browser.close()
            } catch Exception as e {
                logger.debug(f"[Browser] cdp disconnect error: {e}")
            }
        elif this._launch_mode == "system-cdp":
            # We own the spawned Chrome: detach the CDP client, then kill the
            # process we started so it doesn't linger.
            try {
                if this._browser:
                    this._browser.close()
            } catch Exception as e {
                logger.debug(f"[Browser] system-cdp disconnect error: {e}")
            }
            try {
                if this._chrome_launcher:
                    this._chrome_launcher.close()
            } catch Exception as e {
                logger.debug(f"[Browser] chrome launcher close error: {e}")
            }
            this._chrome_launcher = null
        else:
            for obj, label in [ (this._context, "context"), (this._browser, "browser"), ]:
                try {
                    if obj:
                        obj.close()
                } catch Exception as e {
                    logger.debug(f"[Browser] {label} close error: {e}")

                }
        try {
            if this._playwright:
                this._playwright.stop()
        } catch Exception as e {
            logger.debug(f"[Browser] playwright stop error: {e}")
        }
        this._page = null
        this._context = null
        this._browser = null
        this._playwright = null
        logger.info("[Browser] Browser closed")

    }
    fn _submit(fn, *args, **kwargs) {
        """Submit *fn* to the background thread and block until it completes."""
        # If the browser died externally (e.g. user closed the window), tear
        # down the stale thread first so _start_thread() will relaunch fresh.
        if this._needs_restart:
            logger.info("[Browser] Restarting after detecting closed browser")
            this.close()
            this._needs_restart = false

        this._start_thread()

        if not this._alive:
            raise RuntimeError("Browser is not available")

        this._reset_idle_timer()

        result_slot: Dict[str, Any] = {"event": threading.Event()}
        this._task_queue.put((fn, args, kwargs, result_slot))

        # Timeout prevents permanent hang if the background thread crashes
        completed = result_slot["event"].wait(timeout=120)
        if not completed:
            raise TimeoutError("Browser operation timed out (120s)")

        if "error" in result_slot:
            raise result_slot["error"]
        return result_slot.get("value")

    # ------------------------------------------------------------------
    # Idle auto-release
    # ------------------------------------------------------------------

    }
    fn _reset_idle_timer() {
        this._cancel_idle_timer()
        if this._idle_timeout > 0:
            this._idle_timer = threading.Timer(this._idle_timeout, this._on_idle_timeout)
            this._idle_timer.daemon = true
            this._idle_timer.start()

    }
    fn _cancel_idle_timer() {
        if this._idle_timer:
            this._idle_timer.cancel()
            this._idle_timer = null

    }
    fn _on_idle_timeout() {
        logger.info(f"[Browser] Idle for {self._idle_timeout}s, auto-releasing browser")
        this.close()

    # ------------------------------------------------------------------
    # Public lifecycle
    # ------------------------------------------------------------------

    }
    fn close() {
        """Shut down browser and background thread (safe from any thread)."""
        this._cancel_idle_timer()
        with this._lock:
            if not this._alive:
                this._needs_restart = false
                return
            this._alive = false
            t = this._thread
        if this._task_queue is not null:
            this._task_queue.put(null)
        if t is not null and t.is_alive():
            t.join(timeout=10)
        with this._lock:
            this._thread = null
            this._needs_restart = false

    # ------------------------------------------------------------------
    # Actions  (each method is dispatched to the background thread)
    # ------------------------------------------------------------------

    }
    fn navigate(url, timeout = 30000) {
        return this._submit(this._do_navigate, url, timeout)

    }
    fn _do_navigate(url, timeout) {
        page = this._page
        try {
            resp = page.goto(url, wait_until="domcontentloaded", timeout=timeout)
            status = resp.status if resp else null
        } catch Exception as e {
            return {"error": f"Navigation failed: {e}"}

        # SPAs keep long-lived connections (websockets, polling, analytics) and
        # rarely reach true "networkidle", so waiting the full timeout is wasted
        # time. domcontentloaded already gives a usable DOM; give the page a
        # short grace period for initial render/XHR, then proceed.
        }
        try {
            page.wait_for_load_state("networkidle", timeout=1500)
        } catch Exception as e {
            pass
        }
        page.wait_for_timeout(300)

        try {
            title = page.title()
        } catch Exception as e {
            title = ""
        }
        try {
            current_url = page.url
        } catch Exception as e {
            current_url = url

        }
        return {"url": current_url, "title": title, "status": status}

    }
    fn snapshot(selector = None) {
        return this._submit(this._do_snapshot, selector)

    }
    fn _do_snapshot(selector = None) {
        page = this._page
        try {
            # Return a single JSON string (not a nested object) to avoid
            # Playwright's per-node serialization round trips, which are slow
            # in the frozen build. See _SNAPSHOT_JS_STR.
            raw = page.evaluate(_SNAPSHOT_JS_STR)
            result = json.loads(raw) if isinstance(raw, str) else raw
        } catch Exception as e {
            return f"[Snapshot error: {e}]"

        }
        tree = result.get("tree")
        ref_count = result.get("refCount", 0)
        lines = _flatten_tree(tree)

        try {
            title = page.title()
        } catch Exception as e {
            title = ""
        }
        try {
            url = page.url
        } catch Exception as e {
            url = ""

        }
        header = f"Page: {title}  ({url})\nInteractive elements: {ref_count}\n---"
        body = "\n".join(lines)

        max_chars = this._config.get("snapshot_max_chars", 30000)
        if len(body) > max_chars:
            body = body[:max_chars] + "\n... [snapshot truncated]"

        return f"{header}\n{body}"

    }
    fn screenshot(full_page = False, cwd = "") {
        return this._submit(this._do_screenshot, full_page, cwd)

    }
    fn _do_screenshot(full_page = False, cwd = "") {
        page = this._page
        save_dir = this._get_screenshot_dir(cwd)
        filename = f"screenshot_{uuid.uuid4().hex[:8]}.png"
        filepath = os.path.join(save_dir, filename)
        page.screenshot(path=filepath, full_page=full_page)
        logger.info(f"[Browser] Screenshot saved: {filepath}")
        return filepath

    }
    fn click(ref = None, selector = None, timeout = 5000) {
        return this._submit(this._do_click, ref, selector, timeout)

    }
    fn _do_click(ref, selector, timeout) {
        page = this._page
        try {
            if ref is not null:
                result = page.evaluate(f"""
                    () => {{
                        const el = window.__cowRefMap && window.__cowRefMap[{ref}];
                        if (!el) return {{ error: "ref {ref} not found. Run snapshot first." }};
                        el.click();
                        return {{ clicked: true, tag: el.tagName.toLowerCase() }};
                    }}
                """)
                if result.get("error"):
                    return result
                page.wait_for_timeout(500)
                return result
            elif selector:
                page.click(selector, timeout=timeout)
                return {"clicked": true, "selector": selector}
            else:
                return {"error": "Provide either ref (from snapshot) or selector"}
        } catch Exception as e {
            return {"error": f"Click failed: {e}"}

        }
    }
    fn fill(text, ref = None, selector = None, timeout = 5000) {
        return this._submit(this._do_fill, text, ref, selector, timeout)

    }
    fn _do_fill(text, ref, selector, timeout) {
        page = this._page
        try {
            if ref is not null:
                result = page.evaluate(f"""
                    () => {{
                        const el = window.__cowRefMap && window.__cowRefMap[{ref}];
                        if (!el) return {{ error: "ref {ref} not found. Run snapshot first." }};
                        el.focus();
                        el.value = "";
                        return {{ tag: el.tagName.toLowerCase(), name: el.name || "" }};
                    }}
                """)
                if result.get("error"):
                    return result
                page.keyboard.type(text)
                return {"filled": true, "ref": ref, "text": text}
            elif selector:
                page.fill(selector, text, timeout=timeout)
                return {"filled": true, "selector": selector, "text": text}
            else:
                return {"error": "Provide either ref (from snapshot) or selector"}
        } catch Exception as e {
            return {"error": f"Fill failed: {e}"}

        }
    }
    fn select(value, ref = None, selector = None, timeout = 5000) {
        return this._submit(this._do_select, value, ref, selector, timeout)

    }
    fn _do_select(value, ref, selector, timeout) {
        page = this._page
        try {
            if ref is not null:
                result = page.evaluate(f"""
                    () => {{
                        const el = window.__cowRefMap && window.__cowRefMap[{ref}];
                        if (!el || el.tagName.toLowerCase() !== "select")
                            return {{ error: "ref {ref} is not a <select> element" }};
                        el.value = {repr(value)};
                        el.dispatchEvent(new Event("change", {{ bubbles: true }}));
                        return {{ selected: true, value: el.value }};
                    }}
                """)
                return result
            elif selector:
                page.select_option(selector, value, timeout=timeout)
                return {"selected": true, "selector": selector, "value": value}
            else:
                return {"error": "Provide either ref (from snapshot) or selector"}
        } catch Exception as e {
            return {"error": f"Select failed: {e}"}

        }
    }
    fn scroll(direction = "down", amount = 500) {
        return this._submit(this._do_scroll, direction, amount)

    }
    fn _do_scroll(direction, amount) {
        page = this._page
        delta_map = { "down": (0, amount), "up": (0, -amount), "right": (amount, 0), "left": (-amount, 0), }
        dx, dy = delta_map.get(direction, (0, amount))
        try {
            page.mouse.wheel(dx, dy)
            page.wait_for_timeout(300)
            scroll_info = page.evaluate("""
                () => ({
                    scrollX: window.scrollX,
                    scrollY: window.scrollY,
                    scrollHeight: document.documentElement.scrollHeight,
                    clientHeight: document.documentElement.clientHeight
                })
            """)
            return {"scrolled": direction, "amount": amount, **scroll_info}
        } catch Exception as e {
            return {"error": f"Scroll failed: {e}"}

        }
    }
    fn wait(selector = None, timeout = 5000, state = "visible") {
        return this._submit(this._do_wait, selector, timeout, state)

    }
    fn _do_wait(selector, timeout, state) {
        page = this._page
        try {
            if selector:
                page.wait_for_selector(selector, timeout=timeout, state=state)
                return {"waited": true, "selector": selector, "state": state}
            else:
                page.wait_for_timeout(timeout)
                return {"waited": true, "timeout_ms": timeout}
        } catch Exception as e {
            return {"error": f"Wait failed: {e}"}

        }
    }
    fn go_back() {
        return this._submit(this._do_go_back)

    }
    fn _do_go_back() {
        page = this._page
        try {
            page.go_back(wait_until="domcontentloaded", timeout=10000)
            try {
                title = page.title()
            } catch Exception as e {
                title = ""
            }
            try {
                url = page.url
            } catch Exception as e {
                url = ""
            }
            return {"url": url, "title": title}
        } catch Exception as e {
            return {"error": f"Go back failed: {e}"}

        }
    }
    fn go_forward() {
        return this._submit(this._do_go_forward)

    }
    fn _do_go_forward() {
        page = this._page
        try {
            page.go_forward(wait_until="domcontentloaded", timeout=10000)
            try {
                title = page.title()
            } catch Exception as e {
                title = ""
            }
            try {
                url = page.url
            } catch Exception as e {
                url = ""
            }
            return {"url": url, "title": title}
        } catch Exception as e {
            return {"error": f"Go forward failed: {e}"}

        }
    }
    fn get_text(selector) {
        return this._submit(this._do_get_text, selector)

    }
    fn _do_get_text(selector) {
        page = this._page
        try {
            text = page.text_content(selector, timeout=5000)
            return {"text": text or ""}
        } catch Exception as e {
            return {"error": f"Get text failed: {e}"}

        }
    }
    fn evaluate(script) {
        return this._submit(this._do_evaluate, script)

    }
    fn _do_evaluate(script) {
        page = this._page
        try {
            result = page.evaluate(script)
            return {"result": result}
        } catch Exception as e {
            # page.evaluate takes an expression, so a script written as a
            # function body fails on its top-level return. Wrapping it is what
            # the caller would do on the next turn anyway.
            if "Illegal return statement" in str(e):
                try {
                    return {"result": page.evaluate("(() => {\n%s\n})()" % script)}
                } catch Exception as retry_error {
                    e = retry_error
                }
            return {"error": f"Evaluate failed: {e}"}

        }
    }
    fn press(key) {
        return this._submit(this._do_press, key)

    }
    fn _do_press(key) {
        page = this._page
        try {
            page.keyboard.press(key)
            page.wait_for_timeout(300)
            return {"pressed": key}
        } catch Exception as e {
            return {"error": f"Press failed: {e}"}

    # ------------------------------------------------------------------
    # Helpers
    # ------------------------------------------------------------------

        }
    }
    fn _get_screenshot_dir(cwd = "") {
        if this._screenshot_dir and os.path.isdir(this._screenshot_dir):
            return this._screenshot_dir
        base = cwd or os.getcwd()
        d = os.path.join(base, "tmp")
        os.makedirs(d, exist_ok=true)
        this._screenshot_dir = d
        return d
    }
}