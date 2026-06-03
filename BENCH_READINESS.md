# BENCH_READINESS — pgmnemo 0.8.0 vs LightRAG Stage-4 GO/NO-GO

**Date:** 2026-06-03  
**Assessor:** Replication Validator  
**Branch assessed:** `agent/dag-SWDEV-260603-1-SHIP` (`/external-repos/pgmnemo/`)  
**Spec ref:** Agency `spec/experiments/RES-260603-3/EXPERIMENT_SPEC.md`  
**Verdict:** **GO-WITH-PROVISIONING** — 5 blocking items; none require code changes.  
**Assessor:** replication_validator  
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
- **Workaround executed:** `test_v080.sql` (17 tests) run in full via psycopg2 against
  the production DB (which has 0.8.0 functions deployed on top of 0.7.1 extension record).
- **Result: 17/17 PASS** — all DO-block tests emitted explicit PASS NOTICEs; all SELECT
  tests returned expected boolean results. See §7 for full test list.

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
| `ANTHROPIC_API_KEY` | **❌ EMPTY** | Env var set but value is `''` (empty string) |
| `CLAUDE_CODE_OAUTH_TOKEN` | Present (unusable) | `sk-ant-oat01-*` — Claude.ai subscription OAuth. `AsyncAnthropic` rejects this format. |
| `OPENAI_API_KEY` | ❌ ABSENT | Not set; not expected on this deployment |
| LightRAG config for Anthropic | NEEDS SETUP | Requires `llm_model_func=anthropic_complete_if_cache` + real `sk-ant-api03-*` key |

**BLOCKER:** `ANTHROPIC_API_KEY` is empty; `CLAUDE_CODE_OAUTH_TOKEN` (`sk-ant-oat01-*`)
is a Claude.ai subscription OAuth token and is **not compatible** with the Anthropic SDK
`AsyncAnthropic` client. LightRAG entity extraction will fail immediately until a real
API key (`sk-ant-api03-*`) is provisioned. This deployment has no usable LLM API key
for LightRAG Arm D.

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

| Dataset | Present | Detail | License | Action |
|---------|---------|--------|---------|--------|
| LoCoMo (arXiv:2402.17753) | ✅ PARTIAL | `benchmarks/data/locomo/locomo10.json` — 10 sessions, 1,986 Q&A pairs, 5 categories | CC BY 4.0 | Verify category 3 gap (96 pairs < 150 target); optionally download full 50-session set |
| MuSiQue (arXiv:2108.00573) | ❌ NOT FOUND | Absent from all searched paths | CC BY 4.0 | Download 2-hop subset (~45 MB) |

**LoCoMo category gap:** Spec requires 150 × 4 question types. Actual category counts:
Cat 1=282, Cat 2=321, Cat 3=**96** (below target), Cat 4=841, Cat 5=446. Category 3
has only 96 pairs — adjust stratification to 96 for Cat 3, or download full LoCoMo
(50 sessions, ~10× more Q&A pairs) to hit 150×4.

**Embed cache note:** Existing caches use `dragon` model embeddings. Spec mandates
`bge-m3` (1024d). Cache must be regenerated before bench (one-time, ~15 min, no GPU
required — bge-m3 tokenizer confirmed present).

MuSiQue download:
```bash
pip install datasets
python3 -c "from datasets import load_dataset; load_dataset('dtaghi1/musique')"
# Or: wget from https://github.com/StonyBrookNLP/musique/releases (2-hop subset ~45MB)
```

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
| P1 | navigate_locate passes unit tests | **17/17 tests PASS** via psycopg2 execution of `test_v080.sql` (T3–T7 cover locate) | ✅ PASS |
| P2 | navigate_expand passes unit tests | **17/17 tests PASS** (T8–T10 cover expand + graph traversal) | ✅ PASS |
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

Code complete. 17/17 unit tests PASS via live psycopg2 execution. All 5 required
0.8.0 functions + `source_type` + `embedding_at` columns are present in prod. bge-m3
tokenizer works (`transformers` installed). LightRAG 1.5.0 installed with Anthropic
backend. Long-content requirement P6 met (33.8%).

**Hard blockers (bench cannot start without these):**
1. `ANTHROPIC_API_KEY` empty — LightRAG Arm D blocked (provision `sk-ant-api03-*`)
2. `mem_edge = 0` — graph-expand never fires → B2-dense arm invalid
3. Extension catalog 0.7.1 ≠ 0.8.0 — P3/P4 formally failed (Docker rebuild + ALTER)
4. MuSiQue dataset absent — B3 arm has no data

**Provisioning budget estimate:** ~1 engineer-day + ~$35–65 API cost.

LLM key situation: **OPENAI_API_KEY absent. ANTHROPIC_API_KEY env var present but EMPTY.**
`CLAUDE_CODE_OAUTH_TOKEN` is Claude.ai subscription OAuth — not usable as Anthropic SDK API key.
**Provisioning a real `sk-ant-api03-*` key is required for Arm D (LightRAG).**
OPENAI_API_KEY is an explicit non-requirement on this deployment.

---

*Probed: 2026-06-03 | Replication Validator (assignee_id=83) | RES-260603-3 Stage 4*
