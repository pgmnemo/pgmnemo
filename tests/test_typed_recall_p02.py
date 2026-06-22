#!/usr/bin/env python3
"""
test_typed_recall_p02.py — Regression test for P0.2: p_content_types in recall_hybrid.
ADR-61 §3 D3 / pgmnemo v0.11.0

Runs on TEST DB (pgmnemo_regression), NEVER on prod_corpus.

Tests:
  T1  New 10-param signature present
  T2  backward compat: old 9-param API returns all rows in scope
  T3  p_content_types=NULL (explicit) == backward compat count
  T4  p_content_types=ARRAY['procedure'] — only procedure rows returned
  T5  p_content_types='{}' — zero rows (not silent all-types fallback)
  T6  p_content_types=ARRAY['procedure','fact'] — exactly matching types
  T7  Bit-identical: old API == new API with NULL (same lesson_ids, same scores, same order)
  T8  Index usage: typed recall result is subset of direct index scan on content_type

Usage:
  python3 tests/test_typed_recall_p02.py [--db-url postgresql://...]

If --db-url not given, defaults to connecting to postgres:5432 as execas.
"""

import sys
import os
import argparse
import psycopg2
import psycopg2.extras


# ─── connection helpers ───────────────────────────────────────────────────────

DEFAULT_ADMIN_URL = "postgresql://execas:B9WCqySTSIitkB0wAqHLpfYuwsKkBLFP@postgres:5432/prod_corpus"
TEST_DB_NAME = "pgmnemo_regression"

EXTENSION_DIR = os.path.join(os.path.dirname(__file__), "..", "extension")


def build_test_db_url(admin_url: str, db_name: str) -> str:
    """Swap the database name in an existing URL."""
    import urllib.parse as up
    u = up.urlparse(admin_url)
    return u._replace(path=f"/{db_name}").geturl()


def _load_sql(filename: str) -> str:
    path = os.path.join(EXTENSION_DIR, filename)
    with open(path) as f:
        return f.read()


# ─── test DB lifecycle ────────────────────────────────────────────────────────

def create_test_db(admin_url: str, db_name: str) -> None:
    """Create the test database (drops if exists). NEVER touches prod_corpus."""
    assert "prod_corpus" not in db_name, "Safety: refusing to create db with prod_corpus in name"
    conn = psycopg2.connect(admin_url)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(f"DROP DATABASE IF EXISTS {db_name}")
    cur.execute(f"CREATE DATABASE {db_name}")
    conn.close()
    print(f"[setup] Created test DB: {db_name}")


def drop_test_db(admin_url: str, db_name: str) -> None:
    conn = psycopg2.connect(admin_url)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute(f"DROP DATABASE IF EXISTS {db_name}")
    conn.close()
    print(f"[teardown] Dropped test DB: {db_name}")


def setup_extensions(db_url: str) -> None:
    """Install vector + pgmnemo 0.10.0 on the fresh test DB."""
    conn = psycopg2.connect(db_url)
    conn.autocommit = True
    cur = conn.cursor()

    # Install pgvector
    cur.execute("CREATE EXTENSION IF NOT EXISTS vector")

    # Install pgmnemo by running the flat 0.10.0 SQL directly.
    # (Requires the SQL file to have the \echo ... \quit guard replaced or skipped.)
    flat_sql = _load_sql("pgmnemo--0.10.0.sql")
    # Strip the \echo ... \quit guard — it's a psql metacommand, not valid SQL.
    # The guard is: \echo Use ... \quit
    lines = flat_sql.splitlines()
    filtered = [l for l in lines if not l.strip().startswith("\\echo") and l.strip() != "\\quit"]
    flat_sql_clean = "\n".join(filtered)

    # Create the pgmnemo schema
    cur.execute("CREATE SCHEMA IF NOT EXISTS pgmnemo")
    # Execute the flat install SQL
    cur.execute(flat_sql_clean)

    conn.close()
    print("[setup] Installed pgmnemo 0.10.0")


def apply_upgrade_migration(db_url: str, from_ver: str, to_ver: str) -> None:
    """Apply an upgrade migration SQL file (stripping psql metacommands)."""
    filename = f"pgmnemo--{from_ver}--{to_ver}.sql"
    sql = _load_sql(filename)
    lines = sql.splitlines()
    filtered = [l for l in lines if not l.strip().startswith("\\echo") and l.strip() != "\\quit"]
    migration_sql = "\n".join(filtered)

    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    cur = conn.cursor()
    try:
        cur.execute(migration_sql)
        conn.commit()
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()
    print(f"[setup] Applied migration {filename}")


# ─── test helpers ─────────────────────────────────────────────────────────────

class TestFailure(Exception):
    pass


PASSED = []
FAILED = []


def check(name: str, condition: bool, msg: str = "") -> None:
    if condition:
        print(f"  [PASS] {name}")
        PASSED.append(name)
    else:
        detail = f" — {msg}" if msg else ""
        print(f"  [FAIL] {name}{detail}")
        FAILED.append(name)


# ─── test data ────────────────────────────────────────────────────────────────

SETUP_SQL = """
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, commit_sha, content_type)
VALUES
    ('tc_p02', 'procedure alpha',   'procedure alpha beta gamma delta epsilon zeta eta theta iota', 'p02-sha-pa1', 'procedure'),
    ('tc_p02', 'procedure bravo',   'procedure alpha beta gamma delta epsilon zeta eta theta iota', 'p02-sha-pa2', 'procedure'),
    ('tc_p02', 'procedure charlie', 'procedure alpha beta gamma delta epsilon zeta eta theta iota', 'p02-sha-pa3', 'procedure'),
    ('tc_p02', 'fact alpha',        'fact alpha beta gamma delta epsilon zeta eta theta kappa',     'p02-sha-fa1', 'fact'),
    ('tc_p02', 'fact bravo',        'fact alpha beta gamma delta epsilon zeta eta theta kappa',     'p02-sha-fa2', 'fact'),
    ('tc_p02', 'entity alpha',      'entity alpha beta gamma delta epsilon zeta eta theta lambda',  'p02-sha-ea1', 'entity'),
    ('tc_p02', 'untyped alpha',     'untyped alpha beta gamma delta epsilon zeta eta theta mu',     'p02-sha-un1', NULL);
"""

CLEANUP_SQL = "DELETE FROM pgmnemo.agent_lesson WHERE role = 'tc_p02';"

QUERY_TEXT = "alpha beta gamma delta epsilon zeta eta theta"
ROLE = "tc_p02"


def run_recall(cur, p_content_types=None, k=20, use_old_api=False):
    """Call recall_hybrid and return list of (lesson_id, score) tuples."""
    if use_old_api:
        cur.execute("""
            SELECT lesson_id, score, vec_score, bm25_score, rrf_score
            FROM pgmnemo.recall_hybrid(
                NULL, %s,
                %s, %s
            )
            ORDER BY score DESC, lesson_id ASC
        """, (QUERY_TEXT, k, ROLE))
    else:
        cur.execute("""
            SELECT lesson_id, score, vec_score, bm25_score, rrf_score
            FROM pgmnemo.recall_hybrid(
                NULL, %s,
                %s, %s, NULL,
                0.4, 0.4, 60, NULL,
                %s
            )
            ORDER BY score DESC, lesson_id ASC
        """, (QUERY_TEXT, k, ROLE, p_content_types))
    return cur.fetchall()


def get_content_types(cur, lesson_ids):
    """Lookup content_type for a list of lesson_ids."""
    if not lesson_ids:
        return {}
    cur.execute(
        "SELECT id, content_type FROM pgmnemo.agent_lesson WHERE id = ANY(%s)",
        (list(lesson_ids),)
    )
    return {row[0]: row[1] for row in cur.fetchall()}


# ─── main test runner ─────────────────────────────────────────────────────────

def run_tests(db_url: str) -> None:
    conn = psycopg2.connect(db_url)
    conn.autocommit = False
    cur = conn.cursor()

    try:
        # Setup GUCs + test data
        cur.execute(SETUP_SQL)
        conn.commit()

        # ── T1: Signature check (10 params) ───────────────────────────────────
        print("\n[T1] Function signature: 10 parameters")
        cur.execute("""
            SELECT pronargs FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
            ORDER BY pronargs DESC LIMIT 1
        """)
        row = cur.fetchone()
        check("T1: has 10 params", row is not None and row[0] == 10,
              f"got pronargs={row[0] if row else 'none'}")

        # ── T2: Backward compat — old 9-param API ─────────────────────────────
        print("\n[T2] Backward compat: old API returns all 7 rows")
        old_rows = run_recall(cur, use_old_api=True)
        check("T2: old API row count == 7", len(old_rows) == 7,
              f"got {len(old_rows)}")

        # ── T3: p_content_types=NULL explicit == backward compat ──────────────
        print("\n[T3] p_content_types=NULL explicit — same count as old API")
        null_rows = run_recall(cur, p_content_types=None)
        check("T3: NULL param count == old API count", len(null_rows) == len(old_rows),
              f"null={len(null_rows)} old={len(old_rows)}")

        # ── T4: ARRAY['procedure'] — only procedure rows ───────────────────────
        print("\n[T4] p_content_types=ARRAY['procedure'] — 3 procedure rows only")
        proc_rows = run_recall(cur, p_content_types=['procedure'])
        check("T4a: procedure count == 3", len(proc_rows) == 3,
              f"got {len(proc_rows)}")
        proc_ids = [r[0] for r in proc_rows]
        content_types = get_content_types(cur, proc_ids)
        all_proc = all(v == 'procedure' for v in content_types.values())
        check("T4b: all returned rows are content_type='procedure'", all_proc,
              f"types: {set(content_types.values())}")

        # ── T5: ARRAY[] (empty) — zero rows ────────────────────────────────────
        print("\n[T5] p_content_types='{}' (empty array) — zero rows")
        empty_rows = run_recall(cur, p_content_types=[])
        check("T5: empty array → 0 rows", len(empty_rows) == 0,
              f"got {len(empty_rows)}")

        # ── T6: ARRAY['procedure','fact'] — 5 rows, right types ───────────────
        print("\n[T6] p_content_types=['procedure','fact'] — 5 rows (3+2)")
        pf_rows = run_recall(cur, p_content_types=['procedure', 'fact'])
        check("T6a: proc+fact count == 5", len(pf_rows) == 5,
              f"got {len(pf_rows)}")
        pf_ids = [r[0] for r in pf_rows]
        pf_types = get_content_types(cur, pf_ids)
        all_pf = all(v in ('procedure', 'fact') for v in pf_types.values())
        check("T6b: all rows in ['procedure','fact']", all_pf,
              f"types: {set(pf_types.values())}")

        # ── T7: Bit-identical: old API == new API with NULL ────────────────────
        print("\n[T7] Bit-identical: old API == new API with p_content_types=NULL")
        # Both already fetched: old_rows and null_rows
        old_ids_scores = [(r[0], r[1]) for r in old_rows]
        null_ids_scores = [(r[0], r[1]) for r in null_rows]
        check("T7a: same number of rows", len(old_ids_scores) == len(null_ids_scores),
              f"old={len(old_ids_scores)} new={len(null_ids_scores)}")
        old_ids = [r[0] for r in old_rows]
        null_ids = [r[0] for r in null_rows]
        check("T7b: same lesson_ids in same order", old_ids == null_ids,
              f"old={old_ids[:5]}... new={null_ids[:5]}...")
        # Score comparison (identical floats — same computation path)
        scores_match = all(
            abs(o[1] - n[1]) < 1e-12
            for o, n in zip(old_rows, null_rows)
        )
        check("T7c: scores bit-identical (delta < 1e-12)", scores_match)

        # ── T8: Index pushdown — typed result subset of direct indexed scan ────
        print("\n[T8] Index pushdown: typed recall ⊆ direct content_type index scan")
        # Direct query using the index predicate conditions (same as ix_pgmnemo_content_type_active)
        cur.execute("""
            SELECT al.id
            FROM pgmnemo.agent_lesson al
            WHERE al.is_active
              AND al.content_type = 'procedure'
              AND al.role = 'tc_p02'
              AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
        """)
        direct_ids = {row[0] for row in cur.fetchall()}
        recall_ids_set = set(proc_ids)
        check("T8a: direct index scan count == 3", len(direct_ids) == 3,
              f"got {len(direct_ids)}")
        check("T8b: typed recall ⊆ direct index scan", recall_ids_set <= direct_ids,
              f"recall={recall_ids_set} not subset of direct={direct_ids}")
        check("T8c: typed recall == direct index scan (all procedure rows found)",
              recall_ids_set == direct_ids,
              f"recall={recall_ids_set} direct={direct_ids}")

    finally:
        # Cleanup test data
        cur.execute(CLEANUP_SQL)
        conn.commit()
        conn.close()


def main():
    parser = argparse.ArgumentParser(description="P0.2 typed recall regression test")
    parser.add_argument("--admin-url", default=DEFAULT_ADMIN_URL,
                        help="Admin DB URL (NOT the test DB)")
    parser.add_argument("--no-create", action="store_true",
                        help="Skip test DB creation (DB already exists)")
    parser.add_argument("--no-destroy", action="store_true",
                        help="Skip test DB teardown after tests")
    parser.add_argument("--from-version", default="0.10.0",
                        help="Migration source version (default: 0.10.0)")
    args = parser.parse_args()

    admin_url = args.admin_url
    test_db_url = build_test_db_url(admin_url, TEST_DB_NAME)

    print(f"[info] Test DB: {TEST_DB_NAME} (NOT prod_corpus)")
    print(f"[info] Migration: {args.from_version} → 0.11.0")

    try:
        if not args.no_create:
            create_test_db(admin_url, TEST_DB_NAME)
            setup_extensions(test_db_url)
            apply_upgrade_migration(test_db_url, args.from_version, "0.11.0")

        run_tests(test_db_url)

    finally:
        if not args.no_destroy:
            drop_test_db(admin_url, TEST_DB_NAME)

    print(f"\n{'='*60}")
    print(f"Results: {len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        print(f"FAILED: {', '.join(FAILED)}")
        sys.exit(1)
    else:
        print("ALL TESTS PASSED")
        sys.exit(0)


if __name__ == "__main__":
    main()
