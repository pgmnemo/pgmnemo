-- pgmnemo 0.3.0 → 0.3.1 upgrade
--
-- HYGIENE-ONLY RELEASE — NO SQL CHANGES.
--
-- v0.3.1 is the first release under the customer-driven, bench-gated workflow
-- (see docs/WORKFLOW.md). It ships documentation, process tooling, CI bench-gate
-- mechanism, and per-version visualisation artefacts — none of which affect the
-- runtime behaviour of any pgmnemo function or schema object.
--
-- What's in v0.3.1:
--   * docs/WORKFLOW.md            — canonical development discipline
--   * docs/BENCHMARK_PROTOCOL.md  — two-phase bench architecture
--   * docs/SQL_REFERENCE.md       — every public SQL function + GUC
--   * docs/MIGRATION.md Part B    — in-place version-to-version upgrades
--   * benchmarks/METRICS_BY_VERSION.md — release-tracking ledger
--   * benchmarks/gate/v0.3.0.json — first bench-gate baseline snapshot
--   * scripts/significance_test_extended.py — per-cell release gate
--   * scripts/render_*            — viz tooling
--   * .github/workflows/release.yml — mechanical bench-gate enforcement
--   * ROADMAP.md (v2)             — customer-driven per-version plan
--
-- Bench verdict (see benchmarks/gate/v0.3.0.json):
--   Neutral on all 3 benches — no SQL change, no recall delta possible.

\echo Use "ALTER EXTENSION pgmnemo UPDATE TO '0.3.1'" to load this file.  \quit

-- intentionally empty (hygiene release)
