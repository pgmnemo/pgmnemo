"""Smoke tests for pgmnemo_mcp.init_cmd.

All tests run without a live database — no psycopg2 pool, no filesystem side-effects
beyond a temporary directory.
"""
from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

from pgmnemo_mcp.init_cmd import (
    SUPPORTED_CLIS,
    _MCP_SERVER_ENTRY,
    _config_path,
    detect_cli,
    main,
    merge_mcp_config,
)


# ---------------------------------------------------------------------------
# detect_cli
# ---------------------------------------------------------------------------

class TestDetectCli(unittest.TestCase):

    def _tmpdir(self) -> tuple[tempfile.TemporaryDirectory, Path]:
        td = tempfile.TemporaryDirectory()
        return td, Path(td.name)

    def test_detects_claude_dir(self):
        with tempfile.TemporaryDirectory() as d:
            cwd = Path(d)
            (cwd / ".claude").mkdir()
            self.assertEqual(detect_cli(cwd), "claude")

    def test_detects_codex_dir(self):
        with tempfile.TemporaryDirectory() as d:
            cwd = Path(d)
            (cwd / ".codex").mkdir()
            self.assertEqual(detect_cli(cwd), "codex")

    def test_detects_gemini_dir(self):
        with tempfile.TemporaryDirectory() as d:
            cwd = Path(d)
            (cwd / ".gemini").mkdir()
            self.assertEqual(detect_cli(cwd), "gemini")

    def test_returns_none_when_nothing_present(self):
        with tempfile.TemporaryDirectory() as d:
            env_clean = {k: v for k, v in os.environ.items()
                         if k not in {"ANTHROPIC_API_KEY", "CLAUDE_API_KEY",
                                      "OPENAI_API_KEY", "GEMINI_API_KEY",
                                      "GOOGLE_API_KEY"}}
            with patch.dict(os.environ, env_clean, clear=True):
                self.assertIsNone(detect_cli(Path(d)))

    def test_env_fallback_anthropic(self):
        with tempfile.TemporaryDirectory() as d:
            with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"}, clear=False):
                self.assertEqual(detect_cli(Path(d)), "claude")

    def test_env_fallback_openai(self):
        with tempfile.TemporaryDirectory() as d:
            # Ensure no dir markers exist and no anthropic key overrides
            env = {k: v for k, v in os.environ.items()
                   if k not in {"ANTHROPIC_API_KEY", "CLAUDE_API_KEY"}}
            env["OPENAI_API_KEY"] = "sk-openai-test"
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(detect_cli(Path(d)), "codex")

    def test_env_fallback_gemini(self):
        with tempfile.TemporaryDirectory() as d:
            env = {k: v for k, v in os.environ.items()
                   if k not in {"ANTHROPIC_API_KEY", "CLAUDE_API_KEY", "OPENAI_API_KEY"}}
            env["GEMINI_API_KEY"] = "gemini-test"
            with patch.dict(os.environ, env, clear=True):
                self.assertEqual(detect_cli(Path(d)), "gemini")

    def test_dir_takes_priority_over_env(self):
        """Directory marker beats env-var fallback."""
        with tempfile.TemporaryDirectory() as d:
            cwd = Path(d)
            (cwd / ".codex").mkdir()
            with patch.dict(os.environ, {"ANTHROPIC_API_KEY": "sk-test"}):
                # .codex/ dir wins even though ANTHROPIC env is set
                self.assertEqual(detect_cli(cwd), "codex")


# ---------------------------------------------------------------------------
# _config_path
# ---------------------------------------------------------------------------

class TestConfigPath(unittest.TestCase):

    def test_claude_path(self):
        p = _config_path("claude", Path("/project"))
        self.assertEqual(p, Path("/project/.mcp.json"))

    def test_codex_path(self):
        p = _config_path("codex", Path("/project"))
        self.assertEqual(p, Path("/project/.codex/mcp_servers.json"))

    def test_gemini_path(self):
        p = _config_path("gemini", Path("/project"))
        self.assertEqual(p, Path("/project/.gemini/mcp_servers.json"))

    def test_unsupported_raises(self):
        with self.assertRaises(ValueError):
            _config_path("chatgpt", Path("/project"))


# ---------------------------------------------------------------------------
# merge_mcp_config — idempotency
# ---------------------------------------------------------------------------

class TestMergeMcpConfig(unittest.TestCase):

    def test_creates_new_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "subdir" / ".mcp.json"
            changed = merge_mcp_config(p)
            self.assertTrue(changed)
            self.assertTrue(p.exists())
            data = json.loads(p.read_text())
            self.assertIn("pgmnemo", data["mcpServers"])

    def test_written_config_contains_pgmnemo_mcp_command(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".mcp.json"
            merge_mcp_config(p)
            data = json.loads(p.read_text())
            entry = data["mcpServers"]["pgmnemo"]
            self.assertEqual(entry["command"], "pgmnemo-mcp")

    def test_idempotent_no_change_on_second_call(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".mcp.json"
            first = merge_mcp_config(p)
            second = merge_mcp_config(p)
            self.assertTrue(first)
            self.assertFalse(second)  # no-op on second call

    def test_idempotent_file_content_unchanged(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".mcp.json"
            merge_mcp_config(p)
            content_after_first = p.read_text()
            merge_mcp_config(p)
            content_after_second = p.read_text()
            self.assertEqual(content_after_first, content_after_second)

    def test_preserves_existing_keys(self):
        """Existing mcpServers entries must not be removed."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".mcp.json"
            existing = {"mcpServers": {"other-tool": {"command": "other-mcp"}}}
            p.write_text(json.dumps(existing))
            merge_mcp_config(p)
            data = json.loads(p.read_text())
            self.assertIn("other-tool", data["mcpServers"])
            self.assertIn("pgmnemo", data["mcpServers"])

    def test_does_not_overwrite_existing_pgmnemo_entry(self):
        """Custom pgmnemo config must survive a merge call."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".mcp.json"
            custom_entry = {"command": "my-custom-pgmnemo-mcp", "env": {"DATABASE_URL": "custom"}}
            existing = {"mcpServers": {"pgmnemo": custom_entry}}
            p.write_text(json.dumps(existing))
            changed = merge_mcp_config(p)
            self.assertFalse(changed)
            data = json.loads(p.read_text())
            self.assertEqual(data["mcpServers"]["pgmnemo"]["command"], "my-custom-pgmnemo-mcp")

    def test_creates_parent_dirs(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / "a" / "b" / "c" / "mcp_servers.json"
            merge_mcp_config(p)
            self.assertTrue(p.exists())

    def test_handles_invalid_json_gracefully(self):
        """Corrupt existing file is treated as empty — pgmnemo entry written."""
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".mcp.json"
            p.write_text("NOT VALID JSON")
            changed = merge_mcp_config(p)
            self.assertTrue(changed)
            data = json.loads(p.read_text())
            self.assertIn("pgmnemo", data["mcpServers"])


# ---------------------------------------------------------------------------
# main() — --help exits 0 and shows help text
# ---------------------------------------------------------------------------

class TestMainHelp(unittest.TestCase):

    def test_pgmnemo_init_help_exits_zero(self):
        """pgmnemo init --help must exit 0 (not 2 / exception)."""
        with self.assertRaises(SystemExit) as cm:
            main(["init", "--help"])
        self.assertEqual(cm.exception.code, 0)

    def test_pgmnemo_help_exits_zero(self):
        """pgmnemo --help / pgmnemo (no args) must exit 0."""
        with self.assertRaises(SystemExit) as cm:
            main([])
        self.assertEqual(cm.exception.code, 0)

    def test_init_help_mentions_cli_option(self):
        """--help output must mention --cli."""
        import io
        buf = io.StringIO()
        with patch("sys.stdout", buf):
            with self.assertRaises(SystemExit):
                main(["init", "--help"])
        self.assertIn("--cli", buf.getvalue())

    def test_init_help_mentions_supported_clis(self):
        """--help output must list all supported CLI names."""
        import io
        buf = io.StringIO()
        with patch("sys.stdout", buf):
            with self.assertRaises(SystemExit):
                main(["init", "--help"])
        output = buf.getvalue()
        for cli in SUPPORTED_CLIS:
            self.assertIn(cli, output)


# ---------------------------------------------------------------------------
# main() -- init subcommand end-to-end (filesystem)
# ---------------------------------------------------------------------------

class TestMainInit(unittest.TestCase):

    def test_init_with_cli_flag_writes_config(self):
        with tempfile.TemporaryDirectory() as d:
            main(["init", "--cli=claude", f"--dir={d}"])
            config = Path(d) / ".mcp.json"
            self.assertTrue(config.exists())
            data = json.loads(config.read_text())
            self.assertIn("pgmnemo", data["mcpServers"])

    def test_init_idempotent_via_main(self):
        with tempfile.TemporaryDirectory() as d:
            main(["init", "--cli=claude", f"--dir={d}"])
            content_first = (Path(d) / ".mcp.json").read_text()
            main(["init", "--cli=claude", f"--dir={d}"])
            content_second = (Path(d) / ".mcp.json").read_text()
            self.assertEqual(content_first, content_second)

    def test_init_detects_claude_dir(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".claude").mkdir()
            main(["init", f"--dir={d}"])
            config = Path(d) / ".mcp.json"
            self.assertTrue(config.exists())

    def test_init_detects_codex_dir(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".codex").mkdir()
            main(["init", f"--dir={d}"])
            config = Path(d) / ".codex" / "mcp_servers.json"
            self.assertTrue(config.exists())

    def test_init_detects_gemini_dir(self):
        with tempfile.TemporaryDirectory() as d:
            (Path(d) / ".gemini").mkdir()
            main(["init", f"--dir={d}"])
            config = Path(d) / ".gemini" / "mcp_servers.json"
            self.assertTrue(config.exists())

    def test_init_no_cli_no_dir_exits_nonzero(self):
        """No detectable CLI and no --cli flag → exit(1)."""
        with tempfile.TemporaryDirectory() as d:
            env_clean = {k: v for k, v in os.environ.items()
                         if k not in {"ANTHROPIC_API_KEY", "CLAUDE_API_KEY",
                                      "OPENAI_API_KEY", "GEMINI_API_KEY",
                                      "GOOGLE_API_KEY"}}
            with patch.dict(os.environ, env_clean, clear=True):
                with self.assertRaises(SystemExit) as cm:
                    main(["init", f"--dir={d}"])
            self.assertNotEqual(cm.exception.code, 0)

    def test_init_codex_writes_correct_path(self):
        with tempfile.TemporaryDirectory() as d:
            main(["init", "--cli=codex", f"--dir={d}"])
            config = Path(d) / ".codex" / "mcp_servers.json"
            self.assertTrue(config.exists())
            data = json.loads(config.read_text())
            self.assertIn("pgmnemo", data["mcpServers"])

    def test_init_gemini_writes_correct_path(self):
        with tempfile.TemporaryDirectory() as d:
            main(["init", "--cli=gemini", f"--dir={d}"])
            config = Path(d) / ".gemini" / "mcp_servers.json"
            self.assertTrue(config.exists())
            data = json.loads(config.read_text())
            self.assertIn("pgmnemo", data["mcpServers"])


if __name__ == "__main__":
    unittest.main()
