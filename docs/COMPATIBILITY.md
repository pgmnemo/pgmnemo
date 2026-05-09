# Compatibility

**Status:** Beta compatibility statement  
**Last updated:** 2026-05-09

## Supported matrix

| Component | Status | Notes |
|---|---|---|
| PostgreSQL 17 | supported | primary tested target |
| PostgreSQL 14-16 | best effort | some paths may work, but PG17 is the main validation path |
| PostgreSQL 18 | not yet declared supported | test before adopting |
| `pgvector >= 0.7.0` | required | HNSW support required |
| macOS Apple Silicon | commonly used by maintainers | best-effort support |
| Linux amd64 | primary CI / packaging target | recommended for production verification |

## Compatibility contract

The stable contract for adopters is:

- `CREATE EXTENSION pgmnemo CASCADE;`
- documented `ingest()` and `recall_lessons()` SQL signatures in the latest release docs
- upgrade only from versions explicitly listed in `INSTALL.md`

## Before using in production

Validate on your own stack:

1. fresh install
2. `CREATE EXTENSION`
3. core read/write smoke test
4. upgrade rehearsal from your current version
5. rollback / restore plan
