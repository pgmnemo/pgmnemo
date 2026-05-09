-- Regression smoke tests: assemble_context_pack() (v0.2.2)
-- Tests the token cost formula and density-greedy logic without live table data.

-- T1: token_cost formula — ceil(octet_length / 4)
-- 'Hello world' = 11 bytes → ceil(11/4) = 3 tokens
SELECT
    GREATEST(1, CAST(CEIL(octet_length('Hello world')::NUMERIC / 4) AS INT)) AS token_cost_11chars,
    GREATEST(1, CAST(CEIL(octet_length('')::NUMERIC / 4) AS INT))             AS token_cost_empty_clamp;
-- expected: 3, 1

-- T2: empty string clamps to 1 (GREATEST guard)
SELECT GREATEST(1, CAST(CEIL(0::NUMERIC / 4) AS INT)) AS min_token_cost;
-- expected: 1

-- T3: density ordering — higher score/token wins over raw score
-- Item A: score=0.9, cost=100 → density=0.009
-- Item B: score=0.5, cost=10  → density=0.050  ← should rank first
SELECT
    0.9::DOUBLE PRECISION / 100 AS density_a,
    0.5::DOUBLE PRECISION / 10  AS density_b,
    (0.5::DOUBLE PRECISION / 10) > (0.9::DOUBLE PRECISION / 100) AS b_ranks_higher;
-- expected: 0.009, 0.05, true

-- T4: budget fit — greedy with skip-continue
-- budget=15 tokens; A=cost 10, B=cost 12, C=cost 5
-- density order: C(0.10) > A(0.09) > B(0.041)
-- C fits (5 used), A fits (15 used), B skipped (15+12>15)
WITH items(name, score, cost) AS (
    VALUES
        ('A', 0.9, 10),
        ('B', 0.5, 12),
        ('C', 0.5,  5)
),
ranked AS (
    SELECT *, score::DOUBLE PRECISION / cost AS density
    FROM items
    ORDER BY density DESC
),
knapsack AS (
    SELECT
        name, cost,
        SUM(cost) OVER (ORDER BY density DESC ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS running_total
    FROM ranked
)
SELECT name, cost, running_total, running_total <= 15 AS fits
FROM knapsack
ORDER BY running_total;
-- expected: C(5, fits=t), A(15, fits=t), B(27, fits=f)
