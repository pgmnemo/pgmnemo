# pgmnemo — Docker Compose example

Drop-in stack to try `pgmnemo` locally without a custom build.

## Requirements

- Docker with Compose v2 (`docker compose`)
- Network access to pull `pgvector/pgvector:pg17` and clone the pgmnemo repo

## Start the stack

```bash
cd examples
docker compose up
```

The init script clones pgmnemo v0.1.0, builds it from source, and installs the
extension into the `pgmnemo` database automatically on first start.

> **Note:** v0.1.0 is a source-build release. A pre-built image is planned for
> v0.2.0, which will make startup instant.

## Verify installation

```bash
psql -h localhost -U postgres -d pgmnemo -c "CREATE EXTENSION pgmnemo CASCADE;"
psql -h localhost -U postgres -d pgmnemo -c "SELECT pgmnemo.version();"
```

Password: `pgmnemo`

## Sample queries

```sql
-- Store an agent observation (provenance gate off for exploration)
SELECT pgmnemo.set_gate_mode('warn');

SELECT pgmnemo.ingest(
    role    := 'developer',
    topic   := 'authentication',
    content := 'Use short-lived JWT tokens with refresh rotation.',
    source  := 'manual'
);

-- Recall memories for a role + topic
SELECT * FROM pgmnemo.recall_lessons(
    role  := 'developer',
    topic := 'authentication'
);
```

## Tear down

```bash
docker compose down -v   # -v removes the pgdata volume
```
