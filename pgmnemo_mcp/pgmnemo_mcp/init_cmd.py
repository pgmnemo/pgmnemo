"""pgmnemo init — one-command quickstart.

Detects which AI CLI is present (.claude/, .codex/, .gemini/ dirs or env vars),
then idempotently merges the pgmnemo MCP server entry into the CLI's config file.
Prints next-steps for DB seeding (CREATE EXTENSION pgmnemo; PGMNEMO_DATABASE_URL).

Usage::

    pgmnemo init                    # auto-detect CLI
    pgmnemo init --cli=claude       # force Claude Code
    pgmnemo init --cli=codex        # force Codex CLI
    pgmnemo init --cli=gemini       # force Gemini CLI
    pgmnemo init --dir=/my/project  # target a different directory
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path

__all__ = ["main", "detect_cli", "merge_mcp_config"]

SUPPORTED_CLIS = ["claude", "codex", "gemini"]

# The MCP server entry written into every CLI config file.
_MCP_SERVER_ENTRY: dict = {
    "command": "pgmnemo-mcp",
    "env": {
        "DATABASE_URL": "postgresql://user:pass@localhost/mydb",
    },
}


# ---------------------------------------------------------------------------
# CLI detection
# ---------------------------------------------------------------------------

def detect_cli(cwd: Path) -> str | None:
    """Return the name of the first AI CLI detected in *cwd*, or ``None``.

    Detection order:
    1. Presence of a CLI marker directory (``.claude/``, ``.codex/``, ``.gemini/``).
    2. Known environment variables set by each CLI / SDK.
    """
    markers = {
        "claude": cwd / ".claude",
        "codex": cwd / ".codex",
        "gemini": cwd / ".gemini",
    }
    for name, path in markers.items():
        if path.is_dir():
            return name

    # Env-var fallback: useful for CI / Docker environments with no project dir.
    if os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("CLAUDE_API_KEY"):
        return "claude"
    if os.environ.get("OPENAI_API_KEY"):
        return "codex"
    if os.environ.get("GEMINI_API_KEY") or os.environ.get("GOOGLE_API_KEY"):
        return "gemini"

    return None


# ---------------------------------------------------------------------------
# Config path resolution
# ---------------------------------------------------------------------------

def _config_path(cli: str, cwd: Path) -> Path:
    """Return the MCP config file path for *cli* relative to *cwd*."""
    if cli == "claude":
        # Claude Code project-scoped MCP config (shared with team via VCS).
        return cwd / ".mcp.json"
    if cli == "codex":
        return cwd / ".codex" / "mcp_servers.json"
    if cli == "gemini":
        return cwd / ".gemini" / "mcp_servers.json"
    raise ValueError(f"Unsupported CLI: {cli!r}")


# ---------------------------------------------------------------------------
# Idempotent config merge
# ---------------------------------------------------------------------------

def merge_mcp_config(config_path: Path, server_entry: dict | None = None) -> bool:
    """Merge the pgmnemo MCP server entry into *config_path*.

    - If ``pgmnemo`` key already exists under ``mcpServers``, does nothing.
    - Creates the file (and parent dirs) if absent.
    - Preserves all existing keys.

    Returns ``True`` if the file was written, ``False`` if no change was needed.
    """
    if server_entry is None:
        server_entry = _MCP_SERVER_ENTRY

    existing: dict = {}
    if config_path.exists():
        try:
            existing = json.loads(config_path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError):
            existing = {}

    mcp_servers: dict = existing.setdefault("mcpServers", {})

    if "pgmnemo" in mcp_servers:
        return False  # already configured — idempotent, no-op

    mcp_servers["pgmnemo"] = dict(server_entry)  # shallow copy
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(
        json.dumps(existing, indent=2) + "\n",
        encoding="utf-8",
    )
    return True


# ---------------------------------------------------------------------------
# Next-steps output
# ---------------------------------------------------------------------------

_SEED_STEPS = """\

Next steps to activate pgmnemo memory:

  1. Install the PostgreSQL extension (once per DB):
       psql -c "CREATE EXTENSION IF NOT EXISTS pgvector CASCADE;"
       psql -c "CREATE EXTENSION IF NOT EXISTS pgmnemo CASCADE;"

  2. Set DATABASE_URL in {config_path}:
       Edit the "DATABASE_URL" value under mcpServers > pgmnemo > env.
       Example: "postgresql://user:pass@localhost/mydb"

  3. Or export it in your shell before starting the CLI:
       export PGMNEMO_DATABASE_URL=postgresql://user:pass@localhost/mydb

  4. Restart your {cli_title} session — the pgmnemo MCP server loads automatically.

Docs: https://github.com/pgmnemo/pgmnemo/blob/main/INSTALL.md
"""


def _print_next_steps(cli: str, config_path: Path) -> None:
    print(f"\n[pgmnemo init] MCP server entry written to: {config_path}")
    print(
        _SEED_STEPS.format(
            config_path=config_path,
            cli_title=cli.title(),
        ).rstrip()
    )


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="pgmnemo",
        description=(
            "pgmnemo CLI — tools for managing provenance-gated agent memory in PostgreSQL."
        ),
    )
    sub = parser.add_subparsers(dest="command", metavar="<command>")

    init_p = sub.add_parser(
        "init",
        help="Configure pgmnemo MCP server for your AI CLI (Claude Code, Codex, Gemini).",
        description=(
            "Detect the AI CLI in use and write/merge the pgmnemo MCP server configuration "
            "idempotently.  Running 'pgmnemo init' a second time is safe — it only adds the "
            "'pgmnemo' key if it is not already present."
        ),
    )
    init_p.add_argument(
        "--cli",
        choices=SUPPORTED_CLIS,
        default=None,
        help=(
            "Force a specific CLI target.  "
            "Auto-detected from .claude/ / .codex/ / .gemini/ dirs or env vars when omitted."
        ),
    )
    init_p.add_argument(
        "--dir",
        default=".",
        metavar="PATH",
        help="Project directory to write config into (default: current directory).",
    )
    return parser


def main(argv: list[str] | None = None) -> None:
    """Entry point for the ``pgmnemo`` console script."""
    parser = _build_parser()
    args = parser.parse_args(argv)

    if args.command == "init":
        _run_init(args)
    else:
        parser.print_help()
        sys.exit(0)


def _run_init(args: argparse.Namespace) -> None:
    cwd = Path(args.dir).resolve()

    cli: str | None = args.cli or detect_cli(cwd)

    if cli is None:
        print(
            "[pgmnemo init] No AI CLI detected.\n"
            "Run from a project directory containing .claude/, .codex/, or .gemini/,\n"
            "or pass --cli=claude|codex|gemini to specify a target.",
            file=sys.stderr,
        )
        sys.exit(1)

    config_path = _config_path(cli, cwd)
    changed = merge_mcp_config(config_path)

    if changed:
        _print_next_steps(cli, config_path)
    else:
        print(
            f"[pgmnemo init] pgmnemo already configured in {config_path} — no changes made."
        )


if __name__ == "__main__":
    main()
