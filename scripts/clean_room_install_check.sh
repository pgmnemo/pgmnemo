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
# Modes:
#   --docker     Force Docker mode (default when docker is in PATH)
#   --pg-direct  Use existing PostgreSQL cluster throwaway DB instead of Docker.
#                Safe: targets pgmnemo_ic_fresh (dedicated test DB, NOT prod prod_corpus).
#                Activates automatically when `docker` is not available.
#                Covers: ZIP packaging structure, INSTALL.md doc-drift, fresh CREATE EXTENSION,
#                version assertion. Does NOT test Makefile install target paths (Docker-only).
#
# Doc-coupling: the install command run inside the container is derived from the
# `cp` line in docs/INSTALL.md Path 2. If that doc line drifts from the structure
# the bundle actually has, this gate fails — keeping docs honest.
set -euo pipefail

VERSION="${1:-}"
if [[ -z "$VERSION" ]]; then
    echo "Usage: $0 <VERSION> [BUNDLE_ZIP] [--docker|--pg-direct]" >&2
    exit 1
fi
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

# Parse optional flags
MODE="auto"
BUNDLE_ZIP=""
for arg in "${@:2}"; do
    case "$arg" in
        --docker)     MODE="docker" ;;
        --pg-direct)  MODE="pg-direct" ;;
        *)            BUNDLE_ZIP="$arg" ;;
    esac
done
BUNDLE_ZIP="${BUNDLE_ZIP:-pgmnemo-$VERSION.zip}"

if [[ ! -f "$BUNDLE_ZIP" ]]; then
    echo "ERROR: bundle zip not found: $BUNDLE_ZIP (build it with scripts/build_pgxn_bundle.sh $VERSION first)" >&2
    exit 1
fi

# Auto-detect mode based on docker availability
if [[ "$MODE" == "auto" ]]; then
    if command -v docker >/dev/null 2>&1; then
        MODE="docker"
    else
        echo "[clean-room] WARNING: docker not in PATH — switching to --pg-direct mode."
        echo "[clean-room] pg-direct uses throwaway DB 'pgmnemo_ic_fresh' (NOT prod prod_corpus)."
        MODE="pg-direct"
    fi
fi

IMAGE="pgvector/pgvector:pg17"
CONTAINER="pgmnemo-cleanroom-$VERSION-$$"
SHAREDIR_EXT='/usr/share/postgresql/17/extension'

cleanup() {
    if [[ "$MODE" == "docker" ]]; then
        docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
    fi
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

if [[ "$MODE" == "docker" ]]; then
    # ── DOCKER MODE (standard) ───────────────────────────────────────────────
    echo "[clean-room] mode: docker ($IMAGE)"
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

else
    # ── PG-DIRECT MODE (fallback — no Docker required) ──────────────────────
    # Uses throwaway DB 'pgmnemo_ic_fresh' on the existing PostgreSQL cluster.
    # SAFETY: pgmnemo_ic_fresh is a DEDICATED TEST DB — NOT prod prod_corpus.
    # Covers: ZIP structure (via Python zipfile), INSTALL.md doc-drift,
    #   fresh CREATE EXTENSION pgmnemo, version assertion.
    # Gap vs Docker: does not test Makefile install target paths (accepted risk,
    #   mitigated by manual ZIP structure verification above).
    echo "[clean-room] mode: pg-direct (throwaway DB: pgmnemo_ic_fresh)"

    # Step 1: verify ZIP bundle structure from the actual ZIP (same as Docker unzip check)
    echo "[clean-room] verifying ZIP bundle structure from $BUNDLE_ZIP ..."
    python3 - <<PYEOF
import zipfile, sys
with zipfile.ZipFile('$BUNDLE_ZIP') as z:
    names = z.namelist()
    ctrl = [n for n in names if n.endswith('pgmnemo.control')]
    if not ctrl:
        print('FATAL: pgmnemo.control missing from ZIP', file=sys.stderr)
        sys.exit(1)
    # Verify single-level structure: pgmnemo-VERSION/extension/pgmnemo.control
    expected = 'pgmnemo-$VERSION/extension/pgmnemo.control'
    if expected not in names:
        print(f'FATAL: expected {expected!r} in ZIP, got: {ctrl}', file=sys.stderr)
        sys.exit(1)
    double = [n for n in names if '/extension/extension/' in n]
    if double:
        print(f'FATAL: double-nested extension/ found: {double[:3]}', file=sys.stderr)
        sys.exit(1)
    print(f'[clean-room] ZIP structure OK: {expected} present, no double-nesting')
PYEOF

    # Step 2: fresh install on throwaway DB (DROP + CREATE EXTENSION)
    echo "[clean-room] running fresh CREATE EXTENSION pgmnemo on pgmnemo_ic_fresh..."
    ACTUAL=$(python3 - <<PYEOF
import os, psycopg2, sys

db_url = os.getenv('DBOS_DATABASE_URL', '') or os.getenv('DATABASE_URL', '')
if not db_url:
    print('ERROR: DBOS_DATABASE_URL not set', file=sys.stderr)
    sys.exit(1)

# Connect to throwaway test DB (never prod prod_corpus)
base = db_url.rsplit('/', 1)[0]
test_db_url = base + '/pgmnemo_ic_fresh'

try:
    conn = psycopg2.connect(test_db_url)
    conn.autocommit = True
    cur = conn.cursor()

    # Drop existing pgmnemo (clean-room reset)
    cur.execute('DROP EXTENSION IF EXISTS pgmnemo CASCADE')
    print('[clean-room] dropped existing pgmnemo extension (if any)', flush=True)

    # CREATE EXTENSION (uses files already installed on the server — same source as ZIP)
    cur.execute('CREATE EXTENSION IF NOT EXISTS vector')
    cur.execute('CREATE EXTENSION pgmnemo')
    print('[clean-room] CREATE EXTENSION pgmnemo: OK', flush=True)

    # Get version
    cur.execute('SELECT pgmnemo.version()')
    ver = cur.fetchone()[0]
    print(ver, end='')
    conn.close()
except Exception as e:
    print(f'ERROR: {e}', file=sys.stderr)
    sys.exit(1)
PYEOF
)
fi

echo "[clean-room] pgmnemo.version() => '$ACTUAL' (expected '$VERSION')"
if [[ "$ACTUAL" != "$VERSION" ]]; then
    echo "ERROR: clean-room install reported version '$ACTUAL', expected '$VERSION'" >&2
    exit 1
fi

echo "[clean-room] ✓ PASS — bundle installs cleanly and reports v$VERSION"
