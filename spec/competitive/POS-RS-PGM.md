# POS-RS-PGM: Benchmark Card Design + Reproducibility Moat

**Document ID:** PGMNEMO-WG-STRAT-260517  
**Role:** research_supervisor — methodological authority  
**Date:** 2026-05-16  
**Status:** v0 — pre-implementation spec  
**Relates to:** CROSS_CUTTING_SYNTHESIS_2026-05-16.md §Rec#7; Agency WG-STRAT-260516 §14 D6  
**License:** Apache-2.0 — zero legal friction on publication

---

## 1. Benchmark Card v0 Design

### 1.1 Cell selection rationale

The card publishes exactly **8 cells** across three corpora. Every cell that pgmnemo loses is included. Cells are fixed before the v0.4.1 tag; no new cells may be added without a public RFC commit predating the run.

| # | Cell | Corpus | Metric | N (questions) | Current value | Honest note |
|---|---|---|---|---|---|---|
| C1 | LoCoMo session recall@10 | LoCoMo (ACL 2024) | recall@10 | 1,986 | **0.8409** | Session-pooled; 22× smaller search space than paper Table 3 |
| C2 | LoCoMo temporal-category recall@10 | LoCoMo (ACL 2024) | recall@10 | ~340 | **0.645** | Weakest category; H-06 fix targeted for v0.5.0 |
| C3 | LongMemEval-S recall@10 | LongMemEval (ICLR 2025) | recall@10 | full session | **0.9334** | bge-m3 substitution for Stella V5; see addendum |
| C4 | LongMemEval-S vs BM25 gap | LongMemEval (ICLR 2025) | recall@10 Δ vs BM25 | full session | **−0.049** | pgmnemo LOSES to a 50-LOC BM25 script on this corpus |
| C5 | Agency-corpus recall@10 | Agency production (N=1060) | recall@10 | 1,060 | **0.5745** | Real-world agent memory; leave-one-out self-retrieval |
| C6 | LoCoMo session MRR | LoCoMo (ACL 2024) | MRR | 1,986 | **0.6463** | Paired to C1; cross-validate against competitors citing MRR only |
| C7 | LongMemEval-S MRR | LongMemEval (ICLR 2025) | MRR | full session | **0.8472** | — |
| C8 | Provenance gate write-rejection rate | Internal gate audit | pct writes rejected under `gate_strict=enforce` | 500 synthetic + 500 real | **TBD (to run pre-publication)** | First metric no competitor can produce — structural moat proof |

**Why C4 and C8?**  
C4 is the cell we lose. Publishing it prevents the "cherry-picked dataset" accusation levelled at Mem0 (HN 44883133). C8 is the cell nobody else can fill — it is proof-of-mechanism for the provenance moat, not a recall quality metric. Including it alongside recall numbers anchors the card in pgmnemo's actual differentiator rather than a parity race we are not yet winning on all axes.

### 1.2 Sample sizes and confidence intervals

| Cell | N | CI method | Width at 95% |
|---|---|---|---|
| C1–C2 | Q = 1,986 questions × 10 conv | Wilson interval on recall@10 | ±~1.4pp at r=0.84 |
| C3–C4 | Q = full LongMemEval-S session count | Wilson interval | ±~0.8pp at r=0.93 |
| C5 | Q = 1,060 | Wilson interval | ±~3.0pp at r=0.57 |
| C6–C7 | same N as C1/C3 | Bootstrap (1,000 resample), report p5–p95 | — |
| C8 | 1,000 writes (500 synthetic / 500 real) | Exact binomial CI | ±~3.1pp at p=0.95 |

CI values are computed by `scripts/significance_test_extended.py` and included in the published `card_v0/metrics.json`. The card HTML/markdown shows `value ± half_width_95CI`. **No headline value is published without its CI.**

### 1.3 Hardware specification (for latency cells — NOT for recall cells)

Recall@K is hardware-independent (deterministic given model weights + input). The card does not publish latency as a primary metric in v0. If latency is added in v1, the full rig is declared:

- CPU: Apple M-series (M3 Pro or later), ≥24 GB unified memory
- GPU/accelerator: Metal Performance Shaders (MPS) for embedding inference
- PostgreSQL: 17.x, pgvector ≥ 0.7.0, default `max_parallel_workers_per_gather = 2`
- Docker image: `pgvector/pgvector:pg17` pinned to the SHA recorded in `benchmarks/snapshots/INDEX.md`

Recall results from other hardware must match within 95% CI overlap to be cited as "reproduced". The card declaration: *"Recall metrics are hardware-independent and reproducible on any machine with sufficient RAM to hold the embeddings."*

### 1.4 Replication script

Three commands reproduce every recall cell:

```bash
# 1. Restore the frozen corpus snapshot (Phase A reuse — no re-embedding required)
docker compose -f benchmarks/docker-compose.bench.yml up -d
docker exec pgmnemo-bench pg_restore -U bench -d bench \
  benchmarks/snapshots/corpus_locomo_dragon_$(cat benchmarks/snapshots/INDEX.md | grep locomo | awk '{print $2}').dump

# 2. Run Phase B retrieval-only suite against the target version
python benchmarks/scripts/run_locomo_bench.py --skip-corpus --pgmnemo-version 0.4.1
python benchmarks/scripts/run_longmemeval_pgmnemo_full.py --skip-corpus --pgmnemo-version 0.4.1
python benchmarks/scripts/run_agency_corpus_bench.py --skip-corpus --pgmnemo-version 0.4.1

# 3. Emit card row
python scripts/emit_card_row.py \
  --locomo  benchmarks/locomo/results/v0.4.1_*/metrics.json \
  --lme     benchmarks/longmemeval/results/v0.4.1_*/metrics.json \
  --agency  benchmarks/agency_corpus/results/v0.4.1_*/metrics.json \
  --out     spec/competitive/card_v0/v0.4.1_row.json
```

The script `emit_card_row.py` is committed before the v0.4.1 tag. It is frozen; the card row it produces is the publication artifact.

---

## 2. Trusted-Third-Party Design

### 2.1 The Zep/Mem0 benchmark integrity failure — what not to do

In the public record: Mem0 published LoCoMo numbers where Zep was deliberately misconfigured (–10pp swing on reproduction; HN 44883133). Zep responded with numbers that Mem0 disputed as overclaiming their own 84% figure. The community read: *"completely botched the implementation of their competitors' solutions."* Neither party is now trusted on self-reported competitive numbers.

pgmnemo's card is not a competitive-positioning artifact. It is a retrieval-quality ledger. The design constraints flow from that commitment.

### 2.2 Pre-registered evaluation protocol

**Mechanism:** Before any Phase B retrieval run that feeds the card, a protocol snapshot is committed to the repository:

```
benchmarks/gate/card-v0-protocol.json
```

This file contains: dataset SHA-256, embedder name + HuggingFace model SHA, pgmnemo version under test, GUC values, k values, CI method, significance threshold, and the git commit SHA of `run_*.py` scripts. The commit hash of this file appears in the published card header.

**Rule:** If the protocol file is absent or post-dates the results directory, the `emit_card_row.py` script exits 1 and refuses to emit. Pre-registration is mechanically enforced, not honor-system.

**For competitor cells (future v1 card):** If pgmnemo ever publishes competitor recall numbers, each competitor's configuration is frozen in a peer-reviewed `benchmarks/configs/<competitor>_v<version>.json` before the run. Any deviation from that config in the run is a protocol violation and voids the cell. v0 card contains **no competitor numbers** — pgmnemo's own numbers only. This is the conservative default.

### 2.3 Released raw outputs

For every card row:
- `benchmarks/<dataset>/results/v<version>_<date>/per_question_scores.jsonl` — one line per question with question_id, retrieved_ids, ground_truth_ids, hit@k for k=5,10,25,50
- `benchmarks/<dataset>/results/v<version>_<date>/metrics.json` — aggregate with CI values
- `benchmarks/<dataset>/results/v<version>_<date>/config.json` — exact GUC values, embedder hash, k values

These files are committed to the repository and reachable via stable GitHub permalink from the card. **Aggregate numbers alone are not published anywhere.** Every headline number links to the per-question breakdown.

### 2.4 Documented negative results — mandatory cells

The following cells are **required** and may not be omitted regardless of their value:

- **C4** (LongMemEval BM25 gap): published even when negative. If v0.5.0 closes the gap, the old row stays visible with a strikethrough (see §4).
- **C2** (temporal category): the weakest LoCoMo category is always shown. If it regresses, the regression is flagged red.
- **C5** (Agency-corpus): the real-world production corpus recall is always shown, even if lower than academic baselines.

The rationale for mandatory negative cells: a card that only shows wins is indistinguishable from cherry-picking. Publishing where we lose is the only mechanism that makes the where-we-win cells credible.

---

## 3. Two-Way Deliverable Structure with Agency (D6)

### 3.1 Confirmed split

**pgmnemo owns card publication.** Agency provides corpus + harness as one of N data sources. This split is correct from a research-methodology standpoint for the following reasons:

1. **Independence of measurement from publication.** The entity that runs the bench should not be the same entity that controls what the card says. Agency runs its harness on its corpus and provides `metrics.json`; pgmnemo integrates that into the card under its own editorial control. Neither party can unilaterally inflate a result.

2. **Data provenance, not benchmark authority.** Agency's corpus is real-world production agent memory (N=1060 lessons from real agent sessions). That makes it the most rigorous data source in the card. But corpus quality does not grant Agency authority over the card's presentation, CI methodology, or framing. Those are pgmnemo's methodological responsibility.

3. **Multi-source design.** The card for v1 will include ≥ 3 corpora (LoCoMo, LongMemEval, Agency, and any additional adopter who contributes under a signed contributor agreement). No single corpus dominates. Agency is the first external contributor, not the only one.

### 3.2 Operational responsibilities

| Responsibility | Owner | Artifact |
|---|---|---|
| Protocol pre-registration | pgmnemo | `benchmarks/gate/card-v0-protocol.json` |
| LoCoMo + LongMemEval runs | pgmnemo | `benchmarks/*/results/v<version>_*/` |
| Agency-corpus run | Agency | `scripts/measure_recall_locomo.py` output → handed to pgmnemo |
| Card emission script | pgmnemo | `scripts/emit_card_row.py` |
| Card publication (spec/competitive/card_v0/*.md) | pgmnemo | committed to pgmnemo repo |
| Raw output hosting | pgmnemo | GitHub permalinks from card |
| CI gate file | pgmnemo | `benchmarks/gate/v<version>.json` |

**Agency's contribution format:** A signed-off `benchmarks/agency_corpus/results/v<version>_<date>/metrics.json` matching the schema of `emit_card_row.py`. Agency does not commit directly to the card file; they deliver the data artifact.

### 3.3 What this is NOT

- Agency does not have veto over card wording, CI methodology, or which other corpora are included.
- pgmnemo does not have the right to alter Agency's `metrics.json` numbers. If the number is wrong, the fix is to re-run the bench, not to edit the JSON.
- The card is not a joint publication with Agency's name on it. It is a pgmnemo publication that cites Agency as a corpus contributor.

---

## 4. Release-Gate Integration (v0.4.1 / v0.5.0)

### 4.1 Auto-publish on tag

Yes, the card row auto-publishes **on every release tag** — but only if the bench gate passes. The CI workflow:

```yaml
# .github/workflows/release.yml (addition)
- name: Emit card row
  if: startsWith(github.ref, 'refs/tags/v')
  run: |
    python scripts/emit_card_row.py \
      --locomo  benchmarks/locomo/results/v${VERSION}_*/metrics.json \
      --lme     benchmarks/longmemeval/results/v${VERSION}_*/metrics.json \
      --agency  benchmarks/agency_corpus/results/v${VERSION}_*/metrics.json \
      --out     spec/competitive/card_v0/${VERSION}_row.json
    python scripts/update_card_md.py spec/competitive/card_v0/
    git add spec/competitive/card_v0/
    git commit -m "card: auto-publish row for ${VERSION}"
    git push
```

`update_card_md.py` regenerates `spec/competitive/card_v0/CARD.md` from all `*_row.json` files, sorted by version, with the most recent row at the top.

### 4.2 Regression invalidation rule

A previously-published card row is **invalidated** when:

> `Δ recall@10 ≥ 2pp absolute drop` on any cell **and** `p_corr < 0.05` (Holm-Bonferroni corrected, two-proportion z-test)

This matches the existing bench-gate regression threshold in `BENCHMARK_PROTOCOL.md §3`.

**Presentation:** The old row is not deleted. The invalidated cells receive a strikethrough on the old value and the new value in bold with a `⚠ REGRESSION` badge:

```
| C1 | LoCoMo session recall@10 | ~~0.8409~~ → **0.8180** ⚠ REGRESSION (−2.29pp, p=0.031) |
```

The commit that emits the regression row includes a message explaining the root cause (from the release notes). This is the "transparent failure" mechanism that makes the card a living document rather than a curated highlight reel.

### 4.3 Card row lifetime

A card row is considered **active** until superseded by a newer tag row. Rows for end-of-life versions (< 0.1.x) are archived to `spec/competitive/card_v0/archive/` but not deleted — they are part of the permanent record.

---

## 5. Falsification Rules for pgmnemo's Own Claims

### 5.1 Agency-corpus recall@10 drops below 0.55

**Trigger:** Any release candidate where `scripts/significance_test_extended.py` reports Agency-corpus recall@10 `< 0.55` with `p_corr < 0.05`.

**Required actions (in order):**

1. **Block the tag.** The release is not shipped. This is not negotiable — it mirrors the existing bench-gate protocol.
2. **Publish a public incident note** in `spec/reports/RECALL_INCIDENT_<date>.md` within 48 hours of detection, stating the measured value, the triggering threshold, and the hypothesis for root cause.
3. **Notify Agency** directly (the first external production adopter; their Architecture C gate depends on recall@10 ≥ 0.55).
4. **Open a GitHub Issue** tagged `recall-regression` + `P0` with the incident note linked.
5. **Do not ship a "recovery" release** until the root cause is diagnosed and a bench run under the fixed code shows recall@10 ≥ 0.55 with p_corr < 0.05.

The published card's Agency-corpus row carries a `status: HOLD` badge for any version where the gate was triggered, even if the version never shipped.

### 5.2 Write-time RLS enforcement fails a security audit

**Trigger:** An external security audit, a CVE disclosure, or a reproducible exploit demonstrates that `gate_strict=enforce` can be bypassed — i.e., a write without valid `commit_sha` or `artifact_hash` succeeds at the DB layer.

**Required actions:**

1. **Retract the provenance-gate claim from the card.** Cell C8 (write-rejection rate) is removed from the active card and replaced with `⚠ CLAIM SUSPENDED — security audit in progress`. This happens within 24 hours of confirmed reproduction.
2. **Publish a security advisory** in `SECURITY.md` and as a GitHub Security Advisory, with CVE request filed.
3. **No new "provenance-gated" marketing** until a patched version ships and the audit confirms the fix.
4. **Restore the cell** only after an independent reproducer (not the pgmnemo team) confirms the fix under the original test conditions.

The falsification rule exists because the provenance gate is the sole structural moat (per CROSS_CUTTING_SYNTHESIS §"Подтверждённое"). A broken gate that is publicly announced and fixed is recoverable. A broken gate that is quietly buried is an integrity failure that cannot be recovered from.

### 5.3 General falsification posture

pgmnemo's public benchmark card operates under the following standing rule:

> **"If a claimed number is wrong, the right response is to say so publicly, correct it, and explain what changed — not to quietly re-run until a better number appears."**

This is operationalized as: every `emit_card_row.py` run produces a SHA-stamped artifact that is committed. Retroactive modification of a committed card row is a repository integrity violation detectable by `git log`. The CI release workflow verifies the card row commit chain on every tag.

---

## Appendix: Protocol Pre-Registration Checklist (v0 card)

Before running any Phase B bench feeding the card, verify all items are committed:

- [ ] `benchmarks/gate/card-v0-protocol.json` exists with SHA of this spec in `protocol_spec_sha`
- [ ] `benchmarks/gate/card-v0-protocol.json` predates `benchmarks/*/results/v<version>_*/` by at least one commit
- [ ] Dataset SHAs in protocol match `benchmarks/snapshots/INDEX.md`
- [ ] Embedder model SHAs match those in `benchmarks/configs/embedders.json`
- [ ] `scripts/emit_card_row.py` is committed and its SHA is in the protocol file
- [ ] Agency has delivered `benchmarks/agency_corpus/results/v<version>_<date>/metrics.json` with signed-off corpus description
- [ ] All raw output directories are committed (not gitignored)

**Publication is blocked if any item is unchecked.**
