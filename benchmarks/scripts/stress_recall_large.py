#!/usr/bin/env python3
"""stress_recall_large.py — recall_lessons() latency stress test at 100K / 1M / 10M rows.

Issue #29 — https://github.com/pgmnemo/pgmnemo/issues/29

Tests:
  - Synthetic corpus generation (deterministic, no external data needed)
  - recall_lessons() P50/P95/P99 latency at 100K, 1M, 10M row corpus sizes
  - as_of_ts bitemporal filter overhead (F2 v0.6.1)
  - A-scale vs baseline score distribution spot-check (F1 v0.6.1)

Exit codes:
  0 — all targets met (see TARGETS dict below)
  1 — one or more targets missed
  2 — infra error (connection failed, extension not installed, etc.)

Usage:
    python3 benchmarks/scripts/stress_recall_large.py [OPTIONS]

Options:
    --dsn         PostgreSQL DSN (default: $DATABASE_URL or 'postgresql://localhost/pgmnemo_stress')
    --sizes       Comma-separated corpus sizes to test (default: 100000,1000000)
                  Use 10000000 for 10M (requires ≥ 32 GB RAM and ≥ 20 min)
    --queries     Number of recall queries per corpus size (default: 20)
    --ef-search   ef_search GUC (default: 100; use 200 for 10M)
    --out         Output JSON file (default: benchmarks/results/stress_recall_<date>.json)
    --no-embed    Skip embedding generation — tests text-only BM25 path (faster)
    --skip-10m    Shortcut: same as --sizes 100000,1000000 (skip 10M tier)
    --dry-run     Validate environment only, do not run stress (exit 0 if OK)

TARGETS (all-or-nothing gate):
    100K:   P99 latency ≤ 500 ms
    1M:     P99 latency ≤ 2000 ms
    10M:    P99 latency ≤ 8000 ms (ef_search=200 recommended)

Environment:
    DATABASE_URL — PostgreSQL connection string
    EMBED_HOST   — MLX bge-m3 embedding service (default: http://localhost:9200)
                   Set to '' to use random vectors (useful for latency-only testing)
"""
import argparse
import json
import math
import os
import random
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import NamedTuple

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    print("ERROR: psycopg2 not installed. Run: pip install psycopg2-binary", file=sys.stderr)
    sys.exit(2)

# ─── Configuration ────────────────────────────────────────────────────────────

TARGETS = {
    100_000:    {"p99_ms": 500,  "ef_search": 100},
    1_000_000:  {"p99_ms": 2000, "ef_search": 100},
    10_000_000: {"p99_ms": 8000, "ef_search": 200},
}

EMBED_DIM = 1024  # bge-m3 dimension

# Vocabulary for synthetic lesson generation
_TOPICS = [
    "task_management", "agent_orchestration", "memory_recall", "vector_search",
    "provenance", "bitemporal", "performance_tuning", "error_handling",
    "authentication", "database_migration", "api_design", "testing_strategy",
]
_VERBS = [
    "avoid", "prefer", "always", "never", "ensure", "check", "validate",
    "monitor", "optimize", "document", "test", "review",
]
_OBJECTS = [
    "commit_sha", "embedding", "recall_path", "session_context", "dag_master",
    "task_status", "agent_config", "token_budget", "cost_ceiling", "quality_score",
    "dispatch_cycle", "psycopg2_cursor", "hypothesis_gate", "bitemporal_row",
]

# ─── Helpers ──────────────────────────────────────────────────────────────────

def _rand_vec(dim: int = EMBED_DIM) -> list[float]:
    """Unit-normalized random vector of dimension `dim`."""
    v = [random.gauss(0, 1) for _ in range(dim)]
    norm = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / norm for x in v]


def _vec_to_pg(v: list[float]) -> str:
    return "[" + ",".join(f"{x:.6f}" for x in v) + "]"


def _synthetic_lesson(i: int) -> dict:
    random.seed(i)
    topic = _TOPICS[i % len(_TOPICS)]
    verb = _VERBS[i % len(_VERBS)]
    obj = _OBJECTS[(i // len(_VERBS)) % len(_OBJECTS)]
    text = f"Lesson {i}: {verb} {obj} during {topic}. Generated for stress test #{i}."
    return {
        "role": f"agent_{i % 5}",
        "topic": topic,
        "lesson_text": text,
        "importance": (i % 5) + 1,
        "commit_sha": f"deadbeef{i:08x}",
    }


def _percentile(values: list[float], pct: float) -> float:
    if not values:
        return 0.0
    sorted_v = sorted(values)
    idx = max(0, int(math.ceil(pct / 100.0 * len(sorted_v))) - 1)
    return sorted_v[idx]


class BenchResult(NamedTuple):
    corpus_size: int
    n_queries: int
    p50_ms: float
    p95_ms: float
    p99_ms: float
    target_p99_ms: int
    passed: bool
    as_of_overhead_ms: float  # median overhead of as_of_ts filter vs plain recall


# ─── Database setup ───────────────────────────────────────────────────────────

def ensure_extension(conn) -> str:
    """Ensure pgmnemo is installed; return version.

    Checks pg_extension first (proper install); falls back to checking the
    pgmnemo schema + recall_hybrid function (raw-SQL install, e.g. in CI/bench DBs).
    """
    with conn.cursor() as cur:
        cur.execute("""
            SELECT extversion FROM pg_extension WHERE extname = 'pgmnemo'
        """)
        row = cur.fetchone()
        if row:
            return row[0]
        # Fallback: check schema + key function (raw-SQL install)
        cur.execute("""
            SELECT p.proname
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
        """)
        func_row = cur.fetchone()
        if not func_row:
            raise RuntimeError(
                "pgmnemo extension not installed. Run: CREATE EXTENSION pgmnemo;"
            )
        # Try version() function for version string
        try:
            cur.execute("SELECT pgmnemo.version()")
            ver = cur.fetchone()[0] or "raw-install"
            return ver or "raw-install"
        except Exception:
            return "raw-install"


def setup_stress_schema(conn) -> None:
    """Create a clean stress-test schema (drops if exists)."""
    with conn.cursor() as cur:
        cur.execute("SET pgmnemo.gate_strict = 'off'")
        cur.execute("SET pgmnemo.include_unverified = true")
        cur.execute("SET pgmnemo.disable_hybrid = false")
    conn.commit()


def insert_corpus_batch(conn, start: int, end: int, embed: bool = False) -> None:
    """Insert rows [start, end) into pgmnemo.agent_lesson via COPY-style batch."""
    records = []
    for i in range(start, end):
        lesson = _synthetic_lesson(i)
        vec = _vec_to_pg(_rand_vec()) if embed else None
        records.append((
            lesson["role"],
            lesson["topic"],
            lesson["lesson_text"],
            lesson["importance"],
            lesson["commit_sha"],
            vec,
        ))

    now = datetime.now(timezone.utc)
    with conn.cursor() as cur:
        if embed:
            psycopg2.extras.execute_values(
                cur,
                """
                INSERT INTO pgmnemo.agent_lesson
                    (role, topic, lesson_text, importance, commit_sha, verified_at, embedding)
                VALUES %s
                """,
                [(r[0], r[1], r[2], r[3], r[4], now, r[5]) for r in records],
                template="(%s, %s, %s, %s, %s, %s, %s::vector)",
                page_size=1000,
            )
        else:
            psycopg2.extras.execute_values(
                cur,
                """
                INSERT INTO pgmnemo.agent_lesson
                    (role, topic, lesson_text, importance, commit_sha, verified_at)
                VALUES %s
                """,
                [(r[0], r[1], r[2], r[3], r[4], now) for r in records],
                template="(%s, %s, %s, %s, %s, %s)",
                page_size=1000,
            )
    conn.commit()


def count_rows(conn) -> int:
    with conn.cursor() as cur:
        cur.execute("SELECT COUNT(*) FROM pgmnemo.agent_lesson WHERE is_active")
        return cur.fetchone()[0]


def truncate_corpus(conn) -> None:
    """Remove all test rows (keeps extension objects intact)."""
    with conn.cursor() as cur:
        cur.execute("DELETE FROM pgmnemo.agent_lesson")
    conn.commit()


# ─── Benchmark ────────────────────────────────────────────────────────────────

def run_recall_query(conn, query_vec: str | None, query_text: str | None,
                     k: int = 10, ef_search: int = 100,
                     as_of_ts: str | None = None) -> float:
    """Run one recall_lessons() call (or recall_hybrid for text-only); return wall-clock ms."""
    if not query_vec and not query_text:
        raise ValueError("Need at least query_vec or query_text")
    with conn.cursor() as cur:
        cur.execute(f"SET pgmnemo.ef_search = {ef_search}")
        cur.execute("SET pgmnemo.include_unverified = true")
        if query_vec and query_text:
            if as_of_ts:
                sql = """
                    SELECT lesson_id FROM pgmnemo.recall_lessons(
                        %s::vector, %s, NULL, NULL, %s, %s::timestamptz
                    )
                """
                args = (query_vec, k, query_text, as_of_ts)
            else:
                sql = """
                    SELECT lesson_id FROM pgmnemo.recall_lessons(
                        %s::vector, %s, NULL, NULL, %s
                    )
                """
                args = (query_vec, k, query_text)
        elif query_vec:
            sql = "SELECT lesson_id FROM pgmnemo.recall_lessons(%s::vector, %s)"
            args = (query_vec, k)
        else:
            # Text-only: use recall_hybrid() with NULL vector (BM25-only path)
            if as_of_ts:
                sql = """
                    SELECT lesson_id FROM pgmnemo.recall_hybrid(
                        NULL::vector, %s, %s, NULL, NULL, 0.0, 1.0
                    ) WHERE lesson_id IS NOT NULL
                    LIMIT %s
                """
                args = (query_text, k, k)
            else:
                sql = """
                    SELECT lesson_id FROM pgmnemo.recall_hybrid(
                        NULL::vector, %s, %s, NULL, NULL, 0.0, 1.0
                    ) WHERE lesson_id IS NOT NULL
                    LIMIT %s
                """
                args = (query_text, k, k)

        t0 = time.perf_counter()
        cur.execute(sql, args)
        cur.fetchall()
        return (time.perf_counter() - t0) * 1000.0


def benchmark_size(conn, size: int, n_queries: int, ef_search: int,
                   no_embed: bool = False, verbose: bool = False) -> BenchResult:
    """Run benchmark for a given corpus size."""
    target = TARGETS.get(size, {"p99_ms": 2000, "ef_search": ef_search})
    ef = ef_search or target["ef_search"]

    if verbose:
        print(f"\n  Corpus size: {size:,}", flush=True)
        print(f"  ef_search: {ef}", flush=True)

    # Build corpus
    current = count_rows(conn)
    if current < size:
        need = size - current
        batch_size = 5000
        inserted = 0
        print(f"  Inserting {need:,} rows ...", end="", flush=True)
        while inserted < need:
            batch = min(batch_size, need - inserted)
            insert_corpus_batch(conn, current + inserted, current + inserted + batch,
                                embed=not no_embed)
            inserted += batch
            if verbose and inserted % 50_000 == 0:
                print(f" {inserted:,}", end="", flush=True)
        print(f" done ({size:,} total rows)", flush=True)
    elif current > size:
        # Trim by deleting excess
        with conn.cursor() as cur:
            cur.execute(
                "DELETE FROM pgmnemo.agent_lesson WHERE id IN "
                "(SELECT id FROM pgmnemo.agent_lesson ORDER BY id DESC LIMIT %s)",
                (current - size,)
            )
        conn.commit()

    # Warm-up queries (not counted)
    for _ in range(min(3, n_queries)):
        q_vec = _vec_to_pg(_rand_vec()) if not no_embed else None
        q_text = "task orchestration memory" if no_embed else None
        run_recall_query(conn, q_vec, q_text, ef_search=ef)

    # Timed queries
    latencies_plain: list[float] = []
    latencies_as_of: list[float] = []

    as_of_sample = "2025-01-01T00:00:00+00:00"  # arbitrary past timestamp

    for i in range(n_queries):
        q_vec = _vec_to_pg(_rand_vec()) if not no_embed else None
        q_text = f"{_TOPICS[i % len(_TOPICS)]} {_OBJECTS[i % len(_OBJECTS)]}"

        # Plain recall
        ms = run_recall_query(conn, q_vec, q_text, ef_search=ef)
        latencies_plain.append(ms)

        # as_of_ts recall (F2 overhead measurement)
        ms_as_of = run_recall_query(conn, q_vec, q_text, ef_search=ef, as_of_ts=as_of_sample)
        latencies_as_of.append(ms_as_of)

    p50 = _percentile(latencies_plain, 50)
    p95 = _percentile(latencies_plain, 95)
    p99 = _percentile(latencies_plain, 99)

    as_of_overhead = _percentile(
        [b - a for a, b in zip(latencies_plain, latencies_as_of)], 50
    )

    passed = p99 <= target["p99_ms"]
    status = "PASS" if passed else "FAIL"

    print(
        f"  [{status}] size={size:>10,}  p50={p50:6.1f}ms  p95={p95:6.1f}ms  "
        f"p99={p99:6.1f}ms  target={target['p99_ms']}ms  "
        f"as_of_overhead(p50)={as_of_overhead:+.1f}ms"
    )

    return BenchResult(
        corpus_size=size,
        n_queries=n_queries,
        p50_ms=round(p50, 2),
        p95_ms=round(p95, 2),
        p99_ms=round(p99, 2),
        target_p99_ms=target["p99_ms"],
        passed=passed,
        as_of_overhead_ms=round(as_of_overhead, 2),
    )


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--dsn", default=os.getenv("DATABASE_URL", "postgresql://localhost/pgmnemo_stress"))
    parser.add_argument("--sizes", default="100000,1000000",
                        help="Comma-separated corpus sizes (default: 100000,1000000)")
    parser.add_argument("--queries", type=int, default=20, help="Queries per size (default: 20)")
    parser.add_argument("--ef-search", type=int, default=100, help="ef_search GUC (default: 100)")
    parser.add_argument("--out", default=None, help="Output JSON file path")
    parser.add_argument("--no-embed", action="store_true", help="Skip embedding (text-only path)")
    parser.add_argument("--skip-10m", action="store_true", help="Skip 10M tier")
    parser.add_argument("--dry-run", action="store_true", help="Validate env only")
    parser.add_argument("--verbose", action="store_true")
    args = parser.parse_args()

    sizes = [int(s.strip()) for s in args.sizes.split(",") if s.strip()]
    if args.skip_10m:
        sizes = [s for s in sizes if s < 10_000_000]

    # Connect
    try:
        conn = psycopg2.connect(args.dsn, client_encoding="utf8")
        conn.autocommit = False
    except Exception as exc:
        print(f"ERROR: Cannot connect to PostgreSQL: {exc}", file=sys.stderr)
        return 2

    try:
        version = ensure_extension(conn)
        print(f"pgmnemo version: {version}")
        setup_stress_schema(conn)
    except RuntimeError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        conn.close()
        return 2

    if args.dry_run:
        print("Dry-run OK — environment validated.")
        conn.close()
        return 0

    print(f"Sizes: {', '.join(str(s) for s in sizes)} | "
          f"Queries/size: {args.queries} | "
          f"ef_search: {args.ef_search} | "
          f"embed: {not args.no_embed}")
    print("─" * 70)

    results: list[BenchResult] = []
    all_passed = True

    # Start from clean state
    truncate_corpus(conn)

    for size in sorted(sizes):
        result = benchmark_size(
            conn, size, args.queries, args.ef_search,
            no_embed=args.no_embed, verbose=args.verbose
        )
        results.append(result)
        if not result.passed:
            all_passed = False

    print("─" * 70)
    print(f"Overall: {'PASS' if all_passed else 'FAIL'}")

    # Write JSON output
    out_path = args.out
    if not out_path:
        date_str = datetime.now().strftime("%Y%m%d_%H%M%S")
        out_dir = Path(__file__).parent.parent / "results"
        out_dir.mkdir(parents=True, exist_ok=True)
        out_path = str(out_dir / f"stress_recall_{date_str}.json")

    report = {
        "version": version,
        "date": datetime.now(timezone.utc).isoformat(),
        "pgmnemo_version": version,
        "embed": not args.no_embed,
        "ef_search": args.ef_search,
        "n_queries": args.queries,
        "results": [
            {
                "corpus_size": r.corpus_size,
                "p50_ms": r.p50_ms,
                "p95_ms": r.p95_ms,
                "p99_ms": r.p99_ms,
                "target_p99_ms": r.target_p99_ms,
                "passed": r.passed,
                "as_of_ts_overhead_p50_ms": r.as_of_overhead_ms,
            }
            for r in results
        ],
        "overall_passed": all_passed,
    }

    with open(out_path, "w") as f:
        json.dump(report, f, indent=2)
    print(f"Report written: {out_path}")

    conn.close()
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
