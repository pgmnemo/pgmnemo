-- pgmnemo--0.9.3--0.9.4.sql
-- Incremental upgrade: pgmnemo 0.9.3 → 0.9.4
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Documentation-only release.
--   SQL_REFERENCE and USAGE updated to cover three GUCs shipped in v0.9.2–v0.9.3
--   (confidence_boost_weight, reinforce_success_delta, reinforce_fail_delta).
--   No SQL changes; upgrade is a no-op.
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.9.4';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.9.4'" to load this file. \quit

-- (no SQL changes — documentation-only release)
