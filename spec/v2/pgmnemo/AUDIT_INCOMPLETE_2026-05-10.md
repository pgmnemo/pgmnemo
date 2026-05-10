# pgmnemo Incomplete Task Audit — 2026-05-10

**Auditors:** process_guardian (78) + technical_lead (5)  
**Scope:** All open/delegated/escalated/inbox pgmnemo tasks  
**Date:** 2026-05-10  
**Authority:** ACM-PGMNEMO-WORKFLOW-1 Phase 3

---

## Summary

10 open tasks identified. 1 confirmed phantom-close (artifact absent in repo). 1 stale/superseded. 2 legitimately blocked (require §3 migration fix first). 3 require human/external action. 3 require engineering effort within iteration cycle.

Additionally, 3 new tasks are identified from the V0.3.0_AUDIT that are not yet in the task system.

---

## Audit Table

| task_id | title | current_status | artifact_present | real_state | recommended_action | version |
|---|---|---|---|---|---|---|
| 5587 | [ACM-PGMNEMO-WORKFLOW-1] WG coordination + workflow | DELEGATED | Yes — 4 spec docs | IN_PROGRESS | Keep open; close on doc completion | infra |
| 5585 | [HYBRID-DROP-OR-DEMOTE] recall_hybrid() decision | NEXT | No (decision doc) | REAL OPEN — WG decision needed | WG sync: ship as opt-in OR drop before v0.3.0 tag | v0.2.x / pre-v0.3.0 |
| 5269 | [v0.2.2-DIM-FLEX] Embedding dim configurable | DELEGATED | **NO — vector(1024) hardcoded in 4 places in pgmnemo--0.2.1.sql** | **PHANTOM-CLOSE** | Reopen; spawn implementation task | v0.3.x or v0.2.2 |
| 5257 | [GH-C3-EXAMPLES] Reorganize examples/ by user job | ESCALATED | No | REAL OPEN — not started | Backlog; assign to growth_lead (92) | v0.3.x |
| 5237 | [P1.1-PGXN-PUBLISH] Submit v0.2.1 to PGXN | DELEGATED | No (requires human action on pgxn.org) | LEGITIMATELY BLOCKED — human action required | Assign to growth_lead (92) to execute manually | infra |
| 5196 | [RESTORE-C2-HYPERMEM] HyperMem Stage-1 routing | ESCALATED | No | REAL OPEN — not started | DEFER: out of v0.3.0 MAGMA scope per V0.3.0_AUDIT | v0.4.x+ |
| 5191 | [BENCH-B5] CI scheduled nightly + on-tag | INBOX | No | REAL OPEN — not started | Assign to TL (5) for v0.3.x iteration | v0.3.x |
| 5168 | [MAGMA-4] Dual-stream consolidation (MAGMA §5) | ESCALATED | No | REAL OPEN — not started | BLOCKED on §3 migration fix; requeue for v0.3.x | v0.3.x |
| 5167 | [MAGMA-3] Adaptive Traversal Policy (MAGMA §4) | ESCALATED | No | REAL OPEN — not started | BLOCKED on §3 migration fix; requeue for v0.3.x | v0.3.x |
| 5128 | [P0-CRITICAL] Apply v0.2.0.1 hotfix | INBOX | N/A | **STALE** — v0.2.1 shipped and supersedes v0.2.0.1 | CANCEL | cancelled |

---

## Phantom-DONE Detail

### task 5269 — [v0.2.2-DIM-FLEX]

**Status in task system:** DELEGATED  
**Auto-close commit:** d0eeb9b (run #9096 claimed completion)  
**Evidence that work was NOT done:**

```
$ grep -c "vector(1024)" extension/pgmnemo--0.2.1.sql
4
```

`pgmnemo.embedding_dim` GUC is not present in the extension source. Four hardcoded `vector(1024)` occurrences remain in the v0.2.1 schema file. The dim-flex feature was claimed complete but the implementation artifact is absent.

**Classification:** Phantom-close (auto-close triggered by DAG task DAG without implementation validation).

**Recommended action:** Reopen as IN_PROGRESS. Spawn new IMPL task: replace `vector(1024)` with GUC-driven dimension using the AGENT_PROMPT_TEMPLATE RESEARCH→PLAN→IMPL→REVIEW→BENCH pipeline.

---

## New Tasks Identified (not yet in system)

From `spec/v2/pgmnemo/V0.3.0_AUDIT_2026-05-10.md`:

| new_task_tag | description | priority | blocks |
|---|---|---|---|
| [V030-FIX-S3] | Fix migration S3: replace `edge_type` with `relation_type`; add uppercase value mapping | P0 | v0.3.0 release |
| [V030-FIX-S8] | Fix migration S8: replace `me.edge_type` with `me.relation_type` in both UNION ALL branches of traverse_causal_chain() | P0 | v0.3.0 release |
| [V030-INSTALLCHECK] | Add pg_regress tests: edge_kind ENUM exists, 4 partial indexes exist, recall_lessons() BFS uses edge_kind, traverse_causal_chain() compiles | P1 | v0.3.0 release |
| [V030-SEED] | Seed script: populate mem_edge with temporal + entity edges (per MAGMA RFC §7 seed query) | P2 | benchmark validation of BFS fix |

---

## Applied Recommendations

| task_id | action | by |
|---|---|---|
| 5128 | CANCEL — stale, v0.2.0.1 superseded by v0.2.1 | process_guardian (78) |
| 5196 | DEFER to v0.4.x — out of v0.3.0 MAGMA scope | PI (77) |
| 5269 | Mark as phantom-close; REOPEN for actual implementation | process_guardian (78) |
| 5585 | Priority escalation: resolve before v0.3.0 tag | PI (77) |

---

## v0.3.0 Iteration Kickoff

**Using PGMNEMO_ITERATION_WORKFLOW.md Phase A–F structure:**

### Phase A — Hypothesis / Scope for v0.3.0

**PI ranking (2026-05-10):**

v0.3.0 is a focused migration-fix release. Scope is deliberately narrow (MAGMA §3 only, as defined in the MAGMA RFC):

| # | Scope item | Priority | Effort | Evidence |
|---|---|---|---|---|
| 1 | Fix migration S3 + S8 (V030-FIX-S3/S8) | P0 | ~2h | V0.3.0_AUDIT: static analysis confirms 2 runtime failures |
| 2 | Add pg_regress installcheck (V030-INSTALLCHECK) | P1 | ~3h | V0.3.0_AUDIT: no regression coverage for migration |
| 3 | Resolve HYBRID-DROP-OR-DEMOTE (task 5585) | P1 | 0.5d | WG decision — must not leave pending at release |
| 4 | Seed mem_edge temporal edges (V030-SEED) | P2 | ~1h | MAGMA RFC §7 prerequisite for BFS benchmark lift |

**Out of scope for v0.3.0:** MAGMA §4, §5, DIM-FLEX, CI nightly, examples reorganization.

### Phase B — Implementation Tasks

Spawn order (TL executes):
1. `[V030-FIX-S3S8]` — Migration bug fix (IMPL only, ~2h)
2. `[V030-INSTALLCHECK]` — pg_regress tests (IMPL, ~3h)
3. WG sync on 5585 [HYBRID-DROP-OR-DEMOTE] (decision, not implementation)
4. `[V030-SEED]` if time permits

### WG Checkpoints for v0.3.0

| Checkpoint | Trigger | Required |
|---|---|---|
| Migration fix reviewed | After V030-FIX-S3S8 IMPL | TL (5) code review |
| BENCH gate | After installcheck passes + seed applied | experiment_designer (84) GO/NO-GO |
| WG Release Review | 48h before v0.3.0 tag | All 8 members |

### Target Ship Date

**v0.3.0 target:** 2026-05-17 (1 week from today)  
**Milestone:** Migration bug fixed, installcheck passing, recall_lessons() BFS active, bench progression confirmed.

**Hold criteria:** Any of — (1) installcheck fails after fix, (2) recall@10 regresses vs v0.2.1 baseline (0.933 LME, 0.795 LoCoMo), (3) WG review finds unreported risk.
