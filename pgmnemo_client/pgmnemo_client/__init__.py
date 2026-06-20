"""pgmnemo-client — Python SDK for pgmnemo agent memory.

Quick start::

    import pgmnemo_client as pgmnemo

    mem = pgmnemo.connect("postgresql://user:pass@localhost/mydb")
    mem.ingest("Use select_related() to avoid N+1 queries in Django.")
    results = mem.recall("database query optimization", top_k=5)
    mem.reinforce([results[0]["lesson_id"]], "success")

    # Document ingestion ($0 — chunks + embeds only):
    mem.ingest_document("docs/architecture.md")

    # With LLM extraction (caller pays, explicit opt-in):
    mem.ingest_document(
        "docs/architecture.md",
        extraction_model="claude-haiku-3-5",
    )
"""

from __future__ import annotations

__version__ = "0.10.0"

from .client import PgmnemoClient, connect

__all__ = ["PgmnemoClient", "connect", "__version__"]
