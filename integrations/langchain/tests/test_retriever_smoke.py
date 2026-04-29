"""Smoke test: PgmnemoRetriever constructs correct SQL without a real DB."""
from unittest.mock import MagicMock, patch

import pytest

from pgmnemo_langchain import PgmnemoRetriever


FAKE_EMBEDDING = [0.1] * 1024


def _make_retriever(**kwargs) -> PgmnemoRetriever:
    defaults = dict(
        conn_str="postgresql://test:test@localhost/test",
        role="test-agent",
        project_id=1,
        top_k=5,
        embedding_fn=lambda _: FAKE_EMBEDDING,
    )
    defaults.update(kwargs)
    return PgmnemoRetriever(**defaults)


def _fake_cursor_ctx(rows, columns):
    """Return a context-manager mock that behaves like psycopg2 cursor."""
    cursor = MagicMock()
    cursor.fetchall.return_value = rows
    cursor.description = [MagicMock(name=col) for col in columns]
    for mock, col in zip(cursor.description, columns):
        mock.__getitem__ = lambda self, i, c=col: c  # noqa: ARG005
        type(mock).name = col  # psycopg2 Column.name

    cm = MagicMock()
    cm.__enter__ = MagicMock(return_value=cursor)
    cm.__exit__ = MagicMock(return_value=False)
    return cm, cursor


def test_correct_sql_called():
    columns = [
        "lesson_id", "score", "role", "project_id", "topic",
        "lesson_text", "importance", "metadata", "commit_sha",
        "artifact_hash", "verified_at", "created_at",
    ]
    fake_rows = [(1, 0.95, "test-agent", 1, "retry policy",
                  "Use exponential backoff.", 4, None, "abc123", None, None, None)]

    cm, cursor = _fake_cursor_ctx(fake_rows, columns)

    mock_conn = MagicMock()
    mock_conn.cursor.return_value = cm

    with patch("pgmnemo_langchain.retriever.psycopg2.connect", return_value=mock_conn):
        retriever = _make_retriever()
        docs = retriever.invoke("retry strategy")

    # Verify correct SQL was issued
    cursor.execute.assert_called_once()
    call_args = cursor.execute.call_args
    sql: str = call_args[0][0]
    assert "pgmnemo.recall_lessons" in sql
    params = call_args[0][1]
    assert params[0] == FAKE_EMBEDDING   # query_embedding
    assert params[1] == 5                # top_k
    assert params[2] == "test-agent"     # role
    assert params[3] == 1                # project_id
    assert params[4] == "retry strategy" # query_text

    # Verify document wrapping
    assert len(docs) == 1
    assert docs[0].page_content == "Use exponential backoff."
    assert docs[0].metadata["topic"] == "retry policy"
    assert docs[0].metadata["score"] == pytest.approx(0.95)


def test_raises_without_embedding_fn():
    retriever = _make_retriever(embedding_fn=None)
    with pytest.raises(ValueError, match="embedding_fn"):
        retriever.invoke("anything")
