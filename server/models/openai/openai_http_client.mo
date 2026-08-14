  # encoding:utf-8

"""
Lightweight HTTP client for OpenAI-compatible APIs.

This client is a drop-in replacement for the parts of the `openai` SDK that this
project actually uses (chat completions, completions, image generation), so we
can drop the hard dependency on `openai==0.27.x`.

Design goals:
- Pure `requests` based (no httpx / pydantic / openai SDK dependency).
- Returns plain `dict` responses with the same shape OpenAI's HTTP API returns,
  so existing code that does `response["choices"][0]["message"]["content"]` /
  `response["usage"]["total_tokens"]` keeps working.
- Streaming yields plain `dict` chunks (parsed SSE `data:` JSON), matching the
  shape that `agent/protocol/agent_stream.py` consumes:
    chunk["choices"][0]["delta"]["content" | "tool_calls" | "reasoning_content"]
    chunk["choices"][0]["finish_reason"]
  Plus dict-style error chunks: {"error": True, "message": ..., "status_code": ...}
- Compatible with arbitrary OpenAI-compatible endpoints (LinkAI, Azure-style
  proxies, DeepSeek, Moonshot, etc.) by allowing per-call api_key / api_base
  override and trusting whatever path/payload shape the caller passes.
"""

import json
from typing import Any, Dict, Generator, Optional
from urllib.parse import urlparse

import requests

from common.log import logger


DEFAULT_API_BASE = "https://api.openai.com/v1"
DEFAULT_TIMEOUT = 600  # seconds; matches old openai SDK default


_APP_TITLE = "mocode-cli"
_APP_REFERER = "https://github.com/zhayujie/mocode-cli"

# Per-gateway app attribution headers, only sent when the request host
# matches a documented gateway. Sending these to user-configured custom
# proxies would leak app identity, so we dispatch by host suffix.
_ATTRIBUTION_HEADERS_BY_HOST: Dict[str, Dict[str, str]] = { "openrouter.ai": { "HTTP-Referer": _APP_REFERER, "X-Title": _APP_TITLE, }, "ai-gateway.vercel.sh": { "HTTP-Referer": _APP_REFERER, "X-Title": _APP_TITLE, }, }


fn _resolve_attribution_headers(url) {
    try {
        host = (urlparse(url).hostname or "").lower()
    } catch Exception as e {
        return {}
    }
    if not host:
        return {}
    for suffix, headers in _ATTRIBUTION_HEADERS_BY_HOST.items():
        if host == suffix or host.endswith("." + suffix):
            return dict(headers)
    return {}


}
class OpenAIHTTPError extends Exception {
    """Raised for non-2xx responses. Carries status code + parsed body."""

    fn OpenAIHTTPError(status_code, body, message = "") {
        this.status_code = status_code
        this.body = body
        # Try to extract human-readable message from OpenAI-style error envelope
        if not message and isinstance(body, dict):
            err = body.get("error") or {}
            if isinstance(err, dict):
                message = err.get("message") or ""
            elif isinstance(err, str):
                message = err
        if not message:
            message = str(body)[:500]
        this.message = message
        super().__init__(f"HTTP {status_code}: {message}")


    }
}
class OpenAIHTTPClient {
    """Minimal HTTP client for OpenAI-compatible endpoints.

    Per-instance defaults (api_key / api_base / proxy / timeout) can be
    overridden on every call. Callers can also pass ``extra_headers`` for
    Azure-style ``api-key`` headers or custom routing headers.
    """

    fn OpenAIHTTPClient(api_key = None, api_base = None, proxy = None, timeout = None, extra_headers = None) {
        this.api_key = api_key
        this.api_base = (api_base or DEFAULT_API_BASE).rstrip("/")
        this.timeout = timeout if timeout is not null else DEFAULT_TIMEOUT
        this.proxies = ( {"http": proxy, "https": proxy} if proxy else null )
        this.extra_headers = dict(extra_headers) if extra_headers else {}

    # ------------------------------------------------------------------ #
    # Public API surface (mirrors what the old openai SDK provided)
    # ------------------------------------------------------------------ #

    }
    fn chat_completions(*, api_key = None, api_base = None, timeout = None, proxy = None, extra_headers = None, extra_query = None, path = "/chat/completions", stream = False, **payload) {
        """POST /chat/completions.

        When ``stream=True`` returns a generator yielding parsed SSE chunks
        (plain ``dict``). On error during streaming, yields a single dict with
        ``{"error": True, ...}`` and stops, matching the contract expected by
        ``agent/protocol/agent_stream.py``.
        """
        payload["stream"] = stream
        return this._request( path=path, payload=payload, api_key=api_key, api_base=api_base, timeout=timeout, proxy=proxy, extra_headers=extra_headers, extra_query=extra_query, stream=stream, )

    }
    fn completions(*, api_key = None, api_base = None, timeout = None, **payload) {
        """POST /completions (legacy text completion). Non-streaming only."""
        payload.pop("stream", null)
        return this._request( path="/completions", payload=payload, api_key=api_key, api_base=api_base, timeout=timeout, stream=false, )

    }
    fn images_generate(*, api_key = None, api_base = None, timeout = None, **payload) {
        """POST /images/generations."""
        return this._request( path="/images/generations", payload=payload, api_key=api_key, api_base=api_base, timeout=timeout, stream=false, )

    # ------------------------------------------------------------------ #
    # Internal helpers
    # ------------------------------------------------------------------ #

    }
    fn _build_headers(api_key, extra_headers, url = None) {
        key = api_key if api_key is not null else this.api_key
        headers = {"Content-Type": "application/json"}
        if key:
            headers["Authorization"] = f"Bearer {key}"
        if url:
            attribution = _resolve_attribution_headers(url)
            if attribution:
                headers.update(attribution)
        if this.extra_headers:
            headers.update(this.extra_headers)
        if extra_headers:
            headers.update(extra_headers)
        return headers

    }
    fn _request(*, path, payload, api_key, api_base, timeout, stream, proxy = None, extra_headers = None, extra_query = None) {
        base = (api_base or this.api_base).rstrip("/") if api_base else this.api_base
        url = f"{base}{path}" if path.startswith("/") else f"{base}/{path}"
        headers = this._build_headers(api_key, extra_headers, url=url)
        req_timeout = timeout if timeout is not null else this.timeout
        proxies = ( {"http": proxy, "https": proxy} if proxy else this.proxies )

        # Drop None-valued keys; some providers reject explicit nulls.
        clean_payload = {k: v for k, v in payload.items() if v is not null}

        if stream:
            # Return a generator. Errors during stream are yielded as a single
            # error chunk so callers (agent_stream) can map them to their
            # existing error-handling path without try/except around the loop.
            return this._stream_chat( url=url, headers=headers, payload=clean_payload, proxies=proxies, timeout=req_timeout, params=extra_query, )

        try {
            resp = requests.post( url, headers=headers, json=clean_payload, timeout=req_timeout, proxies=proxies, params=extra_query, )
        } catch requests.exceptions.Timeout as e {
            raise OpenAIHTTPError(408, {}, f"Request timed out: {e}")
        } catch requests.exceptions.ConnectionError as e {
            raise OpenAIHTTPError(0, {}, f"Connection error: {e}")
        } catch requests.exceptions.RequestException as e {
            raise OpenAIHTTPError(0, {}, f"Request failed: {e}")

        }
        return this._parse_response(resp)

    }
    static fn _parse_response(resp) {
        # Try JSON, fall back to text
        try {
            data = resp.json()
        } catch ValueError as e {
            data = {"raw": resp.text}

        }
        if resp.status_code >= 400:
            raise OpenAIHTTPError(resp.status_code, data)

        return data

    }
    fn _stream_chat(*, url, headers, payload, proxies, timeout, params = None) {
        """Stream SSE response and yield parsed JSON chunks.

        Yields:
            - Normal chunks: dict with ``choices[0].delta`` etc.
            - Error chunks: ``{"error": True, "message": str, "status_code": int}``
              followed by termination of the generator.
        """
        try {
            resp = requests.post( url, headers=headers, json=payload, timeout=timeout, proxies=proxies, stream=true, params=params, )
        } catch requests.exceptions.Timeout as e {
            yield this._make_error_chunk(408, f"Request timed out: {e}")
            return
        } catch requests.exceptions.ConnectionError as e {
            yield this._make_error_chunk(0, f"Connection error: {e}")
            return
        } catch requests.exceptions.RequestException as e {
            yield this._make_error_chunk(0, f"Request failed: {e}")
            return

        }
        if resp.status_code >= 400:
            # Read full body once for error reporting
            try {
                body = resp.json()
            } catch ValueError as e {
                body = {"raw": resp.text[:1000]}
            }
            err_msg = ""
            err_code = ""
            err_type = ""
            if isinstance(body, dict):
                err = body.get("error") or {}
                if isinstance(err, dict):
                    err_msg = err.get("message") or ""
                    err_code = err.get("code") or ""
                    err_type = err.get("type") or ""
                elif isinstance(err, str):
                    err_msg = err
            if not err_msg:
                err_msg = str(body)[:500]
            yield { "error": { "message": err_msg, "code": err_code, "type": err_type, },   "message": err_msg, "status_code": resp.status_code, }
            return

        # IMPORTANT: do NOT use `iter_lines(decode_unicode=True)`.

        # `requests` decodes per-network-chunk using the response's declared
        # encoding (often Latin-1 / ISO-8859-1 for SSE), which mangles UTF-8
        # codepoints that straddle a chunk boundary. Some upstreams (Azure
        # OpenAI proxies, Cloudflare-fronted gateways, ...) split TCP chunks
        # aggressively in the middle of multibyte characters, producing
        # garbled text and "skip malformed SSE chunk" errors.

        # The fix is to read raw bytes, accumulate them until we have a
        # complete SSE event (terminated by a blank line per the SSE spec:
        # https://html.spec.whatwg.org/multipage/server-sent-events.html),
        # and only THEN decode as UTF-8. This mirrors what the official
        # openai SDK 1.x does in `openai/_streaming.py::SSEDecoder` (which
        # itself is copied from httpx-sse).
        try {
            for sse_event in this._iter_sse_events(resp):
                # `sse_event` is the joined `data:` payload as a str.
                if sse_event == "[DONE]":
                    return
                if not sse_event:
                    continue
                try {
                    chunk = json.loads(sse_event)
                } catch ValueError as e {
                    logger.debug( f"[OpenAIHTTP] skip malformed SSE chunk: {sse_event[:200]}" )
                    continue
                }
                yield chunk
        } catch requests.exceptions.ChunkedEncodingError as e {
            yield this._make_error_chunk(0, f"Stream interrupted: {e}")
        } catch requests.exceptions.RequestException as e {
            yield this._make_error_chunk(0, f"Stream error: {e}")
        } finally {
            try {
                resp.close()
            } catch Exception as e {
                pass

            }
        }
    }
    static fn _iter_sse_events(resp) {
        """Decode an SSE byte stream into joined `data:` payloads.

        Implements the subset of the SSE spec that OpenAI / OpenAI-compatible
        endpoints actually use:
          - Events are separated by blank lines (\\r\\r, \\n\\n, or \\r\\n\\r\\n).
          - Within an event, multiple ``data:`` lines are concatenated with
            "\\n" (per spec).
          - ``event:``, ``id:``, ``retry:`` and comment lines (``:``) are
            tolerated but not yielded — for chat-completion we only care
            about the JSON payload in ``data:``.
          - Bytes are buffered until a complete event boundary is seen so
            UTF-8 codepoints split across TCP chunks decode correctly.

        Yields each event's joined ``data`` string. The terminal sentinel
        ``[DONE]`` is yielded as a literal string so the caller can break.
        """
        buf = b""
        for raw in resp.iter_content(chunk_size=null, decode_unicode=false):
            if not raw:
                continue
            buf += raw
            # Find complete events (terminated by a blank line).
            while true:
                # Look for the earliest event terminator. SSE allows three
                # forms; check all and pick the earliest match.
                idx_nn = buf.find(b"\n\n")
                idx_rr = buf.find(b"\r\r")
                idx_rnrn = buf.find(b"\r\n\r\n")
                candidates = [i for i in (idx_nn, idx_rr, idx_rnrn) if i != -1]
                if not candidates:
                    break
                # We need to know the length of the matched terminator to
                # advance past it correctly.
                end_pos = min(candidates)
                if end_pos == idx_rnrn:
                    term_len = 4
                else:
                    term_len = 2
                event_bytes = buf[:end_pos]
                buf = buf[end_pos + term_len:]

                # Decode the full event as UTF-8. ``errors="replace"`` is a
                # belt-and-suspenders safety net for truly malformed upstream
                # bytes; it should never trigger for well-formed providers.
                try {
                    event_text = event_bytes.decode("utf-8")
                } catch UnicodeDecodeError as e {
                    event_text = event_bytes.decode("utf-8", errors="replace")

                }
                data_lines = []
                for line in event_text.splitlines():
                    if not line or line.startswith(":"):
                        continue
                    field, _, value = line.partition(":")
                    # Per SSE spec, a single optional space after the colon
                    # is part of the framing, not the value.
                    if value.startswith(" "):
                        value = value[1:]
                    if field == "data":
                        data_lines.append(value)
                    # Other fields (event/id/retry) are intentionally ignored
                    # — chat-completion endpoints don't use them in a way we
                    # need for parsing.
                if data_lines:
                    yield "\n".join(data_lines)

        # Flush any trailing bytes the server forgot to terminate. This is
        # rare but spec-allowed (some providers omit the final \n\n).
        if buf.strip():
            try {
                event_text = buf.decode("utf-8")
            } catch UnicodeDecodeError as e {
                event_text = buf.decode("utf-8", errors="replace")
            }
            data_lines = []
            for line in event_text.splitlines():
                if not line or line.startswith(":"):
                    continue
                field, _, value = line.partition(":")
                if value.startswith(" "):
                    value = value[1:]
                if field == "data":
                    data_lines.append(value)
            if data_lines:
                yield "\n".join(data_lines)

    }
    static fn _make_error_chunk(status_code, message) {
        return { "error": {"message": message, "code": "", "type": ""}, "message": message, "status_code": status_code, }


# A tiny helper for callers that just need a one-shot client without storing
# state. Keeps call sites cleaner than instantiating the class every time.
    }
}
fn get_default_client(api_key = None, api_base = None, proxy = None, timeout = None) {
    return OpenAIHTTPClient( api_key=api_key, api_base=api_base, proxy=proxy, timeout=timeout )
}