# ADDENDA: Stella V5 Embedder — rope_theta Fix

**Date:** 2026-05-17  
**Task:** PGMNEMO-260517-1-H02-IMPLEMENT  
**Status:** FIX APPLIED — transformers pinned to 4.44.2

---

## 1. Blocker

`dunzhang/stella_en_1.5B_v5` bundles `modeling_qwen.py` authored against the transformers 4.x
API. Under transformers ≥ 5.0, loading the model raises:

```
AttributeError: 'Qwen2Config' object has no attribute 'rope_theta'
  File "modeling_qwen.py", line ~312, in Qwen2RotaryEmbedding.__init__
      base = config.rope_theta
```

**Root cause:** In transformers 5.x, `Qwen2Config.rope_theta` was absorbed into
`rope_scaling` / `rope_parameters` and is no longer a direct top-level attribute.  
The bench venv shipped with `transformers==5.8.0` (confirmed via
`benchmarks/.venv_bench/venv/lib/python3.11/site-packages/transformers-5.8.0.dist-info/`).

---

## 2. Fix Applied — Option A: transformers pin

**File modified:** `benchmarks/longmemeval/requirements.txt`

```
transformers==4.44.2
```

`transformers==4.44.2` is the last stable 4.x release. It retains `Qwen2Config.rope_theta`
as a direct attribute (present since 4.37.0 when Qwen2 support was added) and is fully
compatible with bge-m3 and sentence-transformers on embedding-only inference.

**Why not Option B (patch modeling_qwen.py):** The patched file lives in HuggingFace cache
and is wiped on model re-download or `huggingface-cli delete-cache`. HIGH maintenance burden
in CI. Option A is reproducible via `pip install -r requirements.txt`.

---

## 3. Version Pin Record

| Package | Before | After |
|---------|--------|-------|
| transformers | 5.8.0 (bench venv) | **4.44.2** (pinned in requirements.txt) |
| sentence-transformers | 5.4.1 | unchanged |
| torch | (existing) | unchanged |

---

## 4. Rebuild Command

To apply the pin to the bench venv:

```bash
source benchmarks/.venv_bench/venv/bin/activate
pip install "transformers==4.44.2"
```

Or from scratch:

```bash
python -m venv .venv_stella
source .venv_stella/bin/activate
pip install -r benchmarks/longmemeval/requirements.txt
pip install torch sentence-transformers huggingface_hub
```

---

## 5. Smoke Test

```bash
source benchmarks/.venv_bench/venv/bin/activate
python - <<'EOF'
from sentence_transformers import SentenceTransformer
m = SentenceTransformer("dunzhang/stella_en_1.5B_v5", trust_remote_code=True)
v = m.encode(["test sentence"])
print(f"OK — shape={v.shape}, dim={v.shape[1]}")   # expect: dim=1024
EOF
```

Expected output: `OK — shape=(1, 1024), dim=1024`

---

## 6. Benchmark Re-run Command

```bash
source benchmarks/.venv_bench/venv/bin/activate
python benchmarks/longmemeval/runner.py \
  --version v0.2.1 \
  --embed-model dunzhang/stella_en_1.5B_v5 \
  --out-dir benchmarks/longmemeval/results/v0.2.1_stella_20260510 \
  --k 20
```

---

## 7. Expected Recall Delta (projection)

Source: `spec/v2/pgmnemo/WG_STELLA_V5_REPRODUCED.md §3`

| Metric | bge-m3 (actual) | Stella V5 (projected) | Δ |
|--------|----------------|-----------------------|---|
| recall@10 | 0.9334 | 0.938–0.946 | +0.4–1.3 pp |
| MRR | 0.8472 | 0.853–0.865 | +0.6–1.8 pp |

**Caveat:** Projected lift is within the bge-m3 CI `[0.9140, 0.9530]`. The re-run confirms
or refutes the projection; it does not claim a headline improvement by itself.
