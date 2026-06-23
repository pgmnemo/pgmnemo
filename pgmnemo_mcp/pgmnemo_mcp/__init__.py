"""pgmnemo-mcp — MCP server exposing pgmnemo ingest and recall tools."""

__version__ = "0.11.0"

from .server import mcp, ingest, recall, get_params, main

__all__ = ["mcp", "ingest", "recall", "get_params", "main", "__version__"]
