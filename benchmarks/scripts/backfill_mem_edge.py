#!/usr/bin/env python3
"""
backfill_mem_edge.py — populate causal + temporal edges in pgmnemo.mem_edge
from production history.

Causal edges:
  For every group of lessons sharing the same source_run_id, link them in
  chronological order with relation_type='CAUSED_BY' (earlier → later).
  Also honours metadata->>'depends_on_run_id': if a lesson's source_run_id
  matches a depends_on_run_id recorded in another lesson's metadata, those
  are linked across run boundaries.

Temporal edges:
  Lessons sharing the same metadata->>'session_id' whose created_at timestamps
  fall within a 30-minute sliding window get relation_type='CO_TEMPORAL'.
  Only forward pairs (earlier → later) to keep the graph directed and avoid
  duplicate pairs.

Usage:
    python benchmarks/scripts/backfill_mem_edge.py \
        --dsn "postgresql://user:pass@localhost/mydb" \
        [--dry-run] [--batch-size 1000] [--window-minutes 30]

Exit codes:
    0  success
    1  DB connection error
    2  fewer than expected edges inserted (threshold check failed)
"""

import argparse
import sys
import time
from datetime import timedelta

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("ERROR: psycopg2 not installed. pip install psycopg2-binary", file=sys.stderr)
    sys.exit(1)


INSERT_EDGE_SQL = """
INSERT INTO pgmnemo.mem_edge
    (source_id, target_id, relation_type, weight, metadata)
VALUES
    (%s, %s, %s, %s, %s)
ON CONFLICT (source_id, target_id, relation_type, valid_from) DO NOTHING
RETURNING id
"""

FETCH_CAUSAL_SAME_RUN_SQL = """
SELECT id, source_run_id, created_at
FROM pgmnemo.agent_lesson
WHERE source_run_id IS NOT NULL
  AND is_active = TRUE
ORDER BY source_run_id, created_at
"""

FETCH_CROSS_RUN_SQL = """
SELECT
    al_dep.id   AS source_lesson_id,
    al_cur.id   AS target_lesson_id
FROM pgmnemo.agent_lesson al_cur
JOIN pgmnemo.agent_lesson al_dep
    ON al_dep.source_run_id = al_cur.metadata->>'depends_on_run_id'
WHERE al_cur.metadata ? 'depends_on_run_id'
  AND al_cur.is_active = TRUE
  AND al_dep.is_active = TRUE
  AND al_dep.id <> al_cur.id
"""

FETCH_TEMPORAL_SQL = """
SELECT id, created_at, metadata->>'session_id' AS session_id
FROM pgmnemo.agent_lesson
WHERE metadata ? 'session_id'
  AND is_active = TRUE
ORDER BY metadata->>'session_id', created_at
"""

COUNT_EDGES_SQL = "SELECT COUNT(*) FROM pgmnemo.mem_edge"


def build_causal_pairs_same_run(rows):
    """Chain lessons within same source_run_id chronologically."""
    pairs = []
    prev_run = None
    prev_id = None
    for row in rows:
        lesson_id, run_id, _ = row["id"], row["source_run_id"], row["created_at"]
        if run_id == prev_run and prev_id is not None:
            pairs.append((prev_id, lesson_id))
        prev_run = run_id
        prev_id = lesson_id
    return pairs


def build_temporal_pairs(rows, window_minutes=30):
    """Within each session_id, pair lessons within window_minutes of each other."""
    pairs = []
    window = timedelta(minutes=window_minutes)
    # Group by session_id
    sessions: dict[str, list] = {}
    for row in rows:
        sid = row["session_id"]
        sessions.setdefault(sid, []).append(row)

    for sid, lessons in sessions.items():
        lessons.sort(key=lambda r: r["created_at"])
        for i, a in enumerate(lessons):
            for b in lessons[i + 1:]:
                delta = b["created_at"] - a["created_at"]
                if delta <= window:
                    pairs.append((a["id"], b["id"]))
                else:
                    break  # sorted, no further pair in window
    return pairs


def insert_edges(cur, pairs, relation_type, dry_run, batch_size):
    inserted = 0
    batch = []
    for src, tgt in pairs:
        batch.append((src, tgt, relation_type, 1.0, '{"backfill": true}'))
        if len(batch) >= batch_size:
            if not dry_run:
                psycopg2.extras.execute_batch(cur, INSERT_EDGE_SQL, batch)
                inserted += cur.rowcount
            else:
                inserted += len(batch)
            batch = []
    if batch:
        if not dry_run:
            psycopg2.extras.execute_batch(cur, INSERT_EDGE_SQL, batch)
            inserted += cur.rowcount
        else:
            inserted += len(batch)
    return inserted


def main():
    parser = argparse.ArgumentParser(description="Backfill pgmnemo.mem_edge edges")
    parser.add_argument("--dsn", required=True, help="PostgreSQL DSN")
    parser.add_argument("--dry-run", action="store_true",
                        help="Compute edges but do not write to DB")
    parser.add_argument("--batch-size", type=int, default=1000)
    parser.add_argument("--window-minutes", type=int, default=30,
                        help="Temporal co-occurrence window in minutes")
    parser.add_argument("--min-edges", type=int, default=0,
                        help="Minimum new edges required; exit 2 if not met")
    args = parser.parse_args()

    try:
        conn = psycopg2.connect(args.dsn)
        conn.autocommit = False
    except Exception as e:
        print(f"ERROR: cannot connect: {e}", file=sys.stderr)
        sys.exit(1)

    cur = conn.cursor(cursor_factory=psycopg2.extras.DictCursor)

    t0 = time.perf_counter()

    # ── Causal: same source_run_id chain ─────────────────────────────────────
    cur.execute(FETCH_CAUSAL_SAME_RUN_SQL)
    same_run_rows = cur.fetchall()
    causal_pairs = build_causal_pairs_same_run(same_run_rows)

    # ── Causal: cross-run depends_on linkage ─────────────────────────────────
    cur.execute(FETCH_CROSS_RUN_SQL)
    cross_run_rows = cur.fetchall()
    cross_pairs = [(r["source_lesson_id"], r["target_lesson_id"])
                   for r in cross_run_rows]

    all_causal = causal_pairs + cross_pairs

    # ── Temporal: co-session 30-min window ───────────────────────────────────
    cur.execute(FETCH_TEMPORAL_SQL)
    temporal_rows = cur.fetchall()
    temporal_pairs = build_temporal_pairs(temporal_rows, args.window_minutes)

    print(f"Causal pairs (same run): {len(causal_pairs)}")
    print(f"Causal pairs (cross run): {len(cross_pairs)}")
    print(f"Temporal pairs: {len(temporal_pairs)}")

    # ── Insert ────────────────────────────────────────────────────────────────
    n_causal = insert_edges(cur, all_causal, "CAUSED_BY",
                            args.dry_run, args.batch_size)
    n_temporal = insert_edges(cur, temporal_pairs, "CO_TEMPORAL",
                              args.dry_run, args.batch_size)

    if not args.dry_run:
        conn.commit()

    elapsed = time.perf_counter() - t0

    # ── Row count after backfill ──────────────────────────────────────────────
    if not args.dry_run:
        cur.execute(COUNT_EDGES_SQL)
        total_edges = cur.fetchone()[0]
    else:
        total_edges = n_causal + n_temporal

    print(f"\nBackfill complete in {elapsed:.2f}s")
    print(f"  CAUSED_BY  inserted: {n_causal}")
    print(f"  CO_TEMPORAL inserted: {n_temporal}")
    print(f"  Total mem_edge rows : {total_edges}")

    conn.close()

    if args.min_edges and total_edges < args.min_edges:
        print(f"ERROR: only {total_edges} edges total, threshold={args.min_edges}",
              file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
