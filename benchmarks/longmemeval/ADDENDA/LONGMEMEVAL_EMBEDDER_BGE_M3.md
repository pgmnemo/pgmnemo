# LongMemEval Embedder — BAAI/bge-m3 Substitution Addendum

**Date:** 2026-05-09
**pgmnemo version:** 0.2.1

## Deviation from paper

LongMemEval paper canonical retriever: `NovaSearch/stella_en_1.5B_v5` (1024d, MTEB top-tier).

We attempted to use Stella V5 verbatim. Stella V5 ships a bundled
`modeling_qwen.py` referenced via `trust_remote_code=True`. This bundled file
references `Qwen2Config.rope_theta` which is not exposed by the installed
`transformers==5.8.0` Qwen2Config object:

```python
File ".../transformers_modules/.../modeling_qwen.py", line 227, in __init__
    self.rope_theta = config.rope_theta
                      ^^^^^^^^^^^^^^^^^
AttributeError: 'Qwen2Config' object has no attribute 'rope_theta'
```

This is a model-version vs library-version compatibility gap inside Stella V5's
own bundled code. Workarounds (downgrade transformers, patch bundled file) were
deferred for cleanliness.

## Substitute: BAAI/bge-m3

We substituted BAAI/bge-m3:
- **Same dimensionality** (1024d) — no padding required, native fit
- **MTEB top-tier** for English retrieval
- **Multilingual** (bonus over Stella V5 English-only)
- **Matches Agency production embedder** — consistent across pgmnemo benchmarks
  and Agency-side dogfooding

## Methodological impact

**Cannot directly cite paper baselines.** Paper-reported numbers used Stella V5;
our numbers used bge-m3. They are not apples-to-apples.

The pgmnemo retrieval-pipeline behavior (HNSW, 5-component scoring) is identical;
only the embedder differs. So recall@K reflects pgmnemo *with* bge-m3, which is
what an open-source adopter using Agency's stack would see.

## Future fix

When transformers/Stella V5 compatibility is resolved (transformers downgrade
to 4.x or Stella V5 bundled file patch upstream), re-run with paper canonical
embedder for direct comparability. Tracked in WG agenda.
