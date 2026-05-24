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
