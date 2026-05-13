# pgmnemo — Honest Competitive Reality Check

**Status:** CANONICAL — written 2026-05-13, must be read alongside `BENCHMARKS.md`.
**Audience:** maintainers, evaluators, potential adopters who don't want sales pitch.

This document exists because our benchmark numbers look more flattering than the
underlying competitive position warrants. The maintainers wrote it for ourselves
first — to keep our own positioning honest — and second for adopters who want
to understand what we measured, what we didn't, and what it actually means.

---

## 1. The three asymmetries in our headline numbers

### 1.1 Session-level vs turn-level — 22× smaller search space

Our README headline says "LoCoMo recall@10 = 0.7994." This is **session-level**
retrieval over **272 sessions**. The LoCoMo paper (Maharana et al., ACL 2024,
Table 3) reports recall@K over **5882 turns** — a 22× larger search space.

Apples-to-apples comparison:

| Methodology | Search space | pgmnemo recall@5 | Paper DRAGON baseline recall@5 | Delta |
|---|---|---|---|---|
| Session-level (our headline) | 272 | 0.662 | not reported by paper | n/a |
| Turn-level (paper protocol) | 5882 | **0.302** | **0.225** | +7.7pp |

The honest "we beat the paper's DRAGON dense baseline" number is **+7.7pp on
turn-level recall@5**, not anything close to "0.795." When a potential adopter
benchmarks pgmnemo against the LoCoMo paper, they'll get the turn-level number.

### 1.2 LongMemEval — we lose to a one-script BM25 baseline

| System | LongMemEval-S recall@10 |
|---|---|
| BM25 baseline (`tsvector + ts_rank_cd`, ~50 LOC Python) | **0.982** |
| pgmnemo v0.3.0 (bge-m3 dense) | 0.933 |

The BM25 baseline lives in this repo at `benchmarks/longmemeval/run_nollm.py`.
Anyone running our bench will see this number. Our defence — that v0.4 will
promote hybrid (BM25 + dense) to default — is on the roadmap, not in the
shipped product today.

### 1.3 We're not comparable to Mem0 / Zep / MAGMA on these benchmarks

Our README states none of them "have published recall@10 on LoCoMo or
LongMemEval as of 2026-05-10." That's technically true and structurally
misleading. They optimise different objectives:

| System | What they optimise | What they report |
|---|---|---|
| Mem0 | Entity extraction + consolidation into structured facts | Memory recall accuracy on internal dialog suites; agent task completion |
| Zep | Graph+vector hybrid + temporal reasoning | F1 on Zep-internal benchmark; entity F1 |
| MAGMA | Research multi-agent memory | QA accuracy with LLM-as-judge |
| pgmnemo | Retrieval recall on raw chunks | recall@K on two academic datasets |

A fair comparison would be the **same retrieval task on the same dataset with
the same evaluation protocol**. Nobody has done that. Claims like "pgmnemo
recall > Mem0 recall" are unsupported.

---

## 2. What we don't measure (and why it matters)

Our entire bench measures one thing: **top-K membership recall on a static
corpus**. Real adopters care about much more:

| Dimension | Measured? | Why it matters for the wedge customer |
|---|---|---|
| Insertion throughput (rows/sec) | ❌ | Production memory grows; ingest path affects latency budget |
| Concurrent read/write under contention | ❌ | Multi-agent systems write in parallel |
| Memory growth over weeks/months | ❌ | Without consolidation, accuracy degrades; we don't test consolidation |
| Retrieval latency p50/p95/p99 | ⚠️ Only `wall_clock_sec` aggregate | UX matters for synchronous agent calls |
| End-to-end agent task completion | ❌ | The real measure of "did memory help" |
| Provenance gate correctness | ❌ | Our biggest moat — and we have zero regression tests for it |
| State-machine transitions (draft → canonical → archived) | ❌ | The full lifecycle is documented but not measured |
| Multi-tenant isolation (RLS) | ❌ | We have RLS policies; nobody validated them |
| Scale (1M+ rows) | ❌ | Our bench corpus is ~5000 rows max |
| Failure modes (DB crash mid-write, network partition, etc.) | ❌ | Real production failure paths |

Honest summary: **we measure one dimension out of ten that adopters care
about.** That's not unusual for an early extension, but the
"recall@10 = 0.x" headline obscures it.

---

## 3. The dataset reality

| Dataset | Scale | Use as a proxy for production memory? |
|---|---|---|
| LoCoMo | 10 conversations, 1986 questions, 5882 turns total | Tests retrieval over **clean conversation transcripts with ground-truth labels**. No noise, no hallucinations, no stale data, no cross-task contamination, no consolidation pressure. |
| LongMemEval-S | 500 questions, ~47.7 sessions per haystack | Same — clean, labeled, small. |
| BM25 baseline | n/a — a 50-LOC Python script | Beats us on LongMemEval. Tells us our dense pipeline is suboptimal for keyword-heavy queries on this dataset. |

A production agent memory at any non-toy scale has:
- failed-run artefacts mixed with successful-run lessons
- contradictions across sessions
- stale or recently-superseded facts
- variable-quality embeddings depending on agent
- multi-tenant scoping concerns
- explicit "this lesson was wrong, archive it" updates

None of this is in LoCoMo or LongMemEval. Numbers from those datasets are
**necessary but not sufficient** evidence of production fitness.

---

## 4. What we actually have that's real

Below are the differentiators that hold up under hostile review. None of them
show up directly in `recall@K` numbers.

### 4.1 Provenance gate — genuinely unique

`pgmnemo.ingest()` blocks (or warns) any write without a `commit_sha` or
`artifact_hash` token. Enforcement is at the SQL function layer, not at the
application — application bugs can't bypass it. None of Mem0, Zep, MAGMA,
MemGPT/Letta, or pgvector-alone do this. This is the actual moat. It does not
need to win a recall@K benchmark to be valuable.

### 4.2 Postgres-native install

`CREATE EXTENSION pgmnemo CASCADE`. No new service. No vendor lockin. No data
egress. pgvector has the same install model but no memory abstractions or
provenance. SaaS competitors all require a separate service + API key.

### 4.3 Apache-2.0 source-available

Mem0 has a proprietary backend behind the MIT client. Zep has a proprietary
cloud behind the Apache client. pgmnemo is Apache-2.0 end-to-end with source
on GitHub. Verifiable, forkable, self-hostable for compliance use-cases.

### 4.4 Reproducible benchmark transparency

We commit `metrics.json`, `raw_retrievals.jsonl`, and per-question retrieval
traces under `benchmarks/<bench>/results/<run>/`. Anyone can re-score with
their own metric. Competitors do not publish their evaluation methodology at
this granularity.

### 4.5 Retrieval at apples-to-apples is competitive, not dominant

On turn-level LoCoMo (paper methodology), pgmnemo is **+7.7pp recall@5 vs
DRAGON dense baseline**. That's a real number; it's also small. It says
"we're competitive with off-the-shelf dense retrieval," not "we're
revolutionary."

---

## 5. Where we are honestly weak

1. **One published bench beats us with 50 lines of Python** (BM25 on LongMemEval).
   v0.4 must fix this via hybrid promotion. If it doesn't, the adoption
   conversation is hard.
2. **Three releases of graph features (v0.2.0–v0.3.0)** delivered zero
   measurable lift because no bench exercises `mem_edge`. v0.4.1 deprecates
   the default-path BFS-mixin; the rest stays as opt-in until a real adopter
   builds a graph-eval bench.
3. **No latency, throughput, concurrent-write, or scale benchmarks.** A
   production engineer evaluating pgmnemo will need to do their own
   stress-testing.
4. **Multi-tenant RLS is implemented but not validated by any test.** A
   security review would catch this immediately.
5. **No end-to-end agent task evaluation.** We measure retrieval; we don't
   measure whether the retrieved memory actually helped the agent solve a
   downstream task.

---

## 6. What this means for adopters

If you are evaluating pgmnemo today, our honest pitch is:

- ✅ Use pgmnemo if you want **provenance-enforced memory inside your existing
  Postgres** and the alternative is wiring your own dedup + provenance logic.
- ✅ Use pgmnemo if your scale is **< 1M rows per project** and your queries
  are **mixed lexical + semantic** (hybrid coming in v0.4).
- ✅ Use pgmnemo if you need **Apache-2.0, no vendor lockin, no egress**.
- ⚠️ Run our bench against `run_nollm.py` BM25 baseline on your own data
  before committing. If BM25 alone hits your accuracy target, you may not
  need pgmnemo.
- ⚠️ Do your own latency / throughput / scale measurements. We have no public
  numbers for these.
- ❌ Do not use pgmnemo if you need **billion-row retrieval at sub-10ms**.
  That's a dedicated vector DB problem.
- ❌ Do not use pgmnemo if your workload is **dominated by entity-relationship
  reasoning over time** — Zep is purpose-built for that.

---

## 7. What we commit to fixing

Per `ROADMAP.md`:

- **v0.4.0 (2026-06-10):** beat BM25 on LongMemEval recall@10. Block the tag
  unless real-DB confirms simulation's +12pp lift.
- **v0.4.1 (2026-06-24):** deprecate default-path graph machinery; move to
  opt-in. Reduces "complexity without evidence."
- **v0.5.0 (2026-07-15):** fix per-category drift (`temporal` is currently
  our weakest LoCoMo category at recall@10 = 0.645) via temporal weight tuning.
- **v0.6.0+ (2026-08-15):** ship adapters (LangChain, LlamaIndex, Anthropic
  SDK) + first external case study. **This is when "competitive position"
  starts to mean something** — currently zero external production adopters
  are publicly known.

Until we have ≥ 3 external adopters with public case studies, every claim
in our positioning that asserts "better than X" should be read as
"hypothetically better at the narrow retrieval task we measured, with
caveats this document spells out."

---

## 8. Self-check rules for every future release announcement

Before any release blog post or social media headline cites a number:

1. Is the number from `BENCHMARK_PROTOCOL.md` frozen methodology? (If not — don't publish.)
2. Does the methodology used match the paper / competitor we're implicitly
   comparing to? (If not — say so explicitly.)
3. Have we run the BM25 baseline on the same dataset? (If yes and BM25 wins
   — disclose.)
4. Is the headline a session-level number that we'd correct on a careful
   reader's prompt? (If yes — show segment-level alongside, or use segment-level
   as the headline.)
5. Have we measured at least one of: latency, throughput, scale? (If no —
   "production-ready" must not appear in the announcement.)

This list goes in `docs/RELEASE_PROCESS.md` v0.4.0 as a mandatory pre-publish
checklist.
