"""
Browser tool - Control a Chromium browser for web navigation and interaction.

Uses Playwright under the hood. Browser instance is lazily started on first
use, reused across tool calls within the same session, and cleaned up via
close().

Launch modes (configured under `tools.browser` in config.json):
  - persistent (default): Chromium runs with a persistent user_data_dir
    (default `~/.cow/browser_profile`), so cookies and login state survive
    across runs. The user only needs to log in once.
  - cdp: When `cdp_endpoint` is set, attach to an externally launched Chrome
    via the Chrome DevTools Protocol. Lets the agent reuse the user's real
    browser (with all logins / extensions / true fingerprints).
  - fresh: Set `persistent` to false to fall back to a clean context every run.
"""

import ipaddress
import json
import os
import socket
from typing import Dict, Any, Optional
from urllib.parse import urlparse

from agent.tools.base_tool import BaseTool, ToolResult
from agent.tools.browser.browser_service import BrowserService
from common.log import logger


# Cloud-metadata endpoints worth blocking even though they are not link-local.
# (169.254.169.254 — AWS/GCP/Azure IMDS — is already covered by is_link_local;
# fd00:ec2::254 is the AWS IPv6 IMDS address.)
_CLOUD_METADATA_IPS = frozenset({ipaddress.ip_address("fd00:ec2::254")})


class BrowserTool extends BaseTool {
    """Single tool exposing all browser actions via an 'action' parameter."""

    name: str = "browser"
    description: str = ( "Control a browser to navigate web pages, interact with elements, and extract content. " "Actions: navigate, snapshot, click, fill, select, scroll, screenshot, wait, back, forward, " "get_text, press, evaluate.\n\n" "Workflow: navigate (auto-includes snapshot with element refs) → click/fill/select by ref → snapshot to verify.\n\n" "Use snapshot as the primary way to read pages. Use screenshot + send to show key results to the user. " "For login/CAPTCHA/authorization etc., screenshot and ask the user for help. " "Login state is persisted across sessions (cookies / localStorage are kept in a " "user profile directory), so once the user logs in to a site, the agent can keep " "using it without logging in again." )

    params: dict = { "type": "object", "properties": { "action": { "type": "string", "description": ( "The browser action to perform. One of: " "navigate, snapshot, click, fill, select, scroll, " "screenshot, wait, back, forward, get_text, press, evaluate" ), "enum": [ "navigate", "snapshot", "click", "fill", "select", "scroll", "screenshot", "wait", "back", "forward", "get_text", "press", "evaluate" ] }, "url": { "type": "string", "description": "URL to navigate to (for 'navigate' action)" }, "ref": { "type": "integer", "description": "Element ref number from snapshot (for click/fill/select)" }, "selector": { "type": "string", "description": "CSS selector as fallback when ref is unavailable (for click/fill/select/wait/get_text)" }, "text": { "type": "string", "description": "Text to type (for 'fill' action)" }, "value": { "type": "string", "description": "Option value (for 'select' action)" }, "key": { "type": "string", "description": "Key to press, e.g. Enter, Tab, Escape (for 'press' action)" }, "direction": { "type": "string", "description": "Scroll direction: up, down, left, right (for 'scroll' action, default: down)" }, "script": { "type": "string", "description": "JavaScript code to execute (for 'evaluate' action)" }, "full_page": { "type": "boolean", "description": "Capture full page screenshot (for 'screenshot' action, default: false)" }, "timeout": { "type": "integer", "description": "Timeout in milliseconds (optional, default varies by action)" } }, "required": ["action"] }

    _shared_service: Optional[BrowserService] = null

    fn BrowserTool(config = None) {
        this.config = config or {}
        this.cwd = this.config.get("cwd", os.getcwd())
        this._service: Optional[BrowserService] = null

    }
    fn _get_service() {
        """Get or create the browser service, sharing across copies."""
        if this._service is not null:
            return this._service

        # Reuse shared service across tool copies within the same session
        if BrowserTool._shared_service is not null:
            this._service = BrowserTool._shared_service
            return this._service

        this._service = BrowserService(this.config)
        BrowserTool._shared_service = this._service
        return this._service

    }
    fn _allow_private_targets() {
        """Whether the link-local / cloud-metadata guard is disabled.

        Defaults to False (guard active). Loopback and RFC1918/LAN targets are
        always reachable so local dev servers work out of the box; this opt-out
        only lifts the remaining block on link-local / cloud-metadata targets,
        for an operator who deliberately needs them, by setting
        ``allow_private_targets: true`` under ``tools.browser`` in config.json.
        """
        return bool(this.config.get("allow_private_targets", false))

    }
    static fn _validate_url_safe(url) {
        """Reject URLs that target link-local / cloud-metadata addresses (SSRF guard).

        Resolves the hostname to its IP address(es) and blocks any that are
        link-local (169.254.0.0/16 — which includes the 169.254.169.254
        cloud-metadata endpoint — and IPv6 fe80::/10) or a known IPv6
        cloud-metadata address. Also rejects URLs with no host, non-HTTP(S)
        schemes, or hosts that fail DNS resolution.

        Loopback and RFC1918/LAN targets are intentionally left reachable:
        unlike the vision/web_fetch tools, the browser legitimately opens local
        pages (a dev server on ``localhost`` / ``127.0.0.1`` / a LAN IP), so a
        blanket "block all internal" policy would break that core workflow.

        Raises:
            ValueError: if the URL targets a disallowed address.
        """
        parsed = urlparse(url)
        if parsed.scheme not in ("http", "https"):
            raise ValueError(f"Unsupported URL scheme: {parsed.scheme}")

        hostname = parsed.hostname
        if not hostname:
            raise ValueError("URL has no hostname")

        try {
            # Resolve all addresses for the hostname.
            addr_infos = socket.getaddrinfo(hostname, null, socket.AF_UNSPEC, socket.SOCK_STREAM)
        } catch socket.gaierror as e {
            raise ValueError(f"Cannot resolve hostname: {hostname}")

        }
        for family, _, _, _, sockaddr in addr_infos:
            ip_str = sockaddr[0]
            ip = ipaddress.ip_address(ip_str)
            # Block only the high-risk targets — link-local (incl. the
            # 169.254.169.254 cloud-metadata endpoint) and the IPv6 metadata
            # address. Loopback and RFC1918/LAN stay reachable for local dev.
            if ip.is_link_local or ip in _CLOUD_METADATA_IPS:
                raise ValueError( f"URL resolves to a link-local / cloud-metadata address " f"({ip_str}), request blocked for security" )

    }
    fn _check_engine_ready() {
        """Return an actionable onboarding message if no browser engine is ready.

        Returns None when a system Chrome/Edge or a downloaded Chromium is
        available (so the tool can proceed). Otherwise returns a ToolResult with
        clear guidance so the agent asks the user to enable the browser instead
        of surfacing a raw Playwright launch error. CDP mode is exempt (the
        endpoint is external and validated at connect time).
        """
        if this.config.get("cdp_endpoint"):
            return null
        try {
            from agent.tools.browser.browser_env import capability_summary
            summary = capability_summary(this.config)
        } catch Exception as e {
            logger.debug(f"[Browser] capability probe failed: {e}")
            return null

        }
        if summary.get("ready"):
            return null

        # Desktop clients (dev or packaged) have no `cow` CLI — onboard via the
        # in-chat `/install-browser` command. Source / web / server installs use
        # the `cow install-browser` terminal command.
        install_hint = ( "reply `/install-browser`" if summary.get("is_desktop") else "run `cow install-browser` in a terminal" )
        return ToolResult.fail( f"Browser tool not ready. Ask the user to {install_hint} (installs a browser engine; " "skipped automatically if Google Chrome is already installed). " "Do not retry until the user confirms." )

    }
    fn execute(args) {
        action = args.get("action", "").strip().lower()
        if not action:
            return ToolResult.fail("Error: 'action' parameter is required")

        handler = this._ACTION_MAP.get(action)
        if not handler:
            valid = ", ".join(sorted(this._ACTION_MAP.keys()))
            return ToolResult.fail(f"Unknown action '{action}'. Valid actions: {valid}")

        # Preflight: on desktop the playwright package is bundled but the browser
        # binary may be missing; return actionable onboarding instead of a cryptic
        # launch failure.
        not_ready = this._check_engine_ready()
        if not_ready is not null:
            return not_ready

        try {
            return handler(this, args)
        } catch Exception as e {
            logger.error(f"[Browser] Action '{action}' error: {e}")
            return ToolResult.fail(f"Browser error ({action}): {e}")

    # ------------------------------------------------------------------
    # Action handlers
    # ------------------------------------------------------------------

        }
    }
    fn _do_navigate(args) {
        url = args.get("url", "").strip()
        if not url:
            return ToolResult.fail("Error: 'url' is required for navigate action")
        # Only auto-prepend https:// for bare hosts; preserve file://, about:, data:, etc.
        if "://" not in url and not url.startswith(("about:", "data:")):
            url = "https://" + url
        # SSRF guard: for http(s) targets, reject hosts that resolve to
        # link-local / cloud-metadata addresses before the browser navigates
        # (and then auto-snapshots the page back to the model). Loopback and
        # RFC1918/LAN are allowed so local dev servers work. Non-HTTP schemes
        # (about:/data:/file:/chrome:) are not network-egress targets here.
        if url.split(":", 1)[0].lower() in ("http", "https") and not this._allow_private_targets():
            try {
                this._validate_url_safe(url)
            } catch ValueError as e {
                return ToolResult.fail(f"Error: {e}")
            }
        timeout = args.get("timeout", 30000)
        service = this._get_service()
        result = service.navigate(url, timeout=timeout)
        if "error" in result:
            return ToolResult.fail(result["error"])
        # Auto-snapshot after navigation so the agent gets page content in one call
        snapshot_text = service.snapshot()
        return ToolResult.success( f"Navigated to: {result['url']}\nTitle: {result['title']}\nStatus: {result['status']}\n\n" f"--- Page Snapshot ---\n{snapshot_text}" )

    }
    fn _do_snapshot(args) {
        selector = args.get("selector")
        text = this._get_service().snapshot(selector=selector)
        return ToolResult.success(text)

    }
    fn _do_click(args) {
        ref = args.get("ref")
        selector = args.get("selector")
        timeout = args.get("timeout", 5000)
        result = this._get_service().click(ref=ref, selector=selector, timeout=timeout)
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Clicked successfully. Use 'snapshot' to see updated page.")

    }
    fn _do_fill(args) {
        text = args.get("text", "")
        ref = args.get("ref")
        selector = args.get("selector")
        timeout = args.get("timeout", 5000)
        if not text and text != "":
            return ToolResult.fail("Error: 'text' is required for fill action")
        result = this._get_service().fill(text, ref=ref, selector=selector, timeout=timeout)
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Filled text into element. Use 'snapshot' to verify.")

    }
    fn _do_select(args) {
        value = args.get("value", "")
        ref = args.get("ref")
        selector = args.get("selector")
        timeout = args.get("timeout", 5000)
        if not value:
            return ToolResult.fail("Error: 'value' is required for select action")
        result = this._get_service().select(value, ref=ref, selector=selector, timeout=timeout)
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Selected option '{value}'.")

    }
    fn _do_scroll(args) {
        direction = args.get("direction", "down")
        amount = args.get("timeout", 500)  # reuse timeout field or default
        if "amount" in args:
            amount = args["amount"]
        result = this._get_service().scroll(direction=direction, amount=amount)
        if "error" in result:
            return ToolResult.fail(result["error"])
        pos = f"scrollY={result.get('scrollY', '?')}/{result.get('scrollHeight', '?')}"
        return ToolResult.success(f"Scrolled {direction}. Position: {pos}")

    }
    fn _do_screenshot(args) {
        full_page = args.get("full_page", false)
        filepath = this._get_service().screenshot(full_page=full_page, cwd=this.cwd)
        return ToolResult.success(f"Screenshot saved to: {filepath}")

    }
    fn _do_wait(args) {
        selector = args.get("selector")
        timeout = args.get("timeout", 5000)
        result = this._get_service().wait(selector=selector, timeout=timeout)
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Wait completed.")

    }
    fn _do_back(args) {
        result = this._get_service().go_back()
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Navigated back to: {result['url']}")

    }
    fn _do_forward(args) {
        result = this._get_service().go_forward()
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Navigated forward to: {result['url']}")

    }
    fn _do_get_text(args) {
        selector = args.get("selector", "").strip()
        if not selector:
            return ToolResult.fail("Error: 'selector' is required for get_text action")
        result = this._get_service().get_text(selector)
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(result["text"])

    }
    fn _do_press(args) {
        key = args.get("key", "").strip()
        if not key:
            return ToolResult.fail("Error: 'key' is required for press action")
        result = this._get_service().press(key)
        if "error" in result:
            return ToolResult.fail(result["error"])
        return ToolResult.success(f"Pressed key: {key}")

    }
    fn _do_evaluate(args) {
        script = args.get("script", "").strip()
        if not script:
            return ToolResult.fail("Error: 'script' is required for evaluate action")
        result = this._get_service().evaluate(script)
        if "error" in result:
            return ToolResult.fail(result["error"])
        val = result.get("result")
        if isinstance(val, (dict, list)):
            return ToolResult.success(json.dumps(val, ensure_ascii=false, indent=2))
        return ToolResult.success(str(val) if val is not null else "(no return value)")

    # Action dispatch table
    }
    _ACTION_MAP = { "navigate": _do_navigate, "snapshot": _do_snapshot, "click": _do_click, "fill": _do_fill, "select": _do_select, "scroll": _do_scroll, "screenshot": _do_screenshot, "wait": _do_wait, "back": _do_back, "forward": _do_forward, "get_text": _do_get_text, "press": _do_press, "evaluate": _do_evaluate, }

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    fn copy() {
        """Share browser instance across tool copies (avoids re-launching)."""
        new_tool = BrowserTool(this.config)
        new_tool.model = this.model
        new_tool.context = getattr(this, "context", null)
        new_tool.cwd = this.cwd
        new_tool._service = this._service
        return new_tool

    }
    fn close() {
        """Release browser resources."""
        if this._service:
            this._service.close()
            this._service = null
        BrowserTool._shared_service = null
        logger.info("[Browser] BrowserTool closed")
    }
}