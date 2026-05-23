---
date: 2026-05-23
author: chief_architect (id=86)
task_id: SWDEV-260523-3-PLAN
phase: PLAN
parent_dag: SWDEV-260523-3
input: spec/v062/RESEARCH_SWDEV-260523-3.md
base_plan: spec/v062/PLAN_V062.md (commit d4af595) — implementation already complete
status: complete
---

# pgmnemo v0.6.2 — PLAN SWDEV-260523-3
## Bench → Gate → Ship Execution Plan

**Version:** 0.6.2 (from 0.6.1)  
**Context:** All implementation work is complete and uncommitted. This plan covers
only the execution path: pre-flight → bench → gate → SHIP or FAIL. No new SQL
writing is required unless gate fails and a fallback variant is needed (see §5).

**Implementation state (working tree, uncommitted):**
- `extension/pgmnemo--0.6.2.sql` — fresh install with sparse-safe RRF ✓
- `extension/pgmnemo--0.6.1--0.6.2.sql` — upgrade migration ✓
- `extension/sql/rrf_sparse.sql` — pg_regress test ✓
- `extension/expected/rrf_sparse.out` — pg_regress expected output ✓
- `extension/Makefile` — DATA + REGRESS updated (includes rrf_sparse) ✓
- `benchmarks/scripts/run_v062_sparse_safe_bench.py` — bench script ✓
- `META.json`, `pgmnemo.control`, `pgmnemo_mcp/pyproject.toml` — bumped to 0.6.2 ✓

---

## 1. Pre-Flight Verification (P0 — MUST complete before bench)

All steps are fast (< 2 min total). Abort the plan if any check fails.

| Step | Command | Expected | Block on fail? |
|------|---------|----------|----------------|
| P1 v3-next container | `docker inspect agentura-v2-agency-v3-next-1 --format '{{.RestartCount}}'` | `0` | YES |
| P2 MLX:9200 health | `curl -s http://localhost:9200/health` | HTTP 200 |  YES |
| P3 LME-S data file | `ls benchmarks/data/longmemeval/longmemeval_s_cleaned.json` | file exists | YES |
| P4 embed cache | `ls benchmarks/.embed_cache/ \| wc -l` | > 0 files | YES |
| P5 PostgreSQL reachable | `psql $PGURL -c 'SELECT 1'` | `1` | YES |
| P6 pgmnemo at v0.6.1 | `psql $PGURL -c "SELECT pgmnemo.version()"` | `0.6.1` | YES — apply migration if 0.6.0 |
| P7 bench script present | `ls benchmarks/scripts/run_v062_sparse_safe_bench.py` | exists | YES |
| P8 smoke script present | `ls scripts/smoke_recall_hybrid.py` | exists | YES |

**Note (from task spec):** v3-next RestartCount=0 throughout v0.6.2 attempt 1.
MLX:9200 verified healthy 2026-05-23 19:14 UTC. Pre-conditions expected to be healthy.
Ignore 'API DOWN' watchdog messages unless `docker inspect` confirms restart.

---

## 2. Smoke Test (S0 — MUST pass before bench)

```bash
# Apply v0.6.2 upgrade to bench DB
psql $PGURL -c "ALTER EXTENSION pgmnemo UPDATE TO '0.6.2';"

# Verify version
psql $PGURL -c "SELECT pgmnemo.version();"  # → 0.6.2

# Run smoke test
DATABASE_URL=$PGURL python3 scripts/smoke_recall_hybrid.py
# Exit 0 = proceed; Exit 1 = stop, fix root cause before bench
```

Smoke test asserts: callable signature (8 params), all 15 output columns present,
vector-only fallback (query_text=NULL), weight overrides, empty corpus → 0 rows.

**If smoke fails:** Check for AmbiguousColumn or UndefinedTable errors — indicates CTE
scoping issue in the v0.6.2 SQL. Fix the SQL file and retry. Do NOT proceed to bench.

---

## 3. pg_regress (R0 — run before bench, 17/17 required)

```bash
cd extension/
make installcheck
# Expected: 17/17 PASS (16 existing + rrf_sparse)
```

The `rrf_sparse` fixture tests:
- Signature: `recall_hybrid` has 8 parameters (unchanged)
- PARTITION trick: zero-BM25 items yield NULL `bm25_rank_sparse`
- Positive-BM25 items yield non-NULL rank
- Sentinel COALESCE: `COALESCE(NULL, n+1)` = sentinel (integer addition verified)

If `make installcheck` shows regression diffs for `rrf_sparse`:
1. `diff extension/expected/rrf_sparse.out extension/results/rrf_sparse.out`
2. Fix expected output if diff is cosmetic (whitespace, version header)
3. Fix SQL if diff indicates logic error

---

## 4. Bench Execution (N=500, LongMemEval-S, bge-m3)

```bash
cd /Users/gaidabura/pgmnemo   # repo root

# Primary bench run — sparse-safe RRF
python3 benchmarks/scripts/run_v062_sparse_safe_bench.py
# Output: benchmarks/longmemeval/results/v062_sparse_safe/metrics.json
# Wall clock: ~15–30 min for N=500 with cached embeddings
# Progress updates: every 100 instances to stdout
```

**Gate evaluation (automated by bench script):**
```
BASELINE   recall@10 = 0.9334          # expected (v0.5.1/v0.6.1 baseline)
v0.6.2 F-A recall@10 = ?               # sparse-safe RRF result
Delta      recall@10 = ?  (gate: ≥+0.01)
p-value  (paired t)  = ?  (gate: < 0.05)
GATE: PASS ✓ / FAIL ✗
```

**Supplemental LoCoMo check (run after LME bench if gate passes):**
```bash
python3 benchmarks/scripts/run_locomo_v061_bench.py --variant sparse_safe
# Gate: recall@10 >= 0.7994 (must not regress from v0.6.0 baseline)
```

---

## 5. Gate Decision Matrix

### 5A — GATE PASS (all 5 criteria met)

Criteria:
- `recall@10(fix_a) >= 0.9434` (baseline 0.9334 + 0.01)
- `p_value < 0.05`
- LoCoMo `recall@10 >= 0.7994`
- pg_regress 17/17 PASS
- `smoke_recall_hybrid.py` exit 0

→ **Proceed to §6 (SHIP path).**

---

### 5B — NEAR-MISS (Alt B: add adaptive-k)

Trigger: `recall@10 ∈ [0.9334, 0.9434)` (no regression, but < +1pp gate) OR
         `p_value >= 0.05` with `delta >= 0.01`.

**Adaptive-k patch (~5 lines in recall_hybrid()):**

```sql
-- In DECLARE block, change:
--   CONSTANT DOUBLE PRECISION := 60 → variable
_rrf_k_f   DOUBLE PRECISION;

-- In BEGIN block, after raw_candidates CTE, add:
SELECT COUNT(*) INTO _total_candidates FROM raw_candidates;
_rrf_k_f := GREATEST(5.0, _total_candidates::DOUBLE PRECISION / 10.0);
```

After patching:
1. Update both `pgmnemo--0.6.1--0.6.2.sql` and `pgmnemo--0.6.2.sql`
2. Reapply to bench DB: `ALTER EXTENSION pgmnemo UPDATE TO '0.6.2';`
3. Re-run smoke test (must still pass)
4. Re-run bench (same script, same data)
5. Evaluate gate — expected: N/10 ≈ 4.8 for 48-seg sessions; denominator 5.8 vs 61 (10× better discrimination)

Estimated cost: ~5 min to patch + ~20–30 min bench rerun.

---

### 5C — CLEAR REGRESSION (Alt C: conditional fusion)

Trigger: `recall@10(fix_a) < 0.9334` (regression vs baseline).

This indicates sparse-safe RRF still harms recall, likely due to ORDER BY rrf_sparse
denominator behavior for queries with no BM25 signal at all. Switch to conditional fusion:
pure vector for zero-BM25 items, proper RRF for BM25-matched items.

**Conditional fusion ORDER BY (~20 lines — modify `scored` CTE + ORDER BY):**

```sql
-- scored CTE: add matched-only BM25 rank
CASE WHEN r.raw_bm25_score > 0
     THEN RANK() OVER (PARTITION BY (r.raw_bm25_score > 0)
                       ORDER BY r.raw_bm25_score DESC NULLS LAST)
     ELSE NULL
END AS bm25_rank_matched,

-- Final ORDER BY: conditional
ORDER BY (
    CASE WHEN s.bm25_score > 0
         THEN vec_weight / (_rrf_k_f + s.vec_rank::DOUBLE PRECISION)
              + bm25_weight / (_rrf_k_f + s.bm25_rank_matched::DOUBLE PRECISION)
         ELSE s.v_score  -- pure vector: degrades to fusion_score path for zero-BM25
    END
  + _aux_scale * (
        0.05 * (s.importance::DOUBLE PRECISION / 5.0)
      + 0.05 * GREATEST(0.0, 1.0 - LEAST(
                   EXTRACT(EPOCH FROM (NOW() - s.created_at)) / (90.0 * 86400.0), 1.0))
      + 0.05 * (CASE WHEN s.commit_sha IS NOT NULL AND s.verified_at IS NOT NULL THEN 1.0
                     WHEN s.commit_sha IS NOT NULL THEN 0.4 ELSE 0.0 END)
    )
  + _graph_weight * COALESCE(gp.proximity, 0.0)
) DESC
```

After patching:
1. Update both SQL files + smoke test + bench (same procedure as §5B)
2. Document in CHANGELOG as "Alt-C conditional fusion (not pure RRF)" — different framing

---

### 5D — ALL FAIL (defer to v0.6.3/v0.7.0)

Trigger: All three variants (sparse-safe, adaptive-k+sparse-safe, conditional fusion) fail gate.

Actions:
1. Write `benchmarks/gate/v0.6.2.json` with `gate_status=NO_GO`, all three metrics, analysis
2. Restore version bumps: `META.json` → `0.6.1`, `pgmnemo.control` → `0.6.1`, `pgmnemo_mcp/pyproject.toml` → `0.6.1`
3. DO NOT commit the SQL files; `git restore` all uncommitted v0.6.2 changes except the gate file
4. ESCALATE — log in ROADMAP.md as "F1 deferred to v0.6.3 or v0.7.0 — all three variants failed"
5. Commit only: gate NO_GO file + ROADMAP update

---

## 6. SHIP Path (after Gate PASS)

### 6.1 Artifact production

**A. Gate file** `benchmarks/gate/v0.6.2.json`:
```json
{
  "version": "v0.6.2",
  "date": "<ISO date>",
  "pgmnemo_version": "0.6.2",
  "gate_status": "PASS",
  "bench_db_tested": true,
  "lme_gate": {
    "recall_at_10": <actual>,
    "baseline_recall_at_10": 0.9334,
    "delta_pp": <actual>,
    "p_value": <actual>,
    "gate_passed": true
  },
  "locomo_gate": {
    "recall_at_10": <actual>,
    "gate_threshold_recall_at_10": 0.7994,
    "gate_passed": true
  },
  "pg_regress": { "n_tests": 17, "gate_passed": true },
  "summary": "<≥1 sentence with bench numbers and F1 sparse-safe note>"
}
```

**B. CHANGELOG.md** `[0.6.2]` entry — MUST be >200 chars:
- Theme: sparse-safe RRF (F1) finally ships after two deferrals
- Prominently note: v0.6.1 A-scale deferred (−22.44pp); v0.6.2 sparse-safe RRF (Cormack 2009)
- Include actual recall@10 delta from bench
- Include pg_regress count (17/17)
- Upgrade command: `ALTER EXTENSION pgmnemo UPDATE TO '0.6.2';`
- Rollback instruction pointer

**C. Release notes** `docs/release_notes/v0.6.2_telegram.md` — ≤3500 chars:
- Feature-centric: what users get (better hybrid recall for sparse corpora)
- Technical: what changed and why (Cormack 2009 proper RRF semantics)
- Metrics: recall@10 delta with benchmark citation
- Upgrade path
- No internal Agency references

### 6.2 Single SHIP commit

```bash
cd /Users/gaidabura/pgmnemo

git add \
  extension/pgmnemo--0.6.2.sql \
  extension/pgmnemo--0.6.1--0.6.2.sql \
  extension/sql/rrf_sparse.sql \
  extension/expected/rrf_sparse.out \
  extension/Makefile \
  extension/pgmnemo.control \
  META.json \
  pgmnemo_mcp/pyproject.toml \
  benchmarks/scripts/run_v062_sparse_safe_bench.py \
  benchmarks/gate/v0.6.2.json \
  CHANGELOG.md \
  docs/release_notes/v0.6.2_telegram.md \
  spec/v062/PLAN_SWDEV-260523-3.md \
  spec/v062/RESEARCH_SWDEV-260523-3.md

git commit -m "feat(v0.6.2): F1 sparse-safe RRF (Cormack 2009) — recall@10 +Xpp [GATE: PASS]

Fixes v0.6.1 regression (−22.44pp) caused by ROW_NUMBER() arbitrary tie-break
on tied zero-BM25 scores. Items without BM25 match now receive sentinel rank
= n_candidates+1 via PARTITION BY (bm25_score > 0), semantically correct per
Cormack et al. 2009 proper RRF formulation.

Real-DB bench: LongMemEval-S N=500, bge-m3 1024d.
recall@10: 0.9334 → <actual> (+<delta>pp, p=<p_value>).
pg_regress: 17/17 PASS (+rrf_sparse fixture).

F2 as_of_ts and F3 stress test shipped in v0.6.1 (commit e4d640e)."
```

### 6.3 Tag and push

```bash
git tag v0.6.2
git push origin main --tags

# Monitor release.yml CI (should mirror v0.6.1 success — pipeline validated)
# Expected jobs: pre-flight, build, test, release (creates GitHub Release + zip artifact)
```

### 6.4 LoCoMo verification (post-tag)

```bash
python3 benchmarks/scripts/run_locomo_v061_bench.py --variant sparse_safe
# Gate: recall@10 >= 0.7994
# If regression: document in errata, do NOT revert tag (LME gate is primary)
```

---

## 7. Cost & Complexity Estimates

### 7.1 Execution complexity (this plan — no new implementation)

| Step | Wall clock | LLM turns | Risk |
|------|-----------|-----------|------|
| P0 Pre-flight (8 checks) | < 2 min | ~5 | LOW |
| S0 Smoke test | < 1 min | ~3 | LOW |
| R0 pg_regress 17/17 | < 5 min | ~5 | LOW (rrf_sparse.out pre-written) |
| Bench N=500 | 15–30 min | ~3 (fire + wait + read) | LOW (cached embeddings) |
| LoCoMo check | 5–10 min | ~3 | LOW |
| Gate evaluation + artifacts | ~15 min | ~10 | LOW |
| SHIP commit + tag | ~5 min | ~5 | LOW |
| **Total (gate PASS)** | **~45–65 min** | **~34** | |

If Alt B needed (adaptive-k patch + rerun): add ~35–45 min, ~10 turns.  
If Alt C needed (conditional fusion patch + rerun): add ~45–60 min, ~15 turns.  
If Alt D (defer): add ~10 min, ~5 turns for rollback + gate NO_GO file.

### 7.2 LLM cost estimate (primary path)

| Phase | Model | Turns | Est. cost |
|-------|-------|-------|-----------|
| IMPLEMENT (pre-flight, smoke, regress, bench) | Sonnet | 20–35 | $0.60–1.05 |
| SHIP (artifacts + commit + tag) | Sonnet | 15–25 | $0.45–0.75 |
| **Total** | | **35–60** | **$1.05–1.80** |

Budget cap: $12 per phase (IMPLEMENT), $6 (SHIP). Per task spec: Expected × 1.5 reserve.
Expected total: ~$1.40. Reserve cap: ~$2.10. Cap set at $12/$6 provides 6–8× headroom.

No new SQL implementation unless Alt B/C fallback triggered. Alt B: +$0.30.
Alt C: +$0.50. Both well within cap.

### 7.3 Critical path

```
P0 pre-flight
  → S0 smoke (gate: exit 0)
  → R0 pg_regress (gate: 17/17)
  → bench N=500 (gate: +1pp, p<0.05)
  → LoCoMo check (gate: ≥0.7994)
  → write artifacts (gate.json, CHANGELOG, telegram.md)
  → single SHIP commit
  → git tag v0.6.2 + push
```

Each step gates the next. Failure at any step → fix or route to Alt B/C/D.

---

## 8. Risk Register

| Risk | Severity | Probability | Mitigation |
|------|----------|-------------|-----------|
| Bench gate FAIL despite sparse-safe fix | MEDIUM | LOW | Alt B (adaptive-k) → Alt C (conditional fusion) → Alt D (defer). All three alternatives pre-planned (§5). |
| Smoke test fails (CTE scoping) | MEDIUM | VERY LOW | Implementation pre-verified: PARTITION BY (bool) is valid PG14+; no CTE add/remove, only in-place edit of `rrf_ranked` and `scored`. |
| pg_regress rrf_sparse.out mismatch | LOW | LOW | Cosmetic (whitespace, version header): update expected. Logic error: fix SQL, rerun. |
| MLX:9200 unavailable during bench | LOW | VERY LOW | Embeddings pre-cached from v0.6.1 bench; bench script uses `.embed_cache/`, not live MLX. |
| LoCoMo regression (recall < 0.7994) | LOW | VERY LOW | sparse-safe RRF improves BM25-mixing; LoCoMo is session-granularity with dense overlap, not sparsely matched. Regression would be anomalous. |
| release.yml CI failure | LOW | VERY LOW | Pipeline validated and green for v0.6.1 release. Same workflow. |
| Commit includes wrong files (untracked junk) | LOW | LOW | Explicit `git add` of 14 named files (§6.2). Never use `git add .`. |

---

## 9. Definition of Done

- [ ] `scripts/smoke_recall_hybrid.py` → exit 0
- [ ] `make installcheck` → 17/17 PASS
- [ ] `benchmarks/gate/v0.6.2.json` exists with `gate_status=PASS` and `bench_db_tested=true`
- [ ] `recall@10(fix_a) >= 0.9434` AND `p_value < 0.05` (from bench)
- [ ] LoCoMo `recall@10 >= 0.7994` (must not regress)
- [ ] `CHANGELOG.md` has `[0.6.2]` entry > 200 chars with actual bench numbers
- [ ] `docs/release_notes/v0.6.2_telegram.md` ≤ 3500 chars
- [ ] `pgmnemo.control` `default_version = '0.6.2'`
- [ ] `META.json` `version = '0.6.2'`
- [ ] `pgmnemo_mcp/pyproject.toml` `version = '0.6.2'`
- [ ] Single SHIP commit contains all 14 listed files (§6.2)
- [ ] `git tag v0.6.2` created and pushed to origin
- [ ] `release.yml` CI green on tag push

---

## Appendix: Rollback (if Gate FAIL and deferred)

```bash
# Restore version bumps only (leave SQL files in place for v0.6.3 reuse):
sed -i "s/default_version = '0.6.2'/default_version = '0.6.1'/" extension/pgmnemo.control
# META.json: set version back to "0.6.1"
# pgmnemo_mcp/pyproject.toml: set version back to "0.6.1"

# Commit only the gate NO_GO file + version rollback + ROADMAP update:
git add benchmarks/gate/v0.6.2.json extension/pgmnemo.control META.json \
        pgmnemo_mcp/pyproject.toml ROADMAP.md
git commit -m "chore(v0.6.2): gate NO_GO — defer F1 to v0.6.3 (all variants failed bench)"

# DO NOT tag v0.6.2; DO NOT push tag; DO NOT ship halfway (lesson from v0.6.0).
```
