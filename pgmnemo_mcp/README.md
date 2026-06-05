# pgmnemo-mcp

**MCP server for pgmnemo — provenance-gated agent memory in PostgreSQL.**

[![PyPI](https://img.shields.io/pypi/v/pgmnemo-mcp.svg)](https://pypi.org/project/pgmnemo-mcp/)
[![License](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](https://github.com/pgmnemo/pgmnemo/blob/main/LICENSE)
[![Python](https://img.shields.io/badge/python-%3E%3D3.11-blue.svg)](https://pypi.org/project/pgmnemo-mcp/)

`pgmnemo-mcp` is an [MCP](https://modelcontextprotocol.io/) server that exposes
[pgmnemo](https://github.com/pgmnemo/pgmnemo)'s ingest and recall capabilities
as tool calls for AI agents and LLM hosts (Claude Desktop, Cursor, Zed, etc.).

## Requirements

- Python ≥ 3.11
- A PostgreSQL database with `pgmnemo` extension installed (`CREATE EXTENSION pgmnemo CASCADE;`)
- pgmnemo ≥ 0.5.0 ([install guide](https://github.com/pgmnemo/pgmnemo/blob/main/INSTALL.md))

## Install

```bash
pip install pgmnemo-mcp
```

## Quick start

```bash
# Set the database URL
export DATABASE_URL="postgresql://user:pass@localhost/mydb"

# Start the MCP server (stdio transport)
pgmnemo-mcp
```

Add to **Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json`):

```json
{
  "mcpServers": {
    "pgmnemo": {
      "command": "pgmnemo-mcp",
      "env": {
        "DATABASE_URL": "postgresql://user:pass@localhost/mydb"
      }
    }
  }
}
```

## Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | `postgresql://localhost/pgmnemo` | libpq connection string |
| `MCP_PORT` | `8765` | Port for HTTP/SSE transport (optional) |

## Tools exposed

| Tool | Arguments (all top-level) | Description |
|------|-----------|-------------|
| `pgmnemo.ingest` | `text` (req), `role`, `topic`, `importance`, `project_id`, `commit_sha`, `artifact_hash`, `metadata` | Store a lesson |
| `pgmnemo.recall` | `query` (req), `top_k` | Retrieve relevant lessons |

`ingest` arguments are **top-level** — do not nest them under `metadata`. Defaults:
`role="mcp_agent"`, `topic="general"`, `importance=3`, `project_id=1`. Pass `commit_sha`
or `artifact_hash` to satisfy the provenance gate (without one the lesson is a "ghost",
excluded from recall by default).

## Usage

```bash
# Smoke test — verify DB connectivity
DATABASE_URL=postgresql://user:pass@host/db python -m pgmnemo_mcp --smoke

# SSE transport (for web-based MCP hosts)
MCP_PORT=8765 pgmnemo-mcp
```

## MCP Registry

| Field | Value |
|-------|-------|
| Server name | `pgmnemo` |
| Entry point | `pgmnemo-mcp` |
| Transport | stdio (default) · SSE (`MCP_PORT`) |

## Links

- [pgmnemo GitHub](https://github.com/pgmnemo/pgmnemo) — SQL extension source, benchmarks, docs
- [INSTALL.md](https://github.com/pgmnemo/pgmnemo/blob/main/INSTALL.md) — extension install guide
- [USAGE.md](https://github.com/pgmnemo/pgmnemo/blob/main/docs/USAGE.md) — API reference
- [CHANGELOG](https://github.com/pgmnemo/pgmnemo/blob/main/CHANGELOG.md)

## License

Apache License 2.0
