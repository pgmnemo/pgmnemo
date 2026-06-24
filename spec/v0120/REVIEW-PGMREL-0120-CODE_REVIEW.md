# PGMREL-0120 Code Review Verdict
**Phase:** CODE_REVIEW  
**Version:** pgmnemo 0.12.0 — Typed Write API  
**Branch:** integration/0.12.0  
**Reviewer:** Chief Architect  
**Date:** 2026-06-24  
**Prior phase:** PACKAGE_VERIFY (a5dabbf) — all 7 dist-shape gates PASS

---

## Verdict: BLOCKED — P0 + P1 unresolved

Functional correctness of the implementation is PASS (all 7 ADDENDUM-2 requirements verified).
Release is **blocked** by two P0 build-system failures and two carry-over P1 confidentiality issues.

---

## P0 Blockers (release cannot proceed)

### P0-1 — Makefile EXTVERSION wrong

**File:** `Makefile:2`  
**Current:** `EXTVERSION = 0.11.0`  
**Required:** `EXTVERSION = 0.12.0`

Release spec: "Makefile (EXTVERSION+DATA+REGRESS with new tests)". The control file is already at `default_version = '0.12.0'` but the Makefile lags. Any PGXS packaging target that uses `$(EXTVERSION)` will produce the wrong version label. Violates explicit release mechanics requirement.

**Fix:** `sed -i 's/EXTVERSION   = 0.11.0/EXTVERSION   = 0.12.0/' Makefile`

---

### P0-2 — Makefile REGRESS missing 0.12.0 tests + wrong inputdir

**File:** `Makefile:9-10`  
**Current:**
```
REGRESS      = test_v071 test_v080 test_v0110_typed_recall
REGRESS_OPTS = --inputdir=tests --load-extension=vector --load-extension=$(EXTENSION)
```

Three 0.12.0 test suites exist with passing expected files:
- `extension/sql/test_remember_fact.sql` + `extension/expected/test_remember_fact.out`
- `extension/sql/test_v0120.sql` + `extension/expected/test_v0120.out`
- `extension/sql/typed_recall_fast.sql` + `extension/expected/typed_recall_fast.out`

But `--inputdir=tests` points to `tests/sql/` + `tests/expected/`, where these files do NOT reside. As a result `make installcheck` will NOT run the 0.12.0 tests.

The bench gate file claims `new_regress_tests: ["typed_recall_fast", "test_remember_fact"]` and the installcheck report says "65/65 PASS" — but that was via psycopg2 direct SQL, not `make installcheck`. The spec explicitly requires: **"make installcheck 'All N passed' (full REGRESS incl remember_* tests, not side-harness)"**. This gate is unverified.

**Fix options (pick one):**
1. Move `extension/sql/test_remember_fact.sql`, `test_v0120.sql`, `typed_recall_fast.sql` + their expected files into `tests/sql/` and `tests/expected/`, then add them to `REGRESS`.
2. OR: change `REGRESS_OPTS --inputdir` to `extension` and move the existing old tests (test_v071, test_v080, test_v0110_typed_recall) to `extension/sql/` + `extension/expected/` (more disruptive).
3. OR: keep `--inputdir=tests` and copy expected files there, update REGRESS to add new names.

Recommended: option 1 (least disruptive).

After the fix, run `make installcheck` against a real Docker pg17 and verify all tests pass before tagging.

---

## P1 Blockers (must resolve before `git tag v0.12.0`)

### P1-1 — G-CONFIDENTIALITY: `design/RECONCILE_0.11.0.md` contains internal identifiers (UNRESOLVED)

Lines 4-5 have been partially scrubbed in the working tree (not committed). Lines 60, 82, 117 still contain:
- Line 60: `PGMREL-0101 series`
- Line 82: `MEM-ERA-W1 addendum (salvage)`
- Line 117: `MEM-ERA-W1 reconciliation complete.`

Rule: "NO MEM-ERA reports" + "NO agency-ids" in public repo (G-CONFIDENTIALITY).

**Fix:** Complete the scrub started in the working tree:
- Line 60: replace `PGMREL-0101 series` → `prior release commits`
- Line 82: replace `MEM-ERA-W1 addendum (salvage):` → `Draft reconstructed and committed at`
- Line 117: replace `MEM-ERA-W1 reconciliation complete.` → `Branch reconciliation complete.`
Then stage and commit all changes to the file.

---

### P1-2 — G-CONFIDENTIALITY: `extension/sql/typed_write_api.sql` contains internal identifiers (UNRESOLVED)

- Line 3: `-- Reconstructed from context for MEM-ERA-W1 salvage (original was uncommitted, lost).`
- Line 20: `-- Status: DRAFT (uncommitted — recreated for W2 from MEM-ERA-W1 salvage)`

This file is NOT in Makefile DATA and has no runtime impact, but it is tracked in the public repo.

**Fix (either):**
1. Scrub: replace `MEM-ERA-W1 salvage` → `design reference only`; replace `recreated for W2 from MEM-ERA-W1 salvage` → `design reference only`.
2. Or remove the file: `git rm extension/sql/typed_write_api.sql` (the design intent is fully captured in RFC-001 + ADDENDUM-2; this file adds no value post-implementation).

---

## Functional Correctness: PASS (all 7 ADDENDUM-2 requirements)

Verified against `extension/pgmnemo--0.12.0.sql` (flat, authoritative install path) and
`extension/pgmnemo--0.11.1--0.12.0.sql` (delta path). Source SQL `extension/sql/remember_fact.sql`
is stale but not in Makefile DATA — see N1 below.

| Req | Description | Evidence | Verdict |
|-----|-------------|---------|---------|
| R1 | PII-aware state routing inside function | flat:9894-9907; PII on `person:*` → `candidate` even with `system` source | ✅ |
| R2 | Non-NULL `artifact_hash` synthesis before gate | `COALESCE(p_artifact_hash, 'fact-'‖entity_key‖':'‖property)` at flat:9885-9886; NULL entity_key rejected first | ✅ |
| R3 | Dedup `(lower(topic), project_id)` FOR UPDATE; merge promotes; supersede uses `_evict_prior_lesson()` | flat:9911-9941; topic = `lower(entity_key)‖'/'‖lower(property)` per ADDENDUM-2; state promotion via CASE in UPDATE | ✅ |
| R4 | `ingest_entity` drop-in; `version_n=0` compat; `MIGRATION.md §C` | flat:9941 `COALESCE(version_n,0)+1`; `docs/MIGRATION.md §C` | ✅ |
| R5 | NULL embedding fail-open | `vector(1024) DEFAULT NULL`; T17 in installcheck | ✅ |
| R6 | `guard_no_test_project` blocks `project_id ≤ 100` | flat:9758-9774; T7+T8; all real-DB tests at `project_id=99999` | ✅ |
| R7 | `confidence` + `has_contact_pii` first-class inputs | params at flat:9842-9843; routing at flat:9889-9891 | ✅ |

---

## Release Artifact Gates

| Gate | File | Result |
|------|------|--------|
| Control `default_version` | `extension/pgmnemo.control:4` | `0.12.0` ✅ |
| Delta psql guard | `pgmnemo--0.11.1--0.12.0.sql:9` | `\echo … \quit` ✅ |
| Delta NOTICE version | `delta:11` | `RAISE NOTICE '…version 0.12.0…'` ✅ |
| Flat contains delta content | `pgmnemo--0.12.0.sql:9733-10127` | delta additions verbatim ✅ |
| `uq_mem_edge_active` index | flat (prior) + delta:17-23 (`IF NOT EXISTS`) | both paths correct ✅ |
| `ix_entity_canonical_name_prj` | flat:9746; delta:25-35 | present ✅ |
| META.json version + file pointer | `META.json:5,14` | `0.12.0`, `extension/pgmnemo--0.12.0.sql` ✅ |
| pyproject.toml (root) | `pyproject.toml:7` | `0.12.0` ✅ |
| pgmnemo_mcp pyproject.toml | `pgmnemo_mcp/pyproject.toml:7` | `0.12.0` ✅ |
| README badge | `README.md:16` | `version-0.12.0-blue.svg` ✅ |
| CHANGELOG entry | `CHANGELOG.md:18` | `## [0.12.0] — 2026-06-24` ✅ |
| Bench gate | `benchmarks/gate/v0.12.0.json` | `gate_status: PASS`, `gate_type: feature_smoke`, no recall claims ✅ |
| TG release notes | `docs/release_notes/v0.12.0_telegram.md` | Russian, parity framing, no `+Xpp` ✅ |
| **Makefile EXTVERSION** | `Makefile:2` | ❌ `0.11.0` — must be `0.12.0` (P0-1) |
| **Makefile REGRESS** | `Makefile:9` | ❌ missing 0.12.0 tests + wrong `--inputdir` (P0-2) |

---

## Test Evidence

| Suite | Tests | Result | Method |
|-------|-------|--------|--------|
| Real-DB `remember_fact` (psycopg2, pg17.10) | 33/33 | PASS | psycopg2 direct |
| Real-DB `remember_event` (psycopg2, pg17.10) | 28/28 | PASS | psycopg2 direct |
| Real-DB `remember_relation` (psycopg2, pg17.10) | 24/24 | PASS | psycopg2 direct |
| installcheck (Gates 1-4, psycopg2 equivalent) | 65/65 | PASS | psycopg2 direct |
| `make installcheck` (full pg_regress) | — | ❌ NOT RUN | Makefile points to wrong dir for 0.12.0 tests |

---

## Positioning / Honesty: PASS

- CHANGELOG [0.12.0]: "Typed structured writes are industry parity" — correct ✅
- TG notes: "Typed writes — это паритет" ✅
- No `+Xpp recall quality` claims anywhere ✅
- Differentiator stated correctly: in-Postgres single-plan, not the write API itself ✅

---

## Non-Blocking Notes

**N1 — Source SQL drift:** `extension/sql/remember_fact.sql` uses `':'` topic separator and omits state-promotion on merge, contradicting the compiled delta/flat (which correctly uses `'/'` and promotes per ADDENDUM-2 R3). File is not in Makefile DATA — zero runtime impact. Sync when file is next edited.

**N2 — MEM-ERA-0120 in SQL comments:** `extension/pgmnemo--0.11.1--0.12.0.sql:3` and `pgmnemo--0.12.0.sql:9737` contain `-- MEM-ERA-0120: Typed Write API`. Brief inline comments; not reports; P2 cleanup desired but not blocking.

**N3 — Flat file header mismatch:** `pgmnemo--0.12.0.sql` header says "Flat install: pgmnemo 0.11.1". P2 cosmetic.

**N4 — spec/v0120/ internal metadata:** RESEARCH_BRIEF and RISK_REGISTER contain `task_id: PGMREL-0120-RESEARCH`, `agent: research_supervisor`. Task IDs already in public commit log. P2.

---

## Required Actions Before Tag

1. **[P0-1]** Fix `Makefile EXTVERSION = 0.12.0`
2. **[P0-2]** Add 0.12.0 tests to Makefile REGRESS; fix inputdir; run real `make installcheck` on Docker pg17 — all tests must pass
3. **[P1-1]** Complete + commit scrub of `design/RECONCILE_0.11.0.md` lines 60, 82, 117
4. **[P1-2]** Scrub or remove `extension/sql/typed_write_api.sql` MEM-ERA lines
5. Commit all fixes to `integration/0.12.0`; re-run G-CONFIDENTIALITY check
6. Tag `v0.12.0` only after all four items are resolved and `make installcheck` reports all N passed
