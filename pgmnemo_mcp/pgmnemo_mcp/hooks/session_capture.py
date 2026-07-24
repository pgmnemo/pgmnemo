"""Stop / SessionEnd hook.

Ingests a short session outcome into pgmnemo so that key decisions,
bugs found, and lessons are persisted across sessions.

Usage (invoked by CLI hook runner):
    python -m pgmnemo_mcp.hooks.session_capture [outcome_text...]

Stdin: session outcome text (preferred). CLI args used as fallback.
If neither source provides text, the hook exits silently (exit 0).

Environment variables:
    CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR / GEMINI_PROJECT_DIR
        Project working directory (first non-empty wins, fallback ".").
    PGMNEMO_ROLE        Role label stored with the lesson (default: hook_agent).
    PGMNEMO_TOPIC       Topic label (default: session_outcome).
    PGMNEMO_IMPORTANCE  Importance 1-5 (default: 3).
    PGMNEMO_DATABASE_URL
        Override the database URL used by the MCP server config.

Exit codes: 0 always (capture is best-effort; ingest errors are logged).
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
    _resolve_project_dir()  # available for future path ops

    # Outcome text: prefer stdin, then CLI args
    if not sys.stdin.isatty():
        outcome = sys.stdin.read().strip()
    else:
        outcome = " ".join(sys.argv[1:]).strip()

    if not outcome:
        # Nothing to capture — exit silently
        return 0

    role = os.environ.get("PGMNEMO_ROLE", "hook_agent")
    topic = os.environ.get("PGMNEMO_TOPIC", "session_outcome")
    importance = int(os.environ.get("PGMNEMO_IMPORTANCE", "3"))

    try:
        from pgmnemo_mcp.server import ingest  # type: ignore[import]
    except ImportError as exc:
        print(f"[pgmnemo] ingest unavailable: {exc}", file=sys.stderr)
        return 0  # non-fatal

    try:
        result = ingest(
            text=outcome,
            role=role,
            topic=topic,
            importance=importance,
        )
        lesson_id = result.get("id", "?")
        print(f"[MEMORY] Captured session outcome: lesson id={lesson_id}")
    except Exception as exc:  # pylint: disable=broad-except
        print(f"[pgmnemo] ingest error: {exc}", file=sys.stderr)
        # Best-effort — do not propagate; hook failure must not block CLI stop

    return 0


if __name__ == "__main__":
    sys.exit(main())
