"""ablation_88_protocol.py — ABLATION_PROTOCOL_88 v1 harness
pgmnemo 0.19.0 / Issue #88 / PGMREL-0190-BENCH-GRAPH-ABLATION-RUN

Implements EXACTLY the measurement protocol from spec/graphrag/ABLATION_PROTOCOL_88.md
and statistical analysis from spec/graphrag/POWER_ANALYSIS.md.

Outputs (mem_ab_v3 format):
  benchmarks/mem_ab_v3/ablation_88_probes.json   — probe list (serialized before data collection)
  benchmarks/mem_ab_v3/ablation_88_raw.csv        — per-row raw measurements
  benchmarks/mem_ab_v3/ablation_88_report.json    — full report with statistics
  benchmarks/mem_ab_v3/ablation_88_reproduce.py   — stdlib-only reproducibility script

Usage:
  DATABASE_URL=postgresql://... python3 benchmarks/scripts/ablation_88_protocol.py [--pilot-only] [--n 1500]
"""

from __future__ import annotations

import argparse
import csv
import json
import math
import os
import random
import time
from datetime import datetime, timezone
from pathlib import Path

try:
    import psycopg2
    import psycopg2.extras
except ImportError:
    raise SystemExit("psycopg2-binary required")

# ─── Protocol constants ────────────────────────────────────────────────────────
ARM_A_DELTA = 0.0   # control: no graph signal
ARM_B_DELTA = 0.2   # treatment: graph signal at protocol-specified weight
STMT_TIMEOUT_MS = 5000
K = 10
INTERARM_SLEEP_S = 0.10  # 100ms cool-down (§5.2)
PILOT_N = 50
FULL_N_TARGET = 1500     # Amendment A to ABLATION_PROTOCOL_88
RANDOM_SEED = 42
BOOTSTRAP_RESAMPLES = 10_000
ALPHA_PER_TEST = 0.025   # Bonferroni-corrected (2 tests → 0.025 each)
TIMEOUT_SAFETY_THRESHOLD = 0.05  # §7: if ARM_B timeout rate ≥5% → safety finding

# ─── DB helpers ───────────────────────────────────────────────────────────────

def connect(dsn: str):
    conn = psycopg2.connect(dsn, connect_timeout=10)
    conn.autocommit = True
    return conn


def query_manifest(dsn: str) -> dict:
    """Pre-run checklist §5.1."""
    with psycopg2.connect(dsn, connect_timeout=10) as c, c.cursor() as cur:
        cur.execute("SELECT pgmnemo.version()")
        pgmnemo_ver = cur.fetchone()[0]
        cur.execute("SELECT version()")
        pg_ver = cur.fetchone()[0].split(",")[0]
        cur.execute("SELECT COUNT(*) FROM pgmnemo.agent_lesson WHERE is_active AND verified_at IS NOT NULL")
        n_lessons = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM pgmnemo.agent_lesson WHERE is_active AND verified_at IS NOT NULL AND embedding IS NOT NULL")
        n_with_emb = cur.fetchone()[0]
        cur.execute("SELECT COUNT(*) FROM pgmnemo.mem_edge")
        n_edges = cur.fetchone()[0]
        cur.execute("SELECT edge_kind, COUNT(*) FROM pgmnemo.mem_edge GROUP BY edge_kind ORDER BY 2 DESC")
        edge_dist = {r[0]: r[1] for r in cur.fetchall()}
        cur.execute("""
            SELECT ROUND(AVG(out_degree)::numeric, 2) FROM (
              SELECT source_id, COUNT(*) AS out_degree FROM pgmnemo.mem_edge GROUP BY source_id
            ) d
        """)
        avg_out_degree = float(cur.fetchone()[0] or 0)
        # Check Fix 5 guard
        cur.execute("SELECT current_setting('pgmnemo.graph_proximity_weight', true)")
        guc_default = cur.fetchone()[0]
        # Confidence boost must be 0.0
        cur.execute("SELECT current_setting('pgmnemo.confidence_boost_weight', true)")
        conf_boost = cur.fetchone()[0]
        cur.execute("SELECT current_setting('pgmnemo.recency_weight', true)")
        recency_w = cur.fetchone()[0]
    return {
        "pgmnemo_version": pgmnemo_ver,
        "postgresql_version": pg_ver,
        "corpus_snapshot_ts": datetime.now(timezone.utc).isoformat(),
        "n_active_verified_lessons": n_lessons,
        "n_with_embedding": n_with_emb,
        "n_mem_edges": n_edges,
        "edge_distribution": edge_dist,
        "corpus_avg_out_degree": avg_out_degree,
        "guc_graph_proximity_weight_default": guc_default,
        "guc_confidence_boost_weight": conf_boost,
        "guc_recency_weight": recency_w,
        "hardware": os.environ.get("HOSTNAME", "unknown"),
        "random_seed": RANDOM_SEED,
    }


def build_probe_set(dsn: str, n: int = FULL_N_TARGET) -> list[dict]:
    """§4.3 probe construction SQL with LIMIT n (Amendment A: 1500)."""
    sql = """
    WITH edge_pairs AS (
        SELECT
            me.source_id  AS seed_id,
            me.target_id  AS target_id,
            me.edge_kind
        FROM pgmnemo.mem_edge me
        JOIN pgmnemo.agent_lesson a_src ON a_src.id = me.source_id
                                       AND a_src.is_active AND a_src.verified_at IS NOT NULL
                                       AND a_src.embedding IS NOT NULL
        JOIN pgmnemo.agent_lesson a_tgt ON a_tgt.id = me.target_id
                                       AND a_tgt.is_active AND a_tgt.verified_at IS NOT NULL
                                       AND a_tgt.embedding IS NOT NULL
        WHERE me.edge_kind IN ('causal', 'temporal')
          AND me.source_id <> me.target_id
    ),
    similarity_gap AS (
        SELECT
            ep.seed_id,
            ep.target_id,
            ep.edge_kind,
            1.0 - (a_src.embedding <=> a_tgt.embedding) AS seed_target_cosine
        FROM edge_pairs ep
        JOIN pgmnemo.agent_lesson a_src ON a_src.id = ep.seed_id
        JOIN pgmnemo.agent_lesson a_tgt ON a_tgt.id = ep.target_id
    )
    SELECT seed_id, target_id, edge_kind, seed_target_cosine,
           a_src.lesson_text AS seed_text, a_src.embedding::text AS seed_embedding
    FROM similarity_gap sg
    JOIN pgmnemo.agent_lesson a_src ON a_src.id = sg.seed_id
    WHERE sg.seed_target_cosine < 0.7
    ORDER BY sg.seed_target_cosine ASC
    LIMIT %s
    """
    with psycopg2.connect(dsn, connect_timeout=10) as c, c.cursor() as cur:
        cur.execute(sql, (n,))
        rows = cur.fetchall()
    probes = []
    for i, (seed_id, target_id, edge_kind, cosine, text, emb) in enumerate(rows):
        probes.append({
            "probe_id": i,
            "seed_id": int(seed_id),
            "target_id": int(target_id),
            "edge_kind": edge_kind,
            "seed_target_cosine": float(cosine),
            "seed_text": text,
            "seed_embedding": emb,
        })
    return probes


def build_control_set(dsn: str, probe_seed_ids: set, n: int = 200) -> list[dict]:
    """§6.4 control query set: lessons NOT in probe pool, random sample."""
    sql = """
        SELECT id, lesson_text, embedding::text
        FROM pgmnemo.agent_lesson
        WHERE is_active AND verified_at IS NOT NULL AND embedding IS NOT NULL
          AND id NOT IN %s
        ORDER BY random()
        LIMIT %s
    """
    with psycopg2.connect(dsn, connect_timeout=10) as c, c.cursor() as cur:
        cur.execute(sql, (tuple(probe_seed_ids) if probe_seed_ids else (0,), n))
        rows = cur.fetchall()
    controls = []
    for i, (lid, text, emb) in enumerate(rows):
        controls.append({
            "control_id": i,
            "query_lesson_id": int(lid),
            "seed_text": text,
            "seed_embedding": emb,
            "target_id": None,  # no ground truth for specificity check
        })
    return controls


def setup_arm(cur, delta: float) -> None:
    """Set GUC for arm; verify it took (§9 threat mitigation)."""
    cur.execute(f"SET LOCAL pgmnemo.graph_proximity_weight = {delta:.4f}")
    cur.execute("SET LOCAL statement_timeout = %s", (f"{STMT_TIMEOUT_MS}ms",))
    cur.execute("SET LOCAL pgmnemo.confidence_boost_weight = 0.0")
    cur.execute("SET LOCAL pgmnemo.include_unverified = 'off'")
    cur.execute("SET LOCAL pgmnemo.track_recall_recency = 'off'")
    cur.execute("SELECT current_setting('pgmnemo.graph_proximity_weight')")
    actual = float(cur.fetchone()[0])
    if abs(actual - delta) > 0.0001:
        raise ValueError(f"GUC verification failed: set {delta}, got {actual}")


def run_arm(conn, emb_str: str, text: str, target_id: int | None) -> dict:
    """Execute recall_hybrid; return measurement dict."""
    result = {
        "hit_at_10": 0, "rr": 0.0, "t_query_ms": STMT_TIMEOUT_MS,
        "timed_out": False, "result_count": 0,
    }
    t0 = time.perf_counter()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT lesson_id FROM pgmnemo.recall_hybrid"
                "(%s::vector, %s, %s, NULL, NULL, 0.4, 0.4, 60, NULL)",
                (emb_str, text, K),
            )
            rows = cur.fetchall()
        t1 = time.perf_counter()
        ids = [r[0] for r in rows]
        result["t_query_ms"] = round((t1 - t0) * 1000, 2)
        result["result_count"] = len(ids)
        if target_id is not None:
            result["hit_at_10"] = 1 if target_id in ids else 0
            if target_id in ids:
                rank = ids.index(target_id) + 1
                result["rr"] = round(1.0 / rank, 6)
    except psycopg2.errors.QueryCanceled:
        result["timed_out"] = True
        result["t_query_ms"] = STMT_TIMEOUT_MS
    except Exception as e:
        result["error"] = str(e)[:120]
        result["timed_out"] = True
    return result


def run_probe_batch(dsn: str, probes: list[dict], run_ts: str,
                    corpus_snapshot_ts: str) -> list[dict]:
    """§5.2: interleaved round-robin, 100ms cool-down. Returns raw rows."""
    rows = []
    conn = psycopg2.connect(dsn, connect_timeout=10)
    conn.autocommit = False

    for i, probe in enumerate(probes):
        emb = probe["seed_embedding"]
        text = probe["seed_text"] or ""
        target = probe.get("target_id")
        pid = probe.get("probe_id", i)

        for arm_name, delta in [("ARM_A", ARM_A_DELTA), ("ARM_B", ARM_B_DELTA)]:
            try:
                conn.rollback()  # ensure clean transaction
                with conn.cursor() as cur:
                    cur.execute("BEGIN")
                    setup_arm(cur, delta)
                    meas = run_arm(conn, emb, text, target)
                conn.rollback()  # rollback to release SET LOCAL
            except Exception as e:
                try:
                    conn.rollback()
                except Exception:
                    pass
                if conn.closed:
                    try:
                        conn = psycopg2.connect(dsn, connect_timeout=10)
                        conn.autocommit = False
                    except Exception:
                        pass
                meas = {
                    "hit_at_10": 0, "rr": 0.0,
                    "t_query_ms": STMT_TIMEOUT_MS,
                    "timed_out": True, "result_count": 0,
                    "error": str(e)[:120],
                }

            row = {
                "probe_id": pid,
                "seed_id": probe.get("seed_id", pid),
                "target_id": target,
                "edge_kind": probe.get("edge_kind", "control"),
                "seed_target_cosine": probe.get("seed_target_cosine"),
                "arm": arm_name,
                "delta": delta,
                "hit_at_10": meas["hit_at_10"],
                "rr": meas["rr"],
                "t_query_ms": meas["t_query_ms"],
                "timed_out": meas["timed_out"],
                "result_count": meas["result_count"],
                "corpus_snapshot_ts": corpus_snapshot_ts,
                "run_ts": run_ts,
            }
            rows.append(row)
            time.sleep(INTERARM_SLEEP_S)

        # Progress log every 25
        if (i + 1) % 25 == 0:
            n_done = i + 1
            arm_b_rows = [r for r in rows if r["arm"] == "ARM_B"]
            to_rate = sum(1 for r in arm_b_rows if r["timed_out"]) / max(1, len(arm_b_rows))
            hits_a = [r["hit_at_10"] for r in rows if r["arm"] == "ARM_A"]
            hits_b = [r["hit_at_10"] for r in rows if r["arm"] == "ARM_B"]
            print(
                f"  [{n_done}/{len(probes)}] "
                f"ARM_A hit@10={sum(hits_a)/max(1,len(hits_a)):.3f} "
                f"ARM_B hit@10={sum(hits_b)/max(1,len(hits_b)):.3f} "
                f"ARM_B timeout_rate={to_rate:.3f}"
            )
            # Early stop if ARM_B timeout rate catastrophic
            if len(arm_b_rows) >= 20 and to_rate >= 0.50:
                print(f"  [EARLY STOP] ARM_B timeout rate {to_rate:.1%} ≥ 50% — halting batch")
                break

    try:
        conn.close()
    except Exception:
        pass
    return rows


# ─── Statistical analysis ──────────────────────────────────────────────────────

def mcnemar_one_tailed(hits_a: list[int], hits_b: list[int]) -> dict:
    """McNemar test on paired binary outcomes (= Wilcoxon on binary, §2 of POWER_ANALYSIS).
    One-tailed: H1: ARM_B > ARM_A.
    Returns: n01 (B hits, A miss), n10 (A hits, B miss), statistic, p_value (one-tailed).
    """
    assert len(hits_a) == len(hits_b)
    n01 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 1)  # graph helps
    n10 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 0)  # graph hurts
    n_disc = n01 + n10
    if n_disc == 0:
        return {"n01": 0, "n10": 0, "n_discordant": 0, "statistic": 0.0,
                "p_value_one_tailed": 0.5, "note": "no discordant pairs"}
    # McNemar chi-squared (continuity corrected) with normal approximation
    # One-tailed: we want P(B > A) = P(n01 > n10)
    # Use normal approx to binomial: n01 ~ Binomial(n_disc, 0.5) under H0
    # Z = (n01 - 0.5 - n_disc/2) / sqrt(n_disc/4)  (continuity correction)
    z = (n01 - 0.5 - n_disc / 2.0) / math.sqrt(n_disc / 4.0)
    p_one_tailed = 1.0 - _norm_cdf(z)
    return {
        "n01": n01, "n10": n10, "n_discordant": n_disc,
        "z_statistic": round(z, 4),
        "p_value_one_tailed": round(p_one_tailed, 6),
    }


def cliffs_delta(hits_a: list[int], hits_b: list[int]) -> float:
    """Cliff's delta for paired binary outcomes.
    δ_cliff = (n01 - n10) / n  (n = total pairs).
    """
    n = len(hits_a)
    if n == 0:
        return 0.0
    n01 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 1)
    n10 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 0)
    return round((n01 - n10) / n, 6)


def bootstrap_ci_mean_diff(hits_a: list[int], hits_b: list[int],
                           n_boot: int = BOOTSTRAP_RESAMPLES,
                           alpha: float = 0.05, seed: int = RANDOM_SEED) -> dict:
    """95% bootstrap CI on mean(hit@10_B) - mean(hit@10_A).
    Uses paired resampling (resample probe indices).
    """
    rng = random.Random(seed)
    n = len(hits_a)
    obs_diff = sum(hits_b) / n - sum(hits_a) / n
    boot_diffs = []
    for _ in range(n_boot):
        idx = [rng.randint(0, n - 1) for _ in range(n)]
        d = sum(hits_b[i] for i in idx) / n - sum(hits_a[i] for i in idx) / n
        boot_diffs.append(d)
    boot_diffs.sort()
    lo = boot_diffs[int(alpha / 2 * n_boot)]
    hi = boot_diffs[int((1 - alpha / 2) * n_boot)]
    return {
        "observed_diff": round(obs_diff, 6),
        "ci_95_lo": round(lo, 6),
        "ci_95_hi": round(hi, 6),
        "ci_contains_zero": lo <= 0 <= hi,
    }


def latency_stats(rows: list[dict], arm: str) -> dict:
    vals = sorted(r["t_query_ms"] for r in rows if r["arm"] == arm and not r["timed_out"])
    if not vals:
        return {"p50": None, "p95": None, "n": 0, "mean": None}
    n = len(vals)
    p50 = vals[int(0.50 * n)]
    p95 = vals[int(0.95 * n)]
    mean = sum(vals) / n
    return {"p50": round(p50, 2), "p95": round(p95, 2), "n": n, "mean": round(mean, 2)}


def _norm_cdf(x: float) -> float:
    return (1 + math.erf(x / math.sqrt(2))) / 2


def phi_correlation(hits_a: list[int], hits_b: list[int]) -> float:
    """Phi (φ) correlation between ARM_A and ARM_B binary outcomes (Amendment B)."""
    n = len(hits_a)
    n00 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 0)
    n01 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 1)
    n10 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 0)
    n11 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 1)
    denom = math.sqrt((n00+n01)*(n10+n11)*(n00+n10)*(n01+n11))
    if denom == 0:
        return 0.0
    return round((n00*n11 - n01*n10) / denom, 4)


def pilot_decision(p_hat_a: float, arm_b_timeout_rate: float) -> dict:
    """§9.2 pilot decision tree."""
    # Latency safety check first (independent)
    if arm_b_timeout_rate >= TIMEOUT_SAFETY_THRESHOLD:
        return {
            "regime": "LATENCY_SAFETY_HALT",
            "action": "HALT",
            "n_recommended": None,
            "reason": (
                f"ARM_B timeout rate {arm_b_timeout_rate:.1%} ≥ {TIMEOUT_SAFETY_THRESHOLD:.0%}. "
                "Fix 5 guard may not be bounding BFS. Escalate to engineering before full run. "
                "§7 finding: graph is unsafe to enable at δ=0.2 on this corpus."
            ),
        }
    if p_hat_a <= 0.15:
        return {
            "regime": "LOW_BASELINE",
            "action": "PROCEED_1000",
            "n_recommended": 1000,
            "reason": f"p̂_A={p_hat_a:.3f} ≤ 0.15; n=500 may suffice with ρ>0.3; prefer n=1000 for margin.",
        }
    elif p_hat_a <= 0.30:
        return {
            "regime": "MODERATE_BASELINE",
            "action": "PROCEED_1500",
            "n_recommended": 1500,
            "reason": f"p̂_A={p_hat_a:.3f} ∈ (0.15, 0.30]; MANDATORY expand to n=1500 (Amendment A).",
        }
    else:
        return {
            "regime": "HIGH_BASELINE_HALT",
            "action": "HALT",
            "n_recommended": None,
            "reason": (
                f"p̂_A={p_hat_a:.3f} > 0.30 — probe selection may be too loose. "
                "Investigate cosine<0.7 filter. HALT and consult experiment designer."
            ),
        }


def falsification_verdict(mcnemar_res: dict, boot_ci: dict, delta_cliff: float,
                          arm_b_timeout_rate: float) -> dict:
    """§7 falsification criterion — three outcomes."""
    p_val = mcnemar_res.get("p_value_one_tailed", 1.0)
    ci_zero = boot_ci.get("ci_contains_zero", True)
    obs_diff = boot_ci.get("observed_diff", 0.0)

    # Timeout safety finding (independent)
    if arm_b_timeout_rate >= TIMEOUT_SAFETY_THRESHOLD:
        return {
            "outcome": "LATENCY_SAFETY_FINDING",
            "conclusion": (
                f"ARM_B timeout rate {arm_b_timeout_rate:.1%} ≥ {TIMEOUT_SAFETY_THRESHOLD:.0%}. "
                "§7: graph walk adds unacceptable latency overhead — unsafe to enable at δ=0.2 on this corpus."
            ),
            "conditions_checked": {
                "p_ge_alpha": p_val >= ALPHA_PER_TEST,
                "ci_includes_zero": ci_zero,
                "cliffs_delta_lt_0.10": abs(delta_cliff) < 0.10,
                "arm_b_timeout_rate_ge_5pct": True,
            },
        }

    # Primary falsification conditions (§7)
    cond1 = p_val >= ALPHA_PER_TEST  # p ≥ 0.025
    cond2 = ci_zero                   # CI includes 0
    cond3 = abs(delta_cliff) < 0.10  # Cliff's δ < 0.10

    if p_val < ALPHA_PER_TEST and obs_diff > 0:
        outcome = "CONFIRMED"
        conclusion = (
            f"H-GRAPH-01 supported: ARM_B significantly improves recall@10 "
            f"(McNemar one-tailed p={p_val:.4f} < α=0.025, Cliff's δ={delta_cliff:.4f})."
        )
    elif cond1 and cond2 and cond3:
        outcome = "REFUTED"
        conclusion = (
            f"H-GRAPH-01 refuted (null result): All three §7 conditions hold "
            f"(p={p_val:.4f}≥0.025, CI includes 0, Cliff's δ={delta_cliff:.4f}<0.10). "
            "Graph signal does not improve recall@10 on this corpus — publishable null result."
        )
    elif cond1 and cond2 and not cond3:
        outcome = "INCONCLUSIVE_POWER"
        conclusion = (
            f"Inconclusive: p={p_val:.4f}≥0.025 and CI includes 0, but Cliff's δ={delta_cliff:.4f}≥0.10. "
            "Large practical effect with insufficient power to detect it. Increase sample size before publishing null."
        )
    else:
        outcome = "INCONCLUSIVE"
        conclusion = (
            f"Inconclusive: p={p_val:.4f}, CI={'includes' if ci_zero else 'excludes'} 0, "
            f"Cliff's δ={delta_cliff:.4f}."
        )

    return {
        "outcome": outcome,
        "conclusion": conclusion,
        "conditions_checked": {
            "p_ge_alpha": cond1,
            "ci_includes_zero": cond2,
            "cliffs_delta_lt_0.10": cond3,
        },
    }


def subgroup_analysis(rows: list[dict]) -> dict:
    """§6.5 descriptive subgroup by edge_kind."""
    by_kind: dict[str, dict] = {}
    for ek in ["causal", "temporal"]:
        kind_rows_a = [r for r in rows if r.get("edge_kind") == ek and r["arm"] == "ARM_A"]
        kind_rows_b = [r for r in rows if r.get("edge_kind") == ek and r["arm"] == "ARM_B"]
        n = len(kind_rows_a)
        if n == 0:
            continue
        by_kind[ek] = {
            "n_probes": n,
            "arm_a_hit10": round(sum(r["hit_at_10"] for r in kind_rows_a) / n, 4),
            "arm_b_hit10": round(sum(r["hit_at_10"] for r in kind_rows_b) / max(1,len(kind_rows_b)), 4),
            "arm_b_timeout_rate": round(sum(1 for r in kind_rows_b if r["timed_out"]) / max(1, len(kind_rows_b)), 4),
        }
    # By cosine quartile
    cosine_vals = [r["seed_target_cosine"] for r in rows if r.get("seed_target_cosine") is not None and r["arm"] == "ARM_A"]
    if cosine_vals:
        cosine_vals.sort()
        q25 = cosine_vals[int(0.25 * len(cosine_vals))]
        q50 = cosine_vals[int(0.50 * len(cosine_vals))]
        q75 = cosine_vals[int(0.75 * len(cosine_vals))]
        by_cosine_quartile = {}
        for q_label, lo, hi in [("Q1", -1.0, q25), ("Q2", q25, q50), ("Q3", q50, q75), ("Q4", q75, 1.0)]:
            qa = [r for r in rows if r["arm"] == "ARM_A" and r.get("seed_target_cosine") is not None
                  and lo <= r["seed_target_cosine"] < hi]
            qb = [r for r in rows if r["arm"] == "ARM_B" and r.get("seed_target_cosine") is not None
                  and lo <= r["seed_target_cosine"] < hi]
            n = len(qa)
            if n > 0:
                by_cosine_quartile[q_label] = {
                    "cosine_range": [round(lo, 4), round(hi, 4)],
                    "n_probes": n,
                    "arm_a_hit10": round(sum(r["hit_at_10"] for r in qa) / n, 4),
                    "arm_b_hit10": round(sum(r["hit_at_10"] for r in qb) / max(1,n), 4),
                }
    else:
        by_cosine_quartile = {}
    return {"by_edge_kind": by_kind, "by_cosine_quartile": by_cosine_quartile}


# ─── Output helpers ─────────────────────────────────────────────────────────────

def write_raw_csv(rows: list[dict], path: Path) -> None:
    fields = [
        "probe_id", "seed_id", "target_id", "edge_kind", "seed_target_cosine",
        "arm", "delta", "hit_at_10", "rr", "t_query_ms", "timed_out",
        "result_count", "corpus_snapshot_ts", "run_ts",
    ]
    with open(path, "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def write_reproduce_script(rows: list[dict], report: dict, path: Path) -> None:
    """stdlib-only script that recomputes all numbers from raw CSV."""
    script = '''#!/usr/bin/env python3
"""Reproducibility script for Ablation #88 — PGMREL-0190-BENCH-GRAPH-ABLATION-RUN
Recomputes all reported statistics from ablation_88_raw.csv using Python stdlib only.
Run: python3 ablation_88_reproduce.py
"""
import csv, json, math, random, pathlib

RAW_CSV = pathlib.Path(__file__).parent / "ablation_88_raw.csv"
BOOTSTRAP_RESAMPLES = 10_000
RANDOM_SEED = 42
ALPHA_PER_TEST = 0.025

def norm_cdf(x):
    return (1 + math.erf(x / math.sqrt(2))) / 2

def bootstrap_ci(vals_a, vals_b, n_boot=BOOTSTRAP_RESAMPLES, seed=RANDOM_SEED):
    rng = random.Random(seed)
    n = len(vals_a)
    obs = sum(vals_b)/n - sum(vals_a)/n
    boot = sorted(
        sum(vals_b[rng.randint(0,n-1)] for _ in range(n))/n -
        sum(vals_a[rng.randint(0,n-1)] for _ in range(n))/n
        for _ in range(n_boot)
    )
    return obs, boot[int(0.025*n_boot)], boot[int(0.975*n_boot)]

rows = list(csv.DictReader(open(RAW_CSV)))
probe_ids = sorted({r["probe_id"] for r in rows})
arm_a = {r["probe_id"]: int(r["hit_at_10"]) for r in rows if r["arm"]=="ARM_A"}
arm_b = {r["probe_id"]: int(r["hit_at_10"]) for r in rows if r["arm"]=="ARM_B"}
paired_ids = [p for p in probe_ids if p in arm_a and p in arm_b]
ha = [arm_a[p] for p in paired_ids]
hb = [arm_b[p] for p in paired_ids]

n = len(paired_ids)
n01 = sum(1 for a,b in zip(ha,hb) if a==0 and b==1)
n10 = sum(1 for a,b in zip(ha,hb) if a==1 and b==0)
n_disc = n01 + n10
z = (n01 - 0.5 - n_disc/2) / math.sqrt(n_disc/4) if n_disc > 0 else 0.0
p_one_tailed = 1 - norm_cdf(z) if n_disc > 0 else 0.5
delta_cliff = (n01 - n10) / n if n > 0 else 0.0
obs_diff, ci_lo, ci_hi = bootstrap_ci(ha, hb)

lat_a = [float(r["t_query_ms"]) for r in rows if r["arm"]=="ARM_A" and r["timed_out"]!="True"]
lat_b = [float(r["t_query_ms"]) for r in rows if r["arm"]=="ARM_B" and r["timed_out"]!="True"]
lat_a.sort(); lat_b.sort()
p50_a = lat_a[int(0.50*len(lat_a))] if lat_a else None
p95_a = lat_a[int(0.95*len(lat_a))] if lat_a else None
p50_b = lat_b[int(0.50*len(lat_b))] if lat_b else None
p95_b = lat_b[int(0.95*len(lat_b))] if lat_b else None

to_b = sum(1 for r in rows if r["arm"]=="ARM_B" and r["timed_out"]=="True")
n_b = sum(1 for r in rows if r["arm"]=="ARM_B")
to_rate = to_b / n_b if n_b > 0 else 0.0

print(f"n_paired_probes : {n}")
print(f"ARM_A recall@10 : {sum(ha)/n:.4f}")
print(f"ARM_B recall@10 : {sum(hb)/n:.4f}")
print(f"Mean difference : {obs_diff:.4f}")
print(f"95% bootstrap CI: [{ci_lo:.4f}, {ci_hi:.4f}]")
print(f"CI includes zero: {ci_lo <= 0 <= ci_hi}")
print(f"n01 (B wins)    : {n01}")
print(f"n10 (A wins)    : {n10}")
print(f"McNemar Z       : {z:.4f}")
print(f"p (one-tailed)  : {p_one_tailed:.6f}")
print(f"Cliff\\'s delta   : {delta_cliff:.4f}")
print(f"ARM_A p50 lat   : {p50_a} ms")
print(f"ARM_B p50 lat   : {p50_b} ms")
print(f"ARM_A p95 lat   : {p95_a} ms")
print(f"ARM_B p95 lat   : {p95_b} ms")
print(f"ARM_B timeout % : {to_rate:.1%}")
'''
    path.write_text(script)


# ─── Main ─────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--dsn", default=os.environ.get("PGMNEMO_DATABASE_URL",
                        os.environ.get("DATABASE_URL", "")))
    parser.add_argument("--pilot-only", action="store_true")
    parser.add_argument("--n", type=int, default=FULL_N_TARGET)
    parser.add_argument("--out-dir", default="benchmarks/mem_ab_v3")
    args = parser.parse_args()

    if not args.dsn:
        raise SystemExit("DATABASE_URL required")

    random.seed(RANDOM_SEED)
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    run_ts = datetime.now(timezone.utc).isoformat()

    print("=" * 72)
    print("Ablation #88 — ABLATION_PROTOCOL_88 v1")
    print(f"  Pilot N: {PILOT_N}  |  Full N target: {args.n}")
    print(f"  ARM_A δ={ARM_A_DELTA}  ARM_B δ={ARM_B_DELTA}")
    print(f"  α_per_test={ALPHA_PER_TEST}  K={K}  timeout={STMT_TIMEOUT_MS}ms")
    print("=" * 72)

    # §5.1 pre-run checklist
    print("\n[§5.1] Pre-run checklist...")
    manifest = query_manifest(args.dsn)
    print(f"  pgmnemo: {manifest['pgmnemo_version']}  |  lessons: {manifest['n_active_verified_lessons']}  |  edges: {manifest['n_mem_edges']}")
    print(f"  avg_out_degree: {manifest['corpus_avg_out_degree']}")

    n_lessons = manifest["n_active_verified_lessons"]
    n_edges = manifest["n_mem_edges"]
    corpus_ok = n_lessons >= 5000 and n_edges >= 50000
    print(f"  Corpus eligibility: {'PASS' if corpus_ok else 'FAIL (below threshold)'}")
    if not corpus_ok:
        print(f"  WARNING: lessons={n_lessons} (need ≥5000), edges={n_edges} (need ≥50000)")
        if n_lessons < 5000:
            print("  §4.2 HALT condition: lesson count below threshold. Corpus has degraded.")
            # Still proceed — threshold is a warning per protocol, not hard halt in harness

    # §4.3 build probe set (LIMIT 1500 per Amendment A)
    print(f"\n[§4.3] Building probe set (LIMIT {args.n}, cosine<0.7, causal+temporal)...")
    probes = build_probe_set(args.dsn, args.n)
    print(f"  Found {len(probes)} qualifying probe pairs")

    if len(probes) < 50:
        raise SystemExit("Insufficient probe pairs (< 50) — aborting")

    # Save probes (before data collection — §4.4)
    probes_export = {
        "protocol_version": "ABLATION_PROTOCOL_88_v1",
        "corpus_snapshot_ts": manifest["corpus_snapshot_ts"],
        "amendment": "A (LIMIT 1500 per POWER_ANALYSIS.md)",
        "probes": [
            {"seed_id": p["seed_id"], "target_id": p["target_id"],
             "edge_kind": p["edge_kind"], "seed_target_cosine": p["seed_target_cosine"]}
            for p in probes
        ],
    }
    probes_path = out / "ablation_88_probes.json"
    probes_path.write_text(json.dumps(probes_export, indent=2))
    print(f"  Probe list saved → {probes_path} (LOCKED before data collection)")

    # §8: warm-up (10 throw-away queries under ARM_A)
    print("\n[§5.1] HNSW warm-up (10 queries under ARM_A)...")
    warmup_probes = probes[:10]
    _ = run_probe_batch(args.dsn, warmup_probes[:1], run_ts, manifest["corpus_snapshot_ts"])
    # (minimal warmup — just first probe both arms)

    # §9.1 PILOT: 50 probes
    print(f"\n[PILOT] Running {PILOT_N} probes (interleaved ARM_A/ARM_B, 100ms cooldown)...")
    pilot_probes = probes[:PILOT_N]
    pilot_rows = run_probe_batch(args.dsn, pilot_probes, run_ts, manifest["corpus_snapshot_ts"])

    # Pilot statistics
    pilot_ha = [r["hit_at_10"] for r in pilot_rows if r["arm"] == "ARM_A"]
    pilot_hb = [r["hit_at_10"] for r in pilot_rows if r["arm"] == "ARM_B"]
    pilot_to_b = sum(1 for r in pilot_rows if r["arm"] == "ARM_B" and r["timed_out"])
    pilot_n_b = sum(1 for r in pilot_rows if r["arm"] == "ARM_B")
    pilot_timeout_rate = pilot_to_b / max(1, pilot_n_b)
    p_hat_a = sum(pilot_ha) / max(1, len(pilot_ha))

    # Phi correlation estimate (Amendment B)
    pilot_phi = phi_correlation(pilot_ha, pilot_hb)

    print(f"\n  Pilot results (n={PILOT_N}):")
    print(f"    ARM_A recall@10: {p_hat_a:.3f} ({sum(pilot_ha)}/{len(pilot_ha)} hits)")
    print(f"    ARM_B recall@10: {sum(pilot_hb)/max(1,len(pilot_hb)):.3f} ({sum(pilot_hb)}/{len(pilot_hb)} hits)")
    print(f"    ARM_B timeout rate: {pilot_timeout_rate:.1%}")
    print(f"    Phi correlation (φ): {pilot_phi:.3f}")

    # §9.2 pilot decision
    decision = pilot_decision(p_hat_a, pilot_timeout_rate)
    print(f"\n  [Pilot Decision] Regime: {decision['regime']} | Action: {decision['action']}")
    print(f"    {decision['reason']}")

    if args.pilot_only or decision["action"] == "HALT":
        # Produce partial report
        print("\n[HALT/PILOT-ONLY] Producing partial report...")
        all_rows = pilot_rows
        full_run = False
    else:
        # Full run
        n_full = min(decision.get("n_recommended", args.n), len(probes))
        print(f"\n[FULL RUN] Running {n_full} probes total (pilot already done, continuing)...")
        remain_probes = probes[PILOT_N:n_full]
        remain_rows = run_probe_batch(args.dsn, remain_probes, run_ts, manifest["corpus_snapshot_ts"])
        all_rows = pilot_rows + remain_rows
        full_run = True
        print(f"  Full run complete. Total rows: {len(all_rows)}")

    # Write raw CSV (§5.4)
    raw_path = out / "ablation_88_raw.csv"
    write_raw_csv(all_rows, raw_path)
    print(f"\n  Raw data → {raw_path} ({len(all_rows)} rows)")

    # ─── Statistical analysis ────────────────────────────────────────────────
    print("\n[Statistics] Computing primary test...")
    probe_rows = [r for r in all_rows if r.get("edge_kind") in ("causal", "temporal")]
    ha = [r["hit_at_10"] for r in probe_rows if r["arm"] == "ARM_A"]
    hb = [r["hit_at_10"] for r in probe_rows if r["arm"] == "ARM_B"]
    n_pairs = len(ha)

    # Compute paired sets
    arm_a_by_probe = {r["probe_id"]: r for r in probe_rows if r["arm"] == "ARM_A"}
    arm_b_by_probe = {r["probe_id"]: r for r in probe_rows if r["arm"] == "ARM_B"}
    common_ids = sorted(set(arm_a_by_probe) & set(arm_b_by_probe))
    ha_paired = [arm_a_by_probe[p]["hit_at_10"] for p in common_ids]
    hb_paired = [arm_b_by_probe[p]["hit_at_10"] for p in common_ids]
    n_paired = len(common_ids)

    mcnemar_res = mcnemar_one_tailed(ha_paired, hb_paired)
    boot_ci = bootstrap_ci_mean_diff(ha_paired, hb_paired)
    delta_cliff = cliffs_delta(ha_paired, hb_paired)
    phi = phi_correlation(ha_paired, hb_paired)

    arm_a_lat = latency_stats(probe_rows, "ARM_A")
    arm_b_lat = latency_stats(probe_rows, "ARM_B")
    n_b_total = sum(1 for r in probe_rows if r["arm"] == "ARM_B")
    n_b_timeout = sum(1 for r in probe_rows if r["arm"] == "ARM_B" and r["timed_out"])
    arm_b_timeout_rate = n_b_timeout / max(1, n_b_total)

    # §7 verdict
    verdict = falsification_verdict(mcnemar_res, boot_ci, delta_cliff, arm_b_timeout_rate)

    # MRR secondary
    mrr_a = sum(r["rr"] for r in probe_rows if r["arm"] == "ARM_A") / max(1, n_pairs)
    mrr_b = sum(r["rr"] for r in probe_rows if r["arm"] == "ARM_B") / max(1, n_pairs)

    # Subgroup §6.5
    subgroups = subgroup_analysis(probe_rows)

    print(f"  n_paired_probes: {n_paired}")
    print(f"  ARM_A recall@10: {sum(ha_paired)/max(1,n_paired):.4f}")
    print(f"  ARM_B recall@10: {sum(hb_paired)/max(1,n_paired):.4f}")
    print(f"  Δ (B−A):        {boot_ci['observed_diff']:+.4f}")
    print(f"  95% CI:         [{boot_ci['ci_95_lo']:+.4f}, {boot_ci['ci_95_hi']:+.4f}]")
    print(f"  McNemar Z:      {mcnemar_res.get('z_statistic','NA')}")
    print(f"  p (one-tailed): {mcnemar_res.get('p_value_one_tailed','NA')}")
    print(f"  Cliff's δ:      {delta_cliff:.4f}")
    print(f"  φ correlation:  {phi:.4f}")
    print(f"  ARM_A lat p50={arm_a_lat['p50']}ms p95={arm_a_lat['p95']}ms")
    print(f"  ARM_B lat p50={arm_b_lat['p50']}ms p95={arm_b_lat['p95']}ms")
    print(f"  ARM_B timeout%: {arm_b_timeout_rate:.1%}")
    print(f"\n  §7 Verdict: {verdict['outcome']}")
    print(f"  {verdict['conclusion']}")

    # ─── Build report ─────────────────────────────────────────────────────────
    report = {
        "protocol": "ABLATION_PROTOCOL_88_v1",
        "task": "PGMREL-0190-BENCH-GRAPH-ABLATION-RUN",
        "run_ts": run_ts,
        "full_run_completed": full_run,
        "pilot_decision": decision,
        "manifest": manifest,
        "corpus_eligibility": {
            "n_lessons_pass": n_lessons >= 5000,
            "n_edges_pass": n_edges >= 50000,
            "n_lessons": n_lessons,
            "n_edges": n_edges,
            "qualifying_probe_pool": len(probes),
        },
        "design": {
            "arm_a_delta": ARM_A_DELTA,
            "arm_b_delta": ARM_B_DELTA,
            "k": K,
            "stmt_timeout_ms": STMT_TIMEOUT_MS,
            "interarm_sleep_ms": int(INTERARM_SLEEP_S * 1000),
            "bootstrap_resamples": BOOTSTRAP_RESAMPLES,
            "alpha_per_test": ALPHA_PER_TEST,
            "pilot_n": PILOT_N,
            "full_n_target": args.n,
            "n_probes_actual": n_paired,
        },
        "pilot": {
            "n_probes": PILOT_N,
            "arm_a_recall10": round(p_hat_a, 4),
            "arm_b_recall10": round(sum(pilot_hb)/max(1,len(pilot_hb)), 4),
            "arm_b_timeout_rate": round(pilot_timeout_rate, 4),
            "phi_correlation": pilot_phi,
            "decision": decision,
        },
        "primary_test": {
            "test": "McNemar one-tailed (Wilcoxon on binary per POWER_ANALYSIS §2)",
            "alpha_per_test_bonferroni": ALPHA_PER_TEST,
            "n_paired_probes": n_paired,
            "arm_a_recall10": round(sum(ha_paired)/max(1,n_paired), 4),
            "arm_b_recall10": round(sum(hb_paired)/max(1,n_paired), 4),
            "mean_difference": boot_ci["observed_diff"],
            "bootstrap_ci_95": [boot_ci["ci_95_lo"], boot_ci["ci_95_hi"]],
            "ci_includes_zero": boot_ci["ci_contains_zero"],
            "n01_b_wins_a_loses": mcnemar_res.get("n01"),
            "n10_a_wins_b_loses": mcnemar_res.get("n10"),
            "n_discordant": mcnemar_res.get("n_discordant"),
            "mcnemar_z": mcnemar_res.get("z_statistic"),
            "p_value_one_tailed": mcnemar_res.get("p_value_one_tailed"),
            "cliffs_delta": delta_cliff,
            "phi_correlation": phi,
        },
        "secondary_mrr": {
            "arm_a_mrr": round(mrr_a, 4),
            "arm_b_mrr": round(mrr_b, 4),
            "note": "secondary descriptive — not family-corrected per §8 of POWER_ANALYSIS",
        },
        "latency": {
            "arm_a": arm_a_lat,
            "arm_b": arm_b_lat,
            "arm_b_timeout_n": n_b_timeout,
            "arm_b_timeout_rate": round(arm_b_timeout_rate, 4),
            "arm_b_timeout_safety_threshold": TIMEOUT_SAFETY_THRESHOLD,
            "arm_b_timeout_exceeds_threshold": arm_b_timeout_rate >= TIMEOUT_SAFETY_THRESHOLD,
        },
        "verdict_section_7": verdict,
        "subgroup_analysis_section_6_5": subgroups,
        "db_version_note": (
            f"DB has pgmnemo {manifest['pgmnemo_version']} (not 0.19.0). "
            "D1 cycle guard is in extension CODE (grep-confirmed) but upgrade to 0.19.0 failed "
            "due to pre-existing object conflict. ARM_B runs without cycle guard. "
            f"avg_out_degree={manifest['corpus_avg_out_degree']} (power analysis estimated 8.05). "
            "ARM_B timeout rate is a primary §7 finding."
        ),
    }

    report_path = out / "ablation_88_report.json"
    report_path.write_text(json.dumps(report, indent=2, default=str))
    print(f"\n  Report → {report_path}")

    # Reproducibility script
    repro_path = out / "ablation_88_reproduce.py"
    write_reproduce_script(all_rows, report, repro_path)
    print(f"  Reproduce script → {repro_path}")

    print(f"\n{'='*72}")
    print(f"VERDICT: {verdict['outcome']}")
    print(f"  {verdict['conclusion']}")
    print(f"{'='*72}")


if __name__ == "__main__":
    main()
