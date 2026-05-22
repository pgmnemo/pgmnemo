from pathlib import Path
import tomllib


def test_flat_package_is_mapped_to_pgmnemo_mcp() -> None:
    pyproject = Path(__file__).resolve().parents[1] / "pyproject.toml"
    config = tomllib.loads(pyproject.read_text())

    setuptools_config = config["tool"]["setuptools"]
    assert setuptools_config["packages"] == ["pgmnemo_mcp"]
    assert setuptools_config["package-dir"]["pgmnemo_mcp"] == "."
