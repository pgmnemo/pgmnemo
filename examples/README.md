# pgmnemo — Docker Compose example

Drop-in stack to try `pgmnemo` v0.3.0 locally without a custom build.

## Requirements

- Docker with Compose v2 (`docker compose`)
- Network access to pull `pgvector/pgvector:pg17` and clone the pgmnemo repo

## Start the stack

```bash
cd examples
docker compose up
```

The init script clones pgmnemo v0.3.0, builds it from source, and installs the
extension into the `pgmnemo` database automatically on first start.

## Verify installation

```bash
psql -h localhost -U postgres -d pgmnemo -c "CREATE EXTENSION pgmnemo CASCADE;"
psql -h localhost -U postgres -d pgmnemo -c "SELECT pgmnemo.version();"
```

Password: `pgmnemo`

## Sample queries

```sql
-- Store an agent observation (provenance gate in warn mode for exploration)
SET pgmnemo.gate_strict = 'warn';

SELECT pgmnemo.ingest(
    p_role        := 'developer',
    p_project_id  := 1,
    p_topic       := 'authentication',
    p_lesson_text := 'Use short-lived JWT tokens with refresh rotation.',
    p_commit_sha  := 'abc1234'
);

-- Recall memories for a role + topic
SELECT lesson_text, score
FROM pgmnemo.recall_lessons(
    query_embedding   := array_fill(0, ARRAY[1024])::vector(1024),
    query_text        := 'JWT token rotation',
    role_filter       := 'developer',
    project_id_filter := 1
);
```

## Tear down

```bash
docker compose down -v   # -v removes the pgdata volume
```
