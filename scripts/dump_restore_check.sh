#!/usr/bin/env bash
# dump_restore_check.sh — real pg_dump -> pg_restore round-trip for pgmnemo.
#
# Guards the 0.21.0 fix: before it, agent_lesson / mem_edge / memory_ingest_log
# were never passed to pg_extension_config_dump(), so a standard pg_dump kept the
# DDL (via CREATE EXTENSION) but silently dumped ZERO rows of the corpus.
#
# Scenarios (each in its own throwaway DB, dropped on exit):
#   A  fresh install of the current version      -> dump -> restore into empty DB
#   B  0.20.0 install -> ALTER EXTENSION UPDATE  -> dump -> restore  (upgrade path)
#   C  negative control: a plain 0.20.0 install dumps NO rows (proves the bug the
#      fix addresses and that this script can detect it). Skipped when the
#      0.20.0 install scripts are not present.
#
# Asserted after every restore: row counts, a content checksum of all three
# tables, sequence continuity (next id > max id, no collision), the transition
# seed table not duplicated, and that recall_lessons() still returns the lesson.
#
# Usage: scripts/dump_restore_check.sh [VERSION]       (default: control file version)
# Env:   PGHOST/PGPORT/PGUSER/PGPASSWORD as for psql. The role needs CREATEDB and
#        permission to CREATE EXTENSION (superuser, or trusted extensions).
#        The extension files must already be installed (make install).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(sed -n "s/^default_version *= *'\(.*\)'/\1/p" "$REPO_ROOT/pgmnemo.control")}"
PREV_VERSION="0.20.0"
TAG="pgmnemo_dr_$$"
WORK="$(mktemp -d)"
FAILS=0
DBS=()

psqlx() { psql -X -v ON_ERROR_STOP=1 -qAt "$@"; }
mkdb()  { DBS+=("$1"); psqlx -d postgres -c "CREATE DATABASE \"$1\""; }
cleanup() {
    for d in "${DBS[@]:-}"; do [[ -n "$d" ]] && psql -X -qAt -d postgres -c "DROP DATABASE IF EXISTS \"$d\" WITH (FORCE)" >/dev/null 2>&1 || true; done
    rm -rf "$WORK"
}
trap cleanup EXIT

check() { # check <label> <expected> <actual>
    if [[ "$2" == "$3" ]]; then echo "  ok   $1 ($3)"; else echo "  FAIL $1: expected [$2] got [$3]"; FAILS=$((FAILS+1)); fi
}

# Seed a deterministic corpus: 5 lessons, 3 edges, 2 ingest-log rows.
seed() { # seed <db>
    psqlx -d "$1" <<'SQL' >/dev/null
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
INSERT INTO pgmnemo.agent_lesson (role, project_id, topic, lesson_text, importance, artifact_hash)
SELECT 'dr-agent', 1, 'dump-restore', 'Dump restore lesson number ' || g || ' about jwt rotation', 1 + g % 5, 'sha256:dr' || g
FROM generate_series(1, 5) g;
INSERT INTO pgmnemo.mem_edge (source_id, target_id, relation_type, edge_kind, weight)
SELECT l.id, l.id + 1, 'CAUSED_BY', 'causal', 0.5
FROM (SELECT id FROM pgmnemo.agent_lesson ORDER BY id LIMIT 3) l;
INSERT INTO pgmnemo.memory_ingest_log (source_origin, min_id, max_id) VALUES ('legacy.a', 1, 3), ('legacy.b', 4, 5);
SQL
}

# One line fingerprint: counts + md5 over every row of the three tables.
fingerprint() { # fingerprint <db>
    psqlx -d "$1" -c "SELECT
      (SELECT count(*) FROM pgmnemo.agent_lesson) || '/' ||
      (SELECT count(*) FROM pgmnemo.mem_edge) || '/' ||
      (SELECT count(*) FROM pgmnemo.memory_ingest_log) || '/' ||
      md5(
        (SELECT coalesce(string_agg(t::text, '|' ORDER BY id), '') FROM pgmnemo.agent_lesson t) ||
        (SELECT coalesce(string_agg(t::text, '|' ORDER BY id), '') FROM pgmnemo.mem_edge t) ||
        (SELECT coalesce(string_agg(t::text, '|' ORDER BY id), '') FROM pgmnemo.memory_ingest_log t))"
}

roundtrip() { # roundtrip <label> <src_db>
    local label="$1" src="$2" dst="${2}_r"
    echo "[$label] pg_dump -Fc -> pg_restore into empty DB"
    local before; before="$(fingerprint "$src")"
    pg_dump -Fc -d "$src" -f "$WORK/$label.dump"
    mkdb "$dst"
    pg_restore --exit-on-error -d "$dst" "$WORK/$label.dump"
    check "extversion"            "$VERSION" "$(psqlx -d "$dst" -c "SELECT extversion FROM pg_extension WHERE extname='pgmnemo'")"
    check "corpus counts+checksum" "$before"  "$(fingerprint "$dst")"
    check "lesson_state_transition not duplicated" \
          "$(psqlx -d "$src" -c 'SELECT count(*) FROM pgmnemo.agent_lesson_state_transition')" \
          "$(psqlx -d "$dst" -c 'SELECT count(*) FROM pgmnemo.agent_lesson_state_transition')"
    # Sequence continuity: a new write must not collide with restored ids.
    check "next lesson id > max id" "t" "$(psqlx -d "$dst" -c "
        SET pgmnemo.gate_strict='off';
        WITH n AS (INSERT INTO pgmnemo.agent_lesson (role, project_id, topic, lesson_text, artifact_hash)
                   VALUES ('dr-agent', 1, 'dump-restore', 'post-restore write', 'sha256:post') RETURNING id)
        SELECT n.id > (SELECT max(id) FROM pgmnemo.agent_lesson WHERE id <> n.id) FROM n" | tail -1)"
    check "mem_edge sequence continues" "t" "$(psqlx -d "$dst" -c "
        SELECT nextval('pgmnemo.mem_edge_id_seq') > (SELECT max(id) FROM pgmnemo.mem_edge)")"
    check "memory_ingest_log sequence continues" "t" "$(psqlx -d "$dst" -c "
        SELECT nextval('pgmnemo.memory_ingest_log_id_seq') > (SELECT max(id) FROM pgmnemo.memory_ingest_log)")"
    check "recall finds restored lessons" "t" "$(psqlx -d "$dst" -c "
        SET pgmnemo.include_unverified='on';
        SELECT count(*) > 0 FROM pgmnemo.recall_lessons(NULL::vector(1024), 5, 'dr-agent', 1, 'jwt rotation')" | tail -1)"
}

echo "== pgmnemo dump/restore check, version $VERSION =="

# A: fresh install
A="${TAG}_a"; mkdb "$A"
psqlx -d "$A" -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION pgmnemo VERSION '$VERSION'" >/dev/null
seed "$A"
roundtrip "A-fresh" "$A"

# B / C need the previous version's install script
if [[ -f "$(pg_config --sharedir)/extension/pgmnemo--$PREV_VERSION.sql" && "$VERSION" != "$PREV_VERSION" ]]; then
    B="${TAG}_b"; mkdb "$B"
    psqlx -d "$B" -c "CREATE EXTENSION IF NOT EXISTS vector; CREATE EXTENSION pgmnemo VERSION '$PREV_VERSION'" >/dev/null
    seed "$B"

    # C: negative control, on the un-upgraded old install
    echo "[C-control] $PREV_VERSION dump must contain NO corpus rows (the bug)"
    pg_dump -Fc -d "$B" -f "$WORK/old.dump"
    old_tables="$(pg_restore -l "$WORK/old.dump" | grep -c 'TABLE DATA pgmnemo \(agent_lesson\|mem_edge\|memory_ingest_log\) ' || true)"
    check "old dump has no TABLE DATA entries for user tables" "0" "$old_tables"

    # B: upgrade path
    psqlx -d "$B" -c "ALTER EXTENSION pgmnemo UPDATE TO '$VERSION'" >/dev/null
    roundtrip "B-upgrade" "$B"
else
    echo "[B/C] skipped: $PREV_VERSION install script not installed"
fi

echo
if [[ $FAILS -eq 0 ]]; then echo "DUMP-RESTORE CHECK PASS"; else echo "DUMP-RESTORE CHECK FAIL ($FAILS)"; exit 1; fi
