# Outcome-Learning Adoption Guide — `reinforce()` + `confidence_boost_weight`

**Version:** 0.10.0 (guide first published)  
**Feature availability:** `reinforce()` since v0.7.0; `confidence_boost_weight` GUC since v0.9.2  
**Status:** Dark by default (GUC = 0.0). This guide activates it.

---

## TL;DR

pgmnemo's outcome-learning loop has been live since v0.7.0 but dormant.  
Activating it takes three steps and ~100 reinforcement calls:

```sql
-- 1. Wire reinforce() into your post-task hook
SELECT pgmnemo.reinforce(ARRAY[lesson_id_1, lesson_id_2], 'success');

-- 2. Check distribution health (wait for ~50+ reinforce calls)
SELECT confidence_p10, confidence_p50, confidence_p90 FROM pgmnemo.stats();
-- Ready when p10 < 0.45 AND p90 > 0.55

-- 3. Activate the ranking boost (recommended starting value)
ALTER ROLE my_agent_role SET pgmnemo.confidence_boost_weight = '0.003';
```

---

## 1. Why it exists (motivation)

Without feedback, every lesson starts at `confidence = 0.5` and stays there.  
`recall_hybrid()` ranks by cosine similarity + BM25 + graph proximity + recency + provenance.  
A lesson written last year competes equally with a noisy one written yesterday — both have `confidence = 0.5`.

**The outcome-learning loop fixes this:**

| Component | Role |
|---|---|
| `pgmnemo.reinforce(id, outcome)` | Updates per-lesson `confidence` based on observed success/failure |
| `confidence_boost_weight` GUC | Makes `confidence` influence `recall_hybrid()` ranking |

The two components are independent. `reinforce()` works without the GUC (confidence is updated but does not affect ranking). The GUC works without reinforce() (no effect until confidence diverges from 0.5).

---

## 2. How the math works

### `reinforce()` — confidence update

```
confidence_new = CLAMP(confidence_old + delta, 0.0, 1.0)

'success' → delta = +pgmnemo.reinforce_success_delta (default: +0.02)
'failure' → delta = −pgmnemo.reinforce_fail_delta    (default: −0.12)
'neutral' → delta = 0 (no-op, useful as a placeholder)
```

**Asymmetric by design:** failure penalises 6× faster than success rewards.  
This reflects a base rate: one success is weak evidence; one failure is strong.

Time to reach `confidence = 0.8` from `0.5` at defaults: 15 success calls with no failures.  
Time to reach `confidence = 0.2` from `0.5` at defaults: 3 failure calls.

### `confidence_boost_weight` — ranking adjustment

```
score_final = score_rrf + w × (confidence − 0.5)
```

Zero-centred at `confidence = 0.5`:
- `confidence = 0.8`, `w = 0.003`: boost = `+0.0009`
- `confidence = 0.5`, `w = 0.003`: boost = `0` (neutral)
- `confidence = 0.2`, `w = 0.003`: boost = `−0.0009` (penalty)

Typical `recall_hybrid()` RRF score at rank-1: `≈ 0.013` (corpus-size invariant).  
At `w = 0.003`, the maximum boost is `±0.0015` (≈ ±12% of the base RRF score).  
This is additive and bounded — confidence cannot flip the rank of a strongly-relevant lesson.

---

## 3. Adoption playbook

### Phase 0 — prerequisites

- pgmnemo ≥ 0.9.2 installed (check: `SELECT pgmnemo.version()`)
- Your orchestrator has access to `lesson_id` values returned by `recall_hybrid()` or `recall_fast()`
- You can hook into task completion (success / failure / skip)

### Phase 1 — wire reinforce() (no GUC change yet)

Add a post-task call wherever you determine task outcome. The canonical call is:

```python
# After task completes — orchestrator, NOT the agent
import psycopg2

def post_task_hook(conn, recalled_lesson_ids: list[int], outcome: str) -> None:
    """
    outcome: 'success' | 'failure' | 'neutral'
    recalled_lesson_ids: lesson_ids from the recall() call that preceded this task
    """
    if not recalled_lesson_ids:
        return
    with conn.cursor() as cur:
        cur.execute(
            "SELECT pgmnemo.reinforce(%s::BIGINT[], %s)",
            (recalled_lesson_ids, outcome)
        )
    conn.commit()
```

Or via the MCP server (`deep=False` for `recall_fast`, `deep=True` for `recall_hybrid`):

```
# MCP tool call:
pgmnemo.recall(query="task description", top_k=5, role_filter="role", deep=False)
pgmnemo.patch(lesson_ids=[42, 17], outcome="success")
```

**Run Phase 1 for 50–200 task cycles before Phase 2.** The GUC has no effect until confidence diverges.

### Phase 2 — verify distribution health

```sql
-- Quick health snapshot
SELECT
    confidence_p10,
    confidence_p50,
    confidence_p90,
    (confidence_p90 - confidence_p10) AS spread,
    (confidence_p90 - confidence_p10) > 0.10 AS ready_for_boost
FROM pgmnemo.stats();
```

**Ready criteria (both must hold):**

| Condition | Meaning |
|---|---|
| `confidence_p10 < 0.45` | Some lessons have been penalised |
| `confidence_p90 > 0.55` | Some lessons have been promoted |

If both `p10` and `p90` are `≈ 0.50`, more reinforce() calls are needed.

```sql
-- Detailed histogram
SELECT
    WIDTH_BUCKET(confidence, 0.0, 1.0, 10) AS bucket,
    ROUND(MIN(confidence)::NUMERIC, 2)     AS bucket_min,
    COUNT(*)                               AS lessons
FROM pgmnemo.agent_lesson
WHERE is_active
GROUP BY 1
ORDER BY 1;
```

### Phase 3 — activate with a conservative value

```sql
-- Per-session test (does not persist across connections):
SET pgmnemo.confidence_boost_weight = '0.001';

-- Run a few queries and compare rankings:
SELECT lesson_id, score, confidence, topic
FROM pgmnemo.recall_hybrid(
    $1::vector(1024),
    'your test query',
    k := 10
)
ORDER BY score DESC;

-- If the ranking change looks reasonable, bump to recommended value:
SET pgmnemo.confidence_boost_weight = '0.003';
```

### Phase 4 — set permanently

```sql
-- Role-scoped (recommended — different roles may need different weights):
ALTER ROLE my_agent_role SET pgmnemo.confidence_boost_weight = '0.003';

-- Session-global (all roles on this database):
ALTER DATABASE mydb SET pgmnemo.confidence_boost_weight = '0.003';
```

---

## 4. Tuning reference

| Weight | Effect | When to use |
|---|---|---|
| `0.0` (default) | Off — confidence has no ranking effect | Always safe; use during Phase 1 |
| `0.001` | Very subtle (~7% of RRF base) | Conservative start; minimal ranking distortion |
| `0.003` | Moderate (~23% of RRF base) | **Recommended default** for most corpora |
| `0.005` | Strong (~38% of RRF base) | High-signal corpus (≥500 reinforce calls, clear distribution spread) |
| `0.010` | Maximum supported | Expert use; risk of confidence dominating relevance |

> **Do not set values above 0.01.** The GUC accepts them but they push `confidence_boost_weight × (confidence − 0.5)` above `±0.005`, which can flip the ranking of a highly-relevant lesson in favour of a less-relevant but well-reinforced one.

### Adjusting the reinforce deltas

If convergence is too slow (agents run frequently, corpus changes fast):

```sql
-- Faster upward drift (default: 0.02):
ALTER ROLE my_agent_role SET pgmnemo.reinforce_success_delta = '0.05';

-- Lighter failure penalty (default: 0.12):
ALTER ROLE my_agent_role SET pgmnemo.reinforce_fail_delta = '0.08';
```

If confidence saturates (most lessons at 0.0 or 1.0):

```sql
-- Slower deltas + review outcome assignment logic
ALTER ROLE my_agent_role SET pgmnemo.reinforce_success_delta = '0.01';
ALTER ROLE my_agent_role SET pgmnemo.reinforce_fail_delta    = '0.05';
```

---

## 5. Monitoring

### Confidence health query (add to your monitoring loop)

```sql
-- Run periodically (e.g. daily) — alert if spread collapses
SELECT
    COUNT(*)                                           AS total_active,
    ROUND(AVG(confidence)::NUMERIC, 3)                AS mean_confidence,
    ROUND(PERCENTILE_CONT(0.10) WITHIN GROUP
          (ORDER BY confidence)::NUMERIC, 3)          AS p10,
    ROUND(PERCENTILE_CONT(0.50) WITHIN GROUP
          (ORDER BY confidence)::NUMERIC, 3)          AS p50,
    ROUND(PERCENTILE_CONT(0.90) WITHIN GROUP
          (ORDER BY confidence)::NUMERIC, 3)          AS p90,
    COUNT(*) FILTER (WHERE confidence >= 0.7)         AS high_confidence,
    COUNT(*) FILTER (WHERE confidence <= 0.3)         AS low_confidence,
    COUNT(*) FILTER (WHERE confidence BETWEEN 0.45
                       AND 0.55)                      AS near_neutral
FROM pgmnemo.agent_lesson
WHERE is_active;
```

**Alert if:** `near_neutral / total_active > 0.8` — means reinforce() is not being called, or all outcomes are 'neutral'.

### Unreinforced recall proxy

```sql
-- Lessons recalled frequently but never reinforced
-- (likely hallucinated or un-tracked usage)
SELECT lesson_id, recall_count, confidence, topic
FROM pgmnemo.agent_lesson
WHERE is_active
  AND recall_count > 5
  AND confidence BETWEEN 0.48 AND 0.52
ORDER BY recall_count DESC
LIMIT 20;
```

---

## 6. Rollback

The boost is additive and bounded. To disable:

```sql
-- Per-session (immediate):
SET pgmnemo.confidence_boost_weight = '0.0';

-- Permanent rollback:
ALTER ROLE my_agent_role RESET pgmnemo.confidence_boost_weight;
ALTER DATABASE mydb RESET pgmnemo.confidence_boost_weight;
```

Rolling back the GUC does not affect stored `confidence` values. Lessons retain their accumulated confidence scores — the scores just stop influencing ranking. Re-enabling the GUC later resumes from where the confidence values left off.

---

## 7. Complete example — before and after

**Corpus:** 100 active lessons, all at `confidence = 0.5`.  
**Phase 1:** 80 task cycles, each recalling 3–5 lessons. Outcomes wired.  
**Result:** confidence spread to [0.1, 0.9].

```sql
-- Before (GUC = 0.0, Phase 1 only):
-- lesson_id | score  | confidence | topic
-- ----------+--------+------------+-------
--        42 | 0.0163 |       0.80 | psycopg2
--        17 | 0.0161 |       0.26 | sql_joins
--        88 | 0.0158 |       0.50 | indexing

-- After (GUC = 0.003, Phase 3):
-- lesson_id | score  | confidence | topic
-- ----------+--------+------------+-------
--        42 | 0.0172 |       0.80 | psycopg2     ← +0.0009 (proven)
--        88 | 0.0158 |       0.50 | indexing     ← no change
--        17 | 0.0154 |       0.26 | sql_joins    ← −0.0007 (penalised)
```

Lesson 17 (`sql_joins`) fell below lesson 88 (`indexing`) despite higher raw RRF score — its failure track record now influences ranking.

---

## 8. Interaction with `mark_stale()`

After sufficient reinforcement, low-confidence lessons become candidates for deprecation:

```sql
-- Dry-run: identify low-confidence, low-recall lessons
SELECT * FROM pgmnemo.mark_stale(
    p_min_days_old         := 30,
    p_max_recall_count     := 2,
    p_min_confidence_keep  := 0.6,   -- lessons below 0.6 are candidates
    dry_run                := TRUE
) LIMIT 20;

-- Deprecate (is_active = FALSE, NOT deleted):
SELECT * FROM pgmnemo.mark_stale(
    p_min_days_old         := 30,
    p_max_recall_count     := 2,
    p_min_confidence_keep  := 0.6,
    dry_run                := FALSE
);
```

This completes the feedback loop: `reinforce()` signals quality → `confidence_boost_weight` promotes proven lessons → `mark_stale()` retires persistently-penalised ones.

---

## 9. References

- `reinforce()` function: [`docs/SQL_REFERENCE.md §2.x`](SQL_REFERENCE.md)
- `confidence_boost_weight` GUC: [`docs/SQL_REFERENCE.md §3.2`](SQL_REFERENCE.md#32-write--ingest-gucs)
- Outcome-learning GUCs: [`docs/SQL_REFERENCE.md §3.3`](SQL_REFERENCE.md#33-outcome-learning-gucs-used-by-reinforce-v093)
- USAGE.md quick reference: [`docs/USAGE.md §Outcome-learning`](USAGE.md)
- MCP server (`pgmnemo.patch` tool): [`pgmnemo_mcp/pgmnemo_mcp/server.py`](../pgmnemo_mcp/pgmnemo_mcp/server.py)
- pg_regress tests: [`extension/sql/confidence_boost_guc.sql`](../extension/sql/confidence_boost_guc.sql), [`extension/sql/reinforce_delta_guc.sql`](../extension/sql/reinforce_delta_guc.sql)
