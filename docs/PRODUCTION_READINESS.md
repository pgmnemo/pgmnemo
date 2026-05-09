# Production Readiness

**Current maturity:** Beta  
**Last updated:** 2026-05-09

## What beta means here

`pgmnemo` is intended to be technically serious and operationally honest, but it is still in a hardening phase.

Treat it as:
- suitable for evaluation, staging, and controlled pilots
- reasonable for production only after your team validates install, upgrade, and recall behavior on your own stack
- not yet a drop-in “set and forget” extension across all environments

## Operator checklist

Before production adoption:

1. confirm supported PostgreSQL and `pgvector` versions
2. run fresh install on your target environment
3. run a minimal ingest / recall smoke test
4. rehearse upgrade from your deployed version
5. document rollback expectations before first rollout
