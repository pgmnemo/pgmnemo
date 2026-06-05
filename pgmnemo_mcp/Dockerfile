# pgmnemo-mcp — containerised MCP server (v0.8.2).
# Run on Linux/CI without polluting the host's Python env (isolates psycopg2/mcp
# deps that conflict with other agent libraries). stdio transport: launch with
# `docker run -i --rm ...` from your MCP client config.
FROM python:3.12-slim

WORKDIR /app
COPY pyproject.toml README.md ./
COPY pgmnemo_mcp ./pgmnemo_mcp
RUN pip install --no-cache-dir .

# stdio MCP server. DATABASE_URL / EMBEDDING_SERVER are passed at `docker run` time.
ENTRYPOINT ["pgmnemo-mcp"]
