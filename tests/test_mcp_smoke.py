"""Smoke tests for pgmnemo_mcp — import and tool registration, no live DB required."""

import importlib
import unittest
from unittest.mock import MagicMock, patch


class TestImport(unittest.TestCase):
    def test_package_imports(self):
        import pgmnemo_mcp
        assert pgmnemo_mcp.__version__ == "0.1.0"

    def test_server_imports(self):
        from pgmnemo_mcp import server
        assert hasattr(server, "mcp")
        assert hasattr(server, "ingest")
        assert hasattr(server, "recall")


class TestToolsRegistered(unittest.TestCase):
    def test_tools_listed(self):
        from pgmnemo_mcp.server import mcp
        # FastMCP exposes registered tools via ._tool_manager or similar; check via list_tools
        # We verify tool names are present in the server's tool registry.
        tools = mcp._tool_manager.list_tools()
        names = [t.name for t in tools]
        assert "pgmnemo.ingest" in names, f"pgmnemo.ingest not found in {names}"
        assert "pgmnemo.recall" in names, f"pgmnemo.recall not found in {names}"


class TestIngestUnit(unittest.TestCase):
    def test_ingest_calls_db(self):
        from pgmnemo_mcp import server

        mock_conn = MagicMock()
        mock_cur = MagicMock()
        mock_cur.__enter__ = lambda s: s
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.fetchone.return_value = (42, "2026-01-01T00:00:00+00:00")
        mock_conn.cursor.return_value = mock_cur

        mock_pool = MagicMock()
        mock_pool.getconn.return_value = mock_conn

        with patch("pgmnemo_mcp.server.get_pool", return_value=mock_pool):
            result = server.ingest("test lesson", {"role": "tester", "topic": "smoke"})

        assert result["lesson_id"] == 42


class TestRecallUnit(unittest.TestCase):
    def test_recall_calls_db(self):
        from pgmnemo_mcp import server

        mock_conn = MagicMock()
        mock_cur = MagicMock()
        mock_cur.__enter__ = lambda s: s
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.description = [("lesson_id",), ("role",), ("topic",), ("lesson_text",), ("importance",), ("created_at",)]
        mock_cur.fetchall.return_value = [(1, "tester", "smoke", "a lesson", 3, "2026-01-01")]
        mock_conn.cursor.return_value = mock_cur

        mock_pool = MagicMock()
        mock_pool.getconn.return_value = mock_conn

        with patch("pgmnemo_mcp.server.get_pool", return_value=mock_pool):
            results = server.recall("test query", top_k=3)

        assert len(results) == 1
        assert results[0]["lesson_id"] == 1


if __name__ == "__main__":
    unittest.main()
