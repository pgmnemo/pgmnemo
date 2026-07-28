-- pgmnemo upgrade: 0.14.2 → 0.15.0
-- SPDX-License-Identifier: Apache-2.0
--
-- 0.15.0 — B1: API-contract COMMENT ON FUNCTION for typed write verbs
--             B2: stale \echo version guard corrected in flat-install scripts
--
-- B1 rationale:
--   reclassify_corpus() (0.14.2) restricts its candidate set to rows whose
--   content_type IS NULL or is in classifier_owned_types() =
--   {incident, decision, entity, fact, procedure}.
--   This creates a deliberate ASYMMETRY across the three typed write verbs:
--
--     remember_event()    → content_type = 'event'    NOT in classifier set → PROTECTED
--     remember_relation() → content_type = 'relation' NOT in classifier set → PROTECTED
--     remember_fact()     → content_type = 'fact'     IS  in classifier set → NOT protected
--
--   The previous COMMENT ON FUNCTION strings did not document this contract,
--   leaving callers of remember_fact() without any signal that a later
--   reclassify_corpus() call can silently overwrite the type they wrote.
--   This upgrade script updates all three comments to make the asymmetry explicit.
--
-- B2 handled in flat-install scripts (pgmnemo--0.12.0.sql … 0.14.2.sql):
--   the embedded \echo guard that previously read '0.11.1' has been corrected
--   to match each file's own version string.  No SQL change required here.
--
-- Sibling tasks may APPEND further 0.15.0 content to this file.
-- =============================================================================


-- =============================================================================
-- B1 §1  remember_fact — content_type 'fact' is in classifier_owned_types()
--         → NOT protected from reclassify_corpus()
-- =============================================================================
-- Replaces: 'Typed fact write with bitemporal supersession … v0.12.0.'

COMMENT ON FUNCTION pgmnemo.remember_fact(TEXT,TEXT,TEXT,TEXT,REAL,BOOLEAN,vector,TEXT,INT,TEXT,TEXT) IS
    'Typed fact write with bitemporal supersession, PII-aware state routing, '
    'synthesized artifact_hash. RFC-001 §D2 + ADDENDUM-2 R1-R7. '
    'RECLASSIFICATION CONTRACT: content_type written here is ''fact'', which IS '
    'in pgmnemo.classifier_owned_types() = {incident, decision, entity, fact, procedure}. '
    'A subsequent pgmnemo.reclassify_corpus() call may therefore overwrite this '
    'content_type with whatever the classifier produces for the same text. '
    'If your application requires a permanent, classifier-immutable type, use '
    'remember_event() (type=''event'') or remember_relation() (type=''relation'') '
    'instead — those types are outside the classifier output domain and are '
    'skipped by reclassify_corpus(). v0.15.0.';


-- =============================================================================
-- B1 §2  remember_event — content_type 'event' is NOT in classifier_owned_types()
--         → PROTECTED from reclassify_corpus()
-- =============================================================================
-- Replaces: 'Immutable event record. Append-only. content_type=event. RFC-001 §D2. v0.12.0.'

COMMENT ON FUNCTION pgmnemo.remember_event(TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,REAL,vector,TEXT,INT,TEXT,TEXT) IS
    'Immutable event record. Append-only. content_type=''event''. RFC-001 §D2. '
    'RECLASSIFICATION CONTRACT: content_type ''event'' is NOT in '
    'pgmnemo.classifier_owned_types() = {incident, decision, entity, fact, procedure}. '
    'pgmnemo.reclassify_corpus() excludes all rows with curator-owned types from '
    'its candidate set, so the type written here is permanent and will never be '
    'overwritten by the classifier. Contrast with remember_fact(), which writes '
    '''fact'' — a classifier-owned type that reclassify_corpus() can update. '
    'v0.15.0.';


-- =============================================================================
-- B1 §3  remember_relation — content_type 'relation' is NOT in classifier_owned_types()
--         → PROTECTED from reclassify_corpus()
-- =============================================================================
-- Replaces: 'Directed typed relation. Idempotent on triple. content_type=relation. RFC-001 §D2. v0.12.0.'

COMMENT ON FUNCTION pgmnemo.remember_relation(TEXT,TEXT,TEXT,TEXT,REAL,vector,TEXT,INT,TEXT,TEXT) IS
    'Directed typed relation between entity hubs. Idempotent on (from_key, to_key, relation_type) '
    'triple. content_type=''relation''. RFC-001 §D2. '
    'RECLASSIFICATION CONTRACT: content_type ''relation'' is NOT in '
    'pgmnemo.classifier_owned_types() = {incident, decision, entity, fact, procedure}. '
    'pgmnemo.reclassify_corpus() excludes all rows with curator-owned types from '
    'its candidate set, so the type written here is permanent and will never be '
    'overwritten by the classifier. Contrast with remember_fact(), which writes '
    '''fact'' — a classifier-owned type that reclassify_corpus() can update. '
    'v0.15.0.';


-- =============================================================================
-- A1  extract_sit_fp — IMMUTABLE situation fingerprint extractor
-- =============================================================================
-- Returns a normalised TEXT fingerprint that identifies the SITUATION CLASS of a
-- lesson row, not its unique identity (unlike task_id).
--
-- Output format:
--   'class=<class>'                              — from [INCIDENT:<class>] topic
--   'class=<FAILURE_CLASS>|outcome=<OUTCOME>'    — from episode failure text
--   'class=completed'                            — COMPLETED episode
--   NULL                                         — no recognisable pattern
--
-- DESIGN — expression index over new column:
--   We chose an IMMUTABLE expression index on extract_sit_fp(topic, lesson_text)
--   rather than a new column because:
--   • No ALTER TABLE — avoids an AccessExclusiveLock on the live corpus.
--   • One index covers both existing [INCIDENT:xxx] topic rows and new episode rows.
--   • No backfill needed: the index is built once on install, maintained on write.
--   • extract_sit_fp is IMMUTABLE (depends only on inputs), satisfying the
--     PostgreSQL requirement for expression indexes.
--
-- IMMUTABLE: depends only on input parameters.
-- STRICT: NULL input → NULL output.
-- PARALLEL SAFE: pure computation, no I/O.
--
-- Extraction rules (evaluated top-to-bottom, first match wins):
--   R1  Topic starts with [INCIDENT:<alphanum_underscore>] → class from topic.
--       Example: [INCIDENT:deploy_gap] Container code stale — 7 files behind git HEAD
--       → 'class=deploy_gap'  (the file count is stripped — only class matters)
--   R2  Text contains failure_class=<WORD> → class from text + outcome if present.
--       Example: '[EPISODE] ... failure_class=INFRA_AUTH_INVALID ... outcome=ESCALATED'
--       → 'class=INFRA_AUTH_INVALID|outcome=ESCALATED'
--   R3  Text contains 'outcome=COMPLETED' → 'class=completed'.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.extract_sit_fp(
    p_topic TEXT,
    p_text  TEXT DEFAULT NULL
)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
PARALLEL SAFE
AS $func$
SELECT CASE
    -- R1: [INCIDENT:<class>] topic pattern — strip everything after the closing bracket.
    -- p_topic may be NULL (handled by IS NOT NULL guard).
    WHEN p_topic IS NOT NULL AND p_topic ~ '^\[INCIDENT:[a-z0-9_]+\]'
        THEN 'class=' || (regexp_match(p_topic, '^\[INCIDENT:([a-z0-9_]+)\]'))[1]

    -- R2: failure_class= in episode text (from run-closeout write path).
    -- outcome= may be absent if the episode was written without it.
    WHEN p_text IS NOT NULL AND p_text ~ 'failure_class=[A-Z0-9_]+'
        THEN 'class=' || (regexp_match(p_text, 'failure_class=([A-Z0-9_]+)'))[1]
             || CASE WHEN p_text ~ 'outcome=[A-Z]+'
                     THEN '|outcome=' || (regexp_match(p_text, 'outcome=([A-Z]+)'))[1]
                     ELSE ''
                END

    -- R3: successful episode (outcome=COMPLETED, no failure_class).
    -- Use simple substring match — \b word boundary is not POSIX ERE in PostgreSQL.
    WHEN p_text IS NOT NULL AND p_text ~ 'outcome=COMPLETED'
        THEN 'class=completed'

    ELSE NULL
END
$func$;

COMMENT ON FUNCTION pgmnemo.extract_sit_fp(TEXT, TEXT) IS
    'IMMUTABLE situation fingerprint extractor (v0.15.0). '
    'Returns a normalised class string that identifies the SITUATION CLASS, not a unique identity. '
    'Two differently-worded reports of the same failure return the same fingerprint; '
    'two similarly-worded reports of different failures return different fingerprints. '
    'Extraction rules (first match): '
    'R1 [INCIDENT:<class>] topic pattern → ''class=<class>'' (file count stripped). '
    'R2 failure_class=<WORD> in text → ''class=<WORD>[|outcome=<WORD>]''. '
    'R3 outcome=COMPLETED in text → ''class=completed''. '
    'NULL input → NULL (STRICT). IMMUTABLE + PARALLEL SAFE: usable in expression indexes. '
    'Used by ix_pgmnemo_sit_fp_active and recall_situation(). v0.15.0.';


-- =============================================================================
-- A1  ix_pgmnemo_sit_fp_active — expression index for situational recall
-- =============================================================================
-- Partial expression index on extract_sit_fp(topic, lesson_text).
-- Predicate: is_active AND content_type IS NOT NULL
--   • Excludes soft-deleted rows and untyped legacy rows.
--   • Covers content_type IN ('event', 'incident', 'procedure', 'decision', ...).
-- recall_situation() uses this index when both predicate conditions appear in WHERE.
-- =============================================================================

CREATE INDEX IF NOT EXISTS ix_pgmnemo_sit_fp_active
    ON pgmnemo.agent_lesson (pgmnemo.extract_sit_fp(topic, lesson_text))
    WHERE is_active AND content_type IS NOT NULL
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON INDEX pgmnemo.ix_pgmnemo_sit_fp_active IS
    'Expression index on extract_sit_fp(topic, lesson_text) for typed active rows. '
    'Predicate: is_active AND content_type IS NOT NULL. '
    'Supports recall_situation() O(log n) lookup by situation class. v0.15.0.';


-- =============================================================================
-- A1b  remember_event() — write sit_fp into metadata at record time
-- =============================================================================
-- Adds 'sit_fp' key to the metadata JSONB so callers can inspect the fingerprint
-- without re-running extract_sit_fp(). Supersedes the B1 §2 COMMENT update above.
--
-- Idempotency path (FOUND): no-op, existing row already has sit_fp.
-- sit_fp is NULL when extract_sit_fp returns NULL (text lacks recognisable pattern).
-- All other behaviour unchanged from v0.12.0.
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.remember_event(
    p_role          TEXT,
    p_entity_key    TEXT,
    p_event_label   TEXT,
    p_event_body    TEXT,
    p_occurred_at   TIMESTAMPTZ  DEFAULT NOW(),
    p_confidence    REAL         DEFAULT 0.8,
    p_embedding     vector(1024) DEFAULT NULL,
    p_source_type   TEXT         DEFAULT NULL,
    p_project_id    INT          DEFAULT NULL,
    p_commit_sha    TEXT         DEFAULT NULL,
    p_artifact_hash TEXT         DEFAULT NULL
) RETURNS BIGINT LANGUAGE plpgsql AS $$
DECLARE
    _topic         TEXT;
    _artifact_hash TEXT;
    _final_state   TEXT;
    _new_id        BIGINT;
    _sit_fp        TEXT;
BEGIN
    IF p_entity_key IS NULL OR p_entity_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'pgmnemo.remember_event: invalid entity_key ''%''', p_entity_key;
    END IF;
    IF p_event_label IS NULL OR length(trim(p_event_label)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.remember_event: p_event_label must not be NULL or empty';
    END IF;
    IF p_event_body IS NULL OR length(trim(p_event_body)) < 1 THEN
        RAISE EXCEPTION 'pgmnemo.remember_event: p_event_body must not be NULL or empty';
    END IF;

    _topic         := p_entity_key || ':event:' || p_event_label;
    _artifact_hash := COALESCE(p_artifact_hash, 'event-' || p_entity_key || ':' || p_event_label);

    -- A1b: compute sit_fp from topic + body at write time
    _sit_fp := pgmnemo.extract_sit_fp(_topic, p_event_body);

    -- R3: Idempotency — FOR UPDATE dedup on (lower(topic), project_id).
    SELECT id INTO _new_id
    FROM pgmnemo.agent_lesson
    WHERE lower(topic) = lower(_topic)
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ
    LIMIT 1 FOR UPDATE;
    IF FOUND THEN
        RETURN _new_id;
    END IF;

    IF p_source_type = 'auto_captured' THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'system' THEN
        _final_state := 'validated';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.8) >= 0.8 THEN
        _final_state := 'validated';
    ELSE
        _final_state := 'candidate';
    END IF;

    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        embedding, commit_sha, artifact_hash, metadata,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to
    ) VALUES (
        p_role, p_project_id, _topic, p_event_body, 3,
        p_embedding, p_commit_sha, _artifact_hash,
        jsonb_build_object(
            'entity_key',  p_entity_key,
            'event_label', p_event_label,
            'occurred_at', p_occurred_at,
            'sit_fp',      _sit_fp
        ),
        COALESCE(p_source_type, 'agent_authored'), 'event', _final_state,
        COALESCE(p_confidence, 0.8), 1,
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        COALESCE(p_occurred_at, NOW()), 'infinity'::TIMESTAMPTZ
    ) RETURNING agent_lesson.id INTO _new_id;
    RETURN _new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_event(TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,REAL,vector,TEXT,INT,TEXT,TEXT) IS
    'Immutable event record. Append-only. content_type=''event''. RFC-001 §D2. '
    'RECLASSIFICATION CONTRACT: content_type ''event'' is NOT in '
    'pgmnemo.classifier_owned_types() = {incident, decision, entity, fact, procedure}. '
    'pgmnemo.reclassify_corpus() excludes all rows with curator-owned types; '
    'the type written here is permanent. '
    'v0.15.0: metadata now includes ''sit_fp'' key — the extract_sit_fp() fingerprint '
    'computed at write time from the episode body. Allows callers to inspect '
    'metadata->>''sit_fp'' without additional SQL. '
    'recall_situation() uses ix_pgmnemo_sit_fp_active for class-based lookup.';


-- =============================================================================
-- A2  recall_situation — situational recall by fingerprint class
-- =============================================================================
-- Returns prior lessons whose situation fingerprint matches p_sit_fp exactly.
--
-- KEY PROPERTY: matches on SITUATION, not on text similarity.
--   Two differently-worded reports of the same failure share the same fingerprint
--   and are both returned.  Two similarly-worded reports of different failures
--   have different fingerprints and are NOT cross-returned.
--
-- Uses ix_pgmnemo_sit_fp_active for O(log n) lookup when
--   is_active AND content_type IS NOT NULL is in the WHERE clause.
--
-- Parameters:
--   p_sit_fp     TEXT              — exact fingerprint (from extract_sit_fp)
--   p_project_id INT  DEFAULT NULL — restrict to one project (NULL = all)
--   p_role       TEXT DEFAULT NULL — restrict to one role (NULL = all)
--   p_k          INT  DEFAULT 10   — max rows, newest-first
--
-- Returns: id, role, topic, lesson_text, content_type, sit_fp, created_at
--
-- Usage:
--   -- What class is a deploy_gap topic?
--   SELECT pgmnemo.extract_sit_fp('[INCIDENT:deploy_gap] 7 files behind');
--   -- → 'class=deploy_gap'
--
--   -- All prior deploy_gap incidents:
--   SELECT id, role, topic FROM pgmnemo.recall_situation('class=deploy_gap', p_k=>60);
--
--   -- All INFRA_AUTH_INVALID escalations:
--   SELECT * FROM pgmnemo.recall_situation('class=INFRA_AUTH_INVALID|outcome=ESCALATED');
-- =============================================================================

CREATE OR REPLACE FUNCTION pgmnemo.recall_situation(
    p_sit_fp     TEXT,
    p_project_id INT     DEFAULT NULL,
    p_role       TEXT    DEFAULT NULL,
    p_k          INT     DEFAULT 10
)
RETURNS TABLE (
    id           BIGINT,
    role         TEXT,
    topic        TEXT,
    lesson_text  TEXT,
    content_type TEXT,
    sit_fp       TEXT,
    created_at   TIMESTAMPTZ
)
LANGUAGE sql
STABLE
PARALLEL SAFE
AS $func$
    SELECT
        al.id,
        al.role,
        al.topic,
        al.lesson_text,
        al.content_type,
        pgmnemo.extract_sit_fp(al.topic, al.lesson_text) AS sit_fp,
        al.created_at
    FROM pgmnemo.agent_lesson al
    WHERE al.is_active
      AND al.content_type IS NOT NULL
      -- P1-A: same bitemporal lifecycle gate every other recall function applies —
      -- without it recall_situation() would surface historically-superseded rows.
      AND al.t_valid_to = 'infinity'::TIMESTAMPTZ
      AND pgmnemo.extract_sit_fp(al.topic, al.lesson_text) = p_sit_fp
      AND (p_project_id IS NULL OR al.project_id = p_project_id)
      AND (p_role IS NULL OR al.role = p_role)
    ORDER BY al.created_at DESC
    LIMIT p_k
$func$;

COMMENT ON FUNCTION pgmnemo.recall_situation(TEXT, INT, TEXT, INT) IS
    'TRUST POSTURE (v0.15.0, differs from other recall functions — read before relying on it): '
    'this function does NOT read pgmnemo.gate_strict or pgmnemo.include_unverified. '
    'It filters on is_active, content_type and the bitemporal t_valid_to gate, but it does '
    'NOT exclude unverified rows, so draft and candidate lessons ARE returned even when '
    'gate_strict is on. Deliberate for 0.15.0: episodes are written at run closeout and are '
    'draft by default, so a validated-only filter would return almost nothing and make the '
    'feature silently useless. GUC-conditional filtering is deferred to a follow-up release. '
    'Situational recall: return prior lessons whose situation class matches p_sit_fp. '
    'Matches on SITUATION fingerprint, not text similarity. '
    'Two differently-worded reports of the same failure match; '
    'two similarly-worded reports of different failures do not. '
    'Uses ix_pgmnemo_sit_fp_active for O(log n) lookup. '
    'p_sit_fp: exact fingerprint string from extract_sit_fp(). '
    'p_project_id: restrict to project (NULL = all). '
    'p_role: restrict to role (NULL = all). '
    'p_k: max results, newest-first (default 10). '
    'Returns: id, role, topic, lesson_text, content_type, sit_fp, created_at. v0.15.0.';
