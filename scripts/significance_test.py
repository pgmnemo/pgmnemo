#!/usr/bin/env python3
"""
significance_test.py — pgmnemo statistical comparison tool

Usage:
    python scripts/significance_test.py <baseline_metrics.json> <candidate_metrics.json>

Computes for every shared metric:
  - Point estimates and 95% Wilson CIs
  - Two-proportion z-test (for recall@k)
  - Cohen's h effect size
  - Holm-Bonferroni correction across all tested metrics

Exit codes:
  0 — at least one metric significantly improved, none regressed significantly
  1 — no significant improvements, or regressions detected
"""

import json
import math
import sys
from typing import Optional


def wilson_ci(k: int, n: int, z: float = 1.96) -> tuple[float, float]:
    """95% Wilson confidence interval for a proportion k/n."""
    if n == 0:
        return (0.0, 0.0)
    p = k / n
    denom = 1 + z**2 / n
    centre = (p + z**2 / (2 * n)) / denom
    half = (z * math.sqrt(p * (1 - p) / n + z**2 / (4 * n**2))) / denom
    return (max(0.0, centre - half), min(1.0, centre + half))


def two_prop_z(p1: float, n1: int, p2: float, n2: int) -> tuple[float, float]:
    """Two-proportion z-test. Returns (z_statistic, p_two_tailed)."""
    p_pool = (p1 * n1 + p2 * n2) / (n1 + n2)
    if p_pool in (0.0, 1.0):
        return (0.0, 1.0)
    se = math.sqrt(p_pool * (1 - p_pool) * (1 / n1 + 1 / n2))
    if se == 0:
        return (0.0, 1.0)
    z = (p2 - p1) / se
    # Two-tailed p-value via standard normal CDF approximation
    p = 2 * (1 - _norm_cdf(abs(z)))
    return (z, p)


def cohens_h(p1: float, p2: float) -> float:
    """Cohen's h effect size for two proportions."""
    phi1 = 2 * math.asin(math.sqrt(max(0.0, min(1.0, p1))))
    phi2 = 2 * math.asin(math.sqrt(max(0.0, min(1.0, p2))))
    return phi2 - phi1


def _norm_cdf(x: float) -> float:
    """Standard normal CDF using math.erf."""
    return (1 + math.erf(x / math.sqrt(2))) / 2


def holm_bonferroni(p_values: list[float]) -> list[float]:
    """
    Holm-Bonferroni correction. Returns corrected p-values in original order.
    p_corr[i] = min(1, max over j<=rank of (m - j + 1) * p_sorted[j])
    """
    m = len(p_values)
    indexed = sorted(enumerate(p_values), key=lambda x: x[1])
    corrected = [0.0] * m
    running_max = 0.0
    for rank, (orig_idx, p) in enumerate(indexed):
        adjusted = (m - rank) * p
        running_max = max(running_max, adjusted)
        corrected[orig_idx] = min(1.0, running_max)
    return corrected


def extract_overall_metric(metrics: dict, metric_name: str) -> Optional[tuple[float, int]]:
    """Extract (mean, n) from overall section of a metrics.json."""
    overall = metrics.get("overall", {})
    if metric_name not in overall:
        return None
    m = overall[metric_name]
    if isinstance(m, dict) and "mean" in m and "n" in m:
        return (m["mean"], m["n"])
    return None


def interpret_h(h: float) -> str:
    ah = abs(h)
    if ah < 0.2:
        return "small"
    if ah < 0.5:
        return "medium"
    return "large"


def run(baseline_path: str, candidate_path: str) -> int:
    with open(baseline_path) as f:
        baseline = json.load(f)
    with open(candidate_path) as f:
        candidate = json.load(f)

    baseline_ver = baseline.get("version", baseline_path)
    candidate_ver = candidate.get("version", candidate_path)

    print("=" * 72)
    print(f"pgmnemo significance_test.py")
    print(f"  Baseline : {baseline_ver}  ({baseline_path})")
    print(f"  Candidate: {candidate_ver}  ({candidate_path})")
    print("=" * 72)

    recall_keys = ["recall@1", "recall@5", "recall@10", "recall@20",
                   "recall@25", "recall@50"]
    other_keys = ["mrr"]
    all_keys = recall_keys + other_keys

    results = []
    for key in all_keys:
        b = extract_overall_metric(baseline, key)
        c = extract_overall_metric(candidate, key)
        if b is None or c is None:
            continue
        p1, n1 = b
        p2, n2 = c
        delta = p2 - p1
        z, p_raw = two_prop_z(p1, n1, p2, n2)
        h = cohens_h(p1, p2)
        lo1, hi1 = wilson_ci(round(p1 * n1), n1)
        lo2, hi2 = wilson_ci(round(p2 * n2), n2)
        results.append({
            "metric": key,
            "p1": p1, "n1": n1, "ci1": (lo1, hi1),
            "p2": p2, "n2": n2, "ci2": (lo2, hi2),
            "delta": delta,
            "z": z,
            "p_raw": p_raw,
            "h": h,
        })

    if not results:
        print("ERROR: No shared metrics found between the two files.")
        return 1

    # Holm-Bonferroni correction
    raw_ps = [r["p_raw"] for r in results]
    corrected_ps = holm_bonferroni(raw_ps)
    for r, p_corr in zip(results, corrected_ps):
        r["p_corrected"] = p_corr
        r["significant"] = p_corr < 0.05

    # Print table
    header = f"{'Metric':<14} {'Base':>7} {'95% CI Base':>22} {'Cand':>7} {'95% CI Cand':>22} {'Δ':>7} {'z':>6} {'p_raw':>7} {'p_corr':>7} {'h':>6} {'|h|':>6} {'Sig?':>5}"
    print()
    print(header)
    print("-" * len(header))

    any_sig_improvement = False
    any_sig_regression = False

    for r in results:
        ci1_str = f"[{r['ci1'][0]:.4f},{r['ci1'][1]:.4f}]"
        ci2_str = f"[{r['ci2'][0]:.4f},{r['ci2'][1]:.4f}]"
        sig = "YES*" if r["significant"] else "no"
        direction = "+" if r["delta"] >= 0 else ""
        print(
            f"{r['metric']:<14} "
            f"{r['p1']:>7.4f} "
            f"{ci1_str:>22} "
            f"{r['p2']:>7.4f} "
            f"{ci2_str:>22} "
            f"{direction}{r['delta']:>6.4f} "
            f"{r['z']:>6.2f} "
            f"{r['p_raw']:>7.4f} "
            f"{r['p_corrected']:>7.4f} "
            f"{r['h']:>6.3f} "
            f"{interpret_h(r['h']):>6} "
            f"{sig:>5}"
        )
        if r["significant"] and r["delta"] > 0:
            any_sig_improvement = True
        if r["significant"] and r["delta"] < 0:
            any_sig_regression = True

    print()
    print("Note: p_corr uses Holm-Bonferroni correction across all metrics in this run.")
    print("      Significant = p_corr < 0.05")
    print("      Cohen's h: <0.2 small, 0.2-0.5 medium, >0.5 large")
    print()

    # Summary
    sig_improvements = [r for r in results if r["significant"] and r["delta"] > 0]
    sig_regressions = [r for r in results if r["significant"] and r["delta"] < 0]
    ns_changes = [r for r in results if not r["significant"] and abs(r["delta"]) > 0.001]

    print("SUMMARY")
    print("-------")
    if sig_improvements:
        print("Significant improvements (p_corr < 0.05):")
        for r in sig_improvements:
            print(f"  {r['metric']}: +{r['delta']*100:.2f}pp  p_corr={r['p_corrected']:.4f}  h={r['h']:.3f} ({interpret_h(r['h'])})")
    else:
        print("Significant improvements: none")

    if ns_changes:
        print("Non-significant changes (within noise):")
        for r in ns_changes:
            sign = "+" if r["delta"] >= 0 else ""
            print(f"  {r['metric']}: {sign}{r['delta']*100:.2f}pp  p_corr={r['p_corrected']:.4f}  (ns)")

    if sig_regressions:
        print("Significant REGRESSIONS (p_corr < 0.05):")
        for r in sig_regressions:
            print(f"  {r['metric']}: {r['delta']*100:.2f}pp  p_corr={r['p_corrected']:.4f}  h={r['h']:.3f} ({interpret_h(r['h'])})")
    else:
        print("Significant regressions: none")

    print()
    if sig_regressions:
        print("VERDICT: HOLD — significant regression(s) detected.")
        return 1
    elif sig_improvements:
        print("VERDICT: candidate shows significant improvements on listed metrics.")
        print("         Apply decision matrix (RELEASE_PROCESS.md §5) for ship/hold.")
        return 0
    else:
        print("VERDICT: No significant improvements or regressions. Candidate is neutral.")
        print("         May ship without performance claims (RELEASE_PROCESS.md §5 row 4).")
        return 0


if __name__ == "__main__":
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <baseline_metrics.json> <candidate_metrics.json>")
        sys.exit(2)
    sys.exit(run(sys.argv[1], sys.argv[2]))
