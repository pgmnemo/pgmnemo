# pgmnemo Release Runbook

End-to-end procedure for shipping a new pgmnemo version. Follow top-to-bottom; every step is a CI pre-flight gate or a recurring pitfall from past releases.

---

## 0. Pre-flight checklist (all must be green before `git tag`)

Run from repo root:

```bash
V=0.6.X  # the version you're about to ship

# 1. Version files agree
grep "^default_version" extension/pgmnemo.control          # → 'X.Y.Z'
python3 -c "import json; print(json.load(open('META.json'))['version'])"
python3 -c "import json; d=json.load(open('META.json')); print(d['provides']['pgmnemo']['version'], d['provides']['pgmnemo']['file'])"
grep "^version" pgmnemo_mcp/pyproject.toml                  # → "X.Y.Z"

# 2. Fresh-install + upgrade SQL scripts exist
ls extension/pgmnemo--${V}.sql                              # fresh install (squash)
ls extension/pgmnemo--$(prev_version)--${V}.sql             # incremental update path

# 3. Makefile DATA list includes the new .sql files
grep "pgmnemo--${V}.sql" extension/Makefile

# 4. CHANGELOG entry exists and is non-trivial (>200 chars)
grep "^## \[${V}\]" CHANGELOG.md
python3 -c "import re; c=open('CHANGELOG.md').read(); m=re.search(rf'^## \[{re.escape(\"$V\")}\][^\n]*\n(.*?)(?=^## \[|\Z)', c, re.M|re.S); print(len(m.group(1).strip()) if m else 0)"

# 5. Bench gate JSON exists
ls benchmarks/gate/v${V}.json                               # gate_status=PASS (or NO_GO with explicit reason)

# 6. Telegram release notes
ls docs/release_notes/v${V}_telegram.md                     # ≤4000 chars, HTML-formatted

# 7. README badge bumped
grep "badge/version-${V}" README.md

# 8. CRITICAL — pg_regress fixtures use current default_version
#    This pitfall hit v0.6.0, v0.6.2, v0.6.3 release pipelines.
grep -rE "UPDATE TO '[^']+'" extension/sql/ extension/expected/ | grep -v "UPDATE TO '${V}'"
# Expected output: EMPTY. If any line shown, fix:
#   sed -i "s/UPDATE TO '[^']*'/UPDATE TO '${V}'/g" extension/sql/*.sql extension/expected/*.out

grep -rE 'NOTICE:[^"]*version "[0-9.]+" of extension' extension/expected/ | grep -v "version \"${V}\""
# Expected output: EMPTY. If any line shown, fix:
#   sed -i 's/version "[0-9.]*" of extension/version "'${V}'" of extension/g' extension/expected/*.out
```

CI pre-flight enforces 1-8 automatically. The pg_regress fixture sweep (#8) was added after v0.6.3 to prevent the recurring NOTICE/UPDATE-TO drift.

---

## 0.A Documentation readiness (manual sweep, before tag)

Every new GUC, function, or changed default **must** be documented before the tag.
v0.9.4 shipped as a separate docs-only release because this was skipped for v0.9.2–v0.9.3.

### GUC coverage check

```bash
# List every GUC defined in the flat install:
grep -oE "current_setting\('pgmnemo\.[^']+'" extension/pgmnemo--${V}.sql | sort -u

# Verify each appears in SQL_REFERENCE §3:
grep "pgmnemo\." docs/SQL_REFERENCE.md | grep -v "^#\|example\|SET pgmnemo\.\(gate\|include\|tenant\)" | grep -oE "pgmnemo\.[a-z_]+" | sort -u
```

Cross-check: every GUC in the flat install must have a row in `SQL_REFERENCE.md §3`.

### Default-value consistency

```bash
# If reinforce() deltas changed — verify USAGE shows the new values:
grep "confidence +=" docs/USAGE.md          # must match default in SQL
grep "confidence -=" docs/USAGE.md          # must match default in SQL
```

### Checklist

- [ ] Every GUC introduced in this version has a row in `SQL_REFERENCE.md §3.x`
- [ ] `SQL_REFERENCE.md §3.6 Default-change history` has an entry for each changed default
- [ ] `USAGE.md` examples use current default values (not previous release's values)
- [ ] `MIGRATION.md` notes any breaking changes (column renames, removed overloads, etc.)
- [ ] `CHANGELOG.md §[V]` entry is non-trivial (>200 chars)

**If docs are not ready: do not tag.** Ship a docs-only patch version first (like v0.9.4),
or backfill docs in the same branch before tagging.

---

## 0.B MCP readiness (manual sweep, before tag)

`pgmnemo_mcp` is a thin Python wrapper; it must stay in sync with the SQL API.

### Version

```bash
grep "^version" pgmnemo_mcp/pyproject.toml   # must match ${V}
```

Already enforced by §0 checklist item #1.

### API surface check

New SQL functions shipped in this version may need MCP tool coverage.
Check whether each new/changed function should be exposed:

```bash
# Functions added or replaced in the upgrade script:
grep -E "^CREATE (OR REPLACE )?FUNCTION" extension/pgmnemo--$(prev)--${V}.sql

# Current MCP tools:
grep -E "^@mcp\.tool|^def " pgmnemo_mcp/pgmnemo_mcp/server.py | head -30
```

Decide for each: **expose** (add MCP tool) | **internal** (skip, leave a comment) | **deferred** (note in CHANGELOG).

### MCP smoke test

```bash
cd pgmnemo_mcp
pip install -e .
python -m pgmnemo_mcp --smoke    # must print PASS; fails on import or schema errors
```

### MCP Docker image

Built and published automatically by CI (`Publish pgmnemo-mcp Docker image` job).
No manual step needed unless the Dockerfile changed — in that case rebuild locally first:

```bash
docker build -t pgmnemo-mcp:${V} pgmnemo_mcp/
docker run --rm pgmnemo-mcp:${V} python -m pgmnemo_mcp --smoke
```

### MCP checklist

- [ ] `pyproject.toml` version = `${V}`
- [ ] New SQL functions reviewed: expose / internal / deferred decision recorded in CHANGELOG
- [ ] `python -m pgmnemo_mcp --smoke` passes locally
- [ ] If Dockerfile changed: local build + smoke verified

---

## 1. Local smoke test (before tag)

```bash
# pg_regress should pass on host PG17 + pgvector
cd extension && make installcheck PG_CONFIG=$(which pg_config)

# scripts/smoke_recall_hybrid.py should PASS
DATABASE_URL=postgresql://... python3 scripts/smoke_recall_hybrid.py
```

If installcheck fails locally, fix BEFORE pushing — fixing in CI loop is expensive (each retry = ~5 min wait + dispatch overhead).

---

## 2. Tag + push

```bash
git tag -a v${V} -m "v${V} — <one-line summary>"
git push origin main
git push origin v${V}
```

The tag push fires `.github/workflows/release.yml`:

| Job | What it does | If it fails |
|---|---|---|
| pre-flight | Validates 8 checklist items above | Fix the named issue, delete tag, retag |
| installcheck | `pg_regress` against PG17 + pgvector | Download `regression-diffs` artifact, fix expected outputs, retag |
| bench-gate | Verifies `benchmarks/gate/v${V}.json` present | Create the gate JSON |
| release | Builds PGXN bundle + creates GitHub Release | Check PGXN credentials secret |
| publish-mcp | Publishes `pgmnemo-mcp` to PyPI | Check OIDC trusted publisher config |
| smoke-pypi | `pip install pgmnemo-mcp==${V}` + import | Investigate empty-wheel regression (#32 class) |
| smoke-pgxn | HEAD-check PGXN release URL | Usually CDN propagation delay; not blocking |
| notify-telegram | Sends `docs/release_notes/v${V}_telegram.md` to chat | See §3 below |
| notify-failure | Auto-opens GitHub issue on any failure | Close after fixing |

---

## 3. Telegram notification

`notify-telegram` job has two modes:

**Auto mode** (preferred): set repo secrets `TG_BOT_TOKEN` + `TG_CHAT_ID` once. Every tag push auto-sends. Create the bot via @BotFather, add to your release chat with post permission.

**Manual mode**: secrets unset → on tag push CI **fails** with the message `TG_BOT_TOKEN / TG_CHAT_ID secrets missing`. To proceed without configuring secrets:

1. Add `[tg-skip]` to the tagging commit message
2. Send manually via your internal release tool (or by hand)

The hard-fail behaviour was added after v0.6.1 and v0.6.2 silently skipped TG notifications (founder trust damage). Silent skip is no longer acceptable on tag pushes.

---

## 4. Post-release verification (operator-side, run after CI green)

NEVER trust `gh run conclusion=success` alone — always probe destinations:

```bash
V=0.6.X

# GitHub Release
gh release view v${V} --json assets

# PyPI
curl -s https://pypi.org/pypi/pgmnemo-mcp/${V}/json | python3 -c "import json,sys; print(json.load(sys.stdin)['info']['version'])"

# PGXN
curl -sI https://api.pgxn.org/dist/pgmnemo/${V}/pgmnemo-${V}.zip -w "%{http_code}\n" -o /dev/null
# Note: pgxn.org/dist/... CDN may lag; api.pgxn.org is authoritative.

# Telegram (if you sent manually)
# Verify msg_id appears in your release chat
```

---

## 5. Post-release housekeeping

- Close any GitHub Issues that this version addresses
- Update `ROADMAP.md`: mark the row `(✅ SHIPPED)` with date + a one-line evidence string
- If the release deferred work, document the reason in the deferred-version's row

---

## 6. Common failure modes & remedies

| Symptom | Root cause | Fix |
|---|---|---|
| `installcheck` fails with `no update path from <X> to <prev>` | Stale `UPDATE TO 'prev'` in `extension/sql/*.sql` | Bulk replace: `sed -i "s/UPDATE TO '[^']*'/UPDATE TO '${V}'/g" extension/sql/*.sql extension/expected/*.out` |
| `installcheck` fails with NOTICE diff `version "prev" vs "${V}"` | Stale NOTICE in `extension/expected/*.out` after `default_version` bump | Bulk replace: `sed -i 's/version "[0-9.]*" of extension/version "'${V}'" of extension/g' extension/expected/*.out` |
| `installcheck` fails for new test with whitespace diff | Hand-written `.out` file missing pg_regress SQL echo or trailing spaces | Run test once, copy actual results: `cp extension/results/<test>.out extension/expected/<test>.out` |
| CI workflow fails in 0 seconds | YAML validation error (e.g. `secrets` context in job-level `if:`) | Run `actionlint .github/workflows/release.yml` locally before push |
| Release succeeds but `notify-telegram` skipped silently | `TG_BOT_TOKEN`/`TG_CHAT_ID` secrets missing (pre-runbook releases) | Now hard-fails on tag push unless `[tg-skip]` in commit |
| Smoke-pgxn flaky 404 | CDN propagation lag | Retry in 5 min; if still 404, check `api.pgxn.org/dist/pgmnemo/<V>/<V>.zip` directly |

---

## 7. Bench-gate variants

The `benchmarks/gate/v${V}.json` file must declare `gate_status: PASS` (or explicitly `NO_GO` with reasons). Pre-flight accepts any of:

- `gate_type: real_db_bench_significance` — real-DB benchmark with p-value < 0.05 and ≥+1pp recall delta (preferred for scoring changes)
- `gate_type: analytical_*` — analytical carry-forward when feature has no scoring impact (e.g. new GUC, doc-only)
- `gate_type: bug_fix_smoke` — bug fix verified by regression test only (no perf change expected)

If a real-DB bench is required but environment isn't ready, **do not ship halfway**. Defer the version, ship narrowed scope.
