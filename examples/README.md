# pgmnemo examples

Runnable, copy-paste Python scripts demonstrating pgmnemo's unique features
against a live PG 17 + pgmnemo ≥ 0.9.0 instance.

## Prerequisites

```bash
pip install psycopg2-binary
```

Point the scripts at your database (default: `localhost`, db `pgmnemo`, user `postgres`, password `pgmnemo`):

```bash
export PGHOST=localhost PGPORT=5432 PGDATABASE=pgmnemo PGUSER=postgres PGPASSWORD=pgmnemo
# or set a full DSN:
export PGMNEMO_DSN="postgresql://postgres:pgmnemo@localhost:5432/pgmnemo"
```

## Example index

| Script | Feature | SQL API |
|--------|---------|---------|
| [`01_reinforce_ranking_flip.py`](01_reinforce_ranking_flip.py) | **Outcome-learning** — reinforce a lesson 3× and watch its rank rise | `recall_hybrid`, `reinforce` |
| [`02_mcp_quickstart.py`](02_mcp_quickstart.py) | Minimal ingest → recall → navigate loop | `ingest`, `recall_hybrid`, `navigate_locate` |
| [`04_provenance_gate.py`](04_provenance_gate.py) | Provenance gate — write without `commit_sha` raises an exception | `ingest`, `_enforce_provenance_gate` |

---

### 01 — Outcome-learning demo (the differentiator)

```bash
python examples/01_reinforce_ranking_flip.py
```

Ingests 5 lessons about JWT security with identical BM25/embedding signal.
Calls `pgmnemo.recall_hybrid()` before and after `reinforce(A, 'success') × 3`.
Prints rank and confidence delta — lesson A rises in score because
`confidence += 0.10` per success call, and confidence is a scoring term in
`recall_hybrid`.

Expected output fragment:
```
  OUTCOME SUMMARY for lesson_A:
    confidence : 0.500  →  0.800  (Δ = +0.300)
    rank       : 3  →  1
  ✓ Rank IMPROVED — outcome-learning works as expected.
```

---

### 02 — Quickstart

```bash
python examples/02_mcp_quickstart.py
```

Ingests 5 Postgres-perf lessons, recalls with `recall_hybrid`, then calls
`navigate_locate` with a 800-char token budget to show budget-bounded
context assembly.

---

### 04 — Provenance gate

```bash
python examples/04_provenance_gate.py
```

Shows the three gate modes:

| `pgmnemo.gate_strict` | no `commit_sha` | with `commit_sha` |
|---|---|---|
| `enforce` (default) | **EXCEPTION** — row rejected | accepted, `verified_at` set |
| `warn` | accepted + server notice | accepted, `verified_at` set |
| `off` | accepted silently | accepted, `verified_at` set |

---

## SQL reference (v0.9.0)

```sql
-- Write (provenance-gated)
SELECT pgmnemo.ingest(p_role, p_project_id, p_topic, p_lesson_text,
                      p_commit_sha := 'abc1234');

-- Hybrid recall (BM25 + vector + confidence + recency)
SELECT lesson_id, score, confidence, lesson_text
FROM pgmnemo.recall_hybrid(
    query_embedding   := NULL,      -- omit if no embedding available
    query_text        := 'JWT auth',
    k                 := 10,
    project_id_filter := 1
);

-- Outcome-learning update
SELECT pgmnemo.reinforce(lesson_id := 42, p_outcome := 'success');  -- +0.10
SELECT pgmnemo.reinforce(lesson_id := 42, p_outcome := 'failure');  -- -0.15

-- Token-budget locate (for context assembly)
SELECT id, preview, score, tokens_consumed
FROM pgmnemo.navigate_locate(
    query_embedding    := NULL,
    query_text         := 'JWT auth',
    token_budget_chars := 2000,
    project_id_filter  := 1
);
```

> **Note on embeddings**: scripts pass `NULL` for `query_embedding` to keep
> the demo self-contained. In production, supply a 1024-dim vector from your
> embedding model. Both `recall_hybrid` and `navigate_locate` require at least
> one signal (`query_text` or `query_embedding`).
