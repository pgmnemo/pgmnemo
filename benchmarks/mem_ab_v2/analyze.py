"""Reproduce every number published for the second memory experiment (mem-AB-v2).

    python analyze.py            # reads runs.csv next to this script

runs.csv is a de-identified export of real agent runs: one row per terminal run,
no task identifiers, no role names, no project names, no failure classes. It is
exported from the fleet's run table, never synthesised. Standard library only, so
the numbers can be checked without installing anything.

Arms
    treat    the retrieved lessons are put into the agent's prompt
    control  they are not. Search and write of memory stay available to the agent
             during the run, so control is "no injected memory", NOT "no memory".

Columns
    run_id, arm, week (0-based 7-day block from 2026-08-13), outcome (success =
    run completed), infra_failure (0/1, run ended on an infrastructure fault),
    turns, cost_usd, retrieved_count (lessons recall returned; computed in both
    arms, injected only in treat), citation_line (0/1, the run's final report
    contains the line that lists which injected lessons it used).

Also reads ../mem_ab_v3/runs.csv (experiment 1) to pool the two experiments.
"""
import csv
import hashlib
import math
import pathlib
from collections import defaultdict

HERE = pathlib.Path(__file__).parent
EXP1 = HERE.parent / "mem_ab_v3" / "runs.csv"
Z975 = 1.959963984540054
Z80 = 0.8416212335729143


# ---------------------------------------------------------------- basics
def load(path):
    with open(path, newline="") as fh:
        return list(csv.DictReader(fh))


def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def median(xs):
    s = sorted(xs)
    n = len(s)
    return float("nan") if n == 0 else (s[n // 2] if n % 2 else (s[n // 2 - 1] + s[n // 2]) / 2)


def num(rows, field):
    return [float(r[field]) for r in rows if r[field] not in ("", None)]


def norm_p(z):
    """Two-tailed p for a standard normal statistic."""
    return math.erfc(abs(z) / math.sqrt(2))


def prop_test(x1, n1, x2, n2):
    """Two-proportion z-test (pooled SE) and unpooled Wald 95% CI for p1 - p2."""
    p1, p2 = x1 / n1, x2 / n2
    pool = (x1 + x2) / (n1 + n2)
    se0 = math.sqrt(pool * (1 - pool) * (1 / n1 + 1 / n2))
    z = (p1 - p2) / se0 if se0 else float("nan")
    se = math.sqrt(p1 * (1 - p1) / n1 + p2 * (1 - p2) / n2)
    d = p1 - p2
    return dict(p1=p1, p2=p2, diff=d, se=se, z=z, p=norm_p(z),
                lo=d - Z975 * se, hi=d + Z975 * se)


def mde(n1, n2, p):
    """Smallest true difference detectable with 80% power, alpha 0.05 two-sided,
    around a base rate p (normal approximation)."""
    return (Z975 + Z80) * math.sqrt(p * (1 - p) * (1 / n1 + 1 / n2))


def cohens_h(p1, p2):
    return 2 * math.asin(math.sqrt(p1)) - 2 * math.asin(math.sqrt(p2))


def student_sf(t, df):
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
    return 1 - math.exp(b * math.log(1 - x) + a * math.log(x) - lbeta) / b * _cf(b, a, 1 - x)


def _cf(a, b, x, iters=300):
    tiny = 1e-30
    f, c, d = 1.0, 1.0, 0.0
    for i in range(iters + 1):
        m = i // 2
        if i == 0:
            num_ = 1.0
        elif i % 2 == 0:
            num_ = m * (b - m) * x / ((a + 2 * m - 1) * (a + 2 * m))
        else:
            num_ = -((a + m) * (a + b + m) * x) / ((a + 2 * m) * (a + 2 * m + 1))
        d = 1 + num_ * d
        d = tiny if abs(d) < tiny else d
        d = 1 / d
        c = 1 + num_ / c
        c = tiny if abs(c) < tiny else c
        delta = c * d
        f *= delta
        if abs(delta - 1) < 1e-12:
            break
    return f - 1


def welch(a, b):
    na, nb = len(a), len(b)
    ma, mb = mean(a), mean(b)
    va = sum((x - ma) ** 2 for x in a) / (na - 1)
    vb = sum((x - mb) ** 2 for x in b) / (nb - 1)
    se = math.sqrt(va / na + vb / nb)
    t = (ma - mb) / se
    df = (va / na + vb / nb) ** 2 / ((va / na) ** 2 / (na - 1) + (vb / nb) ** 2 / (nb - 1))
    return dict(diff=ma - mb, t=t, df=df, p=2 * student_sf(abs(t), df),
                lo=ma - mb - Z975 * se, hi=ma - mb + Z975 * se)


def cmh(strata):
    """Cochran-Mantel-Haenszel chi-square (no continuity correction) across strata of
    (x_treat, n_treat, x_control, n_control). Also the Mantel-Haenszel risk difference."""
    num_, var, w_sum, wd_sum = 0.0, 0.0, 0.0, 0.0
    for x1, n1, x2, n2 in strata:
        n = n1 + n2
        if n < 2 or n1 == 0 or n2 == 0:
            continue
        x = x1 + x2
        num_ += x1 - n1 * x / n
        var += n1 * n2 * x * (n - x) / (n * n * (n - 1))
        w = n1 * n2 / n
        w_sum += w
        wd_sum += w * (x1 / n1 - x2 / n2)
    chi2 = num_ * num_ / var
    return chi2, math.erfc(math.sqrt(chi2 / 2)), wd_sum / w_sum


# ---------------------------------------------------------------- report
def rule_arm(run_id):
    """The assignment rule: sha256 of the run id, first 12 hex digits, mod 10000,
    below 0.5 -> treat."""
    h = int(hashlib.sha256(str(int(run_id)).encode()).hexdigest()[:12], 16)
    return "treat" if (h % 10_000) / 10_000.0 < 0.5 else "control"


def split(rows):
    return ([r for r in rows if r["arm"] == "treat"], [r for r in rows if r["arm"] == "control"])


def succ(rows):
    return sum(1 for r in rows if r["outcome"] == "success")


def show_prop(label, t, c):
    r = prop_test(succ(t), len(t), succ(c), len(c))
    print(f"{label:<26} treat {r['p1']*100:5.1f}% ({succ(t)}/{len(t)})  "
          f"control {r['p2']*100:5.1f}% ({succ(c)}/{len(c)})  "
          f"diff {r['diff']*100:+5.1f} pp [{r['lo']*100:+5.1f}, {r['hi']*100:+5.1f}]  "
          f"z={r['z']:+.2f}  p={r['p']:.3f}  h={cohens_h(r['p1'], r['p2']):+.3f}")
    return r


def main():
    rows = load(HERE / "runs.csv")
    t, c = split(rows)
    print("mem-AB-v2: injected memory vs no injected memory (control keeps search/write)")
    print("=" * 100)
    print(f"runs: {len(rows)}  treat: {len(t)}  control: {len(c)}")
    bad = sum(1 for r in rows if rule_arm(r["run_id"]) != r["arm"])
    print(f"arm re-derived from run_id by the assignment rule: {len(rows) - bad} of {len(rows)} agree")
    if bad:
        raise SystemExit(f"{bad} rows disagree with the assignment rule")
    print("Assignment: sha256(run_id) hashed into two equal buckets. NOT pre-registered.")

    print("\n1. Share of runs that completed (two-proportion z, unpooled 95% CI)")
    print("-" * 100)
    r_all = show_prop("all terminal runs", t, c)
    tn = [r for r in t if r["infra_failure"] == "0"]
    cn = [r for r in c if r["infra_failure"] == "0"]
    r_non = show_prop("excluding infra failures", tn, cn)
    inf_t = len(t) - len(tn)
    inf_c = len(c) - len(cn)
    r_inf = prop_test(inf_t, len(t), inf_c, len(c))
    print(f"infra failure rate         treat {r_inf['p1']*100:5.1f}% ({inf_t}/{len(t)})  "
          f"control {r_inf['p2']*100:5.1f}% ({inf_c}/{len(c)})  "
          f"diff {r_inf['diff']*100:+5.1f} pp  p={r_inf['p']:.3f}")
    print("Note: excluding infra failures conditions on a post-assignment variable and was")
    print("      chosen after seeing the data. It is a sensitivity analysis, not the primary one.")

    print("\n2. Minimum detectable effect (80% power, alpha 0.05, two-sided)")
    print("-" * 100)
    print(f"all terminal runs        : {mde(len(t), len(c), (succ(t)+succ(c))/len(rows))*100:.1f} pp")
    nn = len(tn) + len(cn)
    print(f"excluding infra failures : {mde(len(tn), len(cn), (succ(tn)+succ(cn))/nn)*100:.1f} pp")

    print("\n3. Cost and turns (Welch t, two-tailed). Cost per run, USD.")
    print("-" * 100)
    for label, field in (("cost_usd", "cost_usd"), ("turns", "turns")):
        a, b = num(t, field), num(c, field)
        w = welch(a, b)
        print(f"{label:<9} treat mean {mean(a):7.3f} median {median(a):7.3f} | "
              f"control mean {mean(b):7.3f} median {median(b):7.3f} | "
              f"diff {w['diff']:+.3f} [{w['lo']:+.3f}, {w['hi']:+.3f}]  p={w['p']:.3f}")
    cost_t, cost_c = sum(num(t, "cost_usd")), sum(num(c, "cost_usd"))
    print(f"cost per completed run     treat {cost_t / succ(t):.3f}  control {cost_c / succ(c):.3f}")

    print("\n4. Did the two arms get different prompts? (substitution check)")
    print("-" * 100)
    for name, grp in (("treat", t), ("control", c)):
        rc = num(grp, "retrieved_count")
        cited = sum(1 for r in grp if r["citation_line"] == "1")
        zero = sum(1 for x in rc if x == 0)
        print(f"{name:<8} citation line in final report: {cited}/{len(grp)} = {cited/len(grp)*100:4.1f}%   "
              f"retrieved/run {mean(rc):.2f}   retrieved nothing {zero/len(rc)*100:4.1f}%  (n={len(rc)})")
    print("Retrieval is computed in both arms, so retrieved_count does not differ by design;")
    print("the citation line appears only when lessons were injected into the prompt.")
    late_t = [r for r in t if int(r["week"]) >= 1]
    late_c = [r for r in c if int(r["week"]) >= 1]
    ct = sum(1 for r in late_t if r["citation_line"] == "1")
    cc = sum(1 for r in late_c if r["citation_line"] == "1")
    print(f"from week 1 on (the line was only requested from then): treat {ct}/{len(late_t)} = "
          f"{ct/len(late_t)*100:.1f}%   control {cc}/{len(late_c)} = {cc/len(late_c)*100:.1f}%")
    print("weeks with any citation line (treat/control):")
    for wk in sorted({int(r["week"]) for r in rows}):
        wt = [r for r in t if int(r["week"]) == wk]
        wc = [r for r in c if int(r["week"]) == wk]
        ct = sum(1 for r in wt if r["citation_line"] == "1")
        cc = sum(1 for r in wc if r["citation_line"] == "1")
        print(f"  week {wk:>2}: treat {ct:>3}/{len(wt):<3}  control {cc:>3}/{len(wc):<3}")

    print("\n5. By week (week 0 starts 2026-08-13)")
    print("-" * 100)
    strata, shares = [], []
    for wk in sorted({int(r["week"]) for r in rows}):
        wt = [r for r in t if int(r["week"]) == wk]
        wc = [r for r in c if int(r["week"]) == wk]
        strata.append((succ(wt), len(wt), succ(wc), len(wc)))
        shares.append((len(wt) + len(wc), wk))
        pt = succ(wt) / len(wt) * 100 if wt else float("nan")
        pc = succ(wc) / len(wc) * 100 if wc else float("nan")
        print(f"week {wk:>2}: n={len(wt)+len(wc):>4} ({(len(wt)+len(wc))/len(rows)*100:4.1f}% of sample)  "
              f"treat {pt:5.1f}% ({len(wt)})  control {pc:5.1f}% ({len(wc)})")
    big_n, big_wk = max(shares)
    print(f"heaviest week: {big_wk} with {big_n} runs = {big_n/len(rows)*100:.1f}% of the sample")
    by_wk = {wk: n for n, wk in shares}
    pair_n, pair_wk = max((by_wk[k] + by_wk.get(k + 1, 0), k) for k in by_wk)
    print(f"heaviest two consecutive weeks: {pair_wk}-{pair_wk + 1} with {pair_n} runs = "
          f"{pair_n/len(rows)*100:.1f}% of the sample")
    chi2, p, mh = cmh(strata)
    print(f"Mantel-Haenszel across weeks: risk difference {mh*100:+.1f} pp, CMH chi2={chi2:.2f}, p={p:.3f}")
    rest_t = [r for r in t if int(r["week"]) != big_wk]
    rest_c = [r for r in c if int(r["week"]) != big_wk]
    show_prop(f"without week {big_wk}", rest_t, rest_c)
    show_prop("without week 0", late_t, late_c)
    only_t = [r for r in t if int(r["week"]) == big_wk]
    only_c = [r for r in c if int(r["week"]) == big_wk]
    show_prop(f"only week {big_wk}", only_t, only_c)

    print("\n6. Pooling with experiment 1 (arm B always-on vs arm A recall-off)")
    print("-" * 100)
    e1 = load(EXP1)
    a1 = [r for r in e1 if r["arm"] == "A"]
    b1 = [r for r in e1 if r["arm"] == "B"]
    r1 = show_prop("experiment 1 (B vs A)", b1, a1)
    r2 = r_all
    print(f"experiment 2 (treat vs control), all terminal runs: {r2['diff']*100:+.1f} pp, se {r2['se']*100:.2f}")
    w1, w2 = 1 / r1["se"] ** 2, 1 / r2["se"] ** 2
    pooled = (r1["diff"] * w1 + r2["diff"] * w2) / (w1 + w2)
    se_p = math.sqrt(1 / (w1 + w2))
    zp = pooled / se_p
    print(f"fixed-effect (inverse-variance) pooled difference: {pooled*100:+.1f} pp "
          f"[{(pooled-Z975*se_p)*100:+.1f}, {(pooled+Z975*se_p)*100:+.1f}]  z={zp:+.2f}  p={norm_p(zp):.3f}")
    q = (r1["diff"] - r2["diff"]) ** 2 / (r1["se"] ** 2 + r2["se"] ** 2)
    zd = (r1["diff"] - r2["diff"]) / math.sqrt(r1["se"] ** 2 + r2["se"] ** 2)
    print(f"difference between the two effects: {(r1['diff']-r2['diff'])*100:+.1f} pp  "
          f"z={zd:+.2f}  Q={q:.2f} (1 dof)  p={norm_p(zd):.3f}")
    print("Caveats: the arms are not the same contrast (experiment 1 control = recall off;")
    print("experiment 2 control = recall computed and available but not injected); the pooled")
    print("figure assumes a common effect, which the difference test above questions.")

    print("\nPre-registration status")
    print("-" * 100)
    print("Experiment 2 was NOT pre-registered. No primary metric, sample size or stopping")
    print("rule was fixed before the data were read. The completion rate above is the")
    print("comparison that experiment 1 reported; the infra-excluded variant was added later.")


if __name__ == "__main__":
    main()
