"""Smoke tests for pgmnemo_mcp — import and tool registration, no live DB required."""

import importlib
import unittest
from unittest.mock import MagicMock, patch


class TestImport(unittest.TestCase):
    def test_package_imports(self):
        import pgmnemo_mcp
        assert pgmnemo_mcp.__version__ == "0.11.0"

    def test_server_imports(self):
        from pgmnemo_mcp import server
        assert hasattr(server, "mcp")
        assert hasattr(server, "ingest")
        assert hasattr(server, "recall")
        assert hasattr(server, "get_params")


class TestToolsRegistered(unittest.TestCase):
    def test_tools_listed(self):
        from pgmnemo_mcp.server import mcp
        # FastMCP exposes registered tools via ._tool_manager or similar; check via list_tools
        # We verify tool names are present in the server's tool registry.
        tools = mcp._tool_manager.list_tools()
        names = [t.name for t in tools]
        assert "pgmnemo.ingest" in names, f"pgmnemo.ingest not found in {names}"
        assert "pgmnemo.recall" in names, f"pgmnemo.recall not found in {names}"
        assert "pgmnemo.get_params" in names, f"pgmnemo.get_params not found in {names}"


class TestIngestUnit(unittest.TestCase):
    def test_ingest_calls_db(self):
        from pgmnemo_mcp import server

        mock_conn = MagicMock()
        mock_cur = MagicMock()
        mock_cur.__enter__ = lambda s: s
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.fetchone.return_value = (42,)
        mock_conn.cursor.return_value = mock_cur

        mock_pool = MagicMock()
        mock_pool.getconn.return_value = mock_conn

        with patch("pgmnemo_mcp.server.get_pool", return_value=mock_pool):
            result = server.ingest("test lesson", role="tester", topic="smoke")

        assert result["id"] == 42


class TestRecallUnit(unittest.TestCase):
    def _make_mock_pool(self):
        mock_conn = MagicMock()
        mock_cur = MagicMock()
        mock_cur.__enter__ = lambda s: s
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.description = [
            ("lesson_id",), ("role",), ("topic",),
            ("lesson_text",), ("importance",), ("created_at",),
        ]
        mock_cur.fetchall.return_value = [(1, "tester", "smoke", "a lesson", 3, "2026-01-01")]
        mock_conn.cursor.return_value = mock_cur
        mock_pool = MagicMock()
        mock_pool.getconn.return_value = mock_conn
        return mock_pool, mock_cur

    def test_recall_calls_db_fast_default(self):
        """Default recall (deep=False) calls recall_fast — v0.10.0."""
        from pgmnemo_mcp import server

        mock_pool, mock_cur = self._make_mock_pool()
        with patch("pgmnemo_mcp.server.get_pool", return_value=mock_pool):
            results = server.recall("test query", top_k=3)

        assert len(results) == 1
        assert results[0]["lesson_id"] == 1
        # Verify recall_fast was called (not recall_lessons or recall_hybrid)
        sql_called = mock_cur.execute.call_args[0][0]
        assert "recall_fast" in sql_called, f"expected recall_fast, got: {sql_called}"

    def test_recall_deep_calls_recall_hybrid(self):
        """deep=True routes to recall_hybrid — v0.10.0."""
        from pgmnemo_mcp import server

        mock_pool, mock_cur = self._make_mock_pool()
        with patch("pgmnemo_mcp.server.get_pool", return_value=mock_pool):
            results = server.recall("test query", top_k=3, deep=True)

        assert len(results) == 1
        sql_called = mock_cur.execute.call_args[0][0]
        assert "recall_hybrid" in sql_called, f"expected recall_hybrid, got: {sql_called}"

    def test_recall_exposes_filter_params(self):
        """recall() exposes role_filter, project_id_filter, exclude_dag_id — closes #81."""
        import inspect
        from pgmnemo_mcp import server

        sig = inspect.signature(server.recall)
        params = sig.parameters
        assert "role_filter" in params, "role_filter missing from recall() signature"
        assert "project_id_filter" in params, "project_id_filter missing from recall() signature"
        assert "exclude_dag_id" in params, "exclude_dag_id missing from recall() signature"
        assert "deep" in params, "deep param missing from recall() signature"
        # Defaults: filters=None, deep=False
        assert params["role_filter"].default is None
        assert params["project_id_filter"].default is None
        assert params["exclude_dag_id"].default is None
        assert params["deep"].default is False


class TestGetParams(unittest.TestCase):
    def test_get_params_returns_config(self):
        from pgmnemo_mcp import server

        result = server.get_params()
        assert "database_url" in result
        assert "version" in result
        assert result["version"] == "0.10.0"
        assert "embedding_dim" in result
        assert "mcp_port" in result

    def test_get_params_masks_password(self):
        from pgmnemo_mcp import server

        with patch("pgmnemo_mcp.server.DATABASE_URL", "postgresql://user:secretpass@localhost/pgmnemo"):
            result = server.get_params()
        assert "secretpass" not in result["database_url"]
        assert "***" in result["database_url"]


if __name__ == "__main__":
    unittest.main()
