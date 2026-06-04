# BUG_RECALL_GRAPH_DOMINATES_2026-06-03 — Fix Report

## Bug

[mechanism] In `recall_hybrid` (v0.7.x) and `navigate_locate` (v0.8.0), `_graph_weight * graph_proximity`
is **additive** to `rrf_sparse`:

```
final_score = rrf_sparse + aux + graph_weight * proximity
```

- Max `rrf_sparse` (rank=1 both signals): `0.4/61 + 0.4/61 = 0.0131`
- Max `aux`: `_aux_scale * 0.15 = 0.0026`
- Max `graph`: `0.2 * 0.8 = 0.16` (depth=1, max_depth=5)

Graph term is **12x** the entire retrieval signal. Ranking is decided by graph topology,
not query relevance. A perfect vector match (cosine=1.0) is buried below graph-connected
items with cosine=0.04.

## Fixes Applied (v0.8.1)

### F1: Multiplicative graph re-rank (PRIMARY FIX)

```
-- BEFORE (additive — graph dominates):
score = (rrf_sparse + aux) + graph_weight * proximity

-- AFTER (multiplicative — graph is tie-breaker):
score = (rrf_sparse + aux) * (1.0 + graph_weight * proximity)
```

At default weight=0.2, max graph boost = 16%. Graph can only amplify already-relevant
items; it cannot promote low-rrf items past high-rrf ones.

### F2: Cardinal raw score blend

```
rrf_sparse = ordinal_rrf + raw_blend_weight * (vec_weight * raw_vec + bm25_weight * raw_bm25)
```

Where `raw_blend_weight = 1/(rrf_k + 1) = 1/61 ~ 0.0164`. This preserves absolute
match strength (cosine=0.98 vs cosine=0.3) within ordinal-same-rank items, adding
~50% more score dynamic range.

### F3: Topic in BM25 signal

```sql
setweight(to_tsvector('english', COALESCE(al.topic, '')), 'A') || al.lesson_tsv
```

Topic terms receive weight 'A' (highest); lesson_text stays at default 'D'.
WHERE clause extended to match topic-only queries.

### F4: Cold-start regression test

`tests/sql/test_graph_domination_fix.sql` — 5 assertions:
1. Probe at top-3 with graph_weight=0
2. Probe at top-3 with default graph_weight
3. Multiplicative invariant: rank=1 at weight=0 implies rank=1 at default
4. navigate_locate probe in top-3
5. Topic-only BM25 match

## Files Changed

| File | Changes |
|------|---------|
| `extension/pgmnemo--0.8.0.sql` | All 3 functions fixed (recall_hybrid 15-col, recall_hybrid 17-col, navigate_locate) |
| `extension/pgmnemo--0.7.2--0.8.0.sql` | navigate_locate fixed |
| `tests/sql/test_graph_domination_fix.sql` | Cold-start regression test (NEW) |

## Before / After (live prod_corpus DB, 14118 lessons, 80299 edges)

| Metric | BEFORE | AFTER |
|--------|--------|-------|
| Probe rank, graph_weight=0 | 1 | 1 |
| Probe rank, graph_weight=0.2 (default) | **5** | **1** |
| Probe score, graph_weight=0 | 0.015487 | 0.022173 |
| Probe score, default | 0.015487 | 0.022173 |
| #1 score (non-probe) at default | 0.163790 (graph-dominated) | 0.009182 (query-relevant) |
| Graph contribution to #1 | +0.16 (additive, 12x rrf) | *1.16 (multiplicative, 16% boost) |

The probe is a synthetic lesson with cosine=1.0 to the query embedding. Before fix,
items with cosine=0.04 ranked above it due to graph proximity. After fix, query
relevance (vector + BM25) drives ranking; graph is a proportional tie-breaker.

## navigate_locate

[evidence] Same bug confirmed. Same fix applied. Probe ranks #1 at both weight=0 and default
after fix.
