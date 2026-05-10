# TL Report: GH-C3-EXAMPLES — Reorganize examples/ by user job

**Date:** 2026-05-10
**Task:** GH-C3-EXAMPLES (TACTICS C3)
**Priority:** P2
**Deadline:** 2026-05-23

---

## 1. Current State Audit

### Files present in `examples/`

| File | Type | Status |
|------|------|--------|
| `examples/README.md` | Docker Compose quickstart doc | Stale — references v0.1.0 |
| `examples/docker-compose.yml` | Docker stack | Functional, version-agnostic |
| `examples/init/01_pgmnemo_install.sh` | Init script | **STALE** — hardcodes `VERSION="v0.1.0"` (line 16) |
| `examples/migrate_external_memory.sql` | Migration SQL | Complete, production-quality |

### What exists vs. what's needed

| Job | SQL exists | .md exists | Runnable | Notes |
|-----|-----------|-----------|---------|-------|
| quickstart | inline in README.md | ✓ (docker README) | partial | No standalone .sql; version stale |
| migration | ✓ migrate_external_memory.sql | ✗ no companion .md | ✓ | Missing 1-paragraph "when to reach for it" |
| hybrid | ✗ | ✗ | ✗ | `recall_hybrid()` is v0.2.2-only |
| graph | ✗ | ✗ | ✗ | Functions exist in v0.2.1 SQL (lines 645–834) |

---

## 2. Issues Found

### ISSUE-1 (P1): `examples/init/01_pgmnemo_install.sh:16` hardcodes `VERSION="v0.1.0"`

```bash
# examples/init/01_pgmnemo_install.sh line 16
VERSION="v0.1.0"   # ← stale; current release is v0.2.1
```

The script clones `v0.1.0` from GitHub. Anyone running `docker compose up` gets a two-major-version-old extension. The README comment "A pre-built Docker image is planned for v0.2.0" is now doubly obsolete (v0.2.1 ships a pre-built path via PGXN).

**Impact:** Quickstart example is broken for the current release.

### ISSUE-2 (P2): Hybrid example blocked on v0.2.2

`recall_hybrid()` does not exist in `extension/pgmnemo--0.2.1.sql`. It is introduced in `extension/pgmnemo--0.2.1--0.2.2-hybrid.sql`. A hybrid example must either:
- Target v0.2.2 (not yet released) and note this, or
- Apply the upgrade script inline and note the pre-release dependency.

**Impact:** Hybrid example cannot be written against the current stable release without a caveat.

### ISSUE-3 (P2): No companion `.md` for `migrate_external_memory.sql`

The SQL is high quality and production-ready, but there is no `.md` explaining *when* to reach for it (i.e., the job: "I have an existing mem.mem_item table and want to bring it into pgmnemo"). Without this, the TACTICS C3 requirement (1-paragraph .md per example) is unmet.

### ISSUE-4 (P3): `examples/README.md` is scoped only to Docker Compose

The top-level `examples/README.md` reads as documentation for the Docker Compose stack, not as an index of all examples. It needs to become a job-oriented index after restructuring.

### ISSUE-5 (P3): README.md documentation section has no link to `examples/`

```markdown
# README.md lines 81–83
- [INSTALL.md](INSTALL.md)
- [docs/USAGE.md](docs/USAGE.md)
- [CHANGELOG.md](CHANGELOG.md)
```

No pointer to `examples/` from the main README. Adopters discovering the repo will not find the examples without scrolling to the quickstart section.

---

## 3. Target Structure

```
examples/
  README.md                          ← job index (rewrite)
  quickstart/
    README.md                        ← "When: first time, no existing memory store"
    quickstart.sql                   ← standalone runnable SQL (ingest + recall)
    docker-compose.yml               ← moved from examples/
    init/
      01_pgmnemo_install.sh          ← moved + version updated to v0.2.1
  migration/
    README.md                        ← "When: migrating from mem.mem_item or similar"
    migrate_external_memory.sql      ← moved unchanged
  hybrid/
    README.md                        ← "When: keyword-rich queries where vector recall misses"
    recall_hybrid.sql                ← stub (requires v0.2.2+, clearly noted)
  graph/
    README.md                        ← "When: tracing causal chains or co-temporal episodes"
    graph_traversal.sql              ← new stub using traverse_causal_chain + traverse_temporal_window
```

---

## 4. Metrics

| Metric | Value |
|--------|-------|
| Existing example files | 4 |
| Examples matching job-based structure | 0 / 4 |
| Companion `.md` present for .sql files | 0 / 1 (migration .sql has no .md) |
| Version staleness (init script) | v0.1.0 vs current v0.2.1 (2 major versions behind) |
| README → examples/ link | missing |
| Graph functions in v0.2.1 SQL | 2 (`traverse_causal_chain`, `traverse_temporal_window`) |
| Hybrid function available in stable | NO (v0.2.2 only) |
| New files to create | 7 (4× README.md per job + 3× .sql stubs) |
| Files to move/update | 3 (migrate .sql, docker-compose.yml, init/01_pgmnemo_install.sh) |

---

## 5. Remediation Task Drafts

### task_draft: C3-QUICKSTART-JOB

```
Title: Create examples/quickstart/ job-based example
Files to create:
  examples/quickstart/README.md     — 1-para "when to reach for it" + usage steps
  examples/quickstart/quickstart.sql — ingest() + recall_lessons() runnable from psql
Files to move:
  examples/docker-compose.yml       → examples/quickstart/docker-compose.yml
  examples/init/                    → examples/quickstart/init/
Files to update:
  examples/quickstart/init/01_pgmnemo_install.sh:16 — VERSION="v0.1.0" → VERSION="v0.2.1"
  examples/quickstart/README.md — remove stale v0.1.0/v0.2.0 notes
Priority: P2
Effort: ~30 min
Blocker: none
```

### task_draft: C3-MIGRATION-JOB

```
Title: Create examples/migration/ job-based example + companion .md
Files to create:
  examples/migration/README.md — 1-para "when to reach for it" (migrating from external mem store)
Files to move:
  examples/migrate_external_memory.sql → examples/migration/migrate_external_memory.sql
Priority: P2
Effort: ~15 min
Blocker: none
```

### task_draft: C3-HYBRID-JOB

```
Title: Create examples/hybrid/ stub with v0.2.2 caveat
Files to create:
  examples/hybrid/README.md    — "when to reach for it" + explicit v0.2.2+ requirement note
  examples/hybrid/recall_hybrid.sql — stub showing recall_hybrid() usage; header warns requires v0.2.2
Priority: P2
Effort: ~20 min
Blocker: v0.2.2 release (recall_hybrid() not in v0.2.1 stable) — stub can land now as pre-release preview
```

### task_draft: C3-GRAPH-JOB

```
Title: Create examples/graph/ job-based example
Files to create:
  examples/graph/README.md           — "when to reach for it" (causal chains, co-temporal episodes)
  examples/graph/graph_traversal.sql — runnable stub:
    1. ingest() two lessons with mem_edge linking them
    2. traverse_causal_chain(anchor_id, max_depth := 3, direction := 'forward')
    3. traverse_temporal_window(anchor_id, window := '1 hour')
Priority: P2
Effort: ~30 min
Blocker: none (traverse_causal_chain + traverse_temporal_window in v0.2.1)
```

### task_draft: C3-INDEX-AND-README-LINK

```
Title: Rewrite examples/README.md as job index + link from root README.md
Files to update:
  examples/README.md — replace docker-compose doc with job index (4 entries)
  README.md:81-83 (Documentation section) — add examples/ link
Priority: P3
Effort: ~15 min
Blocker: tasks C3-QUICKSTART-JOB, C3-MIGRATION-JOB, C3-HYBRID-JOB, C3-GRAPH-JOB should land first
```

---

## 6. Self-Evaluation

**What worked:** The existing migration SQL (`migrate_external_memory.sql`) is thorough and production-ready — it just needs a companion `.md` and a home in the restructured directory. The graph traversal functions are fully implemented in v0.2.1 and only need an example written to expose them. The task is mostly additive with minimal risky moves.

**What to improve:** The hybrid example is a dependency on an unreleased version (v0.2.2), which creates a user-trust risk if the stub ships without clear versioning caveats. The recommended approach is to land the stub with a prominent `## Requirements: pgmnemo ≥ 0.2.2` header rather than blocking the whole C3 task on a release.

**Risk:** The `init/01_pgmnemo_install.sh` version update (v0.1.0 → v0.2.1) touches the Docker Compose quickstart that is actively linked from the main README. It must be tested with `docker compose up` to confirm the build still passes before the PR merges.
