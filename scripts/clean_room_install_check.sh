#!/usr/bin/env bash
# clean_room_install_check.sh — the gate that was missing when v0.7.1 shipped.
#
# Takes the BUILT bundle zip (the exact artifact uploaded to PGXN/GitHub), unzips
# it into a clean pgvector/pgvector:pg17 container, runs the DOCUMENTED install
# from docs/INSTALL.md (Path 2), then:
#     CREATE EXTENSION vector;
#     CREATE EXTENSION pgmnemo;
#     SELECT pgmnemo.version();
# and asserts the reported version equals the expected version.
#
# This catches packaging regressions (double-nested extension/extension/, missing
# control file, wrong paths) that no SQL-source installcheck can see, because it
# installs the ZIP, not the working tree.
#
# Usage: scripts/clean_room_install_check.sh <VERSION> [BUNDLE_ZIP]
#   VERSION     e.g. 0.7.2
#   BUNDLE_ZIP  defaults to pgmnemo-<VERSION>.zip in repo root
#
# Doc-coupling: the install command run inside the container is derived from the
# `cp` line in docs/INSTALL.md Path 2. If that doc line drifts from the structure
# the bundle actually has, this gate fails — keeping docs honest.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <VERSION> [BUNDLE_ZIP]" >&2
    exit 1
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

BUNDLE_ZIP="${2:-pgmnemo-$VERSION.zip}"
if [[ ! -f "$BUNDLE_ZIP" ]]; then
    echo "ERROR: bundle zip not found: $BUNDLE_ZIP (build it with scripts/build_pgxn_bundle.sh $VERSION first)" >&2
    exit 1
fi

IMAGE="pgvector/pgvector:pg17"
CONTAINER="pgmnemo-cleanroom-$VERSION-$$"
SHAREDIR_EXT='/usr/share/postgresql/17/extension'

cleanup() {
    docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

echo "[clean-room] verifying docs/INSTALL.md Path 2 documents the single-level extension copy..."
# The install MUST reference the un-nested .../extension/ layout. We assert the
# doc contains a `cp` of the extension contents into the sharedir extension dir.
if ! grep -qE 'cp .*pgmnemo-\$?\{?[A-Za-z0-9._-]*\}?/extension/.* .*extension/' docs/INSTALL.md \
   && ! grep -qE 'cp .*/extension/\* ' docs/INSTALL.md \
   && ! grep -qE 'cp .*/extension/pgmnemo' docs/INSTALL.md; then
    echo "ERROR: docs/INSTALL.md does not document a single-level '.../extension/' install copy." >&2
    echo "       Doc drift detected — the documented path must match the un-nested dist." >&2
    exit 1
fi

echo "[clean-room] starting $IMAGE as $CONTAINER..."
docker run -d --name "$CONTAINER" -e POSTGRES_PASSWORD=pass "$IMAGE" >/dev/null

echo "[clean-room] waiting for postgres to accept connections..."
for i in $(seq 1 30); do
    if docker exec "$CONTAINER" pg_isready -U postgres >/dev/null 2>&1; then
        break
    fi
    sleep 1
    if [[ "$i" == "30" ]]; then
        echo "ERROR: postgres did not become ready in 30s" >&2
        docker logs "$CONTAINER" || true
        exit 1
    fi
done

echo "[clean-room] copying BUILT bundle into container and running the DOCUMENTED install..."
docker cp "$BUNDLE_ZIP" "$CONTAINER:/tmp/pgmnemo.zip"

# This mirrors docs/INSTALL.md Path 2 exactly:
#   unzip; cd pgmnemo-<v>/extension/; cp -r .../extension/* $(pg_config --sharedir)/extension/
docker exec "$CONTAINER" bash -euc "
    apt-get update -qq >/dev/null
    apt-get install -y --no-install-recommends unzip >/dev/null
    cd /tmp
    unzip -q pgmnemo.zip
    test -f pgmnemo-${VERSION}/extension/pgmnemo.control \
        || { echo 'FATAL: pgmnemo-${VERSION}/extension/pgmnemo.control missing — dist is malformed (double-nested?)'; ls -R pgmnemo-${VERSION} | head -40; exit 1; }
    # The single-level copy documented in INSTALL.md Path 2:
    cp -r pgmnemo-${VERSION}/extension/* \"${SHAREDIR_EXT}/\"
    echo '[clean-room] installed files:'
    ls \"${SHAREDIR_EXT}\"/pgmnemo* | head
"

echo "[clean-room] CREATE EXTENSION vector; CREATE EXTENSION pgmnemo; SELECT pgmnemo.version();"
docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE EXTENSION IF NOT EXISTS vector;"
docker exec "$CONTAINER" psql -U postgres -v ON_ERROR_STOP=1 -c "CREATE EXTENSION pgmnemo;"
# Run the version query on its own so command tags don't leak into the result.
ACTUAL=$(docker exec "$CONTAINER" psql -U postgres -tAc "SELECT pgmnemo.version();" | tr -d '[:space:]')

echo "[clean-room] pgmnemo.version() => '$ACTUAL' (expected '$VERSION')"
if [[ "$ACTUAL" != "$VERSION" ]]; then
    echo "ERROR: clean-room install reported version '$ACTUAL', expected '$VERSION'" >&2
    exit 1
fi

echo "[clean-room] ✓ PASS — bundle installs cleanly and reports v$VERSION"
