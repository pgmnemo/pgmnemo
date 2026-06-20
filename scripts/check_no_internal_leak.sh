#!/usr/bin/env bash
#
# check_no_internal_leak.sh — release gate G-NO-INTERNAL-LEAK
#
# Fails (exit 1) if any SHIPPED, tracked file contains content that must never be
# published: a real user home path (/Users/<name>, C:\Users\<name>) or any extra
# project-internal marker supplied via a private pattern file.
#
# Complements the G-CONFIDENTIALITY gate, which blocks adding whole *files* under
# spec/ research/ design/. This gate catches internal *content* that leaks INTO a
# file that is otherwise legitimately public — the 2026-06-05 class of leak.
#
# Design (two-repo safe):
#   - The generic personal-path detection is public-safe and ships in the repo.
#   - Project-internal markers (agent ids, internal project ids, "INTERNAL" tags)
#     are NOT hardcoded here — they live in an OPTIONAL private pattern file so the
#     public repo never enumerates what we consider secret. Point to it with:
#         INTERNAL_LEAK_PATTERN_FILE=/path/to/.internal-leak-patterns
#     Default location (gitignored): scripts/.internal-leak-patterns
#     Each line is one extended-regex (ERE); blank lines and '#' comments ignored.
#     When the file is absent (e.g. a clean public CI checkout) the gate still runs
#     the generic personal-path scan.
#
# Exit codes: 0 = clean, 1 = leak found, 2 = usage/環境 error.

set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT"

SELF_REL="scripts/check_no_internal_leak.sh"
PATTERN_FILE="${INTERNAL_LEAK_PATTERN_FILE:-scripts/.internal-leak-patterns}"

# Working / forensic dirs allowed to hold internal content (never shipped publicly,
# or legitimately quoting a machine path in an incident report).
EXCLUDE_PREFIXES='^(spec/|research/|design/|docs/fixes/|\.git/)'

# Placeholder usernames permitted inside /Users/<name> and C:\Users\<name>.
PLACEHOLDERS='example|me|user|username|you|yourname|yourusername|your-username'

err() { printf '%s\n' "$*" >&2; }

# --- collect candidate files: tracked, not excluded, not this script -------------
collect_files() {
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git ls-files
  else
    find . -type f | sed 's#^\./##'
  fi | grep -Ev "$EXCLUDE_PREFIXES" | grep -Fvx "$SELF_REL" || true
}

leaks=0

while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || continue
  # skip binary files (grep -I: treat binary as no-match; -q exits 0 only if text byte seen)
  grep -Iq . "$f" 2>/dev/null || continue

  # 1) personal home paths, placeholder-aware ------------------------------------
  hits="$(awk -v PH="$PLACEHOLDERS" -v F="$f" '
    {
      line = $0
      while (match(line, /(\/Users\/|[A-Za-z]:\\Users\\)[A-Za-z][A-Za-z0-9._-]*/)) {
        tok  = substr(line, RSTART, RLENGTH)
        name = tok
        sub(/^(\/Users\/|[A-Za-z]:\\Users\\)/, "", name)
        lname = tolower(name)
        isph = 0
        n = split(PH, arr, "|")
        for (i = 1; i <= n; i++) if (lname == arr[i]) isph = 1
        if (!isph) print F ":" NR ": personal path: " tok
        line = substr(line, RSTART + RLENGTH)
      }
    }' "$f" || true)"
  if [ -n "$hits" ]; then
    err "$hits"
    leaks=$((leaks + 1))
  fi

  # 2) extra private markers from the optional pattern file ----------------------
  if [ -f "$PATTERN_FILE" ]; then
    while IFS= read -r pat; do
      case "$pat" in ''|'#'*) continue ;; esac
      mhits="$(grep -nE "$pat" "$f" 2>/dev/null || true)"
      if [ -n "$mhits" ]; then
        while IFS= read -r ln; do
          err "$f:${ln%%:*}: internal marker [/$pat/]: $(printf '%s' "$ln" | cut -d: -f2-)"
        done <<< "$mhits"
        leaks=$((leaks + 1))
      fi
    done < "$PATTERN_FILE"
  fi
done < <(collect_files)

if [ "$leaks" -gt 0 ]; then
  err ""
  err "G-NO-INTERNAL-LEAK: FAIL — $leaks file(s) contain content that must not ship."
  err "Move the content to spec/ research/ design/, redact it, or use a placeholder."
  exit 1
fi

if [ ! -f "$PATTERN_FILE" ]; then
  err "G-NO-INTERNAL-LEAK: PASS (generic scan only — no private pattern file at '$PATTERN_FILE')."
else
  err "G-NO-INTERNAL-LEAK: PASS (generic + $(grep -cvE '^\s*(#|$)' "$PATTERN_FILE") private marker(s))."
fi
exit 0
