# OPERATOR FINAL PUSH INSTRUCTIONS
## pgmnemo v0.6.3 Release Deployment

**Status:** Code complete, locally committed and tagged. Ready for GitHub push and CI verification.

**Commit:** `cd54540` (ship state)
**Tag:** `v0.6.3` → `cd54540`

---

## STEP 1: Verify Local State (in container — already done)

```bash
cd /external-repos/pgmnemo
git status                    # ✅ VERIFIED: clean working tree
git log -1 --oneline          # ✅ VERIFIED: cd54540 ship(v0.6.3): DELIVERY_REPORT
git tag -l | grep v0.6.3      # ✅ VERIFIED: v0.6.3 tag exists
git tag -p v0.6.3             # Points to cd54540
```

---

## STEP 2: Push to GitHub (operator only — requires credentials)

Execute from a terminal with GitHub access:

```bash
cd /external-repos/pgmnemo
git push origin main
git push origin v0.6.3
```

Expected output:
```
To github.com:pgmnemo/pgmnemo.git
   6ba4def..cd54540  main -> main
 * [new tag] v0.6.3 -> v0.6.3
```

---

## STEP 3: Verify CI Pipeline Completion

Monitor the release workflow:

```bash
gh run list --workflow=release.yml
```

OR check GitHub web UI: https://github.com/pgmnemo/pgmnemo/actions

Expected steps (from `.github/workflows/release.yml`):
1. ✅ Trigger: tag v0.6.3 detected
2. ✅ pg_regress: 18 tests PASS (role_no_ambiguity validates R1 fix)
3. ✅ extension build: pgmnemo--0.6.3.so
4. ✅ MCP package build: pgmnemo_mcp (Python 3.11+)
5. ✅ PyPI upload: pgmnemo-mcp v0.6.3
6. ✅ GitHub Release creation: v0.6.3 with CHANGELOG excerpt

---

## STEP 4: Confirm Release Success

Verify artifacts:

### GitHub Release
```bash
gh release view v0.6.3
```

Expected:
- Title: "pgmnemo v0.6.3 — AmbiguousColumn hotfix + docs"
- Body: CHANGELOG excerpt + R1/R2/R3/R4 summary
- Assets: none (builds are on PyPI, docs on extension docs site)

### PyPI Package
```bash
pip index versions pgmnemo-mcp | grep 0.6.3
```

Expected: `Available versions: ..., 0.6.3, ...`

### PostgreSQL Extension
```bash
# After `CREATE EXTENSION pgmnemo VERSION '0.6.3'`:
SELECT default_version FROM pg_available_extensions WHERE name='pgmnemo';
# Expected: 0.6.3

# Test R1 fix (AmbiguousColumn should NOT occur):
SELECT * FROM pgmnemo.recall_lessons(
  agent_id => 1,
  query_embedding => '[0.1, 0.2, 0.3]'::vector
);
# Expected: role column in result, no AmbiguousColumn error
```

---

## ACCEPTANCE GATE — ALL MUST PASS

| Gate | Condition | Evidence |
|------|-----------|----------|
| **Push Success** | Both `git push origin main` and `git push origin v0.6.3` return 0 | Output shows branches/tags accepted |
| **CI Pipeline** | `.github/workflows/release.yml` completes with status=success | All 6 steps green on GitHub Actions |
| **pg_regress** | 18 tests PASS (including role_no_ambiguity) | CI log shows `18 passed, 0 failed` |
| **PyPI Upload** | pgmnemo-mcp v0.6.3 published to PyPI | `pip index versions` shows 0.6.3 |
| **GitHub Release** | v0.6.3 release created with CHANGELOG excerpt | `gh release view v0.6.3` returns content |
| **R1 Fix Validated** | `recall_lessons()` and `recall_hybrid()` return without AmbiguousColumn error | Smoke test against live db passes |

---

## ROLLBACK PROCEDURE (if CI fails)

If any CI step fails:

```bash
# Delete local tag (only if needed)
git tag -d v0.6.3

# Delete remote tag (via GitHub CLI)
gh release delete v0.6.3

# Revert push
git reset --soft HEAD~1    # or git revert cd54540
git push origin main --force-with-lease

# Fix code, re-commit, and re-push
```

---

## TROUBLESHOOTING

### Push fails with "permission denied"
- Verify GitHub SSH key is loaded: `ssh-keyscan -t rsa github.com`
- Or use: `git push https://YOUR_TOKEN@github.com/pgmnemo/pgmnemo.git`

### pg_regress fails: "cannot DROP EXTENSION pgmnemo"
- Check for open connections: `SELECT * FROM pg_stat_activity WHERE datname = 'pgmnemo_test';`
- Kill idle connections: `SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'pgmnemo_test';`

### PyPI upload fails
- Verify `.pypirc` has token: `cat ~/.pypirc | grep -i token`
- Re-upload: `cd pgmnemo_mcp && python -m twine upload dist/pgmnemo_mcp-0.6.3-*.whl`

---

## FINAL CHECKLIST

After push and CI complete:

- [ ] `git push origin main` succeeded
- [ ] `git push origin v0.6.3` succeeded
- [ ] GitHub Actions `.github/workflows/release.yml` status = green
- [ ] pg_regress 18 tests PASS
- [ ] PyPI shows pgmnemo-mcp v0.6.3 available
- [ ] GitHub Release v0.6.3 created
- [ ] Smoke test: `recall_lessons()` and `recall_hybrid()` return without AmbiguousColumn
- [ ] Document link updated in internal wiki (if applicable)

---

**Contact:** TL/Karpov (operator) for any deployment questions.

**Reference:** `/external-repos/pgmnemo/DELIVERY_REPORT_SWDEV-260524-1-SHIP.md`
