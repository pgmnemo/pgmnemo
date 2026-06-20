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

import re

from .config import (
    DATABASE_URL,
    EMBEDDING_DIM,
    EMBEDDING_MODEL,
    EMBEDDING_SERVER,
    MCP_PORT,
    embed,
    get_pool,
    to_pgvector,
)

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
    item_kind: str = "note",
    source_dag_id: str | None = None,
) -> dict[str, Any]:
    """Store a lesson via pgmnemo.ingest() SP and return its id.

    Uses the pgmnemo.ingest() stored procedure instead of raw INSERT so that:
    - Gate enforcement (provenance checks) runs inside the SP.
    - verified_at is stamped automatically when commit_sha/artifact_hash are present.
    - Embedding dimension validation fires before the INSERT.

    item_kind: content-type classification — note|skill_md|template|script|reference|config|spec
    source_dag_id: opaque workflow/DAG run id that produced this lesson (v0.9.6)
    """
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
            if item_kind != "note" or source_dag_id is not None:
                cur.execute(
                    """
                    UPDATE pgmnemo.agent_lesson
                    SET item_kind = %s,
                        source_dag_id = COALESCE(source_dag_id, %s)
                    WHERE id = %s
                    """,
                    (item_kind, source_dag_id, new_id),
                )
            conn.commit()
        return {"id": new_id}
    finally:
        p.putconn(conn)


@mcp.tool(name="pgmnemo.recall", description="Recall lessons from pgmnemo agent memory.")
def recall(
    query: str,
    top_k: int = 5,
    role_filter: str | None = None,
    project_id_filter: int | None = None,
    exclude_dag_id: str | None = None,
    deep: bool = False,
) -> list[dict[str, Any]]:
    """Return up to top_k lessons whose text matches query.

    Default (deep=False): calls recall_fast() — pure HNSW vector search, O(k log n).
    deep=True: calls recall_hybrid() — full 6-signal RRF fusion (vector + BM25 +
      graph proximity + recency + confidence + provenance). Slower but higher recall.

    recall_fast() RETURNS TABLE (lesson_id bigint, score, role, ...) — 12-column shape.
    recall_hybrid() returns the same 12-column subset; extra diagnostic columns dropped.

    role_filter: restrict to lessons from this role (v0.9.6+)
    project_id_filter: restrict to lessons from this project (v0.9.6+)
    exclude_dag_id: suppress lessons whose source_dag_id matches — prevents a workflow
      from recalling its own in-flight outputs (v0.9.6+)
    deep: when True, use recall_hybrid() for BM25 + graph fusion (v0.9.8+)
    """
    query_vec = to_pgvector(embed(query))
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            if deep:
                # recall_hybrid v0.9.6: (query_embedding, query_text, k,
                #   role_filter, project_id_filter, vec_weight, bm25_weight,
                #   rrf_k, exclude_dag_id)
                cur.execute(
                    """
                    SELECT lesson_id, role, topic, lesson_text, importance, created_at
                    FROM pgmnemo.recall_hybrid(
                        %s::vector(1024), %s, %s, %s, %s, 0.4, 0.4, 60, %s
                    )
                    """,
                    (query_vec, query, top_k, role_filter, project_id_filter, exclude_dag_id),
                )
            else:
                # recall_fast v0.9.8: (query_embedding, k,
                #   role_filter, project_id_filter, exclude_dag_id)
                cur.execute(
                    """
                    SELECT lesson_id, role, topic, lesson_text, importance, created_at
                    FROM pgmnemo.recall_fast(
                        %s::vector(1024), %s, %s, %s, %s
                    )
                    """,
                    (query_vec, top_k, role_filter, project_id_filter, exclude_dag_id),
                )
            cols = [d[0] for d in cur.description]
            return [dict(zip(cols, row)) for row in cur.fetchall()]
    finally:
        p.putconn(conn)


@mcp.tool(
    name="pgmnemo.patch",
    description="Update lesson text for an existing lesson (increments version_n and patch_count).",
)
def patch(lesson_id: int, lesson_text: str) -> dict[str, Any]:
    """Revise an existing lesson in place.

    Increments version_n and patch_count. Use when a prior lesson is factually
    outdated rather than creating a duplicate via ingest().
    """
    p = get_pool()
    conn = p.getconn()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                UPDATE pgmnemo.agent_lesson
                SET lesson_text = %s,
                    version_n   = version_n + 1,
                    patch_count = patch_count + 1
                WHERE id = %s
                RETURNING id, version_n, patch_count
                """,
                (lesson_text, lesson_id),
            )
            row = cur.fetchone()
            if row is None:
                raise ValueError(f"lesson_id {lesson_id} not found")
            conn.commit()
        return {"id": row[0], "version_n": row[1], "patch_count": row[2]}
    finally:
        p.putconn(conn)


@mcp.tool(
    name="pgmnemo.get_params",
    description=(
        "Return the current pgmnemo MCP server configuration. "
        "DATABASE_URL password is masked. Use this to verify the server is "
        "connected to the expected PostgreSQL instance and embedding service."
    ),
)
def get_params() -> dict[str, Any]:
    """Return server configuration parameters (DATABASE_URL password is masked).

    v0.9.7: MCP params exposure — lets clients inspect the connection without
    accessing environment variables directly. Password component of DATABASE_URL
    is replaced with '***' before returning.
    """
    masked_url = re.sub(r"://([^:]+):([^@]+)@", r"://\1:***@", DATABASE_URL)
    return {
        "database_url": masked_url,
        "embedding_server": EMBEDDING_SERVER or None,
        "embedding_model": EMBEDDING_MODEL or None,
        "embedding_dim": EMBEDDING_DIM,
        "mcp_port": MCP_PORT,
        "version": "0.9.8",
    }


def run() -> None:
    """Entry point for `python -m pgmnemo_mcp.server`."""
    mcp.run()


def main() -> None:
    """Console script entry point (pgmnemo-mcp = pgmnemo_mcp.server:main)."""
    run()


if __name__ == "__main__":
    main()
