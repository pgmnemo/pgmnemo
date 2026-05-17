"""pgmnemo MCP server — exposes ingest and recall as MCP tools.

Transport note (BUG-3 resolution):
    FastMCP uses MCP protocol transport (stdio by default, SSE/streamable-http
    optionally). It does NOT expose REST endpoints at /ingest or /recall.
    Clients must use the MCP JSON-RPC protocol (stdio pipe or SSE at /sse).
    The --smoke command in __main__.py exercises the DB layer directly
    without going through the MCP transport.
"""

from __future__ import annotations

from typing import Any

from mcp.server.fastmcp import FastMCP

from .config import get_pool

mcp = FastMCP("pgmnemo", port=8765)


@mcp.tool(name="pgmnemo.ingest", description="Ingest a lesson into pgmnemo agent memory.")
def ingest(
    text: str,
    role: str = "mcp_agent",
    topic: str = "general",
    importance: int = 3,
    commit_sha: str | None = None,
    artifact_hash: str | None = None,
    metadata: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """Store a lesson in pgmnemo.agent_lesson and return its id.

    BUG-1 fix: INSERT now uses RETURNING id (column is 'id', not 'lesson_id').
    BUG-2 fix: role/topic are explicit required-with-defaults params (NOT NULL cols);
               artifact_hash added so provenance gate can be satisfied.
    """
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO pgmnemo.agent_lesson
                    (lesson_text, role, topic, importance,
                     commit_sha, artifact_hash, verified_at)
                VALUES (%s, %s, %s, %s, %s, %s, NOW())
                RETURNING id, created_at
                """,
                (text, role, topic, importance, commit_sha, artifact_hash),  # verified_at=NOW() above
            )
            row = cur.fetchone()
            conn.commit()
        return {"id": row[0], "created_at": str(row[1])}
    finally:
        p.putconn(conn)


@mcp.tool(name="pgmnemo.recall", description="Recall lessons from pgmnemo agent memory.")
def recall(query: str, top_k: int = 5) -> list[dict[str, Any]]:
    """Return up to top_k lessons whose text matches query via pgmnemo.recall_lessons.

    recall_lessons() RETURNS TABLE (lesson_id bigint, score, role, ...) — the output
    column is 'lesson_id' (an alias), not 'id' (the physical table column).
    """
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            # recall_lessons(query_vec, top_k, role_filter, project_id_filter, query_text)
            # Pass NULL vector — rely on query_text for BM25/hybrid keyword match.
            cur.execute(
                """
                SELECT lesson_id, role, topic, lesson_text, importance, created_at
                FROM pgmnemo.recall_lessons(
                    NULL::vector(1024), %s, NULL, NULL, %s
                )
                """,
                (top_k, query),
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
