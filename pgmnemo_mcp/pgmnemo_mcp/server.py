"""pgmnemo MCP server — exposes ingest and recall as MCP tools.

Transport note (BUG-3 resolution):
    FastMCP uses MCP protocol transport (stdio by default, SSE/streamable-http
    optionally). It does NOT expose REST endpoints at /ingest or /recall.
    Clients must use the MCP JSON-RPC protocol (stdio pipe or SSE at /sse).
    The --smoke command in __main__.py exercises the DB layer directly
    without going through the MCP transport.
"""

from __future__ import annotations

import json
from typing import Any

from mcp.server.fastmcp import FastMCP

from .config import embed, get_pool, to_pgvector

mcp = FastMCP("pgmnemo", port=8765)


@mcp.tool(name="pgmnemo.ingest", description="Ingest a lesson into pgmnemo agent memory.")
def ingest(
    text: str,
    role: str = "mcp_agent",
    topic: str = "general",
    importance: int = 3,
    project_id: int = 1,
    commit_sha: str | None = None,
    artifact_hash: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Store a lesson via pgmnemo.ingest() SP and return its id.

    Uses the pgmnemo.ingest() stored procedure instead of raw INSERT so that:
    - Gate enforcement (provenance checks) runs inside the SP.
    - verified_at is stamped automatically when commit_sha/artifact_hash are present.
    - Embedding dimension validation fires before the INSERT.
    """
    # v0.8.2: embed the lesson text via EMBEDDING_SERVER if configured;
    # falls back to NULL (text-only) when unset/unavailable.
    embedding = to_pgvector(embed(text))
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                SELECT pgmnemo.ingest(
                    %s, %s, %s, %s, %s::smallint,
                    %s::vector(1024), %s, %s, %s::jsonb
                )
                """,
                (
                    role,
                    project_id,
                    topic,
                    text,
                    importance,
                    embedding,
                    commit_sha,
                    artifact_hash,
                    json.dumps(metadata) if metadata is not None else "{}",
                ),
            )
            new_id = cur.fetchone()[0]
            conn.commit()
        return {"id": new_id}
    finally:
        p.putconn(conn)


@mcp.tool(name="pgmnemo.recall", description="Recall lessons from pgmnemo agent memory.")
def recall(query: str, top_k: int = 5) -> list[dict[str, Any]]:
    """Return up to top_k lessons whose text matches query via pgmnemo.recall_lessons.

    recall_lessons() RETURNS TABLE (lesson_id bigint, score, role, ...) — the output
    column is 'lesson_id' (an alias), not 'id' (the physical table column).
    """
    # v0.8.2: embed the query via EMBEDDING_SERVER if configured → real
    # vector+BM25 hybrid recall; falls back to NULL (BM25 keyword only) when unset.
    query_vec = to_pgvector(embed(query))
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            # recall_lessons(query_vec, top_k, role_filter, project_id_filter, query_text)
            cur.execute(
                """
                SELECT lesson_id, role, topic, lesson_text, importance, created_at
                FROM pgmnemo.recall_lessons(
                    %s::vector(1024), %s, NULL, NULL, %s
                )
                """,
                (query_vec, top_k, query),
            )
            cols = [d[0] for d in cur.description]
            return [dict(zip(cols, row)) for row in cur.fetchall()]
    finally:
        p.putconn(conn)


def run() -> None:
    """Entry point for `python -m pgmnemo_mcp.server`."""
    mcp.run()


def main() -> None:
    """Console script entry point (pgmnemo-mcp = pgmnemo_mcp.server:main)."""
    run()


if __name__ == "__main__":
    main()
