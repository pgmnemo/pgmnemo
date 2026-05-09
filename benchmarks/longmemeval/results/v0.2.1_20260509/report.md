# LongMemEval Benchmark — pgmnemo v0.2.1

**Date:** 2026-05-09  **Dataset:** xiaowu0162/longmemeval-cleaned (longmemeval_s_cleaned.json)
**SHA-256:** `d6f21ea9d60a0d56f34a05b609c79c88a451d2ae03597821ea3d5a9678c3a442`  **Retrieval:** BM25 (k1=1.5, b=0.75) — no LLM, no embeddings API
**mode:** real / dry_run: false

## Results by Question Type

| Question Type | Recall@10 [95% CI] | Recall@20 [95% CI] | F1 token overlap [95% CI] | N |
|---|---|---|---|---|
| `single_session_user` | 0.973 [0.948,0.999] | 1.000 [1.000,1.000] | 0.007 [0.005,0.008] | 150 |
| `multi_session_user` | 0.984 [0.961,1.000] | 0.992 [0.976,1.000] | 0.002 [0.001,0.003] | 121 |
| `temporal_reasoning` | 0.976 [0.950,1.000] | 0.992 [0.977,1.000] | 0.004 [0.003,0.004] | 127 |
| `knowledge_update` | 1.000 [1.000,1.000] | 1.000 [1.000,1.000] | 0.002 [0.001,0.002] | 72 |
| `multi_session_topic_absent` | 1.000 [1.000,1.000] | 1.000 [1.000,1.000] | 0.009 [0.008,0.010] | 30 |

## Overall

| Metric | Value |
|---|---|
| Recall@10 | 0.982 [0.970, 0.994] |
| Recall@20 | 0.996 [0.991, 1.000] |
| F1 token overlap | 0.004 [0.004, 0.005] |
| N | 500 |

## Statistical Notes

- Wilson 95% CI on binary recall metrics; t-based CI on continuous F1
- Bonferroni α_corrected=0.01 across 5 question types
- Recall@K: hit=1 if any answer_session_id in top-K BM25 retrieved sessions
- F1: token overlap between top-10 retrieved context tokens and reference answer tokens

## Methodology

1. Each instance's ~53 haystack_sessions indexed as BM25 corpus
2. BM25 retrieves top-K sessions by question text similarity
3. recall@K = answer_session_id in top-K retrieved sessions
4. F1 = token overlap(top-10 retrieved text, reference answer)
5. No LLM judge, no embedding API — pure BM25 (stdlib only)
