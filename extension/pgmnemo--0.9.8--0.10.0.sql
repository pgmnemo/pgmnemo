-- pgmnemo--0.9.8--0.10.0.sql
-- Upgrade: pgmnemo 0.9.8 → 0.10.0
-- SPDX-License-Identifier: Apache-2.0
--
-- THEME: Extraction substrate backbone
--
-- SQL schema is unchanged from v0.9.8.
-- The extraction pipeline (ingest_document, entity/relation extraction)
-- lives entirely in the pgmnemo-client Python package (DQ-1: trusted
-- extension cannot call external LLM APIs; extraction is Python-only).
--
-- This delta: version string bump only.
-- Upgrade: ALTER EXTENSION pgmnemo UPDATE TO '0.10.0';

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.10.0'" to load this file. \quit

-- Version bump: no schema changes in this delta.
-- All 0.9.8 functions (recall_fast, navigate_locate_dispatch,
-- navigate_expand_typed, apply_selective_embedding_policy) are inherited.
