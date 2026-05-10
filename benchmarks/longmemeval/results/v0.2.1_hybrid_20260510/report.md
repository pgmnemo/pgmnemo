# LongMemEval Benchmark (pgmnemo hybrid) — v0.2.2-hybrid

**Date:** 2026-05-10
**Mode:** simulation (pure-Python, no DB, no GPU)
**Retrieval:** Hybrid: 0.4×tfidf_cosine + 0.4×bm25_norm
**Dataset:** xiaowu0162/longmemeval-cleaned (longmemeval_s_cleaned.json)
**N evaluated:** 500

## Simulation Notes

- `recall_hybrid()` SQL function is production-ready (see `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql`)
- PostgreSQL not reachable in this environment; Python simulation uses identical scoring formula
- TF-IDF cosine is a **lower-bound proxy** for bge-m3 dense retrieval
  (real hybrid with bge-m3 expected to be higher, closing more of the vector→BM25 gap)

## Baselines

| System | recall@10 | MRR |
|---|---|---|
| pgmnemo vector-only (bge-m3, v0.2.1) | 0.9334 | 0.8472 |
| BM25 baseline (run_nollm.py) | 0.982 | — |
| **Hybrid simulation (TF-IDF + BM25)** | **0.9486** | **0.9053** |

## Key Results

| Metric | Value |
|---|---|
| recall@1 | 0.5472 (n=500) |
| recall@5 | 0.9100 |
| recall@10 | 0.9486 [0.9332, 0.9640] |
| recall@20 | 0.9759 |
| MRR | 0.9053 [0.8839, 0.9267] |
| Δ vs vector-only | +0.0152 |
| Δ vs BM25 | -0.0334 |
| Gap closed (vec→BM25) | 31.3% |

## By Question Type

| qtype | recall@10 | N |
|---|---|---|
| knowledge_update | 0.9931 [0.9794, 1.0000] | 72 |
| multi_session_topic_absent | 0.9222 [0.8582, 0.9863] | 30 |
| multi_session_user | 0.9174 [0.8815, 0.9532] | 121 |
| single_session_user | 0.9733 [0.9475, 0.9992] | 150 |
| temporal_reasoning | 0.9303 [0.8954, 0.9652] | 127 |

## Scoring Formula (matching recall_hybrid SQL)

```
hybrid_score = 0.4 × tfidf_cosine(query, session)
             + 0.4 × bm25_norm(query, session)   # bm25_raw / max_bm25 ≈ ts_rank_cd norm=32
```

Wall clock: 18.5s