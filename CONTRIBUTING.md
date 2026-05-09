# Contributing to pgmnemo

Thanks for your interest in contributing! `pgmnemo` is an Apache-2.0 licensed PostgreSQL
extension and welcomes contributions of all sizes.

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

See [SECURITY.md](SECURITY.md) for the project policy.

## Code of conduct

See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

## Decision-making

`pgmnemo` follows a documented decision process:

- Architecture-level decisions are tracked as ADRs in `docs/adr/`
- Strategic decisions are tracked in `docs/STRATEGY.md`
- Day-to-day decisions are made by the maintainers and recorded in PRs

Bigger changes (license, governance, breaking API changes) require maintainer consensus and
will go through a community RFC once the community exists.

## Getting help

- General questions → GitHub Discussions or Issues, depending on what is enabled in the repo
- Bug reports → GitHub Issues
- Security → security email above

Thanks for contributing.
