# Why pgmnemo — Enterprise / Regulated Context

**Audience:** tech lead, security reviewer, or procurement officer evaluating
agent-memory options where data sovereignty, audit trail, or compliance scope
is a hard constraint.
**For indie / startup context:** see [WHY_PGMNEMO.md](WHY_PGMNEMO.md).

---

## The compliance reality

You build AI agents that produce claims — about scenes, transactions,
documents, patients, infrastructure. Every claim references some "memory"
the agent extracted earlier. Your audit / compliance / security review
asks two questions about every claim:

1. **Where did this memory come from?** Which run, which agent, which
   artefact (commit, file hash, attestation)?
2. **Can the memory layer be tampered with by an attacker who breached
   the application?**

Most agent-memory products answer question 1 with "the agent said so."
None answer question 2 with anything stronger than "trust our SaaS."

This page explains why a Postgres extension is a different shape of answer.

---

## Where Mem0 / Zep / Letta / vector DBs fail enterprise procurement

| Constraint | Mem0 | Zep | Letta | Pinecone | pgmnemo |
|---|---|---|---|---|---|
| Data never leaves your perimeter | ❌ SaaS only | ❌ SaaS only | ✓ self-host | ❌ SaaS | ✓ in your DB |
| ITAR / EAR / CUI-compatible deployment | ❌ | ❌ | ✓ if air-gapped | ❌ | ✓ in your DB |
| Source visible & auditable (incl. backend) | ❌ proprietary backend | ❌ proprietary backend | ✓ Apache-2.0 | ❌ | ✓ Apache-2.0 end-to-end |
| Backup with existing PG tooling | ❌ | ❌ | ❌ | ❌ | ✓ `pg_dump` |
| RLS enforced at DB layer (not app) | ❌ | ❌ | ❌ | ❌ | ✓ Postgres RLS |
| Write-time provenance enforcement | ❌ | ❌ | ❌ | ❌ | ✓ (gate inside SQL function) |
| Tamper trail of memory mutations | partial | partial | ❌ | ❌ | ✓ `created_at`+`verified_at`+audit roadmap |
| Same compliance review as your existing DB | n/a | n/a | new vendor | new vendor | ✓ no new vendor |

The bottom row is the strategic point. **Your security team has already
approved PostgreSQL.** They have a threat model, a backup strategy, a
restore drill, a patch schedule. pgmnemo is `CREATE EXTENSION` inside
that already-approved system. Mem0 / Zep / Pinecone require a new vendor
security review (typically 4–12 weeks, sometimes never finishing).

---

## What pgmnemo gives you that no SaaS competitor can

### 1. Write-time provenance gate, enforced inside SQL

```sql
-- This blocks. There is no path from app code to a row in agent_lesson
-- that bypasses this gate when gate_strict='enforce' (the default).
SELECT pgmnemo.ingest(
    p_role        := 'analysis-agent',
    p_project_id  := 7,
    p_topic       := 'scene-3829',
    p_lesson_text := 'Vegetation cover increased 23% YoY in AOI-B',
    p_commit_sha  := NULL,         -- ← no provenance
    p_artifact_hash := NULL        -- ← no provenance
);
-- ERROR: pgmnemo.ingest blocked — gate_strict=enforce requires
-- commit_sha or artifact_hash. (To stage without provenance,
-- SET pgmnemo.gate_strict = 'warn'.)
```

For a regulated workflow you can require **both** a git commit SHA *and*
a signed artefact hash (signed PDF, signed scene-metadata JSON, signed
model-output bundle). The SQL function then becomes:

```sql
-- Custom wrapper that requires BOTH gates for your highest-trust workflow
CREATE FUNCTION my_org.audited_ingest(...) RETURNS BIGINT AS $$
DECLARE _lesson_id BIGINT;
BEGIN
    IF p_commit_sha IS NULL OR p_artifact_hash IS NULL THEN
        RAISE EXCEPTION 'Audited path requires both git SHA and artefact hash';
    END IF;
    SELECT pgmnemo.ingest(...) INTO _lesson_id;
    INSERT INTO my_org.ingest_audit_log (lesson_id, actor, source_run_id, ...)
    VALUES (_lesson_id, current_user, ...);
    RETURN _lesson_id;
END;
$$ LANGUAGE plpgsql;
```

This is a 15-line wrapper your security team can read and approve in 10
minutes. The wrapper lives in **your** schema, version-controlled in
**your** migrations. We did not invent a DSL or a config file — it's PL/pgSQL.

### 2. Data sovereignty by construction

The entire memory layer lives in your existing PostgreSQL instance. No
outbound network calls from `pgmnemo.*` functions. No telemetry. No
phone-home for license validation (the extension is Apache-2.0).

Tested with:

```bash
# In your air-gapped network:
docker compose up postgres
# pgmnemo extension files are vendored in your image build (see docs/INSTALL.md Path 4)
# No internet access required at runtime.
```

### 3. Multi-tenant by DB layer

If you serve multiple analyst teams or customer projects in the same
deployment, `pgmnemo.tenant_id` GUC scopes recall:

```sql
-- Per-session, your application layer sets:
SET pgmnemo.tenant_id = '42';

-- Then all queries through pgmnemo functions can only see rows where
-- agent_lesson.project_id = 42. Enforced by Postgres RLS policy,
-- not by your application code remembering to filter.
SELECT * FROM pgmnemo.recall_lessons(my_embedding, 10);
-- Returns rows belonging to project 42 only.
```

Your application can have a bug. The RLS policy doesn't.

### 4. Same backup, restore, encryption-at-rest as your DB

```bash
# All your existing operational tooling works:
pg_dump -d mydb -n pgmnemo -F custom > pgmnemo_backup.dump
# (or just include it in your standard pg_dump pipeline)

# Logical replication for HA:
CREATE PUBLICATION pgmnemo_pub FOR TABLES IN SCHEMA pgmnemo;
# (or all-tables, your standard pattern)

# Encryption-at-rest:
# Whatever your PG cluster does (TDE, FS-level, etc.) covers pgmnemo too —
# it's just rows in two tables.
```

---

## Honest gaps you should know upfront

We will not waste your security reviewer's time pretending these don't exist:

### Gap 1 — Image / multimodal embeddings: zero published evidence

Our entire benchmark corpus is conversational text (LoCoMo, LongMemEval-S).
The schema is `vector(1024)` so CLIP/DINOv2/etc. work mechanically, **but
we have no published bench showing that our scoring formula
(`0.5×cosine + 0.2×importance + γ×recency + 0.1×provenance`) is correct
for image embedding distributions.**

What this means for you:
- If your "memory" is text (analyst notes, observation summaries, model
  outputs in natural language), our bench applies.
- If your "memory" is image-embedding-keyed (scenes, frames, regions), you
  should run a small bench against your own corpus before committing. We'll
  help you design it; the harness is at `benchmarks/scripts/`.

### Gap 2 — Scale: tested at 5K rows, not 1M

Our public benchmark corpus is ~5K rows. pgvector + HNSW is known-good to
10M+ rows on adequate hardware, **but our scoring stored procedure has not
been stress-tested at that scale on our side.**

What this means for you:
- If you're planning ~100K rows: low risk, we believe it works.
- If you're planning 1M+ rows: pilot it with your real corpus. If you see
  perf issues, file an issue with `EXPLAIN ANALYZE` — we'll prioritise
  optimisation. (Currently the scoring CTE does a `LIMIT k*5` then re-ranks;
  at large N this may need rework.)

### Gap 3 — Spatial / domain-aware retrieval: no native support

If you need queries like "memories about scenes within 50km of point X,
ranked by relevance" — `recall_lessons()` doesn't take spatial predicates
natively. The workaround is a 10-line SQL wrapper combining a PostGIS
pre-filter with our hybrid recall:

```sql
WITH spatial_pre AS (
    SELECT id FROM pgmnemo.agent_lesson
    WHERE ST_DWithin(metadata->>'centroid', ST_GeomFromText($1), 50000)
)
SELECT * FROM pgmnemo.recall_lessons(...)
WHERE lesson_id IN (SELECT id FROM spatial_pre);
```

If you adopt and contribute back the pattern that works for your workflow,
we'll cite you in `docs/cookbook/spatial.md` (planned v0.6.0).

### Gap 4 — Production user count: 1

We have one named production user. You'd be #2 (or #3, etc., depending on
sequence). For some procurement processes this is a stopper. We can offer:

- **Reference call** with the existing adopter's tech lead (after their consent)
- **Co-development arrangement**: we treat your adoption as a top-priority
  validation project; you get direct maintainer attention
- **Public case study** (after your pilot, named or anonymous, your choice)

If your procurement requires "5+ public production references", we are not
yet there; revisit us at v1.0 (Q4 2026 target).

---

## Roadmap items relevant to your context

Sorted by what likely matters for a regulated-enterprise evaluation:

| Item | Target version | Why it matters for you |
|---|---|---|
| `pgmnemo.stats()` health SP with `orphan_count` signal | **v0.4.1 (shipped)** | One-query monitoring; security review-friendly |
| `recall_lessons()` diagnostic columns (`vec_score`, `bm25_score`, `rrf_score`) | **v0.4.1 (shipped)** | Audit "why was this ranked highly" — explainable scoring |
| `pgmnemo.add_edge()` helper SP for causal/temporal lineage between memories | v0.5.0 (June 2026) | Document derivation chains for compliance review |
| Bench-harness packaged for adopter-side use (run our bench on your own corpus) | v0.6.0 (August 2026) | You produce your own validation evidence |
| **Signed provenance attestation** (`commit_sha` extended to cryptographic signature verification) | v0.7.0 (October 2026) | Multi-party attestation — agent A claims agent B verified X, verifiable in SQL |
| 1M+ row scale benchmark on synthetic enterprise corpus | v0.6.0 (August 2026) | We commit to the perf claim we'd otherwise be making informally |
| Compliance-grade audit log of all memory mutations | v0.5.0 → v0.7.0 (incremental) | Satisfies "tamper trail" requirement for SOC2 / FedRAMP-adjacent audits |

If any of these is a blocker for your timeline, tell us — we'd consider
pulling it forward if your adoption depends on it.

---

## What we want from you

1. **Discovery call** (30–45 minutes) to validate fit. We will tell you
   honestly if we're not the right answer.
2. **Pilot pre-conditions:** non-prod database, real-but-anonymised corpus
   (or fully synthetic), 4-week pilot window. We commit to fixing
   blocking issues within the pilot.
3. **Documentation co-authorship:** if your workflow exposes a gap our
   docs don't cover (spatial, multimodal, scale), we'd cite you as
   co-author of the cookbook entry.
4. **Reference call** (post-pilot, optional, named or anonymous): so the
   next regulated-enterprise evaluator doesn't ask "but who else uses this?"

---

## Contact

GitHub: https://github.com/pgmnemo/pgmnemo
Security disclosures: [SECURITY.md](../SECURITY.md) (private channel)
Maintainer: asistentgaidaburas@gmail.com

We respond to enterprise evaluation enquiries within 2 business days.
For NDA-bound contexts, GitHub Issues is not the right channel —
email first.
