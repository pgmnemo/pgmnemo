# Evidence

pgmnemo claims to be measured rather than asserted. This file is where that claim
is cashed. It describes the one controlled experiment we have run, publishes the
result that went against us first, and links the data and the script so every
number can be checked without taking our word for anything.

GUC defaults and the evidence behind each one are audited separately in
[GUC_EVIDENCE.md](GUC_EVIDENCE.md).

**Read this first.** The first experiment below (about 300 runs in the two arms it
compared) suggested that injecting memory helps. A second experiment on about seven
times as many runs did not confirm it: the two arms completed the same share of
runs. The current picture is in [A second, larger experiment](#a-second-larger-experiment);
the first experiment's text and numbers are left exactly as published.

---

## The finding that cost us a quarter

**Selective recall performed as if there were no memory at all.**

We built score-gated, type-filtered recall on the premise that a memory which
knows when to stay quiet beats one that always speaks. Measured against a control
arm with recall switched off entirely, the selective arm was statistically
indistinguishable from having no memory: 55.5% task success against 55.3%,
chi-square 0.001, p=0.98. Plain always-on recall beat it (p=0.048 uncorrected).

It is worth being precise about *why*, because the obvious explanation is wrong.
Arm C did not starve the agent of context: it injected **more** lessons per run than
arm B (4.05 against 3.29 on average), with the same rate of runs that retrieved
nothing (12.4% against 12.2%), at essentially the same match quality (mean cosine 0.561 against 0.570). More
retrieved context, and no benefit.

What actually separates the two arms is the retrieval mechanism, not the amount. Arm B
used the hybrid path — vector plus BM25, no score threshold, no type filter. Arm C used
vector-only recall with a 0.40 cosine gate and a type filter. On this evidence the lever
is *how* memory is retrieved, not how much of it is handed over; a vector-only path with
quality gates returned more material that helped less.

> **Correction, 2026-10-29 (the text above is unchanged).** The sentence "Arm B used the
> hybrid path" names the wrong mechanism. Arm B did not call pgmnemo's `recall_hybrid()`.
> The application that hosts pgmnemo has retrieved lessons since 2026-06-03 with its own
> two-phase query against the lesson table: an HNSW vector query and a full-text (BM25)
> query, fused by reciprocal rank in application code. Calling `recall_hybrid()` is an
> opt-in environment flag. Arm C did call a pgmnemo function,
> `recall_fast()`, which is vector-only; and when its gated query returned nothing, the
> run fell back to arm B's retrieval instead of receiving no lessons. So the A-versus-B
> result is evidence about that application-level vector-plus-BM25 query, not about
> `recall_hybrid()`, and "arm C versus arm B" compares a gated native call (with fallback)
> against the application query. The measured numbers are unchanged; what they are
> evidence *about* is narrower than the paragraph above says. Calling `recall_hybrid()`
> is off by default and is not set in the deployment configuration we can inspect, but
> the setting was not recorded per run, so "off throughout" rests on that configuration
> and the code history, not on a per-run log.

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

## A second, larger experiment

The first experiment ended with a signal we could not prove. We ran a second one to
find out whether it was real. It was not pre-registered, it was not designed to answer
this question cleanly, and its result is a null: on about seven times as many runs, the
effect did not confirm.

**What it measures.** Whether putting retrieved lessons into an agent's prompt changes
the share of runs that complete. Not whether the retriever ranks the right row.

**Design.** Two arms, assigned per agent run, on the same production fleet, from
2026-08-13 until the experiment's switch was turned off on 2026-10-29 at 19:10 UTC.
Every terminal run (completed, failed or escalated) that started in that window is in
the data, except 18 runs from the first day that were still governed by the first
experiment's switch and so were never randomised here.

| Arm | Configuration |
|-----|---------------|
| treat | retrieved lessons are put into the agent's prompt |
| control | lessons are retrieved but **not** put into the prompt |

**Control is not "no memory".** Retrieval is computed in both arms and its result is
recorded, and during a run the agent can still search memory and write to it in both
arms. What differs is only whether the lessons found at dispatch are placed in the
prompt up front. The comparison is *injected memory versus no injected memory*. An
agent in the control arm that searches for itself is partly treated, which pushes any
real effect toward zero; the data do not say how often that happened.

**Assignment.** SHA-256 of the run identifier, mapped into two equal buckets.
Deterministic and re-derivable from the run identifier alone. The unit is the run, not
the task: a task retried after a failure can have runs in both arms, so runs are not
independent and the intervals below are somewhat too narrow by an amount we cannot
estimate from the export.

**Outcome.** A run counts as a success if it completed. The same pipeline judged all
runs, in both arms. Cost and turns per run are secondary.

### Results

| Arm | Runs | Completed | Cost per run (mean) | Turns (mean) |
|-----|-----:|----------:|--------------------:|-------------:|
| treat | 1046 | 63.0% | $2.039 | 41.281 |
| control | 1021 | 62.9% | $2.200 | 47.513 |

| Comparison | Difference | 95% CI | z | p | Cohen's h |
|---|---:|---:|---:|---:|---:|
| Completed, all terminal runs | +0.1 pp | [-4.0, +4.3] | 0.06 | 0.954 | 0.003 |
| Completed, excluding infrastructure faults | +1.2 pp | [-2.4, +4.9] | 0.65 | 0.514 | 0.033 |

Excluding infrastructure faults leaves 84.5% (780 runs) against 83.3% (771 runs). A
quarter of all runs ended on an infrastructure fault (25.4% in treat, 24.5% in control,
no detectable difference between arms, p=0.620), which is why that second row exists.
It conditions on an outcome that happens after assignment and was added after we had
seen the data, so it is a sensitivity analysis and not the headline. The faults it removes include
cost-ceiling stops and restart sweeps, which memory could in principle influence.

Cost and turns, Welch's t, two-tailed: cost per run differs by -0.161 dollars
(95% CI -0.420 to +0.097, p=0.222); turns by -6.232 (95% CI -13.396 to +0.932,
p=0.088). Cost per completed run is $3.091 in treat and $3.399 in control. Neither
reaches significance. The direction favours treat, and that is all it is.

**Did the arms differ in what the agent saw?** Once agents were asked to list which
injected lessons they used, the final report of 489 of 955 treat runs (51.2%) carried
that line, against 2 of 955 control runs (0.2%). So injection did differ by arm. That
request only began in the second week of the window: in week 0 (157 runs, 7.6% of the
sample) neither arm shows the line and the export cannot confirm what the prompts
contained. Dropping week 0 changes nothing: +0.2 pp, 95% CI [-4.1, +4.5], p=0.924.

**Minimum detectable effect.** With these sample sizes, an effect of 6.0 percentage
points on the completion share would be detected 80% of the time at the 5% level
(5.2 points once infrastructure faults are removed). The estimate cannot rule out a
true effect of a few points, and it could not have seen one.

### What this does and does not support

Read this before quoting any number above.

- **It was not pre-registered.** No primary metric, sample size or stopping rule was
  fixed before the data were read. The completion share is the metric the first
  experiment reported, and we use it for the same reason; that is a choice made with
  hindsight, not a registered analysis. The switch was turned off when the decision to
  stop was taken, not at a planned sample size.
- **Control is not "no memory".** See above. The experiment tests the value of putting
  lessons in the prompt at dispatch, with search and write still available.
- **The sample is concentrated in time.** Half of the runs (1034, 50.0%) fall in two
  consecutive weeks, 17 to 30 September (weeks 5 and 6), and one of them holds 30.2% of
  the sample. Completion in week 5 was low in both arms (46.2% in treat, 51.6% in
  control, a difference of -5.4 pp, p=0.173) and high in week 6. The effect by week
  is not stable, and a pooled number is dominated by a few weeks. Without week 5 the
  difference is +2.3 pp (95% CI [-2.5, +7.1], p=0.340). Stratifying by week, the
  Mantel-Haenszel difference is +0.6 pp (p=0.763). None of these is distinguishable
  from zero, and none is a finding.
- **The treatment was not constant.** From 2026-08-20 the injected text asked the agent
  to report which lessons it used. Before that it did not.
- **A null on this sample is not a refutation.** The first experiment's point estimate
  of +11.6 pp lies outside this experiment's interval, so a true effect that large is
  unlikely under this design. An effect of one to four points is compatible with both
  experiments, and this design cannot detect effects below about 6 points.

**Pooling with the first experiment.** Combining the first experiment (always-on versus
recall off: 66.9% against 55.3%, +11.6 pp, 95% CI [+0.6, +22.5], p=0.041) with this one
by inverse-variance weighting gives +1.6 pp, 95% CI [-2.3, +5.5], p=0.433. The two
differences disagree by 11.4 pp (z=1.91, p=0.056), so a single common effect is not a
comfortable summary, and the pooled figure should not be read as an estimate of one.
The contrasts also differ: the first experiment's control had recall switched off, this
one's did not.

The honest summary: *on about seven times as many runs, the effect of injecting memory
on completion did not confirm. The point estimate is zero, the interval runs from a
small loss to a small gain, and the design could not see anything under about six
points. We withdraw nothing from the first experiment, and we no longer read it as
evidence that injected memory raises the completion rate.*

This section follows the same rule as the first: the experiment is closed, and these
figures will not be quietly updated.

### Reproducing it

```
cd benchmarks/mem_ab_v2
python3 analyze.py
```

`runs.csv` is a de-identified export of the real runs: one row per run, carrying arm,
week index (counted from 2026-08-13), outcome, an infrastructure-fault flag, turns,
cost, retrieved count and whether the final report carries the lesson-usage line. It
has no task identifiers, no role names, no project names and no failure classes. The
export is a single read-only query over terminal runs that started in the window. The
file's SHA-256 is `d744b0c2a2a6835011ad500b81e2c8e525ef49209c89294380dce5896f47806c`.
`analyze.py` uses the Python standard library only and regenerates every number in this
section from that file, and from the first experiment's `runs.csv` for the pooled figure.

The export carries `run_id` and `analyze.py` re-derives every row's arm from it with the
assignment rule, and stops if any row disagrees (none does). The run identifiers are
opaque integers from the fleet's run table.

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
