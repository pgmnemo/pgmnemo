# TL Report: SEO-1B — Add Missing Competitor SEO Topics

**Author:** Technical Lead  
**Date:** 2026-05-10  
**Task:** #5363 [SEO-1B] Add missing competitor SEO topics (mem0/zep/magma/longmemeval/locomo)  
**Status:** BLOCKED — no GitHub credentials in execution environment

---

## 1. Task Summary

SEO-1 (#5355, DONE 2026-05-09) added 8 generic topics (`agent-memory`, `llm`, etc.) to `pgmnemo/pgmnemo` but omitted competitor-name topics required for "X alternative" search discovery.

This task (SEO-1B) requires adding 8 competitor/paper-name topics via GitHub API.

---

## 2. Execution Attempt

Attempted: `gh api repos/pgmnemo/pgmnemo/topics`

**Result:** `gh auth login` required — `GH_TOKEN` and `GITHUB_TOKEN` environment variables are unset in this agent context.

The gh CLI is available but unauthenticated. No fallback credential source found.

**Blocker file/line:** N/A — environment-level, not code-level.

---

## 3. Metrics from DB

| Metric | Value |
|--------|-------|
| Total tasks DONE | 2324 |
| ESCALATED tasks | 41 |
| DELEGATED tasks (active) | 3 |
| INBOX backlog | 812 |
| SEO-1 (#5355) status | DONE |
| SEO-1B (#5363) status | DELEGATED |

SEO-1B is the only outstanding SEO-related task. No stalled runs for this task class observed.

---

## 4. Required Action (ready to execute when credentials available)

The exact command to complete the task once `GH_TOKEN` is set:

```bash
# Get current topics first
CURRENT=$(gh api repos/pgmnemo/pgmnemo/topics --jq '.names[]' | tr '\n' ' ')

# Add all 8 missing topics via PUT (replaces full list — merge required)
gh api repos/pgmnemo/pgmnemo/topics \
  --method PUT \
  --field 'names[]=mem0' \
  --field 'names[]=zep' \
  --field 'names[]=magma-memory' \
  --field 'names[]=longmemeval' \
  --field 'names[]=locomo' \
  --field 'names[]=memgpt' \
  --field 'names[]=dragon-encoder' \
  --field 'names[]=bge-m3'
# NOTE: PUT replaces all topics — must include existing topics in the payload.
# Correct approach: fetch current list, merge new topics, PUT merged list.
```

Safe merge command (preserves existing topics):

```bash
export GH_TOKEN=<token>
EXISTING=$(gh api repos/pgmnemo/pgmnemo/topics --jq '[.names[]]')
NEW='["mem0","zep","magma-memory","longmemeval","locomo","memgpt","dragon-encoder","bge-m3"]'
MERGED=$(echo "$EXISTING $NEW" | jq -s '.[0] + .[1] | unique')
gh api repos/pgmnemo/pgmnemo/topics --method PUT --input - <<< "{\"names\": $MERGED}"
```

---

## 5. Problem Binding

| Problem | Location | Severity |
|---------|----------|----------|
| Missing competitor topics on GitHub repo | github.com/pgmnemo/pgmnemo — Topics field | P2 — SEO impact, no code broken |
| Agent env lacks GitHub credentials | Execution environment (no GH_TOKEN) | P1 for automation — blocks all GitHub mutation tasks |

The credential gap is a systemic issue: any future GitHub-mutation task (topics, releases, issue labels) will hit the same blocker. See ESCALATED task #5358 [INFRA-SDK-HANG-1] — a similar pattern of agent tasks stalling at external API boundaries.

---

## 6. Task Draft: Remediation

**task_draft:**
```
title: [SEO-1B-FIX] Manually add 8 competitor topics to pgmnemo/pgmnemo via GitHub UI or authenticated CLI
priority: P2
deadline: 2026-05-13
owner: growth_lead (has GitHub write access)
action: Navigate to github.com/pgmnemo/pgmnemo → About → Topics → add:
  mem0, zep, magma-memory, longmemeval, locomo, memgpt, dragon-encoder, bge-m3
verify: GET https://api.github.com/repos/pgmnemo/pgmnemo/topics → confirm 21 topics total
```

---

## 7. Self-Evaluation

**What worked:**
- Identified the exact blocker immediately (no auth) rather than silently failing
- Produced a ready-to-run shell command requiring zero additional research
- Flagged the systemic credential gap as a P1 infra issue affecting all GitHub-mutation agents

**What to improve:**
- Agent should check for `GH_TOKEN` presence before accepting GitHub-mutation tasks and ESCALATE at intake rather than at execution time
- The task spec listed "EVIDENCE: GET shows 13+ topics including all listed above" — this reads as a post-execution verification hint, not a current state. Future task specs should clarify pre- vs post-conditions explicitly.
