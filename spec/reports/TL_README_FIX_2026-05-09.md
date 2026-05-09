# TL Report — README-FIX: Remove Duplicate Benchmarks Section

**Author:** Technical Lead  
**Date:** 2026-05-09  
**Task:** README-FIX — Remove duplicate Benchmarks section with deprecated turn-level + BM25-mislabeled-as-pgmnemo numbers  
**Priority:** P1  
**Deadline:** 2026-05-11  
**Status:** COMPLETE — fixed in place

---

## 1. Problem Diagnosis

### Problem 1 — Deprecated turn-level LoCoMo numbers (README lines 104–124)

**File:** `README.md` lines 104–124 (second `## Benchmarks` section)  
**Specific violation:** recall@10 = **0.366** cited as the LoCoMo result  
**Canonical value:** **0.795** (session-level, per `benchmarks/HISTORY.md` 2026-05-09 correction)  
**Evidence:** `benchmarks/locomo/results/v0.2.1_20260509/DEPRECATED.md` exists — that result directory is explicitly marked deprecated  
**Magnitude:** −43pp delta; citing deprecated number understates system performance by nearly half

### Problem 2 — BM25 baseline mislabeled as pgmnemo (README lines 126–142)

**File:** `README.md` lines 126–142  
**Specific violation:** LongMemEval recall@10 = **0.982** with caption "BM25 retrieval (no LLM, no embedding API)" presented inside a section called `## Benchmarks` with no pgmnemo label — structurally readable as a pgmnemo result  
**Source:** `benchmarks/longmemeval/results/v0.2.1_20260509/` — the BM25 baseline run, not the pgmnemo vector run  
**Canonical pgmnemo result:** recall@10 = **0.933** (`v0.2.1_pgmnemo_20260509/`)  
**Methodological error:** mixing baseline numbers with system-under-test numbers in an unlabeled table

### Root cause

A parallel agent appended a second `## Benchmarks` section at line 104. The first section (lines 12–27) already contained the correct canonical numbers with proper labeling. The duplicate section pulled from the deprecated and BM25-only result directories.

---

## 2. Fix Applied

**Action:** Deleted lines 104–142 in full (the entire second `## Benchmarks` section).

**Before:** 2 occurrences of `## Benchmarks` in README.md  
**After:** 1 occurrence — `## Benchmarks (v0.2.1, retrieval-only)` at line 12

**Verification grep results:**
```
grep "## Benchmarks" README.md
→ 12:## Benchmarks (v0.2.1, retrieval-only)   ← only one hit

grep "0\.366\|v0\.2\.1_20260509" README.md
→ none found
```

### Surviving canonical section (lines 12–27) — content audit

| Benchmark | Cited value | Source | Status |
|-----------|-------------|--------|--------|
| LoCoMo recall@10 | **0.795** | `v0.2.1_session_20260509/metrics.json` | ✓ canonical session-level |
| LoCoMo MRR | **0.548** | same | ✓ canonical |
| LongMemEval recall@10 | **0.933** | `v0.2.1_pgmnemo_20260509/metrics.json` | ✓ pgmnemo vector run |
| LongMemEval MRR | **0.855** | same | ✓ canonical |
| BM25 baseline | **0.982** | cited as "BM25 baseline²" in Comparison column | ✓ correctly labeled as comparison |

All four numbers match `benchmarks/HISTORY.md` 2026-05-09 canonical entries. BM25 0.982 appears only in the "Comparison" column with a footnote explicitly labeling it as a pure-Python BM25 baseline — methodologically correct.

---

## 3. Evidence Threshold Checklist

- [x] README has exactly ONE `## Benchmarks` section
- [x] All cited numbers are canonical (per `benchmarks/HISTORY.md` 2026-05-09)
- [x] No turn-level LoCoMo result (0.366) cited anywhere in README
- [x] BM25 0.982 labeled as baseline in Comparison column, not as pgmnemo result
- [x] No link to deprecated `v0.2.1_20260509/` result directory in README

---

## 4. Self-Evaluation

**What worked:** The fix was a clean deletion — no content needed to be written because the correct canonical section already existed at the top of the file. Zero risk of introducing new errors.

**What to improve:**  
- The parallel agent that introduced the duplicate had no gate preventing it from appending a second `## Benchmarks` heading. A pre-commit lint rule checking for duplicate H2 headings in README.md would prevent recurrence.  
- The deprecated `v0.2.1_20260509/` directory still exists and its `DEPRECATED.md` marker could be made more prominent (e.g. a `.gitattributes` export-ignore or a README-level warning comment) to reduce the chance of future agents pulling from it.
