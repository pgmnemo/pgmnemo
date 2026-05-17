"""pgmnemo-mcp — MCP server exposing pgmnemo ingest and recall tools."""

__version__ = "0.1.0"

from .server import mcp, ingest, recall

__all__ = ["mcp", "ingest", "recall", "__version__"]
