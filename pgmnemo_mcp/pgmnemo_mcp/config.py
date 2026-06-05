import json as _json
import os
from typing import Any
from urllib import error as _urlerror, request as _request

from psycopg2 import pool

__all__ = [
    "DATABASE_URL",
    "MCP_PORT",
    "EMBEDDING_SERVER",
    "EMBEDDING_MODEL",
    "EMBEDDING_DIM",
    "get_pool",
    "embed",
    "to_pgvector",
]

DATABASE_URL: str = os.environ.get("DATABASE_URL", "postgresql://localhost/pgmnemo")
MCP_PORT: int = int(os.environ.get("MCP_PORT", "8765"))

# v0.8.2: let the MCP server embed text itself via an OpenAI-compatible
# embeddings endpoint, so adopters don't have to supply vectors out of band.
# When EMBEDDING_SERVER is unset, ingest/recall fall back to text-only (NULL vector).
EMBEDDING_SERVER: str = os.environ.get("EMBEDDING_SERVER", "").strip()
EMBEDDING_MODEL: str = os.environ.get("EMBEDDING_MODEL", "").strip()
EMBEDDING_DIM: int = int(os.environ.get("EMBEDDING_DIM", "1024"))


def embed(text: str) -> list[float] | None:
    """Embed ``text`` via the configured OpenAI-compatible EMBEDDING_SERVER.

    Returns the embedding vector, or ``None`` if EMBEDDING_SERVER is unset, the
    call fails, or the returned dimension does not match EMBEDDING_DIM — in which
    case the caller falls back to text-only (BM25) recall/ingest. Never raises.
    """
    if not EMBEDDING_SERVER or not text:
        return None
    url = EMBEDDING_SERVER
    if "/embed" not in url:  # tolerate a base URL
        url = url.rstrip("/") + "/v1/embeddings"
    payload: dict[str, Any] = {"input": text}
    if EMBEDDING_MODEL:
        payload["model"] = EMBEDDING_MODEL
    try:
        req = _request.Request(
            url,
            data=_json.dumps(payload).encode("utf-8"),
            headers={"Content-Type": "application/json"},
            method="POST",
        )
        with _request.urlopen(req, timeout=30) as resp:
            body = _json.loads(resp.read().decode("utf-8"))
        vec = body["data"][0]["embedding"]  # OpenAI-compatible response
        if EMBEDDING_DIM and len(vec) != EMBEDDING_DIM:
            return None
        return [float(x) for x in vec]
    except (_urlerror.URLError, KeyError, IndexError, ValueError, TypeError, OSError):
        return None


def to_pgvector(vec: list[float] | None) -> str | None:
    """Format an embedding as a pgvector literal (``[x,y,z]``), or ``None``."""
    if not vec:
        return None
    return "[" + ",".join(repr(float(x)) for x in vec) + "]"

_pool: pool.SimpleConnectionPool | None = None


def get_pool() -> pool.SimpleConnectionPool:
    global _pool
    if _pool is None:
        _pool = pool.SimpleConnectionPool(1, 5, dsn=DATABASE_URL)
    return _pool
