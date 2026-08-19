-- pg_regress tests for pgmnemo v0.16.1 — widened failure-class vocabulary
SET client_min_messages = warning;
ALTER EXTENSION pgmnemo UPDATE TO '0.19.1';

-- A1: classes whose names contain none of the old FAIL/ERROR/BUG words
SELECT pgmnemo.extract_entity_keys('Run failed with INFRA_RATE_LIMIT during dispatch.') AS a1_rate_limit;
SELECT pgmnemo.extract_entity_keys('Run failed with MAX_TURNS_EXCEEDED during dispatch.') AS a2_exceeded;
SELECT pgmnemo.extract_entity_keys('Run failed with PHASE_GOAL_UNMET during dispatch.') AS a3_unmet;
SELECT pgmnemo.extract_entity_keys('Run failed with COST_CEILING during dispatch.') AS a4_ceiling;

-- B1: the previously-recognised vocabulary still works
SELECT pgmnemo.extract_entity_keys('Run failed with INFRA_FAILURE during dispatch.') AS b1_failure;
SELECT pgmnemo.extract_entity_keys('The PHANTOM_DONE bug marked tasks complete.') AS b2_phantom;

-- C1: ordinary upper-case prose must not become a failure key
SELECT pgmnemo.extract_entity_keys('The README and the API are both fine.') AS c1_no_false_positive;
