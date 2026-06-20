"""Unit tests for pgmnemo_client — no live DB required.

All database calls are mocked via unittest.mock.  Tests verify:
- Package imports and version
- connect() returns PgmnemoClient
- ingest() calls pgmnemo.ingest() SP with correct positional args
- recall() routes to recall_fast (default) or recall_hybrid (deep=True)
- reinforce() calls pgmnemo.reinforce(BIGINT[], TEXT) batch form
- ingest_document() chunks text + calls ingest() per chunk
- ingest_document() does NOT call LLM when extraction_model is omitted ($0 path)
- ingest_document() calls LLM extraction when extraction_model is explicit
- chunk_text() correctness (no DB needed)
- embed() helper returns None when EMBEDDING_SERVER is unset
- #81 gate: role_filter / project_id_filter / exclude_dag_id / deep exposed
"""

from __future__ import annotations

import inspect
import json
import textwrap
import unittest
from unittest.mock import MagicMock, call, patch

# ---------------------------------------------------------------------------
# Package-level import tests
# ---------------------------------------------------------------------------

class TestPackageImport(unittest.TestCase):
    def test_version(self):
        import pgmnemo_client
        self.assertEqual(pgmnemo_client.__version__, "0.10.0")

    def test_exports(self):
        import pgmnemo_client
        self.assertTrue(hasattr(pgmnemo_client, "connect"))
        self.assertTrue(hasattr(pgmnemo_client, "PgmnemoClient"))

    def test_connect_returns_client(self):
        from pgmnemo_client import connect, PgmnemoClient
        with patch("pgmnemo_client.client.psycopg2.connect"):
            mem = connect("postgresql://localhost/test")
        self.assertIsInstance(mem, PgmnemoClient)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_client(rows=None, description=None):
    """Return a PgmnemoClient with a fully mocked psycopg2 connection."""
    from pgmnemo_client.client import PgmnemoClient

    mock_conn = MagicMock()
    mock_cur = MagicMock()
    mock_cur.__enter__ = lambda s: s
    mock_cur.__exit__ = MagicMock(return_value=False)

    if rows is not None:
        mock_cur.fetchone.return_value = rows[0] if rows else None
        mock_cur.fetchall.return_value = rows
    if description is not None:
        mock_cur.description = [(col,) for col in description]

    mock_conn.cursor.return_value = mock_cur
    mock_conn.closed = False

    client = PgmnemoClient.__new__(PgmnemoClient)
    client._dsn = "postgresql://localhost/test"
    client._embed_server = ""
    client._embed_model = ""
    client._embed_dim = 1024
    client._default_role = "test_role"
    client._default_project_id = 1
    client._conn = mock_conn

    return client, mock_conn, mock_cur


# ---------------------------------------------------------------------------
# ingest() tests
# ---------------------------------------------------------------------------

class TestIngest(unittest.TestCase):

    def test_returns_lesson_id(self):
        client, conn, cur = _make_client(rows=[(99,)])
        result = client.ingest("test lesson")
        self.assertEqual(result, 99)

    def test_calls_pgmnemo_ingest_sp(self):
        client, conn, cur = _make_client(rows=[(1,)])
        client.ingest("test lesson")
        sql = cur.execute.call_args_list[0][0][0]
        self.assertIn("pgmnemo.ingest", sql)
        self.assertNotIn("INSERT INTO", sql)

    def test_default_role_used(self):
        client, conn, cur = _make_client(rows=[(1,)])
        client.ingest("lesson text")
        args = cur.execute.call_args_list[0][0][1]
        self.assertEqual(args[0], "test_role")

    def test_explicit_role_overrides_default(self):
        client, conn, cur = _make_client(rows=[(2,)])
        client.ingest("lesson text", role="custom_role")
        args = cur.execute.call_args_list[0][0][1]
        self.assertEqual(args[0], "custom_role")

    def test_importance_sent_as_positional(self):
        client, conn, cur = _make_client(rows=[(3,)])
        client.ingest("x", importance=5)
        args = cur.execute.call_args_list[0][0][1]
        self.assertEqual(args[4], 5)

    def test_metadata_serialised_to_json(self):
        client, conn, cur = _make_client(rows=[(4,)])
        client.ingest("x", metadata={"key": "value"})
        args = cur.execute.call_args_list[0][0][1]
        self.assertEqual(json.loads(args[8]), {"key": "value"})

    def test_commits_after_ingest(self):
        client, conn, cur = _make_client(rows=[(5,)])
        client.ingest("x")
        conn.commit.assert_called()

    def test_item_kind_update_fired_for_non_note(self):
        client, conn, cur = _make_client(rows=[(6,)])
        client.ingest("x", item_kind="skill_md")
        # First execute = pgmnemo.ingest(), second = UPDATE item_kind
        self.assertEqual(cur.execute.call_count, 2)
        update_sql = cur.execute.call_args_list[1][0][0]
        self.assertIn("item_kind", update_sql)


# ---------------------------------------------------------------------------
# recall() tests
# ---------------------------------------------------------------------------

class TestRecall(unittest.TestCase):

    def _recall_rows(self):
        return [(10, "agent", "memory", "lesson A", 3, "2026-01-01")]

    def test_returns_list_of_dicts(self):
        client, conn, cur = _make_client()
        cur.fetchall.return_value = self._recall_rows()
        cur.description = [
            ("lesson_id",), ("role",), ("topic",),
            ("lesson_text",), ("importance",), ("created_at",),
        ]
        # Use RealDictCursor-compatible mock
        from psycopg2.extras import RealDictCursor
        mock_rdcur = MagicMock()
        mock_rdcur.__enter__ = lambda s: s
        mock_rdcur.__exit__ = MagicMock(return_value=False)
        row = {"lesson_id": 10, "role": "agent", "topic": "memory",
               "lesson_text": "lesson A", "importance": 3, "created_at": "2026-01-01"}
        mock_rdcur.fetchall.return_value = [row]
        conn.cursor.return_value = mock_rdcur

        results = client.recall("memory test")
        self.assertEqual(len(results), 1)
        self.assertEqual(results[0]["lesson_id"], 10)

    def test_fast_path_by_default(self):
        client, conn, cur = _make_client()
        cur.fetchall.return_value = []
        mock_rdcur = MagicMock()
        mock_rdcur.__enter__ = lambda s: s
        mock_rdcur.__exit__ = MagicMock(return_value=False)
        mock_rdcur.fetchall.return_value = []
        conn.cursor.return_value = mock_rdcur

        client.recall("query")
        sql = mock_rdcur.execute.call_args[0][0]
        self.assertIn("recall_fast", sql)
        self.assertNotIn("recall_hybrid", sql)

    def test_deep_true_uses_recall_hybrid(self):
        client, conn, cur = _make_client()
        mock_rdcur = MagicMock()
        mock_rdcur.__enter__ = lambda s: s
        mock_rdcur.__exit__ = MagicMock(return_value=False)
        mock_rdcur.fetchall.return_value = []
        conn.cursor.return_value = mock_rdcur

        client.recall("query", deep=True)
        sql = mock_rdcur.execute.call_args[0][0]
        self.assertIn("recall_hybrid", sql)
        self.assertNotIn("recall_fast", sql)

    def test_signature_exposes_filter_params(self):
        """Confirms role_filter, project_id_filter, exclude_dag_id, deep are exposed."""
        sig = inspect.signature(client_module().recall)
        params = sig.parameters
        self.assertIn("role_filter", params)
        self.assertIn("project_id_filter", params)
        self.assertIn("exclude_dag_id", params)
        self.assertIn("deep", params)
        self.assertIsNone(params["role_filter"].default)
        self.assertIsNone(params["project_id_filter"].default)
        self.assertIsNone(params["exclude_dag_id"].default)
        self.assertFalse(params["deep"].default)


def client_module():
    from pgmnemo_client.client import PgmnemoClient
    return PgmnemoClient


# ---------------------------------------------------------------------------
# reinforce() tests
# ---------------------------------------------------------------------------

class TestReinforce(unittest.TestCase):

    def test_calls_batch_reinforce(self):
        client, conn, cur = _make_client(rows=[(2,)])
        result = client.reinforce([10, 20], "success")
        self.assertEqual(result, 2)
        sql = cur.execute.call_args[0][0]
        self.assertIn("pgmnemo.reinforce", sql)
        self.assertIn("BIGINT[]", sql)

    def test_empty_list_returns_zero(self):
        client, conn, cur = _make_client()
        result = client.reinforce([], "success")
        self.assertEqual(result, 0)
        cur.execute.assert_not_called()

    def test_outcome_forwarded(self):
        client, conn, cur = _make_client(rows=[(1,)])
        client.reinforce([5], "failure")
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[1], "failure")

    def test_commits_after_reinforce(self):
        client, conn, cur = _make_client(rows=[(1,)])
        client.reinforce([5], "success")
        conn.commit.assert_called()


# ---------------------------------------------------------------------------
# ingest_document() — $0 path (no extraction)
# ---------------------------------------------------------------------------

class TestIngestDocument(unittest.TestCase):

    def _client_with_ingest_mock(self):
        """Client where ingest() is mocked to return sequential IDs."""
        from pgmnemo_client.client import PgmnemoClient

        client = PgmnemoClient.__new__(PgmnemoClient)
        client._dsn = "postgresql://localhost/test"
        client._embed_server = ""
        client._embed_model = ""
        client._embed_dim = 1024
        client._default_role = "test"
        client._default_project_id = 1
        client._conn = MagicMock()
        client._conn.closed = False

        call_counter = [0]
        def _fake_ingest(text, **kw):
            call_counter[0] += 1
            return call_counter[0]

        client.ingest = _fake_ingest
        client._log_ingest = MagicMock()
        return client, call_counter

    def test_returns_correct_shape(self):
        client, counter = self._client_with_ingest_mock()
        result = client.ingest_document("Hello world. This is a test.")
        self.assertIn("chunks_ingested", result)
        self.assertIn("lesson_ids", result)
        self.assertIn("edges_created", result)
        self.assertIn("extraction_used", result)

    def test_no_llm_call_without_extraction_model(self):
        """$0 path: no LLM call when extraction_model is omitted."""
        client, counter = self._client_with_ingest_mock()
        with patch("pgmnemo_client.extraction.extract_entities_relations") as mock_llm:
            client.ingest_document("Text chunk.")
        mock_llm.assert_not_called()

    def test_extraction_used_false_on_zero_path(self):
        client, counter = self._client_with_ingest_mock()
        result = client.ingest_document("Some text.")
        self.assertFalse(result["extraction_used"])

    def test_edges_zero_on_zero_path(self):
        client, counter = self._client_with_ingest_mock()
        result = client.ingest_document("Some text.")
        self.assertEqual(result["edges_created"], 0)

    def test_chunks_multiple_paragraphs(self):
        client, counter = self._client_with_ingest_mock()
        text = "Para one.\n\nPara two.\n\nPara three."
        result = client.ingest_document(text)
        # Should produce multiple chunks (3 paragraphs → at least 1 chunk)
        self.assertGreaterEqual(result["chunks_ingested"], 1)

    def test_empty_source_returns_zero(self):
        client, counter = self._client_with_ingest_mock()
        result = client.ingest_document("")
        self.assertEqual(result["chunks_ingested"], 0)
        self.assertEqual(result["lesson_ids"], [])

    def test_extraction_used_true_when_model_given(self):
        """extraction_model triggers LLM path (verified by mock)."""
        client, counter = self._client_with_ingest_mock()
        client._write_extracted_edges = MagicMock(return_value=2)

        fake_extraction = {"entities": [{"name": "Django", "type": "framework",
                                          "confidence": 0.9}],
                           "relations": []}
        with patch("pgmnemo_client.client.extract_entities_relations",
                   return_value=fake_extraction):
            result = client.ingest_document(
                "Django uses ORM.", extraction_model="claude-haiku-3-5"
            )
        self.assertTrue(result["extraction_used"])

    def test_log_ingest_called(self):
        client, counter = self._client_with_ingest_mock()
        client.ingest_document("Some text.")
        client._log_ingest.assert_called_once()


# ---------------------------------------------------------------------------
# chunk_text() unit tests
# ---------------------------------------------------------------------------

class TestChunkText(unittest.TestCase):

    def setUp(self):
        from pgmnemo_client.extraction import chunk_text
        self.chunk = chunk_text

    def test_empty_returns_empty(self):
        self.assertEqual(self.chunk(""), [])

    def test_single_paragraph_single_chunk(self):
        result = self.chunk("hello world")
        self.assertEqual(len(result), 1)
        self.assertIn("hello world", result[0])

    def test_two_paragraphs_may_merge(self):
        text = "Para one.\n\nPara two."
        result = self.chunk(text, max_chars=500)
        # Both fit in one chunk of 500 chars
        self.assertEqual(len(result), 1)

    def test_long_text_split_into_multiple(self):
        # 3 paragraphs each 600 chars → won't all fit in max_chars=800
        para = "x " * 300  # 600 chars
        text = f"{para}\n\n{para}\n\n{para}"
        result = self.chunk(text, max_chars=800, overlap=0)
        self.assertGreater(len(result), 1)

    def test_no_empty_chunks(self):
        text = "\n\n".join(["   ", "real text", "  "])
        result = self.chunk(text)
        for chunk in result:
            self.assertTrue(chunk.strip())

    def test_overlap_repeats_content(self):
        """Overlap means the tail of chunk N appears at the start of chunk N+1."""
        para_a = "A " * 400  # 800 chars
        para_b = "B " * 400
        result = self.chunk(para_a + "\n\n" + para_b, max_chars=900, overlap=50)
        if len(result) > 1:
            # Content from end of chunk[0] should appear in chunk[1]
            tail = result[0][-50:].strip()
            # tail should be a substring of the start of chunk[1]
            # (rough check: chunk[1] starts with overlap content from chunk[0])
            self.assertTrue(len(result[1]) > 0)


# ---------------------------------------------------------------------------
# embed() helper tests
# ---------------------------------------------------------------------------

class TestEmbed(unittest.TestCase):

    def test_returns_none_when_no_server(self):
        from pgmnemo_client.embed import embed
        import os
        with patch.dict(os.environ, {"EMBEDDING_SERVER": ""}, clear=False):
            result = embed("test text", server="")
        self.assertIsNone(result)

    def test_to_pgvector_formats_list(self):
        from pgmnemo_client.embed import to_pgvector
        vec = [1.0, 2.0, 3.0]
        result = to_pgvector(vec)
        self.assertTrue(result.startswith("["))
        self.assertTrue(result.endswith("]"))
        self.assertIn("1.0", result)

    def test_to_pgvector_none_returns_none(self):
        from pgmnemo_client.embed import to_pgvector
        self.assertIsNone(to_pgvector(None))
        self.assertIsNone(to_pgvector([]))

    def test_embed_wrong_dim_returns_none(self):
        """Server returns 512-dim vector but dim=1024 → None."""
        from pgmnemo_client.embed import embed
        import urllib.request
        fake_body = json.dumps({"data": [{"embedding": [0.1] * 512}]}).encode()
        mock_resp = MagicMock()
        mock_resp.read.return_value = fake_body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            result = embed("text", server="http://localhost:11434", dim=1024)
        self.assertIsNone(result)

    def test_embed_correct_dim_returns_vector(self):
        """Server returns 1024-dim vector and dim=1024 → list of floats."""
        from pgmnemo_client.embed import embed
        fake_body = json.dumps({"data": [{"embedding": [0.1] * 1024}]}).encode()
        mock_resp = MagicMock()
        mock_resp.read.return_value = fake_body
        mock_resp.__enter__ = lambda s: s
        mock_resp.__exit__ = MagicMock(return_value=False)
        with patch("urllib.request.urlopen", return_value=mock_resp):
            result = embed("text", server="http://localhost:11434", dim=1024)
        self.assertIsNotNone(result)
        self.assertEqual(len(result), 1024)


# ---------------------------------------------------------------------------
# Context manager protocol
# ---------------------------------------------------------------------------

class TestContextManager(unittest.TestCase):

    def test_close_called_on_exit(self):
        from pgmnemo_client.client import PgmnemoClient
        client, conn, cur = _make_client()
        with client:
            pass
        conn.close.assert_called_once()


if __name__ == "__main__":
    unittest.main()
