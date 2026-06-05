-- pgmnemo--0.8.2--0.8.3.sql
-- Incremental upgrade: pgmnemo 0.8.2 → 0.8.3
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Documentation patch — NO schema, function, or scoring changes.
-- Fixes adopter-reported doc bugs (broken install smoke SQL, MCP tool-arg contract,
-- version drift, fresh-DB MCP quickstart). SQL is byte-identical to v0.8.2.
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.8.3';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.8.3'" to load this file. \quit

-- Version sentinel only — no statements. PostgreSQL records the new version in
-- pg_extension automatically when this file is applied.
