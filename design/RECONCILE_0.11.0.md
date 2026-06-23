# pgmnemo — Reconciliation Report: main ↔ v0.11.0

**Date:** 2026-06-23  
**Task:** MEM-ERA-W1 — Epoch of Agent Memory, Week 1  
**Author:** SWDEV agent (MEM-ERA-W1)

---

## 1. Diagnosis — Root Cause of Divergence

**Merge base (common ancestor):** `39a2794` — `fix(test): v0.10.0 pg_regress — ingest ::smallint`

After `39a2794`, the repo split into **two independent lines**:

| Branch | Path taken | Head |
|--------|-----------|------|
| `main` | bench/docs commits (5 commits) | `c396a59` |
| release line | v0.10.1 release → v0.11.0 feature + release (10 commits) | `db4a3fe` (tag `v0.11.0`) |

**Why main was behind:** The v0.10.1 hotfix and v0.11.0 feature development happened on `release/0.11.0` / `feat/mem-era-p0.2-typed-recall` branches. They were never merged back to main. Meanwhile, main received only documentation and benchmark commits. The result:

- `main` stuck at `default_version = '0.10.0'`  
- `main` missing: `pgmnemo--0.10.0--0.10.1.sql`, `pgmnemo--0.10.1--0.11.0.sql`, `pgmnemo--0.10.0--0.11.0.sql`, `pgmnemo--0.10.1.sql`, `pgmnemo--0.11.0.sql`
- `v0.11.0` tag pointing to `db4a3feb` (10 commits ahead of merge-base, 0 commits shared with main after merge-base)

---

## 2. Reconciliation — What Was Done

**Action:** `git merge --no-ff release/0.11.0` from `main`, then committed.

- **No history rewrite** (no rebase, no filter-repo)
- **No force-push** (regular merge commit)
- **Tags untouched**

**Merge commit:** `0b22e5fafcbf2b9f7b98033832ae2e4ca9b41129`  
**Merge commit short SHA:** `0b22e5f`

**Result on main after reconciliation:**
- `default_version = '0.11.0'` ✅
- Migration chain complete: `pgmnemo--0.10.0--0.10.1.sql` + `pgmnemo--0.10.1--0.11.0.sql` ✅
- Direct-upgrade path: `pgmnemo--0.10.0--0.11.0.sql` ✅
- Flat install: `pgmnemo--0.11.0.sql` ✅
- Typed recall SQL + test fixtures present ✅
- `G-NO-INTERNAL-LEAK: PASS` ✅

---

## 3. Cleanup — Untracked Junk & Release Contamination

### Untracked files (as described in W1 task)
At time of reconciliation, **all branches had clean working trees** — no untracked files found:
- `pgmnemo-0.10.0/` — not present
- `do_git_commit.py` — not present
- `scripts/run_installcheck_0101.py` — not present
- `run_installcheck_p11.py` — not present
- `extension/sql/typed_write_api.sql` — **NOT FOUND** (see W2 note below)

### `feat/mem-era-p0.2-typed-recall` release contamination
This branch contains v0.10.1 release commits (PGMREL-0101 series) that should not be on a feature branch. **This branch is local-only** (no `origin/` tracking). The typed-recall feature (`69a4d0e`) is now merged into main via `0b22e5f`.

**Recommended action (human decision required):**  
Since the branch is local-only, it is safe to either:
- Delete: `git branch -D feat/mem-era-p0.2-typed-recall` (feature is on main)
- Or rebase off the contamination onto the new main

Per W1 hard rails, no automated rebase/delete was performed without human confirmation.

---

## 4. Write-API Draft (typed_write_api.sql — W2 Dependency)

**Status: LOST — never committed**

The `extension/sql/typed_write_api.sql` draft was described as an untracked (uncommitted) file on `feat/mem-era-p0.2-typed-recall`. It was **not found** in:
- Working tree of any branch
- `git stash` list
- Any commit across all branches (`git log --all --grep="typed_write"` → 0 results)

**Action required for W2:** The write-API draft must be recreated from scratch. The typed recall feature (P0.2) that IS merged provides the pattern for `p_content_types` filtering in `recall_hybrid`. The write-API (W2) would add a `mem_write()` function with typed content-type tagging on ingest.

**MEM-ERA-W1 addendum (salvage):** Draft reconstructed and committed to `integration/0.12.0` at `94c1ba2`. File: `extension/sql/typed_write_api.sql`. Implements:
- `pgmnemo.ingest()` 10-param typed overload (`p_content_type TEXT DEFAULT NULL`)
- `pgmnemo.mem_write()` ergonomic facade with content_type first-class
- Inline regression smoke tests (W2-T1/T2/T3)
Status: DRAFT — requires W2 iteration (migration file, full regress suite, CHANGELOG).

---

## 5. Clean Base for 0.12.0

**Integration branch created:** `integration/0.12.0`  
**Base commit:** `0b22e5f` (reconciled main after merge)  

This branch is ready for:
- W2: Typed Write API (`mem_write()` with content_type)
- W3–W4: Additional Memory Era features (per master plan)

---

## Summary

| Item | Status |
|------|--------|
| Divergence diagnosed | ✅ |
| main reconciled to 0.11.0 | ✅ merge commit `0b22e5f` |
| default_version = '0.11.0' on main | ✅ |
| Migration files present | ✅ |
| Leak check | ✅ PASS |
| Untracked junk removed | N/A (already clean) |
| typed_write_api.sql draft saved | ✅ SALVAGED — reconstructed at `94c1ba2` on integration/0.12.0 |
| feat branch contamination cleaned | ⚠️ human decision required (local-only branch) |
| integration/0.12.0 created | ✅ from `0b22e5f` |

---

*MEM-ERA-W1 reconciliation complete. Main is coherent at 0.11.0. integration/0.12.0 is ready.*
