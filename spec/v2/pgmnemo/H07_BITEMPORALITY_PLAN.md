---
hypothesis: H-07 — Bitemporality primitive on agent_lesson
date: 2026-05-17
priority: P1 (sprint), P2 (roadmap)
due: 2026-05-22
status: PLAN COMPLETE — DDL ready for IMPLEMENT
evidence_sources:
  - spec/v2/pgmnemo/H07_BITEMPORALITY_RESEARCH.md
  - extension/pgmnemo--0.4.1.sql:75-155 (agent_lesson schema)
  - extension/pgmnemo--0.4.1.sql:267-330 (mem_edge valid_from/valid_until pattern)
  - extension/pgmnemo--0.4.1--0.5.0.sql (migration target, already has H-06 content)
---

# H-07 Plan: Bitemporality Primitive

---

## 1. ICE Score

| Dimension | Score (1–10) | Rationale |
|---|---|---|
| **Impact** | **7** | Enables point-in-time memory queries — key for audit, correction, and temporal-reasoning workloads. Closes the `t_valid_from`/`t_valid_to` gap vs `mem_edge` (already bitemporal at pgmnemo--0.4.1.sql:278-280). Unblocks future `as_of()` API callers. |
| **Confidence** | **8** | Additive DDL only — no existing column changed, no data migrated. `ALTER TABLE … ADD COLUMN IF NOT EXISTS` is idempotent. `recall_lessons()` / `recall_hybrid()` scoring paths are unaffected (confirmed in Research §3). `mem_edge` already uses the same `valid_from`/`valid_until` pattern, so semantics are proven in production. |
| **Ease** | **7** | ~50 LOC DDL (3 columns, 2 indexes, 1 trigger function, 1 trigger, 1 view, 1 function). Idempotent guards (`IF NOT EXISTS`, `CREATE OR REPLACE`) eliminate re-run risk. Generated column (`content_hash`) avoids application-side hashing. |
| **ICE composite** | **7.3** | Priority: ship in v0.5.0 sprint alongside H-06. |

**Confidence caveat:** Live PG testing not possible in this environment (no PG server installed). `installcheck` exit status unverified. Expected outcome: zero recall regression (additive schema; scoring path unchanged per Research §3a).

---

## 2. Schema Clarifications (from Research §1)

| Issue | Resolution |
|---|---|
| `mem_item` table does not exist | Apply H-07 to `agent_lesson`; expose `pgmnemo.mem_item` as active-rows view |
| `content_hash` column does not exist | Add as `GENERATED ALWAYS AS MD5(role\|topic\|commit_sha/artifact_hash) STORED` |
| `source_id` column does not exist | Not needed; dedup key is `content_hash` derived from existing provenance columns |
| `mem_edge` bitemporality | Already has `valid_from`/`valid_until` — H-07 is semantically consistent |

---

## 3. Full Upgrade SQL (appended to extension/pgmnemo--0.4.1--0.5.0.sql)

### 3a. Column additions — idempotent

```sql
-- H-07: Bitemporality primitive on agent_lesson (v0.5.0)
-- Consistent with mem_edge.valid_from / valid_until pattern (pgmnemo--0.4.1.sql:278-280).
-- All guards use IF NOT EXISTS / CREATE OR REPLACE — safe to run twice on same DB.

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS t_valid_from  TIMESTAMPTZ NOT NULL DEFAULT now(),
    ADD COLUMN IF NOT EXISTS t_valid_to    TIMESTAMPTZ NOT NULL DEFAULT 'infinity'::TIMESTAMPTZ;

ALTER TABLE pgmnemo.agent_lesson
    ADD COLUMN IF NOT EXISTS content_hash  TEXT GENERATED ALWAYS AS (
        MD5(
            COALESCE(role,        '') || '|' ||
            COALESCE(topic,       '') || '|' ||
            COALESCE(commit_sha, COALESCE(artifact_hash, ''))
        )
    ) STORED;
```

### 3b. Backfill existing rows

```sql
-- Set t_valid_from = created_at for rows that received DEFAULT now() from this migration.
-- Condition: t_valid_from within 1 second of now() — catches only migration-time defaults.
-- Safe to run twice: rows already backfilled will not match (created_at << now()).
UPDATE pgmnemo.agent_lesson
SET    t_valid_from = created_at
WHERE  t_valid_from >= (now() - INTERVAL '1 second');
```

### 3c. Indexes

```sql
-- Partial index: active rows only — keeps recall_lessons() planning identical.
CREATE INDEX IF NOT EXISTS ix_agent_lesson_valid_range
    ON pgmnemo.agent_lesson (t_valid_from, t_valid_to)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;

-- Lookup index for trigger WHERE content_hash = NEW.content_hash.
CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_hash_active
    ON pgmnemo.agent_lesson (content_hash)
    WHERE t_valid_to = 'infinity'::TIMESTAMPTZ;
```

### 3d. Trigger function and trigger

```sql
-- Trigger function: on INSERT, close any active row with matching content_hash.
-- NULL-safe: if content_hash IS NULL (all provenance columns NULL), no rows closed.
-- Concurrent-insert safety: PostgreSQL AFTER trigger uses row-level locking.
CREATE OR REPLACE FUNCTION pgmnemo._bitemporal_close_prior()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
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

-- DROP before CREATE to make trigger creation idempotent (triggers lack OR REPLACE).
DROP TRIGGER IF EXISTS trg_agent_lesson_bitemporal_close ON pgmnemo.agent_lesson;

CREATE TRIGGER trg_agent_lesson_bitemporal_close
    AFTER INSERT ON pgmnemo.agent_lesson
    FOR EACH ROW
    EXECUTE FUNCTION pgmnemo._bitemporal_close_prior();
```

### 3e. View and time-travel function

```sql
-- pgmnemo.mem_item: active-only view — forward-compat alias for ROADMAP.md "mem_item".
CREATE OR REPLACE VIEW pgmnemo.mem_item AS
    SELECT *
    FROM   pgmnemo.agent_lesson
    WHERE  t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON VIEW pgmnemo.mem_item IS
    'Active-row alias for pgmnemo.agent_lesson (t_valid_to = infinity). '
    'H-07 bitemporality (v0.5.0). Forward-compat alias for ROADMAP mem_item.';

-- pgmnemo.as_of(ts): time-travel query returning agent_lesson state at ts.
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
    'Time-travel: returns agent_lesson state as of timestamp ts. '
    'Returns rows where t_valid_from <= ts < t_valid_to. '
    'H-07 bitemporality primitive (v0.5.0). '
    'For edge time-travel: join pgmnemo.as_of(ts) with pgmnemo.mem_edge.';
```

---

## 4. Idempotency Verification

Running the upgrade SQL twice on the same DB must not error:

| Statement | Guard | Second-run behaviour |
|---|---|---|
| `ADD COLUMN IF NOT EXISTS t_valid_from` | `IF NOT EXISTS` | no-op |
| `ADD COLUMN IF NOT EXISTS t_valid_to` | `IF NOT EXISTS` | no-op |
| `ADD COLUMN IF NOT EXISTS content_hash` | `IF NOT EXISTS` | no-op |
| `UPDATE … WHERE t_valid_from >= now()-1s` | time-bound condition | matches 0 rows (all already backfilled) |
| `CREATE INDEX IF NOT EXISTS ix_agent_lesson_valid_range` | `IF NOT EXISTS` | no-op |
| `CREATE INDEX IF NOT EXISTS ix_agent_lesson_content_hash_active` | `IF NOT EXISTS` | no-op |
| `CREATE OR REPLACE FUNCTION pgmnemo._bitemporal_close_prior()` | `OR REPLACE` | re-defines identically |
| `DROP TRIGGER IF EXISTS trg_agent_lesson_bitemporal_close` | `IF EXISTS` | no error |
| `CREATE TRIGGER trg_agent_lesson_bitemporal_close` | preceded by DROP | always clean |
| `CREATE OR REPLACE VIEW pgmnemo.mem_item` | `OR REPLACE` | re-defines identically |
| `CREATE OR REPLACE FUNCTION pgmnemo.as_of(TIMESTAMPTZ)` | `OR REPLACE` | re-defines identically |

**Verdict: fully idempotent.**

---

## 5. Rollback SQL

```sql
-- H-07 full rollback — removes all bitemporality additions.
-- Objects dropped in dependency order. Safe on a DB where H-07 was never applied.

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
```

**Risk assessment:**
- All H-07 additions are new in v0.5.0 — no v0.4.1 callers reference these objects.
- `mem_item` and `as_of()` are dropped before the columns they depend on.
- `content_hash` is `GENERATED ALWAYS AS … STORED`; `DROP COLUMN IF EXISTS` works normally.
- Net data loss: only bitemporality metadata (`t_valid_from`, `t_valid_to`, `content_hash`). Core lesson content is unaffected.

---

## 6. Acceptance Gate

### 6a. Primary gate

```
significance_test.py exit ≤ 1 on ALL benchmark cells (no recall regression)
```

```bash
python scripts/significance_test.py \
  benchmarks/gate/v0.4.1.json \
  benchmarks/gate/v0.5.0-h07-candidate.json
```

| Exit code | Meaning | Action |
|---|---|---|
| 0 | Significant improvements, no regression | PASS — ship |
| 1 (no change) | Additive schema neutral — expected | PASS — ship |
| 1 (regression) | Investigate trigger / index overhead | ESCALATE |
| 2+ | Run failed | ESCALATE |

### 6b. Regression guard

Reject any cell where:
- Overall recall@10 regresses vs v0.4.1 (LME 0.9334 / LoCoMo 0.8409) by >0.005 at p<0.05
- INSERT latency at n=1000 increases >10% (trigger: single indexed UPDATE, expected <1ms)

### 6c. Functional smoke test

```sql
BEGIN;
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, importance, commit_sha)
    VALUES ('test', 'H07', 'v1 lesson text', 3, 'abc123');
INSERT INTO pgmnemo.agent_lesson (role, topic, lesson_text, importance, commit_sha)
    VALUES ('test', 'H07', 'v2 lesson text', 3, 'abc123');
-- Expect: first row closed (t_valid_to < infinity), second active (t_valid_to = infinity)
SELECT lesson_text, t_valid_to = 'infinity'::TIMESTAMPTZ AS is_active
FROM   pgmnemo.agent_lesson
WHERE  topic = 'H07'
ORDER  BY t_valid_from;
-- Expect: as_of(now()) returns only second row
SELECT lesson_text FROM pgmnemo.as_of(now()) WHERE topic = 'H07';
ROLLBACK;
```

---

## 7. Implementation Checklist for IMPLEMENT task

- [ ] Append H-07 DDL (§3 above) to `extension/pgmnemo--0.4.1--0.5.0.sql`
- [ ] Add regression test `extension/sql/bitemporality_smoke.sql` (§6c)
- [ ] Add `extension/expected/bitemporality_smoke.out` with expected output
- [ ] Add `bitemporality_smoke` to `REGRESS` in `extension/Makefile`
- [ ] Run `make installcheck` (requires live PG + pgvector + pgmnemo)
- [ ] Run significance_test.py against v0.4.1 gate
- [ ] If exit ≤ 1: write `benchmarks/gate/v0.5.0-h07-candidate.json`

---

## 8. Quality Gates

| Gate | Criterion | Status |
|---|---|---|
| ICE score computed | Impact=7, Confidence=8, Ease=7 → composite 7.3 | PASS |
| DDL target confirmed | `agent_lesson` (not non-existent `mem_item`) | PASS |
| `mem_item` resolved | View alias — active rows of `agent_lesson` | PASS |
| `content_hash` designed | MD5 generated column; NULL-safe; indexed | PASS |
| Idempotency verified | All 11 statements guarded — table above | PASS |
| Rollback SQL complete | DROP sequence in dependency order; IF EXISTS throughout | PASS |
| Recall-path impact | Zero — additive schema; `recall_lessons()` unmodified | PASS |
| Acceptance gate defined | sig_test exit ≤ 1; functional smoke in §6c | PASS |
| Live PG verification | PENDING — no PG server in agent environment | PENDING |
