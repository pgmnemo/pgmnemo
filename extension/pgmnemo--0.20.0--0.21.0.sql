-- pgmnemo 0.20.0 → 0.21.0
-- Fix: register user-data tables and sequences with pg_extension_config_dump
-- so that pg_dump includes their data in backups and pg_restore preserves the
-- full memory corpus.
--
-- Root cause (detected 2026-08-31): agent_lesson, mem_edge, and
-- memory_ingest_log were extension-owned (pg_depend deptype='e') but had never
-- been passed to pg_extension_config_dump. pg_extension.extconfig was empty,
-- causing pg_dump to silently omit their data while preserving DDL via
-- CREATE EXTENSION. Any user running a standard pg_dump/pg_restore cycle lost
-- their entire lesson corpus on restore.
--
-- Tables registered:   agent_lesson, mem_edge, memory_ingest_log
-- Tables excluded:     agent_lesson_state_transition — static extension data
--                      seeded by the extension's own SQL; registering it would
--                      cause duplicate-key errors on restore because
--                      CREATE EXTENSION re-inserts the seed rows before the
--                      dump data is applied.
-- Sequences registered: agent_lesson_id_seq, mem_edge_id_seq,
--                       memory_ingest_log_id_seq — preserves id continuity
--                       after restore; without this, sequences reset to 1 and
--                       new writes collide with existing ids.
--
-- This script is safe to run on any live 0.20.0 installation.
-- pg_extension_config_dump() is idempotent: calling it on a table that is
-- already registered replaces the condition (empty string → dump all rows),
-- which is a no-op if the table was already registered with the same condition.
-- No data is moved; no tables are altered; no locks are taken beyond the
-- brief exclusive lock pg_extension_config_dump() acquires on pg_extension.
--
-- G-UPGRADE-PARITY: pgmnemo--0.21.0.sql (fresh install) and this script
-- produce identical pg_extension.extconfig state after installation.
-- ─────────────────────────────────────────────────────────────────────────────

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.21.0'" to apply this script. \quit

SELECT pg_extension_config_dump('pgmnemo.agent_lesson', '');
SELECT pg_extension_config_dump('pgmnemo.agent_lesson_id_seq', '');
SELECT pg_extension_config_dump('pgmnemo.mem_edge', '');
SELECT pg_extension_config_dump('pgmnemo.mem_edge_id_seq', '');
SELECT pg_extension_config_dump('pgmnemo.memory_ingest_log', '');
SELECT pg_extension_config_dump('pgmnemo.memory_ingest_log_id_seq', '');
