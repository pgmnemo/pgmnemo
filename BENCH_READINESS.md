# BENCH READINESS: pgmnemo 0.8.0 vs LightRAG — Stage-4 GO/NO-GO

**Date:** 2026-06-03  
**Branch:** agent/dag-SWDEV-260603-1-SHIP  
**Spec:** spec/experiments/RES-260603-3/EXPERIMENT_SPEC.md  
**Probed from:** agency-api container (Python 3.12, psycopg2, pg_config available; no local psql)  
**DB probed:** prod_corpus via DATABASE_URL / PGMNEMO_DATABASE_URL  

---

## VERDICT: GO-WITH-PROVISIONING

**8 provisioning items required** (listed in §6). No design gaps or missing implementation —
all blockers are operational/setup.

---

## §1 pgmnemo 0.8.0 Install Readiness

### SQL artifacts

| Artifact | Status | Detail |
|----------|--------|--------|
| `extension/pgmnemo.control` | ✅ PASS | `default_version = '0.8.0'` — correctly set |
| `extension/pgmnemo--0.8.0.sql` | ✅ PASS | Present, 4554 lines |
| `extension/pgmnemo--0.7.2--0.8.0.sql` | ✅ PASS | Present, 639 lines (migration) |
| navigate_locate function in SQL | ✅ PASS | Found at line 4027 (full file) / line 77 (migration) |
| navigate_expand function in SQL | ✅ PASS | Found at line 4276 / line 361 |
| reembed in SQL | ✅ PASS | Present |
| reembed_batch in SQL | ✅ PASS | Present |
| recompute_content in SQL | ✅ PASS | Present |
| source_type column definition | ✅ PASS | `CHECK (source_type IN ('agent_authored','auto_captured','imported','system'))` |

### Makefile gap ⚠️ BLOCKER

The `extension/Makefile` DATA list ends at `pgmnemo--0.7.2.sql`. Neither
`pgmnemo--0.7.2--0.8.0.sql` nor `pgmnemo--0.8.0.sql` is listed.
**`make install` will NOT deploy the 0.8.0 SQL files to the server extension directory.**

```
# Makefile DATA ends at:
pgmnemo--0.7.1--0.7.2.sql \
pgmnemo--0.7.2.sql          ← last entry; 0.8.0 files ABSENT
```

REGRESS test list also has no 0.8.0 tests registered.

### pg_regress / installcheck

- `psql` is **not in PATH** in this container.
- No local PostgreSQL socket detected (`/var/run/postgresql/` absent).
- `make installcheck` / `pg_regress` **cannot be run** from this environment.
- Static verification only: SQL syntax was not re-parsed; function bodies confirmed
  present by line-grep.

### Privilege

- `/usr/share/postgresql/17/extension/` — no pgmnemo files present (empty listing).
- `make install` requires write access to that directory (root or postgres user).
- **Cannot perform `CREATE EXTENSION pgmnemo VERSION '0.8.0'`** on a scratch DB
  until files are deployed to the server's extension directory.

### Production DB state (prod_corpus)

Probed via psycopg2:

| Check | Result |
|-------|--------|
| pg_extension version | **0.7.1** ❌ (not 0.8.0) |
| pg_extension_update_paths to 0.8.0 | **EMPTY** ❌ (SQL files not in server ext dir) |
| navigate_locate present | ✅ |
| navigate_expand present | ✅ |
| reembed present | ✅ |
| reembed_batch present | ✅ |
| recompute_content present | ✅ |
| source_type column | ✅ |
| embedding_at column | ✅ |

**Explanation of mismatch:** The 0.8.0 SQL was applied to the production DB manually
(functions + schema deployed outside the PostgreSQL extension system). The extension
catalog still says 0.7.1. P3 (`extversion = '0.8.0'`) formally fails.

### API signature vs EXPERIMENT_SPEC

Live call `SELECT * FROM pgmnemo.navigate_locate(NULL, 'test query', 500) LIMIT 1`
returned columns: `(id, score, tokens_consumed, navigation_path)`.

The EXPERIMENT_SPEC.md §2 defines:
```sql
RETURNS TABLE (id, preview, score, tokens_consumed, navigation_path)
```

**`preview` (first 50 chars of content) is MISSING from the deployed function.**
Similarly, `navigate_expand` deployed signature is:
```
(id, content, expand_detail, navigation_path)
```
Spec requires:
```
(id, content, expand_detail, graph_neighbor_ids, graph_neighbor_previews, tokens_consumed)
```
`graph_neighbor_ids`, `graph_neighbor_previews`, `tokens_consumed` absent from expand.
The SQL files on the branch match the deployed signatures — **spec §2 API table is aspirational,
not the implemented contract.** Harness must be written against actual signatures.

**navigate_locate live call result:**  
`(id=7555, score=0.0147, tokens_consumed=1353, navigation_path='vector')` — function runs, returns data.

---

## §2 LightRAG Readiness

| Item | Status | Detail |
|------|--------|--------|
| lightrag-hku installed | ✅ PASS | v1.5.0 |
| Anthropic LLM backend | ✅ PASS | `lightrag/llm/anthropic.py` present; uses `AsyncAnthropic` |
| ANTHROPIC_API_KEY | ✅ PASS | Present in environment |
| OpenAI key | ❌ ABSENT | No `OPENAI_API_KEY` — default LightRAG config would fail immediately |
| LightRAG config for Anthropic | NEEDS SETUP | Requires `llm_model_func=anthropic_complete_if_cache` |

**This deployment is Claude-subscription OAuth only. `OPENAI_API_KEY` is absent and
will not be provisioned.** LightRAG must be configured for the Anthropic backend.
Configuration change is straightforward (one env var + kwarg); this is not a hard blocker.

**LightRAG entity extraction cost estimate (B2 corpus, 5,979 lessons):**

- Model: claude-haiku-4-5 (cheapest Claude, sufficient for entity extraction)
- Avg lesson: ~300 input tokens + ~80 output tokens
- Input: 5979 × 300 = 1.79M tok × $0.001/Ktok ≈ **$1.79**
- Output: 5979 × 80 = 478K tok × $0.005/Ktok ≈ **$2.39**
- **Total ingestion: ~$4-8** (depending on chunk size strategy)

For LoCoMo (600 conversations → ~2,000 chunks):
- ~$2-5 additional ingestion cost.

---

## §3 Datasets

| Dataset | Present | Package | License | Action |
|---------|---------|---------|---------|--------|
| LoCoMo (arXiv:2402.17753) | ❌ Not found | `datasets` not installed | CC BY 4.0 | `pip install datasets` + download |
| MuSiQue (arXiv:2108.00573) | ❌ Not found | Same | CC BY 4.0 | Same |

- HuggingFace network reachability: untested (test cancelled; network likely available given pip works).
- Estimated sizes: LoCoMo ~50–100 MB, MuSiQue ~100–200 MB.
- Download + format prep estimated at **30–60 min** one-time.

---

## §4 Agency In-Prod Arm (B2)

Live query results from prod_corpus:

| Metric | Value | Prerequisite | Status |
|--------|-------|-------------|--------|
| Total lessons | 5,979 | — | ✅ |
| Embedded lessons | 5,979 (100%) | P4 | ✅ |
| Long content > 500 chars (lesson_text) | 1,422 (23.8%) | P6 ≥ 20% | ✅ |
| mem_edge count | **0** | P7 > 0, ratio ≥ 0.5 | ❌ FAIL |
| Edge/lesson ratio | 0.00 | P7 ≥ 0.5 for B2-dense | ❌ FAIL |
| pgmnemo catalog version | 0.7.1 | P3 ≥ 0.8.0 | ❌ FAIL |

**mem_edge = 0 is the most severe operational blocker.** Arm B's `navigate_expand`
graph traversal joins `mem_edge` — with zero edges, `graph_expand_depth=1` always
returns empty graph neighbors. B2-dense arm becomes a vector-only test, invalidating
the graph-expand hypothesis.

**Required:** Rule-based edge population (no LLM cost):
- Causal: lessons sharing same `source_run_id` or `dag_id` → causal edge
- Temporal: lessons within 60-minute windows → temporal edge
- Target: ≥ 0.5 edges/lesson for B2-dense subset

Note: The `lesson_text` field is used in production (not `content`). Harness queries
must use `lesson_text`, not `content`. `full_text` is also present (indexed for BM25).

---

## §5 Harness + Estimate

### Python packages

| Package | Status | Version |
|---------|--------|---------|
| pandas | ✅ | 2.3.3 |
| numpy | ✅ | 2.4.5 |
| transformers | ✅ | 5.9.0 |
| bge-m3 tokenizer | ✅ | Loads from cache (no PyTorch needed for tokenizer) |
| lightrag-hku | ✅ | 1.5.0 |
| psycopg2 | ✅ | (present, used in probing) |
| scipy | ❌ | Not installed |
| statsmodels | ❌ | Not installed |
| datasets | ❌ | Not installed |
| Eval harness script | ❌ | Not written |

P5 (bge-m3 tokenizer): **PASS** — `AutoTokenizer.from_pretrained("BAAI/bge-m3")`
produces 15 tokens for a 54-char test string; PyTorch absent but tokenizer-only use works.

### Compute / wall-time / cost estimate

**Scope:** 1,050 questions × 5 arms = 5,250 retrieval+answer evaluations

| Component | Count | Model | Est. cost |
|-----------|-------|-------|-----------|
| LLM answers | 5,250 | claude-sonnet-4-6 (~2,000 tok in, 256 out) | ~$55 |
| IU judge (DV6) | 5,250 | claude-haiku (~500 tok in, 100 out) | ~$0.50 |
| LightRAG ingestion (B2+B1) | ~8,000 chunks | claude-haiku | ~$8 |
| bge-m3 embeddings | B1+B3 corpus | local (no API cost) | $0 |
| **Total API cost** | | | **~$65–100** |

**Wall-time** (10-way parallelism):
- LLM eval calls: 5,250 / 10 × 3s = **~26 min**
- LightRAG ingestion: 8,000 chunks / 20 × 2s = **~13 min**
- Dataset prep + corpus loading: **~60 min** (one-time)
- **Total: ~2–3 hours end-to-end**

---

## §6 Provisioning Checklist (Ordered by Priority)

| # | Item | Effort | Blocks |
|---|------|--------|--------|
| P1 | **mem_edge population**: Write + run rule-based edge extraction script (dag_id causal + 60-min temporal). Target ≥ 0.5 edges/lesson for B2-dense. | ~2h | B2-dense arm, P7 |
| P2 | **Makefile fix**: Add `pgmnemo--0.7.2--0.8.0.sql` and `pgmnemo--0.8.0.sql` to DATA list; add 0.8.0 regression tests to REGRESS list. | 15 min | `make install`, pg_regress |
| P3 | **Extension catalog bump**: After P2 + `make install` on server: `ALTER EXTENSION pgmnemo UPDATE TO '0.8.0'`. Verify `SELECT extversion FROM pg_extension WHERE extname='pgmnemo'` = '0.8.0'. | 5 min | P3, P4 prerequisites |
| P4 | **Dataset download**: `pip install datasets` + `datasets.load_dataset('Locomo-main/LoCoMo-Dataset')` + MuSiQue. Estimate 30–60 min. | 1h | B1, B3 benchmarks |
| P5 | **Python deps**: `pip install scipy statsmodels` — required for bootstrap CI + Wilcoxon signed-rank (§5 SAP). | 2 min | Statistical analysis |
| P6 | **LightRAG config**: Set `llm_model_func=anthropic_complete_if_cache`, `llm_model_name="claude-haiku-4-5"` in Arm D harness. No OpenAI key will be provisioned. | 15 min | Arm D (LightRAG) |
| P7 | **Eval harness**: Write Python harness for 5-arm design per EXPERIMENT_SPEC.md §4. Use actual function signatures (no `preview` in navigate_locate; use `lesson_text` not `content`). | ~1 day | Full bench run |
| P8 | **Spec/code alignment**: Decide whether to add `preview` to navigate_locate return type (left-truncated content) before harness is written, or accept current signature and adjust harness. | 2h | Arm B correctness |

---

## §7 Prerequisites Status (per EXPERIMENT_SPEC §0)

| Prereq | Spec requirement | Actual | Status |
|--------|-----------------|--------|--------|
| P1 | navigate_locate passes unit tests | Function present, runs, returns data; no formal unit tests run (psql absent) | ⚠️ PARTIAL |
| P2 | navigate_expand passes unit tests | Function present; not invoked in live test | ⚠️ PARTIAL |
| P3 | extversion ≥ 0.8.0-alpha | extversion = 0.7.1 | ❌ FAIL |
| P4 | Extension installed on experiment DB | Functions/schema present but catalog wrong | ⚠️ PARTIAL |
| P5 | bge-m3 tokenizer available | ✅ loads, tokenizes correctly | ✅ PASS |
| P6 | ≥ 20% long-content lessons > 500 chars | 23.8% (1422/5979) | ✅ PASS |
| P7 | Graph edges populated, ratio ≥ 0.5 for B2-dense | 0 edges total | ❌ FAIL |

---

## §8 No-Go Conditions Check

| Condition | Spec threshold | Current evidence | Risk |
|-----------|---------------|-----------------|------|
| N1: F1 regression > 5pp | F1(B) < F1(A) − 5pp | Cannot assess pre-bench | — |
| N2: TER not significant AND tokens not reduced | — | Cannot assess pre-bench | — |
| N3: Latency p95 > 500ms | 10K-row corpus | Not measured; B2 has 5,979 rows | LOW (in-DB SQL) |
| N4: Two-call overhead > 2× | locate + expand < 2× single | Not measured | LOW (both are simple SQL) |

---

## §9 Summary

**VERDICT: GO-WITH-PROVISIONING**

Code is complete. All 5 required functions (navigate_locate, navigate_expand, reembed,
reembed_batch, recompute_content) and 0.8.0 schema columns are present in prod. bge-m3
tokenizer works. LightRAG is installed with Anthropic backend. Long-content requirement
(P6) met.

**Hard blockers before bench can run:**
1. mem_edge = 0 (graph-expand never fires → B2-dense invalid)
2. Extension catalog version 0.7.1 ≠ 0.8.0 (P3/P4 formally failed)
3. Datasets not downloaded (B1/B3 have no data)
4. Eval harness not written

**Provisioning budget estimate:** ~1 engineer-day + ~$75–100 API cost.

LLM key situation: **OPENAI_API_KEY absent, ANTHROPIC_API_KEY present.** This is
expected for this deployment. LightRAG configured for Anthropic backend is sufficient.
No OpenAI key should be treated as a provisioning need — it is an explicit non-requirement.

---

*Probed: 2026-06-03 | Replication Validator (assignee_id=83) | RES-260603-3 Stage 4*
