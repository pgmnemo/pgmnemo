-- pgmnemo--0.5.0--0.5.1.sql
-- Migration: v0.5.0 → v0.5.1
--
-- Scope:
--   §A  V4 — Fix incorrect temporal_boost comment in recall_lessons()
--
-- Change: The inline comment and COMMENT ON FUNCTION for recall_lessons()
-- incorrectly described the temporal_boost parameter. Updated to accurately
-- state the recency decay formula: linear 90d decay (score→0 at age≥90d),
-- coefficient=pgmnemo.recency_weight, multiplied by pgmnemo.temporal_boost.
--
-- No DDL changes, no data migrations, no new GUCs.
-- Safe to apply on any v0.5.0 installation; no downtime required.
-- ─────────────────────────────────────────────────────────────────────────────

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.5.1'" to load this file.  \quit

-- ─────────────────────────────────────────────────────────────────────────────
-- §A  V4: Fix recall_lessons() temporal_boost comment
--
-- The v0.5.0 inline comment read:
--   "effective_γ = _gamma × temporal_boost (range 0.0–20.0, default 1.0)"
-- which omitted the actual recency decay formula entirely.
--
-- Corrected description:
--   recency decay = max(0, 1 - age_days/90)  — linear 90d decay
--   coeff = pgmnemo.recency_weight (default 0.05)
--   effective_γ = pgmnemo.recency_weight × pgmnemo.temporal_boost
--
-- Only COMMENT ON FUNCTION is updated here (no logic change).
-- The inline SQL comment is fixed in pgmnemo--0.5.0.sql (source of record).
-- ─────────────────────────────────────────────────────────────────────────────

COMMENT ON FUNCTION pgmnemo.recall_lessons(vector, INT, TEXT, INT, TEXT) IS
    'v0.5.1 hybrid router with temporal_boost GUC (H-06) and query_text cap (R5). '
    'Routes to recall_hybrid() when query_text non-empty AND embedding present '
    'AND pgmnemo.disable_hybrid is FALSE/unset. '
    'R5: query_text truncated to pgmnemo.max_query_text_chars (default 2000) with RAISE NOTICE. '
    'H-06: recency decay = max(0, 1 - age_days/90) — linear 90d decay, zeroes at age≥90d. '
    'coeff=pgmnemo.recency_weight (default 0.05); '
    'effective_γ = recency_weight × temporal_boost (boost default 1.0, range 0.0–20.0). '
    'Diagnostic cols: vec_score=cosine; bm25_score/rrf_score=NULL on vector-only path.';
