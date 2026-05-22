def test_pgmnemo_mcp_importable():
    import pgmnemo_mcp
    assert hasattr(pgmnemo_mcp, '__file__')
