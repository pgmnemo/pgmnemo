# Contributing to pgmnemo

Thanks for your interest in contributing! `pgmnemo` is an Apache-2.0 licensed PostgreSQL
extension and welcomes contributions of all sizes.

> 📘 **Read first:** [`docs/WORKFLOW.md`](docs/WORKFLOW.md) (the customer-driven
> bench-gated discipline that every change ships under) and
> [`docs/RELEASE_CHECKLIST.md`](docs/RELEASE_CHECKLIST.md) (the end-to-end
> Phase 0–7 list every release follows).
>
> For feature proposals: open a GitHub Issue using the hypothesis-declaration
> template documented in `docs/WORKFLOW.md §2.1` **before** writing code.
> Untargeted PRs are likely to be rejected with a pointer back to the workflow.

## Quick rules

1. **All contributions are licensed Apache-2.0** — by submitting a PR you agree your contribution
   is offered under the same license as the project.
2. **DCO sign-off required.** Every commit must include `Signed-off-by: Your Name <email>`
   (use `git commit -s`). This is your developer certificate of origin — see
   <https://developercertificate.org/>.
3. **Conventional commits.** Format: `type(scope): subject`. Types: `feat`, `fix`, `docs`,
   `refactor`, `test`, `chore`, `perf`, `build`, `ci`. Example: `feat(retrieval): add tsvector index hint`.
4. **Tests required for behavior changes.** PRs that change extension behavior must include
   regression tests in `test/sql/` with expected output in `test/expected/`.

## Development workflow

```bash
git clone git@github.com:pgmnemo/pgmnemo.git
cd pgmnemo
git checkout -b feat/your-feature-name

# Make changes, test locally:
make
make installcheck

# Commit with sign-off:
git commit -sm "feat(scope): subject"
git push origin feat/your-feature-name
# Open PR via GitHub UI
```

## What we look for in PRs

- Clear problem statement in PR description
- Minimal scope — one PR = one logical change
- Tests for new behavior, regression tests for fixes
- Docs updated when public API changes
- No new external dependencies without prior discussion in an issue

## What we will not merge

- Code that introduces a hard dependency on a specific LLM provider
- Code that requires data to leave the local PostgreSQL instance
- Changes to the provenance gate semantics without a corresponding ADR in `docs/adr/`
- License changes (the project is Apache-2.0 — this is locked)

## Reporting bugs

Open an issue with: PostgreSQL version, OS, `pgmnemo` version (`SELECT pgmnemo.version();`),
minimal reproduction SQL, expected vs actual behavior.

## Reporting security issues

Do **not** open a public issue. Email security@pgmnemo.dev (or until that domain exists,
the maintainer's GitHub-listed email) with details. We aim to respond within 72 hours.

## Code of conduct

Be kind, be precise, assume good intent, criticize ideas not people. The maintainers reserve the
right to remove disruptive comments and ban repeat offenders.

## Decision-making

`pgmnemo` follows a documented decision process:

- Architecture-level decisions are tracked as ADRs in `docs/adr/`
- Strategic decisions are tracked in `docs/STRATEGY.md`
- Day-to-day decisions are made by the maintainers and recorded in PRs

Bigger changes (license, governance, breaking API changes) require maintainer consensus and
will go through a community RFC once the community exists.

## Getting help

- General questions → GitHub Discussions (after public release)
- Bug reports → GitHub Issues
- Security → security email above

Thanks for contributing.
