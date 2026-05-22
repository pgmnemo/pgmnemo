---
date: 2026-05-22
version: v0.6.0
issue: "#28"
status: stable
---

# Cookbook: PostGIS Spatial Pre-filter + pgmnemo Hybrid Recall

## 1. Use Case

A **field-service / logistics agent** dispatches technicians across a city.
Every resolved incident is stored as a pgmnemo lesson tagged with the venue
or region where it occurred. When the agent handles a new incident, it needs
to recall lessons that are *both* semantically relevant to the current problem
*and* physically close to the job site — lessons from a warehouse 500 km away
are rarely useful even if they score well semantically.

The pattern: run a PostGIS `ST_DWithin` spatial pre-filter first to cut the
candidate pool to lessons within a configurable radius, then pass only those
`lesson_id`s into `pgmnemo.recall_lessons()` via a JOIN. The spatial index
reduces the HNSW candidate set by 100×–1000×, keeping recall fast even as the
lesson corpus grows.

---

## 2. Schema Add-ons

```sql
-- Requires PostGIS:
CREATE EXTENSION IF NOT EXISTS postgis;

-- Userland mirror table: one row per lesson that has a known location.
-- Kept separate from pgmnemo.agent_lesson so the extension upgrade path
-- is unaffected by your column additions.
CREATE TABLE IF NOT EXISTS public.lesson_location (
    lesson_id   BIGINT PRIMARY KEY
                    REFERENCES pgmnemo.agent_lesson(lesson_id)
                    ON DELETE CASCADE,
    location    GEOGRAPHY(POINT, 4326) NOT NULL,  -- (lon, lat) WGS-84
    venue_name  TEXT,                              -- optional human label
    updated_at  TIMESTAMPTZ DEFAULT NOW()
);

-- GIST index — required for ST_DWithin to use the spatial index path:
CREATE INDEX IF NOT EXISTS idx_lesson_location_gist
    ON public.lesson_location
    USING GIST (location);

-- Run ANALYZE so the planner picks up the new index statistics:
ANALYZE public.lesson_location;
```

> **Why a separate table?**
> `pgmnemo.agent_lesson` is owned by the extension; adding columns outside
> `ALTER EXTENSION UPDATE` creates orphan objects that block future upgrades
> (see `docs/SQL_REFERENCE.md §2.8 stats()` — `orphan_count`).  The mirror
> table uses a FK + `ON DELETE CASCADE` so it stays consistent automatically.

---

## 3. Recipe

### 3.1 Populate location at ingest time

```sql
-- Ingest the lesson as normal:
INSERT INTO pgmnemo.agent_lesson (
    role, project_id, topic, lesson_text, importance,
    embedding, commit_sha, metadata
) VALUES (
    'field_agent', 42,
    'Faulty sensor — Building 7 loading dock',
    'Vibration sensor on conveyor belt C3 trips false-positive when ambient temp '
    '> 38°C. Workaround: reduce polling interval to 2s and add 0.3g deadband.',
    4,
    $embedding_vector,         -- vector(1024) from your embedding model
    'a1b2c3d4',
    '{"venue": "WH-07", "region": "south-bay"}'
)
RETURNING lesson_id;

-- Then write the geographic position (lon, lat):
INSERT INTO public.lesson_location (lesson_id, location, venue_name)
VALUES (
    <returned_lesson_id>,
    ST_MakePoint(-121.8947, 37.3382)::geography,   -- lon first, then lat
    'Warehouse 7 — South Bay'
)
ON CONFLICT (lesson_id) DO UPDATE
    SET location   = EXCLUDED.location,
        venue_name = EXCLUDED.venue_name,
        updated_at = NOW();
```

### 3.2 Spatial pre-filter → hybrid recall (the main recipe)

```sql
-- Agent parameters (substitute at query time):
--   $lon, $lat        : job-site coordinates (WGS-84)
--   $radius_m         : search radius in metres (e.g. 50 000 = 50 km)
--   $query_embedding  : vector(1024) for the current incident
--   $query_text       : short text description of the incident
--   $project_id       : tenant / project scope

WITH spatial_candidates AS (
    -- Step 1: spatial pre-filter.
    -- ST_DWithin on a GEOGRAPHY column uses metres directly and leverages
    -- the GIST index.  This typically reduces candidates from tens-of-
    -- thousands down to hundreds before the vector scan begins.
    SELECT lesson_id
    FROM public.lesson_location
    WHERE ST_DWithin(
        location,
        ST_MakePoint($lon, $lat)::geography,
        $radius_m
    )
),
recalled AS (
    -- Step 2: hybrid recall over the full verified corpus.
    -- recall_lessons() applies HNSW vector search + BM25 + RRF fusion.
    -- See docs/SQL_REFERENCE.md §2.3 for full signature.
    SELECT *
    FROM pgmnemo.recall_lessons(
        query_embedding   => $query_embedding,
        k                 => 100,                   -- fetch extra; JOIN will trim
        role_filter       => 'field_agent',
        project_id_filter => $project_id,
        query_text        => $query_text
    )
)
-- Step 3: intersect — keep only lessons that passed both filters.
SELECT
    r.lesson_id,
    r.score,
    r.topic,
    r.lesson_text,
    r.importance,
    r.vec_score,
    r.bm25_score,
    ll.venue_name,
    ST_Distance(
        ll.location,
        ST_MakePoint($lon, $lat)::geography
    ) AS distance_m
FROM recalled r
JOIN spatial_candidates sc USING (lesson_id)
JOIN public.lesson_location ll USING (lesson_id)
ORDER BY r.score DESC
LIMIT 10;
```

> **Note on `k`:** Pass a larger `k` to `recall_lessons()` than your final
> `LIMIT` — the JOIN discards lessons outside the radius, so you need slack.
> A factor of 5–10× is typical (e.g. `k=100` → `LIMIT 10`).

### 3.3 Lessons with no location entry

Lessons that were ingested without a corresponding `lesson_location` row are
invisible to the spatial pre-filter — they are excluded from results.  If you
want a fallback that includes un-located lessons, union the spatial path with
a non-spatial recall:

```sql
-- Fallback: union spatial results with un-located lessons
WITH spatial_ids AS (
    SELECT lesson_id
    FROM public.lesson_location
    WHERE ST_DWithin(location, ST_MakePoint($lon, $lat)::geography, $radius_m)
),
recalled AS (
    SELECT *, TRUE AS has_location
    FROM pgmnemo.recall_lessons(
        query_embedding   => $query_embedding,
        k                 => 100,
        role_filter       => 'field_agent',
        project_id_filter => $project_id,
        query_text        => $query_text
    )
    WHERE lesson_id IN (SELECT lesson_id FROM spatial_ids)

    UNION ALL

    SELECT *, FALSE AS has_location
    FROM pgmnemo.recall_lessons(
        query_embedding   => $query_embedding,
        k                 => 20,
        role_filter       => 'field_agent',
        project_id_filter => $project_id,
        query_text        => $query_text
    )
    WHERE lesson_id NOT IN (SELECT lesson_id FROM spatial_ids)
      AND lesson_id NOT IN (
          SELECT lesson_id FROM public.lesson_location
      )
)
SELECT DISTINCT ON (lesson_id) *
FROM recalled
ORDER BY lesson_id, score DESC;
```

---

## 4. Example Output

Below is a mock result for a job site at `(-121.90, 37.34)` with `$radius_m = 50000`.

### Before spatial filter (top 5 from `recall_lessons()` alone)

| lesson_id | score  | topic                                   | vec_score | bm25_score | region      |
|-----------|--------|-----------------------------------------|-----------|------------|-------------|
| 1041      | 0.8812 | Faulty sensor — Building 7 loading dock | 0.921     | 0.740      | south-bay   |
| 892       | 0.8540 | Conveyor jam — Oakland port terminal    | 0.889     | 0.612      | east-bay    |
| 773       | 0.8210 | Temp sensor deadband — Fresno depot     | 0.847     | 0.588      | central-val |
| 1103      | 0.7994 | Vibration false-positive — SFO cargo    | 0.812     | 0.701      | sf-airport  |
| 654       | 0.7780 | Conveyor belt alignment — Stockton hub  | 0.801     | 0.540      | central-val |

### After spatial filter (`$radius_m = 50 000` m around the job site)

| lesson_id | score  | topic                                   | distance_m | venue_name            |
|-----------|--------|-----------------------------------------|------------|-----------------------|
| 1041      | 0.8812 | Faulty sensor — Building 7 loading dock |      4 820 | Warehouse 7 — South Bay |
| 892       | 0.8540 | Conveyor jam — Oakland port terminal    |     22 140 | Oakland Port WH-3     |
| 1103      | 0.7994 | Vibration false-positive — SFO cargo   |     43 670 | SFO Cargo Hub         |

> Lessons 773 and 654 (Fresno, Stockton) are **eliminated** by the spatial
> filter even though they scored highly on semantics.  The agent sees only
> lessons from nearby venues.

---

## 5. Caveats

**PostGIS required.**  The recipe depends on `ST_DWithin`, `ST_MakePoint`, and
`ST_Distance`.  Enable the extension before running any DDL or queries:

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
-- Verify:
SELECT postgis_full_version();
```

PostGIS is not bundled with pgmnemo.  On managed Postgres services (RDS,
Cloud SQL, Supabase, Neon) enable it via the console or:
`CREATE EXTENSION postgis` (requires superuser or `rds_superuser`).

**GIST index must be ANALYZEd.**  After bulk-inserting rows into
`lesson_location`, run `ANALYZE public.lesson_location;` so the query planner
picks up the updated statistics.  Without fresh stats the planner may choose
a sequential scan, negating the performance benefit.

**Geography vs. Geometry.**  The recipe uses `GEOGRAPHY(POINT, 4326)`.
Geography operates in metres on the WGS-84 ellipsoid — `ST_DWithin` radius is
in metres, not degrees.  If you use `GEOMETRY` instead, the radius must be in
the coordinate system's native unit (degrees for EPSG:4326, metres for
projected SRIDs).  Geography is the correct choice for global deployments.

**`lesson_location` rows are optional.**  Lessons without a corresponding
`lesson_location` row are excluded by the `JOIN`.  Populate the table only
for lessons where geography is meaningful; pure conceptual lessons (e.g.
coding guidelines, API contracts) can safely omit it.

**RLS / tenant scoping.**  The `lesson_location` table is in the public schema
and is not subject to pgmnemo's RLS policy.  If your application uses
multi-tenant isolation, add an RLS policy on `lesson_location` matching your
`pgmnemo.agent_lesson` `project_id` scoping, or join through the pgmnemo
view.

---

## 6. Performance Note

Spatial pre-filtering is a force multiplier for HNSW vector search:

| Corpus size | Without spatial pre-filter | With spatial pre-filter (50 km radius) |
|-------------|---------------------------|----------------------------------------|
| 10 000 lessons | HNSW scans all 10 000 candidates | HNSW scans ~50–200 candidates |
| 100 000 lessons | HNSW scans all 100 000 candidates | HNSW scans ~500–2 000 candidates |
| 1 000 000 lessons | HNSW scans all 1 000 000 candidates | HNSW scans ~5 000–20 000 candidates |

The GIST index on `location` returns the spatial candidates in microseconds
(O(log N) on the R-tree).  The subsequent HNSW scan in
`pgmnemo.recall_lessons()` works proportionally to the number of candidates,
not to the full corpus.  At 1 M lessons the combined path typically runs in
**5–30 ms** vs. **200–800 ms** for a full-corpus vector scan.

To tune `ef_search` for the post-filter HNSW step:

```sql
-- Reduce ef_search when the spatial candidate set is already small.
-- The default (100) is conservative; 40–60 is often sufficient after
-- a tight geographic filter.
SET pgmnemo.ef_search = 60;

-- Then run the CTE recipe above.
-- Check actual timings with EXPLAIN ANALYZE:
EXPLAIN (ANALYZE, BUFFERS, FORMAT TEXT)
<paste your CTE query here>;
```

See `docs/SQL_REFERENCE.md §3.1` for the full `ef_search` GUC reference.

---

## See Also

- `docs/SQL_REFERENCE.md §2.3` — `recall_lessons()` full signature and scoring formula
- `docs/SQL_REFERENCE.md §2.5` — `recall_hybrid()` for direct weight control
- `docs/SQL_REFERENCE.md §3.1` — `ef_search` and recall scoring GUCs
- `docs/SQL_REFERENCE.md §4` — Row-Level Security and tenant scoping
- PostGIS docs: [postgis.net/docs/ST_DWithin.html](https://postgis.net/docs/ST_DWithin.html)
