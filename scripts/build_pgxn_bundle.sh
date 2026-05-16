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
mkdir -p "$BUNDLE_DIR"
cp -r extension/ "$BUNDLE_DIR/extension/"
cp Makefile README.md LICENSE CHANGELOG.md META.json "$BUNDLE_DIR/"

echo "[build] creating zip..."
zip -rq "$BUNDLE_ZIP" "$BUNDLE_DIR/"

echo "[build] post-build verification..."
python3 - <<PYEOF || exit 1
import json, zipfile, sys
v = "$VERSION"
z = zipfile.ZipFile("$BUNDLE_ZIP")
names = z.namelist()
required = [
    f"pgmnemo-{v}/META.json",
    f"pgmnemo-{v}/extension/pgmnemo.control",
    f"pgmnemo-{v}/extension/pgmnemo--{v}.sql",
    f"pgmnemo-{v}/README.md",
    f"pgmnemo-{v}/LICENSE",
    f"pgmnemo-{v}/CHANGELOG.md",
]
missing = [r for r in required if r not in names]
if missing:
    for m in missing:
        print(f"ERROR: bundle missing {m}", file=sys.stderr)
    sys.exit(1)
meta = json.loads(z.read(f"pgmnemo-{v}/META.json").decode())
assert meta["version"] == v, f"bundle META.json version mismatch"
print(f"[build] bundle OK — {len(names)} files, {z.fp.tell() if hasattr(z, 'fp') and z.fp else 'N/A'} bytes")
PYEOF

echo "[build] cleaning intermediate directory..."
rm -rf "$BUNDLE_DIR"

# Final size + checksum
SIZE=$(stat -f%z "$BUNDLE_ZIP" 2>/dev/null || stat -c%s "$BUNDLE_ZIP")
echo "[build] ✓ $BUNDLE_ZIP ($SIZE bytes)"
echo "[build] next: tag + push, or upload manually with:"
echo "        curl -X POST -F \"archive=@$BUNDLE_ZIP\" -u \"\$PGXN_USERNAME:\$PGXN_PASSWORD\" https://manager.pgxn.org/upload"
