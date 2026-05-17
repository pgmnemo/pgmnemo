---
task: PGMNEMO-V050-TRACKING-H02 — H-02 Stella V5 Embedder Unblock
date: 2026-05-17
priority: P1
due: 2026-05-22
branch: agent/dag-PGMNEMO-260517-1-IMPLEMENT
---

# TL Report: H-02 — Stella V5 Embedder Unblock

**Tracking task:** PGMNEMO-V050-TRACKING-H02  
**Date:** 2026-05-17  
**Scope:** Unblock `dunzhang/stella_en_1.5B_v5` embedder; confirm no recall regression vs bge-m3

---

## 1. Subtask Status

| Subtask | ID | Status | Evidence |
|---|---|---|---|
| RESEARCH | #6254 | **COMPLETE** | `spec/v2/pgmnemo/H02_STELLA_V5_RESEARCH.md` — GO verdict, Option A recommended, all 6 research gates PASS |
| IMPLEMENT | #6262 | **COMPLETE** | commit `8f38bdb` — `transformers==4.44.2` pinned in `benchmarks/longmemeval/requirements.txt`; smoke test PASS |
| BENCH | #6265 | **BLOCKED** | `scripts/run_bench.py` does not exist; PostgreSQL not running; bench venv macOS-only |

**Agent success rate:** 2/3 subtasks completed (67%). 1 ESCALATED (BENCH).  
**ESCALATED count:** 1 (BENCH #6265)  
**Stalled runs:** 0 (RESEARCH + IMPLEMENT executed to completion same day)

---

## 2. Baseline Metrics (bge-m3, from benchmarks/gate/v0.4.1.json)

Source: `benchmarks/gate/v0.4.1.json` → `tables.longmemeval.overall`

| Metric | bge-m3 (actual, n=500) | CI95 |
|---|---|---|
| recall@1 | 0.4826 | [0.4523, 0.5128] |
| recall@5 | 0.8837 | [0.8593, 0.9082] |
| **recall@10** | **0.9334** | **[0.9140, 0.9528]** |
| recall@20 | 0.9873 | [0.9801, 0.9946] |
| MRR | 0.8521 | [0.8263, 0.8780] |

**Projected Stella V5 delta** (from `H02_STELLA_V5_RESEARCH.md §4`):

| Metric | bge-m3 | Stella V5 (projected) | Δ |
|---|---|---|---|
| recall@10 | 0.9334 | 0.938–0.946 | +0.4–1.3 pp |
| MRR | 0.8521 | 0.853–0.865 | +0.0–1.3 pp |

Significance caveat: projected lift is within bge-m3 CI width (±1.9pp). No regression is expected — Stella V5 is MTEB-superior to bge-m3 on retrieval (+3.6pp MTEB retrieval avg).

**Gate status:** Bench not run; significance_test.py not executed. Acceptance criterion (bench exits 0; no regression) **NOT MET**.

---

## 3. IMPLEMENT Quality Assessment

**Commit:** `8f38bdb` — `fix(bench): pin transformers==4.44.2 to unblock Stella V5 embedder (H-02)`

| Deliverable | File | Status |
|---|---|---|
| transformers pin | `benchmarks/longmemeval/requirements.txt:7` | DONE — `transformers==4.44.2` with explanatory comment |
| Root cause doc | `benchmarks/longmemeval/ADDENDA/LONGMEMEVAL_EMBEDDER_STELLA.md` | DONE — 114 lines, §1–§7 |
| Smoke test | System Python (no torch) | PASS — `Qwen2Config.rope_theta = 10000.0` confirmed as direct attribute |

**Option A vs B correctness:** Option A (pin) is reproducible via `pip install -r requirements.txt`. Option B (patch HF cache) was correctly rejected — wipe risk at `huggingface-cli delete-cache`. Evidence: `ADDENDA §2`.

**Gap:** Smoke test used system Python without torch/sentence-transformers. Full load test (`SentenceTransformer("dunzhang/stella_en_1.5B_v5", trust_remote_code=True)`) was not run because the bench venv's python3 symlink points to `/Users/gaidabura/.local/bin/python3` (macOS path, broken in this Linux container). The smoke test proves the `rope_theta` attribute exists in 4.44.2 but does NOT confirm full model load.

---

## 4. BENCH Blocker Analysis

Three independent blockers prevented `significance_test.py` from running:

| Blocker | Location | Evidence |
|---|---|---|
| `scripts/run_bench.py` missing | `/external-repos/pgmnemo/scripts/` | `ls` confirms: only `benchmark_harness/`, `build_pgxn_bundle.sh`, adapters, `significance_test.py` |
| PostgreSQL not running | `localhost:5432` | `psql: connection refused` (server packages not installed; no initdb) |
| Bench venv macOS-only | `benchmarks/.venv_bench/venv/bin/python3` | Symlink → `/Users/gaidabura/.local/bin/python3` — broken on Linux |

The `benchmarks/longmemeval/results/v0.2.1_stella_20260510/` directory exists from WG-BENCH-5 (2026-05-10) but contains only `BLOCKED.md` — no `metrics.json`, no `report.md`, no `raw_retrievals.jsonl`.

**Pre-existing block duration:** The Stella V5 bench has been blocked since 2026-05-10 (7 days as of this report). The rope_theta blocker was fixed 2026-05-17 but the infrastructure blocker (no PG, no runner) remains.

---

## 5. Task Drafts for Remediation

### TD-H02-R1: Create `scripts/run_bench.py` for LongMemEval
**Blocker:** No bench entry-point script — task spec references `python scripts/run_bench.py --embedder stella-v5` but this file does not exist  
**Fix:** Implement `scripts/run_bench.py` wrapping `benchmarks/longmemeval/runner.py` with `--embedder` flag that maps `stella-v5` → `dunzhang/stella_en_1.5B_v5`; write output to `benchmarks/gate/v0.5.0-h02-candidate.json` in gate format  
**Files:** `scripts/run_bench.py` (new)  
**Priority:** P1 (blocks H-02 BENCH gate entirely)

### TD-H02-R2: Provision PostgreSQL for bench environment
**Blocker:** PostgreSQL server not installed — `initdb` missing, `pg_createcluster 17 main` fails  
**Fix:** Install `postgresql-17` server package; create cluster; install pgvector + pgmnemo extensions; load LoCoMo/LongMemEval corpus  
**Files:** CI/CD setup, `benchmarks/README.md` (document requirement)  
**Priority:** P1 (blocks all bench runs, not just H-02)

### TD-H02-R3: Fix bench venv for Linux / CI
**Blocker:** `benchmarks/.venv_bench/venv/bin/python3` symlinks to macOS path  
**Fix:** Recreate venv on Linux: `python3 -m venv benchmarks/.venv_bench/venv && pip install -r benchmarks/longmemeval/requirements.txt`; add torch + sentence-transformers  
**Files:** `benchmarks/.venv_bench/` (rebuild in-place or document rebuild step)  
**Priority:** P1 (bench cannot run without working Python)

### TD-H02-R4: Full Stella V5 load smoke test
**Gap:** Current smoke test (`Qwen2Config.rope_theta` attribute check) does not exercise `SentenceTransformer.encode()` end-to-end  
**Fix:** After TD-H02-R3 is resolved, run: `python -c "from sentence_transformers import SentenceTransformer; m = SentenceTransformer('dunzhang/stella_en_1.5B_v5', trust_remote_code=True); v = m.encode(['test']); print(v.shape)"` — expected `(1, 1024)`  
**Priority:** P2 (IMPLEMENT is complete; this is verification only)

---

## 6. Quality Trends

| Gate | Criterion | Status |
|---|---|---|
| Blocker identified | AttributeError at `config.rope_theta` confirmed | **PASS** (Research) |
| Root cause cited | transformers 4→5 API break at `modeling_qwen.py:312` | **PASS** (Research) |
| Fix applied | `transformers==4.44.2` in requirements.txt | **PASS** (Implement) |
| Fix documented | ADDENDA with §1–§7 including re-run command | **PASS** (Implement) |
| Smoke test | `Qwen2Config.rope_theta = 10000.0` (system Python) | **PASS** (partial) |
| Full model load | `SentenceTransformer.encode()` end-to-end | **PENDING** |
| Bench run | LME recall@10 with Stella V5 | **BLOCKED** |
| Significance test | `significance_test.py exit 0` vs bge-m3 baseline | **BLOCKED** |

**Research confidence:** H02_STELLA_V5_RESEARCH.md confidence 0.55 per HYPOTHESIS_BACKLOG; projected lift (+0.4–1.3pp recall@10) is within bge-m3 CI — the bench run is needed to confirm, but no regression is expected.

---

## 7. Self-Evaluation

**What worked:**
- RESEARCH delivered a clean GO verdict with specific evidence: `transformers-5.8.0.dist-info` confirmed installed version; `modeling_qwen.py:312` pinpointed the exact failure line; Option A vs B trade-offs quantified (3 LOC LOW vs 7 LOC MEDIUM risk).
- IMPLEMENT correctly chose Option A, added an explanatory comment to requirements.txt, and wrote thorough ADDENDA documentation (114 LOC). The hook-generated commit message is accurate and complete.
- Smoke test was correctly scoped to what the environment allowed (system Python, no torch), and the limitation was explicitly disclosed — no false-positive claim of full model load.

**What to improve:**
- The bench infrastructure gap (no `run_bench.py`, no PG, broken venv) was discoverable before BENCH was scheduled. A pre-flight check at RESEARCH/IMPLEMENT time could have surfaced TD-H02-R1 through R3 earlier, saving a full agent turn on a guaranteed BLOCKED task.
- The smoke test (`Qwen2Config.rope_theta` attribute check) is necessary but not sufficient. TD-H02-R4 (full `SentenceTransformer.encode()` load test) should have been gated as a prerequisite for IMPLEMENT DONE status, not deferred to BENCH.
- `benchmarks/longmemeval/results/v0.2.1_stella_20260510/BLOCKED.md` has been present since 2026-05-10 (7 days). A pre-run check of this directory's content would confirm immediately that no metrics exist and the bench task cannot complete without infrastructure work.
