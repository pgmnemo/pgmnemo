# [GH-BRAINSTORM] Lens 2: Social Proof, Community Funnel, Badges, Discussions vs Competitors

**Author:** growth_lead  
**Date:** 2026-06-13  
**Scope:** GitHub presentation — social proof, Discussions/Issues, badges, star-history, 'Used by', launch/Show-HN funnel  
**Comparators:** mem0 (58.5k ★), LightRAG (36.5k ★), Letta/MemGPT (23.3k ★)  
**Status:** BRAINSTORM — for maintainer review, not yet approved for publish

---

## 0. Starting point: what pgmnemo actually has today

| Signal | Exists? | Notes |
|---|---|---|
| License badge | ✅ | Apache-2.0 |
| Version badge | ✅ | v0.8.3 |
| PGXN badge | ✅ | Linked to pgxn.org |
| CI badge | ✅ | GitHub Actions ci.yml |
| PostgreSQL badge | ✅ | PG17 |
| **LoCoMo recall@10 badge** | ✅ **UNIQUE** | 0.8409 — no competitor has this |
| **LongMemEval recall@10 badge** | ✅ **UNIQUE** | 0.9604 — no competitor has this |
| PyPI version/downloads badge | ❌ | pgmnemo-mcp is on PyPI — badge missing |
| Docker Hub pulls badge | ❌ | gaidabura/pgmnemo-mcp exists on Docker Hub — badge missing |
| Star-history chart | ❌ | Not in README |
| Discord badge | ❌ | No Discord (correct at this stage) |
| arXiv badge | ❌ | No paper yet |
| Discussions tab | ❌ | **DELIBERATELY OFF** (SUPPORT.md trigger: Show HN OR 5 merged external PRs) |
| 'Used by' section | ❌ | Not faked — correct |
| ADOPTERS.md | ❌ | Not created yet |
| good-first-issue labels/queue | ❌ | Only bug_report + iteration_proposal templates |
| COMPETITIVE_REALITY.md | ✅ **DIFFERENTIATOR** | Rare honesty in this space — trust moat |
| Agency case study (draft) | ✅ | `research/CASE_STUDY_AGENCY_2026-06-01.md` — PUBLISH-READY except one [AGENCY-REVIEW] line |

**Key observation:** pgmnemo's badge line is *richer in technical signal* than any competitor right now — the recall@K badges are genuinely unique. The gap is on *distribution signals* (PyPI, Docker) and *community readiness* (Discussions trigger not yet fired, no good-first-issues, no named public adopter).

---

## 1. Competitor social proof anatomy

### mem0 (58.5k ★) — the benchmark
**Badge line:** Discord · PyPI Downloads · commit activity · version · npm · YC S24  
**Key moves:**
- YC S24 badge is credibility-by-association — we can't replicate but shouldn't try
- Discussions: enabled, 7 categories (Announcements, General, Ideas, Knowledge Base, Polls, Q&A, Show and tell) — hundreds of threads, but **many Q&A threads unanswered** (trust liability at scale)
- No star-history chart (surprising gap)
- No "Used by" counter visible
- Comparison table: Library vs Self-Hosted vs Cloud framing (buy vs build vs rent)

**What pgmnemo can beat mem0 on:** technical transparency. mem0 doesn't show you how it works. COMPETITIVE_REALITY.md + EXPLAIN-able SQL is a counter-signal that scales with credibility, not with headcount.

### LightRAG (36.5k ★) — academic-to-OSS path
**Badge line:** CI · PyPI (lightrag-hku) · MIT · Trendshift · arXiv  
**Key moves:**
- Star-history chart in README — shows the hockey-stick trajectory. Very effective.
- Discord + WeChat group for non-English speakers
- Related ecosystem: VideoRAG, RAG-Anything, MiniRAG — signals a platform not a tool
- Chinese README alongside English — reached a big second audience
- arXiv badge legitimises the benchmarks

**What pgmnemo can learn:** star-history chart is cheap and effective. The arXiv-equivalent for pgmnemo is the benchmark transparency (COMPETITIVE_REALITY.md + BENCHMARK_PROTOCOL.md) — that's even more credible than a paper because it's reproducible.

### Letta / MemGPT (23.3k ★) — agent memory incumbent
**Badge line:** Apache-2.0 visible; no CI/PyPI visible in surface scan  
**Key moves:**
- "100+ contributors from around the world" — explicit social proof
- 177 releases (v0.16.8 in May 2026) — signals active maintenance cadence
- Discord + forum + Twitter/X/LinkedIn/YouTube — full social stack
- No Discussions tab (interesting — routes to Discord instead)

**What pgmnemo can learn:** Release velocity itself is social proof. pgmnemo is at v0.8.3 after ~6 weeks — this is fast. Surface this explicitly ("8 releases in 6 weeks" or equivalent in first community update).

---

## 2. The one existing social proof asset being under-used

**`research/CASE_STUDY_AGENCY_2026-06-01.md`** — production use at ~100k runs/week.

This is the single most valuable social proof asset the project has. It's sitting in `/research/` where no GitHub visitor sees it. Status: `PUBLISH-READY except [AGENCY-REVIEW] cost figure`.

**Action:**
1. Resolve the [AGENCY-REVIEW] cost number (or soften to "several dollars of wasted compute" if exact number isn't approved)
2. Publish to `docs/case_studies/agency.md` or `docs/WHY_AGENCY.md`
3. Add a one-line reference to it in the README — "Production case study: [why an autonomous agent fleet built on pgmnemo →](docs/case_studies/agency.md)"
4. The 100k-runs/week number is the anchor. Leads with volume + use-case, not vanity metrics.

**Effort:** 2 hours (resolve review note → move file → update README link)  
**Quick win:** YES — this is already written.

---

## 3. Badge additions (quick wins, all real)

### Immediate (< 1 hour each)

**3.1 PyPI badge for pgmnemo-mcp**
pgmnemo-mcp is published on PyPI. Add two badges above or below the existing badge row:

```markdown
[![PyPI version](https://badge.fury.io/py/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
[![PyPI downloads](https://img.shields.io/pypi/dm/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
```

Once real downloads accumulate (post-launch), the downloads badge becomes strong social proof. Before launch, version badge alone is fine — don't pre-add the downloads badge until it shows non-zero.

**3.2 Docker Hub pulls badge**
```markdown
[![Docker Pulls](https://img.shields.io/docker/pulls/gaidabura/pgmnemo-mcp.svg)](https://hub.docker.com/r/gaidabura/pgmnemo-mcp)
```

Same timing note: add after first real pulls (post-launch).

**3.3 Move benchmark badges HIGHER in README**  
Currently the LoCoMo and LongMemEval badges are in row 2 of the badge line. They are the most technically distinctive signal. Proposed badge order:

```
Row 1: License | Version | PostgreSQL | PGXN | CI (infrastructure trust)
Row 2: LoCoMo recall@10 | LongMemEval recall@10 (performance proof — unique to pgmnemo)
Row 3 (post-launch): PyPI version | PyPI downloads | Docker pulls
```

Add a one-sentence caption under row 2: `> Benchmark methodology: [docs/BENCHMARK_PROTOCOL.md](docs/BENCHMARK_PROTOCOL.md) · Honest caveats: [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md)`

This anchors the badges in reproducibility, not marketing.

### Post-launch (add after first 50 stars)

**3.4 Star-history chart**  
LightRAG uses this effectively. [star-history.com](https://star-history.com) generates a free SVG you embed in README:

```markdown
## Star History

[![Star History Chart](https://api.star-history.com/svg?repos=pgmnemo/pgmnemo&type=Date)](https://star-history.com/#pgmnemo/pgmnemo&Date)
```

At 0 stars it looks empty. Add this section **on the day of Show HN** so the chart captures the launch spike — that spike is itself social proof for the next wave of visitors.

**3.5 GitHub Topics**  
Check that the repo has GitHub Topics set. Recommended: `postgresql`, `postgres-extension`, `rag`, `agent-memory`, `pgvector`, `mcp`, `provenance`, `multiagent`  
Topics drive GitHub search discovery. Takes 2 minutes.

---

## 4. 'Used by' — honest strategy

### What GitHub's native counter is

GitHub shows "Used by N" when N public repositories list your package as a dependency (requirements.txt, pyproject.toml, package.json). For pgmnemo, this fires when:
- pip users add pgmnemo-mcp to their requirements.txt in a public repo

**DO NOT manufacture this.** It will grow organically. After Show HN, if 20 people install and 5 put it in a public repo, the counter appears automatically.

### What to do instead: ADOPTERS.md

Create `/ADOPTERS.md` with a simple format:

```markdown
# Who uses pgmnemo

If you use pgmnemo in production or in a public project, add yourself here via PR.

| Name / project | Use case | Since |
|---|---|---|
| [Agency](docs/case_studies/agency.md) | Autonomous agent fleet, ~100k runs/week | v0.3.0 |
```

Agency is row 1 — it's real, it's documented, it's not fake. "Add yourself via PR" is an invitation that converts readers into contributors. It's also a minimal contribution that lowers the PR barrier for non-code contributors.

**Effort:** 30 minutes.  
**Quick win:** YES.

### README 'Used in production by' teaser

Add one line in README introduction (after the tagline, before quickstart):

```markdown
> **In production at:** [Agency](docs/case_studies/agency.md) — autonomous agent fleet running
> ~100k tasks/week. [Add your project →](ADOPTERS.md)
```

This is honest (Agency is real), invites participation, and shows the "in production" signal without inflating it.

---

## 5. Discussions vs Issues — the existing decision is correct

**Current state (from SUPPORT.md):** Discussions OFF.  
**Trigger:** Show HN post published OR 5 external contributors with merged PRs.

**This decision is correct.** Here's why, backed by competitor evidence:

mem0 has hundreds of discussion threads with **many unanswered Q&A threads**. At their scale (58.5k stars) that's acceptable noise. At 50 stars, an unanswered thread is the first thing a potential adopter reads — and it signals abandonment. pgmnemo's approach (route everything to Issues until community can sustain responses) is the right call.

### When Show HN fires: open Discussions with 3 categories (not 7)

mem0 went to 7 categories too fast — it looks like enterprise-support-theater at small scale. Recommend 3 categories at launch:

| Category | Label | Purpose |
|---|---|---|
| 📣 Announcements | Maintainer-only | Release notes, breaking changes |
| 🙏 Q&A | Community | Install issues, usage questions (redirect from Issues `question` label) |
| 🙌 Show & Tell | Community | "I built X with pgmnemo" — converts lurkers, generates testimonials |

Add Ideas (💡) when there are 10+ Show & Tell threads. That order signals active community before you solicit feature requests.

### Issue label hygiene (do this now, before launch)

Add these missing labels to the issue tracker:
- `good first issue` — required for GitHub's first-contributor discovery
- `question` — redirect to Discussions post-launch but use Issues now
- `documentation` — separate from `docs` (GitHub's suggested label is `documentation`)
- `help wanted` — GitHub surfaces these to contributors

Current: only `bug`, `iteration-proposal`, `wg-required` labels visible from templates. That's an opaque signal for external contributors.

---

## 6. Good-first-issue queue

**Currently missing.** This is a contributor funnel blocker — developers willing to contribute can't find entry points.

### Candidate good-first-issues (file before Show HN)

| Issue title | Effort | Skill required | Why it's bounded |
|---|---|---|---|
| Add ARM64 `compat-matrix` CI job | S | GitHub Actions YAML | Well-defined — add arm64 runner target to existing matrix |
| Add PG 18 beta to aspirational compat matrix | S | GitHub Actions YAML | Add one matrix entry, continue-on-error |
| Add `pgmnemo.stats()` return type documentation to USAGE.md | S | Docs (SQL/Markdown) | Column list is in the code, needs prose |
| Improve error message when embedding dimension mismatches 1024 | M | PL/pgSQL | RAISE EXCEPTION text change, add test |
| Add Windows (WSL2) quickstart note to INSTALL.md | S | Docs | Research + 10 lines |
| Create `Makefile` shortcut for `make bench-locomo` | S | Makefile | Wraps existing bench runner |

Label all with `good first issue` + `help wanted`. For each, write a 3-paragraph description: (1) current behavior / gap, (2) what done looks like, (3) pointers to relevant files. Vague good-first-issues get no takers.

**Effort:** 1 hour to file 4-6 issues with proper descriptions.  
**Quick win:** YES — this directly feeds the "5 external contributors" trigger for Discussions.

---

## 7. Star path — T0 to T+90

### The honest trajectory

| Phase | Target | Primary levers | Social proof added |
|---|---|---|---|
| T0: Show HN day | 0 → 50 | Show HN post + first comment + direct emails to ~15 developers | star-history chart starts (captures launch spike) |
| T+7 | 50 → 100 | dev.to post + r/PostgreSQL cross-post + r/LocalLLaMA | enable Discussions; add Downloads + Docker badges |
| T+30 | 100 → 250 | Agency case study publish; first good-first-issue closed by external contributor | ADOPTERS.md row 2 if any new adopter |
| T+90 | 250 → 500 | PgConf CFP acceptance signal; second case study or benchmark update | Star history shows slope |

### "First 100 stars" mechanics

**Before Show HN:**
1. Resolve CASE_STUDY [AGENCY-REVIEW] line → publish → add README link
2. Create ADOPTERS.md with Agency as row 1
3. File 4-6 good-first-issues with proper labels
4. Add PyPI version badge (not downloads yet)
5. Set GitHub Topics (2 min)
6. Prepare star-history embed — add on the morning of HN post

**Show HN post:**
- Title formula: `Show HN: pgmnemo – PostgreSQL extension for agent memory (provenance gate, recall@10=0.96)`
- First comment (maintainer, post immediately): 3 paragraphs — why it exists, what's honest about the benchmarks (link COMPETITIVE_REALITY.md), what help is needed. Do NOT pitch.
- Timing: Tuesday 9am ET

**First comment template (write before T0):**
```
pgmnemo is what we built when [Agency's] agent fleet needed memory that accumulated across thousands of runs. The problem was specific: hallucinated memories silently poisoned recall. The provenance gate (DB-level constraint) blocks untracked writes — not optional, not a linter, a Postgres constraint.

Honest numbers: our LoCoMo headline (0.84) is over a 22x smaller search space than the paper's baseline; we lose to a 50-LOC BM25 script on LongMemEval-S. We wrote COMPETITIVE_REALITY.md before this HN post because we'd rather you know this now than file an angry issue later.

We're pre-community (no Discord, Discussions deliberately off until 5 external contributors). What actually helps right now: try the 3-command quickstart and tell us what broke.
```

This first comment is the most important post-submission action. It establishes intellectual honesty as a brand attribute, preempts "but your benchmarks are misleading" attacks, and gives the HN crowd something specific to engage with.

---

## 8. Comparison vs competitors: what to add to README

The existing README comparison table covers the right dimensions (single-plan recall, zero egress, EXPLAIN-able ranking, $0 LLM write, provenance, install model, price). It's technically accurate.

**Gaps vs what visitors actually want to know:**

### Gap 1: No direct mem0/Letta comparison
Add a second table or section:

```markdown
## How pgmnemo differs from memory libraries

| | pgmnemo | mem0 | Letta |
|---|---|---|---|
| Where memory lives | Your Postgres | External API / self-hosted | Letta server |
| Write cost | $0 (SQL INSERT) | ~$0.17-$0.36 / 1K (LLM extraction) | API call to Letta |
| Provenance gate | ✅ DB constraint | ❌ | ❌ |
| Outcome-learning | ✅ `reinforce()` SQL | ❌ | Partial (MemGPT score) |
| EXPLAIN-able | ✅ Full query plan | ❌ opaque | ❌ opaque |
| Install | `CREATE EXTENSION` | `pip install` + API key | `pip install letta-client` |
| Backup | `pg_dump` | vendor backup | vendor backup |
```

Add footnote: `This table reflects pgmnemo's understanding of the other projects as of June 2026. We welcome corrections via PR.` — this is honest AND invites engagement.

### Gap 2: POSITIONING_LEAD_WITH_OUTCOME_LEARNING.md recommendation is buried

The positioning document (`research/POSITIONING_LEAD_WITH_OUTCOME_LEARNING.md`) contains the strongest single-line pitch: *"agent memory that learns which lessons actually worked — and lets you read why in plain SQL."*

This line is not in the README. It should be. Proposed placement: tagline subheading between the repository header and the badges.

Current:
```
# pgmnemo
**In-your-Postgres agent memory — single-plan multimodal recall, token-budget navigation, provenance-gated writes.**
```

Proposed revision:
```
# pgmnemo
**Agent memory that learns which lessons worked — inspectable in plain SQL, no new service.**

*In-your-Postgres: single-plan multimodal recall, outcome-learning, provenance gate, token-budget navigation.*
```

The first line is the emotional hook. The second is the technical specification for people who want to know more.

---

## 9. Summary: prioritised action list

### P0 — before Show HN (total: ~6 hours)

| # | Action | Effort | What it unlocks |
|---|---|---|---|
| 1 | Resolve [AGENCY-REVIEW] → publish case study → add README link | 1h | Named production user — primary social proof |
| 2 | Create ADOPTERS.md with Agency row 1 | 30m | Invitation for community to self-nominate |
| 3 | Revise README tagline to lead with outcome-learning | 30m | Stronger hook for HN/Reddit visitors |
| 4 | Add PyPI version badge for pgmnemo-mcp | 15m | Distribution signal (real — published) |
| 5 | Set GitHub Topics (postgresql, rag, agent-memory, pgvector, mcp, provenance, multiagent) | 10m | Search discovery |
| 6 | File 4-6 good-first-issues with proper descriptions + labels | 1h | Feeds 5-external-contributor trigger for Discussions |
| 7 | Add mem0/Letta comparison table to README | 45m | Captures "how does this compare" search intent |
| 8 | Prepare Show HN first comment (write offline, post immediately after submission) | 45m | Shapes the HN narrative before anyone else does |
| 9 | Add star-history embed code (but add the section empty — or don't add until launch morning) | 15m | Captures launch spike |

### P1 — on Show HN day

| # | Action | When | Notes |
|---|---|---|---|
| 10 | Enable Discussions with 3 categories | T0 post-submission | Show HN post is the trigger |
| 11 | Add star-history chart section | T0 morning | Charts the spike |
| 12 | Add Docker pulls + PyPI downloads badges | T0 if any downloads exist | Don't show 0 |

### P2 — T+7 to T+30

| # | Action | Trigger |
|---|---|---|
| 13 | Publish Agency case study to pgmnemo.dev / docs site | T+7 |
| 14 | First good-first-issue closed by external contributor → announce in Discussions Show & Tell | When it happens |
| 15 | Add Ideas Discussions category | When 10+ Show & Tell threads exist |

---

## 10. What NOT to do

- **No fake 'Used by' section.** GitHub's counter is automatic from real pip/pgxn installs. Don't add a "Companies using pgmnemo" section with only Agency listed under a corporate logo — it reads as self-promotion theater.
- **No Discord before Discussions.** Discord at 0 community creates a ghost channel that signals failure. Discussions-first is cheaper to moderate and stays visible in GitHub search.
- **No inflated benchmark framing.** COMPETITIVE_REALITY.md is the strongest trust signal the project has. Any badge or claim that contradicts it burns that asset.
- **No "we're the fastest/best" claims** unless benchmarked against a specific competitor on the same protocol. The README already handles this correctly with the honest comparison.
- **Don't open all 7 Discussions categories at once.** mem0 did; many are ghost categories. 3 is the right starting number.

---

## Appendix A: Competitor badge line comparison

| Project | Stars | CI | Version | License | Discord | PyPI/npm | Benchmark | arXiv | Star-history |
|---|---|---|---|---|---|---|---|---|---|
| mem0 | 58.5k | ❌ (not visible) | ✅ | ❌ | ✅ | ✅ downloads | ❌ | ❌ | ❌ |
| LightRAG | 36.5k | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ | ✅ | ✅ |
| Letta | 23.3k | ❌ (not visible) | ❌ | ✅ | ✅ (link) | ✅ | ❌ | ❌ | ❌ |
| **pgmnemo** | **0 (pre-launch)** | ✅ | ✅ | ✅ | ❌ | ✅ (missing badge) | ✅ **UNIQUE** | ❌ | ❌ |

pgmnemo's benchmark badges are genuinely differentiating. No competitor exposes live recall@K metrics in their badge line. This is the thing to protect and amplify — not copy competitor badge patterns, but build on the one thing only pgmnemo has.

---

*End of brainstorm document. Not approved for external publication without maintainer review.*
