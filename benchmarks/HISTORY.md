# Benchmark History — Methodology Corrections

This file logs every benchmark methodology change that affects published metrics,
even when pgmnemo source itself is unchanged. Per principle:
> A change in benchmark methodology that materially changes metrics must be
> explicitly documented and re-published.

---

## 2026-05-09 — LoCoMo granularity correction

**Source change:** none (pgmnemo v0.2.1 unchanged)
**Methodology change:** corpus extraction granularity, turn-level → session-level
**Reason:** Maharana ACL 2024 §4.2 evaluates at session level. Evidence refs
like "D1:3" are dialog session refs. Our previous turn-level extraction
(5882 segments per 10 conversations) was an interpretation bug.
**Impact:**

| Metric | Turn-level (deprecated) | Session-level (canonical) | Δ |
|---|---|---|---|
| recall@10 | 0.366 | **0.795** | +43pp |
| recall@25 | 0.477 | 0.962 | +49pp |
| recall@50 | 0.574 | 0.999 | +43pp |
| MRR | 0.237 | 0.548 | +31pp |

**Canonical result:** [v0.2.1_session_20260509/](locomo/results/v0.2.1_session_20260509/)
**Deprecated:** [v0.2.1_20260509/](locomo/results/v0.2.1_20260509/)
**Commits:** [b0ef466](https://github.com/pgmnemo/pgmnemo/commit/b0ef466)

---

## 2026-05-09 — LongMemEval embedder substitution

**Source change:** none
**Methodology change:** embedder, NovaSearch/stella_en_1.5B_v5 (paper canonical)
→ BAAI/bge-m3 (substitute)
**Reason:** Stella V5 bundled `modeling_qwen.py` incompatible with transformers 5.8
(`Qwen2Config.rope_theta` AttributeError). bge-m3 is same dim (1024d), MTEB-strong.
**Impact:** unmeasured directly (Stella V5 reproduction pending). bge-m3 typically
performs within 1-3pp of Stella V5 on MTEB English retrieval; expect comparable.

---

## 2026-05-09 — LongMemEval truncation correction (resolved (delta=0, addendum removed))

**Source change:** none
**Methodology change:** session text truncation, 500-char (custom) → 512-token
(bge-m3 default)
**Reason:** original 500-char truncation was a config bug (bge-m3 max_seq_length
default is 8192 tokens, but batch_size=32 caused MPS OOM, not text length).
Proper config: max_seq_length=512 token cap + batch=8 fits MPS without OOM.
**Impact:** QUICK-C re-run (v0.2.1_pgmnemo_20260509) showed recall@10 delta = 0.0008 — near-zero impact.
**Addendum:** ADDENDA/LONGMEMEVAL_TRUNCATION_500.md removed — "MPS memory constraint" claim was false; real cause was batch size, not text length.

---

## Update protocol

Whenever a benchmark result is added or methodology changes:

1. Add new entry at the top of this file with date, source change vs methodology change, impact table
2. Mark deprecated results clearly in their report.md with link to new canonical
3. Update README.md headline numbers to canonical values
4. Commit with message format: `benchmarks(<bench>): <one-line change> → <metric delta>`

This file is the audit trail for every metric we publish.
