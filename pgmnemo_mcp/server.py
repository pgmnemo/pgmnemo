"""pgmnemo MCP server — exposes ingest and recall as MCP tools."""

from __future__ import annotations

import json
from typing import Any

from mcp.server.fastmcp import FastMCP

from .config import get_pool

mcp = FastMCP("pgmnemo", port=8765)


@mcp.tool(name="pgmnemo.ingest", description="Ingest a lesson into pgmnemo agent memory.")
def ingest(text: str, metadata: dict[str, Any] | None = None) -> dict[str, Any]:
    """Store a lesson; metadata keys map to agent_lesson columns where recognised."""
    meta = metadata or {}
    role = meta.get("role")
    topic = meta.get("topic")
    importance = meta.get("importance", 3)
    commit_sha = meta.get("commit_sha")

    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                INSERT INTO pgmnemo.agent_lesson
                    (lesson_text, role, topic, importance, commit_sha)
                VALUES (%s, %s, %s, %s, %s)
                RETURNING lesson_id, created_at
                """,
                (text, role, topic, importance, commit_sha),
            )
            row = cur.fetchone()
            conn.commit()
        return {"lesson_id": row[0], "created_at": str(row[1])}
    finally:
        p.putconn(conn)


@mcp.tool(name="pgmnemo.recall", description="Recall lessons from pgmnemo agent memory.")
def recall(query: str, top_k: int = 5) -> list[dict[str, Any]]:
    """Return up to top_k lessons whose text matches query via pgmnemo.recall_lessons."""
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            # recall_lessons(query_vec, top_k, role_filter, topic_filter, text_filter)
            # Pass NULL vector — rely on text_filter for keyword match.
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
