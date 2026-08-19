#!/usr/bin/env python3
"""Anti-fabrication gate for benchmarks/ and docs/.

Three checks — all must pass:

1. NO GENERATOR IN PUBLISHED BENCHMARK DIRS
   Any Python file under benchmarks/*/ that imports a random-number generator
   (random, numpy.random, secrets) AND writes a data file fails the gate.
   Datasets are exports; generators belong in test fixtures, not in evidence.

2. NUMBERS MUST AGREE
   For each registered benchmark, run its analysis script and assert that every
   numeric claim in the corresponding published document matches the script's
   printed output (within rounding).  A document and its dataset disagreeing is
   a failure, not a warning.

3. ANALYSIS SCRIPTS MUST READ THE DATASET
   A script that prints constants without ever opening its data file fails.

Usage: python3 scripts/check_evidence_integrity.py
Exit 0 = all checks pass; non-zero = at least one failure.

To register a new benchmark for check #2 add an entry to BENCHMARKS below.
"""
import ast
import io
import math
import pathlib
import re
import subprocess
import sys
import tokenize

ROOT = pathlib.Path(__file__).resolve().parent.parent
BENCHMARKS_DIR = ROOT / "benchmarks"

# ── Registered benchmarks (check #2 and #3) ──────────────────────────────────
# Each entry maps a benchmark directory (relative to BENCHMARKS_DIR) to:
#   script:      the analysis script to run (relative to the benchmark dir)
#   dataset:     the data file the script must read
#   document:    the published document whose numbers must match
#   doc_stop_at: heading after which numbers come from OTHER sources and must
#                NOT be checked against this script (optional)
BENCHMARKS = [
    {
        "dir": "mem_ab_v3",
        "script": "analyze.py",
        "dataset": "runs.csv",
        "document": ROOT / "docs" / "EVIDENCE.md",
        # Numbers after this heading are from retrieval benchmarks, not the AB
        # experiment — do not cross-check them against analyze.py output.
        "doc_stop_at": "## Where we lose",
    },
]

# ── RNG import patterns (check #1) ───────────────────────────────────────────
RNG_MODULES = {"random", "secrets"}
RNG_FROM_MODULES = {"random", "numpy", "numpy.random", "secrets"}

# ── File-write patterns (check #1) ───────────────────────────────────────────
WRITE_MODES = {"w", "wb", "wt", "a", "ab"}
WRITE_EXTENSIONS = {".csv", ".json", ".tsv", ".txt", ".parquet", ".pkl"}


def _imports_rng(tree: ast.AST) -> list[str]:
    """Return list of RNG-related import descriptions found in the AST."""
    found = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                base = alias.name.split(".")[0]
                if alias.name in RNG_MODULES or base in ("numpy",) and "random" in alias.name:
                    found.append(f"import {alias.name}")
        elif isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            if mod in RNG_FROM_MODULES or mod.startswith("numpy"):
                found.append(f"from {mod} import ...")
    return found


def _build_alias_map(tree: ast.AST) -> dict[str, str]:
    """Return {local_name: canonical_module_path} for every import in the tree.

    Examples:
      ``import numpy as np``           → {"np": "numpy"}
      ``import numpy.random``          → {"numpy": "numpy.random"}
      ``from numpy.random import default_rng`` → {"default_rng": "numpy.random.default_rng"}
    """
    aliases: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                # The local name is the alias (e.g. "np") or the top-level component
                # of the module path (e.g. "numpy" for "import numpy.random").
                local = alias.asname if alias.asname else alias.name.split(".")[0]
                aliases[local] = alias.name
        elif isinstance(node, ast.ImportFrom):
            mod = node.module or ""
            for alias in node.names:
                local = alias.asname if alias.asname else alias.name
                aliases[local] = f"{mod}.{alias.name}" if mod else alias.name
    return aliases


def _attr_chain(node: ast.expr) -> str | None:
    """Extract a dotted-name chain from an AST Attribute/Name node.

    Returns e.g. ``"np.random.default_rng"`` for the call target
    ``np.random.default_rng(42)``, or ``None`` if the node is not a
    simple dotted attribute chain.
    """
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if isinstance(node, ast.Name):
        parts.append(node.id)
        return ".".join(reversed(parts))
    return None


# Module paths that confer RNG capability.  A local name mapping to one of
# these (or a prefix thereof) enables RNG use through attribute access.
_NUMPY_ROOT = "numpy"
_NUMPY_RANDOM_PREFIX = "numpy.random"
_RANDOM_ROOT = "random"
_SECRETS_ROOT = "secrets"


def _uses_rng_via_alias(tree: ast.AST, aliases: dict[str, str]) -> list[str]:
    """Detect RNG *use* through aliased module names — catches what _imports_rng
    misses when numpy is imported without its ``.random`` sub-path in the import
    statement itself.

    Covered patterns (beyond what _imports_rng already catches):

    * ``import numpy as np;           np.random.default_rng(42)``  ← the real incident
    * ``import numpy;                 numpy.random.Generator(...)``
    * ``import numpy.random as nr;    nr.choices(population, k=10)``
    * ``from numpy.random import default_rng;  default_rng(42)``
    * ``import random as r;           r.randint(0, 1)``            (additive—import
                                                                    already caught)
    """
    # Partition the alias map into RNG-relevant categories.
    numpy_locals: set[str] = set()        # local name → bare "numpy"
    numpy_random_locals: set[str] = set() # local name → "numpy.random" or deeper
    direct_rng_locals: set[str] = set()   # local name → "random.*" or "secrets.*"
    # Direct RNG-function imports (e.g. "from numpy.random import default_rng")
    rng_fn_locals: set[str] = set()

    for local, module in aliases.items():
        if module == _NUMPY_ROOT:
            numpy_locals.add(local)
        elif module.startswith(_NUMPY_RANDOM_PREFIX):
            # Covers "numpy.random", "numpy.random.default_rng", etc.
            if "." in module[len(_NUMPY_RANDOM_PREFIX):]:
                # Specific function imported directly (numpy.random.default_rng)
                rng_fn_locals.add(local)
            else:
                numpy_random_locals.add(local)
        elif module == _RANDOM_ROOT or module.startswith(_RANDOM_ROOT + "."):
            direct_rng_locals.add(local)
        elif module == _SECRETS_ROOT or module.startswith(_SECRETS_ROOT + "."):
            direct_rng_locals.add(local)
        # Specific function imported from random/secrets
        if module.startswith((_RANDOM_ROOT + ".", _SECRETS_ROOT + ".")):
            rng_fn_locals.add(local)

    if not (numpy_locals or numpy_random_locals or direct_rng_locals or rng_fn_locals):
        return []

    found: list[str] = []
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue

        # Bare-name call: default_rng(42) when "from numpy.random import default_rng"
        if isinstance(node.func, ast.Name):
            name = node.func.id
            if name in rng_fn_locals:
                found.append(f"{name}() [RNG function imported directly]")
            continue

        chain = _attr_chain(node.func)
        if chain is None:
            continue

        parts = chain.split(".")
        local = parts[0]

        if local in numpy_locals:
            # np.random.anything(...) — must cross the .random. boundary
            if len(parts) >= 3 and parts[1] == "random":
                found.append(f"{chain}() [RNG via numpy alias '{local}']")
        elif local in numpy_random_locals:
            # nr.default_rng(), nr.Generator(), etc.
            if len(parts) >= 2:
                found.append(f"{chain}() [RNG via numpy.random alias '{local}']")
        elif local in direct_rng_locals:
            # r.random(), sec.token_bytes(), etc.
            if len(parts) >= 2:
                found.append(f"{chain}() [RNG via alias '{local}']")

    return found


def _writes_data_file(tree: ast.AST) -> list[str]:
    """Return list of data-file write expressions found in the AST."""
    found = []
    for node in ast.walk(tree):
        # open(path, mode) calls where mode is a write mode
        if isinstance(node, ast.Call):
            func = node.func
            func_name = (
                func.id if isinstance(func, ast.Name)
                else func.attr if isinstance(func, ast.Attribute)
                else None
            )
            if func_name in {"open", "write_csv", "to_csv", "to_json", "dump"}:
                # Check mode arg
                mode_arg = None
                for kw in node.keywords:
                    if kw.arg == "mode" and isinstance(kw.value, ast.Constant):
                        mode_arg = kw.value.value
                for i, arg in enumerate(node.args):
                    if i == 1 and isinstance(arg, ast.Constant):
                        mode_arg = arg.value
                # open() without a mode is a READ by definition (default 'r') —
                # flagging it made the gate cry wolf on a seeded-bootstrap
                # reproduce script whose only open() was reading its CSV. A
                # *variable* second positional arg still counts as unknown:
                # only the literal-absent case is safely a read.
                mode_unknown = (
                    func_name == "open"
                    and len(node.args) > 1
                    and not isinstance(node.args[1], ast.Constant)
                )
                is_write = (
                    (mode_arg is not None and mode_arg in WRITE_MODES)
                    or mode_unknown
                    or (func_name != "open" and mode_arg is None)
                )
                if is_write:
                    # Check filename extension (first arg if string)
                    fname = None
                    if node.args and isinstance(node.args[0], ast.Constant):
                        fname = str(node.args[0].value)
                    if fname is None or any(fname.endswith(ext) for ext in WRITE_EXTENSIONS):
                        found.append(f"{func_name}({fname!r}, {mode_arg!r})")
        # pathlib Path.write_text / write_bytes
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Attribute):
                if node.func.attr in {"write_text", "write_bytes", "open"}:
                    found.append(f"Path.{node.func.attr}()")
    return found


def _reads_data_file(tree: ast.AST, dataset_name: str) -> bool:
    """Return True if the script opens its dataset file for reading."""
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            func_name = (
                func.id if isinstance(func, ast.Name)
                else func.attr if isinstance(func, ast.Attribute)
                else None
            )
            if func_name in {"open", "read_csv", "read_json", "read_parquet"}:
                for arg in node.args:
                    if isinstance(arg, ast.Constant) and dataset_name in str(arg.value):
                        return True
                # Also accept when the argument is a variable (e.g. HERE / 'runs.csv')
                # We do a string-level scan as a fallback
    # String-level fallback: look for dataset_name in the source
    return False


def _source_references_dataset(source: str, dataset_name: str) -> bool:
    """Return True if dataset_name appears in the source text."""
    return dataset_name in source


# ── Number extraction ─────────────────────────────────────────────────────────
_NUM_RE = re.compile(r"\b(\d+\.\d+)\b")


def _extract_numbers(text: str) -> set[str]:
    """Return all decimal numbers appearing in text."""
    return set(_NUM_RE.findall(text))


def _numbers_match(
    script_output: str,
    document: str,
    *,
    tol: float = 0.005,
    doc_stop_at: str = "",
) -> list[str]:
    """Return list of discrepancy descriptions; empty list = all match.

    Direction: BACKWARD — every decimal number the document *claims* must
    appear (within absolute tolerance ``tol``) in the script's stdout.

    Rationale: the script may print intermediate values (t-statistics, degrees
    of freedom, etc.) that the document legitimately omits.  Checking forward
    (script → doc) would therefore false-positive on every non-headline number.
    Checking backward (doc → script) catches the two real fabrication scenarios:
      • A generated dataset makes the script output different numbers → doc
        numbers no longer match any script number → FAIL.
      • A fabricated document claims a number never output by the script → FAIL.

    ``doc_stop_at``: if set and found in the document, only the text BEFORE
    that heading is checked.  Use this to exclude numbers from other experiments
    that also appear in the same document.

    Inline code spans (``backtick content``) are stripped before extraction to
    prevent config literals like ``p_min_score=0.40`` from being treated as
    statistical claims.
    """
    script_vals = [float(n) for n in _NUM_RE.findall(script_output)]

    # Scope: stop before unrelated section
    doc_section = document
    if doc_stop_at and doc_stop_at in document:
        doc_section = document[: document.index(doc_stop_at)]

    # Strip inline code (prevents config values from being treated as claims)
    doc_section = re.sub(r"`[^`\n]*`", "", doc_section)

    doc_vals = [float(n) for n in _NUM_RE.findall(doc_section)]

    missing = []
    for dval in sorted(set(doc_vals)):
        if not any(abs(dval - s) <= tol for s in script_vals):
            missing.append(
                f"document claims {dval} — not found in script output "
                f"(closest: {min(script_vals, key=lambda s: abs(dval-s)):.4f}, tol={tol})"
            )
    return missing


# ── Check implementations ─────────────────────────────────────────────────────

def check_no_generator(
    failures: list[str],
    bench_root: pathlib.Path | None = None,
) -> None:
    """Check #1: no RNG-importing, data-writing script in any benchmark evidence dir.

    Scans the directories listed in BENCHMARKS (or, when bench_root is supplied,
    all immediate subdirectories of bench_root — used by tests).

    Benchmark harness scripts (benchmarks/scripts/) and build artefacts
    (.venv_bench/, .embed_cache/) are deliberately excluded.
    """
    if bench_root is not None:
        # Testing override: scan every immediate subdir of bench_root
        scan_dirs = [d for d in bench_root.iterdir() if d.is_dir()]
        rel_base = bench_root
    else:
        scan_dirs = [BENCHMARKS_DIR / entry["dir"] for entry in BENCHMARKS]
        rel_base = ROOT

    for bench_dir in scan_dirs:
        if not bench_dir.is_dir():
            continue
        # Only scan direct Python files in the benchmark dir itself (not nested venvs)
        for py_file in bench_dir.glob("*.py"):
            source = py_file.read_text(encoding="utf-8", errors="replace")
            try:
                tree = ast.parse(source, filename=str(py_file))
            except SyntaxError:
                continue
            rng_hits = _imports_rng(tree)
            # G1b: also detect RNG *use* through aliased names (e.g. import numpy as np;
            # np.random.default_rng(42)) — _imports_rng misses this because "random"
            # is not a substring of "numpy".  _uses_rng_via_alias walks attribute chains.
            alias_map = _build_alias_map(tree)
            rng_hits = rng_hits + _uses_rng_via_alias(tree, alias_map)
            if not rng_hits:
                continue
            write_hits = _writes_data_file(tree)
            if not write_hits:
                continue
            try:
                rel = py_file.relative_to(rel_base)
            except ValueError:
                rel = py_file
            failures.append(
                f"[G1-1] {rel}: imports RNG ({', '.join(rng_hits)}) "
                f"AND writes data file ({', '.join(write_hits[:2])}). "
                f"Generators must not live in published benchmark directories."
            )


def _rel(path: pathlib.Path) -> pathlib.Path:
    """Return path relative to ROOT if possible, else the path itself."""
    try:
        return path.relative_to(ROOT)
    except ValueError:
        return path


def check_numbers_agree(failures: list[str]) -> None:
    """Check #2: numeric claims in docs match analysis script output."""
    for entry in BENCHMARKS:
        bench_path = BENCHMARKS_DIR / entry["dir"]   # absolute if entry["dir"] is absolute
        script_path = bench_path / entry["script"]
        doc_path = pathlib.Path(entry["document"])

        if not script_path.exists():
            failures.append(f"[G1-2] {_rel(script_path)}: analysis script missing.")
            continue
        if not doc_path.exists():
            failures.append(f"[G1-2] {_rel(doc_path)}: evidence document missing.")
            continue

        result = subprocess.run(
            [sys.executable, str(script_path)],
            capture_output=True,
            text=True,
            cwd=str(bench_path),
        )
        if result.returncode != 0:
            failures.append(
                f"[G1-2] {_rel(script_path)}: script exited with code "
                f"{result.returncode}.\nstderr: {result.stderr[:500]}"
            )
            continue

        doc_text = doc_path.read_text(encoding="utf-8")
        doc_stop = entry.get("doc_stop_at", "")
        discrepancies = _numbers_match(result.stdout, doc_text, doc_stop_at=doc_stop)
        for d in discrepancies:
            failures.append(f"[G1-2] {entry['dir']}/{entry['script']} vs {doc_path.name}: {d}")


def check_scripts_read_dataset(failures: list[str]) -> None:
    """Check #3: analysis scripts must read their dataset file."""
    for entry in BENCHMARKS:
        bench_path = BENCHMARKS_DIR / entry["dir"]
        script_path = bench_path / entry["script"]
        dataset_name = entry["dataset"]

        if not script_path.exists():
            continue  # reported in check #2

        source = script_path.read_text(encoding="utf-8", errors="replace")
        if not _source_references_dataset(source, dataset_name):
            failures.append(
                f"[G1-3] {_rel(script_path)}: does not reference its "
                f"dataset '{dataset_name}'. Scripts must read real data, not print constants."
            )


# ── Main ──────────────────────────────────────────────────────────────────────

def main() -> int:
    failures: list[str] = []

    print("check_evidence_integrity: running anti-fabrication gate...")
    print(f"  repo root: {ROOT}")
    print()

    print("[1/3] Scanning for RNG-importing data-generating scripts in benchmarks/...")
    check_no_generator(failures)
    print(f"      {'PASS' if not [f for f in failures if '[G1-1]' in f] else 'FAIL'}")

    print("[2/3] Running analysis scripts and comparing against published documents...")
    check_numbers_agree(failures)
    print(f"      {'PASS' if not [f for f in failures if '[G1-2]' in f] else 'FAIL'}")

    print("[3/3] Verifying analysis scripts read their datasets...")
    check_scripts_read_dataset(failures)
    print(f"      {'PASS' if not [f for f in failures if '[G1-3]' in f] else 'FAIL'}")

    print()
    if failures:
        print(f"FAILED — {len(failures)} violation(s):")
        for f in failures:
            print(f"  • {f}")
            print()
        return 1

    print("PASSED — all evidence-integrity checks green.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
