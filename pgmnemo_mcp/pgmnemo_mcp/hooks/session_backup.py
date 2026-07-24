"""PreCompact / PreCompress hook.

Backs up the current session transcript before the CLI compresses or
truncates context.  The transcript payload arrives via stdin (JSON string
as provided by the CLI hook runner).  On success the backup path is printed
to stdout.

Usage (invoked by CLI hook runner):
    python -m pgmnemo_mcp.hooks.session_backup

Stdin: JSON transcript payload from the CLI (any format; stored verbatim).
       Falls back to a timestamped placeholder when stdin is empty/TTY.

Environment variables:
    CLAUDE_PROJECT_DIR / CODEX_PROJECT_DIR / GEMINI_PROJECT_DIR
        Project working directory (first non-empty wins, fallback ".").
    PGMNEMO_BACKUP_DIR  Override backup directory (default: <project>/.pgmnemo_backups).

Exit codes: 0 on success; 1 if the backup file cannot be written.
"""

from __future__ import annotations

import datetime
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
    project_dir = _resolve_project_dir()

    # Transcript payload: prefer stdin, else use placeholder
    if not sys.stdin.isatty():
        payload = sys.stdin.read()
    else:
        payload = ""

    ts = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")

    if not payload.strip():
        payload = f'{{"timestamp": "{ts}", "note": "no transcript data provided by hook runner"}}'

    backup_dir = os.environ.get(
        "PGMNEMO_BACKUP_DIR",
        os.path.join(project_dir, ".pgmnemo_backups"),
    )

    try:
        os.makedirs(backup_dir, exist_ok=True)
        backup_path = os.path.join(backup_dir, f"transcript_{ts}.json")
        with open(backup_path, "w", encoding="utf-8") as fh:
            fh.write(payload)
        print(f"[MEMORY] Transcript backed up to {backup_path}")
    except OSError as exc:
        print(f"[pgmnemo] backup failed: {exc}", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
