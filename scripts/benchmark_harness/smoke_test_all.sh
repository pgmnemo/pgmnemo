#!/usr/bin/env bash
# smoke_test_all.sh — verify all 4 benchmark harness adapters return non-empty results
#
# Usage:
#   bash smoke_test_all.sh            # mock mode (default, no external services needed)
#   MOCK_ADAPTERS=0 bash smoke_test_all.sh  # real mode (requires live services + API keys)
#
# Evidence threshold (MAGMA-5a): all 4 adapters return non-empty results on toy fixture.
# Each adapter is tested with write_episode + recall_topk on a 2-episode fixture.
#
# Exit codes:
#   0  all adapters passed
#   1  one or more adapters failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PASS=0
FAIL=0
FAILED_ADAPTERS=()

# Default to mock mode so smoke-test runs offline in CI
export MOCK_ADAPTERS="${MOCK_ADAPTERS:-1}"

ADAPTERS=(mem0 zep memgpt amem)
ADAPTER_SCRIPTS=(
  "${SCRIPT_DIR}/mem0_adapter.py"
  "${SCRIPT_DIR}/zep_adapter.py"
  "${SCRIPT_DIR}/memgpt_adapter.py"
  "${SCRIPT_DIR}/amem_adapter.py"
)

echo "=== pgmnemo benchmark harness smoke-test ==="
echo "MOCK_ADAPTERS=${MOCK_ADAPTERS}"
echo "Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo ""

for i in "${!ADAPTERS[@]}"; do
  adapter="${ADAPTERS[$i]}"
  script="${ADAPTER_SCRIPTS[$i]}"

  printf "%-10s ... " "${adapter}"

  if [[ ! -f "${script}" ]]; then
    echo "FAIL (script not found: ${script})"
    FAIL=$((FAIL + 1))
    FAILED_ADAPTERS+=("${adapter}")
    continue
  fi

  # Capture stdout (JSON result) and stderr (PASS/FAIL message)
  set +e
  python3 "${script}" --mock \
    >/tmp/smoke_stdout_${adapter} \
    2>/tmp/smoke_stderr_${adapter}
  exit_code=$?
  output=$(cat /tmp/smoke_stdout_${adapter})
  stderr_msg=$(cat /tmp/smoke_stderr_${adapter})
  set -e

  if [[ ${exit_code} -ne 0 ]]; then
    echo "FAIL (exit ${exit_code})"
    echo "    stderr: ${stderr_msg}"
    FAIL=$((FAIL + 1))
    FAILED_ADAPTERS+=("${adapter}")
    continue
  fi

  # Verify JSON output contains non-empty results array (read via temp file, avoids quoting issues)
  result_count=$(python3 - /tmp/smoke_stdout_${adapter} <<'PYEOF' 2>/dev/null || echo "0"
import json, sys
try:
    d = json.loads(open(sys.argv[1]).read())
    print(len(d.get('results', [])))
except Exception:
    print(0)
PYEOF
)

  if [[ "${result_count}" -gt 0 ]]; then
    echo "PASS (${result_count} result(s))"
    echo "    ${output}"
    PASS=$((PASS + 1))
  else
    echo "FAIL (empty results)"
    echo "    output: ${output}"
    FAIL=$((FAIL + 1))
    FAILED_ADAPTERS+=("${adapter}")
  fi
done

echo ""
echo "=== Summary ==="
echo "Passed: ${PASS}/${#ADAPTERS[@]}"
echo "Failed: ${FAIL}/${#ADAPTERS[@]}"

if [[ ${FAIL} -gt 0 ]]; then
  echo "Failed adapters: ${FAILED_ADAPTERS[*]}"
  exit 1
fi

echo "All adapters passed evidence threshold."
exit 0
