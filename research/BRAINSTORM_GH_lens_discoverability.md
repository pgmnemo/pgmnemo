# BRAINSTORM: GitHub Presentation — Lenses 1 + 4
## Discoverability, README Hero, Docs-Site, Examples, Quickstart vs Competitors

**Date:** 2026-06-13  
**Author:** literature_scout (facilitation brief: BRAINSTORM_GITHUB_PRESENTATION_2026-06-13)  
**Scope:** Lenses 1 (discoverability / README hero / visuals / OG / quickstart) + 4 (docs-site, copy-paste quickstart, reinforce→ranking-flip demo, examples dir, benchmark presentation)  
**Repos analysed:** mem0ai/mem0 (58.5k ⭐), HKUDS/LightRAG (36.5k ⭐), getzep/graphiti (27.4k ⭐)  
**Constraint:** No fake social proof; moat-safe; honest.

---

## 1. Competitor Teardown — Above-the-Fold Inventory

### 1.1 mem0ai/mem0 — "The Memory Layer for Personalized AI"

| Element | Present | Detail |
|---|---|---|
| Logo / hero image | ✅ | Mem0 banner logo, color-branded |
| Animated GIF | ❌ | — |
| Architecture diagram | ❌ | — (Python SDK; architecture is in docs) |
| Hero tagline | ✅ | **"The Memory Layer for Personalized AI"** — benefit-first |
| Star count badge | ✅ | 58.5k |
| Download badge | ✅ | PyPI monthly downloads (prominently shown) |
| Community badge | ✅ | Discord (large purple badge) |
| Institutional credibility | ✅ | Y Combinator S24 badge |
| Trending badge | ✅ | Trendshift ranking |
| New feature announcement | ✅ | "New Memory Algorithm (April 2026)" with before/after benchmarks (LoCoMo 71.4→91.6, LongMemEval 67.8→94.8) — PROMINENT |
| Quickstart (copy-paste) | ✅ | **4 commands**: `npm install -g @mem0/cli` → `mem0 init` → `mem0 add` → `mem0 search` |
| Dedicated docs site | ✅ | docs.mem0.ai — Mintlify, landing page with 6-card grid |
| SDK breadth | ✅ | Python + JS/TypeScript |
| Changelog noise above fold | ✅ | None — changelog is not surfaced in README hero |

**First impression:** Logo → tagline → social proof badges → new algorithm announcement → 4-command quickstart. Professional, benefit-forward, immediately actionable.

---

### 1.2 HKUDS/LightRAG — "Simple and Fast Retrieval-Augmented Generation"

| Element | Present | Detail |
|---|---|---|
| Logo / hero image | ✅ | Large stylized graph logo |
| Animated GIF | ✅ | Demo GIF showing system in action |
| Architecture diagram | ✅ | Dual-level retrieval diagram visible above fold |
| Hero tagline | ✅ | "🚀 LightRAG: Simple and Fast RAG" — benefit-first, has emoji |
| Star count badge | ✅ | 36.5k stars prominently badged |
| Download badge | ✅ | PyPI downloads |
| Community badge | ✅ | Discord + WeChat (dual community) |
| Institutional credibility | ✅ | arXiv paper badge (2410.05779) — peer-reviewed credibility |
| Trending badge | ✅ | Trendshift |
| News section | ✅ | Prominent "News" block with dated feature updates |
| Quickstart | ✅ | `uv tool install "lightrag-hku[api]"` — single command |
| Dedicated docs site | ⚠️ | GitHub-hosted docs, not separate domain |
| Changelog noise above fold | ✅ | None — changelog not in hero |

**First impression:** Logo + GIF + architecture diagram → 12 badges → news section → 1-command install. Densely visual, research-credentialed.

---

### 1.3 getzep/graphiti — "Build Temporal Context Graphs for AI Agents"

| Element | Present | Detail |
|---|---|---|
| Logo / hero image | ✅ | Zep logo with brand color |
| Animated GIF | ✅ | **Two GIFs**: temporal walkthrough + structured/unstructured demo |
| Architecture diagram | ❌ | — (in docs instead) |
| Hero tagline | ✅ | **"Build Temporal Context Graphs for AI Agents"** — action-verb, audience-aware |
| Star count badge | ✅ | 27.4k |
| Community badge | ✅ | Discord badge |
| Institutional credibility | ✅ | arXiv paper badge (2501.13956) |
| Trending badge | ✅ | Trendshift |
| Company backing signal | ✅ | "We're Hiring!" + Zep brand = not a side project |
| Quickstart | ✅ | `pip install graphiti-core` — 1 command; full quickstart in `examples/quickstart/README.md` |
| Dedicated docs site | ✅ | help.getzep.com/graphiti — structured navigation |
| Changelog noise above fold | ✅ | None |

**First impression:** Logo → tagline → 8 badges → 2 GIFs showing real behavior → company backing. Credible, visually communicates what it does.

---

## 2. pgmnemo README — Honest Assessment

### 2.1 What pgmnemo does above the fold

Reading the current README top-to-bottom, a first-time visitor encounters in order:

1. `# pgmnemo` (no logo/image)
2. Tagline (bold, technical): *"In-your-Postgres agent memory — single-plan multimodal recall, token-budget navigation, provenance-gated writes."*
3. 7 badges: License, Version, PGXN, CI, PostgreSQL version, LoCoMo recall@10, LongMemEval recall@10
4. **8 consecutive `> v0.x.x (date):` changelog blockquotes** — v0.7.2, v0.7.1, v0.6.3, v0.6.1, v0.6.0, v0.5.2.post1, v0.5.2, v0.5.1, v0.8.0 — **before any value proposition**
5. Benchmark table with methodology notes
6. Self-defeating caveat block: *"The 'we beat everyone' framing is wrong…"*
7. "Why this exists" section (good content, buried)

### 2.2 Gap table vs competitors

| Gap | mem0 | LightRAG | graphiti | pgmnemo |
|---|---|---|---|---|
| Hero logo/image | ✅ | ✅ | ✅ | ❌ |
| Animated GIF demo | ❌ | ✅ | ✅ (×2) | ❌ |
| Architecture diagram in README | ❌ | ✅ | ❌ | ❌ |
| Benefit-first tagline | ✅ | ✅ | ✅ | ⚠️ (implementation-first) |
| Star count badge | ✅ | ✅ | ✅ | ❌ |
| Download / adoption badge | ✅ | ✅ | ❌ | ❌ (PGXN badge present but obscure) |
| Community (Discord) badge | ✅ | ✅ | ✅ | ❌ |
| arXiv / paper credibility badge | ❌ | ✅ | ✅ | ❌ (ICSE-SEIP in prep, not citable yet) |
| Trending badge | ✅ | ✅ | ✅ | ❌ |
| Changelog noise before value prop | ❌ | ❌ | ❌ | ✅ (8 blockquotes!) |
| Copy-paste 1–3 command quickstart | ✅ | ✅ | ✅ | ❌ (4+ Docker commands) |
| Python-native quickstart (no psql) | ✅ | ✅ | ✅ | ❌ (MCP exists, no Python example) |
| Dedicated docs site | ✅ | ⚠️ | ✅ | ❌ |
| New feature announcement section | ✅ | ✅ | ❌ | ❌ (buried in changelog) |

---

## 3. Lens 1 — Discoverability / README Hero / Visuals / OG / Quickstart

### PROBLEM 1 — Changelog blockquotes dominate the hero (CRITICAL)
**What's happening:** 8 version-specific `>` blockquotes appear immediately after the badges. Every competitor puts changelog in a separate CHANGELOG.md or a collapsed `<details>` block. The current README forces a first-time visitor to scroll through ~80 lines of version notes before reaching "Why this exists."

**Concrete fix:**  
```markdown
<!-- REPLACE current 8 blockquotes with single collapsed block: -->
<details>
<summary>Recent releases (v0.8.0 → v0.8.3)</summary>

**v0.8.3 (latest):** Token-economy navigation API...
[Full history →](CHANGELOG.md)
</details>
```
Or: delete all but the most recent one, link to CHANGELOG.md.

**Effort:** S (30 min) | **Quick win: ✅ YES — highest ROI item**

---

### PROBLEM 2 — No hero logo / brand image
**What's happening:** Pure `# pgmnemo` text header. Every competitor has a branded banner image at `docs/img/` or equivalent.

**Concrete fix:** Create a 1200×300px banner (`docs/img/pgmnemo-banner.png`) showing the pgmnemo name + the core concept visually (e.g., a PostgreSQL elephant icon + "memory graph" lines + "EXPLAIN-able" callout). Reference it in README:
```markdown
<p align="center">
  <img src="docs/img/pgmnemo-banner.png" alt="pgmnemo — in-Postgres agent memory" width="800"/>
</p>
```
This also becomes the GitHub social preview (OG image) — set it in repo Settings → Social preview.

**Effort:** M (½ day for design, 15 min to wire up) | **Quick win: ✅ (if design is fast)**

---

### PROBLEM 3 — Tagline is implementation-first, not benefit-first
**Current:** *"In-your-Postgres agent memory — single-plan multimodal recall, token-budget navigation, provenance-gated writes."*  
**Problem:** Tells you the mechanism before the benefit. A developer landing from GitHub search doesn't know if this solves their problem.

**Concrete fix (one line change):**
```markdown
**Persistent agent memory that lives in your Postgres. Zero new infrastructure, zero LLM cost per write, EXPLAIN-able recall.**
```
Or more pointed:
```markdown
**Add durable memory to any AI agent — using the Postgres you already run. No new service. $0/write.**
```
Keep the technical subtitle for the detail line below.

**Effort:** S (15 min) | **Quick win: ✅**

---

### PROBLEM 4 — No star count badge (missing easy social proof)
**Note:** Stars will be low relative to mem0/LightRAG/graphiti early on. Don't fake it. But not showing them looks worse than showing a real number.

**Concrete fix:** Add a GitHub stars badge (shows real number, authentic):
```markdown
[![GitHub Stars](https://img.shields.io/github/stars/pgmnemo/pgmnemo?style=social)](https://github.com/pgmnemo/pgmnemo)
```
If under 500 stars: optionally omit until organic growth reaches a threshold worth showing. Decision point: >500 → add it. **Do not add fake star counts or use purchased stars.**

**Effort:** S (5 min) | **Quick win: ✅ (once organic stars warrant it)**

---

### PROBLEM 5 — No community/contact badge
**Problem:** No Discord, no Discussions badge, no way to signal "there are humans behind this who answer questions."

**Concrete fix (moat-safe, honest):** Enable GitHub Discussions on the repo (free). Add badge:
```markdown
[![GitHub Discussions](https://img.shields.io/github/discussions/pgmnemo/pgmnemo)](https://github.com/pgmnemo/pgmnemo/discussions)
```
If Discord is created: add Discord badge. If not: GitHub Discussions is sufficient and zero-cost.

**Effort:** S (10 min) | **Quick win: ✅**

---

### PROBLEM 6 — Quickstart is NOT "30 seconds"
**Current quickstart is actually:**
1. `docker run` (30s+ download)
2. `curl -L` (download zip)
3. `docker cp` (file copy)
4. `docker exec bash -c ...` (file extraction)
5. `psql` session with SQL
6. Embedding must be provided as `array_fill(0, ARRAY[1024])::vector(1024)` — this is a dummy that produces meaningless recall

**Competitor baseline:** `pip install mem0ai` (1 command), `pip install graphiti-core` (1 command), `uv tool install "lightrag-hku[api]"` (1 command).

**pgmnemo genuine constraint:** It's a Postgres extension, not a Python package. The install WILL be longer. But the current quickstart undersells the MCP path.

**Concrete fix — add a Python MCP quickstart FIRST:**
```markdown
## Quickstart (Python via MCP)

The fastest path — no Postgres setup required if you already have one:

\```bash
pip install pgmnemo-mcp
export DATABASE_URL=postgresql://localhost/mydb
pgmnemo-mcp --smoke   # verifies DB connection
\```

Then in your agent code:
\```python
import subprocess, json

# Store a memory
result = subprocess.run(
    ["pgmnemo-mcp", "ingest", "--text", "Rotate JWT secrets after key compromise"],
    capture_output=True
)

# Recall
result = subprocess.run(
    ["pgmnemo-mcp", "recall", "--query", "JWT security"],
    capture_output=True
)
print(json.loads(result.stdout))
\```
```

Or: show the Claude Desktop / Cursor MCP config JSON (already in README but buried) as the "quickstart" — it's already copy-paste.

**Better still:** Create `examples/quickstart_python.py` — a ~30-line script using `psycopg2` + `pgmnemo` directly. The `psycopg2` path is copy-paste if they have a Postgres.

**Effort:** M (2-3h to write + test example) | **Quick win: ✅ partial (MCP config is already there)**

---

### PROBLEM 7 — No animated GIF showing recall/reinforce behavior
**What's missing:** All visual-learner developers who scroll GitHub want to see "does this do what it says." A 15-second GIF showing:
1. `ingest()` a lesson → `recall()` it → it appears
2. `reinforce(id, 'success')` × 3 → `recall()` again → it moves to rank #1

This is the single most differentiating feature (outcome-learning → ranking flip) and it has zero visual representation.

**Concrete fix:** Record a terminal GIF using `asciinema` or `vhs` (free CLI tool):
```bash
# 15 commands, 30 seconds of demo
# stores 3 memories → recalls → reinforces winner → recalls again → winner is now first
```
Host at `docs/img/reinforce-demo.gif`, embed in README.

**Effort:** M (2-3h) | **Quick win: ✅ for engagement**

---

### PROBLEM 8 — No GitHub social preview (OG image)
**What's happening:** GitHub uses repo name as the social card when shared on Twitter/LinkedIn/Slack. Competitors with logos have branded previews.

**Fix:** Upload a 1280×640px image to repo Settings → Social preview. Can reuse the banner from Problem 2.

**Effort:** S (15 min after banner exists) | **Quick win: ✅**

---

## 4. Lens 4 — Docs-Site, Copy-Paste Quickstart, Examples Dir, Benchmark Presentation

### PROBLEM 9 — No dedicated docs site
**Competitors:** mem0 → docs.mem0.ai (Mintlify), graphiti → help.getzep.com (Mintlify/custom).  
**pgmnemo:** Markdown files in repo. No site, no search, no navigation.

**Options ranked by effort:**

| Option | Effort | Result |
|---|---|---|
| GitHub Pages with mkdocs-material | M (1 day) | Free, auto-deploys, full search, versioned |
| Mintlify (mintlify.com) | M-L (2-3 days) | Slick, mem0-quality, free tier |
| Docusaurus + GitHub Pages | L (3-5 days) | Most flexible, heavier setup |
| Status quo (Markdown in repo) | S (0) | No search, no navigation, no landing page |

**Concrete recommendation:** MkDocs-Material + GitHub Pages. Config is 50 lines of YAML. Auto-deploys on push. Supports search, code copy buttons, versioning via mike. Maps directly to existing `docs/` directory structure. Cost: $0.

```yaml
# mkdocs.yml (skeleton)
site_name: pgmnemo
theme:
  name: material
  palette:
    scheme: slate
nav:
  - Home: README.md
  - Install: INSTALL.md
  - Usage: docs/USAGE.md
  - Benchmarks: docs/BENCHMARKS.md
  - Examples: examples/
  - API Reference: docs/SQL_REFERENCE.md
```

**Effort:** M (1 day) | **Quick win: ✅ relative to Mintlify**

---

### PROBLEM 10 — Examples directory is nearly empty
**Current state:** `examples/` contains:
- `README.md` (docker-compose intro)
- `docker-compose.yml`
- `init/01_pgmnemo_install.sh`
- `migrate_external_memory.sql`

**No examples for:** Python MCP usage, reinforce→ranking-flip, token-budget navigation, provenance gate enforcement, LangChain integration, multi-role scoping, bitemporal point-in-time recall.

**Concrete additions needed (prioritized):**

#### P0 — `examples/01_reinforce_ranking_flip.py` (the killer demo)
The single most unique feature. Script should:
1. Ingest 5 lessons on "authentication"
2. `recall('authentication')` → show ranked list, note lesson A is at rank 3
3. `reinforce(A, 'success')` × 3
4. `recall('authentication')` again → lesson A is now rank 1
5. Print confidence delta before/after

This is the **only** feature pgmnemo has that none of the competitors have — database-native outcome-learning that visibly affects recall ranking. It needs a runnable demo.

**Effort:** S-M (2-4h to write + test) | **Quick win: ✅ critical**

#### P1 — `examples/02_mcp_quickstart.py`
30-line Python script using psycopg2 directly. Assumes existing Postgres + pgvector. Shows ingest → recall in pure Python. No Docker required if they have a Postgres already.

**Effort:** S (1-2h) | **Quick win: ✅**

#### P2 — `examples/03_token_budget_navigate.py`
Demonstrates `navigate_locate()` + `navigate_expand()` — the other unique feature. Shows cost difference: full recall vs locate-then-expand on a corpus of 100 lessons.

**Effort:** S-M (2-3h) | **Quick win: ⚠️ (requires corpus setup)**

#### P3 — `examples/04_provenance_gate.py`
Shows enforcement: `gate_strict = 'enforce'` → attempt write without commit_sha → exception caught → write with commit_sha → succeeds.

**Effort:** S (1h) | **Quick win: ✅**

#### P4 — `examples/05_langchain_integration.py`
Exists in `integrations/langchain/` but not in examples/. Copy or symlink a runnable quickstart.

**Effort:** S (30 min if integrations/langchain already works) | **Quick win: ✅**

---

### PROBLEM 11 — Benchmark presentation is self-defeating in the README hero
**Current README benchmark section order:**
1. Benchmark table
2. `> **Read this before the numbers below:** [COMPETITIVE_REALITY.md]...`
3. Table with honest comparisons
4. `> **The "we beat everyone" framing is wrong.** Our headline session-level LoCoMo number compares to a 22× smaller search space...`

**Problem:** The caveat block "The 'we beat everyone' framing is wrong" appears INSIDE the README body, not just in COMPETITIVE_REALITY.md. This is the right instinct (honesty) but the wrong execution. It reads as the project undermining itself.

**Concrete fix:** Restructure the benchmark section to lead with what pgmnemo ACTUALLY shows, then one sentence linking to full methodology:

```markdown
## Benchmarks (v0.8.0)

| Benchmark | pgmnemo recall@10 | Baseline | Delta |
|---|---|---|---|
| LoCoMo (turn-level, paper-canonical) | 0.302 | DRAGON 0.225 | **+7.7pp** |
| LongMemEval-S (retrieval-only) | 0.9604 | BM25 0.982 | −2.2pp |

Methodology, search-space caveats, and apples-to-apples comparisons vs Mem0/Zep: [docs/COMPETITIVE_REALITY.md](docs/COMPETITIVE_REALITY.md).  
**Reproduce:** `make bench` (see [docs/BENCHMARKS.md](docs/BENCHMARKS.md)).
```

Keep the detailed honest caveats in COMPETITIVE_REALITY.md (already there). The README gets the table + 2 lines. A developer who cares about methodology will click through; a developer doing a 5-second scan doesn't get scared off.

**Effort:** S (30 min) | **Quick win: ✅**

---

### PROBLEM 12 — Benchmark presentation doesn't show the reinforce→confidence story
**Missing entirely:** After running `reinforce(id, 'success')` repeatedly, `match_confidence` visibly increases and the lesson moves up in recall ranking. This is measurable and demonstrable. No benchmark currently shows this.

**Concrete fix:** Add a micro-benchmark table to the benchmarks section:

```markdown
### Outcome-Learning: Ranking Flip Verification

| Scenario | recall@1 pre-reinforce | After 3× reinforce('success') | Rank delta |
|---|---|---|---|
| Lessons corpus N=50, target at rank 4 | 0% (target not at rank 1) | 100% (target at rank 1) | +3 |

See: [examples/01_reinforce_ranking_flip.py](examples/01_reinforce_ranking_flip.py)
```

This makes the unique feature measurable and verifiable, not just claimed.

**Effort:** S-M (2-4h including the example script) | **Quick win: ✅**

---

## 5. Summary: Prioritized Action Table

| # | Change | Lens | Effort | Quick Win? | Impact |
|---|---|---|---|---|---|
| 1 | **Collapse 8 changelog blockquotes** into `<details>` or delete to 1 | 1 | S (30 min) | ✅ | Removes #1 friction for first-time visitors |
| 2 | **Rewrite tagline** to benefit-first | 1 | S (15 min) | ✅ | Immediately clearer value prop |
| 3 | **Restructure benchmark section** — table first, 2-line caveat, link to COMPETITIVE_REALITY.md | 4 | S (30 min) | ✅ | Stops README from undermining itself |
| 4 | **Add `examples/01_reinforce_ranking_flip.py`** — the killer demo | 4 | S-M (2-4h) | ✅ | First runnable proof of unique feature |
| 5 | **Add Python MCP quickstart snippet** to README (replaces Docker-only hero) | 1 | S-M (2h) | ✅ | Lowers time-to-first-success for Python devs |
| 6 | **Enable GitHub Discussions + add badge** | 1 | S (10 min) | ✅ | Signals active project, allows Q&A |
| 7 | **Add GitHub stars badge** (when count warrants) | 1 | S (5 min) | ✅ | Authentic social proof |
| 8 | **Hero banner image** (1200×300px) + **OG social preview** | 1 | M (½ day) | ✅ | Brand presence, shareable link previews |
| 9 | **Add `examples/02_mcp_quickstart.py`** and `03_token_budget_navigate.py` | 4 | M (3-4h) | ⚠️ | Covers other unique features |
| 10 | **Add animated GIF** showing reinforce→ranking-flip (asciinema/vhs) | 1 | M (2-3h) | ⚠️ | Visual proof, highest engagement on GitHub |
| 11 | **MkDocs-Material docs site** on GitHub Pages | 4 | M (1 day) | ⚠️ | Matches competitor docs quality |
| 12 | **Add provenance gate demo** (`examples/04_provenance_gate.py`) | 4 | S (1h) | ⚠️ | Covers compliance differentiator |

**Immediate (today, no design needed):** Items 1, 2, 3, 6, 7 → ~2 hours of writing. Removes the worst first-impression blockers.

**This sprint:** Items 4, 5, 12 → 1 day. Gives working code for the two uniquely differentiating features.

**Next sprint:** Items 8, 9, 10, 11 → 2-3 days. Matches the visual/docs quality of graphiti (27.4k stars).

---

## 6. What pgmnemo Should NOT Copy

- **Fake star counts / purchased social proof** — do not use star-history.com tricks or inflate. PGXN badge is more credible than inflated GitHub stars.
- **"We beat everyone" benchmark framing** — pgmnemo already has the right instinct here. The fix is presentation (move caveats to linked doc), not removal of honesty.
- **YC badge equivalent without YC backing** — do not add fake accelerator/investor badges. If there's a real institution (university, research lab, employer), that's worth adding. Otherwise omit.
- **Trendshift badge** — only meaningful if the repo is actually trending. Check if it qualifies; if not, don't add the empty badge.

---

## 7. The Reinforce→Ranking-Flip Demo — Why It's the Moat

This section is for the facilitation discussion, not the README.

pgmnemo's `reinforce()` + `match_confidence` is the only feature in this comparison set that:
1. Lets agents *learn from outcomes* (not just store/retrieve)
2. Has database-native implementation (no Python process, no sidecar)
3. Changes recall ranking measurably and verifiably via SQL
4. Is regression-testable with `pg_regress`

Mem0 has confidence scores but they're LLM-derived (write cost, non-deterministic). Graphiti has temporal edge confidence but it's not a per-lesson outcome-learning signal. Neither has a copy-paste demo.

The **single highest ROI action** for pgmnemo's GitHub presence is: write `examples/01_reinforce_ranking_flip.py` → record a GIF → add both to README. This creates a visual proof of the unique differentiator that none of the competitors can copy without changing their architecture.

---

## Appendix: Sources Examined

- `github.com/mem0ai/mem0` — raw README + rendered page (fetched 2026-06-13)
- `github.com/HKUDS/LightRAG` — raw README + rendered page (fetched 2026-06-13)  
- `github.com/getzep/graphiti` — raw README + rendered page (fetched 2026-06-13)
- `docs.mem0.ai` — docs landing page (fetched 2026-06-13)
- `help.getzep.com/graphiti` — docs landing page (fetched 2026-06-13)
- `/external-repos/pgmnemo/README.md` — current state (v0.8.3)
- `/external-repos/pgmnemo/POSITIONING.md` — competitor matrix
- `/external-repos/pgmnemo/examples/` — examples directory inventory
- `/external-repos/pgmnemo/docs/` — docs directory inventory
