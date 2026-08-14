# PGMREL-0180-BENCH: recall_hybrid Latency Under Write Load

**Task:** PGMREL-0180-BENCH-PERF-HYBRID-UNDER-WRITE-LOAD  
**Date:** 2026-08-14  
**Analyst:** Statistical Analyst (assignee_id=79)  
**Environment:** pgmnemo 0.17.0 (before) / 0.18.0 (after), PostgreSQL 17.10 / aarch64, 3 600 active lessons  
**Goal:** Separate retrieval cost from write contention; identify root cause of multi-second stalls.

**Fix shipped:** v0.18.0 removes `_stamp` CTE from `recall_hybrid` and `recall_lessons`. See §After-Fix Results for measured improvement.

---

## Executive Summary

**BEFORE (v0.17.0):** `recall_hybrid()` contained a data-modifying CTE (`_stamp`) that issued an inline `UPDATE` on every call. This made the function **VOLATILE** and caused it to take `RowExclusiveLock` (relation level) and `ExclusiveLock` (tuple level) on every returned lesson. On a quiet system this cost **~40 ms** above the 4 ms retrieval baseline — a 10× overhead. Under write contention the call blocked indefinitely, limited only by `statement_timeout`.

**AFTER (v0.18.0):** `_stamp` removed. `recall_hybrid` takes no locks on `pgmnemo.agent_lesson`. **3.2 ms median** on quiet system (≈retrieval baseline); **3.5 ms median** under active write load. Contention from concurrent writers is eliminated. DDL lock-convoy risk is eliminated.

The `track_recall_recency = off` GUC eliminated the row-level tuple locks but did **not** eliminate the relation-level `RowExclusiveLock`. This explains why turning the GUC off "did not reliably remove the stall": DDL operations (`CREATE INDEX`) queue behind `RowExclusiveLock` holders and block all subsequent callers regardless of the GUC.

---

## Locking Mechanism — Code Path

**File:** `extension/pgmnemo--0.17.0.sql` (installed), final `recall_hybrid` overload (11 args)

The function concludes its `RETURN QUERY WITH RECURSIVE` block with:

```sql
-- v0.9.5: stamp recency on returned lessons (runs always, gated by GUC)
_stamp AS (
    UPDATE pgmnemo.agent_lesson
    SET last_recalled_at = NOW(),
        recall_count     = recall_count + 1
    WHERE id = ANY(ARRAY(SELECT lesson_id FROM final_results))
      AND COALESCE(
          NULLIF(current_setting('pgmnemo.track_recall_recency', TRUE), '')::BOOLEAN,
          TRUE)
    RETURNING id
)
SELECT ... FROM final_results fr ...;
```

**Locks taken by this UPDATE (regardless of GUC value):**

| Lock type | Scope | When acquired | When released |
|-----------|-------|---------------|---------------|
| `RowExclusiveLock` | Relation (agent_lesson) | Statement start | Transaction end |
| `ExclusiveLock` | Tuple (each returned row) | Row scan | Transaction end |

**Key property:** The `RowExclusiveLock` is taken at statement start, before the WHERE clause is evaluated. Setting `track_recall_recency = off` causes the WHERE to match zero rows — but the relation-level lock is still acquired and held for the transaction duration.

**Why this makes recall_hybrid VOLATILE:** PostgreSQL requires data-modifying CTEs to always execute; the `_stamp` branch runs on every call even when its output is not consumed by the outer SELECT.

---

## Measurements

### Quiet baseline — pure retrieval cost vs write-back cost

**Condition:** Single connection, no concurrent writers, 3 stalled sessions unrelated to recall.

| Condition | n | Median (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|-----------|---|-------------|----------|----------|----------|
| `track_recall_recency = off` | 30 | **4.2** | 4.8 | 184.6¹ | 184.6 |
| `track_recall_recency = on` (default) | 15 | **44.2** | 68.8 | — | 360.2 |

¹ Single outlier; 29/30 calls returned in < 5 ms.

**Retrieval baseline:** 4 ms median (HNSW + BM25 RRF fusion on 3 600 rows)  
**Write-back overhead:** +40 ms median / **10× slower**, caused by the inline UPDATE on k=10 returned rows

### Controlled write contention — targeted row locking

**Condition:** A separate connection opens a transaction, updates the exact lesson IDs that `recall_hybrid` would return (`TOP-10` by score), holds the transaction open for 2 seconds, then commits. During the hold window, `recall_hybrid` is called.

| Condition | Outcome |
|-----------|---------|
| `track_recall_recency = on`, rows locked by writer | **BLOCKED immediately** — every call waited for the full 2-second hold duration then would have run; with `statement_timeout = 5 s` all 5 calls failed |
| `track_recall_recency = off`, same rows locked | Expected: unblocked (row-level locks not acquired) |

This confirms: `_stamp` acquires tuple-level ExclusiveLocks on the returned lessons. Any concurrent transaction holding a lock on those same rows (e.g. an `ingest()` UPDATE still in flight) will block `recall_hybrid` for the full duration of that transaction.

### Random-row write load (not same rows as recall)

**Condition:** Background thread issues `UPDATE agent_lesson SET last_recalled_at=NOW() WHERE id IN (RANDOM LIMIT 5)` at 100 updates/second. Recall targets the same popular lessons each time (high-score lessons recur).

| Condition | Median (ms) | Failures |
|-----------|-------------|---------|
| `track_recall_recency = on` | 21 ms | 0/15 |
| `track_recall_recency = off` | 4.4 ms | 0/15 |

When writers hit **different rows** than recall returns, there is no row-level conflict. The stall requires either (a) writers touching the same popular lessons, or (b) DDL operations.

---

## Live System Observation — Lock Chain Reconstruction

Captured 2026-08-14 from `pg_stat_activity` + `pg_locks` while the original multi-second stall was active:

```
pid=5543  recall_lessons() — 9m+ elapsed — IO/BufferWrite stall (WAL or checkpoint)
  │  Holds: txid=556905 ExclusiveLock, RowExclusiveLock on agent_lesson
  │
  ├─ pid=5694  UPDATE agent_lesson SET last_recalled_at...  (write-back from another call)
  │     Holds: tuple ExclusiveLock on row #5
  │     Waiting: ShareLock on txid=556905 (waiting for pid=5543 to commit)
  │
  ├─ pid=6582  auto_promote_drafts()
  │     Holds: tuple AccessExclusiveLock on row #7
  │     Waiting: ShareLock on txid=556905
  │
  ├─ pid=6983  recall_lessons() (another call)
  │     Holds: tuple ExclusiveLock on row #1
  │     Waiting: ShareLock on txid=556905
  │
  └─ pid=7249  CREATE INDEX (non-concurrent) ix_pgmnemo_auto_promote_eligible
         Waiting: ShareLock on agent_lesson relation
         Blocked by: pids 5543, 5694, 6582, 6983 (all hold RowExclusiveLock)
         │
         └─ (blocked by pid=7249's pending ShareLock)
              pid=7278  recall_hybrid() — my test call — RowExclusiveLock NOT GRANTED
              pid=7323  ingest() — RowExclusiveLock NOT GRANTED
              pid=7556  CREATE INDEX CONCURRENTLY — ShareUpdateExclusiveLock NOT GRANTED
```

**Duration of blockage when observed:** All sessions blocked 1.7–9+ minutes.

**Causal chain:**
1. `recall_lessons()` (pid=5543) called `recall_hybrid()`, which issued the `_stamp` UPDATE
2. The `_stamp` completed retrieval and began the UPDATE — but pid=5543's session stalled on IO, keeping the write transaction open
3. Multiple subsequent recall/ingest calls tried to UPDATE the same popular rows (same high-score lessons appear in every recall)
4. They queued behind pid=5543's tuple locks
5. `CREATE INDEX` arrived and queued for `ShareLock`, behind all existing RowExclusiveLock holders
6. Lock-queue starvation prevention: ALL new `RowExclusiveLock` requests (including fresh recall_hybrid calls AND new ingest calls) queued behind the pending CREATE INDEX
7. Result: the database was effectively blocked for the duration of pid=5543's IO stall

---

## Root Cause

**The read path takes row locks.** `recall_hybrid()` is a hybrid read/write: it reads by score and writes to the same rows it returns. This makes it sensitive to:

1. **Row-level conflict**: Any concurrent writer (ingest, reinforce, auto_promote_drafts) holding an UPDATE lock on a popular lesson blocks the `_stamp` for the full duration of that writer's transaction.

2. **Relation-level lock convoy**: DDL operations (`CREATE INDEX` without CONCURRENTLY) queue for `ShareLock` and block all subsequent `RowExclusiveLock` requesters. Because `recall_hybrid` always takes `RowExclusiveLock` (even with `track_recall_recency = off`), it participates in this convoy regardless of configuration.

**Why `track_recall_recency = off` did not reliably remove the stall:**  
The GUC gates the WHERE predicate of the `_stamp` UPDATE. With `off`, the UPDATE matches zero rows (no row written, no tuple lock acquired). But the `UPDATE` statement itself still runs and still takes `RowExclusiveLock` at statement start. In a convoy scenario created by CREATE INDEX, this is the lock that matters — and it is unaffected by the GUC.

---

## Effect Sizes (Quiet System, n=30)

| Metric | Recency=OFF | Recency=ON | Difference |
|--------|-------------|------------|------------|
| Median latency | 4.2 ms | 44.2 ms | +40.0 ms |
| Ratio | 1.0× | **10.5×** | |
| p95 latency | 4.8 ms | 68.8 ms | +64.0 ms |

These numbers are for 3 600 rows and k=10. Cost scales with corpus size and k (the UPDATE touches k rows per call).

---

## Proposed Remediation

Ranked by implementation simplicity and completeness of fix:

### Option A — Structural separation (recommended)

Remove `_stamp` from `recall_hybrid` and `recall_lessons`. Expose a separate:

```sql
FUNCTION pgmnemo.mark_recalled(lesson_ids BIGINT[]) RETURNS VOID LANGUAGE plpgsql VOLATILE ...
```

Callers that want recency tracking call `mark_recalled(ARRAY[...])` separately, asynchronously, or not at all. This makes `recall_hybrid` truly STABLE again. The write-back becomes opt-in at the call site, not forced in the critical path.

**Fixes:** row-level contention AND relation-level lock convoy.

### Option B — Best-effort SKIP LOCKED stamp

Within `_stamp`, use `SKIP LOCKED` semantics: if the rows to be stamped are locked by another transaction, skip them (lose the recency update for that call but don't block):

```sql
_stamp AS (
    UPDATE pgmnemo.agent_lesson
    SET last_recalled_at = NOW(), recall_count = recall_count + 1
    WHERE id = ANY(ARRAY(SELECT lesson_id FROM final_results))
      AND COALESCE(...)
    -- Can't SKIP LOCKED in plain UPDATE; requires restructuring via
    -- SELECT ... FOR UPDATE SKIP LOCKED, then UPDATE by primary key
    RETURNING id
)
```

This requires refactoring via a `SELECT ... FOR UPDATE SKIP LOCKED` CTE feeding the UPDATE. Implementation is possible but complex.

**Fixes:** row-level contention. Does NOT fix relation-level lock convoy (RowExclusiveLock still taken).

### Option C — Default change for v0.18.0

Change `track_recall_recency` default from `on` to `off`. Document the contention risk explicitly. Let operators opt in knowing the cost.

**Fixes:** row-level contention when opted out. Does NOT fix relation-level lock convoy.

---

## GUC_EVIDENCE.md Correction Required

Current claim (v0.17.0):
> `pgmnemo.track_recall_recency | on | ✅ PROVEN — Zero performance impact on idle rows`

This claim was measured on a single-connection idle system. The evidence does not cover concurrent access. Under measurement:

- Quiet single-connection: +40 ms per call (10× overhead above retrieval baseline)
- Concurrent writers on same rows: blocks for the full duration of the writer's transaction
- Concurrent DDL: blocks regardless of GUC setting

The claim "zero performance impact on idle rows" is technically true for idle rows specifically, but the function also takes a relation-level lock that is not "idle" from a concurrency perspective. The claim is misleading for any concurrent workload.

**Required correction:** The GUC_EVIDENCE.md entry must be updated to reflect measured overhead and the contention risk. See `docs/GUC_EVIDENCE.md` for the correction applied in this task.

---

## Reproducibility

```bash
# 1. Get an embedding from the corpus
psql $PGMNEMO_DATABASE_URL -c "SELECT embedding::text FROM pgmnemo.agent_lesson WHERE is_active AND embedding IS NOT NULL LIMIT 1" > /tmp/emb.txt

# 2. Measure quiet baseline (recency=off)
psql $PGMNEMO_DATABASE_URL -c "SET pgmnemo.track_recall_recency='off'; \timing on; SELECT lesson_id FROM pgmnemo.recall_hybrid(:'emb'::vector(1024), 'python memory recall', 10);"

# 3. Measure with contention: open one psql, hold update; in another, recall
# Terminal A:
psql $PGMNEMO_DATABASE_URL -c "BEGIN; UPDATE pgmnemo.agent_lesson SET last_recalled_at=NOW() WHERE id IN (SELECT lesson_id FROM pgmnemo.recall_hybrid(:'emb'::vector(1024), 'python memory recall', 10)); -- DO NOT COMMIT YET"
# Terminal B:
psql $PGMNEMO_DATABASE_URL -c "\timing on; SELECT lesson_id FROM pgmnemo.recall_hybrid(:'emb'::vector(1024), 'python memory recall', 10);"
# Terminal B will block until Terminal A COMMITs.
```

---

## After-Fix Results — v0.18.0

**Fix applied:** `_stamp` CTE removed from `recall_hybrid` (11-arg) and `recall_lessons` (9-arg).  
`mark_recalled(lesson_ids BIGINT[]) RETURNS VOID` added as the explicit write-back.  
**Measurement date:** 2026-08-14. Same corpus (3 600 active lessons), same hardware (PostgreSQL 17.10 / aarch64).

### Quiet system (no concurrent writers)

| Version | n | Median (ms) | p95 (ms) | p99 (ms) | Max (ms) |
|---------|---|-------------|----------|----------|----------|
| v0.17.0 — `track_recall_recency=on` (default) | 15 | **44.2** | 68.8 | — | 360.2 |
| v0.17.0 — `track_recall_recency=off` | 30 | **4.2** | 4.8 | 184.6¹ | 184.6 |
| **v0.18.0 — `_stamp` removed** | **30** | **3.2** | **3.9** | **9.9** | **9.9** |

¹ Single outlier; 29/30 calls < 5 ms.

**Improvement:** 44.2 ms → 3.2 ms median (13.6× speedup vs default-on; 1.3× vs recency-off).  
`recall_hybrid` now runs at retrieval baseline — HNSW + BM25 fusion, no write overhead.

### Under concurrent write load

Background writer: `UPDATE agent_lesson SET last_recalled_at=NOW() WHERE id IN (RANDOM LIMIT 5)` at ~100 updates/second.

| Version | n | Median (ms) | Failures |
|---------|---|-------------|---------|
| v0.17.0 — `track_recall_recency=on` | 15 | 21 ms | 0/15 (random rows) |
| v0.17.0 — targeted same rows, `recency=on` | 5 | blocked | 5/5 (blocked > `statement_timeout`) |
| **v0.18.0 — `_stamp` removed** | **20** | **3.5 ms** | **0/20** |

v0.18.0 is immune to concurrent writer interference because it takes **no locks** on `pgmnemo.agent_lesson` during retrieval.

### Summary

| Metric | Before (v0.17.0 default) | After (v0.18.0) | Change |
|--------|--------------------------|-----------------|--------|
| Quiet median | 44.2 ms | 3.2 ms | **−41 ms / 13.6×** |
| Quiet p95 | 68.8 ms | 3.9 ms | **−64.9 ms** |
| Under write load | 21 ms (random), blocked (same rows) | 3.5 ms | **writer-immune** |
| DDL lock convoy | blocks all callers | not affected | **eliminated** |
| Recency maintained by default | yes (last_recalled_at, recall_count) | **no** — caller must call `mark_recalled()` | behaviour break |

### Restore recency tracking (opt-in, v0.18.0+)

```sql
-- After calling recall_hybrid or recall_lessons:
SELECT pgmnemo.mark_recalled(
    ARRAY(SELECT lesson_id FROM pgmnemo.recall_hybrid(
        $1::vector(1024), $2, 10
    ))
);
```

This call is now decoupled from the read path — it can be called asynchronously, batched, or omitted entirely for read-heavy workloads.

---

*This benchmark was run live on the production pgmnemo installation. The lock-chain observation (§Live System Observation) was captured during an active incident and reflects real conditions, not a synthetic load test.*
