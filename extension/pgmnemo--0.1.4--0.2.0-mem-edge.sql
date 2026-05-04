-- pgmnemo upgrade: 0.1.4 → 0.2.0 (mem_edge)
-- Multi-graph relations between lessons. RFC §3.
-- SPDX-License-Identifier: Apache-2.0

CREATE TABLE pgmnemo.mem_edge (
    id          BIGSERIAL PRIMARY KEY,
    source_id   BIGINT NOT NULL REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    target_id   BIGINT NOT NULL REFERENCES pgmnemo.agent_lesson(id) ON DELETE CASCADE,
    edge_type   TEXT NOT NULL CHECK (edge_type IN ('causal','temporal','semantic','entity','supersedes','derives_from','contradicts','elaborates')),
    weight      DOUBLE PRECISION NOT NULL DEFAULT 1.0,
    metadata    JSONB NOT NULL DEFAULT '{}'::jsonb,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX ix_pgmnemo_mem_edge_source    ON pgmnemo.mem_edge (source_id, edge_type);
CREATE INDEX ix_pgmnemo_mem_edge_target    ON pgmnemo.mem_edge (target_id, edge_type);
CREATE INDEX ix_pgmnemo_mem_edge_type_time ON pgmnemo.mem_edge (edge_type, created_at DESC);

COMMENT ON TABLE pgmnemo.mem_edge IS 'Multi-graph relations between lessons. v0.2.0 RFC §3.';
