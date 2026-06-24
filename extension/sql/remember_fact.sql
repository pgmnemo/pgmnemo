-- remember_fact.sql
-- pgmnemo v0.12.0 — Typed Write API: remember_fact / remember_event / remember_relation
-- RFC-001 §D2 + ADDENDUM-2 (7 correctness requirements)
--
-- All three functions encode write-path discipline at the database layer:
--   • PII-aware candidate routing (ADR-61 §D4) — R1
--   • Non-NULL artifact_hash synthesis before provenance gate — R2
--   • Identity/dedup on (lower(topic), project_id) with FOR UPDATE — R3
--   • Drop-in upgrade from ingest_entity (same key+project) — R4
--   • confidence + has_contact_pii as first-class inputs — R7
--
-- SPDX-License-Identifier: Apache-2.0

-- ─────────────────────────────────────────────────────────────────────────────
-- 0. guard_no_test_project — safety guard for test harnesses (R6)
--
-- Call at the start of any test script before writing data. Raises if the
-- supplied project_id looks like a production ID (≤ 100) so test scripts
-- cannot accidentally mutate prod data when pointed at the wrong database.
-- Accepts an optional database allowlist for stricter env checks.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.guard_no_test_project(
    p_project_id     INT,
    p_allowed_db     TEXT   DEFAULT NULL   -- NULL = skip DB name check
)
RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    IF p_project_id IS NULL THEN
        RAISE EXCEPTION
            'pgmnemo.guard_no_test_project: p_project_id IS NULL — '
            'tests must use an explicit test project_id (> 10000 recommended)';
    END IF;
    -- Project IDs ≤ 100 are reserved for production use in Agency.
    -- Tests should use project_id > 10000 (e.g. 99999).
    IF p_project_id <= 100 THEN
        RAISE EXCEPTION
            'pgmnemo.guard_no_test_project: project_id=% looks like a production ID '
            '(≤ 100). Tests should use project_id > 10000 to avoid prod contamination.',
            p_project_id;
    END IF;
    -- Optional: enforce DB name
    IF p_allowed_db IS NOT NULL AND current_database() <> p_allowed_db THEN
        RAISE EXCEPTION
            'pgmnemo.guard_no_test_project: test must run on database ''%'' but '
            'current database is ''%''.',
            p_allowed_db, current_database();
    END IF;
END;
$$;

COMMENT ON FUNCTION pgmnemo.guard_no_test_project(INT, TEXT) IS
    'Safety guard for test harnesses (R6, v0.12.0). '
    'Raises EXCEPTION when p_project_id ≤ 100 (reserved for production). '
    'Call at the start of test scripts before any data writes. '
    'Optional p_allowed_db enforces that tests only run on a named test database.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 1. _has_contact_pii — PII property detector (R1, R7)
--
-- Returns TRUE when p_property is in the closed PII set defined in
-- PROPERTY_CONVENTIONS.md §5.1 for person:* entities.
-- Intentionally a thin lookup — no regex, no fuzzy match.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo._has_contact_pii(p_property TEXT)
RETURNS BOOLEAN
LANGUAGE sql IMMUTABLE PARALLEL SAFE AS $$
    -- PII property closed set (PROPERTY_CONVENTIONS.md §5.1).
    -- When adding a new PII property here, also update remember_fact documentation.
    SELECT p_property IN ('email', 'phone', 'address', 'telegram', 'full_name');
$$;

COMMENT ON FUNCTION pgmnemo._has_contact_pii(TEXT) IS
    'Returns TRUE when p_property is in the PII closed set: '
    '{email, phone, address, telegram, full_name}. '
    'Used by remember_fact() for automatic candidate-state routing on person:* entities. '
    'v0.12.0. Source: PROPERTY_CONVENTIONS.md §5.1 / ADR-61 D4.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 2. canonical_slug — slug normalisation helper (SLUG_CONVENTION.md §4)
--
-- Normalises a free-form label into a valid canonical slug:
--   ^(person|org|project|product|location|concept):[a-z0-9_]+$  ≤ 72 chars
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.canonical_slug(
    p_type  TEXT,   -- must be one of the six closed-set prefixes
    p_label TEXT    -- free-form label to normalise
)
RETURNS TEXT
LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    _id     TEXT;
    _slug   TEXT;
    _valid  CONSTANT TEXT[] := ARRAY['person','org','project','product','location','concept'];
BEGIN
    IF p_type IS NULL OR NOT (p_type = ANY(_valid)) THEN
        RAISE EXCEPTION
            'pgmnemo.canonical_slug: unknown type prefix ''%'' — '
            'must be one of: person, org, project, product, location, concept', p_type;
    END IF;
    IF p_label IS NULL OR length(trim(p_label)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.canonical_slug: p_label must not be NULL or empty';
    END IF;

    -- Normalisation steps (SLUG_CONVENTION.md §4):
    -- 1. Lower-case
    _id := lower(p_label);
    -- 2. Replace runs of non-[a-z0-9] characters with a single underscore
    _id := regexp_replace(_id, '[^a-z0-9]+', '_', 'g');
    -- 3. Strip leading and trailing underscores
    _id := trim(BOTH '_' FROM _id);
    -- 4. Truncate to 64 chars at last underscore boundary if needed
    IF length(_id) > 64 THEN
        _id := substring(_id FOR 64);
        -- back off to last underscore if present in the last 16 chars
        IF _id ~ '_' THEN
            _id := regexp_replace(_id, '_[^_]*$', '');
        END IF;
        -- trim again in case we backed off to a trailing underscore
        _id := trim(BOTH '_' FROM _id);
    END IF;
    -- 5. Build slug
    _slug := p_type || ':' || _id;
    -- 6. Validate
    IF _id = '' OR _slug !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION
            'pgmnemo.canonical_slug: could not normalise ''%'' into a valid slug '
            '(result was ''%'')', p_label, _slug;
    END IF;
    -- 7. Length guard (72 chars total)
    IF length(_slug) > 72 THEN
        RAISE EXCEPTION
            'pgmnemo.canonical_slug: resulting slug ''%'' exceeds 72 chars (%)',
            _slug, length(_slug);
    END IF;

    RETURN _slug;
END;
$$;

COMMENT ON FUNCTION pgmnemo.canonical_slug(TEXT, TEXT) IS
    'Normalise a free-form label into a canonical entity slug. '
    'Regex: ^(person|org|project|product|location|concept):[a-z0-9_]+$ ≤ 72 chars. '
    'Steps: lower-case → replace non-[a-z0-9] with _ → strip leading/trailing _ → '
    'truncate at 64-char id boundary → prepend type prefix. '
    'v0.12.0. Source: SLUG_CONVENTION.md §4.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 3. remember_fact — structured property write with bitemporal supersession
--    RFC-001 §D2 + ADDENDUM-2 R1–R7
--
-- State routing (R1, ADR-61 D4) — runs INSIDE the function, caller stays thin:
--   PII property on person:* entity → candidate ALWAYS (overrides source_type)
--   source_type = 'system'         → validated
--   source_type = 'auto_captured'  → candidate
--   agent_authored, non-PII, conf ≥ 0.8 → validated
--   everything else                → candidate
--
-- Artifact hash synthesis (R2) — COALESCE before provenance gate:
--   artifact_hash = COALESCE(p_artifact_hash, 'fact-'||entity_key||':'||property)
--   NULL entity_key → NULL hash → provenance gate rejects (correct behaviour)
--
-- Identity/dedup (R3): (lower(topic), project_id) with SELECT … FOR UPDATE
--   Same value  → MERGE  (update confidence in-place, no version bump)
--   New value   → SUPERSEDE (close old row, open version_n+1)
--   No prior    → INSERT fresh version_n=1
--
-- Topic encoding: entity_key || ':' || property  (PROPERTY_CONVENTIONS §1)
--
-- Returns: (id BIGINT, final_state TEXT)
--   final_state is the state assigned to the row (new or surviving merge row).
--   Callers can inspect final_state='candidate' and decide whether to call
--   pgmnemo.trust_record(id) to promote immediately.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.remember_fact(
    p_role            TEXT,
    p_entity_key      TEXT,               -- canonical slug e.g. 'person:ada_lovelace'
    p_property        TEXT,               -- property name e.g. 'affiliation'
    p_value           TEXT,               -- value assertion
    p_confidence      REAL     DEFAULT 0.7,
    p_has_contact_pii BOOLEAN  DEFAULT NULL,  -- R7: explicit override; NULL = auto-detect
    p_embedding       vector(1024) DEFAULT NULL,
    p_source_type     TEXT     DEFAULT NULL,  -- 'system'|'agent_authored'|'auto_captured'|'imported'
    p_project_id      INT      DEFAULT NULL,
    p_commit_sha      TEXT     DEFAULT NULL,
    p_artifact_hash   TEXT     DEFAULT NULL
)
RETURNS TABLE(id BIGINT, final_state TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    _topic          TEXT;
    _artifact_hash  TEXT;
    _is_pii         BOOLEAN;
    _final_state    TEXT;
    _prior          pgmnemo.agent_lesson%ROWTYPE;
    _new_id         BIGINT;
    _version_n      INT;
    _eff_source     TEXT;
BEGIN
    -- ── Input guards ─────────────────────────────────────────────────────────
    IF p_entity_key IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_entity_key must not be NULL';
    END IF;
    IF p_entity_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION
            'pgmnemo.remember_fact: invalid entity_key ''%'' — '
            'must match ^(person|org|project|product|location|concept):[a-z0-9_]+$',
            p_entity_key;
    END IF;
    IF p_property IS NULL OR length(trim(p_property)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_property must not be NULL or empty';
    END IF;
    IF p_value IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_value must not be NULL';
    END IF;
    IF p_confidence IS NOT NULL AND (p_confidence < 0.0 OR p_confidence > 1.0) THEN
        RAISE EXCEPTION
            'pgmnemo.remember_fact: p_confidence must be in [0.0, 1.0], got %', p_confidence;
    END IF;
    IF p_source_type IS NOT NULL AND
       p_source_type NOT IN ('system','agent_authored','auto_captured','imported') THEN
        RAISE EXCEPTION
            'pgmnemo.remember_fact: unknown source_type ''%'' — '
            'must be system|agent_authored|auto_captured|imported', p_source_type;
    END IF;

    -- ── Topic and artifact_hash (R2 — COALESCE slug BEFORE building) ─────────
    -- If entity_key is NULL, we already raised above, so _topic is always non-NULL.
    -- artifact_hash is synthesized so the provenance gate never rejects a
    -- well-formed remember_fact call, even under gate_strict='enforce'.
    _topic         := p_entity_key || ':' || p_property;
    _artifact_hash := COALESCE(
        p_artifact_hash,
        'fact-' || p_entity_key || ':' || p_property
    );

    -- ── PII detection (R1, R7) ───────────────────────────────────────────────
    -- p_has_contact_pii = explicit caller override (R7 first-class input)
    -- NULL = auto-detect: PII property AND entity is a person:* slug
    _is_pii := COALESCE(
        p_has_contact_pii,
        pgmnemo._has_contact_pii(p_property) AND (p_entity_key LIKE 'person:%')
    );

    -- ── State routing (R1, ADR-61 D4) ───────────────────────────────────────
    -- PII on person key → candidate ALWAYS (safety overrides even system source)
    IF _is_pii THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'system' THEN
        _final_state := 'validated';
    ELSIF p_source_type = 'auto_captured' THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.0) >= 0.8 THEN
        _final_state := 'validated';
    ELSE
        -- agent_authored with low confidence, imported, or NULL source_type → candidate
        _final_state := 'candidate';
    END IF;

    -- effective source_type for INSERT (normalise NULL)
    _eff_source := COALESCE(p_source_type, 'agent_authored');

    -- ── Identity/dedup (R3) — FOR UPDATE to prevent concurrent write races ───
    SELECT * INTO _prior
    FROM pgmnemo.agent_lesson
    WHERE lower(topic) = lower(_topic)
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ
    ORDER BY version_n DESC
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        IF lower(trim(_prior.lesson_text)) = lower(trim(p_value)) THEN
            -- ── MERGE: same value — update confidence in place ────────────────
            -- Do NOT auto-promote candidate → validated here; that's trust_record().
            -- Do update confidence monotonically (GREATEST wins).
            UPDATE pgmnemo.agent_lesson
            SET confidence  = GREATEST(confidence, COALESCE(p_confidence, 0.7)),
                updated_at  = NOW()
            WHERE id = _prior.id;

            RETURN QUERY SELECT _prior.id, _prior.state::TEXT;
            RETURN;
        ELSE
            -- ── SUPERSEDE: different value — close prior, open new version ─────
            UPDATE pgmnemo.agent_lesson
            SET t_valid_to  = NOW(),
                state       = 'superseded',
                is_active   = FALSE,
                updated_at  = NOW()
            WHERE id = _prior.id;

            _version_n := COALESCE(_prior.version_n, 0) + 1;
        END IF;
    ELSE
        _version_n := 1;
    END IF;

    -- ── INSERT new fact row ───────────────────────────────────────────────────
    INSERT INTO pgmnemo.agent_lesson (
        role,
        project_id,
        topic,
        lesson_text,
        importance,
        embedding,
        commit_sha,
        artifact_hash,
        metadata,
        source_type,
        content_type,
        state,
        confidence,
        version_n,
        verified_at,
        t_valid_from,
        t_valid_to
    ) VALUES (
        p_role,
        p_project_id,
        _topic,
        p_value,
        3,                   -- default importance; callers can update separately
        p_embedding,         -- NULL = text-only (BM25 path); not a ghost-exclusion
        p_commit_sha,
        _artifact_hash,      -- never NULL (R2)
        jsonb_build_object(
            'canonical_name', p_entity_key,
            'entity_key',     p_entity_key,
            'property',       p_property
        ),
        _eff_source,
        'fact',
        _final_state,
        COALESCE(p_confidence, 0.7),
        _version_n,
        -- verified_at gates default recall: validated → visible, candidate → ghost
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        NOW(),
        'infinity'::TIMESTAMPTZ
    )
    RETURNING agent_lesson.id INTO _new_id;

    RETURN QUERY SELECT _new_id, _final_state;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_fact(TEXT,TEXT,TEXT,TEXT,REAL,BOOLEAN,vector,TEXT,INT,TEXT,TEXT) IS
    'Typed fact write with bitemporal supersession, PII-aware state routing, '
    'and synthesized artifact_hash. RFC-001 §D2 + ADDENDUM-2 R1–R7. v0.12.0. '
    'State routing (ADR-61 D4): '
    '  PII property on person:* → candidate ALWAYS; '
    '  source_type=system → validated; '
    '  source_type=auto_captured → candidate; '
    '  agent_authored non-PII confidence≥0.8 → validated; '
    '  all others → candidate. '
    'Returns (id BIGINT, final_state TEXT). '
    'candidate rows have verified_at=NULL — invisible to default recall until '
    'promoted via pgmnemo.trust_record(id). '
    'Merge (same value): confidence updated in-place; no new version. '
    'Supersede (new value): prior row closed (t_valid_to=NOW(), state=superseded); '
    '  new row opened with version_n=prior+1.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 4. remember_event — immutable event record (append-only)
--    RFC-001 §D2 / content_type = 'event'
--
-- Events are immutable records of what happened at a specific time.
-- No dedup, no bitemporal close, no supersession.
-- Topic: entity_key || ':event:' || event_label
-- State routing: same PII-aware logic as remember_fact for consistency.
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.remember_event(
    p_role          TEXT,
    p_entity_key    TEXT,               -- canonical slug
    p_event_label   TEXT,               -- slug within entity scope
    p_event_body    TEXT,
    p_occurred_at   TIMESTAMPTZ DEFAULT NOW(),
    p_confidence    REAL        DEFAULT 0.8,
    p_embedding     vector(1024) DEFAULT NULL,
    p_source_type   TEXT        DEFAULT NULL,
    p_project_id    INT         DEFAULT NULL,
    p_commit_sha    TEXT        DEFAULT NULL,
    p_artifact_hash TEXT        DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    _topic          TEXT;
    _artifact_hash  TEXT;
    _final_state    TEXT;
    _new_id         BIGINT;
BEGIN
    -- Input guards
    IF p_entity_key IS NULL OR p_entity_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION
            'pgmnemo.remember_event: invalid entity_key ''%''', p_entity_key;
    END IF;
    IF p_event_label IS NULL OR length(trim(p_event_label)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.remember_event: p_event_label must not be NULL or empty';
    END IF;
    IF p_event_body IS NULL OR length(trim(p_event_body)) < 1 THEN
        RAISE EXCEPTION 'pgmnemo.remember_event: p_event_body must not be NULL or empty';
    END IF;

    _topic         := p_entity_key || ':event:' || p_event_label;
    _artifact_hash := COALESCE(
        p_artifact_hash,
        'event-' || p_entity_key || ':' || p_event_label
    );

    -- Events default to validated unless auto_captured (events are usually observed facts)
    IF p_source_type = 'auto_captured' THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'system' THEN
        _final_state := 'validated';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.8) >= 0.8 THEN
        _final_state := 'validated';
    ELSE
        _final_state := 'candidate';
    END IF;

    -- Events are always append-only — no dedup, no supersession
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        embedding, commit_sha, artifact_hash, metadata,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to
    ) VALUES (
        p_role, p_project_id, _topic, p_event_body, 3,
        p_embedding, p_commit_sha, _artifact_hash,
        jsonb_build_object(
            'entity_key',   p_entity_key,
            'event_label',  p_event_label,
            'occurred_at',  p_occurred_at
        ),
        COALESCE(p_source_type, 'agent_authored'),
        'event',
        _final_state,
        COALESCE(p_confidence, 0.8),
        1,
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        COALESCE(p_occurred_at, NOW()),
        'infinity'::TIMESTAMPTZ
    )
    RETURNING agent_lesson.id INTO _new_id;

    RETURN _new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_event(TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,REAL,vector,TEXT,INT,TEXT,TEXT) IS
    'Immutable event record write. Append-only — no supersession, no dedup. '
    'content_type=event. Topic: entity_key:event:event_label. '
    'RFC-001 §D2. v0.12.0.';

-- ─────────────────────────────────────────────────────────────────────────────
-- 5. remember_relation — directed typed association between two entities
--    RFC-001 §D2 / content_type = 'relation'
--
-- Idempotent on the triple (from_key, to_key, relation_type).
-- Also writes a mem_edge row via pgmnemo.add_edge() when entity hub IDs are
-- discoverable. Both writes are inside one transaction (atomic rollback).
-- Topic: from_key || ':' || relation_type || ':' || to_key
-- ─────────────────────────────────────────────────────────────────────────────

CREATE OR REPLACE FUNCTION pgmnemo.remember_relation(
    p_role          TEXT,
    p_from_key      TEXT,               -- source entity slug
    p_to_key        TEXT,               -- target entity slug
    p_relation_type TEXT,               -- e.g. 'works_for', 'depends_on'
    p_confidence    REAL    DEFAULT 0.7,
    p_embedding     vector(1024) DEFAULT NULL,
    p_source_type   TEXT    DEFAULT NULL,
    p_project_id    INT     DEFAULT NULL,
    p_commit_sha    TEXT    DEFAULT NULL,
    p_artifact_hash TEXT    DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql AS $$
DECLARE
    _topic          TEXT;
    _artifact_hash  TEXT;
    _final_state    TEXT;
    _prior_id       BIGINT;
    _new_id         BIGINT;
    _from_hub_id    BIGINT;
    _to_hub_id      BIGINT;
BEGIN
    -- Input guards
    IF p_from_key IS NULL OR p_from_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'pgmnemo.remember_relation: invalid from_key ''%''', p_from_key;
    END IF;
    IF p_to_key IS NULL OR p_to_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'pgmnemo.remember_relation: invalid to_key ''%''', p_to_key;
    END IF;
    IF p_relation_type IS NULL OR length(trim(p_relation_type)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.remember_relation: p_relation_type must not be NULL or empty';
    END IF;

    _topic         := p_from_key || ':' || p_relation_type || ':' || p_to_key;
    _artifact_hash := COALESCE(
        p_artifact_hash,
        'rel-' || p_from_key || ':' || p_relation_type || ':' || p_to_key
    );

    -- State routing (no PII gate for relations; non-person entities)
    IF p_source_type = 'system' THEN
        _final_state := 'validated';
    ELSIF p_source_type = 'auto_captured' THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.7) >= 0.8 THEN
        _final_state := 'validated';
    ELSE
        _final_state := 'candidate';
    END IF;

    -- Idempotency: check for existing active relation on same triple
    SELECT id INTO _prior_id
    FROM pgmnemo.agent_lesson
    WHERE lower(topic) = lower(_topic)
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ
    LIMIT 1
    FOR UPDATE;

    IF FOUND THEN
        -- MERGE: update confidence monotonically
        UPDATE pgmnemo.agent_lesson
        SET confidence = GREATEST(confidence, COALESCE(p_confidence, 0.7)),
            updated_at = NOW()
        WHERE id = _prior_id;
        RETURN _prior_id;
    END IF;

    -- INSERT new relation row
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        embedding, commit_sha, artifact_hash, metadata,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to
    ) VALUES (
        p_role, p_project_id, _topic,
        p_from_key || ' ' || p_relation_type || ' ' || p_to_key,
        3,
        p_embedding, p_commit_sha, _artifact_hash,
        jsonb_build_object(
            'from_key',       p_from_key,
            'to_key',         p_to_key,
            'relation_type',  p_relation_type
        ),
        COALESCE(p_source_type, 'agent_authored'),
        'relation',
        _final_state,
        COALESCE(p_confidence, 0.7),
        1,
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        NOW(),
        'infinity'::TIMESTAMPTZ
    )
    RETURNING agent_lesson.id INTO _new_id;

    -- Attempt to wire mem_edge between entity hub rows if discoverable.
    -- Failure here is non-fatal (hubs may not exist yet); logged as NOTICE.
    BEGIN
        SELECT id INTO _from_hub_id
        FROM pgmnemo.agent_lesson
        WHERE content_type = 'entity'
          AND lower(topic) = lower(p_from_key)
          AND (p_project_id IS NULL OR project_id = p_project_id)
          AND is_active AND t_valid_to = 'infinity'::TIMESTAMPTZ
        LIMIT 1;

        SELECT id INTO _to_hub_id
        FROM pgmnemo.agent_lesson
        WHERE content_type = 'entity'
          AND lower(topic) = lower(p_to_key)
          AND (p_project_id IS NULL OR project_id = p_project_id)
          AND is_active AND t_valid_to = 'infinity'::TIMESTAMPTZ
        LIMIT 1;

        IF _from_hub_id IS NOT NULL AND _to_hub_id IS NOT NULL THEN
            PERFORM pgmnemo.add_edge(
                _from_hub_id, _to_hub_id,
                p_relation_type,
                COALESCE(p_confidence, 0.7)::FLOAT8,
                jsonb_build_object('relation_lesson_id', _new_id),
                'max'
            );
        ELSE
            RAISE NOTICE
                'pgmnemo.remember_relation: entity hubs not found for ''%'' or ''%'' '
                '— mem_edge not created; relation lesson_id=% recorded.',
                p_from_key, p_to_key, _new_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE
            'pgmnemo.remember_relation: add_edge failed (lesson_id=%): %',
            _new_id, SQLERRM;
    END;

    RETURN _new_id;
END;
$$;

COMMENT ON FUNCTION pgmnemo.remember_relation(TEXT,TEXT,TEXT,TEXT,REAL,vector,TEXT,INT,TEXT,TEXT) IS
    'Directed typed relation write between two entity slugs. '
    'Idempotent on (from_key, relation_type, to_key): merges confidence on re-write. '
    'Attempts to wire a mem_edge between entity hub rows; skips with NOTICE if hubs absent. '
    'content_type=relation. RFC-001 §D2. v0.12.0.';
