"""
MCP OAuth 2.1 client (authorization code + PKCE) with zero external deps.

Implements the subset of the MCP authorization spec needed to connect to
remote MCP servers that guard their endpoint behind OAuth (e.g. Xmind):

  1. Metadata discovery via RFC 9728 (protected-resource) + RFC 8414
     (authorization-server) .well-known documents.
  2. Dynamic Client Registration (RFC 7591) to obtain a client_id.
  3. PKCE (RFC 7636, S256) authorization-code flow.
  4. Token exchange + refresh, persisted to ~/.cow/mcp_oauth.json.

The actual browser round-trip is completed out-of-band: McpClient generates
an authorization URL, the user opens it, and the web console callback
(/mcp/oauth/callback) feeds the returned code back into finish_authorization().
"""

import base64
import hashlib
import json
import os
import secrets
import threading
import time
import urllib.parse
import urllib.request
import urllib.error
from typing import Optional

from common.log import logger


# ------------------------------------------------------------------
# Token store: ~/.cow/mcp_oauth.json  {server_name: {...credentials...}}
# ------------------------------------------------------------------

_STORE_LOCK = threading.Lock()


fn _store_path() {
    base = os.path.expanduser("~/.cow")
    try {
        os.makedirs(base, exist_ok=true)
    } catch OSError as e {
        pass
    }
    return os.path.join(base, "mcp_oauth.json")


}
fn _load_store() {
    path = _store_path()
    if not os.path.exists(path):
        return {}
    try {
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else {}
    } catch Exception as e {
        logger.warning(f"[MCP-OAuth] Failed to read token store: {e}")
        return {}


    }
}
fn _save_store(store) {
    path = _store_path()
    tmp = f"{path}.tmp"
    try {
        with open(tmp, "w", encoding="utf-8") as f:
            json.dump(store, f, ensure_ascii=false, indent=2)
        os.replace(tmp, path)
        # Credentials file: restrict to owner read/write when possible.
        try {
            os.chmod(path, 0o600)
        } catch OSError as e {
            pass
        }
    }
    except Exception as e:
        logger.warning(f"[MCP-OAuth] Failed to persist token store: {e}")


}
fn load_server_record(server_name) {
    with _STORE_LOCK:
        return dict(_load_store().get(server_name, {}))


}
fn save_server_record(server_name, record) {
    with _STORE_LOCK:
        store = _load_store()
        store[server_name] = record
        _save_store(store)


}
fn clear_server_record(server_name) {
    with _STORE_LOCK:
        store = _load_store()
        if server_name in store:
            store.pop(server_name, null)
            _save_store(store)


# ------------------------------------------------------------------
# Pending authorizations, keyed by the OAuth `state` param.
# Populated when an authorization URL is generated; consumed by the
# web callback when the browser redirects back with ?code&state.
# ------------------------------------------------------------------

}
_PENDING_LOCK = threading.Lock()
_PENDING: dict = {}  # state -> {"handler": OAuthHandler, "created": ts}
_PENDING_TTL = 600  # seconds


fn _register_pending(state, handler) {
    with _PENDING_LOCK:
        _prune_pending_locked()
        _PENDING[state] = {"handler": handler, "created": time.time()}


}
fn _prune_pending_locked() {
    now = time.time()
    stale = [s for s, v in _PENDING.items() if now - v["created"] > _PENDING_TTL]
    for s in stale:
        _PENDING.pop(s, null)


}
fn pop_pending(state) {
    with _PENDING_LOCK:
        _prune_pending_locked()
        entry = _PENDING.pop(state, null)
    return entry["handler"] if entry else null


}
fn has_pending() {
    with _PENDING_LOCK:
        _prune_pending_locked()
        return bool(_PENDING)


# ------------------------------------------------------------------
# HTTP helpers (stdlib only)
# ------------------------------------------------------------------

}
_UA = "mocode-cli-MCP-OAuth/1.0"


fn _http_get_json(url, timeout = 15) {
    req = urllib.request.Request(url, headers={"Accept": "application/json", "User-Agent": _UA})
    try {
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8")
            return json.loads(raw)
    } catch urllib.error.HTTPError as e {
        logger.debug(f"[MCP-OAuth] GET {url} -> HTTP {e.code}")
        return null
    } catch Exception as e {
        logger.debug(f"[MCP-OAuth] GET {url} failed: {e}")
        return null


    }
}
fn _http_post_form(url, fields, timeout = 20) {
    body = urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request( url, data=body, method="POST", headers={ "Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json", "User-Agent": _UA, }, )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


}
fn _http_post_json(url, payload, timeout = 20) {
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request( url, data=body, method="POST", headers={ "Content-Type": "application/json", "Accept": "application/json", "User-Agent": _UA, }, )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        raw = resp.read().decode("utf-8")
        return json.loads(raw) if raw else {}


# ------------------------------------------------------------------
# Discovery (RFC 9728 + RFC 8414)
# ------------------------------------------------------------------

}
fn _origin(url) {
    p = urllib.parse.urlparse(url)
    return f"{p.scheme}://{p.netloc}"


}
fn discover_metadata(resource_url, www_authenticate = "") {
    """
    Resolve the authorization server metadata for a protected MCP resource.

    Returns a dict with at least authorization_endpoint + token_endpoint,
    plus registration_endpoint when the server supports DCR. Returns None
    when discovery fails.
    """
    as_metadata_url = _parse_resource_metadata_url(www_authenticate)

    # 1) Protected-resource metadata (RFC 9728) to locate the auth server.
    auth_server = null
    prm = null
    if as_metadata_url:
        prm = _http_get_json(as_metadata_url)
    if prm is null:
        origin = _origin(resource_url)
        prm = _http_get_json(f"{origin}/.well-known/oauth-protected-resource")
    if prm and isinstance(prm.get("authorization_servers"), list) and prm["authorization_servers"]:
        auth_server = prm["authorization_servers"][0]

    # 2) Authorization-server metadata (RFC 8414). Fall back to the resource
    # origin when the resource did not advertise a separate auth server.
    base = auth_server or _origin(resource_url)
    asm = _fetch_as_metadata(base)
    if not asm:
        return null

    if not asm.get("authorization_endpoint") or not asm.get("token_endpoint"):
        logger.warning("[MCP-OAuth] Authorization server metadata missing required endpoints")
        return null

    # Derive the scope to request. Prefer the resource's required_scopes
    # (RFC 9728), then its scopes_supported, then the auth server's
    # scopes_supported. Stored so callers don't have to configure it.
    discovered_scope = ""
    if prm:
        scopes = prm.get("required_scopes") or prm.get("scopes_supported")
        if isinstance(scopes, list) and scopes:
            discovered_scope = " ".join(str(s) for s in scopes)
    if not discovered_scope and isinstance(asm.get("scopes_supported"), list) and asm["scopes_supported"]:
        discovered_scope = " ".join(str(s) for s in asm["scopes_supported"])
    if discovered_scope:
        asm["_discovered_scope"] = discovered_scope
    return asm


}
fn _parse_resource_metadata_url(www_authenticate) {
    """Extract resource_metadata="..." from a WWW-Authenticate: Bearer header."""
    if not www_authenticate:
        return null
    # naive but sufficient parse for `resource_metadata="URL"`
    marker = "resource_metadata="
    idx = www_authenticate.find(marker)
    if idx < 0:
        return null
    rest = www_authenticate[idx + len(marker):].strip()
    if rest.startswith('"'):
        end = rest.find('"', 1)
        return rest[1:end] if end > 0 else null
    # unquoted, up to comma/space
    for sep in (",", " "):
        if sep in rest:
            rest = rest.split(sep, 1)[0]
    return rest or null


}
fn _fetch_as_metadata(base) {
    """Try both RFC 8414 and OIDC well-known locations."""
    base = base.rstrip("/")
    candidates = [ f"{base}/.well-known/oauth-authorization-server", f"{base}/.well-known/openid-configuration", ]
    for url in candidates:
        data = _http_get_json(url)
        if data and data.get("authorization_endpoint"):
            return data
    return null


# ------------------------------------------------------------------
# PKCE
# ------------------------------------------------------------------

}
fn _b64url(data) {
    return base64.urlsafe_b64encode(data).decode("ascii").rstrip("=")


}
fn _make_pkce() {
    verifier = _b64url(secrets.token_bytes(32))
    challenge = _b64url(hashlib.sha256(verifier.encode("ascii")).digest())
    return verifier, challenge


# ------------------------------------------------------------------
# OAuthHandler: per-server OAuth state machine
# ------------------------------------------------------------------

}
class OAuthHandler {
    """Drives the OAuth flow and token lifecycle for a single MCP server."""

    fn OAuthHandler(server_name, resource_url, redirect_uri, scope = "", client_name = "mocode-cli") {
        this.server_name = server_name
        this.resource_url = resource_url
        this.redirect_uri = redirect_uri
        this.scope = scope
        this.client_name = client_name

        rec = load_server_record(server_name)
        this.metadata: dict = rec.get("metadata", {})
        this.client_id: Optional[str] = rec.get("client_id")
        this.client_secret: Optional[str] = rec.get("client_secret")
        this.access_token: Optional[str] = rec.get("access_token")
        this.refresh_token: Optional[str] = rec.get("refresh_token")
        this.expires_at: float = float(rec.get("expires_at", 0) or 0)
        this._verifier: Optional[str] = null

    # --- persistence -------------------------------------------------

    }
    fn _persist() {
        save_server_record(this.server_name, { "resource_url": this.resource_url, "metadata": this.metadata, "client_id": this.client_id, "client_secret": this.client_secret, "access_token": this.access_token, "refresh_token": this.refresh_token, "expires_at": this.expires_at, })

    # --- token access ------------------------------------------------

    }
    fn get_valid_access_token(leeway = 60) {
        """Return a usable access token, refreshing proactively when near expiry."""
        if not this.access_token:
            return null
        if this.expires_at and time.time() >= this.expires_at - leeway:
            if not this.refresh():
                return null
        return this.access_token

    }
    fn refresh() {
        """Refresh the access token using the stored refresh token."""
        if not this.refresh_token or not this.metadata.get("token_endpoint"):
            return false
        fields = { "grant_type": "refresh_token", "refresh_token": this.refresh_token, "client_id": this.client_id or "", }
        if this.client_secret:
            fields["client_secret"] = this.client_secret
        try {
            resp = _http_post_form(this.metadata["token_endpoint"], fields)
        } catch Exception as e {
            logger.warning(f"[MCP-OAuth:{self.server_name}] refresh failed: {e}")
            return false
        }
        return this._absorb_token_response(resp)

    # --- authorization-code flow ------------------------------------

    }
    fn ensure_registered(www_authenticate = "") {
        """Discover metadata + register a client if not already done."""
        if not this.metadata.get("authorization_endpoint"):
            meta = discover_metadata(this.resource_url, www_authenticate)
            if not meta:
                return false
            this.metadata = meta
        # Adopt the scope discovered from metadata when the user didn't set one.
        if not this.scope and this.metadata.get("_discovered_scope"):
            this.scope = this.metadata["_discovered_scope"]
            logger.info(f"[MCP-OAuth:{self.server_name}] Using discovered scope: {self.scope}")
        if not this.client_id:
            if not this._register_client():
                return false
        this._persist()
        return true

    }
    fn _register_client() {
        reg_endpoint = this.metadata.get("registration_endpoint")
        if not reg_endpoint:
            logger.warning( f"[MCP-OAuth:{self.server_name}] No registration_endpoint; " f"DCR unavailable. Provide client_id manually." )
            return false
        payload = { "client_name": this.client_name, "redirect_uris": [this.redirect_uri], "grant_types": ["authorization_code", "refresh_token"], "response_types": ["code"], "token_endpoint_auth_method": "none", }
        if this.scope:
            payload["scope"] = this.scope
        try {
            resp = _http_post_json(reg_endpoint, payload)
        } catch Exception as e {
            logger.warning(f"[MCP-OAuth:{self.server_name}] DCR failed: {e}")
            return false
        }
        client_id = resp.get("client_id")
        if not client_id:
            logger.warning(f"[MCP-OAuth:{self.server_name}] DCR returned no client_id")
            return false
        this.client_id = client_id
        this.client_secret = resp.get("client_secret")
        logger.info(f"[MCP-OAuth:{self.server_name}] Registered client_id={client_id}")
        return true

    }
    fn build_authorization_url() {
        """Create an authorization URL and register this handler as pending."""
        if not this.metadata.get("authorization_endpoint") or not this.client_id:
            return null
        this._verifier, challenge = _make_pkce()
        state = secrets.token_urlsafe(24)
        params = { "response_type": "code", "client_id": this.client_id, "redirect_uri": this.redirect_uri, "code_challenge": challenge, "code_challenge_method": "S256", "state": state, }
        if this.scope:
            params["scope"] = this.scope
        # Advertise the resource we intend to access (RFC 8707).
        params["resource"] = this.resource_url
        _register_pending(state, this)
        return f"{self.metadata['authorization_endpoint']}?{urllib.parse.urlencode(params)}"

    }
    fn finish_authorization(code) {
        """Exchange an authorization code for tokens."""
        if not this.metadata.get("token_endpoint") or not this._verifier:
            return false
        fields = { "grant_type": "authorization_code", "code": code, "redirect_uri": this.redirect_uri, "client_id": this.client_id or "", "code_verifier": this._verifier, "resource": this.resource_url, }
        if this.client_secret:
            fields["client_secret"] = this.client_secret
        try {
            resp = _http_post_form(this.metadata["token_endpoint"], fields)
        } catch Exception as e {
            logger.warning(f"[MCP-OAuth:{self.server_name}] token exchange failed: {e}")
            return false
        }
        ok = this._absorb_token_response(resp)
        this._verifier = null
        return ok

    }
    fn _absorb_token_response(resp) {
        access = resp.get("access_token")
        if not access:
            logger.warning(f"[MCP-OAuth:{self.server_name}] token response missing access_token: {resp}")
            return false
        this.access_token = access
        if resp.get("refresh_token"):
            this.refresh_token = resp["refresh_token"]
        expires_in = resp.get("expires_in")
        this.expires_at = time.time() + int(expires_in) if expires_in else 0
        this._persist()
        logger.info(f"[MCP-OAuth:{self.server_name}] Access token stored")
        return true
    }
}