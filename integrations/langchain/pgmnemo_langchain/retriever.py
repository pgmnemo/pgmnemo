"""LangChain BaseRetriever adapter for pgmnemo.recall_lessons()."""
from __future__ import annotations

from typing import Any, Callable, List, Optional

import psycopg2
from langchain_core.callbacks import CallbackManagerForRetrieverRun
from langchain_core.documents import Document
from langchain_core.retrievers import BaseRetriever
from pydantic import ConfigDict, Field


class PgmnemoRetriever(BaseRetriever):
    """Retrieve agent lessons from a pgmnemo-enabled PostgreSQL database.

    Calls ``pgmnemo.recall_lessons(query_embedding, k, role, project_id, query_text)``
    and wraps each returned row as a :class:`langchain_core.documents.Document`.

    Args:
        conn_str: libpq connection string (e.g. ``"postgresql://user:pw@host/db"``).
        role: Agent role filter passed to ``recall_lessons``. ``None`` = all roles.
        project_id: Integer project filter. ``None`` = all projects.
        top_k: Maximum number of lessons to return (default 10).
        embedding_fn: Callable ``(text: str) -> list[float]`` that produces a
            1024-dimensional embedding vector.  Required at retrieval time.
    """

    model_config = ConfigDict(arbitrary_types_allowed=True)

    conn_str: str
    role: Optional[str] = None
    project_id: Optional[int] = None
    top_k: int = Field(default=10, ge=1)
    embedding_fn: Optional[Callable[[str], List[float]]] = None

    def _get_relevant_documents(
        self,
        query: str,
        *,
        run_manager: CallbackManagerForRetrieverRun,
    ) -> List[Document]:
        """Return lessons relevant to *query* from the pgmnemo database.

        Args:
            query: Natural-language query string.
            run_manager: LangChain callback manager (passed by the framework).

        Returns:
            List of :class:`Document` objects, one per lesson row, ordered by
            descending hybrid score.

        Raises:
            ValueError: If *embedding_fn* is not set.
            psycopg2.Error: On database connectivity or query failures.
        """
        if self.embedding_fn is None:
            raise ValueError(
                "embedding_fn must be provided to PgmnemoRetriever before retrieval."
            )

        embedding: List[float] = self.embedding_fn(query)

        conn = psycopg2.connect(self.conn_str)
        try:
            with conn.cursor() as cur:
                cur.execute(
                    "SELECT * FROM pgmnemo.recall_lessons(%s, %s, %s, %s, %s)",
                    (embedding, self.top_k, self.role, self.project_id, query),
                )
                rows = cur.fetchall()
                columns = [desc[0] for desc in cur.description]
        finally:
            conn.close()

        documents: List[Document] = []
        for row in rows:
            record: dict[str, Any] = dict(zip(columns, row))
            page_content = record.pop("lesson_text", "") or ""
            documents.append(Document(page_content=page_content, metadata=record))

        return documents
