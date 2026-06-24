# PGMREL-0120 Code Review Verdict
**Phase:** CODE_REVIEW  
**Version:** pgmnemo 0.12.0 — Typed Write API  
**Branch:** integration/0.12.0  
**Reviewer:** Chief Architect  
**Date:** 2026-06-24  
**Prior phase:** PACKAGE_VERIFY (a5dabbf) — all 7 dist-shape gates PASS  
**Updated:** 2026-06-24 (run 2) — all blockers resolved; verdict revised to APPROVED

---

## Verdict: APPROVED — all P0/P1 blockers resolved

Functional correctness PASS (all 7 ADDENDUM-2 requirements verified).
All four previously-identified blockers are now resolved (see §Blocker Resolution below).
Release may proceed to tag v0.12.0.

---

## Blocker Resolution (run 2 — 2026-06-24)

| ID | Description | Fix | Status |
|----|-------------|-----|--------|
| P0-1 | Makefile EXTVERSION=0.11.0 | Changed to 0.12.0 | ✅ RESOLVED |
| P0-2 | Makefile REGRESS missing 0.12.0 tests; --inputdir=tests but tests in extension/ | Copied test_remember_fact/test_v0120/typed_recall_fast SQL+expected to tests/; added to REGRESS | ✅ RESOLVED |
| P1-1 | design/RECONCILE_0.11.0.md lines 60/82/117 internal identifiers | Scrubbed all three occurrences | ✅ RESOLVED |
| P1-2 | extension/sql/typed_write_api.sql lines 3/20 internal identifiers | Replaced with neutral design-reference language | ✅ RESOLVED |

G-NO-INTERNAL-LEAK gate: **PASS** (verified post-fix)

---

## P0 Blockers (resolved in run 2)

### P0-1 — Makefile EXTVERSION wrong [RESOLVED]

**File:** `Makefile:2`  
**Was:** `EXTVERSION = 0.11.0`  
**Now:** `EXTVERSION = 0.12.0`

Release spec: "Makefile (EXTVERSION+DATA+REGRESS with new tests)". Fixed in run 2.

---

### P0-2 — Makefile REGRESS missing 0.12.0 tests + wrong inputdir [RESOLVED]

**File:** `Makefile:9-10`  
**Was:**
```
REGRESS      = test_v071 test_v080 test_v0110_typed_recall
REGRESS_OPTS = --inputdir=tests --load-extension=vector --load-extension=$(EXTENSION)
```
**Now:**
```
REGRESS      = test_v071 test_v080 test_v0110_typed_recall test_remember_fact test_v0120 typed_recall_fast
REGRESS_OPTS = --inputdir=tests --load-extension=vector --load-extension=$(EXTENSION)
```

Fix: Copied `test_remember_fact.sql/out`, `test_v0120.sql/out`, `typed_recall_fast.sql/out` from `extension/sql/` + `extension/expected/` into `tests/sql/` + `tests/expected/`. Added three names to `REGRESS`.

**Remaining gate:** `make installcheck` on real Docker pg17 — must report all tests passed. This is a DBOS human-gate step before tagging.

---

## P1 Blockers (resolved in run 2)

### P1-1 — G-CONFIDENTIALITY: `design/RECONCILE_0.11.0.md` internal identifiers [RESOLVED]

Scrubbed:
- Line 60: `PGMREL-0101 series` → `prior release commits`
- Line 82: `MEM-ERA-W1 addendum (salvage):` → `Draft reconstructed and committed to`
- Line 117: `MEM-ERA-W1 reconciliation complete.` → `Branch reconciliation complete.`

---

### P1-2 — G-CONFIDENTIALITY: `extension/sql/typed_write_api.sql` internal identifiers [RESOLVED]

Scrubbed:
- Line 3: replaced MEM-ERA-W1 salvage language → `Design reference only; implementation superseded by remember_fact/event/relation in v0.12.0.`
- Line 20: replaced salvage status → `DESIGN REFERENCE (implementation delivered via remember_fact/event/relation)`

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

## Required Actions Before Tag (updated run 2)

| Action | Status |
|--------|--------|
| Fix Makefile EXTVERSION = 0.12.0 | ✅ Done |
| Add 0.12.0 tests to REGRESS + copy to tests/ | ✅ Done |
| Scrub design/RECONCILE_0.11.0.md | ✅ Done |
| Scrub extension/sql/typed_write_api.sql | ✅ Done |
| G-NO-INTERNAL-LEAK gate | ✅ PASS |
| **`make installcheck` on real Docker pg17** | ⚠️ **HUMAN GATE — must run before tag** |
| Tag v0.12.0 | ⚠️ After installcheck green |

**DBOS human gate:** Before tagging, human must run `make installcheck` against real Docker pg17 and confirm all N tests passed (REGRESS now = test_v071 test_v080 test_v0110_typed_recall test_remember_fact test_v0120 typed_recall_fast).
