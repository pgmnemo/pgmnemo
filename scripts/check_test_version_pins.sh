#!/usr/bin/env bash
# Gate: no test file may pin an extension version other than default_version.
#
# Why this is a gate and not a lesson. Every release, ~36 test files carry a
# literal `ALTER EXTENSION pgmnemo UPDATE TO '<prev>'`. Bump default_version and
# each of them tries to DOWNGRADE, which Postgres refuses — 28 of 54 tests failed
# this way on 0.16.0, and the same trap fired again on 0.16.1 even though the
# lesson had been written down. Written-down procedure does not reach the person
# who needs it; a gate does.
set -euo pipefail
cd "$(dirname "$0")/.."
WANT=$(grep -oE "default_version = '([0-9.]+)'" extension/pgmnemo.control | grep -oE "[0-9.]+")
[ -n "$WANT" ] || { echo "cannot read default_version from extension/pgmnemo.control"; exit 1; }
BAD=$(grep -rnoE "UPDATE TO '[0-9.]+'" extension/sql tests/sql 2>/dev/null | grep -v "UPDATE TO '$WANT'" || true)
if [ -n "$BAD" ]; then
    echo "G-TEST-VERSION-PIN: FAIL — test files pin a version other than $WANT:"
    echo "$BAD" | head -20
    echo "Fix: sed -i \"s/UPDATE TO '<old>'/UPDATE TO '$WANT'/g\" over extension/sql tests/sql (and the matching expected/*.out NOTICE lines)."
    exit 1
fi
echo "G-TEST-VERSION-PIN: PASS — all test pins match default_version $WANT."
