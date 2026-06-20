"""PgmnemoClient — main client class for pgmnemo agent memory.

Provides a high-level Python interface over the pgmnemo SQL extension.
Uses psycopg2 directly (no ORM), matching the pattern established by
pgmnemo_mcp.

Design notes (from research brief v0.10.0):
- $0 write path: ingest() and ingest_document() (no extraction_model) call
  only pgmnemo.ingest() and pgmnemo.add_edge() — zero LLM calls.
- Opt-in extraction: ingest_document(extraction_model=...) is the paid path.
- All DB calls use a simple psycopg2 connection (no pool by default;
  callers can share a single PgmnemoClient across their agent run).
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import psycopg2
import psycopg2.extras

from .embed import embed, to_pgvector
from .extraction import chunk_text, extract_entities_relations

__all__ = ["PgmnemoClient", "connect"]

# Default recall mode: fast (pure HNSW).  Callers can pass deep=True for
# full 6-signal RRF fusion via recall_hybrid().
_RECALL_FAST_SQL = """
SELECT lesson_id, role, topic, lesson_text, importance, created_at
FROM pgmnemo.recall_fast(
    %s::vector(1024), %s, %s, %s, %s
)
"""

_RECALL_HYBRID_SQL = """
SELECT lesson_id, role, topic, lesson_text, importance, created_at
FROM pgmnemo.recall_hybrid(
    %s::vector(1024), %s, %s, %s, %s, 0.4, 0.4, 60, %s
)
"""


class PgmnemoClient:
    """Thin Python wrapper over the pgmnemo SQL API.

    Parameters
    ----------
    dsn : str
        PostgreSQL DSN, e.g. ``"postgresql://user:pass@localhost/db"``.
    embedding_server : str
        Base URL of an OpenAI-compatible embeddings endpoint.
        If empty, falls back to ``EMBEDDING_SERVER`` env var.
        If unset, ingest/recall work text-only (BM25 path only; no vectors).
    embedding_model : str
        Model name sent to the embedding server.
        Falls back to ``EMBEDDING_MODEL`` env var.
    embedding_dim : int
        Expected vector dimension.  Default 1024 (bge-m3).
    role : str
        Default role label for ingested lessons.
    project_id : int
        Default project_id for ingested lessons.
    """

    def __init__(
        self,
        dsn: str,
        *,
        embedding_server: str = "",
        embedding_model: str = "",
        embedding_dim: int = 1024,
        role: str = "pgmnemo_client",
        project_id: int = 1,
    ) -> None:
        self._dsn = dsn
        self._embed_server = embedding_server or os.environ.get("EMBEDDING_SERVER", "")
        self._embed_model = embedding_model or os.environ.get("EMBEDDING_MODEL", "")
        self._embed_dim = embedding_dim
        self._default_role = role
        self._default_project_id = project_id
        self._conn: psycopg2.extensions.connection | None = None

    # ------------------------------------------------------------------
    # Connection management
    # ------------------------------------------------------------------

    @property
    def conn(self) -> psycopg2.extensions.connection:
        """Lazy-open and return the underlying psycopg2 connection."""
        if self._conn is None or self._conn.closed:
            self._conn = psycopg2.connect(self._dsn)
        return self._conn

    def close(self) -> None:
        """Close the underlying database connection."""
        if self._conn and not self._conn.closed:
            self._conn.close()

    def __enter__(self) -> "PgmnemoClient":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    # ------------------------------------------------------------------
    # Embedding helper
    # ------------------------------------------------------------------

    def _embed(self, text: str) -> str | None:
        """Embed *text* and return a pgvector literal, or ``None``."""
        vec = embed(
            text,
            server=self._embed_server,
            model=self._embed_model,
            dim=self._embed_dim,
        )
        return to_pgvector(vec)

    # ------------------------------------------------------------------
    # ingest()
    # ------------------------------------------------------------------

    def ingest(
        self,
        text: str,
        *,
        role: str | None = None,
        topic: str = "general",
        importance: int = 3,
        project_id: int | None = None,
        commit_sha: str | None = None,
        artifact_hash: str | None = None,
        metadata: dict[str, Any] | None = None,
        item_kind: str = "note",
        source_dag_id: str | None = None,
    ) -> int:
        """Ingest a single lesson into pgmnemo agent memory.

        Calls ``pgmnemo.ingest()`` stored procedure — gets embedding dimension
        validation, provenance gate enforcement, and ``verified_at`` auto-stamp.

        Parameters
        ----------
        text : str
            The lesson text to ingest.
        role : str | None
            Role label.  Defaults to the client's ``role`` setting.
        topic : str
            Topic label for the lesson.
        importance : int
            1 (low) to 5 (critical).
        project_id : int | None
            Project scope.  Defaults to the client's ``project_id``.
        commit_sha : str | None
            Git commit SHA — stamps ``verified_at`` when provided.
        artifact_hash : str | None
            Build artifact hash — stamps ``verified_at`` when provided.
        metadata : dict | None
            Arbitrary JSONB metadata.
        item_kind : str
            Content-type classification: ``note|skill_md|template|script|
            reference|config|spec``.
        source_dag_id : str | None
            Workflow/DAG run ID that produced this lesson.

        Returns
        -------
        int
            The ``lesson_id`` (BIGINT) of the newly ingested lesson.
        """
        embedding = self._embed(text)
        _role = role or self._default_role
        _project_id = project_id if project_id is not None else self._default_project_id
        _meta = json.dumps(metadata) if metadata else "{}"

        with self.conn.cursor() as cur:
            cur.execute(
                """
                SELECT pgmnemo.ingest(
                    %s, %s, %s, %s, %s::smallint,
                    %s::vector(1024), %s, %s, %s::jsonb
                )
                """,
                (_role, _project_id, topic, text, importance,
                 embedding, commit_sha, artifact_hash, _meta),
            )
            new_id: int = cur.fetchone()[0]
            if item_kind != "note" or source_dag_id is not None:
                cur.execute(
                    """
                    UPDATE pgmnemo.agent_lesson
                    SET item_kind      = %s,
                        source_dag_id  = COALESCE(source_dag_id, %s)
                    WHERE id = %s
                    """,
                    (item_kind, source_dag_id, new_id),
                )
        self.conn.commit()
        return new_id

    # ------------------------------------------------------------------
    # recall()
    # ------------------------------------------------------------------

    def recall(
        self,
        query: str,
        *,
        top_k: int = 5,
        role_filter: str | None = None,
        project_id_filter: int | None = None,
        exclude_dag_id: str | None = None,
        deep: bool = False,
    ) -> list[dict[str, Any]]:
        """Recall the most relevant lessons for *query*.

        Parameters
        ----------
        query : str
            Natural-language query.
        top_k : int
            Maximum number of results to return.
        role_filter : str | None
            Restrict to lessons from this role.
        project_id_filter : int | None
            Restrict to lessons from this project.
        exclude_dag_id : str | None
            Suppress lessons whose ``source_dag_id`` matches (prevents a
            workflow from recalling its own in-flight outputs).
        deep : bool
            When ``False`` (default): uses ``recall_fast()`` — pure HNSW,
            O(k log n), lowest latency.
            When ``True``: uses ``recall_hybrid()`` — full 6-signal RRF
            fusion (vector + BM25 + graph + recency + confidence + provenance).

        Returns
        -------
        list[dict]
            Each dict has keys: ``lesson_id``, ``role``, ``topic``,
            ``lesson_text``, ``importance``, ``created_at``.
        """
        query_vec = self._embed(query)
        with self.conn.cursor(cursor_factory=psycopg2.extras.RealDictCursor) as cur:
            if deep:
                cur.execute(
                    _RECALL_HYBRID_SQL,
                    (query_vec, query, top_k, role_filter,
                     project_id_filter, exclude_dag_id),
                )
            else:
                cur.execute(
                    _RECALL_FAST_SQL,
                    (query_vec, top_k, role_filter,
                     project_id_filter, exclude_dag_id),
                )
            return [dict(row) for row in cur.fetchall()]

    # ------------------------------------------------------------------
    # reinforce()
    # ------------------------------------------------------------------

    def reinforce(
        self,
        lesson_ids: list[int],
        outcome: str,
    ) -> int:
        """Update confidence scores for *lesson_ids* based on *outcome*.

        Uses the batch ``pgmnemo.reinforce(BIGINT[], TEXT)`` overload
        (shipped in v0.7.1) — skips missing IDs silently.

        Parameters
        ----------
        lesson_ids : list[int]
            IDs returned by ``recall()``.
        outcome : str
            ``"success"``, ``"failure"``, or ``"neutral"``.

        Returns
        -------
        int
            Number of lessons actually updated.
        """
        if not lesson_ids:
            return 0
        with self.conn.cursor() as cur:
            cur.execute(
                "SELECT pgmnemo.reinforce(%s::BIGINT[], %s)",
                (lesson_ids, outcome),
            )
            updated: int = cur.fetchone()[0]
        self.conn.commit()
        return updated

    # ------------------------------------------------------------------
    # ingest_document()
    # ------------------------------------------------------------------

    def ingest_document(
        self,
        source: str,
        *,
        source_type: str = "text",
        role: str | None = None,
        topic: str | None = None,
        project_id: int | None = None,
        commit_sha: str | None = None,
        chunk_max_chars: int = 1500,
        chunk_overlap: int = 150,
        # Extraction — opt-in, explicit model required (R2: $0 write path preserved)
        extraction_model: str | None = None,
        extraction_api_key: str | None = None,
        extraction_confidence: float = 0.5,
        extraction_kwargs: dict[str, Any] | None = None,
        dag_id: str | None = None,
    ) -> dict[str, Any]:
        """Ingest a document: chunk → embed → ``pgmnemo.ingest()`` per chunk.

        This is the **$0 path** when called without ``extraction_model``:
        no LLM API calls are made, no external service is contacted beyond
        your own embedding server (if configured).

        LLM entity+relation extraction is **opt-in** — provide
        ``extraction_model`` explicitly to enable it.  The caller supplies
        their own API key; pgmnemo does not store or manage LLM credentials.

        Parameters
        ----------
        source : str
            Raw text, Markdown string, or a file path.  If the string is a
            readable file path, the file contents are read automatically.
        source_type : str
            ``"text"`` (default) or ``"markdown"``.  Currently informational;
            used as the ``item_kind`` for ingested chunks (stored as
            ``"reference"`` to distinguish from free-form notes).
        role : str | None
            Role label for ingested chunks.  Defaults to the client's ``role``.
        topic : str | None
            Topic label.  Defaults to the document filename or ``"document"``.
        project_id : int | None
            Project scope.
        commit_sha : str | None
            Provenance commit SHA.
        chunk_max_chars : int
            Soft character limit per chunk (default 1500).
        chunk_overlap : int
            Character overlap between consecutive chunks (default 150).
        extraction_model : str | None
            litellm model identifier for LLM entity+relation extraction,
            e.g. ``"claude-haiku-3-5"``.  **Omit to stay on the $0 path.**
        extraction_api_key : str | None
            API key passed to litellm.  Falls back to env vars if ``None``.
        extraction_confidence : float
            Minimum confidence for extracted entities/relations (default 0.5).
        extraction_kwargs : dict | None
            Extra kwargs forwarded to ``litellm.completion()``.
        dag_id : str | None
            Workflow/DAG run ID — stored as ``source_dag_id`` on each chunk.

        Returns
        -------
        dict with keys:
            ``chunks_ingested``  — number of chunks stored,
            ``lesson_ids``       — list of lesson_ids created,
            ``edges_created``    — number of ``mem_edge`` rows written
                                   (0 when ``extraction_model`` is ``None``),
            ``extraction_used``  — bool, whether LLM extraction ran.
        """
        # Resolve source text
        try:
            p = Path(source)
            if p.is_file():
                text = p.read_text(encoding="utf-8")
                _topic = topic or p.stem
            else:
                text = source
                _topic = topic or "document"
        except OSError:
            text = source
            _topic = topic or "document"

        chunks = chunk_text(text, max_chars=chunk_max_chars, overlap=chunk_overlap)
        if not chunks:
            return {"chunks_ingested": 0, "lesson_ids": [], "edges_created": 0,
                    "extraction_used": False}

        _role = role or self._default_role
        _project_id = project_id if project_id is not None else self._default_project_id
        lesson_ids: list[int] = []
        edges_created = 0

        for chunk in chunks:
            lid = self.ingest(
                chunk,
                role=_role,
                topic=_topic,
                project_id=_project_id,
                commit_sha=commit_sha,
                item_kind="reference",
                source_dag_id=dag_id,
            )
            lesson_ids.append(lid)

            # Optional LLM extraction — caller must explicitly opt in
            if extraction_model:
                extracted = extract_entities_relations(
                    chunk,
                    model=extraction_model,
                    api_key=extraction_api_key,
                    confidence_threshold=extraction_confidence,
                    extra_kwargs=extraction_kwargs,
                )
                edges_created += self._write_extracted_edges(
                    lid, extracted, _role, _project_id, _topic, dag_id
                )

        # Log to memory_ingest_log for provenance tracking
        self._log_ingest(
            source_origin=_topic,
            lesson_ids=lesson_ids,
        )

        return {
            "chunks_ingested": len(lesson_ids),
            "lesson_ids": lesson_ids,
            "edges_created": edges_created,
            "extraction_used": extraction_model is not None,
        }

    # ------------------------------------------------------------------
    # Private helpers
    # ------------------------------------------------------------------

    def _write_extracted_edges(
        self,
        anchor_lesson_id: int,
        extracted: dict[str, Any],
        role: str,
        project_id: int,
        topic: str,
        dag_id: str | None,
    ) -> int:
        """Persist extracted entities as lessons + relations as edges.

        Each entity becomes a lesson with ``item_kind='reference'`` and
        ``content_type='entity'``.  Each relation becomes a ``mem_edge``
        via ``pgmnemo.add_edge()``.

        Returns the number of edges written.
        """
        entity_lesson_map: dict[str, int] = {}
        edges_written = 0

        with self.conn.cursor() as cur:
            for entity in extracted.get("entities", []):
                name = entity.get("name", "").strip()
                etype = entity.get("type", "concept").strip()
                if not name:
                    continue
                # Embed the entity name for vector recall
                entity_text = f"{name} ({etype})"
                entity_vec = self._embed(entity_text)
                # Ingest entity as a reference lesson
                cur.execute(
                    """
                    SELECT pgmnemo.ingest(
                        %s, %s, %s, %s, 2::smallint,
                        %s::vector(1024), NULL, NULL, %s::jsonb
                    )
                    """,
                    (role, project_id, topic, entity_text, entity_vec,
                     json.dumps({"entity_name": name, "entity_type": etype})),
                )
                eid = cur.fetchone()[0]
                # Mark as entity content_type
                cur.execute(
                    """
                    UPDATE pgmnemo.agent_lesson
                    SET content_type  = 'entity',
                        item_kind     = 'reference',
                        source_dag_id = COALESCE(source_dag_id, %s)
                    WHERE id = %s
                    """,
                    (dag_id, eid),
                )
                entity_lesson_map[name.lower()] = eid
                # Edge: anchor chunk → entity
                cur.execute(
                    """
                    SELECT pgmnemo.add_edge(
                        %s, %s,
                        'mentions', 0.7::REAL
                    )
                    """,
                    (anchor_lesson_id, eid),
                )
                edges_written += 1

            # Write relation edges between entity lessons
            for rel in extracted.get("relations", []):
                src_name = rel.get("source", "").strip().lower()
                tgt_name = rel.get("target", "").strip().lower()
                rel_type = rel.get("relation_type", "related_to").strip()
                if not src_name or not tgt_name:
                    continue
                src_id = entity_lesson_map.get(src_name)
                tgt_id = entity_lesson_map.get(tgt_name)
                if src_id is None or tgt_id is None:
                    continue
                cur.execute(
                    """
                    SELECT pgmnemo.add_edge(
                        %s, %s,
                        %s, 0.7::REAL
                    )
                    """,
                    (src_id, tgt_id, rel_type),
                )
                edges_written += 1

        self.conn.commit()
        return edges_written

    def _log_ingest(self, source_origin: str, lesson_ids: list[int]) -> None:
        """Write a row to ``pgmnemo.memory_ingest_log`` (v0.9.6+)."""
        if not lesson_ids:
            return
        try:
            with self.conn.cursor() as cur:
                cur.execute(
                    """
                    INSERT INTO pgmnemo.memory_ingest_log
                        (source_origin, min_id, max_id)
                    VALUES (%s, %s, %s)
                    """,
                    (source_origin, min(lesson_ids), max(lesson_ids)),
                )
            self.conn.commit()
        except Exception:  # noqa: BLE001 — log table may not exist in all deployments
            self.conn.rollback()


# ---------------------------------------------------------------------------
# Module-level connect() convenience function
# ---------------------------------------------------------------------------

def connect(
    dsn: str,
    *,
    embedding_server: str = "",
    embedding_model: str = "",
    embedding_dim: int = 1024,
    role: str = "pgmnemo_client",
    project_id: int = 1,
) -> PgmnemoClient:
    """Open a connection to pgmnemo and return a :class:`PgmnemoClient`.

    Parameters
    ----------
    dsn : str
        PostgreSQL connection string.
    embedding_server : str
        Optional OpenAI-compatible embeddings endpoint URL.
    embedding_model : str
        Optional model name for the embedding server.
    embedding_dim : int
        Expected embedding dimension (default 1024).
    role : str
        Default role label for ingested lessons.
    project_id : int
        Default project_id scope.

    Returns
    -------
    PgmnemoClient
        A connected client.  Use as a context manager for automatic cleanup.

    Examples
    --------
    >>> mem = pgmnemo.connect("postgresql://localhost/mydb")
    >>> mem.ingest("Use select_related() to avoid N+1 queries.")
    42
    >>> results = mem.recall("database query optimization", top_k=3)
    >>> mem.close()

    Or as a context manager::

        with pgmnemo.connect("postgresql://localhost/mydb") as mem:
            mem.ingest("lesson text")
    """
    return PgmnemoClient(
        dsn,
        embedding_server=embedding_server,
        embedding_model=embedding_model,
        embedding_dim=embedding_dim,
        role=role,
        project_id=project_id,
    )
