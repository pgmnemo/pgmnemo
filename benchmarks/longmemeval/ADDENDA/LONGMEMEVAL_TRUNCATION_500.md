# LongMemEval Session Truncation — 500 chars Addendum

**Date:** 2026-05-09

## Deviation from paper

Paper does not truncate haystack sessions. Sessions in `longmemeval_s_cleaned`
average ~115K tokens / 500 ≈ 230 tokens per session, but distribution is wide
(some sessions are full multi-turn dialogs >2000 chars).

## Constraint

Apple Silicon MPS GPU with bge-m3 hits OOM at higher batch sizes when token
length per item is large. To make the run completable on commodity hardware
(M-series with 24 GiB unified memory), we truncated each session to **500 chars**
before embedding.

## Impact analysis

- Sessions ≤ 500 chars (majority): **no impact**, full content embedded
- Sessions > 500 chars (long dialogs): **truncated**, may discard relevant
  content from later turns. Could lower recall@K on questions whose ground-truth
  evidence is in late dialog turns.

## Mitigation paths (for WG)

1. Use longer max_length on H100/A100 GPU (production benchmark hardware) — no truncation
2. Hierarchical encode (chunk session into 500-char chunks, mean-pool embeddings)
3. Switch to embedder with longer context window (e.g. nomic-embed 8192 ctx)

## Why we chose to truncate vs skip

Reproducibility on commodity hardware was prioritized. Future runs on cloud GPU
should drop this truncation entirely.
