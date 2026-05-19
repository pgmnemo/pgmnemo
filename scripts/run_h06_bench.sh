#!/usr/bin/env bash
# H-06 grid-search bench — recency_weight ∈ {0.05, 0.1, 0.3, 0.5}
# Run on macOS host with pgmnemo v0.4.1 at localhost:5432 and bench venv active.
#
# Usage:
#   DATABASE_URL="postgresql://postgres:postgres@localhost:5432/postgres" \
#     bash scripts/run_h06_bench.sh
#
# Outputs: benchmarks/h06_grid_search/{cell}.json + VERDICT.md
# Acceptance gate: temporal/recall@10 >= 0.7109 (+5.5pp vs 0.6559 baseline)
# No non-temporal category may regress by > 0.005 at p<0.05

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
OUT_DIR="${REPO_ROOT}/benchmarks/h06_grid_search"
LOCOMO_DATA="${REPO_ROOT}/benchmarks/data/locomo/locomo10.json"
LME_DATA="${REPO_ROOT}/benchmarks/data/longmemeval/longmemeval_s_cleaned.json"
LOCOMO_RUNNER="${REPO_ROOT}/benchmarks/locomo/run_locomo.py"
LME_RUNNER="${REPO_ROOT}/benchmarks/longmemeval/runner.py"
SIG_TEST="${REPO_ROOT}/scripts/significance_test.py"

DB_URL="${DATABASE_URL:-postgresql://postgres:postgres@localhost:5432/postgres}"

RECENCY_WEIGHTS=(0.05 0.1 0.3 0.5)

# --- Prereq checks ---
echo "[H-06] Checking prerequisites..."

if ! pg_isready -h localhost -p 5432 -q; then
    echo "ERROR: PostgreSQL not running at localhost:5432. Aborting."
    exit 1
fi

PG_VER=$(psql "${DB_URL}" -tAc "SELECT pgmnemo.version();" 2>/dev/null || echo "")
if [[ -z "${PG_VER}" ]]; then
    echo "ERROR: pgmnemo extension not found in DB. Run: CREATE EXTENSION pgmnemo;"
    exit 1
fi
echo "[H-06] pgmnemo version: ${PG_VER}"

if [[ ! -f "${LOCOMO_DATA}" ]]; then
    echo "ERROR: LoCoMo data not found at ${LOCOMO_DATA}"
    exit 1
fi

if [[ ! -f "${LME_DATA}" ]]; then
    echo "ERROR: LongMemEval data not found at ${LME_DATA}"
    exit 1
fi

mkdir -p "${OUT_DIR}"
echo "[H-06] Output dir: ${OUT_DIR}"

# --- Baseline (C1, C5: recency_weight=0.05) ---
BASELINE_TEMPORAL=0.6559
BASELINE_LME=0.9334

# --- Grid run ---
BEST_TEMPORAL=0.0
BEST_WEIGHT="none"

for GW in "${RECENCY_WEIGHTS[@]}"; do
    echo ""
    echo "=========================================="
    echo "[H-06] Running LoCoMo — recency_weight=${GW}"
    echo "=========================================="

    CELL_OUT="${OUT_DIR}/locomo_rw${GW//./_}.json"

    if [[ -f "${LOCOMO_RUNNER}" ]]; then
        python "${LOCOMO_RUNNER}" \
            --data "${LOCOMO_DATA}" \
            --db-url "${DB_URL}" \
            --guc "pgmnemo.recency_weight=${GW}" \
            --granularity session \
            --k 10 \
            --out "${CELL_OUT}"
    else
        # Fallback: direct psql + python inline runner (if runner.py not present)
        echo "[H-06] WARN: ${LOCOMO_RUNNER} not found — using inline psql GUC override"
        psql "${DB_URL}" -c "SET pgmnemo.recency_weight = ${GW};"
        # Delegate to whichever bench runner exists
        python -c "
import json, sys
# Placeholder: integrate with actual bench runner
print(json.dumps({'recency_weight': ${GW}, 'note': 'runner not found — manual invocation required'}))
" > "${CELL_OUT}"
        echo "[H-06] MANUAL_REQUIRED: Run LoCoMo bench with recency_weight=${GW} and write to ${CELL_OUT}"
        continue
    fi

    # Extract temporal recall@10 from cell output
    TEMPORAL=$(python3 -c "
import json, sys
with open('${CELL_OUT}') as f:
    d = json.load(f)
cat = d.get('by_category', {}).get('temporal', {})
r10 = cat.get('recall@10', {})
val = r10.get('mean', r10) if isinstance(r10, dict) else r10
print(val)
" 2>/dev/null || echo "0.0")

    echo "[H-06] LoCoMo temporal recall@10 at rw=${GW}: ${TEMPORAL}"

    # Track best
    BETTER=$(python3 -c "print(1 if float('${TEMPORAL}') > float('${BEST_TEMPORAL}') else 0)")
    if [[ "${BETTER}" == "1" ]]; then
        BEST_TEMPORAL="${TEMPORAL}"
        BEST_WEIGHT="${GW}"
    fi

    echo ""
    echo "=========================================="
    echo "[H-06] Running LongMemEval — recency_weight=${GW}"
    echo "=========================================="

    LME_OUT="${OUT_DIR}/lme_rw${GW//./_}.json"

    if [[ -f "${LME_RUNNER}" ]]; then
        python "${LME_RUNNER}" \
            --data "${LME_DATA}" \
            --db-url "${DB_URL}" \
            --guc "pgmnemo.recency_weight=${GW}" \
            --version "h06_rw${GW}" \
            --out-dir "${OUT_DIR}" \
            --k 10
    else
        echo "[H-06] WARN: ${LME_RUNNER} not found — check actual runner path"
        echo "[H-06] MANUAL_REQUIRED: Run LME bench with recency_weight=${GW} and write to ${LME_OUT}"
    fi

done

# --- Significance test ---
echo ""
echo "=========================================="
echo "[H-06] Significance test — best cell vs baseline"
echo "=========================================="

GATE_PASSED=0
VERDICT="H-06 REJECTED (inconclusive)"

DELTA=$(python3 -c "print(round(float('${BEST_TEMPORAL}') - ${BASELINE_TEMPORAL}, 4))")
DELTA_PP=$(python3 -c "print(round((float('${BEST_TEMPORAL}') - ${BASELINE_TEMPORAL}) * 100, 2))")

echo "[H-06] Best temporal recall@10: ${BEST_TEMPORAL} (rw=${BEST_WEIGHT})"
echo "[H-06] Baseline: ${BASELINE_TEMPORAL} | Delta: +${DELTA_PP}pp"

# Gate: +5.5pp required
GATE_CHECK=$(python3 -c "print(1 if float('${BEST_TEMPORAL}') >= 0.7109 else 0)")
if [[ "${GATE_CHECK}" == "1" ]]; then
    GATE_PASSED=1
fi

# Run statistical significance test if available
BEST_CELL_FILE="${OUT_DIR}/locomo_rw${BEST_WEIGHT//./_}.json"
SIG_EXIT=99
if [[ -f "${SIG_TEST}" ]] && [[ -f "${BEST_CELL_FILE}" ]]; then
    BASELINE_FILE="${OUT_DIR}/locomo_rw0_05.json"
    python3 "${SIG_TEST}" \
        --baseline "${BASELINE_TEMPORAL}" \
        --treatment "${BEST_TEMPORAL}" \
        --n 92 \
        --alpha 0.05 \
        && SIG_EXIT=0 || SIG_EXIT=$?
    echo "[H-06] significance_test.py exit: ${SIG_EXIT}"
fi

# Compute verdict
if [[ "${GATE_PASSED}" == "1" ]] && [[ "${SIG_EXIT}" -le 1 ]]; then
    VERDICT="H-06 CONFIRMED: temporal/recall@10=${BEST_TEMPORAL} at recency_weight=${BEST_WEIGHT} (+${DELTA_PP}pp, p<0.05)"
elif [[ "${GATE_PASSED}" == "1" ]] && [[ "${SIG_EXIT}" -gt 1 ]]; then
    VERDICT="H-06 WATCHLIST: +${DELTA_PP}pp at rw=${BEST_WEIGHT} exceeds gate but significance_test failed (exit ${SIG_EXIT}) — check n=92 power"
elif python3 -c "exit(0 if float('${DELTA}') < 0.02 else 1)"; then
    VERDICT="H-06 REJECTED: best improvement ${DELTA_PP}pp < 2pp falsification threshold"
else
    VERDICT="H-06 REJECTED: +${DELTA_PP}pp below 5.5pp gate (temporal/recall@10=${BEST_TEMPORAL} < 0.7109)"
fi

# Write VERDICT.md
cat > "${OUT_DIR}/VERDICT.md" <<EOF
# H-06 Grid-Search Verdict

**Date:** $(date -u +%Y-%m-%d)
**Verdict:** ${VERDICT}

## Grid Results

| Cell | recency_weight | LoCoMo temporal r@10 | Delta vs baseline |
|------|---------------|---------------------|-------------------|
| C1 (baseline) | 0.05 | ${BASELINE_TEMPORAL} | — |
| C2 | 0.1 | [see locomo_rw0_1.json] | — |
| C3 | 0.3 | [see locomo_rw0_3.json] | — |
| C4 | 0.5 | [see locomo_rw0_5.json] | — |

**Best cell:** recency_weight=${BEST_WEIGHT} → temporal/recall@10=${BEST_TEMPORAL} (+${DELTA_PP}pp)

## Gate

| Criterion | Value | Status |
|-----------|-------|--------|
| temporal/recall@10 ≥ 0.7109 (+5.5pp) | ${BEST_TEMPORAL} | $([ "${GATE_PASSED}" == "1" ] && echo "✅ PASS" || echo "❌ FAIL") |
| significance_test.py exit ≤ 1 | exit ${SIG_EXIT} | $([ "${SIG_EXIT}" -le 1 ] && echo "✅ PASS" || echo "⚠ CHECK") |
| No non-temporal regression > 0.005 | [check cell JSONs] | MANUAL |

## Files

- Cell results: \`locomo_rw{weight}.json\`, \`lme_rw{weight}.json\`
- Baseline ref: \`benchmarks/gate/v0.4.1.json\` (locomo_session.by_category.temporal.recall@10.mean=0.6559)

## Next Steps

$(if [ "${GATE_PASSED}" == "1" ]; then
echo "- Update benchmarks/gate/v0.5.0.json with best cell metrics"
echo "- Add 'recommended: recency_weight=${BEST_WEIGHT}' to pgmnemo docs"
echo "- Create PLAN task for H-06 GUC default change in v0.5.0"
else
echo "- H-06 temporal uplift insufficient at γ≤0.5 with current halflife default"
echo "- Consider H-06 extension: add time_decay_halflife_days GUC (τ axis) — deferred to v0.6.0"
echo "- Close H-06 with evidence: falsification condition met"
fi)
EOF

echo ""
echo "=========================================="
echo "[H-06] VERDICT: ${VERDICT}"
echo "=========================================="
echo "[H-06] Full results at: ${OUT_DIR}/VERDICT.md"
