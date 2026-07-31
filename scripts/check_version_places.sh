#!/usr/bin/env bash
# Gate: every version-bearing file agrees with extension/pgmnemo.control.
#
# There are six of them and they are easy to miscount. 0.16.0 shipped with
# META.provides.*.file still pointing at the previous flat install (caught by the
# packaging gate); 0.16.1 was tagged with pgmnemo_mcp/pyproject.toml still on the
# previous version (caught by CI pre-flight). Both were found after the tag was
# pushed. This finds them before.
set -euo pipefail
cd "$(dirname "$0")/.."
V=$(grep -oE "default_version = '([0-9.]+)'" extension/pgmnemo.control | grep -oE "[0-9.]+")
[ -n "$V" ] || { echo "cannot read default_version"; exit 1; }
fail=0
check() {  # $1=label $2=actual
    if [ "$2" != "$V" ]; then echo "  MISMATCH  $1: '$2' (expected '$V')"; fail=1
    else echo "  ok        $1: $2"; fi
}
echo "G-VERSION-PLACES: target $V"
check "extension/pgmnemo.control default_version" "$V"
check "Makefile EXTVERSION" "$(grep -oE '^EXTVERSION[[:space:]]*=[[:space:]]*[0-9.]+' Makefile | grep -oE '[0-9.]+$' || echo MISSING)"
check "META.json version" "$(python3 -c "import json;print(json.load(open('META.json'))['version'])")"
check "META.provides file path" "$(python3 -c "
import json,re
p=json.load(open('META.json'))['provides']
f=list(p.values())[0]['file']
m=re.search(r'([0-9]+\.[0-9]+\.[0-9]+)\.sql\$',f); print(m.group(1) if m else 'UNPARSED')")"
check "pyproject.toml version" "$(grep -m1 -oE '^version = \"[0-9.]+\"' pyproject.toml | grep -oE '[0-9.]+')"
check "pgmnemo_mcp/pyproject.toml version" "$(grep -m1 -oE '^version = \"[0-9.]+\"' pgmnemo_mcp/pyproject.toml | grep -oE '[0-9.]+')"
[ -f "extension/pgmnemo--$V.sql" ] && echo "  ok        flat install extension/pgmnemo--$V.sql" || { echo "  MISSING   extension/pgmnemo--$V.sql"; fail=1; }
[ -f "benchmarks/gate/v$V.json" ] && echo "  ok        bench gate benchmarks/gate/v$V.json" || { echo "  MISSING   benchmarks/gate/v$V.json"; fail=1; }
[ $fail -eq 0 ] && { echo "G-VERSION-PLACES: PASS"; exit 0; } || { echo "G-VERSION-PLACES: FAIL"; exit 1; }
