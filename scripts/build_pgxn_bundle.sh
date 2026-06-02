#!/usr/bin/env bash
# build_pgxn_bundle.sh — reproducible PGXN bundle build for pgmnemo
#
# Usage: scripts/build_pgxn_bundle.sh X.Y.Z
#
# Produces pgmnemo-X.Y.Z.zip in repo root. Validates META.json consistency
# (version field == bundled directory name == provides.pgmnemo.version).
#
# Idempotent: removes any prior pgmnemo-X.Y.Z/ + pgmnemo-X.Y.Z.zip first.
#
# Exits non-zero on validation failure. Safe to call from CI.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 X.Y.Z" >&2
    exit 1
fi

# Determine repo root from script location, regardless of CWD
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_DIR="pgmnemo-$VERSION"
BUNDLE_ZIP="pgmnemo-$VERSION.zip"

echo "[build] cleaning prior artefacts..."
rm -rf "$BUNDLE_DIR" "$BUNDLE_ZIP"

echo "[build] validating extension files..."
test -f "extension/pgmnemo--$VERSION.sql" || {
    echo "ERROR: extension/pgmnemo--$VERSION.sql missing — run scripts/build_flat_install.sh first?" >&2
    exit 1
}
test -f "extension/pgmnemo.control" || {
    echo "ERROR: extension/pgmnemo.control missing" >&2
    exit 1
}
CONTROL_VER=$(grep -E "^default_version" extension/pgmnemo.control | sed -E "s/.*'([^']+)'.*/\1/")
if [[ "$CONTROL_VER" != "$VERSION" ]]; then
    echo "ERROR: extension/pgmnemo.control default_version='$CONTROL_VER' but bundle is for $VERSION" >&2
    exit 1
fi

echo "[build] validating META.json..."
python3 - <<PYEOF || exit 1
import json, sys
meta = json.load(open("META.json"))
v = "$VERSION"
errors = []
if meta.get("version") != v:
    errors.append(f"META.version={meta.get('version')!r}, expected {v!r}")
prov = meta.get("provides", {}).get("pgmnemo", {})
if prov.get("version") != v:
    errors.append(f"META.provides.pgmnemo.version={prov.get('version')!r}, expected {v!r}")
if prov.get("file") != f"extension/pgmnemo--{v}.sql":
    errors.append(f"META.provides.pgmnemo.file={prov.get('file')!r}, expected 'extension/pgmnemo--{v}.sql'")
if errors:
    for e in errors:
        print(f"ERROR: {e}", file=sys.stderr)
    sys.exit(1)
print(f"[build] META.json consistent for v{v}")
PYEOF

echo "[build] assembling bundle directory..."
# NOTE: a single, top-level "extension/" directory is the contract. The v0.7.1
# dist double-nested it (extension/extension/) because the old release.yml/this
# script copied the source dir INTO a pre-created destination dir. We avoid that
# by NEVER pre-creating "$BUNDLE_DIR/extension" and by copying file-by-file
# rather than `cp -r extension/ dest/extension/` (which is GNU/BSD-cp dependent
# and the exact idiom that broke v0.7.1).
mkdir -p "$BUNDLE_DIR/extension"

# Copy the control file + extension Makefile (PGXS conventions).
cp extension/pgmnemo.control "$BUNDLE_DIR/extension/"
cp extension/Makefile "$BUNDLE_DIR/extension/"

# Copy ONLY production migration / flat-install SQL. Exclude dev/test assets:
#   *_smoke.sql, test_*.sql, stress_*.sql live under extension/sql|tests, not as
#   pgmnemo--*.sql, so the glob below already excludes them — but we double-guard
#   in the dist-shape validator. Also drop orphan/dead-end variant migrations
#   from the *package* (they remain in-repo for the upgrade-path CI matrix).
ORPHAN_MIGRATIONS=(
    "pgmnemo--0.1.3--0.1.4-provenance.sql"
    "pgmnemo--0.1.3--0.1.4-ttl.sql"
    "pgmnemo--0.1.3--0.1.4-state-machine.sql"
    "pgmnemo--0.1.4--0.2.0-mem-edge.sql"
    "pgmnemo--0.1.4--0.2.0-traverse-causal.sql"
    "pgmnemo--0.1.4--0.2.0-traverse-temporal.sql"
    "pgmnemo--0.2.0-step4-recall-mixin.sql"
    "pgmnemo--0.2.1--0.2.2-hybrid.sql"
)
is_orphan() {
    local base="$1"
    for o in "${ORPHAN_MIGRATIONS[@]}"; do
        [[ "$base" == "$o" ]] && return 0
    done
    return 1
}
SQL_COPIED=0
for f in extension/pgmnemo--*.sql; do
    base="$(basename "$f")"
    # Skip any dev/test SQL that may have leaked into the pgmnemo--*.sql namespace
    case "$base" in
        *_smoke.sql|test_*.sql|stress_*.sql) continue ;;
    esac
    if is_orphan "$base"; then
        echo "[build]   skipping orphan migration (kept in-repo, not bundled): $base"
        continue
    fi
    cp "$f" "$BUNDLE_DIR/extension/"
    SQL_COPIED=$((SQL_COPIED + 1))
done
echo "[build]   bundled $SQL_COPIED production SQL files"

cp Makefile README.md LICENSE CHANGELOG.md META.json "$BUNDLE_DIR/"

echo "[build] creating zip..."
zip -rq "$BUNDLE_ZIP" "$BUNDLE_DIR/"

echo "[build] post-build verification + dist-shape guard..."
python3 - <<PYEOF || exit 1
import json, zipfile, sys, re, posixpath
v = "$VERSION"
z = zipfile.ZipFile("$BUNDLE_ZIP")
names = z.namelist()
errors = []

# 1) Required files present at the SINGLE level.
required = [
    f"pgmnemo-{v}/META.json",
    f"pgmnemo-{v}/extension/pgmnemo.control",
    f"pgmnemo-{v}/extension/pgmnemo--{v}.sql",
    f"pgmnemo-{v}/README.md",
    f"pgmnemo-{v}/LICENSE",
    f"pgmnemo-{v}/CHANGELOG.md",
]
for r in required:
    if r not in names:
        errors.append(f"bundle missing required entry: {r}")

# 2) Exactly ONE top-level directory, named pgmnemo-<v>/.
tops = set()
for n in names:
    parts = n.split("/", 1)
    if parts[0]:
        tops.add(parts[0])
if tops != {f"pgmnemo-{v}"}:
    errors.append(f"expected exactly one top-level dir 'pgmnemo-{v}/', got: {sorted(tops)}")

# 3) The control file must live at exactly ONE level (no double-nesting).
ctrl_hits = [n for n in names if n.endswith("/pgmnemo.control") or n.endswith("pgmnemo.control")]
if ctrl_hits != [f"pgmnemo-{v}/extension/pgmnemo.control"]:
    errors.append(f"pgmnemo.control must be at exactly 'pgmnemo-{v}/extension/pgmnemo.control', found: {ctrl_hits}")

# 4) Forbidden entries — the v0.7.1 double-nest + dev/build/test cruft.
FORBIDDEN_SUBSTR = ["extension/extension", ".git", "__pycache__"]
FORBIDDEN_SUFFIX = [".o", ".so", ".bak"]
# dev/test SQL + golden outputs must not ship.
FORBIDDEN_RE = [
    re.compile(r".*_smoke\.sql$"),
    re.compile(r".*/test_[^/]*\.sql$"),
    re.compile(r".*/stress_[^/]*\.sql$"),
    re.compile(r".*/expected/.*\.out$"),
]
for n in names:
    for sub in FORBIDDEN_SUBSTR:
        if sub in n:
            errors.append(f"forbidden path component '{sub}' in: {n}")
    for suf in FORBIDDEN_SUFFIX:
        if n.endswith(suf):
            errors.append(f"forbidden file type '{suf}' in: {n}")
    for rx in FORBIDDEN_RE:
        if rx.match(n):
            errors.append(f"forbidden dev/test asset in dist: {n}")

# 5) META.json sanity.
try:
    meta = json.loads(z.read(f"pgmnemo-{v}/META.json").decode())
    if meta.get("version") != v:
        errors.append(f"bundle META.json version={meta.get('version')!r}, expected {v!r}")
except Exception as e:
    errors.append(f"could not parse bundled META.json: {e}")

if errors:
    print("ERROR: dist-shape validation FAILED:", file=sys.stderr)
    for e in errors:
        print(f"  - {e}", file=sys.stderr)
    sys.exit(1)
print(f"[build] dist-shape OK — {len(names)} entries, single-level extension/, no cruft")
PYEOF

echo "[build] cleaning intermediate directory..."
rm -rf "$BUNDLE_DIR"

# Final size + checksum
SIZE=$(stat -f%z "$BUNDLE_ZIP" 2>/dev/null || stat -c%s "$BUNDLE_ZIP")
echo "[build] ✓ $BUNDLE_ZIP ($SIZE bytes)"
echo "[build] next: tag + push, or upload manually with:"
echo "        curl -X POST -F \"archive=@$BUNDLE_ZIP\" -u \"\$PGXN_USERNAME:\$PGXN_PASSWORD\" https://manager.pgxn.org/upload"
