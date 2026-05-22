import os
from psycopg2 import pool

__all__ = ["DATABASE_URL", "MCP_PORT", "get_pool"]

DATABASE_URL: str = os.environ.get("DATABASE_URL", "postgresql://localhost/pgmnemo")
MCP_PORT: int = int(os.environ.get("MCP_PORT", "8765"))

_pool: pool.SimpleConnectionPool | None = None


def get_pool() -> pool.SimpleConnectionPool:
    global _pool
    if _pool is None:
        _pool = pool.SimpleConnectionPool(1, 5, dsn=DATABASE_URL)
    return _pool
