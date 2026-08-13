"""Self-tests for scripts/check_evidence_integrity.py.

Verifies three "DONE WHEN" conditions from PGMREL-0170-QA-G1:

  T1  Gate FAILS against a deliberately generated (synthetic) dataset.
  T2  Gate FAILS against a document whose claimed number disagrees with data.
  T3  Gate PASSES on the actual current data (regression guard).
  T4  Generator check FAILS when a benchmark dir contains a script that
      imports a random-number generator AND writes a data file.
  T5  Generator check PASSES for a script that imports RNG but never writes.
  T6  Read check FAILS for a script that does not reference its dataset.

These tests import the gate module directly so they run without a live
database or any extra dependencies (stdlib only).
"""

import csv
import importlib.util
import pathlib
import random
import sys
import textwrap

import pytest

# ── Import the gate module from scripts/ ────────────────────────────────────
_REPO_ROOT = pathlib.Path(__file__).parent.parent.resolve()
_GATE_PATH = _REPO_ROOT / "scripts" / "check_evidence_integrity.py"

spec = importlib.util.spec_from_file_location("check_evidence_integrity", _GATE_PATH)
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)


# ── Helpers ──────────────────────────────────────────────────────────────────

def _make_manifest(script: pathlib.Path, dataset: pathlib.Path, document: pathlib.Path):
    """Build a single-entry manifest for the gate's check functions."""
    return [
        {
            "dir": str(script.parent),
            "script": script.name,
            "dataset": dataset.name,
            "document": document,
            "doc_stop_at": "## Where we lose",
        }
    ]


def _synthetic_csv(path: pathlib.Path, rng: random.Random) -> None:
    """Write a synthetic runs.csv whose statistics differ from the real data."""
    fieldnames = ["run_id", "arm", "week", "outcome", "turns", "cost_usd",
                  "retrieved_count", "mean_cosine"]
    arms = ["A"] * 50 + ["B"] * 50 + ["C"] * 50
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fieldnames)
        writer.writeheader()
        for i, arm in enumerate(arms):
            outcome = "success" if rng.random() > 0.5 else "failure"
            writer.writerow({
                "run_id": i + 1,
                "arm": arm,
                "week": rng.randint(0, 3),
                "outcome": outcome,
                "turns": round(rng.uniform(10, 60), 2),
                "cost_usd": round(rng.uniform(0.3, 2.5), 4),
                "retrieved_count": rng.randint(0, 10) if arm != "A" else "",
                "mean_cosine": "",
            })


def _build_fake_manifest(tmp_path: pathlib.Path, document: pathlib.Path):
    """Copy analyze.py + synthetic CSV to tmp_path; return a manifest pointing there."""
    import shutil
    # Copy the real analyze.py (it's the script logic we want; data is synthetic)
    real_script = _REPO_ROOT / "benchmarks" / "mem_ab_v3" / "analyze.py"
    fake_script = tmp_path / "analyze.py"
    shutil.copy(real_script, fake_script)

    # Write synthetic dataset
    fake_dataset = tmp_path / "runs.csv"
    _synthetic_csv(fake_dataset, random.Random(99))

    return [
        {
            "dir": str(tmp_path),
            "script": "analyze.py",
            "dataset": "runs.csv",
            "document": document,
            "doc_stop_at": "## Where we lose",
        }
    ]


# ── T1: generated dataset causes gate to fail ────────────────────────────────

def test_generated_dataset_fails(tmp_path):
    """T1: Gate fails when runs.csv is replaced with synthetic data.

    The synthetic data will produce different success rates / chi-square
    values than the ones claimed in EVIDENCE.md.  The backward number check
    must detect this mismatch.
    """
    real_doc = _REPO_ROOT / "docs" / "EVIDENCE.md"
    manifest = _build_fake_manifest(tmp_path, real_doc)

    # Patch BENCHMARKS_DIR so check_numbers_agree finds the fake script
    original_benchmarks_dir = gate.BENCHMARKS_DIR
    gate.BENCHMARKS_DIR = tmp_path.parent  # unused by the patched manifest path below

    failures = []
    # Directly call check_numbers_agree with patched BENCHMARKS list
    orig_list = gate.BENCHMARKS
    gate.BENCHMARKS = manifest
    try:
        gate.check_numbers_agree(failures)
    finally:
        gate.BENCHMARKS = orig_list
        gate.BENCHMARKS_DIR = original_benchmarks_dir

    assert failures, (
        "Gate should fail when runs.csv is a synthetic dataset — "
        "the numbers it produces differ from those in EVIDENCE.md."
    )
    assert any("[G1-2]" in f for f in failures), failures


# ── T2: edited document causes gate to fail ──────────────────────────────────

def test_edited_document_fails(tmp_path):
    """T2: Gate fails when a claimed number in the document is edited to disagree.

    We change the A-arm success rate from '55.3%' to '75.3%' — a value that
    analyze.py will never output.  The backward check must catch it.
    """
    # Create a doctored copy of EVIDENCE.md
    real_doc = _REPO_ROOT / "docs" / "EVIDENCE.md"
    doc_text = real_doc.read_text()
    # Change the success rate for Arm A (first occurrence of 55.3)
    assert "55.3" in doc_text, "EVIDENCE.md no longer contains '55.3' — update this test"
    fake_doc = tmp_path / "EVIDENCE_fake.md"
    fake_doc.write_text(doc_text.replace("55.3", "75.3", 1))  # edit just the first hit

    # Use the REAL dataset + script; only the document is wrong
    manifest = [
        {
            "dir": "mem_ab_v3",
            "script": "analyze.py",
            "dataset": "runs.csv",
            "document": fake_doc,
            "doc_stop_at": "## Where we lose",
        }
    ]

    failures = []
    orig_list = gate.BENCHMARKS
    gate.BENCHMARKS = manifest
    try:
        gate.check_numbers_agree(failures)
    finally:
        gate.BENCHMARKS = orig_list

    assert failures, (
        "Gate should fail when a document number (55.3→75.3) disagrees with "
        "the analysis script output."
    )
    assert any("[G1-2]" in f for f in failures), failures


# ── T3: current main passes ──────────────────────────────────────────────────

def test_real_data_passes():
    """T3: Gate passes on the actual committed dataset and document."""
    failures = []
    gate.check_no_generator(failures)
    gate.check_numbers_agree(failures)
    gate.check_scripts_read_dataset(failures)
    assert not failures, "Gate failed on real data:\n" + "\n".join(failures)


# ── T4: generator check fires when RNG + write in same file ──────────────────

def test_generator_check_fails_rng_plus_write(tmp_path):
    """T4: Generator check fires on a script that imports RNG and writes CSV."""
    bench_dir = tmp_path / "fake_bench"
    bench_dir.mkdir()
    sub = bench_dir / "generator_script.py"
    sub.write_text(textwrap.dedent("""\
        import random
        import csv

        rng = random.Random(42)
        with open("output.csv", "w", newline="") as f:
            writer = csv.writer(f)
            writer.writerow(["x"])
            for _ in range(10):
                writer.writerow([rng.random()])
    """))

    failures = []
    gate.check_no_generator(failures, bench_root=tmp_path)
    assert failures, "Generator check should fail for a script that imports random + writes CSV"
    assert any("RNG" in f or "generator" in f.lower() for f in failures), failures


# ── T5: RNG import alone does not fail generator check ───────────────────────

def test_generator_check_passes_rng_no_write(tmp_path):
    """T5: Generator check passes for a script that imports RNG but never writes."""
    bench_dir = tmp_path / "fake_bench"
    bench_dir.mkdir()
    sub = bench_dir / "sampler.py"
    sub.write_text(textwrap.dedent("""\
        import random
        # This script only READS data; it samples for analysis but does not write.
        with open("data.csv", "r") as f:
            rows = list(f)
        sample = random.sample(rows, min(10, len(rows)))
        print(sample)
    """))

    failures = []
    gate.check_no_generator(failures, bench_root=tmp_path)
    assert not failures, (
        "Generator check should NOT fail when the script imports random but "
        "only reads a file, never writes.\n" + "\n".join(failures)
    )


# ── T6: read check fails when script never references dataset ────────────────

def test_read_check_fails_no_dataset_reference(tmp_path):
    """T6: Read check fails for an analysis script that prints constants only."""
    bench_dir = tmp_path / "fake_bench"
    bench_dir.mkdir()
    # A "script" that just prints hardcoded numbers — no data file read
    fake_script = bench_dir / "fake_analyze.py"
    fake_script.write_text(textwrap.dedent("""\
        # Hardcoded results — does not read any data file
        print("success rate: 55.3%")
        print("p-value: 0.041")
    """))
    fake_dataset = bench_dir / "runs.csv"
    fake_dataset.write_text("run_id,arm\n1,A\n")
    fake_doc = bench_dir / "EVIDENCE.md"
    fake_doc.write_text("# Evidence\nSuccess rate: 55.3%\n")

    manifest = [
        {
            "dir": str(bench_dir),
            "script": "fake_analyze.py",
            "dataset": "runs.csv",
            "document": fake_doc,
        }
    ]

    failures = []
    orig = gate.BENCHMARKS
    gate.BENCHMARKS = manifest
    try:
        gate.check_scripts_read_dataset(failures)
    finally:
        gate.BENCHMARKS = orig

    assert failures, (
        "Read check should fail when the analysis script does not reference "
        "its dataset file."
    )
    assert any("[G1-3]" in f for f in failures), failures

# ── T7: alias-based RNG detection (G1b regression) ───────────────────────────

def test_numpy_alias_rng_fails(tmp_path):
    """T7: Generator check fires on the exact pattern from the real incident.

    The generator that shipped used 'import numpy as np' (not 'import numpy.random'),
    then called np.random.default_rng(42).  _imports_rng did not flag this because
    'random' is not a substring of 'numpy'.  _uses_rng_via_alias must catch it.

    This test FAILS against the pre-G1b detector and PASSES after the fix.
    """
    bench_dir = tmp_path / "mem_ab_v3"
    bench_dir.mkdir()
    gen = bench_dir / "generate.py"
    # Exact reproduction from PGMREL-0170-QA-G1B task description:
    gen.write_text(textwrap.dedent("""\
        import numpy as np, pathlib
        rng = np.random.default_rng(42)
        open(pathlib.Path(__file__).parent / "runs.csv", "w").write("x\\n")
    """))

    failures = []
    gate.check_no_generator(failures, bench_root=tmp_path)
    assert failures, (
        "Generator check must fail for the exact reproduction pattern: "
        "'import numpy as np; np.random.default_rng(42)' — "
        "this is the shape of the generator that actually shipped."
    )
    assert any("[G1-1]" in f for f in failures), (
        "Expected [G1-1] tag in failures, got: " + str(failures)
    )


def test_numpy_random_submodule_alias_fails(tmp_path):
    """T8: Generator check fires when numpy.random is imported under an alias."""
    bench_dir = tmp_path / "bench"
    bench_dir.mkdir()
    gen = bench_dir / "gen2.py"
    gen.write_text(textwrap.dedent("""\
        import numpy.random as nr
        rng = nr.default_rng(7)
        open("results.csv", "w").write("col\\n" + str(rng.integers(100)) + "\\n")
    """))

    failures = []
    gate.check_no_generator(failures, bench_root=tmp_path)
    assert failures, "Generator check must catch numpy.random aliased as 'nr'"
    assert any("[G1-1]" in f for f in failures), str(failures)


def test_analyze_no_false_positive(tmp_path):
    """T9: analyze.py does not false-positive — it reads data but generates nothing."""
    import shutil
    bench_dir = tmp_path / "mem_ab_v3"
    bench_dir.mkdir()
    real_script = _REPO_ROOT / "benchmarks" / "mem_ab_v3" / "analyze.py"
    shutil.copy(real_script, bench_dir / "analyze.py")

    failures = []
    gate.check_no_generator(failures, bench_root=tmp_path)
    assert not failures, (
        "analyze.py must not false-positive — it reads data without importing RNG.\n"
        + "\n".join(failures)
    )
