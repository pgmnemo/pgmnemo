#!/usr/bin/env bash
# Installs pgmnemo extension from source into the running container.
#
# NOTE: v0.1.0 is a source-build release. A pre-built Docker image is planned
# for v0.2.0, at which point this script will not be needed.
#
# This script runs once as part of docker-entrypoint-initdb.d on first start.
# It requires git and build tools to be available in the image; the
# pgvector/pgvector:pg17 image ships with them.

set -euo pipefail

REPO_URL="https://github.com/pgmnemo/pgmnemo.git"
CLONE_DIR="/tmp/pgmnemo-src"
VERSION="v0.3.0"

echo "[pgmnemo] Cloning $VERSION from $REPO_URL ..."
git clone --depth 1 --branch "$VERSION" "$REPO_URL" "$CLONE_DIR"

echo "[pgmnemo] Building and installing extension ..."
cd "$CLONE_DIR/extension"
make PG_CONFIG="$(which pg_config)"
make install PG_CONFIG="$(which pg_config)"

echo "[pgmnemo] Creating extension in database $POSTGRES_DB ..."
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE EXTENSION IF NOT EXISTS vector;
    CREATE EXTENSION IF NOT EXISTS pgmnemo CASCADE;
EOSQL

echo "[pgmnemo] Installation complete."
