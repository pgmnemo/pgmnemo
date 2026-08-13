#!/usr/bin/env bash
# G-UPGRADE-PARITY — an upgraded install must be indistinguishable from a fresh one.
#
# Two defects shipped past the regression suite because pg_regress creates the
# extension directly at the target version, so ALTER EXTENSION UPDATE is a no-op
# there and the upgrade path is never exercised:
#   - a truncated COMMENT literal made the 0.16.1 -> 0.17.0 script unparseable;
#   - superseded recall_lessons / recall_hybrid overloads were never dropped, so
#     on every upgraded install the short call — the one published in the README
#     as the "see it work" example — failed with "function is not unique".
#
# This gate builds both installs and diffs their function signatures.
#
# Usage: check_upgrade_parity.sh <from_version> <to_version>
set -euo pipefail

FROM="${1:?usage: check_upgrade_parity.sh <from_version> <to_version>}"
TO="${2:?usage: check_upgrade_parity.sh <from_version> <to_version>}"
DB_FRESH="pgmnemo_parity_fresh_$$"
DB_UPG="pgmnemo_parity_upg_$$"

cleanup() {
    psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB_FRESH" >/dev/null 2>&1 || true
    psql -q -d postgres -c "DROP DATABASE IF EXISTS $DB_UPG" >/dev/null 2>&1 || true
}
trap cleanup EXIT

SIGS="SELECT p.oid::regprocedure::text FROM pg_proc p
      JOIN pg_namespace n ON n.oid = p.pronamespace
      WHERE n.nspname = 'pgmnemo' ORDER BY 1"

psql -q -d postgres -c "CREATE DATABASE $DB_FRESH" >/dev/null
psql -q -d "$DB_FRESH" -c "CREATE EXTENSION vector; CREATE EXTENSION pgmnemo VERSION '$TO';" >/dev/null

psql -q -d postgres -c "CREATE DATABASE $DB_UPG" >/dev/null
psql -q -d "$DB_UPG" -c "CREATE EXTENSION vector; CREATE EXTENSION pgmnemo VERSION '$FROM';" >/dev/null
psql -q -d "$DB_UPG" -c "ALTER EXTENSION pgmnemo UPDATE TO '$TO';" >/dev/null

psql -tA -d "$DB_FRESH" -c "$SIGS" > "/tmp/parity_fresh_$$.txt"
psql -tA -d "$DB_UPG"   -c "$SIGS" > "/tmp/parity_upg_$$.txt"

if diff -u "/tmp/parity_fresh_$$.txt" "/tmp/parity_upg_$$.txt" > "/tmp/parity_diff_$$.txt"; then
    echo "G-UPGRADE-PARITY: PASS — $FROM -> $TO produces the same objects as a fresh $TO install."
    rm -f "/tmp/parity_fresh_$$.txt" "/tmp/parity_upg_$$.txt" "/tmp/parity_diff_$$.txt"
    exit 0
fi

echo "G-UPGRADE-PARITY: FAIL — upgraded install differs from a fresh one."
echo "  '-' present only after a fresh install, '+' left behind by the upgrade path."
sed -n '3,40p' "/tmp/parity_diff_$$.txt"
echo
echo "  A signature left behind by the upgrade is how short calls become ambiguous."
echo "  Drop it in the upgrade script; do not change the flat install."
rm -f "/tmp/parity_fresh_$$.txt" "/tmp/parity_upg_$$.txt" "/tmp/parity_diff_$$.txt"
exit 1
