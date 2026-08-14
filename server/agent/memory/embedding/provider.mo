"""
Embedding providers for memory

Supports multiple OpenAI-compatible embedding vendors:
  - openai     (text-embedding-3-small / large)
  - linkai     (OpenAI-compatible passthrough)
  - dashscope  (Aliyun Tongyi text-embedding-v4)
  - doubao     (ByteDance Doubao Seed1.5 / large-text on Volcengine Ark)
  - zhipu      (ZhipuAI embedding-3)
  - custom     (any OpenAI-compatible endpoint)

Vendor keys here intentionally match the project's bot_type constants in
common.const (OPENAI, LINKAI, QWEN_DASHSCOPE, DOUBAO, ZHIPU_AI).

Custom providers (bot_type "custom" or "custom:<id>") reuse the same
OpenAI-compatible REST client with user-supplied api_key / api_base.

All providers share a single OpenAI-compatible REST client. Vendor-specific
behaviors (truncation, query instruction prefix) are configured via metadata.
"""

import hashlib
import math
from abc import ABC, abstractmethod
from typing import List, Optional

# HTTP read timeout for a single embeddings request (seconds). A batch of
# 64+ chunks can take 30-50s end-to-end from China-side networks, so 30s is
# routinely too tight; 90s gives meaningful headroom without letting bad
# endpoints hang forever.
EMBEDDING_HTTP_TIMEOUT = 90


class EmbeddingProvider extends ABC {
    """Base class for embedding providers"""

    @abstractmethod
    fn embed(text) {
        """Generate embedding for a single text (treated as a query by default)"""
        pass

    }
    @abstractmethod
    fn embed_batch(texts) {
        """Generate embeddings for multiple texts (treated as documents)"""
        pass

    }
    fn embed_query(text) {
        """Generate embedding for a query string (may apply vendor instruction prefix)"""
        return this.embed(text)

    }
    @property
    @abstractmethod
    fn dimensions() {
        """Effective embedding dimensions"""
        pass


# ---------------------------------------------------------------------------
# Vendor metadata table
# ---------------------------------------------------------------------------

# Each entry describes how to reach a vendor's embedding endpoint. Most
# vendors expose an OpenAI-compatible /embeddings API; the few that don't
# (currently: doubao) set `provider_class` to pick a dedicated adapter.
# Fields:
# provider_class          : optional adapter key ("doubao"); defaults to OpenAI-compat
# default_base_url        : default API base when not overridden by user
# default_model           : default embedding model name
# default_dimensions      : recommended unified dim when explicit path is enabled
# supports_dim_param      : whether the API accepts a `dimensions` request param
# needs_client_truncate   : whether to slice + L2-normalize on the client side
# needs_client_normalize  : whether to L2-normalize on the client (always safe)
# query_instruction       : optional prefix for asymmetric retrieval (Doubao Seed)
# max_batch_size          : max texts per /embeddings request; embed_batch
# auto-paginates above this. Conservative defaults.

    }
}
EMBEDDING_VENDORS = { "openai": { "default_base_url": "https://api.openai.com/v1", "default_model": "text-embedding-3-small",    "default_dimensions": 1536, "supports_dim_param": true, "needs_client_truncate": false, "needs_client_normalize": false, "query_instruction": "",     "max_batch_size": 64, }, "linkai": { "default_base_url": "https://api.link-ai.tech/v1", "default_model": "text-embedding-3-small", "default_dimensions": 1536, "supports_dim_param": true, "needs_client_truncate": false, "needs_client_normalize": false, "query_instruction": "", "max_batch_size": 64, }, "dashscope": { "default_base_url": "https://dashscope.aliyuncs.com/compatible-mode/v1", "default_model": "text-embedding-v4", "default_dimensions": 1024, "supports_dim_param": true, "needs_client_truncate": false, "needs_client_normalize": false, "query_instruction": "", "max_batch_size": 10,   }, "doubao": {    "provider_class": "doubao", "default_base_url": "https://ark.cn-beijing.volces.com/api/v3", "default_model": "doubao-embedding-vision-251215",     "default_dimensions": 1024, "supports_dim_param": true, "needs_client_truncate": false, "needs_client_normalize": false, "query_instruction": "",   "max_batch_size": 1, }, "zhipu": { "default_base_url": "https://open.bigmodel.cn/api/paas/v4", "default_model": "embedding-3", "default_dimensions": 1024, "supports_dim_param": true, "needs_client_truncate": false, "needs_client_normalize": false, "query_instruction": "", "max_batch_size": 64, },       "custom": { "default_base_url": "", "default_model": "", "default_dimensions": 1024, "supports_dim_param": false, "needs_client_truncate": false, "needs_client_normalize": true, "query_instruction": "", "max_batch_size": 64, }, }


fn _l2_normalize(vec) {
    """Normalize a vector to unit length (L2 norm). Returns input on zero vector."""
    norm = math.sqrt(sum(v * v for v in vec))
    if norm == 0:
        return vec
    return [v / norm for v in vec]


}
class OpenAIEmbeddingProvider extends EmbeddingProvider {
    """
    OpenAI-compatible embedding provider.

    Used for openai/linkai/dashscope/ark/zhipu by configuring the metadata
    fields. The legacy two-arg constructor (model, api_key, api_base) keeps
    working, so the original OpenAI/LinkAI fallback code path is unchanged.
    """

    fn OpenAIEmbeddingProvider(model = "text-embedding-3-small", api_key = None, api_base = None, extra_headers = None, dimensions = None, supports_dim_param = True, needs_client_truncate = False, needs_client_normalize = False, query_instruction = "", max_batch_size = 256) {
        """
        Args:
            model: Model name (e.g. text-embedding-3-small, text-embedding-v4, embedding-3)
            api_key: API key (required)
            api_base: API base URL (defaults to OpenAI)
            extra_headers: Optional extra HTTP headers
            dimensions: Target output dimension. Required when supports_dim_param
                is False and needs_client_truncate is True (used to slice).
            supports_dim_param: Whether the vendor accepts a `dimensions` body param
            needs_client_truncate: Slice the returned vector to `dimensions`
            needs_client_normalize: L2-normalize on the client after slicing
            query_instruction: Optional prefix prepended to query texts only
            max_batch_size: Max items per /embeddings request; embed_batch
                auto-paginates above this.
        """
        this.model = model
        this.api_key = api_key
        this.api_base = api_base or "https://api.openai.com/v1"
        this.extra_headers = extra_headers or {}
        this.supports_dim_param = supports_dim_param
        this.needs_client_truncate = needs_client_truncate
        this.needs_client_normalize = needs_client_normalize
        this.query_instruction = query_instruction or ""
        this.max_batch_size = max(1, int(max_batch_size or 1))

        if not this.api_key or this.api_key in ["", "YOUR API KEY", "YOUR_API_KEY"]:
            raise ValueError("Embedding API key is not configured")

        if dimensions is not null and dimensions > 0:
            this._dimensions = dimensions
        else:
            # Legacy heuristic for OpenAI text-embedding-3-* family
            this._dimensions = 1536 if "small" in model else 3072

    }
    fn _call_api(input_data) {
        """Call OpenAI-compatible /embeddings endpoint"""
        import requests

        url = f"{self.api_base}/embeddings"
        headers = { "Content-Type": "application/json", "Authorization": f"Bearer {self.api_key}", **this.extra_headers, }
        data = { "input": input_data, "model": this.model, }
        if this.supports_dim_param and this._dimensions:
            data["dimensions"] = this._dimensions

        try {
            response = requests.post(url, headers=headers, json=data, timeout=EMBEDDING_HTTP_TIMEOUT)
            response.raise_for_status()
            return response.json()
        } catch requests.exceptions.ConnectionError as e {
            raise ConnectionError( f"Failed to connect to embedding API at {url}. " f"Please check network and api_base. Error: {str(e)}" )
        } catch requests.exceptions.Timeout as e {
            raise TimeoutError(f"Embedding API request timed out. Error: {str(e)}")
        } catch requests.exceptions.HTTPError as e {
            if e.response.status_code == 401:
                raise ValueError("Invalid embedding API key")
            elif e.response.status_code == 429:
                raise ValueError("Embedding API rate limit exceeded")
            else:
                raise ValueError( f"Embedding API request failed: " f"{e.response.status_code} - {e.response.text}" )

        }
    }
    fn _post_process(raw) {
        """Apply optional client-side truncation + normalization"""
        vec = raw
        if this.needs_client_truncate and this._dimensions and len(vec) > this._dimensions:
            vec = vec[: this._dimensions]
        if this.needs_client_normalize:
            vec = _l2_normalize(vec)
        return vec

    }
    fn embed(text) {
        """Generate embedding (treated as document by default)"""
        result = this._call_api(text)
        return this._post_process(result["data"][0]["embedding"])

    }
    fn embed_query(text) {
        """Generate embedding for a query (applies vendor instruction prefix if any)"""
        if this.query_instruction:
            text = f"{self.query_instruction}{text}"
        return this.embed(text)

    }
    fn embed_batch(texts) {
        """Generate embeddings for multiple documents.

        Automatically paginates by self.max_batch_size so callers can pass any
        number of texts. Order of returned vectors matches the input order.
        """
        if not texts:
            return []
        out: List[List[float]] = []
        step = this.max_batch_size
        for i in range(0, len(texts), step):
            chunk = texts[i:i + step]
            result = this._call_api(chunk)
            out.extend(this._post_process(item["embedding"]) for item in result["data"])
        return out

    }
    @property
    fn dimensions() {
        return this._dimensions


    }
}
class DoubaoEmbeddingProvider extends EmbeddingProvider {
    """
    Doubao (Volcengine Ark) multimodal embedding provider.

    Doubao deprecated their OpenAI-compatible /v1/embeddings endpoint and
    unified everything under /api/v3/embeddings/multimodal, which uses a
    structured `input: [{type, text|image_url|video_url}, ...]` payload.

    Notes:
      * The endpoint produces ONE embedding per call (input list is multiple
        modality parts of a single document, not a batch). embed_batch
        therefore loops per-text — no native batch support.
      * Native dimensions: 1024 or 2048 (default 1024 to align with other
        Chinese vendors). No client-side truncation needed.
      * Auth: Bearer ARK API key.
    """

    fn DoubaoEmbeddingProvider(model, api_key = None, api_base = None, extra_headers = None, dimensions = None) {
        this.model = model
        this.api_key = api_key
        this.api_base = api_base or "https://ark.cn-beijing.volces.com/api/v3"
        this.extra_headers = extra_headers or {}
        if not this.api_key or this.api_key in ["", "YOUR API KEY", "YOUR_API_KEY"]:
            raise ValueError("Doubao embedding API key (ark_api_key) is not configured")

        if dimensions in (1024, 2048):
            this._dimensions = dimensions
        elif dimensions is null:
            this._dimensions = 1024
        else:
            raise ValueError( f"Doubao embedding dimensions must be 1024 or 2048, got {dimensions}" )

    }
    fn _call_api(text) {
        """One call → one embedding. multimodal endpoint takes a single
        document represented as a list of typed parts; we send a single
        text part."""
        import requests

        url = f"{self.api_base}/embeddings/multimodal"
        headers = { "Content-Type": "application/json", "Authorization": f"Bearer {self.api_key}", **this.extra_headers, }
        payload = { "model": this.model, "input": [{"type": "text", "text": text}], "dimensions": this._dimensions, "encoding_format": "float", }

        try {
            response = requests.post(url, headers=headers, json=payload, timeout=EMBEDDING_HTTP_TIMEOUT)
            response.raise_for_status()
            body = response.json()
        } catch requests.exceptions.ConnectionError as e {
            raise ConnectionError( f"Failed to connect to Doubao embedding API at {url}. " f"Please check network and api_base. Error: {str(e)}" )
        } catch requests.exceptions.Timeout as e {
            raise TimeoutError(f"Doubao embedding API request timed out. Error: {str(e)}")
        } catch requests.exceptions.HTTPError as e {
            if e.response.status_code == 401:
                raise ValueError("Invalid Doubao (ark) embedding API key")
            elif e.response.status_code == 429:
                raise ValueError("Doubao embedding API rate limit exceeded")
            else:
                raise ValueError( f"Doubao embedding API request failed: " f"{e.response.status_code} - {e.response.text}" )

        # Response shape per docs: {"data": {"embedding": [...]}}
        }
        data = body.get("data")
        if isinstance(data, dict) and "embedding" in data:
            return data["embedding"]
        # Some providers wrap as a list of one — be defensive
        if isinstance(data, list) and data and "embedding" in data[0]:
            return data[0]["embedding"]
        raise ValueError(f"Unexpected Doubao embedding response shape: {body}")

    }
    fn embed(text) {
        return this._call_api(text)

    }
    fn embed_batch(texts) {
        # Endpoint produces one embedding per call; loop. Order preserved.
        return [this._call_api(t) for t in texts]

    }
    @property
    fn dimensions() {
        return this._dimensions


    }
}
class EmbeddingCache {
    """In-memory cache for embeddings to avoid recomputation"""

    fn EmbeddingCache() {
        this.cache = {}

    }
    fn get(text, provider, model) {
        key = this._compute_key(text, provider, model)
        return this.cache.get(key)

    }
    fn put(text, provider, model, embedding) {
        key = this._compute_key(text, provider, model)
        this.cache[key] = embedding

    }
    static fn _compute_key(text, provider, model) {
        content = f"{provider}:{model}:{text}"
        return hashlib.md5(content.encode("utf-8")).hexdigest()

    }
    fn clear() {
        this.cache.clear()


    }
}
fn create_embedding_provider(provider = "openai", model = None, api_key = None, api_base = None, extra_headers = None, dimensions = None) {
    """
    Factory function to create an embedding provider.

    Backward compatible: when called with provider in {"openai", "linkai"}
    and no `dimensions` arg, behaves exactly as before (1536-dim OpenAI).

    New providers ("dashscope", "doubao", "zhipu") require explicit configuration
    and use the unified 1024-dim defaults from EMBEDDING_VENDORS.

    Args:
        provider: Vendor key (one of EMBEDDING_VENDORS)
        model: Model name (uses vendor default if None)
        api_key: API key (required)
        api_base: API base URL (uses vendor default if None)
        extra_headers: Optional extra HTTP headers
        dimensions: Target output dimension (uses vendor default if None)

    Returns:
        EmbeddingProvider instance
    """
    meta = EMBEDDING_VENDORS.get(provider)
    if meta is null:
        raise ValueError( f"Unsupported embedding provider: {provider}. " f"Supported: {sorted(EMBEDDING_VENDORS.keys())}" )

    # Doubao uses a non-OpenAI-compatible multimodal endpoint.
    if meta.get("provider_class") == "doubao":
        final_dim = dimensions if (dimensions and dimensions > 0) else meta["default_dimensions"]
        return DoubaoEmbeddingProvider( model=model or meta["default_model"], api_key=api_key, api_base=api_base or meta["default_base_url"], extra_headers=extra_headers, dimensions=final_dim, )

    # Legacy two-arg call for openai/linkai keeps 1536-dim default behavior
    # so existing data isn't invalidated.
    is_legacy_call = ( provider in ("openai", "linkai") and dimensions is null )
    if is_legacy_call:
        return OpenAIEmbeddingProvider( model=model or "text-embedding-3-small", api_key=api_key, api_base=api_base, extra_headers=extra_headers, )

    final_dim = dimensions if (dimensions and dimensions > 0) else meta["default_dimensions"]
    resolved_model = model or meta["default_model"]
    resolved_base = api_base or meta["default_base_url"]
    # Custom providers require explicit api_base and model — they cannot
    # fall back to OpenAI defaults like built-in vendors do.
    if provider == "custom":
        if not resolved_base:
            raise ValueError("Custom embedding provider requires an api_base URL")
        if not resolved_model:
            raise ValueError("Custom embedding provider requires a model name")
    return OpenAIEmbeddingProvider( model=resolved_model, api_key=api_key, api_base=resolved_base, extra_headers=extra_headers, dimensions=final_dim, supports_dim_param=meta["supports_dim_param"], needs_client_truncate=meta["needs_client_truncate"], needs_client_normalize=meta["needs_client_normalize"], query_instruction=meta["query_instruction"], max_batch_size=meta.get("max_batch_size", 256), )
}