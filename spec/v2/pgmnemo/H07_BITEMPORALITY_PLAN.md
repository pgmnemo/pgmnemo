---
hypothesis: H-07 — Bitemporality primitive on agent_lesson
date: 2026-05-17
priority: P1
due: 2026-05-22
status: PLAN COMPLETE — ready for IMPLEMENT
research_source: spec/v2/pgmnemo/H07_BITEMPORALITY_RESEARCH.md
target_file: extension/pgmnemo--0.4.1--0.5.0.sql
---

# H-07 Bitemporality Plan

## ICE Score

| Dimension | Score (1–10) | Rationale |
|-----------|-------------|-----------|
| **Impact** | **7** | Enables point-in-time queries (`as_of()`) and deduplication on ingest. Closes the `mem_item` ROADMAP gap. No recall regression expected (additive only). Primary use case: audit, knowledge-update detection, multi-agent conflict resolution. Not on the critical hot-path (recall scoring unaffected). |
| **Confidence** | **8** | `mem_edge` already uses the same `valid_from`/`valid_until` pattern (`extension/pgmnemo--0.4.1.sql:278–280`). DDL is proven pattern. `IF NOT EXISTS` guards make upgrade idempotent. Research identified all schema clarifications (`mem_item` → `agent_lesson` view, `content_hash` design, NULL-trigger edge case). |
| **Ease** | **8** | ~50 LOC pure SQL. No C extension changes. No recall-path modification. Full rollback in 8 SQL statements. One migration file append. Regression gate is structural (significance_test exit ≤ 1, no regression). |
| **ICE composite** | **7.7** | (I×C×E)^(1/3) ≈ 7.7. High confidence, high ease, solid impact — proceed. |

**GO/NO-GO: GO.** Evidence confidence: HIGH (all 9 research quality gates PASS).

---

## 1. Acceptance Gate

```
significance_test.py exit ≤ 1 on ALL benchmark cells (no significant regression).
```

**Operationalized:**
```bash
python scripts/significance_test.py \
  benchmarks/gate/v0.4.1.json \
  benchmarks/gate/v0.5.0-h07-candidate.json
# exit 0 = significant improvement or neutral — PASS
# exit 1 = significant regression detected — FAIL / ESCALATE
```

Expected exit: **0** (neutral — additive schema, recall_lessons() unchanged).  
Baseline: `benchmarks/gate/v0.4.1.json` overall recall@10 = 0.9334 (LME) / 0.8409 (LoCoMo).  
Regression guard: overall recall@10 must not drop > 0.005 at p<0.05 on any table.

---

## 2. Upgrade SQL Plan

Append verbatim to `extension/pgmnemo--0.4.1--0.5.0.sql`.  
Every DDL statement uses `IF NOT EXISTS` / `CREATE OR REPLACE` — **running twice produces no error**.

```sql
-- ─────────────────────────────────────────────────────────────────────────────
-- H-07: Bitemporality primitive on agent_lesson (v0.5.0)
-- Additive schema — no existing column changed, no data deleted.
-- Research: spec/v2/pgmnemo/H07_BITEMPORALITY_RESEARCH.md
-- ─────────────────────────────────────────────────────────────────────────────

-- Step 1: Add bitemporality columns + computed dedup key
ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS t_valid_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS t_valid_to    TIMESTAMPTZ NOT NULL DEFAULT 'infinity'::TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS content_hash  TEXT GENERATED ALWAYS AS (
        MD5(
            COALESCE(role,       '') || '|' ||
            COALESCE(topic,      '') || '|' ||
            COALESCE(commit_sha, COALESCE(artifact_hash, ''))
        )
    ) STORED;

COMMENT ON COLUMN pgmnemo.agent_lesson.t_valid_from IS
    'Valid-time start: when this row''s content became true (defaults to row creation). '
    'H-07 bitemporality (v0.5.0).';
COMMENT ON COLUMN pgmnemo.agent_lesson.t_valid_to IS
    'Valid-time end: infinity = currently active; set to now() when superseded by a new insert. '
    'H-07 bitemporality (v0.5.0).';
COMMENT ON COLUMN pgmnemo.agent_lesson.content_hash IS
    'MD5(role|topic|commit_sha_or_artifact_hash). Dedup key for bitemporal trigger. '
    'NULL when all three source fields are NULL (provenance-gated inserts prevent this in practice).';

-- Step 2: Backfill existing rows — treat them as always-valid from creation time.
-- WHERE clause limits update to rows whose t_valid_from was just set to now()
-- by the ADD COLUMN DEFAULT; rows where t_valid_from was already meaningful are skipped.
UPDATE pgmnemo.agent_lesson
SET    t_valid_from = created_at
WHERE  t_valid_from >= (NOW() - INTERVAL '1 second');

-- Step 3: Indexes (partial — active rows only, keeps scan cost identical to pre-H-07)
CREATE INDEX IF NOT EXISTS ix_agent_lesson_valid_range
    ON pgmnemo.agent_lesson (t_valid_from, t_valid_to)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_hash_active
    ON pgmnemo.agent_lesson (content_hash)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Step 4: Trigger function — closes the prior active row on conflicting insert
CREATE OR REPLACE FUNCTION pgmnemo._bitemporal_close_prior()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    -- Expire any currently-active row with the same content_hash.
    -- NULL content_hash (all provenance fields absent) is skipped safely:
    -- NULL = NULL evaluates FALSE in WHERE, so no rows are closed.
    IF NEW.content_hash IS NOT NULL THEN
        UPDATE pgmnemo.agent_lesson
        SET    t_valid_to = now()
        WHERE  content_hash = NEW.content_hash
          AND  t_valid_to   = 'infinity'::TIMESTAMPTZ
          AND  id           <> NEW.id;
    END IF;
    RETURN NEW;
END;
$$;

-- CREATE OR REPLACE is not valid for triggers; DROP IF EXISTS + CREATE is the
-- idempotent pattern for triggers in pure-SQL extensions.
DROP TRIGGER IF EXISTS trg_agent_lesson_bitemporal_close ON pgmnemo.agent_lesson;
CREATE TRIGGER trg_agent_lesson_bitemporal_close
    AFTER INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW
    EXECUTE FUNCTION pgmnemo._bitemporal_close_prior();

-- Step 5: View alias — forward-compat with ROADMAP "mem_item" naming
CREATE OR REPLACE VIEW pgmnemo.mem_item AS
    SELECT * FROM pgmnemo.agent_lesson
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON VIEW pgmnemo.mem_item IS
    'Active-only alias for pgmnemo.agent_lesson (t_valid_to = infinity). '
    'Forward-compat with ROADMAP mem_item naming (H-07, v0.5.0).';

-- Step 6: Time-travel function
CREATE OR REPLACE FUNCTION pgmnemo.as_of(ts TIMESTAMPTZ)
RETURNS SETOF pgmnemo.agent_lesson
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $$
    SELECT *
    FROM   pgmnemo.agent_lesson
    WHERE  t_valid_from <= ts
      AND  t_valid_to   >  ts;
$$;

COMMENT ON FUNCTION pgmnemo.as_of(TIMESTAMPTZ) IS
    'Time-travel query: returns the state of agent_lesson as of timestamp ts. '
    'Returns rows where t_valid_from <= ts < t_valid_to (half-open interval). '
    'H-07 bitemporality primitive (v0.5.0). '
    'Example: SELECT * FROM pgmnemo.as_of(''2026-05-01 12:00:00+00'');';
```

---

## 3. Idempotency Verification

Running the upgrade SQL **twice on the same database must not error**.

| Statement | Idempotency mechanism |
|---|---|
| `ALTER TABLE … ADD COLUMN IF NOT EXISTS` | `IF NOT EXISTS` — no-op on second run |
| `UPDATE … WHERE t_valid_from >= NOW()-1s` | Window too old on second run → 0 rows updated |
| `CREATE INDEX IF NOT EXISTS` | `IF NOT EXISTS` — no-op on second run |
| `CREATE OR REPLACE FUNCTION _bitemporal_close_prior` | `OR REPLACE` — overwrites on second run, no error |
| `DROP TRIGGER IF EXISTS` | `IF EXISTS` — no-op on second run |
| `CREATE TRIGGER` | Always succeeds after DROP IF EXISTS |
| `CREATE OR REPLACE VIEW mem_item` | `OR REPLACE` — no error |
| `CREATE OR REPLACE FUNCTION as_of` | `OR REPLACE` — no error |

**Idempotency verdict: PASS** — all 8 statement classes are safe to re-run.

**One exception to verify:** The `UPDATE` backfill uses `t_valid_from >= NOW()-1s` as a proxy for "rows whose DEFAULT fired within the current migration session." On first run this updates existing rows correctly. On second run, `t_valid_from` was already set to `created_at` (a historical timestamp), which will be `< NOW()-1s`, so the WHERE clause matches 0 rows. **SAFE.**

---

## 4. Rollback SQL

Full removal of all H-07 objects. Safe to run at any time after the upgrade; no data is permanently destroyed (historical rows with closed `t_valid_to` remain in the table until the DROP COLUMN).

```sql
-- ─── H-07 ROLLBACK ────────────────────────────────────────────────────────────
-- Run in order: trigger → function → view → function → indexes → columns
DROP TRIGGER   IF EXISTS trg_agent_lesson_bitemporal_close ON pgmnemo.agent_lesson;
DROP FUNCTION  IF EXISTS pgmnemo._bitemporal_close_prior();
DROP FUNCTION  IF EXISTS pgmnemo.as_of(TIMESTAMPTZ);
DROP VIEW      IF EXISTS pgmnemo.mem_item;
DROP INDEX     IF EXISTS ix_agent_lesson_valid_range;
DROP INDEX     IF EXISTS ix_agent_lesson_content_hash_active;
ALTER TABLE pgmnemo.agent_lesson
    DROP COLUMN IF EXISTS t_valid_from,
    DROP COLUMN IF EXISTS t_valid_to,
    DROP COLUMN IF EXISTS content_hash;
-- ─────────────────────────────────────────────────────────────────────────────
```

**Rollback safety:**
- All DROP statements use `IF EXISTS` — safe to run even if upgrade was partial.
- `content_hash` is a `GENERATED ALWAYS AS … STORED` column; PostgreSQL drops it cleanly with `DROP COLUMN IF EXISTS`.
- After rollback, `recall_lessons()` and all existing callers are unaffected (they never referenced the dropped columns).
- Rollback to v0.4.1 is clean because all H-07 objects are new in v0.5.0.

---

## 5. Implementation Checklist for IMPLEMENT agent

- [ ] Append upgrade SQL (§2) to `extension/pgmnemo--0.4.1--0.5.0.sql`
- [ ] Add regression test `extension/sql/bitemporality_smoke.sql`:
  - INSERT a row, verify `t_valid_from IS NOT NULL` and `t_valid_to = 'infinity'`
  - INSERT second row with same (role, topic, commit_sha), verify prior row has `t_valid_to < 'infinity'`
  - SELECT from `pgmnemo.as_of(NOW() - INTERVAL '1 second')` — must return 0 rows (too early)
  - SELECT from `pgmnemo.mem_item` — must return only the new active row
- [ ] Add `extension/expected/bitemporality_smoke.out`
- [ ] Add `bitemporality_smoke` to REGRESS in `extension/Makefile`
- [ ] Run `make installcheck` (requires live PG)
- [ ] Run `python scripts/significance_test.py benchmarks/gate/v0.4.1.json benchmarks/gate/v0.5.0-h07-candidate.json` — expect exit 0

---

## 6. Quality Gates

| Gate | Criterion | Status |
|---|---|---|
| ICE scored | I=7, C=8, E=8, composite=7.7 | PASS |
| Target table confirmed | `agent_lesson` (ROADMAP `mem_item` → view alias) | PASS |
| `content_hash` designed | MD5(role\|topic\|commit_sha_or_artifact_hash) GENERATED STORED | PASS |
| DDL fully specified | ALTER TABLE + indexes + trigger + view + as_of() — all IF NOT EXISTS / OR REPLACE | PASS |
| Idempotency verified | All 8 statement classes safe to re-run (table above) | PASS |
| Trigger edge case | NULL content_hash → no rows closed (NULL ≠ NULL in WHERE) | PASS |
| Backfill correctness | `t_valid_from = created_at` for existing rows; window guard prevents double-run | PASS |
| Rollback complete | 8 DROP/ALTER statements, all IF EXISTS, ordering correct | PASS |
| Acceptance gate declared | `significance_test.py exit ≤ 1` (no regression) | PASS |
| Recall-path impact | Zero — recall_lessons() unchanged; partial index preserves scan selectivity | PASS |
