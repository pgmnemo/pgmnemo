# pgmnemo Release Checklist

## Pre-release gates (mandatory before every release)

### 1. Packaging smoke test — prevents Issue #32 empty-wheel regression

Run from `pgmnemo_mcp/` directory:

```bash
# Build wheel
pip install build && python -m build --wheel

# Install in clean venv
python -m venv /tmp/testenv
/tmp/testenv/bin/pip install dist/*.whl

# Import check (must print a path, not error)
/tmp/testenv/bin/python -c 'import pgmnemo_mcp; print("OK:", pgmnemo_mcp.__file__)'

# Verify wheel contains .py files
WHL=$(ls dist/*.whl)
COUNT=$(unzip -l $WHL | grep '\.py$' | wc -l)
echo "Python files in wheel: $COUNT"
[ $COUNT -gt 0 ] || (echo 'FAIL: wheel contains no .py files' && exit 1)
```

Combined one-liner:
```bash
python -m build --wheel && pip install dist/*.whl && python -c 'import pgmnemo_mcp'
```

### 2. Run full test suite

```bash
cd pgmnemo_mcp && pytest tests/ -v
```

### 3. Verify version bumped

- `pgmnemo_mcp/pyproject.toml` → `version`
- `CHANGELOG.md` → entry for new version

### 4. Tag and publish

```bash
git tag v<version>
git push origin v<version>
# CI publish-mcp.yml handles PyPI upload on tag push
```

## CI gates (automated — all must be green before merging)

- `ci.yml` — PostgreSQL extension build + installcheck
- `packaging-smoke.yml` — wheel build, install, import check (prevents Issue #32)
- `release.yml` — release publishing
