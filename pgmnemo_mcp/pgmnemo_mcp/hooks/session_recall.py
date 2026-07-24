"""SessionStart / BeforeAgent / UserPromptSubmit hook.

Recalls top-K lessons from pgmnemo and prints them to stdout for
injection into the model context at session start or on each prompt.

Usage (invoked by CLI hook runner):
    python -m pgmnemo_mcp.hooks.session_recall [query_text...]

Stdin: optional query text (falls back to CLI args, then "session start").

Environment variables:
    CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR / GEMINI_PROJECT_DIR
        Project working directory (first non-empty wins, fallback ".").
    PGMNEMO_TOP_K       Number of lessons to recall (default: 5).
    PGMNEMO_ROLE        Role filter passed to recall (optional).
    PGMNEMO_DATABASE_URL
        Override the database URL used by the MCP server config.

Exit codes: 0 on success or when no DB is configured; 1 on recall error.
"""

from __future__ import annotations

import os
import sys


def _resolve_project_dir() -> str:
    return (
        os.environ.get("CLAUDE_PROJECT_DIR")
        or os.environ.get("CODEX_PROJECT_DIR")
        or os.environ.get("GEMINI_PROJECT_DIR")
        or "."
    )


def main() -> int:
    project_dir = _resolve_project_dir()  # noqa: F841 — available for future path ops

    # Query: prefer stdin, then CLI args, then generic fallback
    if not sys.stdin.isatty():
        query = sys.stdin.read().strip()
    else:
        query = " ".join(sys.argv[1:]).strip()

    if not query:
        query = "session start"

    top_k = int(os.environ.get("PGMNEMO_TOP_K", "5"))

    try:
        from pgmnemo_mcp.server import recall  # type: ignore[import]
    except ImportError as exc:
        print(f"[pgmnemo] recall unavailable: {exc}", file=sys.stderr)
        return 0  # non-fatal: missing DB config is normal in CI / fresh installs

    try:
        results = recall(query, top_k=top_k)
    except Exception as exc:  # pylint: disable=broad-except
        print(f"[pgmnemo] recall error: {exc}", file=sys.stderr)
        return 1

    if not results:
        print("[pgmnemo] no lessons recalled", file=sys.stderr)
        return 0

    for r in results:
        text = r.get("lesson_text") or r.get("text") or ""
        role = r.get("role", "")
        topic = r.get("topic", "")
        tag = f"{role}/{topic}" if role or topic else "memory"
        print(f"[MEMORY:{tag}] {text}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
