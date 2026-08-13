"""Reproduce every number published for the mem-AB-v3 three-arm experiment.

    python analyze.py            # reads runs.csv next to this script

runs.csv is a de-identified export of real agent runs: one row per run, no task
identifiers, no role names, no project names. It is exported from the fleet's
run table, never synthesised. Standard library only, so the numbers can be
checked without installing anything.

Arms
    A  recall disabled
    B  recall always on (control)
    C  selective + typed recall
"""
import csv
import math
import pathlib
from collections import defaultdict

HERE = pathlib.Path(__file__).parent
ARMS = [("A", "recall off"), ("B", "recall always on"), ("C", "selective + typed")]


def load(path=HERE / "runs.csv"):
    by_arm = defaultdict(list)
    with open(path, newline="") as fh:
        for row in csv.DictReader(fh):
            by_arm[row["arm"]].append(row)
    return by_arm


def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def numeric(rows, field):
    return [float(r[field]) for r in rows if r[field] not in ("", None)]


def welch(a, b):
    """Welch's t-test. Returns (t, df, two-tailed p)."""
    na, nb = len(a), len(b)
    ma, mb = mean(a), mean(b)
    va = sum((x - ma) ** 2 for x in a) / (na - 1)
    vb = sum((x - mb) ** 2 for x in b) / (nb - 1)
    se = math.sqrt(va / na + vb / nb)
    t = (ma - mb) / se
    df = (va / na + vb / nb) ** 2 / (
        (va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1)
    )
    return t, df, 2 * student_sf(abs(t), df)


def student_sf(t, df):
    """Upper-tail probability of Student's t, via the incomplete beta function."""
    x = df / (df + t * t)
    return 0.5 * betainc(df / 2, 0.5, x)


def betainc(a, b, x):
    if x <= 0:
        return 0.0
    if x >= 1:
        return 1.0
    lbeta = math.lgamma(a) + math.lgamma(b) - math.lgamma(a + b)
    front = math.exp(a * math.log(x) + b * math.log(1 - x) - lbeta) / a
    if x < (a + 1) / (a + b + 2):
        return front * _cf(a, b, x)
    return 1 - math.exp(
        b * math.log(1 - x) + a * math.log(x) - lbeta
    ) / b * _cf(b, a, 1 - x)


def _cf(a, b, x, iters=300):
    """Lentz's continued fraction for the incomplete beta."""
    tiny = 1e-30
    f, c, d = 1.0, 1.0, 0.0
    for i in range(iters + 1):
        m = i // 2
        if i == 0:
            num = 1.0
        elif i % 2 == 0:
            num = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
        else:
            num = -((a + m) * (a + b + m) * x) / ((a + 2 * m) * (a + 2 * m + 1))
        d = 1 + num * d
        d = tiny if abs(d) < tiny else d
        d = 1 / d
        c = 1 + num / c
        c = tiny if abs(c) < tiny else c
        delta = c * d
        f *= delta
        if abs(delta - 1) < 1e-12:
            break
    return f - 1


def chi2_2x2(a, b, c, d):
    """Pearson chi-square on a 2x2 table, plus its 1-dof p-value."""
    n = a + b + c + d
    denom = (a + b) * (c + d) * (a + c) * (b + d)
    if denom == 0:
        return float("nan"), float("nan")
    chi2 = n * (a * d - b * c) ** 2 / denom
    return chi2, math.erfc(math.sqrt(chi2 / 2))


def main():
    by_arm = load()

    print("Arm summary")
    print("-" * 72)
    stats = {}
    for key, label in ARMS:
        rows = by_arm.get(key, [])
        succ = sum(1 for r in rows if r["outcome"] == "success")
        turns = numeric(rows, "turns")
        cost = numeric(rows, "cost_usd")
        stats[key] = dict(n=len(rows), succ=succ, turns=turns, cost=cost)
        print(
            f"{key} ({label:<19}) n={len(rows):>3}  "
            f"success={succ / len(rows) * 100:5.1f}% ({succ}/{len(rows)})  "
            f"turns={mean(turns):6.2f}  cost=${mean(cost):.4f}"
        )

    print("\nPairwise success-rate comparisons (chi-square, 1 dof)")
    print("-" * 72)
    raw_p = {}
    for x, y in (("A", "B"), ("B", "C"), ("A", "C")):
        sx, sy = stats[x], stats[y]
        chi2, p = chi2_2x2(
            sx["succ"], sx["n"] - sx["succ"], sy["succ"], sy["n"] - sy["succ"]
        )
        raw_p[(x, y)] = p
        print(f"{x} vs {y}:  chi2={chi2:6.3f}  p={p:.4f}")

    print("\nBonferroni correction for the three pairwise tests")
    print("-" * 72)
    for pair, p in raw_p.items():
        adj = min(1.0, p * 3)
        verdict = "significant" if adj < 0.05 else "NOT significant"
        print(f"{pair[0]} vs {pair[1]}:  p={p:.4f} -> {adj:.4f}  {verdict}")

    print("\nCost and turns (Welch's t, two-tailed)")
    print("-" * 72)
    for x, y in (("A", "B"), ("B", "C")):
        for field in ("cost", "turns"):
            t, df, p = welch(stats[x][field], stats[y][field])
            print(f"{field:<5} {x} vs {y}:  t={t:6.3f}  df={df:6.1f}  p={p:.4f}")

    print("\nPre-registration status")
    print("-" * 72)
    print("Primary metric   : arm C cost vs arm B cost. Pre-registered.")
    print("Target sample    : 400 completed runs per arm.")
    actual = ", ".join("%s=%d" % (k, stats[k]["n"]) for k, _ in ARMS)
    print("Actual sample    : " + actual)
    print("The A-vs-B comparison was NOT pre-registered. Report it as a first")
    print("signal with its Bonferroni-adjusted p-value attached, never alone.")


if __name__ == "__main__":
    main()
