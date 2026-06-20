"""Unit tests for pgmnemo_mcp.server — ingest() and recall() tools.

Uses unittest.mock to patch get_pool() so no live PostgreSQL is required.
All tests verify the SQL / SP call generated and the return shape of each function.
"""
from __future__ import annotations

import importlib
import json
import sys
import types
import unittest
from datetime import datetime
from unittest.mock import MagicMock, patch, call


# ---------------------------------------------------------------------------
# Stub the `mcp` package so tests run without `mcp` installed
# ---------------------------------------------------------------------------

def _stub_mcp() -> None:
    if "mcp" in sys.modules:
        return
    mcp_pkg = types.ModuleType("mcp")
    server_pkg = types.ModuleType("mcp.server")
    fastmcp_mod = types.ModuleType("mcp.server.fastmcp")

    class _FastMCP:
        def __init__(self, name: str, **kw: object) -> None:
            self.name = name

        def tool(self, **kw: object):
            def decorator(fn):
                return fn
            return decorator

        def run(self) -> None:
            pass

    fastmcp_mod.FastMCP = _FastMCP
    sys.modules["mcp"] = mcp_pkg
    sys.modules["mcp.server"] = server_pkg
    sys.modules["mcp.server.fastmcp"] = fastmcp_mod


_stub_mcp()

# Force reimport after stub
for mod in list(sys.modules):
    if mod.startswith("pgmnemo_mcp"):
        del sys.modules[mod]

from pgmnemo_mcp import server  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_pool(rows=None, description=None):
    """Return a mock psycopg2 connection pool and cursor."""
    pool = MagicMock()
    conn = MagicMock()
    cur = MagicMock()

    pool.getconn.return_value = conn
    conn.cursor.return_value.__enter__ = lambda s: cur
    conn.cursor.return_value.__exit__ = MagicMock(return_value=False)

    if rows is not None:
        cur.fetchone.return_value = rows[0] if rows else None
        cur.fetchall.return_value = rows
    if description is not None:
        cur.description = [(col,) for col in description]

    return pool, conn, cur


# ---------------------------------------------------------------------------
# ingest() tests
# ---------------------------------------------------------------------------

class TestIngest(unittest.TestCase):

    def test_returns_id(self):
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (42,)
        with patch.object(server, "get_pool", return_value=pool):
            result = server.ingest(text="hello world")
        self.assertEqual(result["id"], 42)

    def test_calls_ingest_sp_not_raw_insert(self):
        """Regression: must call pgmnemo.ingest() SP, not raw INSERT."""
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (1,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="test lesson")
        sql = cur.execute.call_args[0][0]
        self.assertIn("pgmnemo.ingest", sql)
        self.assertNotIn("INSERT INTO", sql)

    def test_default_params_sent_to_sp(self):
        """SP receives args in positional order: role, project_id, topic, text, importance, ..."""
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (1,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="test lesson")
        args = cur.execute.call_args[0][1]
        # Positional order matches SP signature: role, project_id, topic, lesson_text, importance
        self.assertEqual(args[0], "mcp_agent")    # role
        self.assertEqual(args[1], 1)              # project_id
        self.assertEqual(args[2], "general")      # topic
        self.assertEqual(args[3], "test lesson")  # lesson_text
        self.assertEqual(args[4], 3)              # importance

    def test_project_id_passed_through(self):
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (7,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="x", project_id=99)
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[1], 99)

    def test_commit_sha_and_artifact_hash_forwarded(self):
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (5,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="x", commit_sha="abc123", artifact_hash="def456")
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[6], "abc123")   # commit_sha
        self.assertEqual(args[7], "def456")   # artifact_hash

    def test_metadata_serialized_to_json(self):
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (3,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="x", metadata={"key": "val"})
        args = cur.execute.call_args[0][1]
        self.assertEqual(json.loads(args[8]), {"key": "val"})

    def test_none_metadata_defaults_to_empty_json_object(self):
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (3,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="x")
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[8], "{}")

    def test_jsonb_cast_present_in_sql(self):
        """Ensures metadata arg is cast to ::jsonb so PostgreSQL accepts it."""
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (1,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="x")
        sql = cur.execute.call_args[0][0]
        self.assertIn("::jsonb", sql)

    def test_conn_returned_to_pool(self):
        pool, conn, cur = _make_pool()
        cur.fetchone.return_value = (1,)
        with patch.object(server, "get_pool", return_value=pool):
            server.ingest(text="x")
        pool.putconn.assert_called_once_with(conn)

    def test_conn_returned_on_exception(self):
        pool, conn, cur = _make_pool()
        cur.execute.side_effect = RuntimeError("db down")
        with patch.object(server, "get_pool", return_value=pool):
            with self.assertRaises(RuntimeError):
                server.ingest(text="boom")
        pool.putconn.assert_called_once_with(conn)


# ---------------------------------------------------------------------------
# recall() tests
# ---------------------------------------------------------------------------

class TestRecall(unittest.TestCase):

    def test_returns_list_of_dicts(self):
        ts = datetime(2026, 5, 17)
        rows = [(10, "agent", "memory", "lesson A", 3, ts)]
        cols = ["lesson_id", "role", "topic", "lesson_text", "importance", "created_at"]
        pool, conn, cur = _make_pool(rows=rows, description=cols)
        with patch.object(server, "get_pool", return_value=pool):
            result = server.recall(query="memory test")
        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["lesson_id"], 10)
        self.assertEqual(result[0]["lesson_text"], "lesson A")

    def test_default_top_k_is_5(self):
        pool, conn, cur = _make_pool(rows=[], description=["lesson_id"])
        with patch.object(server, "get_pool", return_value=pool):
            server.recall(query="q")
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[1], 5)   # top_k

    def test_top_k_passed_through(self):
        pool, conn, cur = _make_pool(rows=[], description=["lesson_id"])
        with patch.object(server, "get_pool", return_value=pool):
            server.recall(query="q", top_k=10)
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[1], 10)

    def test_query_text_forwarded(self):
        pool, conn, cur = _make_pool(rows=[], description=["lesson_id"])
        with patch.object(server, "get_pool", return_value=pool):
            server.recall(query="find lessons about memory")
        args = cur.execute.call_args[0][1]
        self.assertEqual(args[2], "find lessons about memory")

    def test_empty_result(self):
        pool, conn, cur = _make_pool(rows=[], description=["lesson_id"])
        with patch.object(server, "get_pool", return_value=pool):
            result = server.recall(query="nothing")
        self.assertEqual(result, [])

    def test_conn_returned_to_pool(self):
        pool, conn, cur = _make_pool(rows=[], description=["lesson_id"])
        with patch.object(server, "get_pool", return_value=pool):
            server.recall(query="x")
        pool.putconn.assert_called_once_with(conn)

    def test_conn_returned_on_exception(self):
        pool, conn, cur = _make_pool()
        cur.execute.side_effect = RuntimeError("db error")
        with patch.object(server, "get_pool", return_value=pool):
            with self.assertRaises(RuntimeError):
                server.recall(query="x")
        pool.putconn.assert_called_once_with(conn)


if __name__ == "__main__":
    unittest.main()
