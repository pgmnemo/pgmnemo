# TL Report: P0.5-BENCH-PROTOCOL — Canonical Recall Benchmark Protocol

**Date:** 2026-05-10
**Task:** P0.5-BENCH-PROTOCOL
**Priority:** P1
**Deadline:** 2026-05-19

---

## 1. Summary

Created `benchmarks/PROTOCOL.md` v1.0.0 — the frozen, canonical recall benchmark protocol for pgmnemo. Updated `README.md` Benchmarks section to link it. Release notes may now cite recall improvements with a protocol version reference.

---

## 2. Files Created / Modified

| File | Action | Description |
|------|--------|-------------|
| `benchmarks/PROTOCOL.md` | **Created** | Canonical protocol v1.0.0, frozen 2026-05-10 |
| `README.md:14` | **Modified** | Added PROTOCOL.md link in Benchmarks section |

---

## 3. PROTOCOL.md Coverage Assessment

| Deliverable | Covered | Location in PROTOCOL.md |
|-------------|---------|------------------------|
| Corpus definition — LongMemEval | ✓ | §2.1: sha256, split, 500-item taxonomy, download cmd |
| Corpus definition — LoCoMo | ✓ | §2.2 + §2.2.1: session-level rule, oracle coverage gate |
| Query generation | ✓ | §2.1 query taxonomy (6 question types, n=500) |
| Include/exclude unverified rule | ✓ | §5: 7-gate table; BLOCKED.md presence = exclude |
| Embedding source | ✓ | §3: bge-m3 (LME), DRAGON (LoCoMo), deviation rationale |
| Recall metric definition | ✓ | §4.1: recall@k binary fraction + MRR; SQL in §4.2 |
| Acceptable variance band | ✓ | §6: per-metric ± bounds + v0.2.1 baseline numbers |
| Release note citation template | ✓ | §8: required format includes protocol version |
| Protocol versioning | ✓ | §9: semver bump rules + HISTORY.md coupling |

---

## 4. Issues Found (bound to files/lines)

### ISSUE-1 (P1): BLOCKED.md present in both canonical result directories

**Files:**
- `benchmarks/locomo/results/v0.2.1_session_20260509/BLOCKED.md` — status: corpus validation done, execution environment unavailable
- `benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/` — `report.md` and `metrics.json` exist but `raw_judge_calls.jsonl` is absent (retrieval-only mode, no judge calls)

**Impact:** Per PROTOCOL.md §5 include/exclude rule, the BLOCKED.md in LoCoMo results means the LoCoMo recall@10=0.795 result is technically BLOCKED. The README badge and table cite it; this is a contradiction.

**Clarification from HISTORY.md:** The LoCoMo BLOCKED.md dates from a time when the DB was unavailable; the session-level metrics in `report.md` were computed via in-memory corpus extraction (no DB needed for retrieval oracle evaluation). The BLOCKED.md is stale.

**task_draft: CLEAN-LOCOMO-BLOCKED**
```
Title: Remove or resolve stale BLOCKED.md from locomo/results/v0.2.1_session_20260509/
File: benchmarks/locomo/results/v0.2.1_session_20260509/BLOCKED.md
Action: If metrics were computed correctly (in-memory oracle mode), remove BLOCKED.md
        and add a RESOLVED note to the report.md. If DB run is still needed, keep but
        update status to reflect which gate is blocking.
Priority: P1 (protocol §5 exclude rule applies to any result with BLOCKED.md)
Effort: 15 minutes investigation + 5 minutes file edit
```

### ISSUE-2 (P2): `longmemeval/results/v0.2.1_pgmnemo_20260509/metrics.json` missing `seed` and `judge_prompt_sha256`

**File:** `benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/metrics.json`

`metrics.json["seed"]` is `null` and `metrics.json["judge_prompt_sha256"]` is `null`. This is a retrieval-only run (no LLM judge used), which is valid — but the protocol requires these fields to be recorded or explicitly null with a rationale string.

**task_draft: FIX-METRICS-NULL-FIELDS**
```
Title: Add rationale strings for null seed/judge fields in LongMemEval metrics.json
File: benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/metrics.json
Action: Set seed to "42" (PYTHONHASHSEED was set per runner env) and
        judge_prompt_sha256 to "N/A — retrieval-only mode, no judge calls"
Priority: P2 (protocol audit compliance)
Effort: 5 minutes
```

### ISSUE-3 (P2): `benchmarks/longmemeval/` and `benchmarks/locomo/` have no `METHODOLOGY.md`

**Files checked:** Neither `benchmarks/longmemeval/METHODOLOGY.md` nor `benchmarks/locomo/METHODOLOGY.md` exist, despite `benchmarks/README.md:38-39` referencing them directly as live links.

**Impact:** README links to `longmemeval/METHODOLOGY.md` and `locomo/METHODOLOGY.md` are broken. An external adopter following the reproducibility guide will hit 404.

**task_draft: CREATE-BENCHMARK-METHODOLOGY-FILES**
```
Title: Create per-benchmark METHODOLOGY.md files from _TEMPLATE
Files: benchmarks/longmemeval/METHODOLOGY.md, benchmarks/locomo/METHODOLOGY.md
Action: Copy _TEMPLATE/METHODOLOGY.md, fill all [PLACEHOLDERs] using existing
        metrics.json + report.md data. These are already measured; filling is
        transcription work.
Priority: P2 (broken README links; external adopter can't follow guide)
Effort: 1-2 hours per file
```

### ISSUE-4 (P3): `benchmarks/README.md:39` links to `locomo/METHODOLOGY.md` but LoCoMo runner is `run_locomo.sh`, not `runner.py`

**File:** `benchmarks/README.md:39`

LoCoMo procedure in README §5.5 references `bash run_locomo.sh`, consistent with actual scripts. But the "Adding a New Benchmark" section (README:234) says "implement `runner.py`". LoCoMo has `run_locomo.sh` but no `runner.py`. When METHODOLOGY.md is created for LoCoMo, §5.7 template "Full Run" section will need updating to use `bash run_locomo.sh` instead of `python runner.py`.

---

## 5. Metrics

| Metric | Value |
|--------|-------|
| Protocol fields covered | 9/9 deliverables ✓ |
| README Benchmarks section updated | ✓ (README.md:14) |
| P1 blockers to citation compliance | 1 (BLOCKED.md in LoCoMo results) |
| Broken README links found | 2 (per-benchmark METHODOLOGY.md files missing) |
| Null fields in canonical metrics.json | 2 (seed, judge_prompt_sha256 in LME run) |
| task_drafts created | 3 (CLEAN-LOCOMO-BLOCKED, FIX-METRICS-NULL-FIELDS, CREATE-BENCHMARK-METHODOLOGY-FILES) |

---

## 6. Self-Evaluation

**What worked:** PROTOCOL.md covers all 7 required deliverable components (corpus definition, query generation, include/exclude rule, embedding source, metric definition, variance band) plus adds a formal release-note citation template and protocol versioning table. The variance band is grounded in actual v0.2.1 CI data from `metrics.json`. The session-level granularity rule (§2.2.1) encodes the most dangerous drift vector — the 43pp recall gap between session and turn extraction — directly into the frozen protocol so future runners can't silently repeat the bug.

**What to improve:** PROTOCOL.md §6 LoCoMo CI bounds are listed as "—" because the `locomo/results/v0.2.1_session_20260509/metrics.json` couldn't be parsed (empty file). A follow-up run should populate these with bootstrap CIs. The BLOCKED.md situation (ISSUE-1) means the evidence threshold ("external adopter can reproduce from PROTOCOL.md alone") is not yet fully met — that gate depends on resolving the LoCoMo BLOCKED.md before the deadline.
