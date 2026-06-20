"""Embedding helper — OpenAI-compatible HTTP endpoint, no SDK dependency.

Mirrors the pattern in pgmnemo_mcp/config.py so both packages behave
identically without a shared dependency.
"""

from __future__ import annotations

import json
import os
from typing import Any
from urllib import error as _urlerror
from urllib import request as _request

__all__ = ["embed", "to_pgvector"]


def embed(
    text: str,
    *,
    server: str = "",
    model: str = "",
    dim: int = 1024,
) -> list[float] | None:
    """Return an embedding vector for *text* via an OpenAI-compatible endpoint.

    Parameters
    ----------
    text:
        The text to embed.
    server:
        Base URL of the embedding server (e.g. ``http://localhost:11434``).
        Falls back to ``EMBEDDING_SERVER`` env var, then returns ``None``.
    model:
        Model name to pass to the embedding API.
        Falls back to ``EMBEDDING_MODEL`` env var.
    dim:
        Expected embedding dimension. Returns ``None`` if the server returns
        a different dimension (avoids silent dimension mismatch).

    Returns
    -------
    list[float] | None
        The embedding vector, or ``None`` if the server is not configured,
        unreachable, or returns an unexpected dimension.  Never raises.
    """
    server = server or os.environ.get("EMBEDDING_SERVER", "").strip()
    model = model or os.environ.get("EMBEDDING_MODEL", "").strip()
    if not server or not text:
        return None

    url = server.rstrip("/")
    if "/embed" not in url:
        url += "/v1/embeddings"

    payload: dict[str, Any] = {"input": text}
    if model:
        payload["model"] = model

    try:
        req = _request.Request(
            url,
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with _request.urlopen(req, timeout=30) as resp:
            body = json.loads(resp.read().decode())
        vec = body["data"][0]["embedding"]
        if dim and len(vec) != dim:
            return None
        return [float(x) for x in vec]
    except (_urlerror.URLError, KeyError, IndexError, ValueError, TypeError, OSError):
        return None


def to_pgvector(vec: list[float] | None) -> str | None:
    """Serialise *vec* as a pgvector literal ``[x,y,z]``, or ``None``."""
    if not vec:
        return None
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"
