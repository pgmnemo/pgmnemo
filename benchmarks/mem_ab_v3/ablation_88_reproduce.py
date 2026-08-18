#!/usr/bin/env python3
"""Reproducibility script for Ablation #88 — PGMREL-0190-BENCH-GRAPH-ABLATION-RUN
Protocol: ABLATION_PROTOCOL_88_v1 (Amendment A)
Recomputes all reported statistics from ablation_88_raw.csv using Python stdlib only.

Run: python3 ablation_88_reproduce.py

G-EVIDENCE-INTEGRITY verification: this script reproduces all numbers in ablation_88_report.json
from ablation_88_raw.csv with zero external dependencies.

FINDING SUMMARY:
  pgmnemo 0.18.1 corpus (74,778 edges, avg_out_degree=16.7, hub nodes temporal_deg=176-220):
  ARM_B timeout_rate = 96.0% >= 5% threshold -> LATENCY_SAFETY_FINDING
  ARM_A recall@10 = 0.0 (targets outside HNSW+BM25 candidate pool -> re-ranker cannot help)
  Required: D3 repair (max_depth 5->2) before quality ablation is valid
"""
import csv
import json
import math
import pathlib
import random
import sys

RAW_CSV = pathlib.Path(__file__).parent / "ablation_88_raw.csv"
REPORT_JSON = pathlib.Path(__file__).parent / "ablation_88_report.json"
ALPHA_PER_TEST = 0.025
TIMEOUT_SAFETY_THRESHOLD = 0.05
BOOTSTRAP_RESAMPLES = 10_000
RANDOM_SEED = 42


def norm_cdf(x):
    return (1 + math.erf(x / math.sqrt(2))) / 2


def mcnemar_one_tailed(ha, hb):
    n01 = sum(1 for a, b in zip(ha, hb) if a == 0 and b == 1)
    n10 = sum(1 for a, b in zip(ha, hb) if a == 1 and b == 0)
    n_disc = n01 + n10
    if n_disc == 0:
        return {"n01": 0, "n10": 0, "n_discordant": 0, "z": 0.0, "p_one_tailed": 0.5}
    z = (n01 - 0.5 - n_disc / 2.0) / math.sqrt(n_disc / 4.0)
    p = 1.0 - norm_cdf(z)
    return {"n01": n01, "n10": n10, "n_discordant": n_disc, "z": round(z, 4), "p_one_tailed": round(p, 6)}


def cliffs_delta(ha, hb):
    n = len(ha)
    if n == 0: return 0.0
    n01 = sum(1 for a, b in zip(ha, hb) if a == 0 and b == 1)
    n10 = sum(1 for a, b in zip(ha, hb) if a == 1 and b == 0)
    return round((n01 - n10) / n, 6)


def bootstrap_ci(ha, hb, n_boot=BOOTSTRAP_RESAMPLES, seed=RANDOM_SEED):
    rng = random.Random(seed)
    n = len(ha)
    if n < 2:
        obs = (sum(hb) - sum(ha)) / max(1, n)
        return obs, 0.0, 0.0
    obs = sum(hb) / n - sum(ha) / n
    boot = sorted(
        sum(hb[rng.randint(0, n-1)] for _ in range(n)) / n -
        sum(ha[rng.randint(0, n-1)] for _ in range(n)) / n
        for _ in range(n_boot)
    )
    return obs, boot[int(0.025 * n_boot)], boot[int(0.975 * n_boot)]


# ── Load ───────────────────────────────────────────────────────────────────────
if not RAW_CSV.exists():
    print(f"ERROR: {RAW_CSV} not found", file=sys.stderr)
    sys.exit(1)

rows = list(csv.DictReader(open(RAW_CSV)))
arm_a_rows = [r for r in rows if r["arm"] == "ARM_A"]
arm_b_rows = [r for r in rows if r["arm"] == "ARM_B"]

n_probes = len(arm_a_rows)
hits_a = [int(r["hit_at_10"]) for r in arm_a_rows]
hits_b = [int(r["hit_at_10"]) for r in arm_b_rows]
n_b_total = len(arm_b_rows)
n_b_timeout = sum(1 for r in arm_b_rows if r["timed_out"] == "True")
timeout_rate = n_b_timeout / max(1, n_b_total)
recall_a = sum(hits_a) / max(1, n_probes)
recall_b = sum(hits_b) / max(1, n_b_total)

# Paired analysis
probe_ids = sorted({r["probe_id"] for r in rows})
arm_a_map = {r["probe_id"]: int(r["hit_at_10"]) for r in arm_a_rows}
arm_b_map = {r["probe_id"]: int(r["hit_at_10"]) for r in arm_b_rows}
paired_ids = [p for p in probe_ids if p in arm_a_map and p in arm_b_map]
ha = [arm_a_map[p] for p in paired_ids]
hb = [arm_b_map[p] for p in paired_ids]
n_paired = len(paired_ids)

mcn = mcnemar_one_tailed(ha, hb)
delta_c = cliffs_delta(ha, hb)
obs_diff, ci_lo, ci_hi = bootstrap_ci(ha, hb)

# Latency
lat_a = sorted(float(r["t_query_ms"]) for r in arm_a_rows if r["timed_out"] != "True")
lat_b = sorted(float(r["t_query_ms"]) for r in arm_b_rows if r["timed_out"] != "True")
p50_a = lat_a[int(0.50 * len(lat_a))] if lat_a else None
p95_a = lat_a[int(0.95 * len(lat_a))] if lat_a else None
p50_b = lat_b[int(0.50 * len(lat_b))] if lat_b else None
p95_b = lat_b[int(0.95 * len(lat_b))] if lat_b else None

# §7 verdict
if timeout_rate >= TIMEOUT_SAFETY_THRESHOLD:
    verdict = "LATENCY_SAFETY_FINDING"
    verdict_detail = (
        f"ARM_B timeout_rate={timeout_rate:.1%} >= {TIMEOUT_SAFETY_THRESHOLD:.0%}. "
        "Graph walk unsafe at delta=0.2 on 74k-edge corpus. D3 (max_depth 5->2) required."
    )
elif mcn["p_one_tailed"] < ALPHA_PER_TEST and obs_diff > 0:
    verdict = "CONFIRMED"
    verdict_detail = f"H-GRAPH-01 confirmed: p={mcn['p_one_tailed']:.4f}<alpha, Cliff_d={delta_c:.4f}"
elif mcn["p_one_tailed"] >= ALPHA_PER_TEST and (ci_lo <= 0 <= ci_hi) and abs(delta_c) < 0.10:
    verdict = "REFUTED"
    verdict_detail = f"H-GRAPH-01 refuted: p={mcn['p_one_tailed']:.4f}>=0.025, CI includes 0, Cliff_d={delta_c:.4f}<0.10"
else:
    verdict = "INCONCLUSIVE"
    verdict_detail = f"p={mcn['p_one_tailed']:.4f}, CI=[{ci_lo:.4f},{ci_hi:.4f}], Cliff_d={delta_c:.4f}"

# ── Print ──────────────────────────────────────────────────────────────────────
print("=" * 72)
print("Ablation #88: Graph Signal Isolation in recall_hybrid")
print("Task: PGMREL-0190-BENCH-GRAPH-ABLATION-RUN  |  pgmnemo 0.19.0 release")
print("=" * 72)
print(f"n_probes_completed      : {n_probes}")
print(f"n_paired_probes         : {n_paired}")
print(f"ARM_A recall@10         : {recall_a:.4f}  ({sum(hits_a)}/{n_probes})")
print(f"ARM_B recall@10         : {recall_b:.4f}  ({sum(hits_b)}/{n_b_total})")
print(f"Mean diff (B-A)         : {obs_diff:+.4f}")
print(f"95% bootstrap CI        : [{ci_lo:.4f}, {ci_hi:.4f}]")
print(f"CI includes zero        : {ci_lo <= 0 <= ci_hi}")
print(f"n01 (B wins / A loses)  : {mcn['n01']}")
print(f"n10 (A wins / B loses)  : {mcn['n10']}")
print(f"McNemar Z               : {mcn['z']:.4f}")
print(f"p (one-tailed)          : {mcn['p_one_tailed']:.6f}")
print(f"Cliff's delta           : {delta_c:.4f}")
print(f"ARM_A lat p50/p95       : {p50_a}/{p95_a} ms")
print(f"ARM_B lat p50/p95       : {p50_b}/{p95_b} ms  (non-timeout only, n={len(lat_b)})")
print(f"ARM_B timeout rate      : {n_b_timeout}/{n_b_total} = {timeout_rate:.1%}")
print()
print(f"§7 VERDICT: {verdict}")
print(f"  {verdict_detail}")
print("=" * 72)

# Cross-check vs report.json
if REPORT_JSON.exists():
    saved = json.loads(REPORT_JSON.read_text())
    saved_to = saved.get("latency", {}).get("arm_b", {}).get("timeout_rate", -1)
    saved_verdict = saved.get("section_7_verdict", {}).get("outcome", "?")
    ok = abs((saved_to or 0) - timeout_rate) < 0.001 and saved_verdict == verdict
    print(f"Cross-check vs ablation_88_report.json: {'PASS ✓' if ok else 'MISMATCH ✗'}")
