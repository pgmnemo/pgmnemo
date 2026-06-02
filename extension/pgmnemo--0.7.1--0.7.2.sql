-- pgmnemo--0.7.1--0.7.2.sql
-- Incremental upgrade: pgmnemo 0.7.1 → 0.7.2
-- SPDX-License-Identifier: Apache-2.0
--
-- PACKAGING-ONLY release. NO schema change, NO DDL, NO function change.
--
-- Background: the v0.7.1 published distribution double-nested the extension
-- directory (pgmnemo-0.7.1/extension/extension/), making it uninstallable from
-- PGXN and GitHub release zips ("could not open extension control file").
-- The SQL was correct; only the packaging was broken. v0.7.2 ships a
-- correctly-structured dist and adds a CI clean-room install gate so this
-- class of packaging regression cannot recur. See CHANGELOG.md [0.7.2].
--
-- This upgrade script intentionally contains no DDL: there is nothing to
-- migrate because the schema is byte-identical to v0.7.1. PostgreSQL bumps
-- pg_extension.extversion to '0.7.2' on ALTER EXTENSION; pgmnemo.version()
-- (which reads pg_extension.extversion) then returns '0.7.2'.
--
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.7.2';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.7.2'" to load this file. \quit

-- (no-op: packaging-only release — no DDL)
