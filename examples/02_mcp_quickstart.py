"""
02_mcp_quickstart.py — pgmnemo minimal recall quickstart
=========================================================
Minimal, copy-paste script: ingest a lesson, recall it with
recall_hybrid(), navigate_locate() for token-budget recall, then
print results. No Docker required — just a running PG 17 + pgmnemo ≥ 0.9.0.

Covered APIs:
  • pgmnemo.ingest()          — provenance-gated write
  • pgmnemo.recall_hybrid()   — BM25+vector+confidence hybrid ranking
  • pgmnemo.navigate_locate() — budget-bounded LOCATE (token economy)

Connection: PGMNEMO_DSN env var, or PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE.

Install deps:
    pip install psycopg2-binary

Usage:
    export PGDATABASE=pgmnemo PGUSER=postgres PGPASSWORD=pgmnemo
    python examples/02_mcp_quickstart.py
"""

import sys
import os
import psycopg2
import psycopg2.extras

DSN = os.environ.get("PGMNEMO_DSN", "")

ROLE       = "quickstart_agent"
PROJECT_ID = 1
COMMIT_SHA = "quickstart000000000000000000000000000001"

LESSONS = [
    ("Use connection pooling (PgBouncer) to cap PG connection overhead at scale."),
    ("Index foreign keys — Postgres does not create them automatically."),
    ("VACUUM ANALYZE after bulk loads to keep planner statistics current."),
    ("Prefer BRIN indexes for append-only time-series tables over B-tree."),
    ("Set work_mem per session for sort-heavy queries, not globally."),
]

QUERY = "database index performance"


def connect():
    if DSN:
        return psycopg2.connect(DSN, cursor_factory=psycopg2.extras.RealDictCursor)
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", 5432)),
        dbname=os.environ.get("PGDATABASE", "pgmnemo"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "pgmnemo"),
        cursor_factory=psycopg2.extras.RealDictCursor,
    )


def section(n, title):
    print(f"\n{'='*60}")
    print(f"  [{n}] {title}")
    print(f"{'='*60}")


def main():
    print("pgmnemo quickstart — ingest → recall_hybrid → navigate_locate")

    conn = connect()
    conn.autocommit = False
    cur = conn.cursor()

    # Clean prior quickstart data
    cur.execute(
        "DELETE FROM pgmnemo.agent_lesson WHERE project_id=%s AND role=%s",
        (PROJECT_ID, ROLE),
    )

    # ── 1. Ingest ──────────────────────────────────────────────────────────────
    section(1, "Ingest 5 lessons via pgmnemo.ingest()")
    ids = []
    for text in LESSONS:
        cur.execute(
            """
            SELECT pgmnemo.ingest(
                p_role        := %s,
                p_project_id  := %s,
                p_topic       := 'postgres_perf',
                p_lesson_text := %s,
                p_importance  := 3,
                p_commit_sha  := %s
            )
            """,
            (ROLE, PROJECT_ID, text, COMMIT_SHA),
        )
        lid = cur.fetchone()["pgmnemo.ingest"]
        ids.append(lid)
        print(f"  ingested id={lid}  {text[:60]}")
    conn.commit()

    # ── 2. recall_hybrid ───────────────────────────────────────────────────────
    section(2, f"recall_hybrid(query_text='{QUERY}', k=5)")
    print(f"  Signals: BM25 (query_text) + recency + confidence (no embedding)\n")
    cur.execute(
        """
        SELECT lesson_id, score, confidence, match_confidence, lesson_text
        FROM pgmnemo.recall_hybrid(
            query_embedding   := NULL,
            query_text        := %s,
            k                 := 5,
            role_filter       := %s,
            project_id_filter := %s
        )
        ORDER BY score DESC
        """,
        (QUERY, ROLE, PROJECT_ID),
    )
    rows = cur.fetchall()
    if not rows:
        print("  (no results — BM25 tsvectors may need ANALYZE; rerun after ANALYZE pgmnemo.agent_lesson)")
    for rank, row in enumerate(rows, 1):
        print(
            f"  #{rank}  id={row['lesson_id']}  score={row['score']:.5f}"
            f"  conf={row['confidence']:.3f}"
            f"  match_conf={row['match_confidence']:.5f}"
        )
        print(f"       {row['lesson_text'][:72]}")

    # ── 3. navigate_locate ─────────────────────────────────────────────────────
    section(3, "navigate_locate(query_text, token_budget_chars=800)")
    print("  Budget-bounded LOCATE: returns previews that fit inside char budget.")
    print("  Use this for token-economy context assembly — load detail on demand.\n")
    cur.execute(
        """
        SELECT id, preview, score, tokens_consumed, navigation_path
        FROM pgmnemo.navigate_locate(
            query_embedding   := NULL,
            query_text        := %s,
            token_budget_chars := 800,
            project_id_filter := %s
        )
        ORDER BY score DESC
        """,
        (QUERY, PROJECT_ID),
    )
    nav_rows = cur.fetchall()
    if not nav_rows:
        print("  (no results)")
    for row in nav_rows:
        print(
            f"  id={row['id']}  score={row['score']:.5f}"
            f"  tokens_consumed={row['tokens_consumed']}"
        )
        print(f"    preview: {(row['preview'] or '')[:72]}")

    # ── Summary ────────────────────────────────────────────────────────────────
    print(f"\n{'─'*60}")
    print("  recall_hybrid  — fuses BM25 + vector + confidence + recency")
    print("  navigate_locate — same fusion, but stops when token budget exhausted")
    print("  Both functions are pure SQL — no sidecar process required.")
    print(f"{'─'*60}")
    print("\nQuickstart complete — exit 0")

    cur.close()
    conn.close()
    sys.exit(0)


if __name__ == "__main__":
    main()
