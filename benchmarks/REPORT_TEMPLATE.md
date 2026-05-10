# Benchmark Report: pgmnemo v{VERSION}

**Report date:** YYYY-MM-DD  
**Prepared by:** {Author}  
**Status:** DRAFT / WG REVIEW / APPROVED  

---

## 0. Executive Summary

| | |
|---|---|
| Version | v{VERSION} |
| Previous version | v{PREV_VERSION} |
| Decision | SHIP / HOLD / CONDITIONAL SHIP |
| Key finding | _{one sentence: what changed and whether it's statistically significant}_ |

---

## 1. Methodology

### 1.1 Conformance

Runs conform to `benchmarks/_TEMPLATE/METHODOLOGY.md` with the following addenda:

_(list any deviations or "none")_

### 1.2 Run Configuration

| Parameter | LoCoMo | LongMemEval |
|-----------|--------|-------------|
| Dataset | snap-research/locomo (locomo10.json) | xiaowu0162/longmemeval-cleaned (longmemeval_s_cleaned.json) |
| Dataset SHA256 | {SHA} | {SHA} |
| Embedder | {model} | {model} |
| pgmnemo version | v{VERSION} | v{VERSION} |
| Retrieval method | {method} | {method} |
| n evaluated | {N} | {N} |
| Device | {device} | {device} |
| Wall clock | {sec}s | {sec}s |
| Run date | YYYY-MM-DD | YYYY-MM-DD |

### 1.3 Methodology Changes vs. Previous Version

_(Describe any changes to retrieval method, embedder, dataset version, or evaluation protocol. If none: "No changes to methodology.")_

---

## 2. Results: LoCoMo

### 2.1 Overall Metrics

| Metric | v{PREV} mean | v{PREV} 95% CI | v{VERSION} mean | v{VERSION} 95% CI | Δ | z | p_raw | p_corrected | h | Significant? |
|--------|-------------|----------------|-----------------|-------------------|----|---|-------|-------------|---|--------------|
| recall@5 | | | | | | | | | | |
| recall@10 | | | | | | | | | | |
| recall@25 | | | | | | | | | | |
| recall@50 | | | | | | | | | | |
| MRR | | | | | | | | | | |

_p_corrected: Holm-Bonferroni across all metrics in this report. h: Cohen's h effect size._

### 2.2 Per-Category Breakdown

| Category | n | recall@5 | recall@10 | MRR | Δ recall@10 vs prev | Sig? |
|----------|---|----------|-----------|-----|---------------------|------|
| single_hop | | | | | | |
| multi_hop | | | | | | |
| temporal | | | | | | |
| open_domain | | | | | | |
| adversarial | | | | | | |

---

## 3. Results: LongMemEval-S

### 3.1 Overall Metrics

| Metric | v{PREV} mean | v{PREV} 95% CI | v{VERSION} mean | v{VERSION} 95% CI | Δ | z | p_raw | p_corrected | h | Significant? |
|--------|-------------|----------------|-----------------|-------------------|----|---|-------|-------------|---|--------------|
| recall@1 | | | | | | | | | | |
| recall@5 | | | | | | | | | | |
| recall@10 | | | | | | | | | | |
| recall@20 | | | | | | | | | | |
| MRR | | | | | | | | | | |

### 3.2 Per-Question-Type Breakdown

| qtype | n | recall@10 | MRR | Δ recall@10 vs prev | Sig? |
|-------|---|-----------|-----|---------------------|------|
| single_session_user | | | | | |
| multi_session_user | | | | | |
| multi_session_topic_absent | | | | | |
| temporal_reasoning | | | | | |
| knowledge_update | | | | | |

---

## 4. Statistical Summary

_(Output of `scripts/significance_test.py {prev_metrics.json} {curr_metrics.json}` — paste verbatim)_

```
[paste significance_test.py output here]
```

---

## 5. Threats to Validity

### 5.1 Internal Validity

_(e.g., simulation vs. real DB run; proxy embedder vs. canonical; any known confounds)_

### 5.2 External Validity

_(e.g., dataset representativeness; known gaps in coverage)_

### 5.3 Simulation Notes

_(If any run used simulation mode: describe what was simulated, what the lower-bound / upper-bound implications are, and whether results should be treated as conservative or optimistic estimates)_

---

## 6. Decision

### 6.1 Decision Matrix Applied

_(Copy the applicable row from docs/RELEASE_PROCESS.md §5 and fill in the blanks)_

| Primary metric | Secondary metric | Applied rule | Decision |
|----------------|-----------------|--------------|----------|
| | | | |

### 6.2 Rationale

_(2–4 sentences: what the data shows, what is and is not claimed, why the decision is Ship/Hold/Conditional)_

### 6.3 Prohibited Claims Check

- [ ] No metric claimed as improved where p_corrected ≥ 0.05
- [ ] All metrics reported (no cherry-picking)
- [ ] Any "X pp improvement" claim cites metric name, CI, and p-value

---

## 7. WG Discussion Notes

_(Record key discussion points, dissenting views, questions raised during WG review)_

---

## 8. WG Sign-off

| Role | Name | Signature | Date | Notes |
|------|------|-----------|------|-------|
| PI | | | | |
| Chief Architect | | | | |
| StatAnalyst | | | | |
| ResSup | | | | |

**All four signatures required before tag is cut.** (Exception: documented quorum per RELEASE_PROCESS.md §4.3)

---

## 9. Appendix: Raw Data References

- LoCoMo metrics: `benchmarks/locomo/results/{run_dir}/metrics.json`
- LoCoMo raw retrievals: `benchmarks/locomo/results/{run_dir}/raw_retrievals.jsonl`
- LongMemEval metrics: `benchmarks/longmemeval/results/{run_dir}/metrics.json`
- LongMemEval raw retrievals: `benchmarks/longmemeval/results/{run_dir}/raw_retrievals.jsonl`
- significance_test.py version: `{git_sha}`
