# Production Readiness — pgmnemo v0.2.1 Beta

**Version:** v0.2.1  
**Status:** Public Beta  
**Last updated:** 2026-05-09

This page answers four questions directly. No marketing language.

---

## 1. What does "beta" mean here?

**Beta means:** the core retrieval API (`recall_lessons`, `store_lesson`, `traverse_causal_chain`) is stable enough for production evaluation, but we have not yet run a sustained load campaign in a multi-tenant production environment and cannot guarantee forward API stability across minor versions.

Specifically:
- SQL function signatures may change between 0.x minor versions (breaking changes will appear in CHANGELOG with migration SQL).
- GUC names (`pgmnemo.ef_search`, `pgmnemo.recency_weight`, `pgmnemo.tenant_id`) are considered stable for 0.2.x but may be renamed in 0.3.x.
- The upgrade path (`ALTER EXTENSION pgmnemo UPDATE TO '...'`) is tested for sequential upgrades only; skip-version upgrades are not validated.

Beta does **not** mean experimental or unreliable for single-tenant deployments on PG17.

---

## 2. What is tested?

| Area | What we test | Evidence |
|---|---|---|
| **Retrieval accuracy** | LoCoMo (1 982 Q&A pairs, 10 conversations): recall@10 = **0.795**, MRR = 0.548 | [`benchmarks/locomo/results/v0.2.1_session_20260509/report.md`](../benchmarks/locomo/results/v0.2.1_session_20260509/report.md) |
| **Retrieval accuracy** | LongMemEval (500 questions, bge-m3 embedder): recall@10 = **0.933**, MRR = 0.855 | [`benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/report.md`](../benchmarks/longmemeval/results/v0.2.1_pgmnemo_20260509/report.md) |
| **Schema correctness** | `make installcheck` on vanilla PG17 Docker (amd64) | CI on every PR |
| **Upgrade path** | Sequential upgrade scripts from 0.1.4 → 0.2.0 → 0.2.0.1 → 0.2.1, idempotent DDL guards | CHANGELOG §Upgrade sections |
| **RLS isolation** | `pgmnemo.tenant_id` GUC policies: tenant A cannot read tenant B rows | Manual verification per INS-032 |
| **Bug regression** | Named regressions for every INS-* fix: IN-param collision (INS-029), numeric cast (INS-030), idempotent DDL (INS-031) | CHANGELOG v0.2.0.1, v0.2.1 |
| **Cycle guard** | `traverse_causal_chain` cycle detection via path array, all three direction modes | Unit test in `extension/sql/test_traverse.sql` |
| **EF search GUC** | `pgmnemo.ef_search` applied at `recall_lessons()` entry, clamped 10–500 | CHANGELOG v0.2.1 |

**Embedder note:** All benchmark numbers use retrieval-only mode. No LLM-as-judge downstream evaluation has been run yet (see §3).

---

## 3. What is not yet guaranteed?

| Gap | Detail |
|---|---|
| **LLM-as-judge / end-to-end QA accuracy** | We report retrieval recall@K only. Downstream answer quality (the metric competitors report as "LLM-judge accuracy") is not yet measured for pgmnemo. |
| **PG14–16 compatibility** | Install and upgrade scripts work on PG14–16 in informal testing; numeric cast fix (INS-030) was the only known PG14 regression. Formal `installcheck` CI does not run on PG14–16. |
| **Sustained load / p99 latency at scale** | No stress-test or sustained load campaign has been run. The `US-A2` acceptance criterion (≤40 ms p95 on 10K entries) is a design target, not a validated result. |
| **`arm64` prebuilt binary** | Source build works on arm64; prebuilt `.so` for arm64 is not yet distributed. |
| **Skip-version upgrades** | Upgrading from 0.1.x directly to 0.2.1 (skipping intermediate versions) is untested. |
| **Multi-tenant RLS under adversarial load** | RLS policies have been reviewed for correctness but not fuzz-tested or audited by a third party. |
| **Recency weight calibration** | `pgmnemo.recency_weight` default lowered from 0.20 → 0.08 in v0.2.1 pending REC-1 ablation study. The ablation has not been published; the current default is a provisional best estimate. |

---

## 4. What must a production adopter verify on their side?

Before running pgmnemo in a workload that matters, verify the following:

1. **Run `make installcheck` against your target PG version.**  
   If your PG version is not 17, run the test suite explicitly. PG14–16 deviations will surface here.

2. **Smoke-test the upgrade path from your current version.**  
   Run each `ALTER EXTENSION pgmnemo UPDATE TO '...'` step sequentially in a staging environment before applying to production.

3. **Validate RLS with your tenant ID scheme.**  
   Set `pgmnemo.tenant_id` and confirm cross-tenant queries return empty results. Do not rely on application-layer filtering alone.

4. **Measure your own p95 latency on your corpus size.**  
   Index your `agent_lesson` table with HNSW before load. Tune `pgmnemo.ef_search` (default 100) for your recall/latency tradeoff. The ≤40 ms p95 target was not benchmarked on real hardware.

5. **Pin the extension version in your migration scripts.**  
   Use `ALTER EXTENSION pgmnemo UPDATE TO '0.2.1'` explicitly, not `UPDATE` (latest). Minor version API changes are documented but will not be held back for you.

6. **Do not rely on LLM-as-judge accuracy numbers from competitor papers.**  
   pgmnemo v0.2.1 publishes retrieval recall only. If your application needs QA accuracy guarantees, you must run your own end-to-end evaluation.

---

*Honest assessment, not a sales page. If you find a gap not listed here, open an issue.*
