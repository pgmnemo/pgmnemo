"""Smoke tests for pgmnemo export command — no live DB required."""

from __future__ import annotations

import sys
import os
import unittest
from datetime import datetime
from unittest.mock import MagicMock, patch

# Ensure pgmnemo_mcp package is importable from tests/
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


SEEDED_ROWS = [
    {
        "id": 1,
        "role": "technical_lead",
        "project_id": 1,
        "topic": "db-pattern",
        "lesson_text": "When using psycopg2 in threads, always use connection pools.",
        "importance": 4,
        "item_kind": "note",
        "created_at": datetime(2026, 1, 15, 10, 0, 0),
        "state": "active",
    },
    {
        "id": 2,
        "role": "software_developer",
        "project_id": 1,
        "topic": "testing",
        "lesson_text": "Mock psycopg2 connections in unit tests to avoid Docker dependency.",
        "importance": 3,
        "item_kind": "skill_md",
        "created_at": datetime(2026, 2, 1, 9, 0, 0),
        "state": "active",
    },
    {
        "id": 3,
        "role": "technical_lead",
        "project_id": 2,
        "topic": "architecture",
        "lesson_text": "Prefer DBOS workflows for exactly-once delivery guarantees.",
        "importance": 5,
        "item_kind": "note",
        "created_at": datetime(2026, 3, 10, 8, 30, 0),
        "state": "deprecated",
    },
]


class TestRenderMarkdown(unittest.TestCase):
    """Unit tests for render_markdown() — pure function, no DB."""

    def setUp(self):
        from pgmnemo_mcp.export import render_markdown
        self.render_markdown = render_markdown

    def test_title_present(self):
        md = self.render_markdown(SEEDED_ROWS)
        self.assertIn("# pgmnemo Corpus Export", md)

    def test_section_per_content_type(self):
        md = self.render_markdown(SEEDED_ROWS)
        # Two distinct item_kinds: note and skill_md
        self.assertIn("## Note", md)
        self.assertIn("## Skill Md", md)

    def test_frontmatter_id(self):
        md = self.render_markdown(SEEDED_ROWS)
        self.assertIn("id: 1", md)
        self.assertIn("id: 2", md)
        self.assertIn("id: 3", md)

    def test_frontmatter_state(self):
        md = self.render_markdown(SEEDED_ROWS)
        self.assertIn("state: active", md)
        self.assertIn("state: deprecated", md)

    def test_frontmatter_created_at(self):
        md = self.render_markdown(SEEDED_ROWS)
        self.assertIn("created_at: 2026-01-15T10:00:00Z", md)

    def test_lesson_text_present(self):
        md = self.render_markdown(SEEDED_ROWS)
        self.assertIn("always use connection pools", md)
        self.assertIn("exactly-once delivery guarantees", md)

    def test_empty_corpus(self):
        md = self.render_markdown([])
        self.assertIn("# pgmnemo Corpus Export", md)


class TestFetchLessons(unittest.TestCase):
    """Unit tests for fetch_lessons() — DB call mocked."""

    def _make_mock_conn(self, rows, cols):
        mock_cur = MagicMock()
        mock_cur.__enter__ = lambda s: s
        mock_cur.__exit__ = MagicMock(return_value=False)
        mock_cur.description = [(c,) for c in cols]
        mock_cur.fetchall.return_value = rows
        mock_conn = MagicMock()
        mock_conn.cursor.return_value = mock_cur
        return mock_conn, mock_cur

    def test_fetch_returns_dicts(self):
        from pgmnemo_mcp.export import fetch_lessons

        cols = ["id", "role", "project_id", "topic", "lesson_text",
                "importance", "item_kind", "created_at", "state"]
        raw_row = (1, "tl", 1, "topic", "text", 3, "note",
                   datetime(2026, 1, 1), "active")
        mock_conn, _ = self._make_mock_conn([raw_row], cols)

        with patch("pgmnemo_mcp.export._connect", return_value=mock_conn):
            result = fetch_lessons("postgresql://localhost/pgmnemo")

        self.assertEqual(len(result), 1)
        self.assertEqual(result[0]["id"], 1)
        self.assertEqual(result[0]["lesson_text"], "text")
        self.assertEqual(result[0]["state"], "active")


class TestExportCorpus(unittest.TestCase):
    """Integration-style test for export_corpus() — mocks fetch_lessons."""

    def test_export_corpus_writes_stdout(self):
        from pgmnemo_mcp.export import export_corpus
        import io

        with patch("pgmnemo_mcp.export.fetch_lessons", return_value=SEEDED_ROWS):
            with patch("sys.stdout", new_callable=io.StringIO) as mock_stdout:
                export_corpus("postgresql://localhost/pgmnemo", output_path=None)
                output = mock_stdout.getvalue()

        self.assertIn("## Note", output)
        self.assertIn("## Skill Md", output)
        self.assertIn("id: 1", output)

    def test_export_corpus_writes_file(self):
        import tempfile
        from pgmnemo_mcp.export import export_corpus

        with tempfile.NamedTemporaryFile(mode="r", suffix=".md", delete=False) as tf:
            path = tf.name

        try:
            with patch("pgmnemo_mcp.export.fetch_lessons", return_value=SEEDED_ROWS):
                export_corpus("postgresql://localhost/pgmnemo", output_path=path)

            with open(path, encoding="utf-8") as fh:
                content = fh.read()

            self.assertIn("# pgmnemo Corpus Export", content)
            self.assertIn("## Note", content)
            self.assertIn("always use connection pools", content)
        finally:
            os.unlink(path)


class TestMainExportCLI(unittest.TestCase):
    """Test main_export() CLI entry point."""

    def test_help_exits_zero(self):
        from pgmnemo_mcp.export import main_export
        with self.assertRaises(SystemExit) as ctx:
            main_export(["--help"])
        self.assertEqual(ctx.exception.code, 0)

    def test_export_stdout_via_cli(self):
        import io
        from pgmnemo_mcp.export import main_export

        with patch("pgmnemo_mcp.export.fetch_lessons", return_value=SEEDED_ROWS):
            with patch("pgmnemo_mcp.config.DATABASE_URL", "postgresql://localhost/test"):
                with patch("sys.stdout", new_callable=io.StringIO) as mock_stdout:
                    main_export([])
                    output = mock_stdout.getvalue()

        self.assertIn("# pgmnemo Corpus Export", output)
        self.assertIn("## Note", output)


if __name__ == "__main__":
    unittest.main()
