---
date: 2026-06-24
agent: research_supervisor
task_id: PGMREL-0120-RESEARCH
status: complete
branch: integration/0.12.0
---

# pgmnemo 0.12.0 — Risk Register
**Typed Write API: remember_fact / remember_event / remember_relation**

Severity: P0 = release-blocker | P1 = high / must mitigate | P2 = medium / document | P3 = low / monitor

---

## P0 — Release Blockers

### R-01 · Draft SQL is NOT the delivery shape

**Risk:** `extension/sql/typed_write_api.sql` implements `mem_write()` + `ingest()` 10th-param
overload. The actual delivery shape per RFC-001 §D2 + task ADDENDUM-2 is
`remember_fact / remember_event / remember_relation`. If the draft is used as-is, all 7
correctness requirements (R1–R7) are unmet — the release would ship without PII candidate
routing (R1), bitemporal supersession (D-2), or identity dedup (R3).

**Probability:** HIGH (already confirmed — draft diverges on 3 structural dimensions)
**Impact:** HIGH (correctness requirements unmet; security gate absent)
**Mitigation:** Build `remember_*` from scratch per RFC-001 §D2. The draft informs the
`ingest()` integration pattern only.
**Source:** `design/RFC-001-memory-organism.md §D2`; typed_write_api.sql analysis §2.1

---

### R-02 · ADDENDUM-2 spec files don't exist in repo

**Risk:** `spec/v3/memory-era/RFC-001-ADDENDUM-2-write-api-learnings.md` and
`RFC-001-ADDENDUM-typed-recall-coverage.md` are listed as mandatory "READ FIRST" inputs but
are absent from the repository. The 7 correctness requirements exist only in the task
dispatch. If the implementation phase begins without these files, requirements can drift.

**Probability:** CERTAIN (files confirmed absent by `find` on integration/0.12.0)
**Impact:** HIGH (implementation without anchored spec; no regression-testable requirements)
**Mitigation:** Create both ADDENDUM files in the repo before the implementation phase begins.
Content: copy the 7 requirements from the task spec verbatim; add rationale from RFC-001 §D4.
**Owner:** Implementation agent (first commit in implementation phase)

---

### R-03 · `remember_fact` creates silent candidate rows invisible to recall

**Risk:** Correct-by-design but dangerous: PII writes via `remember_fact` on `person:*`
entities with `{email, phone, address, telegram, full_name}` properties go to `state='candidate'`
automatically. These rows are INVISIBLE to default `recall_hybrid()`. An adopter who expects
recall of a recently-written email address will get 0 results with no error.

**Probability:** HIGH (design intent — this is supposed to happen)
**Impact:** HIGH (silent data loss from the caller's perspective; debugging is non-trivial)
**Mitigation:** (a) `remember_fact` MUST return the row state in its return value alongside
the id — e.g. `RETURNS TABLE(id BIGINT, state TEXT)` or `RAISES NOTICE '... state=candidate'`;
(b) CHANGELOG must have prominent warning; (c) include a `trust_record()` example.
**Source:** RFC-001 §5 anti-poisoning gate; PROPERTY_CONVENTIONS.md §5.1

---

### R-04 · NULL slug → NULL artifact_hash → provenance gate rejects write

**Risk:** R2 (task ADDENDUM-2): if `p_entity_key` is NULL or fails slug validation,
`canonical_slug()` returns NULL, making `artifact_hash = 'fact-' || NULL || ':' || property = NULL`.
`gate_strict='enforce'` then rejects the write (no artifact_hash = provenance violation).
Current `ingest()` doesn't synthesize `artifact_hash` — it just passes through caller-supplied values.
If `remember_fact` inherits this behavior without the COALESCE synthesis, every write under
`gate_strict='enforce'` without a caller-supplied `p_commit_sha` silently fails.

**Probability:** HIGH (R2 is unimplemented in draft)
**Impact:** HIGH (complete write failure for all `remember_fact` callers under enforce mode)
**Mitigation:** R2 implementation: `artifact_hash := COALESCE(p_artifact_hash, 'fact-' || p_entity_key || ':' || p_property)` before the provenance gate check. Must be before any `SELECT ... FOR UPDATE`.
**Source:** ADDENDUM-2 R2 (task spec); RFC-001 §3 §D2

---

### R-05 · FOR UPDATE race on concurrent remember_fact to same (entity_key, property)

**Risk:** RFC-001 §D2 Drawback D3: under high-frequency concurrent writes to the same
`(entity_key, property)`, the `SELECT ... FOR UPDATE` creates a serialization point.
If two agents write `person:ada_lovelace/affiliation` simultaneously, one waits while the
other commits. In a deadlock scenario (agent A locks row X, agent B locks row Y, then A tries
Y), Postgres will deadlock-kill one transaction. No retry logic in the function.

**Probability:** LOW (typical agent-memory workloads < 100 concurrent writes; collision on
same entity+property is rare)
**Impact:** MEDIUM (deadlock = write error; caller must retry)
**Mitigation:** Document the serialization behavior; callers should implement retry for
deadlock errors (`SQLSTATE 40P01`). P1 future: add a `FOR UPDATE SKIP LOCKED` fast-path for
best-effort writes.
**Source:** RFC-001 §Drawbacks D3

---

## P1 — High Risk / Must Mitigate

### R-06 · `guard_no_test_project` not yet implemented

**Risk:** R6 (ADDENDUM-2): real-DB integration tests must target `pgmnemo_bench` test DB and
block sandbox project IDs on prod. No `guard_no_test_project` function exists in current
extension. Without this guard, a test run against prod leaks test data into live agent_lesson
rows.

**Probability:** HIGH (function not implemented)
**Impact:** HIGH (data contamination on prod)
**Mitigation:** Create `pgmnemo.guard_no_test_project(p_project_id INT)` that raises EXCEPTION
if `p_project_id` matches any known sandbox ID. Implemented as a check-only function called
at the top of the real-DB test harness (not inside `remember_*` functions — would be too
restrictive for adopters using project_id=1 for testing).

---

### R-07 · Memanto benchmark position invalidates SotA claim

**Risk:** arXiv:2604.22085 (Memanto, April 2026) claims 87.1% LoCoMo accuracy and 89.8%
LongMemEval accuracy, described as "surpassing all evaluated hybrid graph and vector-based
systems." pgmnemo's published LoCoMo recall@10 = 0.8409. If Memanto's claim is reproducible
and the metrics are even approximately comparable, pgmnemo's benchmark position is not SotA.

**Probability:** MEDIUM (paper exists; methodology comparison needed before accepting claim)
**Impact:** MEDIUM (marketing/positioning — no functional impact on 0.12.0; write-path
release doesn't change recall scores anyway)
**Mitigation:** (a) POSITIONING.md must NOT claim SotA in 0.12.0 release materials;
(b) add Memanto to competitor matrix with honest "different metric" caveat;
(c) defer recall-bench comparison to post-0.12.0 sprint.
**Source:** arXiv:2604.22085 — [https://arxiv.org/abs/2604.22085](https://arxiv.org/abs/2604.22085)

---

### R-08 · ingest_entity → remember_fact migration not documented

**Risk:** R4 (ADDENDUM-2): `remember_fact` must be a drop-in upgrade for `ingest_entity`
callers. No migration guide exists. Adopters who already use `ingest_entity` (if any exist)
will not know how to transition without documentation.

**Probability:** HIGH (documentation does not exist; confirmed by `docs/MIGRATION.md` review)
**Impact:** MEDIUM (only affects current `ingest_entity` adopters; function is not widely
shipped but is a prototype)
**Mitigation:** Add `docs/MIGRATION.md §C — ingest_entity → remember_fact` before release.
Key points: same `(topic slug, project_id)` identity; existing rows get `version_n=0`
sentinel; no data loss; new writes produce `version_n=1`.

---

### R-09 · `remember_fact` entity-hub auto-create ambiguity

**Risk:** RFC-001 §D2 says `remember_fact` stores a property on an entity. But what if the
entity hub row (`content_type='entity'`) doesn't exist yet? RFC-001 doesn't specify whether
`remember_fact` should auto-create the hub or require the caller to pre-create it via a
separate `remember_entity()` call.

**Probability:** HIGH (architectural decision not resolved in RFC-001)
**Impact:** HIGH (if not auto-created: every caller must make two calls; if auto-created:
entity creation semantics are implicit and metadata is incomplete)
**Mitigation:** Decide before implementation: recommended = auto-create entity hub with minimal
metadata (`entity_type` derived from slug prefix, `canonical_name = p_entity_key`) and let
caller enrich it with subsequent `remember_fact('description', ...)` calls.
**Owner:** Chief Architect — P0 decision gate for implementation.

---

## P2 — Medium Risk / Document

### R-10 · Property naming convention drift — new PII property bypasses gate

**Risk:** `PROPERTY_CONVENTIONS.md §5.1` defines the PII property closed set in prose; it
is not enforced at the DB layer. If a new property (e.g. `biometric_id`) is added to the
convention file but not to the `IN (...)` check inside `remember_fact`, it bypasses
candidate routing silently.

**Mitigation:** Add comment block in `remember_fact` SQL: `-- PII property set: sync with design/PROPERTY_CONVENTIONS.md §5.1`. Create a cross-reference checklist in `PROPERTY_CONVENTIONS.md §5.1`: "When adding a PII property here, update the corresponding IN-list in `remember_fact`."

---

### R-11 · `remember_relation` adds `mem_edge` row — 2-step write is not atomic per se

**Risk:** RFC-001 §Drawback D4: `remember_relation` writes `agent_lesson` + `mem_edge`.
Both are inside one function body (one transaction). However, `add_edge()` can fail
independently (e.g. if `mem_edge` schema changes). A failure in `add_edge()` after the
`agent_lesson` INSERT will roll back both writes cleanly (transaction semantics), but the
error message may be confusing ("mem_edge constraint violation" when the caller expected
a relation write).

**Mitigation:** Add explicit error handling in `remember_relation`: `BEGIN ... EXCEPTION WHEN others THEN RAISE EXCEPTION 'remember_relation failed: % (both agent_lesson and mem_edge writes rolled back)', SQLERRM;`

---

### R-12 · Flat install `pgmnemo--0.12.0.sql` must include ALL prior delta content

**Risk:** From CHANGELOG 0.11.0: "There is no flat pgmnemo--0.11.0.sql" — that version was
shipped without a flat install. If 0.12.0 repeats this pattern, fresh installs will fail.
The 0.11.1 flat exists (`pgmnemo--0.11.1.sql` confirmed on `release/0.11.1`). 0.12.0 flat
must be the 0.11.1 flat + the 0.12.0 delta under ONE psql-guard.

**Mitigation:** Build flat as: `cat pgmnemo--0.11.1.sql <delta> > pgmnemo--0.12.0.sql`.
Verify flat-vs-delta schema-IDENTICAL via `pg_dump` diff in INSTALLCHECK.
**Source:** Release mechanics from CHANGELOG 0.11.0; task spec

---

### R-13 · G-CONFIDENTIALITY gate — ADDENDUM files must not leak internal paths

**Risk:** ADDENDUM-2 files, once created, must not contain `/Users` paths, agency-ids, MEM-ERA
report internal content, or `spec/v3/memory-era` internal cross-references that leak
implementation context. The `G-NO-INTERNAL-LEAK` gate checks for these patterns.

**Mitigation:** ADDENDUM files should cite RFC-001 by section, not by internal agent task IDs
or memory system paths. Review with `scripts/.internal-leak-patterns` before commit.

---

## P3 — Low Risk / Monitor

### R-14 · Corroboration promotion (30-day rule) not GUC-controlled

**PROPERTY_CONVENTIONS.md §5.1** mentions a 30-day corroboration window. This is not
formalized as a GUC. Low priority for 0.12.0 — the corroboration path is secondary to the
main candidate/validated state gate — but should become a GUC in a subsequent release.

### R-15 · `remember_event` allows arbitrary `p_occurred_at` in the past

No guard on how far in the past `p_occurred_at` can be. An erroneous event at
`p_occurred_at = '1970-01-01'` would sort to the bottom of temporal recall but is otherwise
harmless. Monitor for edge cases in production.

### R-16 · Benchmark gate `significance_required=false` for 0.12.0

Task spec requires `benchmarks/gate/v0.12.0.json` with `feature_smoke` and
`significance_required=false`. Correct: 0.12.0 adds no recall algorithm changes.
Risk: if a future gate-check script changes to require significance by default, this
sentinel value would break CI. Document the exemption rationale in the gate file itself.

---

## Summary table

| ID | Severity | Area | Status |
|---|---|---|---|
| R-01 | P0 | Implementation | Open — must build from scratch |
| R-02 | P0 | Process | Open — create ADDENDUM files before impl |
| R-03 | P0 | UX/correctness | Open — must surface state in return value |
| R-04 | P0 | Correctness | Open — R2 not implemented |
| R-05 | P0 | Concurrency | Open — document + retry semantics |
| R-06 | P1 | Testing | Open — guard function needed |
| R-07 | P1 | Positioning | Open — Memanto must appear in competitor matrix |
| R-08 | P1 | Documentation | Open — MIGRATION.md §C needed |
| R-09 | P1 | Architecture | Open — entity auto-create decision needed |
| R-10 | P2 | Convention | Open — cross-ref comment in SQL |
| R-11 | P2 | Error handling | Open — exception wrapping in remember_relation |
| R-12 | P2 | Release mechanics | Open — flat install build procedure |
| R-13 | P2 | Confidentiality | Open — review before commit |
| R-14 | P3 | Future work | Deferred to post-0.12.0 |
| R-15 | P3 | Edge case | Monitor |
| R-16 | P3 | CI | Document exemption in gate file |
