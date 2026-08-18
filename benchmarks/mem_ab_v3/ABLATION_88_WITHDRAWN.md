# Ablation #88 — withdrawn before publication

**Status:** the protocol cannot answer its own question. Withdrawn 2026-08-18, before any of it was
published. This file stays in the repository because a retracted experiment is more useful to the
next person than a deleted one.

## What it claimed

That enabling `graph_proximity_weight` gives zero measurable recall improvement — `hit@10 = 0.0000`
in both arms, McNemar degenerate, "NULL_RESULT, publishable".

## Why that claim is not available

Both arms are pinned at zero **by construction**, so the comparison had no room to move.

Probes were selected with `seed_target_cosine < 0.7`, sorted ascending, which produced a band of
0.225–0.347: the target lesson is semantically far from the query. But `recall_hybrid` retrieves its
candidates by ANN search (`LIMIT max(k*4, 100)`) and graph proximity is a **multiplier on candidates
already retrieved** — it cannot pull a lesson into the pool. A target at cosine 0.23 is never in the
pool, so neither arm can hit it, whatever the graph does.

The pilot already showed 0/50 in both arms. That is a stop signal to redesign, not a reason to
scale to n=1500.

## The measurement that settles it

40 edge pairs per cosine band on the same bench (`pgmnemo_ablation_88`), `recall_hybrid` at k=10,
δ=0.0 versus δ=0.2:

| Cosine band | In protocol? | Hits without graph | Hits with graph |
|---|---|---|---|
| 0.20–0.40 | yes — the band it ran in | 0 / 40 | 0 / 40 |
| 0.70–0.85 | excluded | 24 / 40 | 25 / 40 |
| 0.85–1.00 | excluded | 26 / 40 | 26 / 40 |

The probe filter, not the graph signal, determined the outcome. In the band where anything is
measurable at all, the graph moves one probe out of forty.

## What survives

- **The structural finding.** Graph proximity re-ranks; it does not retrieve. Reaching a lesson the
  ANN pool never contained requires expanding the candidate pool, which is an architecture change,
  not a weight.
- **The latency check.** With the cycle guard and depth capped at 2, the walk costs nothing
  measurable: p50 delta −0.2 ms, zero timeouts in 3000 calls.
- **This retraction**, and the reason for it.

## What a valid protocol needs

Probes in a band where the baseline arm is non-zero (cosine ≥ 0.7 on this corpus), power computed
from that non-zero baseline, and — if the question is whether graph traversal *retrieves* rather
than *reorders* — a candidate pool the graph is allowed to extend.
