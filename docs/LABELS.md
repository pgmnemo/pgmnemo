# Label taxonomy

GitHub label definitions for `pgmnemo/pgmnemo`.

Apply labels at triage. Issues may have multiple labels.

## Type (what kind of change)

| Label | Color | Description |
|---|---|---|
| `bug` | `#d73a4a` | Confirmed defect — wrong behavior, crash, data loss |
| `enhancement` | `#a2eeef` | New capability or improvement to existing behavior |
| `documentation` | `#0075ca` | Docs missing, wrong, or confusing |
| `question` | `#d876e3` | Question answered in Discussions; keep for searchability |
| `refactor` | `#e4e669` | Internal restructuring with no behavior change |
| `performance` | `#fbca04` | Throughput, latency, or memory improvement |

## Component (which subsystem)

| Label | Color | Description |
|---|---|---|
| `sql-extension` | `#1d76db` | Extension SQL, functions, schema, GUCs |
| `pgmnemo-mcp` | `#0e8a16` | MCP server package (`pgmnemo_mcp/`) |
| `benchmarks` | `#5319e7` | Benchmark scripts, gate files, metrics |
| `ci-packaging` | `#f9d0c4` | CI workflows, Docker, PGXN, PyPI |
| `install` | `#c2e0c6` | Installation, upgrade, migration path |

## Status (workflow)

| Label | Color | Description |
|---|---|---|
| `triage` | `#ededed` | Needs maintainer review — default for new issues |
| `confirmed` | `#0e8a16` | Reproduced / accepted; ready for work |
| `needs-info` | `#e4e669` | Waiting on reporter for reproduction or clarification |
| `wontfix` | `#ffffff` | Deliberate decision not to address |
| `duplicate` | `#cfd3d7` | Covered by another issue |
| `good first issue` | `#7057ff` | Suitable for first-time contributors |
| `help wanted` | `#008672` | Core team welcomes external contribution |

## Priority (severity / urgency)

| Label | Color | Description |
|---|---|---|
| `P0-critical` | `#b60205` | Data loss, security, or blocked release |
| `P1-high` | `#e11d48` | Significant user impact; address in current cycle |
| `P2-normal` | `#f97316` | Standard backlog item |
| `P3-low` | `#fbbf24` | Nice to have; no current timeline |

## Release

| Label | Color | Description |
|---|---|---|
| `breaking-change` | `#d93f0b` | Requires migration step; will appear in Breaking Changes scan |
| `regression` | `#b60205` | Behavior correct in prior version, broken now |

---

**To create labels in bulk**, use the GitHub CLI:
```bash
# Example
gh label create "sql-extension" --color "1d76db" --description "Extension SQL, functions, schema, GUCs"
```
Or import via the GitHub UI (Settings → Labels).
