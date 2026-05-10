# LongMemEval — pgmnemo v0.2.1 with Stella V5 (Paper Canonical Embedder)

**Date:** 2026-05-10  
**Task:** WG-BENCH-5  
**Status:** BLOCKED — environment incompatibility prevents actual model inference  
**Target embedder:** `dunzhang/stella_en_1.5B_v5` (Wu et al. ICLR 2025 paper canonical)

---

## Why This Directory Exists

This results directory was created as part of WG-BENCH-5. The actual benchmark run is
blocked by a transformers version incompatibility (see diagnosis below). Once the
environment is fixed, the runner will populate:

- `metrics.json` — full metrics + CI
- `report.md` — human-readable report
- `raw_retrievals.jsonl` — per-item retrieval results

---

## Blocking Incompatibility

**Error:** `AttributeError: 'Qwen2Config' object has no attribute 'rope_theta'`  
**Location:** bundled `modeling_qwen.py` (≈line 312) in `dunzhang/stella_en_1.5B_v5`  
**Triggered by:** `transformers >= 5.0` (current environment: 5.8)  
**Root cause:** `rope_theta` was promoted from a direct `Qwen2Config` attribute into the
`rope_scaling` dict in transformers 5.0. The model's bundled code still accesses it as
`config.rope_theta`.

---

## Resolution

Apply ONE of:

**Option A (recommended):** `pip install "transformers==4.44.2"` in a fresh venv.

**Option B (patch):** In the model's cached `modeling_qwen.py`, replace:
```python
base = config.rope_theta
```
with:
```python
base = getattr(config, 'rope_theta', None)
if base is None:
    rs = getattr(config, 'rope_scaling', None) or {}
    base = rs.get('rope_theta', 1_000_000.0)
```

---

## Re-run Command (after env fix)

```bash
python benchmarks/longmemeval/runner.py \
  --version v0.2.1 \
  --embed-model dunzhang/stella_en_1.5B_v5 \
  --out-dir benchmarks/longmemeval/results/v0.2.1_stella_20260510 \
  --k 20
```

---

## Projected Results (from MTEB gap analysis)

| Metric | bge-m3 actual | Stella V5 projected |
|---|---|---|
| recall@10 | 0.9334 | 0.938–0.946 |
| MRR | 0.8472 | 0.853–0.865 |

Full analysis: `spec/v2/pgmnemo/WG_STELLA_V5_REPRODUCED.md`
