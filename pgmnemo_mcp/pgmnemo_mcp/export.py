"""pgmnemo export — dump corpus to human-readable markdown.

Usage (CLI):
    pgmnemo export [--output FILE] [--db DATABASE_URL]

Output format:
    One top-level section per content_type (item_kind).
    Each lesson rendered as a fenced block with YAML frontmatter:
        - id, state, created_at, role, topic, importance

Read-only: no writes to the database.
"""

from __future__ import annotations

import sys
from datetime import datetime
from typing import Iterator


_QUERY = """
SELECT
    al.id,
    al.role,
    al.project_id,
    al.topic,
    al.lesson_text,
    al.importance,
    al.item_kind,
    al.created_at,
    COALESCE(st.state, 'active') AS state
FROM pgmnemo.agent_lesson al
LEFT JOIN LATERAL (
    SELECT state
    FROM pgmnemo.agent_lesson_state_transition
    WHERE lesson_id = al.id
    ORDER BY transitioned_at DESC
    LIMIT 1
) st ON true
ORDER BY al.item_kind, al.created_at
"""


def _connect(db_url: str):
    """Return a psycopg2 connection (caller closes it)."""
    import psycopg2  # type: ignore[import]
    return psycopg2.connect(db_url)


def fetch_lessons(db_url: str) -> list[dict]:
    """Return all lessons ordered by item_kind, created_at."""
    conn = _connect(db_url)
    try:
        with conn.cursor() as cur:
            cur.execute(_QUERY)
            cols = [d[0] for d in cur.description]
            return [dict(zip(cols, row)) for row in cur.fetchall()]
    finally:
        conn.close()


def _fmt_ts(ts) -> str:
    if ts is None:
        return "unknown"
    if isinstance(ts, datetime):
        return ts.strftime("%Y-%m-%dT%H:%M:%SZ")
    return str(ts)


def _section_heading(kind: str) -> str:
    label = kind.replace("_", " ").title() if kind else "Uncategorized"
    return f"## {label}\n"


def _lesson_block(row: dict) -> str:
    """Render one lesson as a markdown block with YAML-style frontmatter."""
    lines: list[str] = []
    lines.append("---")
    lines.append(f"id: {row['id']}")
    lines.append(f"state: {row['state']}")
    lines.append(f"created_at: {_fmt_ts(row['created_at'])}")
    lines.append(f"role: {row['role']}")
    lines.append(f"topic: {row['topic']}")
    lines.append(f"importance: {row['importance']}")
    if row.get("project_id") is not None:
        lines.append(f"project_id: {row['project_id']}")
    lines.append("---")
    lines.append("")
    lines.append(row["lesson_text"] or "")
    lines.append("")
    return "\n".join(lines)


def render_markdown(lessons: list[dict]) -> str:
    """Convert list of lesson rows to grouped markdown string."""
    lines: list[str] = []
    lines.append("# pgmnemo Corpus Export\n")

    # Group by item_kind
    from collections import defaultdict
    groups: dict[str, list[dict]] = defaultdict(list)
    for row in lessons:
        kind = row.get("item_kind") or "note"
        groups[kind].append(row)

    for kind in sorted(groups):
        lines.append(_section_heading(kind))
        for row in groups[kind]:
            lines.append(_lesson_block(row))
        lines.append("")

    return "\n".join(lines)


def export_corpus(db_url: str, output_path: str | None = None) -> str:
    """Fetch corpus and write markdown. Returns rendered markdown string."""
    lessons = fetch_lessons(db_url)
    md = render_markdown(lessons)

    if output_path:
        with open(output_path, "w", encoding="utf-8") as fh:
            fh.write(md)
        print(f"pgmnemo export: wrote {len(lessons)} lessons → {output_path}", file=sys.stderr)
    else:
        sys.stdout.write(md)

    return md


def main_export(argv: list[str] | None = None) -> None:
    """Entry point for `pgmnemo export` subcommand."""
    import argparse
    from .config import DATABASE_URL

    parser = argparse.ArgumentParser(
        prog="pgmnemo export",
        description="Export pgmnemo corpus to human-readable markdown.",
    )
    parser.add_argument(
        "--output", "-o",
        metavar="FILE",
        default=None,
        help="Write output to FILE instead of stdout.",
    )
    parser.add_argument(
        "--db",
        metavar="DATABASE_URL",
        default=None,
        help="PostgreSQL connection string (defaults to $DATABASE_URL).",
    )
    args = parser.parse_args(argv)

    db_url = args.db or DATABASE_URL
    export_corpus(db_url, args.output)
