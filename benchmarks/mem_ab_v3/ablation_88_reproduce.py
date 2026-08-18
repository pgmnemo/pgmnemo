#!/usr/bin/env python3
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
print(f"Cliff\'s delta   : {delta_cliff:.4f}")
print(f"ARM_A p50 lat   : {p50_a} ms")
print(f"ARM_B p50 lat   : {p50_b} ms")
print(f"ARM_A p95 lat   : {p95_a} ms")
print(f"ARM_B p95 lat   : {p95_b} ms")
print(f"ARM_B timeout % : {to_rate:.1%}")
