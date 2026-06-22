-- typed_write_api.sql
-- pg_regress tests for pgmnemo v0.11.0 P1.1 — typed WRITE API
-- ADR-61 §3 D2 / MEM-ERA-P1.1
--
-- Coverage:
--   T1:  canonical_slug — valid pass-through
--   T2:  canonical_slug — normalisation (uppercase, spaces, special chars)
--   T3:  remember_fact — supersession: different value → version_n=2, old=superseded
--   T4:  remember_fact — same-value merge: patch_count++, confidence lifted
--   T5:  remember_fact — PII gate: auto_captured + person:* + email → candidate
--   T6:  remember_fact — PII gate: system + person:* + email → validated (conf≥0.8)
--   T7:  remember_event — append-only: two calls → two distinct lesson rows
--   T8:  remember_event — content_type='event', state='validated' for conf≥0.5
--   T9:  remember_relation — auto-stub missing entities + returns edge_id > 0
--   T10: remember_relation — idempotent triple: second call returns same edge_id
--   T11: remember_relation — auto-stub entities visible in entity-hub
--   T12: remember_relation — metadata update: closes old edge, inserts new

-- Isolated role prefix: twa (typed-write-api)
-- Gate off so provenance gate does not interfere with test inserts.
SET pgmnemo.gate_strict = 'off';
SET pgmnemo.include_unverified = 'on';
SET pgmnemo.track_recall_recency = 'off';

ALTER EXTENSION pgmnemo UPDATE TO '0.11.0';

-- ─────────────────────────────────────────────────────────────────────────────
-- T1: canonical_slug — valid key passes through unchanged
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.canonical_slug('person:alice') AS t1_slug;

-- ─────────────────────────────────────────────────────────────────────────────
-- T2: canonical_slug — normalisation: upper+space+special → lower+underscore
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.canonical_slug('Org:ACME Corp!') AS t2_slug;

-- ─────────────────────────────────────────────────────────────────────────────
-- T3: remember_fact — supersession
--     Insert fact v1 for person:twa_sup:city = 'Moscow',
--     then overwrite with 'Berlin'.
--     Expect: v1 row state='superseded', is_active=false;
--             v2 row version_n=2, is_active=true.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_fact(
    'twa', 1, 'person:twa_sup', 'city', 'Moscow', 0.9, 'system'
) > 0 AS t3a_v1_inserted;

SELECT pgmnemo.remember_fact(
    'twa', 1, 'person:twa_sup', 'city', 'Berlin', 0.9, 'system'
) > 0 AS t3b_v2_inserted;

-- Prior version must be superseded and inactive.
SELECT
    state    = 'superseded' AS t3_old_superseded,
    is_active = FALSE        AS t3_old_inactive
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'person:twa_sup:city' AND lesson_text = 'Moscow';

-- New version must have version_n=2 and be active.
SELECT
    version_n = 2 AS t3_version_2,
    is_active = TRUE AS t3_new_active,
    lesson_text = 'Berlin' AS t3_new_value
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'person:twa_sup:city' AND is_active = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- T4: remember_fact — same-value merge
--     Insert fact, then call again with same value but higher confidence.
--     Expect: single active row, patch_count=1, confidence lifted.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_fact(
    'twa', 1, 'person:twa_mrg', 'age', '30', 0.7, 'system'
) > 0 AS t4a_inserted;

SELECT pgmnemo.remember_fact(
    'twa', 1, 'person:twa_mrg', 'age', '30', 0.95, 'system'
) > 0 AS t4b_merged;

SELECT
    patch_count = 1        AS t4_patch_incremented,
    confidence >= 0.94     AS t4_confidence_lifted,
    version_n = 1          AS t4_still_version_1
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'person:twa_mrg:age' AND is_active = TRUE;

-- Only one active fact row for this entity+property.
SELECT count(*) AS t4_single_active_row
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'person:twa_mrg:age'
  AND is_active = TRUE AND t_valid_to = 'infinity'::timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────
-- T5: PII gate — auto_captured + person:* + email → candidate
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_fact(
    'twa', 1, 'person:twa_pii1', 'email', 'pii1@test.com', 0.9, 'auto_captured'
) > 0 AS t5_pii_inserted;

SELECT state = 'candidate' AS t5_pii_is_candidate
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'person:twa_pii1:email' AND is_active = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- T6: PII gate — system source + person:* + email + conf≥0.8 → validated
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_fact(
    'twa', 1, 'person:twa_pii2', 'email', 'pii2@test.com', 0.9, 'system'
) > 0 AS t6_pii_system_inserted;

SELECT state = 'validated' AS t6_pii_system_is_validated
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'person:twa_pii2:email' AND is_active = TRUE;

-- ─────────────────────────────────────────────────────────────────────────────
-- T7: remember_event — append-only: two calls → two distinct IDs
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_event(
    'twa', 1, 'person:twa_evt', 'login',
    '2026-01-01 10:00:00+00'::timestamptz, 'Login attempt 1'
) AS t7_evt1_id
INTO TEMPORARY TABLE _t7_e1;

SELECT pgmnemo.remember_event(
    'twa', 1, 'person:twa_evt', 'login',
    '2026-01-01 10:01:00+00'::timestamptz, 'Login attempt 2'
) AS t7_evt2_id
INTO TEMPORARY TABLE _t7_e2;

SELECT (SELECT t7_evt1_id FROM _t7_e1) <> (SELECT t7_evt2_id FROM _t7_e2)
    AS t7_two_distinct_ids;

DROP TABLE _t7_e1;
DROP TABLE _t7_e2;

-- ─────────────────────────────────────────────────────────────────────────────
-- T8: remember_event — content_type='event', state='validated' for conf≥0.5
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_event(
    'twa', 1, 'project:twa_proj', 'deploy',
    '2026-06-22 08:00:00+00'::timestamptz, 'Deployed v1.0', 0.9
) > 0 AS t8_event_inserted;

SELECT
    content_type = 'event' AS t8_content_type_event,
    state        = 'validated' AS t8_state_validated,
    t_valid_from = '2026-06-22 08:00:00+00'::timestamptz AS t8_t_valid_from_correct
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND topic = 'project:twa_proj:event:deploy'
ORDER BY id DESC LIMIT 1;

-- ─────────────────────────────────────────────────────────────────────────────
-- T9: remember_relation — auto-stub missing entities, returns edge_id > 0
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_relation(
    'twa', 1, 'person:twa_alice', 'org:twa_corp', 'MEMBER_OF', 0.8
) > 0 AS t9_edge_created;

-- ─────────────────────────────────────────────────────────────────────────────
-- T10: remember_relation — idempotent on same triple+metadata
--      Second call with same args must return the same edge_id.
-- ─────────────────────────────────────────────────────────────────────────────

SELECT pgmnemo.remember_relation(
    'twa', 1, 'person:twa_alice', 'org:twa_corp', 'MEMBER_OF', 0.8
) AS t10_eid1
INTO TEMPORARY TABLE _t10_r1;

SELECT pgmnemo.remember_relation(
    'twa', 1, 'person:twa_alice', 'org:twa_corp', 'MEMBER_OF', 0.8
) AS t10_eid2
INTO TEMPORARY TABLE _t10_r2;

SELECT (SELECT t10_eid1 FROM _t10_r1) = (SELECT t10_eid2 FROM _t10_r2)
    AS t10_idempotent_same_edge_id;

DROP TABLE _t10_r1;
DROP TABLE _t10_r2;

-- Only ONE active edge for the triple after two calls.
SELECT count(*) AS t10_one_active_edge
FROM pgmnemo.mem_edge me
JOIN pgmnemo.agent_lesson al_f ON al_f.id = me.source_id
JOIN pgmnemo.agent_lesson al_t ON al_t.id = me.target_id
WHERE al_f.topic = 'person:twa_alice' AND al_t.topic = 'org:twa_corp'
  AND me.relation_type = 'MEMBER_OF' AND me.valid_until IS NULL;

-- ─────────────────────────────────────────────────────────────────────────────
-- T11: auto-stub entities are visible in entity-hub
-- ─────────────────────────────────────────────────────────────────────────────

SELECT count(*) = 2 AS t11_two_stubs_created
FROM pgmnemo.agent_lesson
WHERE role = 'twa' AND content_type = 'entity'
  AND topic IN ('person:twa_alice', 'org:twa_corp')
  AND is_active = TRUE
  AND t_valid_to = 'infinity'::timestamptz;

-- ─────────────────────────────────────────────────────────────────────────────
-- T12: remember_relation — metadata change → closes old edge, inserts new
-- ─────────────────────────────────────────────────────────────────────────────

-- First call: create relation between two new entities.
SELECT pgmnemo.remember_relation(
    'twa', 1, 'concept:twa_src', 'concept:twa_dst', 'DERIVED_FROM', 0.7
) AS t12_eid1
INTO TEMPORARY TABLE _t12_r1;

-- Second call: same triple but different extra metadata → close + new.
SELECT pgmnemo.remember_relation(
    'twa', 1, 'concept:twa_src', 'concept:twa_dst', 'DERIVED_FROM', 0.7,
    '{"version": 2}'::jsonb
) AS t12_eid2
INTO TEMPORARY TABLE _t12_r2;

-- Old edge must be closed (valid_until IS NOT NULL).
SELECT count(*) = 1 AS t12_closed_old_edge
FROM pgmnemo.mem_edge me
JOIN pgmnemo.agent_lesson al_f ON al_f.id = me.source_id
JOIN pgmnemo.agent_lesson al_t ON al_t.id = me.target_id
WHERE al_f.topic = 'concept:twa_src' AND al_t.topic = 'concept:twa_dst'
  AND me.relation_type = 'DERIVED_FROM' AND me.valid_until IS NOT NULL;

-- New edge must be active.
SELECT count(*) = 1 AS t12_new_edge_active
FROM pgmnemo.mem_edge me
JOIN pgmnemo.agent_lesson al_f ON al_f.id = me.source_id
JOIN pgmnemo.agent_lesson al_t ON al_t.id = me.target_id
WHERE al_f.topic = 'concept:twa_src' AND al_t.topic = 'concept:twa_dst'
  AND me.relation_type = 'DERIVED_FROM' AND me.valid_until IS NULL;

-- Two edges are distinct (different ids).
SELECT (SELECT t12_eid1 FROM _t12_r1) <> (SELECT t12_eid2 FROM _t12_r2)
    AS t12_new_edge_different_id;

DROP TABLE _t12_r1;
DROP TABLE _t12_r2;

-- ─────────────────────────────────────────────────────────────────────────────
-- Cleanup
-- ─────────────────────────────────────────────────────────────────────────────

DELETE FROM pgmnemo.agent_lesson WHERE role = 'twa';
