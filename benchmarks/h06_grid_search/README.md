# H-06 Grid-Search Results

Output directory for the H-06 recency_weight grid-search benchmark (pgmnemo v0.5.0 sprint).

## Cell Schema

Each cell file is a JSON object matching the `benchmarks/gate/v0.4.1.json` schema:

```json
{
  "version": "h06_rw0.3",
  "date": "YYYY-MM-DD",
  "guc_overrides": {"pgmnemo.recency_weight": 0.3},
  "by_category": {
    "temporal": {"n": 92, "recall@10": {"mean": ..., "ci95_lo": ..., "ci95_hi": ...}},
    "single_hop": {...},
    "multi_hop": {...},
    "open_domain": {...},
    "adversarial": {...}
  },
  "overall": {"recall@10": {"mean": ..., "ci95_lo": ..., "ci95_hi": ...}}
}
```

## Files

| File | Description |
|------|-------------|
| `locomo_rw0_05.json` | LoCoMo baseline (recency_weight=0.05, same as gate/v0.4.1.json) |
| `locomo_rw0_1.json` | LoCoMo cell C2 (recency_weight=0.1) |
| `locomo_rw0_3.json` | LoCoMo cell C3 (recency_weight=0.3) — most likely gate passer |
| `locomo_rw0_5.json` | LoCoMo cell C4 (recency_weight=0.5) — watch open_domain regression |
| `lme_rw0_05.json` | LongMemEval baseline (recency_weight=0.05) |
| `lme_rw0_1.json` | LME cell C6 |
| `lme_rw0_3.json` | LME cell C7 |
| `lme_rw0_5.json` | LME cell C8 |
| `VERDICT.md` | Auto-generated verdict after grid run |

## Gate

- **GO:** temporal/recall@10 ≥ 0.7109 (+5.5pp vs baseline 0.6559) at p<0.05, n=92
- **NO-GO:** < +2pp across all 4 recency_weight values

## Run

```bash
# On macOS host
DATABASE_URL="postgresql://postgres:postgres@localhost:5432/postgres" \
  bash scripts/run_h06_bench.sh
```
