-- pgmnemo--0.8.0--0.8.1.sql
-- Incremental upgrade: pgmnemo 0.8.0 → 0.8.1
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Documentation sprint — no schema changes.
--
-- v0.8.1 resolves the following adoption issues:
--   #18 — GUC access pattern (SHOW vs current_setting): documented in
--          docs/INSTALL.md §"Reading the GUCs" and docs/USAGE.md §"GUC reference"
--   #19 — Docker production install without compiler: documented in
--          docs/INSTALL.md Path 3 (Dockerfile COPY, no build tools needed)
--   #20 — pgmnemo.stats() diagnostic SP: already shipped in v0.4.1; 19-col version
--          (including confidence distribution) shipped in v0.7.0; documented in
--          docs/USAGE.md §"Health check — pgmnemo.stats()"
--   #24 — Orphan recovery: documented in docs/MIGRATION.md §B.5; cross-referenced
--          from docs/USAGE.md and orphan_count surface in pgmnemo.stats()
--   AGENTS.md — new top-level agent integration guide (all functions, working SQL)
--   README.md / POSITIONING.md / WHY_PGMNEMO.md / ROADMAP.md — positioning reframe
--
-- No DDL changes. No data changes. Schema is identical to v0.8.0.
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.8.1';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.8.1'" to load this file. \quit

-- Version sentinel comment only — no statements needed.
-- PostgreSQL updates the extension's recorded version in pg_extension automatically
-- when this file is applied via ALTER EXTENSION ... UPDATE TO '0.8.1'.
