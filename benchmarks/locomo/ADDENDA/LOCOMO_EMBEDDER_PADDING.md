# LoCoMo Embedder — Zero-Padding Addendum

**Date:** 2026-05-09
**pgmnemo version:** 0.2.1

## Deviation from paper

LoCoMo paper canonical retriever: `facebook/dragon-plus` (768-dimensional dense encoder, Lin et al. 2023).

pgmnemo v0.2.1 schema enforces `embedding vector(1024)` (hardcoded — fixed in v0.2.2 (planned in next minor release)).

## Mathematical equivalence

We zero-pad DRAGON's 768d output to 1024d before INSERT into pgmnemo:

```
DRAGON output a ∈ ℝ^768
pgmnemo storage a' = pad(a, 1024) = [a_1, ..., a_768, 0, 0, ..., 0]
```

For cosine similarity:
```
cos(a', b') = (a' · b') / (‖a'‖ × ‖b'‖)
            = (a · b + Σᵢ 0·0) / (sqrt(‖a‖² + Σᵢ 0²) × sqrt(‖b‖² + Σᵢ 0²))
            = (a · b) / (‖a‖ × ‖b‖)
            = cos(a, b)
```

Zero-padding preserves cosine similarity exactly. Order of nearest neighbors
under HNSW(vector_cosine_ops) is identical to native 768d index.

## Empirical impact

Recall@K and MRR values reported are **methodologically equivalent to running
on a hypothetical pgmnemo schema with vector(768)**.

The 256 wasted dimensions add ~25% storage overhead per row (not measured for
this run; not a benchmark concern).

## Future fix

pgmnemo v0.2.2 introduces dim-configurable schema, removing the need
for padding. Future LoCoMo runs on v0.2.2 will use native vector(768) DRAGON.
