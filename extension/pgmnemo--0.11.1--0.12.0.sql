-- pgmnemo--0.11.1--0.12.0.sql
-- pgmnemo upgrade 0.11.1 → 0.12.0
-- v0.12.0: Typed Write API — remember_fact / remember_event / remember_relation
-- RFC-001 §D2 + ADDENDUM-2 (7 correctness requirements)
--
-- No breaking changes. No schema column additions. All new symbols.
-- SPDX-License-Identifier: Apache-2.0

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.12.0'" to load this file. \quit

DO $$ BEGIN RAISE NOTICE 'pgmnemo: upgrading to version 0.12.0 (Typed Write API)'; END; $$;

-- ADDENDUM-2 R8: Ensure uq_mem_edge_active partial index exists.
-- add_edge() uses ON CONFLICT (source_id, target_id, relation_type) WHERE valid_until IS NULL
-- which requires this partial unique index. Created in 0.5.0 delta; re-asserted here
-- defensively (IF NOT EXISTS) to guard against non-standard upgrade paths or direct SQL installs.
CREATE UNIQUE INDEX IF NOT EXISTS uq_mem_edge_active
    ON pgmnemo.mem_edge (source_id, target_id, relation_type)
    WHERE valid_until IS NULL;

COMMENT ON INDEX pgmnemo.uq_mem_edge_active IS
    'Partial unique index on active edges (valid_until IS NULL). '
    'Enables ON CONFLICT upsert in add_edge(). Created in 0.5.0; re-asserted in 0.12.0 (ADDENDUM-2 R8).';

CREATE UNIQUE INDEX IF NOT EXISTS ix_entity_canonical_name_prj
    ON pgmnemo.agent_lesson (
        lower(metadata->>'canonical_name'),
        COALESCE(project_id, -1)
    )
    WHERE content_type = 'entity'
      AND is_active
      AND t_valid_to = 'infinity'::TIMESTAMPTZ;

COMMENT ON INDEX pgmnemo.ix_entity_canonical_name_prj IS
    'Unique entity hub per (lower(canonical_name), project_id). v0.12.0.';

-- guard_no_test_project
CREATE OR REPLACE FUNCTION pgmnemo.guard_no_test_project(
    p_project_id INT,
    p_allowed_db TEXT DEFAULT NULL
) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    IF p_project_id IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: p_project_id IS NULL — tests must use an explicit test project_id';
    END IF;
    IF p_project_id <= 100 THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: project_id=% looks like a production ID (<=100). Use project_id > 10000.', p_project_id;
    END IF;
    IF p_allowed_db IS NOT NULL AND current_database() <> p_allowed_db THEN
        RAISE EXCEPTION 'pgmnemo.guard_no_test_project: must run on ''%'', current db is ''%''.', p_allowed_db, current_database();
    END IF;
END;
$$;
COMMENT ON FUNCTION pgmnemo.guard_no_test_project(INT, TEXT) IS 'Safety guard for test harnesses (R6, v0.12.0). Raises when project_id<=100 (production sentinel).';

-- _evict_prior_lesson: shared bitemporal eviction helper (RFC-001 §D3 / ADDENDUM-2 R3)
-- Called by remember_fact and remember_relation to close a prior active row.
-- Centralises the t_valid_to / state / is_active / updated_at update so that
-- all supersession paths are byte-for-byte identical and a single fix propagates everywhere.
CREATE OR REPLACE FUNCTION pgmnemo._evict_prior_lesson(p_lesson_id BIGINT)
RETURNS VOID LANGUAGE sql AS $$
    UPDATE pgmnemo.agent_lesson
    SET t_valid_to = NOW(),
        state      = 'superseded',
        is_active  = FALSE,
        updated_at = NOW()
    WHERE id = p_lesson_id;
$$;
COMMENT ON FUNCTION pgmnemo._evict_prior_lesson(BIGINT) IS
    'Bitemporal eviction: close active lesson (t_valid_to=NOW, state=superseded, is_active=FALSE). '
    'Shared helper called by remember_fact + remember_relation supersession paths. '
    'RFC-001 §D3 + ADDENDUM-2 R3. v0.12.0.';

-- _has_contact_pii
CREATE OR REPLACE FUNCTION pgmnemo._has_contact_pii(p_property TEXT)
RETURNS BOOLEAN LANGUAGE sql IMMUTABLE STRICT PARALLEL SAFE AS $$
    SELECT p_property IN ('email', 'phone', 'address', 'telegram', 'full_name');
$$;
COMMENT ON FUNCTION pgmnemo._has_contact_pii(TEXT) IS 'PII property detector. Returns TRUE for {email,phone,address,telegram,full_name}. PROPERTY_CONVENTIONS §5.1 / ADR-61 D4. v0.12.0.';

-- canonical_slug
CREATE OR REPLACE FUNCTION pgmnemo.canonical_slug(p_type TEXT, p_label TEXT)
RETURNS TEXT LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE AS $$
DECLARE
    _id    TEXT;
    _slug  TEXT;
    _valid CONSTANT TEXT[] := ARRAY['person','org','project','product','location','concept'];
BEGIN
    IF p_type IS NULL OR NOT (p_type = ANY(_valid)) THEN
        RAISE EXCEPTION 'pgmnemo.canonical_slug: unknown type prefix ''%'' — must be one of: person, org, project, product, location, concept', p_type;
    END IF;
    IF p_label IS NULL OR length(trim(p_label)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.canonical_slug: p_label must not be NULL or empty';
    END IF;
    _id := lower(p_label);
    _id := regexp_replace(_id, '[^a-z0-9]+', '_', 'g');
    _id := trim(BOTH '_' FROM _id);
    IF length(_id) > 64 THEN
        _id := substring(_id FOR 64);
        IF _id ~ '_' THEN _id := regexp_replace(_id, '_[^_]*$', ''); END IF;
        _id := trim(BOTH '_' FROM _id);
    END IF;
    _slug := p_type || ':' || _id;
    IF _id = '' OR _slug !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'pgmnemo.canonical_slug: could not normalise ''%'' (result: ''%'')', p_label, _slug;
    END IF;
    IF length(_slug) > 72 THEN
        RAISE EXCEPTION 'pgmnemo.canonical_slug: slug ''%'' exceeds 72 chars', _slug;
    END IF;
    RETURN _slug;
END;
$$;
COMMENT ON FUNCTION pgmnemo.canonical_slug(TEXT, TEXT) IS 'Normalise label into canonical slug ^(person|org|project|product|location|concept):[a-z0-9_]+$ <=72. SLUG_CONVENTION §4. v0.12.0.';

-- remember_fact
CREATE OR REPLACE FUNCTION pgmnemo.remember_fact(
    p_role            TEXT,
    p_entity_key      TEXT,
    p_property        TEXT,
    p_value           TEXT,
    p_confidence      REAL        DEFAULT 0.7,
    p_has_contact_pii BOOLEAN     DEFAULT NULL,
    p_embedding       vector(1024) DEFAULT NULL,
    p_source_type     TEXT        DEFAULT NULL,
    p_project_id      INT         DEFAULT NULL,
    p_commit_sha      TEXT        DEFAULT NULL,
    p_artifact_hash   TEXT        DEFAULT NULL
) RETURNS TABLE(id BIGINT, final_state TEXT)
LANGUAGE plpgsql AS $$
DECLARE
    _topic         TEXT;
    _artifact_hash TEXT;
    _is_pii        BOOLEAN;
    _final_state   TEXT;
    _merge_state   TEXT;    -- actual post-merge state (may differ from _final_state for promote)
    _prior         pgmnemo.agent_lesson%ROWTYPE;
    _new_id        BIGINT;
    _version_n     INT;
    _eff_source    TEXT;
BEGIN
    -- Input guards
    IF p_entity_key IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_entity_key must not be NULL';
    END IF;
    IF p_entity_key !~ '^(person|org|project|product|location|concept):[a-z0-9_]+$' THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: invalid entity_key ''%'' — must match slug regex', p_entity_key;
    END IF;
    IF p_property IS NULL OR length(trim(p_property)) = 0 THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_property must not be NULL or empty';
    END IF;
    IF p_value IS NULL THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_value must not be NULL';
    END IF;
    IF p_confidence IS NOT NULL AND (p_confidence < 0.0 OR p_confidence > 1.0) THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: p_confidence % out of [0,1]', p_confidence;
    END IF;
    IF p_source_type IS NOT NULL AND
       p_source_type NOT IN ('system','agent_authored','auto_captured','imported') THEN
        RAISE EXCEPTION 'pgmnemo.remember_fact: invalid source_type ''%''', p_source_type;
    END IF;

    -- R2: Synthesize artifact_hash (COALESCE BEFORE gate can inspect)
    -- topic: lower(entity_key)/lower(property) per RFC-001 §D2
    _topic         := lower(p_entity_key) || '/' || lower(p_property);
    _artifact_hash := COALESCE(p_artifact_hash, 'fact-' || p_entity_key || ':' || p_property);

    -- R1/R7: PII detection — explicit override wins, else auto-detect
    _is_pii := COALESCE(
        p_has_contact_pii,
        pgmnemo._has_contact_pii(p_property) AND (p_entity_key LIKE 'person:%')
    );

    -- R1: State routing (ADR-61 D4)
    -- PII on person:* → candidate ALWAYS (even system source)
    IF _is_pii THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'system' THEN
        _final_state := 'validated';
    ELSIF p_source_type = 'auto_captured' THEN
        _final_state := 'candidate';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.0) >= 0.8 THEN
        _final_state := 'validated';
    ELSE
        -- agent_authored low-conf, imported, NULL source_type → candidate
        _final_state := 'candidate';
    END IF;

    _eff_source := COALESCE(p_source_type, 'agent_authored');

    -- R3: Identity/dedup on (lower(topic), project_id) with FOR UPDATE
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
            -- MERGE: same value — update confidence + promote state, no new version.
            -- Promotion rule: 'validated' wins over 'candidate'/'draft'; never demote.
            UPDATE pgmnemo.agent_lesson
            SET confidence = GREATEST(confidence, COALESCE(p_confidence, 0.7)),
                state      = CASE
                                 WHEN _final_state = 'validated'
                                      AND state NOT IN ('validated', 'canonical')
                                 THEN 'validated'
                                 ELSE state
                             END
            WHERE agent_lesson.id = _prior.id
            RETURNING agent_lesson.state INTO _merge_state;
            RETURN QUERY SELECT _prior.id, _merge_state;
            RETURN;
        ELSE
            -- SUPERSEDE: different value — close prior row via shared eviction helper, open new version
            PERFORM pgmnemo._evict_prior_lesson(_prior.id);
            _version_n := COALESCE(_prior.version_n, 0) + 1;
        END IF;
    ELSE
        _version_n := 1;
    END IF;

    -- INSERT new fact row
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        embedding, commit_sha, artifact_hash, metadata,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to
    ) VALUES (
        p_role, p_project_id, _topic, p_value, 3,
        p_embedding, p_commit_sha, _artifact_hash,
        jsonb_build_object(
            'canonical_name', p_entity_key,
            'entity_key',     p_entity_key,
            'property',       p_property
        ),
        _eff_source, 'fact', _final_state,
        COALESCE(p_confidence, 0.7),
        _version_n,
        -- validated → visible to recall; candidate → ghost (verified_at NULL)
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        NOW(),
        'infinity'::TIMESTAMPTZ
    )
    RETURNING agent_lesson.id INTO _new_id;

    RETURN QUERY SELECT _new_id, _final_state;
END;
$$;
COMMENT ON FUNCTION pgmnemo.remember_fact(TEXT,TEXT,TEXT,TEXT,REAL,BOOLEAN,vector,TEXT,INT,TEXT,TEXT) IS
    'Typed fact write with bitemporal supersession, PII-aware state routing, synthesized artifact_hash. RFC-001 §D2 + ADDENDUM-2 R1-R7. v0.12.0.';

-- remember_event
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

    -- R3: Idempotency — FOR UPDATE dedup on (lower(topic), project_id).
    -- Events are append-only (no supersession); same (entity_key, event_label, project_id)
    -- returns the existing row id. Prevents duplicate event rows across concurrent writes.
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
        jsonb_build_object('entity_key', p_entity_key, 'event_label', p_event_label, 'occurred_at', p_occurred_at),
        COALESCE(p_source_type, 'agent_authored'), 'event', _final_state,
        COALESCE(p_confidence, 0.8), 1,
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        COALESCE(p_occurred_at, NOW()), 'infinity'::TIMESTAMPTZ
    ) RETURNING agent_lesson.id INTO _new_id;
    RETURN _new_id;
END;
$$;
COMMENT ON FUNCTION pgmnemo.remember_event(TEXT,TEXT,TEXT,TEXT,TIMESTAMPTZ,REAL,vector,TEXT,INT,TEXT,TEXT) IS 'Immutable event record. Append-only. content_type=event. RFC-001 §D2. v0.12.0.';

-- remember_relation
CREATE OR REPLACE FUNCTION pgmnemo.remember_relation(
    p_role          TEXT,
    p_from_key      TEXT,
    p_to_key        TEXT,
    p_relation_type TEXT,
    p_confidence    REAL         DEFAULT 0.7,
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
    _prior_id      BIGINT;
    _new_id        BIGINT;
    _from_hub_id   BIGINT;
    _to_hub_id     BIGINT;
BEGIN
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
    _artifact_hash := COALESCE(p_artifact_hash, 'rel-' || p_from_key || ':' || p_relation_type || ':' || p_to_key);
    IF p_source_type = 'system' THEN _final_state := 'validated';
    ELSIF p_source_type = 'auto_captured' THEN _final_state := 'candidate';
    ELSIF p_source_type = 'agent_authored' AND COALESCE(p_confidence, 0.7) >= 0.8 THEN _final_state := 'validated';
    ELSE _final_state := 'candidate';
    END IF;
    SELECT id INTO _prior_id FROM pgmnemo.agent_lesson
    WHERE lower(topic) = lower(_topic)
      AND (p_project_id IS NULL OR project_id = p_project_id)
      AND is_active AND t_valid_to = 'infinity'::TIMESTAMPTZ
    LIMIT 1 FOR UPDATE;
    IF FOUND THEN
        UPDATE pgmnemo.agent_lesson SET confidence = GREATEST(confidence, COALESCE(p_confidence, 0.7)), updated_at = NOW() WHERE agent_lesson.id = _prior_id;
        RETURN _prior_id;
    END IF;
    INSERT INTO pgmnemo.agent_lesson (
        role, project_id, topic, lesson_text, importance,
        embedding, commit_sha, artifact_hash, metadata,
        source_type, content_type, state, confidence,
        version_n, verified_at, t_valid_from, t_valid_to
    ) VALUES (
        p_role, p_project_id, _topic,
        p_from_key || ' ' || p_relation_type || ' ' || p_to_key, 3,
        p_embedding, p_commit_sha, _artifact_hash,
        jsonb_build_object('from_key', p_from_key, 'to_key', p_to_key, 'relation_type', p_relation_type),
        COALESCE(p_source_type, 'agent_authored'), 'relation', _final_state,
        COALESCE(p_confidence, 0.7), 1,
        CASE WHEN _final_state = 'validated' THEN NOW() ELSE NULL END,
        NOW(), 'infinity'::TIMESTAMPTZ
    ) RETURNING agent_lesson.id INTO _new_id;
    BEGIN
        SELECT id INTO _from_hub_id FROM pgmnemo.agent_lesson WHERE content_type = 'entity' AND lower(topic) = lower(p_from_key) AND (p_project_id IS NULL OR project_id = p_project_id) AND is_active AND t_valid_to = 'infinity'::TIMESTAMPTZ LIMIT 1;
        SELECT id INTO _to_hub_id FROM pgmnemo.agent_lesson WHERE content_type = 'entity' AND lower(topic) = lower(p_to_key) AND (p_project_id IS NULL OR project_id = p_project_id) AND is_active AND t_valid_to = 'infinity'::TIMESTAMPTZ LIMIT 1;
        IF _from_hub_id IS NOT NULL AND _to_hub_id IS NOT NULL THEN
            PERFORM pgmnemo.add_edge(_from_hub_id, _to_hub_id, p_relation_type, COALESCE(p_confidence, 0.7)::FLOAT8, jsonb_build_object('relation_lesson_id', _new_id), 'max');
        ELSE
            RAISE NOTICE 'pgmnemo.remember_relation: entity hubs not found for ''%'' or ''%'' — mem_edge skipped; lesson_id=% recorded.', p_from_key, p_to_key, _new_id;
        END IF;
    EXCEPTION WHEN OTHERS THEN
        RAISE NOTICE 'pgmnemo.remember_relation: add_edge failed (lesson_id=%): %', _new_id, SQLERRM;
    END;
    RETURN _new_id;
END;
$$;
COMMENT ON FUNCTION pgmnemo.remember_relation(TEXT,TEXT,TEXT,TEXT,REAL,vector,TEXT,INT,TEXT,TEXT) IS 'Directed typed relation. Idempotent on triple. content_type=relation. RFC-001 §D2. v0.12.0.';

