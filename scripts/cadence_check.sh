#!/usr/bin/env bash
# Weekly GitHub maturity cadence (docs/GITHUB_TACTICS.md §6)
# Usage: ./scripts/cadence_check.sh [--day mon|wed|fri|all] [--out <path>]
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TODAY="$(date +%Y-%m-%d)"
DOW="$(date +%u)"

DAY_ARG=""; OUT_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --day) DAY_ARG="$2"; shift 2 ;;
    --out) OUT_ARG="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 1 ;;
  esac
done

if   [[ -n "$DAY_ARG" ]];   then RUN_DAY="$DAY_ARG"
elif [[ "$DOW" == "1" ]];   then RUN_DAY="mon"
elif [[ "$DOW" == "3" ]];   then RUN_DAY="wed"
elif [[ "$DOW" == "5" ]];   then RUN_DAY="fri"
else RUN_DAY="all"
fi

OUT="${OUT_ARG:-$REPO_ROOT/spec/reports/CADENCE_${TODAY}.md}"
mkdir -p "$(dirname "$OUT")"
ISSUES=0; WARNINGS=0

emit_header() {
  cat > "$OUT" <<EOF
# Cadence Check — $TODAY

**Day:** $RUN_DAY | **Runner:** $(whoami 2>/dev/null || echo ci)

---
EOF
}

section() { printf '\n## %s\n\n' "$1" >> "$OUT"; }
pass()    { printf -- '- [x] %s\n' "$1" >> "$OUT"; }
warn()    { printf -- '- [~] **WARN** %s\n' "$1" >> "$OUT"; WARNINGS=$((WARNINGS+1)); }
fail()    { printf -- '- [ ] **FAIL** %s\n' "$1" >> "$OUT"; ISSUES=$((ISSUES+1)); }
note()    { printf '  - %s\n' "$1" >> "$OUT"; }

ctrl_ver() { grep '^default_version' "$REPO_ROOT/extension/pgmnemo.control" | sed "s/.*= *'\\([^']*\\)'.*/\\1/"; }
readme_ver() { grep -o 'version-[0-9][^-]*-' "$REPO_ROOT/README.md" 2>/dev/null | head -1 | sed 's/version-//;s/-$//' || true; }
cl_ver() { grep '^## \[' "$REPO_ROOT/CHANGELOG.md" 2>/dev/null | head -1 | sed 's/## \[\([^]]*\)\].*/\1/' || true; }

# ── MONDAY ─────────────────────────────────────────────────────────────────
check_monday() {
  local ctrl; ctrl=$(ctrl_ver)
  section "Monday — Release Coherence"
  printf '**Control version:** `%s`\n\n' "$ctrl" >> "$OUT"

  local rv; rv=$(readme_ver)
  [[ "$ctrl" == "$rv" ]] && pass "README badge matches control ($ctrl)" \
    || fail "README badge mismatch: badge=\`$rv\` control=\`$ctrl\`"

  local cv; cv=$(cl_ver)
  [[ "$ctrl" == "$cv" ]] && pass "CHANGELOG top entry matches control ($ctrl)" \
    || fail "CHANGELOG mismatch: changelog=\`$cv\` control=\`$ctrl\`"

  if [[ -f "$REPO_ROOT/META.json" ]]; then
    local mv; mv=$(grep '"version"' "$REPO_ROOT/META.json" | head -1 | sed 's/.*"\([0-9][^"]*\)".*/\1/' || true)
    [[ "$ctrl" == "$mv" ]] && pass "META.json version matches" || fail "META.json mismatch: \`$mv\` vs \`$ctrl\`"
  else
    warn "META.json absent (PGXN submission not prepared)"
  fi

  section "Monday — Docs Drift"
  local iv; iv=$(grep -o '[0-9]\+\.[0-9]\+\.[0-9]*' "$REPO_ROOT/INSTALL.md" 2>/dev/null | head -1 || true)
  [[ -n "$iv" ]] && { [[ "$ctrl" == "$iv" ]] && pass "INSTALL.md version matches" || fail "INSTALL.md drift: \`$iv\` vs \`$ctrl\`"; } \
    || warn "INSTALL.md has no explicit version string"

  local uv; uv=$(grep -o '[0-9]\+\.[0-9]\+\.[0-9]*' "$REPO_ROOT/docs/USAGE.md" 2>/dev/null | head -1 || true)
  [[ -n "$uv" ]] && { [[ "$ctrl" == "$uv" ]] && pass "docs/USAGE.md version matches" || fail "docs/USAGE.md drift: \`$uv\` vs \`$ctrl\`"; } \
    || warn "docs/USAGE.md has no explicit version string"

  section "Monday — Issue Triage Scaffolding"
  [[ -d "$REPO_ROOT/.github/ISSUE_TEMPLATE" ]] && pass "Issue templates present" \
    || fail ".github/ISSUE_TEMPLATE/ missing"
  [[ -f "$REPO_ROOT/.github/PULL_REQUEST_TEMPLATE.md" ]] && pass "PR template present" \
    || fail ".github/PULL_REQUEST_TEMPLATE.md missing"

  section "Monday — Required Files"
  for f in README.md INSTALL.md CONTRIBUTING.md CHANGELOG.md docs/USAGE.md docs/BENCHMARKS.md; do
    [[ -f "$REPO_ROOT/$f" ]] && pass "$f exists" || fail "$f missing"
  done
  for f in SECURITY.md CODE_OF_CONDUCT.md; do
    [[ -f "$REPO_ROOT/$f" ]] && pass "$f exists" || fail "$f missing (trust scaffolding gap)"
  done
  [[ -f "$REPO_ROOT/.github/CODEOWNERS" ]] && pass ".github/CODEOWNERS present" \
    || fail ".github/CODEOWNERS missing"
}

# ── WEDNESDAY ───────────────────────────────────────────────────────────────
check_wednesday() {
  local ctrl; ctrl=$(ctrl_ver)
  section "Wednesday — Benchmark Artifacts"

  local lr; lr=$(find "$REPO_ROOT/benchmarks/locomo/results" -name "report.md" -path "*${ctrl}*" 2>/dev/null | head -1 || true)
  [[ -n "$lr" ]] && { pass "LoCoMo report for v$ctrl present"; note "${lr#$REPO_ROOT/}"; } \
    || fail "No LoCoMo report for v$ctrl"

  local lmr; lmr=$(find "$REPO_ROOT/benchmarks/longmemeval/results" -name "report.md" -path "*${ctrl}*" 2>/dev/null | head -1 || true)
  [[ -n "$lmr" ]] && { pass "LongMemEval report for v$ctrl present"; note "${lmr#$REPO_ROOT/}"; } \
    || fail "No LongMemEval report for v$ctrl"

  [[ -f "$REPO_ROOT/docs/BENCHMARKS.md" ]] \
    && { grep -qi 'reproduc' "$REPO_ROOT/docs/BENCHMARKS.md" \
           && pass "docs/BENCHMARKS.md has reproducibility section" \
           || warn "docs/BENCHMARKS.md missing reproducibility instructions"; } \
    || fail "docs/BENCHMARKS.md missing"

  section "Wednesday — CI Confidence"
  local ci="$REPO_ROOT/.github/workflows/ci.yml"
  if [[ ! -f "$ci" ]]; then
    fail ".github/workflows/ci.yml missing"
  else
    pass "CI workflow exists"
    local n; n=$(grep -c 'continue-on-error: true' "$ci" || true)
    [[ "$n" -gt 0 ]] \
      && { warn "CI has $n continue-on-error step(s) — confirm labeled temporary"; \
           grep -n 'continue-on-error: true' "$ci" | while IFS=: read -r ln _; do note "Line $ln"; done; } \
      || pass "No continue-on-error (all steps hard-fail)"
    grep -q 'CREATE EXTENSION' "$ci" && pass "CI exercises CREATE EXTENSION" \
      || fail "CI does not exercise CREATE EXTENSION"
  fi

  section "Wednesday — Examples"
  if [[ -d "$REPO_ROOT/examples" ]]; then
    local ec; ec=$(find "$REPO_ROOT/examples" \( -name '*.sql' -o -name '*.sh' -o -name '*.py' \) | wc -l)
    pass "examples/ present ($ec runnable files)"
    [[ -f "$REPO_ROOT/examples/README.md" ]] && pass "examples/README.md present" \
      || warn "examples/README.md missing"
    grep -rq 'pgmnemo\.ingest\|pgmnemo\.recall_lessons' "$REPO_ROOT/examples/" 2>/dev/null \
      && pass "Examples reference current pgmnemo API" \
      || warn "Examples may not reference current pgmnemo.ingest/recall_lessons"
  else
    fail "examples/ directory missing"
  fi
}

# ── FRIDAY ──────────────────────────────────────────────────────────────────
check_friday() {
  section "Friday — New Visitor Experience"
  for f in README.md INSTALL.md CONTRIBUTING.md SECURITY.md CODE_OF_CONDUCT.md; do
    [[ -f "$REPO_ROOT/$f" ]] && pass "$f at root" \
      || fail "$f missing from root — new visitors cannot find it"
  done

  local ql; ql=$(grep -in 'quickstart\|quick.start\|30.second' "$REPO_ROOT/README.md" | head -1 | cut -d: -f1 || true)
  if [[ -n "$ql" && "$ql" -le 80 ]]; then
    pass "README quickstart within first 80 lines (line $ql)"
  elif [[ -n "$ql" ]]; then
    warn "README quickstart deep at line $ql"
  else
    fail "README has no quickstart section"
  fi

  section "Friday — Competitor Signal Check"
  if command -v gh &>/dev/null; then
    for repo in mem0ai/mem0 getzep/graphiti pgvector/pgvector; do
      local t; t=$(gh release view --repo "$repo" --json tagName -q '.tagName' 2>/dev/null || true)
      [[ -n "$t" ]] && pass "$repo latest: \`$t\`" || warn "Could not fetch release for $repo"
    done
  else
    warn "gh CLI unavailable — competitor checks skipped"
    note "Manual: mem0ai/mem0, getzep/graphiti, pgvector/pgvector"
  fi

  section "Friday — POSITIONING.md Currency"
  if [[ -f "$REPO_ROOT/docs/POSITIONING.md" ]]; then
    local pd; pd=$(git -C "$REPO_ROOT" log -1 --format="%ci" -- docs/POSITIONING.md | cut -c1-10 2>/dev/null || true)
    [[ -n "$pd" ]] && pass "docs/POSITIONING.md last committed $pd" \
      || warn "Could not determine POSITIONING.md commit date"
  else
    fail "docs/POSITIONING.md missing"
  fi
}

# ── SUMMARY ─────────────────────────────────────────────────────────────────
emit_summary() {
  section "Summary"
  printf '| Metric | Count |\n|---|---|\n| FAIL | %d |\n| WARN | %d |\n\n' "$ISSUES" "$WARNINGS" >> "$OUT"
  if [[ "$ISSUES" -eq 0 && "$WARNINGS" -eq 0 ]]; then printf '**Status: ALL CLEAR**\n' >> "$OUT"
  elif [[ "$ISSUES" -eq 0 ]]; then printf '**Status: WARNINGS ONLY**\n' >> "$OUT"
  else printf '**Status: %d ISSUE(S) REQUIRE ACTION**\n' "$ISSUES" >> "$OUT"
  fi
  printf '\n_Generated by scripts/cadence_check.sh — %s_\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$OUT"
}

emit_header
case "$RUN_DAY" in
  mon) check_monday ;;
  wed) check_wednesday ;;
  fri) check_friday ;;
  all) check_monday; check_wednesday; check_friday ;;
  *)   printf 'Unknown day: %s\n' "$RUN_DAY" >&2; exit 1 ;;
esac
emit_summary

printf 'Report: %s\nIssues: %d  Warnings: %d\n' "$OUT" "$ISSUES" "$WARNINGS"
[[ "$ISSUES" -eq 0 ]]
