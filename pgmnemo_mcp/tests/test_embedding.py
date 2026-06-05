"""Unit tests for pgmnemo_mcp.config embedding helpers (v0.8.2).

Loads config.py standalone (no live embedding server, PostgreSQL, or `mcp` pkg).
"""
from __future__ import annotations

import importlib.util
import os
import pathlib
import unittest

_CFG_PATH = pathlib.Path(__file__).resolve().parents[1] / "pgmnemo_mcp" / "config.py"


def _load_config():
    spec = importlib.util.spec_from_file_location("_pgmnemo_cfg", _CFG_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


class TestToPgvector(unittest.TestCase):
    def setUp(self):
        self.cfg = _load_config()

    def test_format(self):
        self.assertEqual(self.cfg.to_pgvector([1.0, 2.0, 3.0]), "[1.0,2.0,3.0]")

    def test_none_and_empty(self):
        self.assertIsNone(self.cfg.to_pgvector(None))
        self.assertIsNone(self.cfg.to_pgvector([]))


class TestEmbed(unittest.TestCase):
    def test_unset_server_returns_none(self):
        os.environ.pop("EMBEDDING_SERVER", None)
        cfg = _load_config()
        self.assertEqual(cfg.EMBEDDING_SERVER, "")
        self.assertIsNone(cfg.embed("hello"))  # no server → text-only fallback

    def test_empty_text_returns_none(self):
        self.assertIsNone(_load_config().embed(""))

    def test_dim_default(self):
        self.assertEqual(_load_config().EMBEDDING_DIM, 1024)


if __name__ == "__main__":
    unittest.main()
