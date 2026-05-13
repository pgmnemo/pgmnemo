#!/usr/bin/env python3
"""
significance_test_extended.py — pgmnemo per-category significance test (release gate)

Extends scripts/significance_test.py with:
  - per-category z-test (LoCoMo: single_hop, multi_hop, temporal, open_domain, adversarial)
  - Holm-Bonferroni correction across ALL tested cells (categories × metrics + overall)
  - regression alert cells (|Δ|≥1pp but not yet significant — "near-threshold")
  - machine-readable JSON output for METRICS_BY_VERSION.md auto-population

Usage:
    python scripts/significance_test_extended.py \\
        <baseline_metrics.json> <candidate_metrics.json> \\
        [--out-json spec/reports/sig_<bench>_<cand>_vs_<base>.json] \\
        [--regression-pp 1.0]   # near-threshold delta to flag

Exit codes:
  0 — no significant regression, no significant improvement (neutral, OK to ship)
  1 — significant improvement found (OK to ship with claim)
  2 — significant regression detected (BLOCK release)
  3 — near-threshold cells without significance but delta ≥ regression-pp (WARN)
"""
import argparse, json, math, sys
from pathlib import Path


def z_test(k1, n1, k2, n2):
    if n1 == 0 or n2 == 0:
        return (0.0, 1.0)
    p1, p2 = k1 / n1, k2 / n2
    p_pool = (k1 + k2) / (n1 + n2)
    if p_pool in (0.0, 1.0):
        return (0.0, 1.0)
    se = math.sqrt(p_pool * (1 - p_pool) * (1 / n1 + 1 / n2))
    if se == 0:
        return (0.0, 1.0)
    z = (p2 - p1) / se
    p_two = math.erfc(abs(z) / math.sqrt(2))
    return (z, p_two)


def collect_cells(base, cand, metrics):
    cells = []
    for cat, stats in base.get("by_category", {}).items():
        c_stats = cand.get("by_category", {}).get(cat, {})
        for metric in metrics:
            if metric in stats and metric in c_stats:
                b, c = stats[metric], c_stats[metric]
                nb, mb, nc, mc = b["n"], b["mean"], c["n"], c["mean"]
                kb, kc = round(mb * nb), round(mc * nc)
                z, p = z_test(kb, nb, kc, nc)
                cells.append(
                    {"scope": cat, "metric": metric, "n_base": nb, "n_cand": nc,
                     "mean_base": mb, "mean_cand": mc, "delta": mc - mb,
                     "z": z, "p_raw": p}
                )
    for metric in metrics:
        if metric in base.get("overall", {}) and metric in cand.get("overall", {}):
            b = base["overall"][metric]
            c = cand["overall"][metric]
            nb, mb, nc, mc = b["n"], b["mean"], c["n"], c["mean"]
            kb, kc = round(mb * nb), round(mc * nc)
            z, p = z_test(kb, nb, kc, nc)
            cells.append(
                {"scope": "OVERALL", "metric": metric, "n_base": nb, "n_cand": nc,
                 "mean_base": mb, "mean_cand": mc, "delta": mc - mb,
                 "z": z, "p_raw": p}
            )
    return cells


def holm_bonferroni(cells):
    m = len(cells)
    idxs = sorted(range(m), key=lambda i: cells[i]["p_raw"])
    for rank, i in enumerate(idxs):
        cells[i]["p_corr"] = min(1.0, cells[i]["p_raw"] * (m - rank))
    return cells


def verdict(cell, regression_pp_threshold=1.0):
    dpp = cell["delta"] * 100
    if cell["p_corr"] < 0.05 and cell["delta"] < 0:
        return "REGRESSION"
    if cell["p_corr"] < 0.05 and cell["delta"] > 0:
        return "IMPROVED"
    if abs(dpp) >= regression_pp_threshold:
        return "NEAR_THRESHOLD"
    return "neutral"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("baseline", help="path to baseline metrics.json")
    ap.add_argument("candidate", help="path to candidate metrics.json")
    ap.add_argument("--out-json", default=None, help="write structured result to this path")
    ap.add_argument("--regression-pp", type=float, default=1.0,
                    help="absolute pp threshold for NEAR_THRESHOLD flag (default 1.0)")
    ap.add_argument("--metrics", default="recall@1,recall@5,recall@10,recall@20,recall@25,recall@50,mrr",
                    help="comma-separated metric list; only those present in both files are tested")
    args = ap.parse_args()

    base = json.load(open(args.baseline))
    cand = json.load(open(args.candidate))
    metrics = [m.strip() for m in args.metrics.split(",") if m.strip()]

    cells = collect_cells(base, cand, metrics)
    if not cells:
        print("ERROR: no shared metrics between base and cand", file=sys.stderr)
        sys.exit(2)
    cells = holm_bonferroni(cells)
    for c in cells:
        c["verdict"] = verdict(c, args.regression_pp)

    # Print table
    print(f"\nBase:  {args.baseline}")
    print(f"Cand:  {args.candidate}")
    print(f"Tested cells: {len(cells)}  |  regression threshold: ±{args.regression_pp}pp")
    print()
    hdr = f'{"scope":<13} {"metric":<12} {"base":<8} {"cand":<8} {"Δpp":<10} {"z":<7} {"p_raw":<9} {"p_corr":<9} {"verdict"}'
    print(hdr)
    print("-" * len(hdr))
    cells_sorted = sorted(cells, key=lambda c: (c["scope"] != "OVERALL", c["scope"], c["metric"]))
    for c in cells_sorted:
        dpp = c["delta"] * 100
        print(f'{c["scope"]:<13} {c["metric"]:<12} {c["mean_base"]:<8.4f} {c["mean_cand"]:<8.4f} '
              f'{dpp:+.2f}pp    {c["z"]:<+6.2f} {c["p_raw"]:<9.4f} {c["p_corr"]:<9.4f} {c["verdict"]}')

    regressions = [c for c in cells if c["verdict"] == "REGRESSION"]
    improvements = [c for c in cells if c["verdict"] == "IMPROVED"]
    near = [c for c in cells if c["verdict"] == "NEAR_THRESHOLD"]

    print()
    print(f"SIGNIFICANT REGRESSIONS  : {len(regressions)}")
    for c in regressions:
        print(f"  🔴 {c['scope']}/{c['metric']}: {c['delta']*100:+.2f}pp  p_corr={c['p_corr']:.4f}")
    print(f"SIGNIFICANT IMPROVEMENTS : {len(improvements)}")
    for c in improvements:
        print(f"  🟢 {c['scope']}/{c['metric']}: {c['delta']*100:+.2f}pp  p_corr={c['p_corr']:.4f}")
    print(f"NEAR-THRESHOLD (|Δ| ≥ {args.regression_pp}pp, ns): {len(near)}")
    for c in near:
        sign = "📉" if c["delta"] < 0 else "📈"
        print(f"  {sign} {c['scope']}/{c['metric']}: {c['delta']*100:+.2f}pp  p_corr={c['p_corr']:.4f}")

    if args.out_json:
        out = {
            "baseline": str(Path(args.baseline).resolve()),
            "candidate": str(Path(args.candidate).resolve()),
            "regression_pp_threshold": args.regression_pp,
            "cells": cells,
            "summary": {
                "n_cells": len(cells),
                "n_regression": len(regressions),
                "n_improvement": len(improvements),
                "n_near_threshold": len(near),
            },
        }
        Path(args.out_json).parent.mkdir(parents=True, exist_ok=True)
        with open(args.out_json, "w") as f:
            json.dump(out, f, indent=2)
        print(f"\n[wrote] {args.out_json}")

    # Exit codes per docstring
    if regressions:
        sys.exit(2)  # BLOCK release
    if improvements and not near:
        sys.exit(1)  # OK with claim
    if near:
        sys.exit(3)  # WARN
    sys.exit(0)


if __name__ == "__main__":
    main()
