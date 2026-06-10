<!-- SPDX-License-Identifier: Apache-2.0 -->
# WG RELEASE VOTE — pgmnemo 0.9.0

**Vote ID:** WG-VOTE-RELEASE-0.9.0-2026-06-10  
**Date:** 2026-06-10  
**Voter:** principal_investigator (77) — decision authority for release_decision gate  
**Branch:** release/0.9.0  
**Tag target:** v0.9.0  
**Investor:** NOT in loop — WG/PI gate only

---

## VERDICT: **GO ✅**

All 4 release gates GREEN. Proceed to `tag_publish`:
merge release/0.9.0 → main, tag v0.9.0, push, CI publishes.

---

## Gate Verification

### Gate 1 — POST-CREATE-EXTENSION smoke + upgrade chain

**Status: GREEN ✅**

Source: `research/INSTALLCHECK_0.9.0.md` (commit `d30eafb`)

- Fresh install (pgmnemo--0.9.0.sql): 18/18 assertions PASS
- Upgrade path (0.8.3 → 0.9.0 migration): 12/12 assertions PASS
- **Total: 30/30 PASS**

Verified:
- navigate_locate: 5-arg only (4-arg dropped), LEAST(length,50), project_id_filter isolation
- content_type / blob_ref / doc_ref: present, nullable
- GREATEST(k*4, _ef_search) + f.id ASC in recall_hybrid
- NULL-embedding ingest: verified_at IS NOT NULL (not ghost)
- Budget accounting: tokens_consumed max=50 per row at budget=2000

### Gate 2 — installcheck = 0 failures

**Status: GREEN ✅**

Same evidence as Gate 1. 30/30, 0 failures.

### Gate 3 — Code review APPROVE

**Status: GREEN ✅**

Source: `research/CODE_REVIEW_0.9.0.md` (commit `810eb49`)  
Verdict: GO-WITH-CONDITIONS. All REVIEW_0.9 concerns cleared:

| Concern | Status |
|---------|--------|
| C2: `GREATEST(k*4, _ef_search)` HNSW floor | CLEARED ✅ |
| C3: CHANGELOG behavioral warning + docstring | CLEARED ✅ |
| C5: navigate_locate O(n) deferral noted (ADR line 44) | CLEARED ✅ |
| C6: full function bodies in migration (no "copy from 0.8.3") | CLEARED ✅ |
| C7: `f.id ASC` tie-breaker | CLEARED ✅ |

Sole condition at code-review time was C1 benchmark — now resolved (Gate 4).

### Gate 4 — C1 Benchmark: recall_hybrid quality parity

**Status: GREEN ✅**

Source: `benchmarks/gate/v0.9.0.json` (host-executed by orchestrator)

| Metric | Old (full-n) | New (bounded CTE) | Δ | Gate criterion |
|--------|-------------|------------------|---|----------------|
| Recall@10 | 78.1% | **78.8%** | +0.6 pp | ≥ 55% ✅ |
| Top-10 Jaccard median | — | **1.00** | — | parity ✅ |
| Latency p50 | 39 ms | **13 ms** | −67% | — |
| Latency p95 | 64 ms | **22 ms** | −66% | — |
| Sign test | — | better=1 worse=0 | p=1.0 | |

Corpus: project_id 31337, 2500 active rows, 80 queries (MuSiQue controlled corpus).  
REVIEW_0.9 C1 criteria: new recall@10 ≥ 0.55 AND |delta| < 5pp. **Both met.**  
C2 ef_search-floor fix applied. #4 is cleared for release.

---

## Version-File Agreement

| File | Value | Status |
|------|-------|--------|
| `extension/pgmnemo.control` `default_version` | `0.9.0` | ✅ |
| `pyproject.toml` (root) `version` | `0.9.0` | ✅ |
| `pgmnemo_mcp/pyproject.toml` `version` | `0.9.0` | ✅ |
| `pgmnemo_mcp/pgmnemo_mcp/__init__.py` `__version__` | `0.5.0` ⚠️ | DISCREPANCY |
| `CHANGELOG.md` `## [0.9.0]` | present | ✅ |

**Discrepancy noted:** `pgmnemo_mcp/__init__.py` reports `__version__ = "0.5.0"` at runtime,
while its `pyproject.toml` declares `version = "0.9.0"`. The `pyproject.toml` is the
authoritative packaging version (used by `pip install`, `pkg_resources`, `importlib.metadata`).
The `__version__` string is a cosmetic runtime attribute that was not bumped.

**Disposition:** Non-blocking for extension release. The MCP package will install and publish
as 0.9.0 (correct). Runtime `__version__` mismatch is a bug to fix in 0.9.1 alongside
navigate_locate O(n). Logged as residual risk R1 below.

---

## Scope Shipped in 0.9.0

| # | Item | Status |
|---|------|--------|
| #1 | `navigate_locate` budget fix: `LEAST(length(lesson_text), 50)` | SHIPPED ✅ |
| #1b | `project_id_filter INT DEFAULT NULL` on `navigate_locate` | SHIPPED ✅ |
| #2 | `ingest()` NULL-embedding != ghost (`verified_at = NOW()` unconditional) | SHIPPED ✅ |
| #3 | `agent_lesson` columns: content_type / blob_ref / doc_ref (nullable TEXT) | SHIPPED ✅ |
| #4 | `recall_hybrid` O(n) → O(k log n) two bounded CTEs + C2 ef_search floor + C7 tie-breaker | SHIPPED ✅ |

### Deferred to 0.9.1

| Item | Reason |
|------|--------|
| `navigate_locate` O(n) fix (same two-CTE pattern) | LIMIT 200 adequate at current corpus size; ADR_0.9.0.md §table line 44 |
| `agent_lesson.content_type` dispatch (#5) | Gated on G1: ≥50% coverage, ≥3 distinct types |
| Typed `navigate_expand` deref (#6) | Gated on G1: same |
| `pgmnemo_mcp` `__version__` bump | Low-risk cosmetic; fix alongside navigate_locate O(n) |

---

## Residual Risk Register

| ID | Risk | Severity | Mitigation |
|----|------|----------|------------|
| R1 | `pgmnemo_mcp/__init__.py __version__ = "0.5.0"` (not bumped) | LOW | `importlib.metadata` reports 0.9.0 (from pyproject.toml). Fix in 0.9.1. |
| R2 | Hybrid-sweet-spot recall miss (C4): documents ranked ~55th in both vec and BM25 may be dropped by bounded CTEs | LOW | Jaccard median=1.00 at 80 queries on 2500-row corpus; quantified risk is empirically small. Monitor in production. |
| R3 | navigate_locate O(n) still present; at ~5k+ rows latency will grow | MODERATE | LIMIT 200 on `final_ranked` caps worst-case at current corpus size. Deferred to 0.9.1 with priority. |
| R4 | C1 corpus is 2500 rows (benchmark note: full-n timeout emerges at ~5k+ rows) | LOW | Gate criteria met. O(n) → O(k log n) win will compound at production scale. |
| R5 | #4 behavioral-change warning in CHANGELOG not labeled "Breaking" | LOW | Ranking may change for callers who depend on exact candidate sets. Documented in CHANGELOG [0.9.0] and function COMMENT. |

---

## Release Authorization

I, principal_investigator (agent 77), certify:

1. All 4 release gates are GREEN as of 2026-06-10.
2. The code on branch `release/0.9.0` matches the scope reviewed and tested.
3. No open blockers exist. Residual risks R1–R5 are logged and non-blocking.
4. C1 benchmark was host-executed by orchestrator per modified release fork-flow.

**Decision: GO**

**Action for orchestrator/release-engineer:**
```
git checkout main
git merge --no-ff release/0.9.0 -m "Merge release/0.9.0: pgmnemo v0.9.0"
git tag v0.9.0
git push origin main v0.9.0
# CI publishes to extension registry
```

*Note: investor/founder OSS-push gate remains; this WG vote authorizes the
technical release action (tag_publish). Public repository push requires founder sign-off.*
