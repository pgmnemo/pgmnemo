-- Regression test: pgmnemo.temporal_boost GUC (v0.5.1, H-06)
-- Verifies: default=1.0, clamping [0.0,5.0], helper function, SET/RESET round-trip.

-- Apply the v0.4.1→v0.5.1 migration to expose get_temporal_boost().
ALTER EXTENSION pgmnemo UPDATE TO '0.11.0';

-- Default value via helper
SELECT pgmnemo.get_temporal_boost() AS default_boost;

-- SET to in-range value
SET pgmnemo.temporal_boost = '2.5';
SELECT pgmnemo.get_temporal_boost() AS boost_2_5;

-- Clamping: above 5.0 → 5.0
SET pgmnemo.temporal_boost = '9.0';
SELECT pgmnemo.get_temporal_boost() AS clamped_to_5;

-- Clamping: below 0.0 → 0.0
SET pgmnemo.temporal_boost = '-1.0';
SELECT pgmnemo.get_temporal_boost() AS clamped_to_0;

-- Reset; COALESCE fallback in get_temporal_boost() returns 1.0 when GUC is unset.
RESET pgmnemo.temporal_boost;
SELECT pgmnemo.get_temporal_boost() AS after_reset;
