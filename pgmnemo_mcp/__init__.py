"""pgmnemo-mcp — MCP server exposing pgmnemo ingest and recall tools."""

__version__ = "0.5.0"

from .server import mcp, ingest, recall, main

__all__ = ["mcp", "ingest", "recall", "main", "__version__"]
