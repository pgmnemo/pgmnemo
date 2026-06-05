# pgmnemo-mcp

Containerised [MCP](https://modelcontextprotocol.io/) server for **pgmnemo** — in-your-Postgres
agent memory. Exposes `ingest` and `recall` tools so agents can write and retrieve lessons
directly from PostgreSQL, with no second datastore and zero data egress.

Run it in a container so its `psycopg2`/`mcp` dependencies stay isolated from your agent
environment (a common pain on Linux where `pip install pgmnemo-mcp` conflicts with other libs).

## Quick start

MCP client config (stdio via `docker run -i`):

```json
{
  "mcpServers": {
    "pgmnemo": {
      "command": "docker",
      "args": ["run", "-i", "--rm",
               "-e", "DATABASE_URL", "-e", "EMBEDDING_SERVER",
               "gaidabura/pgmnemo-mcp:latest"],
      "env": {
        "DATABASE_URL": "postgresql://user:pass@host:5432/db",
        "EMBEDDING_SERVER": "http://server:1234/v1/embeddings"
      }
    }
  }
}
```

| Variable | Description |
|---|---|
| `DATABASE_URL` | Postgres with the `pgmnemo` extension installed (`CREATE EXTENSION pgmnemo`). |
| `EMBEDDING_SERVER` | *(optional)* OpenAI-compatible embeddings endpoint (1024-dim, e.g. bge-m3). When set, the server embeds queries/lessons itself → vector+BM25 hybrid recall. Unset → text-only (BM25) fallback. |
| `EMBEDDING_MODEL` / `EMBEDDING_DIM` | *(optional)* model name and expected dimension (default 1024). |

If your DB or embedding server runs on the Docker host, add
`--add-host=host.docker.internal:host-gateway` and point the URLs at `host.docker.internal`.

## Image

- Multi-arch: `linux/amd64`, `linux/arm64`
- Tags: version (e.g. `0.8.2`) and `latest`
- Built from [`pgmnemo_mcp/Dockerfile`](https://github.com/pgmnemo/pgmnemo/blob/main/pgmnemo_mcp/Dockerfile)

Apache-2.0 · **Source, extension & full docs:** https://github.com/pgmnemo/pgmnemo
