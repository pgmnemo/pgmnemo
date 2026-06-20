"""Conftest for root-level smoke tests.

Adds pgmnemo_mcp/ to sys.path so test_mcp_smoke.py can import pgmnemo_mcp
without requiring an editable install or PYTHONPATH to be set manually.
"""
import sys
import os

# pgmnemo_mcp Python package lives at <repo-root>/pgmnemo_mcp/
# (which is a project subdirectory containing the pgmnemo_mcp/ Python package)
_repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_mcp_dir = os.path.join(_repo_root, "pgmnemo_mcp")
if _mcp_dir not in sys.path:
    sys.path.insert(0, _mcp_dir)
