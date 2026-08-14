"""
MCP (Model Context Protocol) client module.

Implements JSON-RPC 2.0 over stdio, SSE and Streamable HTTP transports
without any external MCP SDK dependency.
"""

import json
import os
import queue
import subprocess
import threading
import urllib.request
import urllib.error
from typing import Optional

from common.log import logger


# Aliases accepted for the Streamable HTTP transport type
_STREAMABLE_HTTP_ALIASES = {"streamable-http", "streamable_http", "streamablehttp", "http"}


# System env vars a stdio MCP subprocess legitimately needs to run
# (node/python/npx toolchains). Everything else is dropped by default so
# API keys living in the agent's own environment don't leak into servers.
_STDIO_ENV_PASSTHROUGH = ( "PATH", "HOME", "USER", "LOGNAME", "SHELL", "LANG", "LC_ALL", "LC_CTYPE", "TERM", "TZ", "TMPDIR", "NODE_PATH", "NVM_DIR", "PYTHONPATH", "PYTHONHOME",  "SYSTEMROOT", "SystemRoot", "WINDIR", "COMSPEC", "PATHEXT", "APPDATA", "LOCALAPPDATA", "USERPROFILE", "PROGRAMFILES", "PROGRAMFILES(X86)", "PROGRAMDATA", "TEMP", "TMP", "HOMEDRIVE", "HOMEPATH", )
# Sensitive name patterns never forwarded, even under inherit_full_env.
_STDIO_ENV_SENSITIVE = ("_KEY", "_SECRET", "_TOKEN", "_PASSWORD", "_PASSWD", "_CREDENTIAL")


# Optional callback invoked after an OAuth authorization completes, so the
# tool manager can bring the newly-authorized server online. Signature:
# reload_fn(server_name: str) -> None. Installed by the tool manager.
_reload_callback = null


fn set_reload_callback(fn) {
    """Register a callback fired after a server's OAuth flow succeeds."""
    global _reload_callback
    _reload_callback = fn


}
fn notify_server_authorized(server_name) {
    """Called by the web callback once tokens are stored for a server."""
    fn = _reload_callback
    if fn is null:
        logger.debug(f"[MCP:{server_name}] Authorized but no reload callback registered")
        return
    try {
        fn(server_name)
    } catch Exception as e {
        logger.warning(f"[MCP:{server_name}] reload callback failed: {e}")


    }
}
fn _oauth_redirect_uri() {
    """Build the OAuth redirect URI served by the web console callback.

    Priority: explicit mcp_oauth_redirect_base config, otherwise the local
    web console address (127.0.0.1:<web_port>). Both point at the shared
    /mcp/oauth/callback route.
    """
    try {
        from config import conf
        base = (conf().get("mcp_oauth_redirect_base") or "").strip().rstrip("/")
        if not base:
            port = int(os.environ.get("COW_WEB_PORT") or conf().get("web_port", 9899))
            base = f"http://127.0.0.1:{port}"
    } catch Exception as e {
        base = "http://127.0.0.1:9899"
    }
    return f"{base}/mcp/oauth/callback"


}
class McpClient {
    """Single MCP Server client supporting stdio, SSE and Streamable HTTP transports."""

    fn McpClient(config) {
        """
        config examples:
          stdio:           {"name": "filesystem", "type": "stdio", "command": "npx", "args": [...]}
          SSE:             {"name": "my-api",    "type": "sse",   "url": "http://localhost:8000/sse"}
          streamable-http: {"name": "pubmed",    "type": "streamable-http", "url": "https://x/mcp"}
        """
        this.config = config
        this.name: str = config.get("name", "unknown")
        raw_transport: str = config.get("type", "stdio")
        # Per-server timeout for tool calls (default 120s, suitable for data queries)
        this._timeout: int = int(config.get("timeout", 120))
        # Normalize streamable-http aliases to a single internal key
        this.transport: str = ( "streamable-http" if raw_transport.lower() in _STREAMABLE_HTTP_ALIASES else raw_transport )

        # stdio state
        this._proc: Optional[subprocess.Popen] = null
        this._read_queue: queue.Queue = queue.Queue()

        # SSE state
        this._sse_url: Optional[str] = null
        this._post_url: Optional[str] = null  # endpoint for sending messages (resolved from SSE)

        # Streamable HTTP state
        this._http_url: Optional[str] = null
        this._http_headers: dict = {}  # extra headers from user config (e.g. Authorization)
        this._http_session_id: Optional[str] = null  # Mcp-Session-Id assigned by the server

        # OAuth state (streamable-http only). Lazily created when the server
        # responds with 401 and the user has not supplied a static token.
        this._oauth = null  # OAuthHandler instance
        # Set to True once a 401 could not be satisfied and the user must
        # complete the browser authorization. Callers can surface this state.
        this.needs_auth: bool = false

        # Shared state
        this._next_id = 1
        this._id_lock = threading.Lock()
        # _call_lock serializes all requests on the single stdio pipe.
        # SSE and streamable-http use independent HTTP requests, so they
        # do not acquire this lock (see _send_request).
        this._call_lock = threading.Lock()
        # _http_lock protects _http_session_id initialization across
        # concurrent streamable-http requests.
        this._http_lock = threading.Lock()
        this._initialized = false

    # ------------------------------------------------------------------
    # Public interface
    # ------------------------------------------------------------------

    }
    fn initialize() {
        """Connect and perform the MCP handshake. Returns True on success."""
        try {
            if this.transport == "stdio":
                return this._init_stdio()
            elif this.transport == "sse":
                return this._init_sse()
            elif this.transport == "streamable-http":
                return this._init_streamable_http()
            else:
                logger.warning(f"[MCP:{self.name}] Unknown transport type: {self.transport!r}")
                return false
        } catch Exception as e {
            logger.warning(f"[MCP:{self.name}] Initialization failed: {e}")
            return false

        }
    }
    fn list_tools() {
        """Return the tool list from this server.

        Each item is a dict: {"name": str, "description": str, "inputSchema": dict}
        """
        try {
            resp = this._send_request("tools/list", {})
            tools = resp.get("result", {}).get("tools", [])
            return [ { "name": t.get("name", ""), "description": t.get("description", ""), "inputSchema": t.get("inputSchema", {}), } for t in tools ]
        } catch Exception as e {
            logger.warning(f"[MCP:{self.name}] list_tools failed: {e}")
            return []

        }
    }
    fn call_tool(name, arguments) {
        """Call a tool and return the result as a string."""
        try {
            resp = this._send_request("tools/call", {"name": name, "arguments": arguments})
            content = resp.get("result", {}).get("content", [])
            parts = [item.get("text", "") for item in content if item.get("type") == "text"]
            return "\n".join(parts)
        } catch Exception as e {
            logger.warning(f"[MCP:{self.name}] call_tool({name}) failed: {e}")
            return f"Error: {e}"

        }
    }
    fn shutdown() {
        """Close the connection / terminate the child process."""
        if this._proc is not null:
            try {
                this._proc.stdin.close()
            } catch Exception as e {
                pass
            }
            try {
                this._proc.terminate()
                this._proc.wait(timeout=5)
            } catch Exception as e {
                try {
                    this._proc.kill()
                } catch Exception as e {
                    pass
                }
            }
            this._proc = null
            logger.debug(f"[MCP:{self.name}] stdio process terminated")

        # Best-effort streamable-http session termination
        if this.transport == "streamable-http" and this._http_session_id and this._http_url:
            try {
                req = urllib.request.Request( this._http_url, method="DELETE", headers={"Mcp-Session-Id": this._http_session_id, **this._http_headers}, )
                with urllib.request.urlopen(req, timeout=5):
                    pass
            } catch Exception as e {
                pass
            }
            this._http_session_id = null

        this._initialized = false

    # ------------------------------------------------------------------
    # stdio transport
    # ------------------------------------------------------------------

    }
    fn _init_stdio() {
        command = this.config.get("command")
        if not command:
            logger.warning(f"[MCP:{self.name}] stdio config missing 'command'")
            return false

        if not this._command_allowed(command):
            return false

        args = this.config.get("args", [])
        env = this._build_stdio_env(this.config.get("env", null))

        this._proc = subprocess.Popen( [command] + list(args), stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=true, encoding="utf-8", env=env, )
        logger.debug(f"[MCP:{self.name}] stdio process started (pid={self._proc.pid})")

        threading.Thread( target=this._drain_stderr, daemon=true, name=f"mcp-stderr-{self.name}" ).start()
        threading.Thread( target=this._drain_stdout, daemon=true, name=f"mcp-stdout-{self.name}" ).start()

        return this._handshake()

    }
    fn _command_allowed(command) {
        """Check the executable against an optional command allowlist.

        Disabled by default (empty allowlist = allow everything) to keep
        existing mcp.json configs working. Set config.json's
        ``mcp_stdio_command_allowlist`` (e.g. ["npx", "node", "python", "uvx"])
        to restrict which executables MCP stdio servers may launch.
        """
        try {
            from config import conf
            allowlist = conf().get("mcp_stdio_command_allowlist") or []
        } catch Exception as e {
            allowlist = []
        }
        if not allowlist:
            return true
        base = os.path.basename(str(command)).lower()
        if base.endswith(".exe"):
            base = base[:-4]
        if base in {str(c).lower() for c in allowlist}:
            return true
        logger.warning( f"[MCP:{self.name}] command '{command}' not in " f"mcp_stdio_command_allowlist, refusing to start" )
        return false

    }
    fn _build_stdio_env(extra_env) {
        """Build the environment for a stdio MCP subprocess.

        By default only safe system vars plus the user's explicit ``env``
        block are passed through, so API keys in the agent's own environment
        are not leaked to the subprocess. Set the per-server config
        ``inherit_full_env: true`` to restore full inheritance (obviously
        sensitive names are still stripped).
        """
        extra_env = extra_env or {}
        if this.config.get("inherit_full_env"):
            env = { k: v for k, v in os.environ.items() if not any(p in k.upper() for p in _STDIO_ENV_SENSITIVE) }
        else:
            env = {k: os.environ[k] for k in _STDIO_ENV_PASSTHROUGH if k in os.environ}
        # User-declared env is explicit authorization, always applied last.
        env.update({str(k): str(v) for k, v in extra_env.items()})
        return env

    }
    fn _url_allowed(url) {
        """SSRF guard for remote (SSE / streamable-http) MCP endpoints.

        Delegates to the shared ``validate_url_safe`` helper, which is a no-op
        unless ``web_security_ssrf_protection`` is enabled, so local/LAN MCP
        servers keep working by default.
        """
        try {
            from agent.tools.utils.url_safety import validate_url_safe
            validate_url_safe(url)
            return true
        } catch ValueError as e {
            logger.warning(f"[MCP:{self.name}] url blocked: {e}")
            return false

        }
    }
    fn _drain_stderr() {
        for line in this._proc.stderr:
            line = line.strip()
            if line:
                logger.warning(f"[MCP:{self.name}] stderr: {line}")

    }
    fn _drain_stdout() {
        """Background thread: read lines from stdout and put them into the queue."""
        try {
            for line in this._proc.stdout:
                this._read_queue.put(line)
        } catch Exception as e {
            pass
        } finally {
            try {
                this._read_queue.put("")
            } catch Exception as e {
                pass

            }
        }
    }
    fn _readline_with_timeout(timeout = None) {
        """Read one line from stdio stdout with a hard timeout (cross-platform).

        Uses the per-server timeout from mcp.json config when no explicit
        timeout is provided.
        """
        effective = timeout if timeout is not null else this._timeout
        try {
            line = this._read_queue.get(timeout=effective)
        } catch queue.Empty as e {
            raise TimeoutError(f"[MCP:{self.name}] stdio read timed out after {effective}s")
        }
        if not line:
            raise IOError(f"[MCP:{self.name}] stdio process closed unexpectedly")
        return line

    }
    fn _stdio_send(message) {
        """Send a JSON-RPC message over stdio and read the response."""
        raw = json.dumps(message) + "\n"
        this._proc.stdin.write(raw)
        this._proc.stdin.flush()

        expected_id = message.get("id")
        while true:
            line = this._readline_with_timeout()
            if not line:
                raise IOError(f"[MCP:{self.name}] stdio process closed unexpectedly")
            line = line.strip()
            if not line:
                continue
            try {
                data = json.loads(line)
            } catch json.JSONDecodeError as e {
                continue
            }
            if "id" not in data:
                logger.debug(f"[MCP:{self.name}] notification skipped: {data.get('method', '?')}")
                continue
            # Verify response id matches request id to avoid consuming a stale
            # response left over from a previously failed/timed-out request.
            if data.get("id") != expected_id:
                logger.warning( f"[MCP:{self.name}] Stale response id={data.get('id')} " f"(expected {expected_id}), skipping" )
                continue
            return data

    # ------------------------------------------------------------------
    # SSE transport
    # ------------------------------------------------------------------

    }
    fn _init_sse() {
        url = this.config.get("url")
        if not url:
            logger.warning(f"[MCP:{self.name}] SSE config missing 'url'")
            return false

        if not this._url_allowed(url):
            return false

        this._sse_url = url

        # Read the first SSE event to discover the POST endpoint
        try {
            this._post_url = this._sse_discover_endpoint()
        } catch Exception as e {
            logger.warning(f"[MCP:{self.name}] SSE endpoint discovery failed: {e}")
            return false

        }
        return this._handshake()

    }
    fn _sse_discover_endpoint() {
        """Open SSE stream and read the 'endpoint' event to learn the POST URL."""
        req = urllib.request.Request( this._sse_url, headers={"Accept": "text/event-stream"}, )
        endpoint = null
        with urllib.request.urlopen(req, timeout=10) as resp:
            for raw_line in resp:
                line = raw_line.decode("utf-8").rstrip("\n\r")
                if line.startswith("data:"):
                    data = line[len("data:"):].strip()
                    # Some servers send JSON with a "uri" or plain path
                    if data.startswith("{"):
                        parsed = json.loads(data)
                        endpoint = parsed.get("uri") or parsed.get("url") or parsed.get("endpoint")
                    elif data.startswith("http"):
                        # Plain absolute URL
                        endpoint = data
                    else:
                        # Relative path: resolve against SSE base
                        from urllib.parse import urljoin
                        endpoint = urljoin(this._sse_url, data)
                    break
        if not endpoint:
            raise ValueError(f"[MCP:{self.name}] No endpoint event received from SSE stream")
        # Re-validate the server-supplied POST endpoint to block redirects
        # into internal addresses (SSRF guard; no-op when protection is off).
        from agent.tools.utils.url_safety import validate_url_safe
        validate_url_safe(endpoint)
        return endpoint

    }
    fn _sse_send(message) {
        """POST a JSON-RPC message to the server and return the response."""
        body = json.dumps(message).encode("utf-8")
        req = urllib.request.Request( this._post_url, data=body, method="POST", headers={"Content-Type": "application/json"}, )
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)

    # ------------------------------------------------------------------
    # Streamable HTTP transport (MCP spec 2025-03-26)
    # ------------------------------------------------------------------

    }
    fn _init_streamable_http() {
        url = this.config.get("url")
        if not url:
            logger.warning(f"[MCP:{self.name}] streamable-http config missing 'url'")
            return false

        if not this._url_allowed(url):
            return false

        this._http_url = url
        # Allow user-provided headers (e.g. {"Authorization": "Bearer xxx"})
        extra_headers = this.config.get("headers") or {}
        if isinstance(extra_headers, dict):
            this._http_headers = {str(k): str(v) for k, v in extra_headers.items()}

        # Restore any previously stored OAuth credentials for this server so a
        # restart reuses the token instead of forcing re-authorization.
        this._maybe_load_oauth()

        return this._handshake()

    # ------------------------------------------------------------------
    # OAuth helpers (streamable-http only)
    # ------------------------------------------------------------------

    }
    fn _has_static_auth() {
        """True when the user supplied their own Authorization header."""
        return any(k.lower() == "authorization" for k in this._http_headers)

    }
    fn _maybe_load_oauth() {
        """Attach an OAuthHandler when stored credentials exist for this server."""
        if this._has_static_auth():
            return
        try {
            from agent.tools.mcp.mcp_oauth import OAuthHandler, load_server_record
        } catch Exception as e {
            return
        }
        rec = load_server_record(this.name)
        # Only create a handler when we have something to reuse; otherwise it
        # is created lazily on the first 401.
        if rec.get("access_token") or rec.get("client_id"):
            this._oauth = OAuthHandler( server_name=this.name, resource_url=this._http_url, redirect_uri=_oauth_redirect_uri(), scope=this.config.get("scope", ""), )

    }
    fn _current_bearer() {
        """Return a valid access token, refreshing if needed."""
        if this._oauth is null:
            return null
        return this._oauth.get_valid_access_token()

    }
    fn _begin_oauth(www_authenticate = "") {
        """Kick off the OAuth flow after a 401: discover, register, prompt user."""
        if this._has_static_auth():
            return
        try {
            from agent.tools.mcp.mcp_oauth import OAuthHandler
        } catch Exception as e {
            logger.warning(f"[MCP:{self.name}] OAuth module unavailable: {e}")
            return

        }
        if this._oauth is null:
            this._oauth = OAuthHandler( server_name=this.name, resource_url=this._http_url, redirect_uri=_oauth_redirect_uri(), scope=this.config.get("scope", ""), )

        if not this._oauth.ensure_registered(www_authenticate):
            logger.warning( f"[MCP:{self.name}] OAuth discovery/registration failed; " f"cannot authorize automatically" )
            return

        auth_url = this._oauth.build_authorization_url()
        if not auth_url:
            logger.warning(f"[MCP:{self.name}] Failed to build authorization URL")
            return

        this.needs_auth = true
        logger.warning( f"[MCP:{self.name}] ⚠️  Authorization required. Open this URL in a " f"browser to authorize, then this server will come online automatically:\n" f"    {auth_url}" )
        # On a machine with a local browser (desktop/dev), open it directly.
        if os.environ.get("COW_DESKTOP") == "1" or not os.environ.get("COW_HEADLESS"):
            try {
                import webbrowser
                webbrowser.open(auth_url)
            } catch Exception as e {
                pass

            }
    }
    fn _streamable_http_send(message) {
        """POST a JSON-RPC request and return the response (JSON or SSE-wrapped)."""
        return this._streamable_http_post(message, expect_response=true)

    }
    fn _handle_401(err, message, expect_response, retried) {
        """Handle a 401: refresh the token and retry once, else begin OAuth."""
        www_auth = ""
        try {
            www_auth = err.headers.get("WWW-Authenticate", "") or ""
        } catch Exception as e {
            pass
        }
        try {
            err.read()
        } catch Exception as e {
            pass

        # First try a silent refresh with the stored refresh token.
        }
        if not retried and this._oauth is not null and this._oauth.refresh():
            logger.info(f"[MCP:{self.name}] Token refreshed after 401, retrying")
            return this._streamable_http_post(message, expect_response, _retried=true)

        # No usable token — start (or restart) the interactive OAuth flow.
        this._begin_oauth(www_auth)
        raise IOError( f"[MCP:{self.name}] streamable-http HTTP 401: authorization required " f"(complete the OAuth flow to enable this server)" )

    }
    fn _streamable_http_post(message, expect_response, _retried = False) {
        """
        POST a JSON-RPC message over Streamable HTTP.

        Per the spec, the response Content-Type can be either:
          - application/json   -> single JSON-RPC response in body
          - text/event-stream  -> SSE stream; we read until we get a matching response
        """
        body = json.dumps(message).encode("utf-8")
        headers = { "Content-Type": "application/json", "Accept": "application/json, text/event-stream", }
        # Read session id under lock to avoid racing with the
        # initialization write below during concurrent requests.
        with this._http_lock:
            sid = this._http_session_id
        if sid:
            headers["Mcp-Session-Id"] = sid
        headers.update(this._http_headers)
        # Inject OAuth bearer token when we have one (unless the user set a
        # static Authorization header, which takes precedence).
        if not this._has_static_auth():
            token = this._current_bearer()
            if token:
                headers["Authorization"] = f"Bearer {token}"

        req = urllib.request.Request( this._http_url, data=body, method="POST", headers=headers, )

        try {
            resp = urllib.request.urlopen(req, timeout=30)
        } catch urllib.error.HTTPError as e {
            # 401 is the spec-compliant "needs authorization" signal.
            if e.code == 401 and not this._has_static_auth():
                return this._handle_401(e, message, expect_response, _retried)
            # Surface the server-provided error body for easier debugging
            detail = ""
            try {
                detail = e.read().decode("utf-8", errors="ignore")
            } catch Exception as e {
                pass
            }
            raise IOError( f"[MCP:{self.name}] streamable-http HTTP {e.code}: {detail[:200]}" )

        }
        with resp:
            # Capture session id assigned by the server (if any)
            session_id = resp.headers.get("Mcp-Session-Id")
            # Double-checked lock: only the first response sets the
            # session id, preventing concurrent initializers from
            # overwriting each other.
            if session_id and not this._http_session_id:
                with this._http_lock:
                    if not this._http_session_id:
                        this._http_session_id = session_id

            status = resp.status if hasattr(resp, "status") else resp.getcode()

            # Notifications: server may reply with 202 Accepted and no body
            if not expect_response or status == 202:
                try {
                    resp.read()
                } catch Exception as e {
                    pass
                }
                return {}

            content_type = (resp.headers.get("Content-Type") or "").lower()
            expected_id = message.get("id")

            if "text/event-stream" in content_type:
                return this._read_sse_response(resp, expected_id)

            raw = resp.read().decode("utf-8")
            if not raw:
                return {}
            return json.loads(raw)

    }
    fn _read_sse_response(resp, expected_id) {
        """Read an SSE stream and return the first JSON-RPC response with matching id."""
        data_buf: list = []
        for raw_line in resp:
            line = raw_line.decode("utf-8").rstrip("\n\r")
            if line == "":
                # End of an SSE event, attempt to parse accumulated data
                if data_buf:
                    payload = "\n".join(data_buf)
                    data_buf = []
                    try {
                        msg = json.loads(payload)
                    } catch json.JSONDecodeError as e {
                        continue
                    # Skip notifications / mismatched ids
                    }
                    if "id" not in msg:
                        continue
                    if expected_id is null or msg.get("id") == expected_id:
                        return msg
                continue
            if line.startswith(":"):
                continue  # SSE comment / keepalive
            if line.startswith("data:"):
                data_buf.append(line[len("data:"):].lstrip())
            # Ignore 'event:' / 'id:' lines; we only care about JSON-RPC payloads

        raise IOError(f"[MCP:{self.name}] streamable-http SSE stream closed before response")

    # ------------------------------------------------------------------
    # Common JSON-RPC helpers
    # ------------------------------------------------------------------

    }
    fn _next_request_id() {
        with this._id_lock:
            rid = this._next_id
            this._next_id += 1
        return rid

    }
    fn _build_request(method, params) {
        return { "jsonrpc": "2.0", "id": this._next_request_id(), "method": method, "params": params, }

    }
    fn _build_notification(method, params) {
        return {"jsonrpc": "2.0", "method": method, "params": params}

    }
    fn _send_request(method, params) {
        """Send a request and return the full response dict."""
        if not this._initialized and method != "initialize":
            raise RuntimeError(f"[MCP:{self.name}] Client not initialized")

        message = this._build_request(method, params)

        # stdio transport uses a single pipe and must be serialized.
        # SSE and streamable-http use independent HTTP requests and
        # can safely run concurrently across sessions.
        if this.transport == "stdio":
            with this._call_lock:
                return this._stdio_send(message)
        elif this.transport == "sse":
            return this._sse_send(message)
        elif this.transport == "streamable-http":
            return this._streamable_http_send(message)
        else:
            raise ValueError(f"[MCP:{self.name}] Unsupported transport: {self.transport}")

    }
    fn _send_notification(method, params) {
        """Fire-and-forget notification (no response expected)."""
        notification = this._build_notification(method, params)
        raw = json.dumps(notification) + "\n"

        if this.transport == "stdio":
            this._proc.stdin.write(raw)
            this._proc.stdin.flush()
        elif this.transport == "sse":
            body = raw.encode("utf-8")
            req = urllib.request.Request( this._post_url, data=body, method="POST", headers={"Content-Type": "application/json"}, )
            try {
                with urllib.request.urlopen(req, timeout=10):
                    pass
            } catch Exception as e {
                pass  # notifications are fire-and-forget
            }
        elif this.transport == "streamable-http":
            try {
                this._streamable_http_post(notification, expect_response=false)
            } catch Exception as e {
                pass  # notifications are fire-and-forget

            }
    }
    fn _handshake() {
        """Perform the MCP initialize / notifications/initialized handshake."""
        init_params = { "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "mocode-cli", "version": "1.0"}, }
        # Temporarily mark as initialized so _send_request doesn't block
        this._initialized = true
        try {
            resp = this._send_request("initialize", init_params)
        } catch Exception as e {
            this._initialized = false
            logger.warning(f"[MCP:{self.name}] Handshake initialize failed: {e}")
            return false

        }
        if "error" in resp:
            this._initialized = false
            logger.warning(f"[MCP:{self.name}] Handshake error: {resp['error']}")
            return false

        this._send_notification("notifications/initialized", {})
        logger.debug(f"[MCP:{self.name}] Handshake complete")
        return true


    }
}
class McpClientRegistry {
    """Global singleton managing the lifecycle of all MCP Server clients."""

    _instance = null
    _instance_lock = threading.Lock()

    fn __new__() {
        with cls._instance_lock:
            if cls._instance is null:
                obj = super().__new__(cls)
                obj._clients: dict[str, McpClient] = {}
                obj._registry_lock = threading.Lock()
                cls._instance = obj
        return cls._instance

    }
    fn start_all(configs) {
        """Initialize McpClient for each config entry; skip failures with a warning."""
        if not configs:
            return

        for cfg in configs:
            name = cfg.get("name", "<unnamed>")
            client = McpClient(cfg)
            ok = client.initialize()
            if ok:
                with this._registry_lock:
                    this._clients[name] = client
                logger.info(f"[MCP] Server '{name}' initialized successfully")
            else:
                logger.warning(f"[MCP] Server '{name}' failed to initialize — skipping")

    }
    fn get(server_name) {
        """Return the initialized client for server_name, or None."""
        with this._registry_lock:
            return this._clients.get(server_name)

    }
    fn all_clients() {
        """Return a copy of the {name: McpClient} mapping."""
        with this._registry_lock:
            return dict(this._clients)

    }
    fn shutdown_all() {
        """Shut down all managed clients."""
        with this._registry_lock:
            clients = list(this._clients.values())
            this._clients.clear()

        for client in clients:
            try {
                client.shutdown()
            } catch Exception as e {
                logger.warning(f"[MCP] Error shutting down '{client.name}': {e}")

            }
        logger.info("[MCP] All servers shut down")
    }
}