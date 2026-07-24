"""Smoke tests for pgmnemo cross-model hook packs (OM-2).

Asserts:
1. All three shared hook scripts exist inside pgmnemo_mcp.hooks.
2. All three per-CLI config files exist in integrations/.
3. Every config references the same canonical script commands
   (python -m pgmnemo_mcp.hooks.session_recall / session_capture / session_backup).
4. The hook __init__ module exposes the HOOK_SCRIPTS tuple.
5. session_backup writes a backup file when given stdin-like text.
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

# Repo root — tests/ lives one level below the repo root
REPO_ROOT = Path(__file__).parent.parent

# pgmnemo_mcp package root
MCP_PKG_ROOT = REPO_ROOT / "pgmnemo_mcp" / "pgmnemo_mcp"
HOOKS_DIR = MCP_PKG_ROOT / "hooks"

# Per-CLI config template paths
CLAUDE_CONFIG = REPO_ROOT / "integrations" / "claude" / "settings.json"
CODEX_CONFIG = REPO_ROOT / "integrations" / "codex" / "hooks.json"
GEMINI_CONFIG = REPO_ROOT / "integrations" / "gemini" / "settings.json"

# The three canonical module paths that every config must reference
EXPECTED_COMMANDS = {
    "python -m pgmnemo_mcp.hooks.session_recall",
    "python -m pgmnemo_mcp.hooks.session_capture",
    "python -m pgmnemo_mcp.hooks.session_backup",
}


def _collect_commands(obj) -> set[str]:
    """Recursively collect all 'command' string values from a JSON structure."""
    found: set[str] = set()
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k == "command" and isinstance(v, str):
                found.add(v)
            else:
                found |= _collect_commands(v)
    elif isinstance(obj, list):
        for item in obj:
            found |= _collect_commands(item)
    return found


class TestHookScriptsExist(unittest.TestCase):
    """Shared hook scripts must all be present on disk."""

    def test_hooks_dir_exists(self):
        self.assertTrue(HOOKS_DIR.is_dir(), f"hooks/ dir missing: {HOOKS_DIR}")

    def test_init_module_exists(self):
        self.assertTrue((HOOKS_DIR / "__init__.py").is_file())

    def test_session_recall_exists(self):
        self.assertTrue((HOOKS_DIR / "session_recall.py").is_file())

    def test_session_capture_exists(self):
        self.assertTrue((HOOKS_DIR / "session_capture.py").is_file())

    def test_session_backup_exists(self):
        self.assertTrue((HOOKS_DIR / "session_backup.py").is_file())


class TestHookInitExports(unittest.TestCase):
    """__init__ must expose HOOK_SCRIPTS tuple with the three names."""

    def test_hook_scripts_tuple(self):
        # Add pgmnemo_mcp package to path if needed (unit test context)
        pkg_parent = str(REPO_ROOT / "pgmnemo_mcp")
        if pkg_parent not in sys.path:
            sys.path.insert(0, pkg_parent)

        from pgmnemo_mcp.hooks import HOOK_SCRIPTS  # type: ignore[import]
        self.assertIn("session_recall", HOOK_SCRIPTS)
        self.assertIn("session_capture", HOOK_SCRIPTS)
        self.assertIn("session_backup", HOOK_SCRIPTS)


class TestCliConfigsExist(unittest.TestCase):
    """All three per-CLI config templates must be present on disk."""

    def test_claude_config_exists(self):
        self.assertTrue(CLAUDE_CONFIG.is_file(), f"Missing: {CLAUDE_CONFIG}")

    def test_codex_config_exists(self):
        self.assertTrue(CODEX_CONFIG.is_file(), f"Missing: {CODEX_CONFIG}")

    def test_gemini_config_exists(self):
        self.assertTrue(GEMINI_CONFIG.is_file(), f"Missing: {GEMINI_CONFIG}")


class TestCliConfigsReferenceSharedScripts(unittest.TestCase):
    """Every per-CLI config must reference the same shared hook scripts."""

    def _load(self, path: Path) -> dict:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)

    def _assert_contains_commands(self, config_path: Path, required: set[str]) -> None:
        data = self._load(config_path)
        found = _collect_commands(data)
        for cmd in required:
            self.assertIn(
                cmd,
                found,
                f"{config_path.name} missing command '{cmd}'. Found: {found}",
            )

    def test_claude_references_recall(self):
        self._assert_contains_commands(
            CLAUDE_CONFIG, {"python -m pgmnemo_mcp.hooks.session_recall"}
        )

    def test_claude_references_capture(self):
        self._assert_contains_commands(
            CLAUDE_CONFIG, {"python -m pgmnemo_mcp.hooks.session_capture"}
        )

    def test_claude_references_backup(self):
        self._assert_contains_commands(
            CLAUDE_CONFIG, {"python -m pgmnemo_mcp.hooks.session_backup"}
        )

    def test_codex_references_recall(self):
        self._assert_contains_commands(
            CODEX_CONFIG, {"python -m pgmnemo_mcp.hooks.session_recall"}
        )

    def test_codex_references_capture(self):
        self._assert_contains_commands(
            CODEX_CONFIG, {"python -m pgmnemo_mcp.hooks.session_capture"}
        )

    def test_codex_does_not_have_precompact(self):
        """Codex has no PreCompact event — backup must not be in SessionStart/Stop events."""
        data = self._load(CODEX_CONFIG)
        hooks_section = data.get("hooks", {})
        # session_backup may appear but should not be mapped to PreCompact (key absent)
        self.assertNotIn(
            "PreCompact",
            hooks_section,
            "Codex config must not define PreCompact (unsupported event)",
        )

    def test_gemini_references_recall(self):
        self._assert_contains_commands(
            GEMINI_CONFIG, {"python -m pgmnemo_mcp.hooks.session_recall"}
        )

    def test_gemini_references_capture(self):
        self._assert_contains_commands(
            GEMINI_CONFIG, {"python -m pgmnemo_mcp.hooks.session_capture"}
        )

    def test_gemini_references_backup(self):
        self._assert_contains_commands(
            GEMINI_CONFIG, {"python -m pgmnemo_mcp.hooks.session_backup"}
        )

    def test_gemini_uses_ms_timeouts(self):
        """Gemini config must use timeoutMs (milliseconds), not timeout (seconds)."""
        data = self._load(GEMINI_CONFIG)
        found_ms = False

        def _walk(obj):
            nonlocal found_ms
            if isinstance(obj, dict):
                if "timeoutMs" in obj:
                    found_ms = True
                for v in obj.values():
                    _walk(v)
            elif isinstance(obj, list):
                for item in obj:
                    _walk(item)

        _walk(data)
        self.assertTrue(found_ms, "Gemini config must use 'timeoutMs' keys")

    def test_all_three_configs_use_same_script_prefix(self):
        """All commands across all three configs share the same module prefix."""
        all_cmds: set[str] = set()
        for path in (CLAUDE_CONFIG, CODEX_CONFIG, GEMINI_CONFIG):
            all_cmds |= _collect_commands(self._load(path))

        hook_cmds = {c for c in all_cmds if c.startswith("python -m pgmnemo_mcp.hooks.")}
        self.assertEqual(
            hook_cmds,
            EXPECTED_COMMANDS,
            f"Expected exactly {EXPECTED_COMMANDS}, got {hook_cmds}",
        )


class TestSessionBackupUnit(unittest.TestCase):
    """session_backup.py writes a file when stdin data is provided."""

    def test_backup_writes_file(self):
        import tempfile

        pkg_parent = str(REPO_ROOT / "pgmnemo_mcp")
        if pkg_parent not in sys.path:
            sys.path.insert(0, pkg_parent)

        from pgmnemo_mcp.hooks import session_backup  # type: ignore[import]

        with tempfile.TemporaryDirectory() as tmp:
            payload = '{"session": "test", "note": "smoke"}'

            # Patch stdin and env
            import io
            fake_stdin = io.StringIO(payload)
            with patch.dict(os.environ, {"PGMNEMO_BACKUP_DIR": tmp}), \
                 patch("sys.stdin", fake_stdin), \
                 patch("sys.stdin.isatty", return_value=False):
                rc = session_backup.main()

            self.assertEqual(rc, 0)
            backups = list(Path(tmp).glob("transcript_*.json"))
            self.assertEqual(len(backups), 1, f"Expected 1 backup file, got {backups}")
            content = backups[0].read_text(encoding="utf-8")
            self.assertIn("smoke", content)


if __name__ == "__main__":
    unittest.main()
