# Evidence Reproduction Log — v0.17.0 QA (V1)

**Verified:** 2026-08-13
**Task:** PGMREL-0170-QA-V1-VERIFY-EVIDENCE-ARTIFACTS
**Method:** Run `python3 benchmarks/mem_ab_v3/analyze.py` (stdlib only, no third-party packages), compare every numeric claim in `docs/EVIDENCE.md` (section before `## Where we lose`) against script output.

---

## Script output

```
Arm summary
------------------------------------------------------------------------
A (recall off         ) n=150  success= 55.3% (83/150)  turns= 34.39  cost=$1.4082
B (recall always on   ) n=148  success= 66.9% (99/148)  turns= 27.81  cost=$1.2321
C (selective + typed  ) n=137  success= 55.5% (76/137)  turns= 34.49  cost=$1.1683

Pairwise success-rate comparisons (chi-square, 1 dof)
------------------------------------------------------------------------
A vs B:  chi2= 4.186  p=0.0407
B vs C:  chi2= 3.913  p=0.0479
A vs C:  chi2= 0.001  p=0.9808

Bonferroni correction for the three pairwise tests
------------------------------------------------------------------------
A vs B:  p=0.0407 -> 0.1222  NOT significant
B vs C:  p=0.0479 -> 0.1437  NOT significant
A vs C:  p=0.9808 -> 1.0000  NOT significant

Cost and turns (Welch's t, two-tailed)
------------------------------------------------------------------------
cost  A vs B:  t= 0.875  df= 224.5  p=0.3824
turns A vs B:  t= 1.858  df= 279.5  p=0.0642
cost  B vs C:  t= 0.385  df= 231.9  p=0.7007
turns B vs C:  t=-1.355  df= 198.7  p=0.1768

Pre-registration status
------------------------------------------------------------------------
Primary metric   : arm C cost vs arm B cost. Pre-registered.
Target sample    : 400 completed runs per arm.
Actual sample    : A=150, B=148, C=137
```

---

## Document claims vs script output

Tolerance: absolute |doc - script| <= 0.005.

| Claim in EVIDENCE.md | Script value | Delta | Pass |
|---|---|---|---|
| A n=150 | 150 | 0 | PASS |
| A 55.3% | 55.3% | 0 | PASS |
| A turns=34.39 | 34.39 | 0 | PASS |
| A cost=$1.4082 | $1.4082 | 0 | PASS |
| B n=148 | 148 | 0 | PASS |
| B 66.9% | 66.9% | 0 | PASS |
| B turns=27.81 | 27.81 | 0 | PASS |
| B cost=$1.2321 | $1.2321 | 0 | PASS |
| C n=137 | 137 | 0 | PASS |
| C 55.5% | 55.5% | 0 | PASS |
| C turns=34.49 | 34.49 | 0 | PASS |
| C cost=$1.1683 | $1.1683 | 0 | PASS |
| A vs B chi2=4.186 | 4.186 | 0 | PASS |
| A vs B p=0.041 | 0.0407 | 0.0003 | PASS |
| A vs B Bonf=0.122 | 0.1222 | 0.0002 | PASS |
| B vs C chi2=3.913 | 3.913 | 0 | PASS |
| B vs C p=0.048 | 0.0479 | 0.0001 | PASS |
| B vs C Bonf=0.144 | 0.1437 | 0.0003 | PASS |
| A vs C chi2=0.001 | 0.001 | 0 | PASS |
| A vs C p=0.981 | 0.9808 | 0.0002 | PASS |
| A vs C Bonf=1.000 | 1.0000 | 0 | PASS |
| cost A vs B p=0.38 | 0.3824 | 0.0024 | PASS |
| turns A vs B p=0.064 | 0.0642 | 0.0002 | PASS |
| cost B vs C p=0.70 | 0.7007 | 0.0007 | PASS |

**All 24 numeric claims verified. Zero failures.**

Numbers in EVIDENCE.md after `## Where we lose` are from separate retrieval benchmarks (LoCoMo, LongMemEval), not from analyze.py, and were excluded from this check.

---

## Stdlib-only verification

analyze.py imports: `csv`, `math`, `pathlib`, `collections.defaultdict` — all standard library. Ran to completion with exit code 0. No pandas, scipy, or third-party dependency required.

---

## Confidentiality (leak gate)

runs.csv columns: `run_id, arm, week, outcome, turns, cost_usd, retrieved_count, mean_cosine`

| Column | Assessment |
|---|---|
| run_id | Sequential integer — no real session or task IDs |
| arm | Categorical A/B/C — no identifying label |
| week | Integer week index — no date, no timestamp |
| outcome | success/failure — no task content, no role name |
| turns, cost_usd | Numeric metrics — no PII |
| retrieved_count, mean_cosine | Numeric metrics — no PII |

No role names, project names, production database names, or task identifiers present.

**Leak gate: GREEN**

---

## generate.py

`benchmarks/mem_ab_v3/generate.py` does **not exist** in the committed tree. The anti-fabrication gate (G1) confirmed no RNG-importing data-writing script is present in any registered benchmark directory.
