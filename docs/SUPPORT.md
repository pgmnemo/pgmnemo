# Support Policy

**Status:** active  
**Date:** 2026-05-09  
**Scope:** pgmnemo v0.2.x and later

---

## GitHub Discussions — DISABLED

**Decision (2026-05-09):** GitHub Discussions are OFF.

**Trigger to re-enable:** whichever comes first —
- 5 external contributors with merged PRs (accounts outside the core team), or
- Show HN post published.

**Rationale:** open Discussions implies a community capable of sustaining responses. That community does not yet exist. An open Discussions tab with unanswered threads is a trust liability, not an asset.

Until the trigger fires, all user conversation routes through GitHub Issues.

---

## Where to get help

| Channel | Label to use | Use for | Response window |
|---|---|---|---|
| [GitHub Issues](../../issues) | `question` | Install / usage questions | Best-effort; target ≤ 5 business days |
| [GitHub Issues](../../issues) | `bug` | Reproducible failures | Target ≤ 3 business days initial triage |
| [GitHub Issues](../../issues) | `docs` | Doc gaps, typos, misleading text | Target ≤ 5 business days |
| [GitHub Issues](../../issues) | `benchmark` | Benchmark discrepancies or replication failures | Target ≤ 5 business days |

**Security issues:** do not open a public issue — see [SECURITY.md](../SECURITY.md).

---

## What "response window" means

- Initial human acknowledgment (not a bot reply) within the stated window.
- Resolution is not guaranteed within the window; complex issues may take longer.
- No paid-support tier exists at this stage.
- Response cadence may slow during maintainer absence.
- The project is pre-1.0 and resource-constrained; all responses are best-effort.

---

## How to write a useful issue

Paste this template into your issue for faster triage:

```
PostgreSQL version:
pgmnemo version (SELECT pgmnemo.version()):
pgvector version:
Install method (source / pgxn / docker):
Minimal reproduction (SQL or shell):
Observed output:
Expected output:
```

For install failures, include the full `make install` output or Docker log.

---

## Out of scope

- Feature requests without a concrete use-case description
- Architecture consulting
- Managed-service constraints (AWS RDS, Supabase, Neon) — open an issue anyway;
  known limitations will be documented as they are confirmed

---

## Re-enable checklist for Discussions

Before enabling GitHub Discussions:

- [ ] Trigger condition met: 5 external contributors merged OR Show HN published
- [ ] One team member assigned as Discussions moderator
- [ ] Default categories pruned to: Q&A, Ideas, Show & Tell
- [ ] Pinned "Read before posting" post linking USAGE, INSTALL, SUPPORT
- [ ] This file updated with Discussions-specific response-window expectations
