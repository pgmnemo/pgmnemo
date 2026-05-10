# pgmnemo Roadmap

**Last updated:** 2026-05-10  
**Maintainer:** Project Lead (PI)  
**Next review:** at v0.3.0 tag

> **Horizon rule:** this roadmap covers the next two releases in detail (H1 + H2). Items beyond two releases live in the hypothesis backlog (`spec/v2/pgmnemo/HYPOTHESIS_BACKLOG_*.md`) until they are prioritized.

---

## Current Baselines (v0.2.1)

| Benchmark | Metric | Value |
|-----------|--------|-------|
| LoCoMo (n=1982) | recall@5 | 0.662 |
| LoCoMo (n=1982) | recall@10 | **0.795** |
| LoCoMo (n=1982) | MRR | 0.548 |
| LongMemEval-S (n=500) | recall@10 | **0.933** |
| LongMemEval-S (n=500) | MRR | 0.847 |

---

## Release Timeline

```
Apr 2026   May 2026              May–Jun 2026        Jun–Jul 2026
────────── ──────────────────── ──────────────────── ─────────────
v0.2.1 ──► v0.2.2 candidate ──► v0.3.0 ──────────► v0.3.1+
(SHIPPED)  (in review)          (target 2026-05-17)  (next horizon)
```

---

## H1 — v0.2.2 (candidate, expected 2026-05-14)

**Theme:** Hybrid retrieval — experimental opt-in for hard recall cases

**Status:** WG decision made 2026-05-10 (see `spec/v2/pgmnemo/HYBRID_DECISION_2026-05-10.md`).

### What's in

| Feature | Status | Notes |
|---------|--------|-------|
| `pgmnemo.recall_hybrid()` | ✅ implemented | EXPERIMENTAL, NOT default; `recall_lessons()` unchanged |
| Migration `pgmnemo--0.2.1--0.2.2-hybrid.sql` | ✅ ready | Opt-in upgrade |
| LongMemEval hybrid bench harness | ✅ ready | `benchmarks/scripts/run_longmemeval_hybrid.py` |
| `docs/USAGE.md` hybrid section | ✅ written | EXPERIMENTAL label prominent |

### Evidence (simulation — real-DB pending)

| Benchmark | Metric | Vector-only | Hybrid | Δ | Significant? |
|-----------|--------|-------------|--------|---|--------------|
| LoCoMo | recall@10 | 0.795 | 0.922 | **+12.7pp** | ✅ YES (CIs disjoint) |
| LoCoMo | MRR | 0.548 | 0.768 | **+22pp** | ✅ YES |
| LongMemEval | recall@10 | 0.933 | 0.949 | +1.5pp | ❌ NO (p=0.308) |
| LongMemEval | MRR | 0.847 | 0.905 | **+5.8pp** | ✅ YES (p=0.005) |

> ⚠️ Numbers are simulation (TF-IDF proxy for dense retrieval). Real-DB bench required before promotion to default.

### Release gates remaining

- [ ] Real-DB benchmark confirmation (localhost:15432 must be reachable)
- [ ] `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql` `EXPERIMENTAL` comment in-code (see HYBRID_DECISION action item 3)
- [ ] PGXN bundle for v0.2.2 (META.json + zip)
- [ ] PGXN v0.2.1 publish unblocked (prerequisite)

### Promotion criteria (EXPERIMENTAL → default)

`recall_hybrid()` becomes the default retrieval function when **any one** of:
- Real-DB bench confirms LoCoMo recall@10 ≥ +12pp
- 2+ production adopters report positive outcome
- Third dataset (not LoCoMo, not LongMemEval) shows uniform lift across all categories
- LongMemEval recall@10 p-value < 0.05 with real embeddings

---

## H1 — v0.3.0 (target: 2026-05-17)

**Theme:** MAGMA §3 — edge taxonomy schema (foundation for graph-aware retrieval)

**Status:** 🔴 BLOCKED — migration script has 2 critical bugs. Fix required before any bench.

### What's in

| Feature | Status | Blocker |
|---------|--------|---------|
| `edge_kind` ENUM (`semantic`, `temporal`, `causal`, `entity`) | 🔴 blocked | Migration references `edge_type` (wrong column name) |
| 4 partial B-tree indexes per edge kind | 🔴 blocked | Same — cannot test until schema applies |
| `recall_lessons()` BFS fix using `edge_kind` | 🔴 blocked | Depends on schema |
| `traverse_causal_chain()` updated for new ENUM | 🔴 blocked | References `me.edge_type` (must be `relation_type`) |
| `pgmnemo--0.2.1--0.3.0.sql` migration | 🔴 2 bugs | See `spec/v2/pgmnemo/V0.3.0_AUDIT_2026-05-10.md` |

### P0 Blockers (must fix before any other v0.3.0 work)

**Bug 1 — S3 wrong column name:**  
Migration `S3_BACKFILL` references `edge_type` column that doesn't exist.  
Fix: replace `edge_type` with `relation_type` throughout backfill block.

**Bug 2 — S8 traverse function wrong column:**  
`traverse_causal_chain()` body references `me.edge_type`.  
Fix: replace with `me.relation_type`.

**Bug 3 — Case mismatch:**  
v0.2.1 stores uppercase values (`CAUSED_BY`). Migration expects lowercase enum.  
Fix: add `UPPER()` cast or enum values to match existing data.

### What v0.3.0 explicitly defers

- MAGMA §4 (Adaptive Traversal Policy) → v0.3.x+
- MAGMA §5 (Dual-stream Consolidation) → v0.3.x+
- DIM-FLEX (embedding dimension configurability) → v0.3.x — **marked as phantom-closed; needs real implementation** (4 hardcoded `vector(1024)` remain)
- RESTORE-C1/C2/C3 → v1.0 scope

### Release gates

- [ ] P0 migration bugs fixed (all 3)
- [ ] Migration applied to clean schema → zero errors
- [ ] Migration idempotent (second application → zero errors)
- [ ] `make check` + `pg_regress` pass
- [ ] LoCoMo bench on v0.3.0 vs v0.2.1 (expected: no regression; graph schema is additive)
- [ ] Rollback branch `rollback/v0.2.1` exists and is tested
- [ ] ExpDesigner GO on bench report
- [ ] ResSup sign-off on any public benchmark claims

---

## H2 — v0.3.1+ (planned scope, target: 2026-06-07)

**Theme:** Retrieval quality improvements — real-bench validated

> Scope is provisional. Final selection after v0.3.0 bench results and hypothesis re-scoring.

### Candidate items (by ICE score)

| Hypothesis | ICE | RICE | Expected lift | Status |
|------------|-----|------|---------------|--------|
| H-06: Temporal weight tuning | 15.4 | 4.40 | +3–6pp LoCoMo temporal category | Ready; low-effort |
| H-02: Stella V5 compatibility | 14.4 | 4.80 | +1–3pp LongMemEval | Ready; 1-day effort |
| H-04: Scoring weight grid search | 13.75 | 2.75 | +2–5pp | Overfitting risk — holdout set required |
| H-05: DIM-FLEX / DRAGON 768d | 11.4 | 1.90 | 0pp metric, −25% storage | Blocked on DIM-FLEX real impl |

### H-01 special status

H-01 (Hybrid BM25+vector RRF) — **ICE 24.0, highest in backlog** — is currently blocked on a feasibility question: does `pg_trgm` or `pgroonga` give sufficient BM25 signal without adding a hard dependency?

A dedicated feasibility task is required before H-01 can enter an iteration. If feasibility passes, H-01 should be prioritized over all H2 candidates.

---

## v1.0 Horizon (no date — gated on evidence)

v1.0 requires all of the following:

| Gate | Current state |
|------|---------------|
| H-1 through H-5 hypotheses: all pass bench significance | H-1 (hybrid): ✅ EXPERIMENTAL; H-2 through H-5: open |
| RESTORE stack (C1/C2/C3) live and bench-validated | Not started |
| Real-DB bench confirms all simulation results | Pending |
| External adopter count ≥ 2 with production validation | 0 confirmed |
| API stability: no breaking changes in ≥ 2 consecutive releases | In progress |
| Academic paper submitted (ICSE-SEIP or equivalent) | Drafting |

---

## PGXN Publish Status

| Version | PGXN status | Blocker |
|---------|-------------|---------|
| v0.2.1 | 🟡 bundle ready, not published | Project Lead must upload zip manually at manager.pgxn.org |
| v0.2.2 | 🔴 pending | v0.2.1 must publish first |
| v0.3.0 | 🔴 pending | v0.2.2 + migration fixes |

---

## What Is Not On This Roadmap

Items that were discussed but are not scheduled (reasons noted):

| Item | Decision | Reason |
|------|----------|--------|
| Promote `recall_hybrid()` to default | ❌ NOT scheduled | Simulation-only evidence; real-DB bench first |
| DIM-FLEX as shipped feature | ❌ Reopened (was phantom-closed) | 4 hardcoded `vector(1024)` remain; needs real implementation |
| BM25 as a hard extension dependency | 🟡 Feasibility study only | H-01 requires `pg_trgm` / `pgroonga` decision |
| Multi-tenant RBAC (beyond RLS) | 🔵 Backlog | Low ICE; no external requester yet |
| REST API wrapper | 🔵 Backlog | pgmnemo is an extension, not a service |

---

## Roadmap Change Policy

- **Minor scope trims** (remove item from a release): PI unilateral  
- **Scope additions** (add item to a release already in progress): WG 3/5 vote  
- **Release date changes** ≤ 1 week: PI unilateral with Monday status sync notice  
- **Release date changes** > 1 week: WG notified; no vote required but reason must be documented  
- **Horizon 2 reprioritization**: PI proposes after H1 closes; WG 3/5 vote  

*This document is updated at every release tag. Changes tracked in git log.*
