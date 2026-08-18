#!/usr/bin/env python3
"""
ablation_88_reproduce.py — stdlib-only reproduction script
Ablation #88: Graph signal contribution in recall_hybrid (pgmnemo 0.19.0)
Protocol: spec/graphrag/ABLATION_PROTOCOL_88.md (Amendment A: LIMIT 1500)
Run: 2026-08-18  Task: PGMREL-0190-BENCH-GRAPH-ABLATION-RUN

Usage:
    python3 ablation_88_reproduce.py [ablation_88_raw.csv]

Reproduces all reported numbers from the raw dataset (no DB required).
G-EVIDENCE-INTEGRITY format: mem_ab_v3

Expected output (REFUTED null result):
  n_probes_completed      : 1500
  ARM_A recall@10         : 0.0000  (0/1500)
  ARM_B recall@10         : 0.0000  (0/1500)
  Mean diff (B-A)         : +0.0000
  95% bootstrap CI        : [0.0000, 0.0000]
  n01 (B wins / A loses)  : 0
  n10 (A wins / B loses)  : 0
  McNemar Z               : 0.0000
  p (one-tailed)          : 1.000000
  Cliff's delta           : 0.0000
  §7 VERDICT: REFUTED
"""

import csv
import json
import math
import random
import sys
from pathlib import Path

# ── Constants (must match harness) ────────────────────────────────────────────
ALPHA_PER_TEST = 0.025       # Bonferroni α for 2-test family
TIMEOUT_SAFETY_THRESHOLD = 0.05  # §7: ARM_B timeout rate ≥ 5% → safety finding
BOOTSTRAP_B = 10_000
BOOTSTRAP_SEED = 42


def load_csv(path):
    rows = []
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            r["hit_at_10"] = int(r["hit_at_10"])
            r["rr"] = float(r["rr"])
            r["t_query_ms"] = float(r["t_query_ms"])
            r["timed_out"] = r["timed_out"] in ("True", "true", "1")
            r["delta"] = float(r["delta"])
            rows.append(r)
    return rows


def percentile(data, p):
    s = sorted(data)
    if not s:
        return None
    return s[min(int(p * len(s)), len(s) - 1)]


def norm_cdf(x):
    return (1 + math.erf(x / math.sqrt(2))) / 2


def mcnemar_one_tailed(hits_a, hits_b):
    """One-tailed McNemar. Returns dict with n01, n10, z, p_one_tailed."""
    n01 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 1)
    n10 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 0)
    n_disc = n01 + n10
    if n_disc == 0:
        return {"n01": 0, "n10": 0, "z": 0.0, "p_one_tailed": 1.0,
                "note": "degenerate — zero discordant pairs"}
    z = (n01 - 0.5 - n_disc / 2.0) / math.sqrt(n_disc / 4.0)
    p = 1.0 - norm_cdf(z)
    return {"n01": n01, "n10": n10, "z": round(z, 4), "p_one_tailed": round(p, 6)}


def cliffs_delta(hits_a, hits_b):
    n = len(hits_a)
    if n == 0:
        return 0.0
    n01 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 1)
    n10 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 0)
    return round((n01 - n10) / n, 6)


def bootstrap_ci(hits_a, hits_b, B=BOOTSTRAP_B, seed=BOOTSTRAP_SEED, alpha=0.05):
    """Bootstrap CI on mean(hits_b) - mean(hits_a), paired resampling."""
    rng = random.Random(seed)
    n = len(hits_a)
    obs = sum(hits_b) / n - sum(hits_a) / n
    diffs = [b - a for a, b in zip(hits_a, hits_b)]
    boot = sorted([sum(rng.choices(diffs, k=n)) / n for _ in range(B)])
    lo = boot[int((alpha / 2) * B)]
    hi = boot[int((1 - alpha / 2) * B)]
    return round(obs, 6), round(lo, 6), round(hi, 6)


def reproduce(csv_path):
    rows = load_csv(csv_path)

    # Split probe vs control
    probe_a = [r for r in rows if r.get("query_class") == "probe" and r["arm"] == "ARM_A"]
    probe_b = [r for r in rows if r.get("query_class") == "probe" and r["arm"] == "ARM_B"]
    ctrl_a  = [r for r in rows if r.get("query_class") == "control" and r["arm"] == "ARM_A"]
    ctrl_b  = [r for r in rows if r.get("query_class") == "control" and r["arm"] == "ARM_B"]

    # Fallback: if query_class absent (legacy format), split by delta
    if not probe_a:
        probe_a = [r for r in rows if r["arm"] == "ARM_A" and float(r.get("delta","0.0")) == 0.0]
        probe_b = [r for r in rows if r["arm"] == "ARM_B" and float(r.get("delta","0.2")) == 0.2]

    n_probe = len(probe_a)
    n_ctrl  = len(ctrl_a)

    # Primary
    hits_a = [r["hit_at_10"] for r in probe_a]
    hits_b = [r["hit_at_10"] for r in probe_b]

    n00 = sum(1 for a, b in zip(hits_a, hits_b) if a == 0 and b == 0)
    n11 = sum(1 for a, b in zip(hits_a, hits_b) if a == 1 and b == 1)

    mcn = mcnemar_one_tailed(hits_a, hits_b)
    delta_c = cliffs_delta(hits_a, hits_b)
    obs_diff, ci_lo, ci_hi = bootstrap_ci(hits_a, hits_b)

    recall_a = sum(hits_a) / max(1, n_probe)
    recall_b = sum(hits_b) / max(1, n_probe)
    mrr_a = sum(r["rr"] for r in probe_a) / max(1, n_probe)
    mrr_b = sum(r["rr"] for r in probe_b) / max(1, n_probe)

    # Latency (probe only, exclude timeouts)
    lat_a = [r["t_query_ms"] for r in probe_a if not r["timed_out"]]
    lat_b = [r["t_query_ms"] for r in probe_b if not r["timed_out"]]
    p50_a = percentile(lat_a, 0.50)
    p95_a = percentile(lat_a, 0.95)
    p50_b = percentile(lat_b, 0.50)
    p95_b = percentile(lat_b, 0.95)
    n_b_timeout = sum(1 for r in probe_b if r["timed_out"])
    timeout_rate = n_b_timeout / max(1, n_probe)

    # Control specificity
    c_hits_a = [r["hit_at_10"] for r in ctrl_a]
    c_hits_b = [r["hit_at_10"] for r in ctrl_b]
    ctrl_hit_a = sum(c_hits_a) / max(1, n_ctrl)
    ctrl_hit_b = sum(c_hits_b) / max(1, n_ctrl)
    c_mcn = mcnemar_one_tailed(c_hits_a, c_hits_b)

    # §7 verdict
    crit1 = mcn["p_one_tailed"] >= ALPHA_PER_TEST
    crit2 = ci_lo <= 0 <= ci_hi
    crit3 = abs(delta_c) < 0.10

    if timeout_rate >= TIMEOUT_SAFETY_THRESHOLD:
        verdict = "LATENCY_SAFETY_FINDING"
        verdict_detail = (
            f"ARM_B timeout_rate={timeout_rate:.1%} >= {TIMEOUT_SAFETY_THRESHOLD:.0%}. "
            "Graph walk unsafe at delta=0.2 on this corpus."
        )
    elif crit1 and crit2 and crit3:
        verdict = "REFUTED"
        verdict_detail = (
            f"H-GRAPH-01 null result: p={mcn['p_one_tailed']:.6f} >= {ALPHA_PER_TEST}, "
            f"CI=[{ci_lo},{ci_hi}] includes 0, Cliff_d={delta_c:.4f} < 0.10"
        )
    elif not crit1:
        verdict = "CONFIRMED"
        verdict_detail = (
            f"H-GRAPH-01 confirmed: p={mcn['p_one_tailed']:.6f} < {ALPHA_PER_TEST}, "
            f"obs_diff={obs_diff:+.4f}, Cliff_d={delta_c:.4f}"
        )
    else:
        verdict = "INCONCLUSIVE"
        verdict_detail = (
            f"p={mcn['p_one_tailed']:.6f}, CI=[{ci_lo},{ci_hi}], Cliff_d={delta_c:.4f}"
        )

    # ── Print ─────────────────────────────────────────────────────────────────
    print("=" * 72)
    print("Ablation #88: Graph Signal Isolation in recall_hybrid")
    print("Task: PGMREL-0190-BENCH-GRAPH-ABLATION-RUN  |  pgmnemo 0.19.0")
    print("=" * 72)
    print(f"n_probes_completed      : {n_probe}")
    print(f"n00 (both miss)         : {n00}")
    print(f"n01 (B hits, A misses)  : {mcn['n01']}")
    print(f"n10 (A hits, B misses)  : {mcn['n10']}")
    print(f"n11 (both hit)          : {n11}")
    print(f"ARM_A recall@10         : {recall_a:.4f}  ({sum(hits_a)}/{n_probe})")
    print(f"ARM_B recall@10         : {recall_b:.4f}  ({sum(hits_b)}/{n_probe})")
    print(f"Mean diff (B-A)         : {obs_diff:+.4f}")
    print(f"95% bootstrap CI        : [{ci_lo:.4f}, {ci_hi:.4f}]  (B={BOOTSTRAP_B}, seed={BOOTSTRAP_SEED})")
    print(f"CI includes zero        : {crit2}")
    print(f"McNemar Z               : {mcn['z']:.4f}")
    print(f"p (one-tailed)          : {mcn['p_one_tailed']:.6f}")
    print(f"Cliff's delta           : {delta_c:.4f}")
    print(f"MRR ARM_A / ARM_B       : {mrr_a:.4f} / {mrr_b:.4f}")
    print(f"ARM_A lat p50/p95       : {p50_a}/{p95_a} ms")
    print(f"ARM_B lat p50/p95       : {p50_b}/{p95_b} ms")
    print(f"ARM_B timeout rate      : {n_b_timeout}/{n_probe} = {timeout_rate:.1%}")
    print()
    if n_ctrl > 0:
        print(f"Control set n={n_ctrl}:")
        print(f"  hit@10 ARM_A / ARM_B  : {ctrl_hit_a:.3f} / {ctrl_hit_b:.3f}")
        print(f"  McNemar n01/n10       : {c_mcn['n01']}/{c_mcn['n10']}  p={c_mcn['p_one_tailed']:.4f}")
        print(f"  Confound detected     : {c_mcn['p_one_tailed'] < ALPHA_PER_TEST}")
    print()
    print(f"§7 Falsification criterion: crit1={crit1} crit2={crit2} crit3={crit3}")
    print(f"§7 VERDICT: {verdict}")
    print(f"  {verdict_detail}")
    print("=" * 72)

    return {
        "n_probe": n_probe, "n_ctrl": n_ctrl,
        "n00": n00, "n01": mcn["n01"], "n10": mcn["n10"], "n11": n11,
        "recall_a": recall_a, "recall_b": recall_b, "obs_diff": obs_diff,
        "ci_lo": ci_lo, "ci_hi": ci_hi, "p_one_tailed": mcn["p_one_tailed"],
        "cliffs_delta": delta_c, "verdict": verdict,
        "p50_a": p50_a, "p95_a": p95_a, "p50_b": p50_b, "p95_b": p95_b,
        "timeout_rate_b": timeout_rate,
    }


if __name__ == "__main__":
    csv_path = sys.argv[1] if len(sys.argv) > 1 else str(
        Path(__file__).parent / "ablation_88_raw.csv"
    )
    reproduce(csv_path)
