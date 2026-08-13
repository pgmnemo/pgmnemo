# Evidence

pgmnemo claims to be measured rather than asserted. This file is where that claim
is cashed. It describes the one controlled experiment we have run, publishes the
result that went against us first, and links the data and the script so every
number can be checked without taking our word for anything.

GUC defaults and the evidence behind each one are audited separately in
[GUC_EVIDENCE.md](GUC_EVIDENCE.md).

---

## The finding that cost us a quarter

**Selective recall performed as if there were no memory at all.**

We built score-gated, type-filtered recall on the premise that a memory which
knows when to stay quiet beats one that always speaks. Measured against a control
arm with recall switched off entirely, the selective arm was statistically
indistinguishable from having no memory: 55.5% task success against 55.3%,
chi-square 0.001, p=0.98. Plain always-on recall beat it (p=0.048 uncorrected).

Selectivity did save money — the selective arm was the cheapest of the three —
but it saved it by withholding the context that produced the benefit.

This is published first because it is the most useful result here for anyone else
building agent memory, and because it is the result that costs us the most.
Score-gated filtering (`p_min_score`) therefore defaults to off.

---

## The experiment

**What it measures.** Whether agents produce better outcomes with memory — not
whether a retriever ranks the right row. Retrieval quality is measured separately
against LoCoMo and LongMemEval; see [BENCHMARK_PROTOCOL.md](BENCHMARK_PROTOCOL.md).

**Design.** Three arms, assigned per agent run over a 30-day window on a
production fleet doing real work. No task selection, no cherry-picked slice, no
retrospective filtering of runs.

| Arm | Configuration |
|-----|---------------|
| A | recall disabled — the control |
| B | recall always on |
| C | selective + typed recall (`p_min_score=0.40`, types: procedure, incident, decision) |

**Assignment.** SHA-256 of the run identifier mapped into three equal-probability
buckets. Deterministic, re-derivable from the run identifier alone, invisible to
the agent and to anyone monitoring fleet health.

**Outcome measures.** Task success as judged by the same pipeline in all three
arms; agent turns to completion; model spend per run.

### Results

| Arm | Runs | Success | Turns (mean) | Cost (mean) |
|-----|-----:|--------:|-------------:|------------:|
| A — recall off | 150 | 55.3% | 34.39 | $1.4082 |
| B — recall always on | 148 | 66.9% | 27.81 | $1.2321 |
| C — selective + typed | 137 | 55.5% | 34.49 | $1.1683 |

Pairwise success-rate comparisons, chi-square with 1 degree of freedom:

| Comparison | chi-square | p (uncorrected) | p (Bonferroni x3) |
|---|---:|---:|---:|
| A vs B | 4.186 | 0.041 | 0.122 |
| B vs C | 3.913 | 0.048 | 0.144 |
| A vs C | 0.001 | 0.981 | 1.000 |

Cost and turns, Welch's t, two-tailed: cost A vs B p=0.38; turns A vs B p=0.064;
cost B vs C p=0.70. Neither cost nor turns reaches significance in any pairing.

### What this does and does not support

Read this before quoting any number above.

- **The A-vs-B comparison was not pre-registered.** The pre-registered primary
  metric was arm C cost against arm B cost. On cost there is no effect at all.
- **The sample is short.** The pre-registered target was 400 completed runs per
  arm. We have 150, 148 and 137, and the experiment was stopped there. At the run
  volume this fleet actually produces, reaching 400 per arm would have taken about
  five more months, during which two thirds of production runs would keep being
  assigned to arms we had already measured as worse. We chose to stop and report
  an underpowered result honestly rather than buy power with degraded work.
- **No comparison survives multiple-comparison correction.** Every pairwise test
  above loses significance under Bonferroni.
- **Direction is consistent.** Arms were balanced week over week and the A-vs-B
  direction held independently in both high-volume weeks. Consistency is not
  significance, but it is why we treat this as a signal worth continuing rather
  than as noise.

The honest summary: *memory-on looks better than memory-off, at a sample too small
to prove it, on a comparison we did not pre-register — and selective recall is the
one arm we can say something firm about, because it failed.*

We do not headline a number from this experiment without the correction attached.
These figures are final: the experiment is closed, not paused, and this file will
not be quietly updated with a larger sample later.

### Reproducing it

```
cd benchmarks/mem_ab_v3
python3 analyze.py
```

`runs.csv` is a de-identified export of the real runs: one row per run, carrying
arm, week index, outcome, turns, cost, retrieved count and mean cosine. It has no
task identifiers, no role names and no project names. `analyze.py` uses the Python
standard library only and regenerates every number in this document from that file.

### Disclosure: the first version of this dataset was fabricated

The first attempt at producing `runs.csv` for this release did not export anything.
It generated the rows with a seeded random number generator, tuned so the summary
statistics matched the real ones, and shipped with a commit message stating the data
had been de-identified from real runs. A draft of this document, written at the same
time, described a retrieval study that was never run and attached to it a p-value
taken from the real fleet experiment.

None of it reached a release. It was caught in review, the dataset was replaced with a
genuine export, and this document was rewritten from that export. We are recording it
here rather than quietly correcting it, because a project whose central claim is
"measured, not asserted" does not get to hide the one time it asserted.

Two things came out of it. `G-EVIDENCE-INTEGRITY` is now a release-blocking gate: it
fails if a published benchmark directory contains a generator, if an analysis script
does not read its dataset, or if any number in this document disagrees with the script
output. And the gate itself is only accepted after it has been shown to fail against
the original incident — the first version of it reported three passes while the
generator that caused all this walked straight through.

**The dataset is an export, never a synthesis.** If a change to this directory ever
produces `runs.csv` from a random number generator instead of from real runs, this
document is void and the claim on the front of this project is false.

---

## Where we lose

Published because the alternative is asking you to trust a vendor's own scorecard.

| Benchmark | pgmnemo | Comparison | Verdict |
|---|---|---|---|
| LongMemEval-S recall@10 | 0.9604 | BM25 = 0.982 | We lose by 2.2pp |
| LoCoMo turn-level recall@5 | 0.302 | DRAGON = 0.225 | We win by 7.7pp |
| Graph-augmented recall | no measured gain | hybrid alone | Ships for lineage, not ranking |
| Selective recall, live fleet | 55.5% | no memory = 55.3% | Failed; off by default |

A plain BM25 index still beats us on raw retrieval on one of the two standard
benchmarks. If retrieval over a static corpus is your whole problem, use BM25.

Full self-assessment: [COMPETITIVE_REALITY.md](COMPETITIVE_REALITY.md).
