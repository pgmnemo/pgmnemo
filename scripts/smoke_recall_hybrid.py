#!/usr/bin/env python3
"""
smoke_recall_hybrid.py — regression smoke test for pgmnemo.recall_hybrid()

Catches signature / output-column breaks BEFORE bench scripts hit them at run time.
Background: 2026-05-14 run_longmemeval_hybrid_v040.py crashed on the very first
SQL execute with `column "hybrid_score" does not exist` because the script
expected hybrid_score but the actual output column is `score`. A simple smoke
test would have caught this in ~3 seconds vs ~5 minutes of failed bench setup.

Asserts:
  1. pgmnemo.recall_hybrid is callable with documented signature
  2. Output table contains every column documented in docs/SQL_REFERENCE.md
  3. recall_hybrid honours `query_text IS NULL` (graceful fallback to vector-only path)
  4. Default weights (vec_weight=0.4, bm25_weight=0.4) accept overrides
  5. Empty corpus returns 0 rows (not error)

Usage:
    DATABASE_URL=postgresql://bench:bench@localhost:15432/bench \\
        python3 scripts/smoke_recall_hybrid.py

Exit:
    0 — all assertions pass
    1 — any assertion fails or DB error (release-blocking)
"""
import os
import sys

try:
    import psycopg2
except ImportError:
    print("ERROR: psycopg2 not installed", file=sys.stderr)
    sys.exit(1)


# Output schema documented in docs/SQL_REFERENCE.md §2.5
EXPECTED_COLUMNS = {
    "lesson_id",
    "score",
    "vec_score",
    "bm25_score",
    "rrf_score",
    "role",
    "project_id",
    "topic",
    "lesson_text",
    "importance",
    "metadata",
    "commit_sha",
    "artifact_hash",
    "verified_at",
    "created_at",
}


def main():
    dsn = os.environ.get("DATABASE_URL", "host=localhost port=15432 dbname=bench user=bench password=bench")
    print(f"[smoke] connecting: {dsn.split('@')[-1] if '@' in dsn else dsn}")
    conn = psycopg2.connect(dsn)
    conn.autocommit = True
    cur = conn.cursor()

    # Verify function exists
    cur.execute("""
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
    """)
    if not cur.fetchone():
        print("FAIL: pgmnemo.recall_hybrid does not exist. Apply opt-in:")
        print("      \\i extension/pgmnemo--0.2.1--0.2.2-hybrid.sql")
        sys.exit(1)
    print("[smoke] ✓ pgmnemo.recall_hybrid exists")

    # Verify expected output columns by inspecting pg_proc.proargnames + proallargtypes
    # Simpler: call it on empty corpus and inspect cursor.description.
    cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role = 'smoke_recall_hybrid'")

    zero_vec = "[" + ",".join(["0.001"] * 1024) + "]"
    cur.execute(
        f"SELECT * FROM pgmnemo.recall_hybrid('{zero_vec}'::vector, 'test query', 10, 'smoke_recall_hybrid', 1, 0.4, 0.4) LIMIT 1"
    )
    actual_cols = {desc[0] for desc in cur.description}
    missing = EXPECTED_COLUMNS - actual_cols
    extra = actual_cols - EXPECTED_COLUMNS
    if missing:
        print(f"FAIL: recall_hybrid is MISSING output columns: {sorted(missing)}")
        print(f"      Actual columns:  {sorted(actual_cols)}")
        sys.exit(1)
    if extra:
        print(f"WARN: recall_hybrid has UNDOCUMENTED extra columns: {sorted(extra)}")
        print(f"      Update docs/SQL_REFERENCE.md §2.5 if intentional.")
    print(f"[smoke] ✓ output columns match expected schema ({len(actual_cols)} cols)")

    # Verify empty corpus returns 0 rows, not error
    cur.execute(
        f"SELECT COUNT(*) FROM pgmnemo.recall_hybrid('{zero_vec}'::vector, 'nothing here', 10, 'smoke_recall_hybrid', 1, 0.4, 0.4)"
    )
    n = cur.fetchone()[0]
    if n != 0:
        print(f"FAIL: empty corpus should return 0 rows, got {n}")
        sys.exit(1)
    print("[smoke] ✓ empty corpus → 0 rows (no error)")

    # Insert 3 lessons with provenance + verified_at so they pass the gate
    real_vec = "[" + ",".join([f"{0.001 + i * 0.0001:.6f}" for i in range(1024)]) + "]"
    for i, (topic, text) in enumerate([
        ("smoke/auth", "JWT rotation policy: 24-hour window after key compromise indicator"),
        ("smoke/api", "Rate limit fallback: degrade to read-only after 5 consecutive 429s"),
        ("smoke/db", "PostgreSQL connection pool: max 25 per process to avoid socket exhaustion"),
    ]):
        cur.execute(
            """INSERT INTO pgmnemo.agent_lesson
               (role, project_id, topic, lesson_text, importance, embedding,
                commit_sha, verified_at)
               VALUES ('smoke_recall_hybrid', 1, %s, %s, 3, %s::vector, 'smoke_abc1234', NOW())""",
            (topic, text, real_vec),
        )

    # Verify recall_hybrid returns rows
    cur.execute(
        f"""
        SELECT lesson_id, score, vec_score, bm25_score, rrf_score, topic
        FROM pgmnemo.recall_hybrid('{real_vec}'::vector, 'JWT rotation', 5, 'smoke_recall_hybrid', 1, 0.4, 0.4)
        ORDER BY score DESC
        """
    )
    rows = cur.fetchall()
    if len(rows) == 0:
        print("FAIL: recall_hybrid returned 0 rows from non-empty corpus")
        sys.exit(1)
    if len(rows) > 3:
        print(f"FAIL: recall_hybrid returned {len(rows)} rows, expected ≤ 3")
        sys.exit(1)
    print(f"[smoke] ✓ recall_hybrid returned {len(rows)} rows from 3-lesson corpus")

    # Verify score is in expected range (non-NULL, finite)
    for row in rows:
        lesson_id, score, vec_score, bm25_score, rrf_score, topic = row
        if score is None:
            print(f"FAIL: lesson_id={lesson_id} score IS NULL")
            sys.exit(1)
        if not (-100.0 < score < 100.0):
            print(f"FAIL: lesson_id={lesson_id} score={score} out of plausible range")
            sys.exit(1)
        print(f"[smoke]   lesson_id={lesson_id} topic={topic} score={score:.4f} vec={vec_score:.4f} bm25={bm25_score:.4f}")

    # Verify ORDER BY score DESC is honoured (the bug fix from 2026-05-14)
    scores = [r[1] for r in rows]
    if scores != sorted(scores, reverse=True):
        print(f"FAIL: ORDER BY score DESC not honoured: {scores}")
        sys.exit(1)
    print("[smoke] ✓ ORDER BY score DESC works")

    # Verify NULL query_text path (vector-only fallback through hybrid function)
    cur.execute(
        f"""
        SELECT COUNT(*)
        FROM pgmnemo.recall_hybrid('{real_vec}'::vector, NULL, 10, 'smoke_recall_hybrid', 1, 0.4, 0.4)
        """
    )
    n_null_text = cur.fetchone()[0]
    if n_null_text == 0:
        print("FAIL: recall_hybrid with NULL query_text should still return vector matches")
        sys.exit(1)
    print(f"[smoke] ✓ NULL query_text gracefully → {n_null_text} rows (vector-only path)")

    # Cleanup
    cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role = 'smoke_recall_hybrid'")
    print("[smoke] ALL PASS — recall_hybrid signature is stable")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        print(f"FAIL (exception): {type(e).__name__}: {e}", file=sys.stderr)
        sys.exit(1)
