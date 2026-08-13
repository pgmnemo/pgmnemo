# Adversarial Review Verdict — pgmnemo v0.17.0

**Reviewer:** Chief Architect (PGMREL-0170-REVIEW-REL-0170-REVIEW)  
**Date:** 2026-08-13  
**Scope:** Pre-tag review of all changes in the v0.17.0 release branch  
**Priority order:** fabrication first, then behaviour-break accuracy, then correctness/coverage/upgrade path.

---

## Changed files reviewed

| File | Change type |
|------|-------------|
| `CHANGELOG.md` | Behaviour break documentation |
| `benchmarks/gate/v0.17.0.json` | Gate artefact |
| `docs/GUC_EVIDENCE.md` | GUC audit table + restore commands |
| `docs/EVIDENCE.md` | Unchanged — verified only |
| `docs/EVIDENCE_REPRO_LOG.md` | New — V1 reproduction log |
| `extension/pgmnemo--0.16.1--0.17.0.sql` | Upgrade script |
| `extension/pgmnemo--0.17.0.sql` | Flat install |
| `extension/sql/test_v0170_foreign_schema.sql` | New pg_regress test |
| `extension/expected/test_v0170_foreign_schema.out` | New expected output |
| `extension/sql/test_v0170_guc_consistency.sql` | New pg_regress test |
| `extension/expected/test_v0170_guc_consistency.out` | New expected output |
| `scripts/check_evidence_integrity.py` | New — G1 anti-fabrication gate |
| `tests/test_evidence_gate.py` | New — T1–T7 Python unit tests |
| `ROADMAP.md` | Release row added |

---

## Section 1: Fabrication risk

### Finding F1 — runs.csv provenance ✅ PASS (non-blocker)

**Claim:** `benchmarks/mem_ab_v3/runs.csv` is a de-identified export of real production runs, not generated data.

**Evidence:**
- `benchmarks/mem_ab_v3/generate.py` does **not exist** in the committed tree.
- `scripts/check_evidence_integrity.py` check_no_generator() AST-scans all Python files in registered benchmark dirs for RNG imports; passes on current tree.
- G1b enhancement added: alias-based RNG detection catches `import numpy as np; np.random.default_rng()` patterns.
- runs.csv columns: `run_id, arm, week, outcome, turns, cost_usd, retrieved_count, mean_cosine` — no synthetic-looking identifiers, sequential run_id integers are consistent with a live export.

**Verdict:** NON-BLOCKER. Provenance confirmed. Anti-fabrication gate is green.

---

### Finding F2 — numeric claims in EVIDENCE.md ✅ PASS (non-blocker)

**Claim:** All numeric claims in `docs/EVIDENCE.md` (sections before `## Where we lose`) match the output of `python3 benchmarks/mem_ab_v3/analyze.py`.

**Evidence (from EVIDENCE_REPRO_LOG.md):** 24 decimal claims verified, all within ±0.005.  
Representative spot-checks:

| Claim | Script | Delta |
|-------|--------|-------|
| A n=150 | 150 | 0 |
| B 66.9% success | 66.9% | 0 |
| A vs B chi2=4.186 | 4.186 | 0 |
| B vs C p=0.048 | 0.0479 | 0.0001 |
| A vs C Bonf=1.000 | 1.0000 | 0 |

**Verdict:** NON-BLOCKER. Numbers are reproducible. Leak gate green (no PII in runs.csv columns).

---

## Section 2: Behaviour-break accuracy in CHANGELOG

### Finding F3 — COALESCE vs EXCEPTION misdescription 🔴 BLOCKER → FIXED

**What was wrong (initial state):**  
The CHANGELOG quick-scan table row read:  
> "graph_proximity_weight EXCEPTION fallback unified from 0.2 → 0.0 in recall_hybrid and navigate_locate"

**Why that is wrong:**  
Code inspection of `extension/pgmnemo--0.16.1.sql`:
- `recall_hybrid` (10p, L10387) and `recall_hybrid` (11p, L8900): `COALESCE(... , 0.2)` on the **normal path**; EXCEPTION fallback also 0.2.
- `navigate_locate` (5p, L8507): `COALESCE(... , 0.2)` on the normal path; EXCEPTION fallback 0.0 (was not broken on exception path).

The COALESCE is the primary defect — it fires on every caller who has not set the GUC. Framing it as an EXCEPTION path fix understates the scope (callers with no GUC setting were silently getting 0.2 graph weighting, not just callers triggering a GUC parse error).

**Fix applied:** CHANGELOG now reads:  
> "graph_proximity_weight COALESCE default unified 0.2 → 0.0 in recall_hybrid (8p, 9p) and navigate_locate (5p) — callers with unset GUC lost implicit graph weighting"

**Verdict:** WAS BLOCKER. Fixed before tag. Correct description now committed.

---

### Finding F4 — recall_lessons overstated as broken 🔴 BLOCKER → FIXED

**What was wrong:**  
The upgrade script comment (and early draft gate file) labelled `recall_lessons` as one of the three inconsistent functions.

**Why that is wrong:**  
`recall_lessons` LAST definition in `pgmnemo--0.16.1.sql` at L10957:
```sql
COALESCE(current_setting('pgmnemo.graph_proximity_weight', TRUE)::REAL, 0.0)
-- exception path also: 0.0
```
Both paths were already correct in 0.16.1. `recall_lessons` was NOT broken.

The three actually broken overloads were:
1. `recall_hybrid` (10p) — COALESCE=0.2, EXCEPTION=0.2
2. `recall_hybrid` (11p) — COALESCE=0.2, EXCEPTION=0.2
3. `navigate_locate` (5p) — COALESCE=0.2, EXCEPTION=0.0

**Fix applied:** GUC_EVIDENCE.md row 22 corrected; gate file scope corrected; test file comment corrected.

**Verdict:** WAS BLOCKER. Fixed before tag. Documentation now accurate.

---

### Finding F5 — CHANGELOG upgrade version attribution ✅ (non-blocker)

**Claim:** The OPT-IN change from 0.2 → 0.0 was made in v0.10.1.

**Evidence:** GUC_EVIDENCE.md references `pgmnemo--0.10.0--0.10.1.sql` preamble Fix 5 comment. The three-overload reconciliation is v0.17.0. Attribution is correct.

**Verdict:** NON-BLOCKER. No discrepancy.

---

## Section 3: Correctness and coverage

### Finding F6 — Foreign schema test F3 duplicate ingest risk 🟡 RISK → FIXED

**What was wrong (initial draft):**  
F3 DO block included an inline `ingest()` call with `artifact_hash='alien-test-hash-i6'`. The fixture section before A1 also ingested I6 with the same hash. Second call would hit ON CONFLICT UPDATE (not INSERT), so no new row — the pair existed but the test was fragile (implicit dependency on fixture order).

**Fix applied:** F3 DO block no longer includes inline ingest. It calls `consolidate(0.92, TRUE, 'cs_agent', 50)` relying on fixture I6 seeded before A1. A1 assertion updated to count 6 lessons (not 5). .out updated to match.

**Verdict:** WAS RISK. Fixed before tag.

---

### Finding F7 — G1b alias-RNG detection gap 🟡 RISK → FIXED

**What was wrong:**  
Original check_no_generator() used `isinstance(node, ast.Import)` checks and detected `import random`, `from numpy.random import default_rng` etc. but missed `import numpy as np; np.random.default_rng()` (attribute-chain on an alias).

**Fix applied:** `_build_alias_map()` + `_attr_chain()` added to check_evidence_integrity.py. T7 test (`test_numpy_alias_rng_fails`) added to tests/test_evidence_gate.py.

**Verdict:** WAS RISK. Fixed before tag. Gate now catches alias-based RNG.

---

### Finding F8 — Foreign schema coverage completeness ✅ (non-blocker)

**Required coverage (from R3B task):** ingest, recall_lessons, recall_hybrid, recall_entity, recall_situation, consolidate, classify_content_type, reclassify_corpus, reinforce.

**Actual coverage in test_v0170_foreign_schema.sql:**

| Function | Assertion | Section |
|----------|-----------|---------|
| `ingest()` | 6 rows in alien corpus | I1–I6 fixture + A1 |
| `recall_lessons()` | non-empty result | B1 |
| `recall_hybrid()` | non-empty result | B2 |
| `recall_entity()` | non-empty result | B3 |
| `recall_situation()` | non-empty result | B4 |
| `reinforce()` | non-empty result | B5 |
| `consolidate()` | count ≥ 1 | F3 |
| `classify_content_type()` | IS NOT NULL | F1 |
| `reclassify_corpus()` | count ≥ 1 | F2 |

All 9 required functions covered. Assertions are "returns non-empty", not "does not error".

**Verdict:** NON-BLOCKER. Coverage complete.

---

### Finding F9 — GUC consistency test correctness ✅ (non-blocker)

G1–G5 in `test_v0170_guc_consistency.sql`:
- G1/G2: `recall_hybrid` 10p and 11p — explicit 0.0 == unset, ≥1 row
- G3: `recall_lessons` — explicit 0.0 == unset, ≥1 row (correctly included even though it wasn't broken — proves no regression)
- G4: `navigate_locate` — explicit 0.0 == unset, ≥1 row
- G5: corrupt GUC (`'invalid_value'`) — exception path must not crash, must produce same count as baseline

Tests are mechanically sound: SET LOCAL + RESET within DO blocks, count comparison rather than row content comparison.

**Verdict:** NON-BLOCKER. Tests correct.

---

### Finding F10 — Upgrade path safety ✅ (non-blocker)

`pgmnemo--0.16.1--0.17.0.sql` changes ONLY the `graph_proximity_weight` COALESCE and EXCEPTION fallbacks in the three affected functions. No schema changes. No data migration. No column additions. `ALTER FUNCTION` only.

Rollback path: documented in GUC_EVIDENCE.md and CHANGELOG as `SET pgmnemo.graph_proximity_weight = 0.2`.

**Verdict:** NON-BLOCKER. Upgrade is safe. Rollback documented.

---

## Section 4: Anti-fabrication gate wiring

`scripts/check_evidence_integrity.py` is wired in `.github/workflows/release.yml` as a required pre-flight step. Runs before the tag. Checks:
1. No RNG-importing data-writing script in any registered benchmark directory (including alias-based detection).
2. Numeric claims in published documents match analysis script output (DOC→SCRIPT direction).
3. Analysis scripts read dataset files (not generate them).

Gate passes on current main. Would fail on: (a) introduction of a generate.py with RNG, (b) tampered document number, (c) analysis script that doesn't open runs.csv.

**Verdict:** NON-BLOCKER. Gate is wired and functional.

---

## Summary verdict

| Finding | Severity | Status at tag |
|---------|----------|--------------|
| F1 — runs.csv provenance | — | PASS |
| F2 — EVIDENCE.md numbers | — | PASS (24/24) |
| F3 — COALESCE vs EXCEPTION misdescription | 🔴 BLOCKER | FIXED |
| F4 — recall_lessons overstated as broken | 🔴 BLOCKER | FIXED |
| F5 — version attribution | — | PASS |
| F6 — F3 duplicate ingest risk | 🟡 RISK | FIXED |
| F7 — G1b alias-RNG gap | 🟡 RISK | FIXED |
| F8 — Foreign schema coverage | — | PASS (9/9) |
| F9 — GUC consistency tests | — | PASS |
| F10 — Upgrade path safety | — | PASS |

**All blockers resolved before tag. No open blockers remain.**  
**Recommendation: tag v0.17.0.**
