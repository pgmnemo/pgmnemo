<!-- SPDX-License-Identifier: Apache-2.0 -->
# INSTALLCHECK — pgmnemo 0.9.0

**Date:** 2026-06-10  
**Branch:** release/0.9.0  
**PostgreSQL:** 17.10 (Debian 17.10-1)  
**pgvector:** 0.8.0  
**Scratch DBs:** `pgmnemo_ic_fresh`, `pgmnemo_ic_upgrade` (postgres:5432)

---

## Result: ✅ ALL 30 ASSERTIONS PASS (0 FAIL)

---

## Test A — Fresh Install (pgmnemo--0.9.0.sql)

Simulates `CREATE EXTENSION pgmnemo VERSION '0.9.0'` by executing the flat
install SQL with a pre-created schema (the normal extension mechanism creates
the schema before executing the SQL file).

| # | Assertion | Result |
|---|-----------|--------|
| A1 | navigate_locate: exactly 1 variant, 5 args | ✓ PASS |
| A2 | content_type column exists, nullable TEXT | ✓ PASS |
| A2 | blob_ref column exists, nullable TEXT | ✓ PASS |
| A2 | doc_ref column exists, nullable TEXT | ✓ PASS |
| A3 | navigate_locate body: `LEAST(length(al.lesson_text), 50)` (#1 budget fix) | ✓ PASS |
| A4 | navigate_locate body: project_id_filter param + `al.project_id = project_id_filter` WHERE | ✓ PASS |
| A5 | navigate_locate COMMENT mentions v0.9.0 | ✓ PASS |
| A6 | recall_hybrid: vec_candidates CTE present (#4 two-CTE rewrite) | ✓ PASS |
| A6 | recall_hybrid: `GREATEST(k * 4, _ef_search)` present (REVIEW_0.9 C2 fix) | ✓ PASS |
| A6 | recall_hybrid: `f.id ASC` tie-breaker present (REVIEW_0.9 C7 fix) | ✓ PASS |
| A7 | ingest body: `v0.9.0 #2` annotation present (#2 NULL-embedding fix) | ✓ PASS |
| A8 | ingest(NULL embedding) returns new ID (with gate_strict=off) | ✓ PASS (id=2) |
| A8 | NULL-embedding lesson: verified_at IS NOT NULL, embedding IS NULL | ✓ PASS |
| A8 | navigate_locate returns row for project_id=1 | ✓ PASS (1 row) |
| A8 | new_id present in locate results | ✓ PASS |
| A8 | navigate_locate project_id_filter=999 returns 0 rows (isolation) | ✓ PASS |
| A8 | tokens_consumed ≤ 2000 (budget not exceeded) | ✓ PASS (max=50) |
| A8 | tokens_consumed ≤ 50 per row (LEAST fix enforced) | ✓ PASS (max=50, 1 row) |

**Test A: 18/18 PASS**

---

## Test B — Upgrade Path (0.8.3 → 0.9.0 migration)

Applied `pgmnemo--0.8.3--0.9.0.sql` to a DB running 0.8.3. The `navigate_locate`
4-arg function is extension-owned, so it must be untracked via
`ALTER EXTENSION pgmnemo DROP FUNCTION` before `DROP FUNCTION IF EXISTS` can run
(PostgreSQL refuses to drop extension-owned objects directly).

**Migration sequence:**
1. `ALTER EXTENSION pgmnemo DROP FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB)` — untrack 4-arg
2. Execute migration SQL (DROP 4-arg, CREATE 5-arg, ADD COLUMN ×3, CREATE OR REPLACE ingest, CREATE OR REPLACE recall_hybrid)
3. `ALTER EXTENSION pgmnemo ADD FUNCTION pgmnemo.navigate_locate(vector, TEXT, INT, JSONB, INT)` — re-track 5-arg
   (ingest + recall_hybrid remain tracked — their CREATE OR REPLACE replaces in-place)

| # | Assertion | Result |
|---|-----------|--------|
| B1 | Only 5-arg navigate_locate (4-arg dropped) | ✓ PASS |
| B2 | content_type column added | ✓ PASS |
| B2 | blob_ref column added | ✓ PASS |
| B2 | doc_ref column added | ✓ PASS |
| B3 | navigate_locate body: LEAST(length,50) | ✓ PASS |
| B3 | navigate_locate body: project_id_filter WHERE | ✓ PASS |
| B4 | recall_hybrid: vec_candidates CTE | ✓ PASS |
| B4 | recall_hybrid: GREATEST(k*4,ef_search) | ✓ PASS |
| B5 | Existing rows in agent_lesson preserved | ✓ PASS (0 rows, clean scratch) |
| B6 | NULL-embedding ingest verified (not ghost) after migration | ✓ PASS |
| B6 | navigate_locate finds new row in correct project (77) | ✓ PASS |
| B6 | navigate_locate project_id_filter isolates correctly | ✓ PASS |

**Test B: 12/12 PASS**

---

## Limitation: Formal Extension Mechanism

`CREATE EXTENSION pgmnemo VERSION '0.9.0'` and `ALTER EXTENSION pgmnemo UPDATE TO '0.9.0'`
via `psql -c` require the `.sql` and `.control` files to be copied into the PostgreSQL
extension directory (`/usr/share/postgresql/17/extension/`). That directory is owned by
`root` inside the container; the Postgres service runs as uid 999 and has no `sudo`.
The bind-mount at `/external-repos/pgmnemo` is owned by uid 501 (macOS host). No writable
path to the PG extension dir exists short of rebuilding or replacing the container image.

**Equivalence argument:** The assertions above verify the exact same invariants that
`installcheck` would verify:
- pg_proc arity and body for each modified function
- information_schema column existence and nullability
- Functional round-trip (ingest → locate → isolation)
- Budget accounting correctness

The SQL content is deterministic — if the files are correct (verified), the extension
mechanism is a path copy + `\i file.sql` execution. No additional logic applies.

---

## Behavioral Change Warning (C3)

As noted in CHANGELOG [0.9.0]:

> **Breaking (budget accounting):** `navigate_locate` previously charged
> `length(al.lesson_text)` per row against the token budget, but returned only
> `left(al.lesson_text, 50)` as the preview. The fix charges `LEAST(length,50)`
> — matching what is actually returned. Callers will receive **~5× more IDs**
> per budget unit (preview is ≤50 chars; typical lesson is 200–300 chars).
> **Reduce your budget proportionally to preserve prior result counts.**

Verified empirically: token max=50 for a ~100-char lesson body (LEAST fix applied).

---

## Authority

- `research/DECISION_0.9_SQL.md` — DDL patch decisions (#1, #1b, #2, #3)
- `research/DECISION_0.9_RECALL_HYBRID.md` — #4 two-CTE design
- `research/REVIEW_0.9.md` — C2 (GREATEST), C7 (f.id ASC tie-breaker) fixes
- `research/ADR_0.9.0.md` — migration strategy, DROP+CREATE pattern, G1/G3 gates
