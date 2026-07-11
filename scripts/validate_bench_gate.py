#!/usr/bin/env python3
"""Validate a release bench-gate file — the HARD replacement for the old
"file exists → PASS" check in release.yml.

Background (investigation 2026-06-23): the release bench-gate job only checked
that benchmarks/gate/v<V>.json EXISTED. It never asserted the version stamp,
never rejected working-note drafts, and never re-ran anything. As a result a
draft file explicitly marked {"do_not_push": true, "release_decision": null}
(v0.10.1) satisfied the gate. This validator closes that hole.

It does NOT re-run benchmarks: GitHub CI has no prod corpus, so a faithful
recall@K re-run is impossible there. What it DOES enforce is honesty of the
committed gate artifact:

  1. pgmnemo_version in the file == release tag        (version stamp)
  2. gate_status == "PASS"
  3. NOT a working-note draft  (do_not_push / release_decision: null reject)
  4. quality-claim gates (significance_required==true OR gate_type contains
     "recall"/"quality") MUST carry an explicit corpus.database + the corpus
     version it was measured against (measured_pgmnemo_version), and that
     version MUST equal the tag. No more "measured on whatever was installed".

Usage: validate_bench_gate.py <version-without-v>
Exit 0 = valid; non-zero = fail (prints ::error:: for GitHub annotations).
"""
import json
import sys
from pathlib import Path

QUALITY_HINTS = ("recall", "quality", "overlap", "significance")


def err(msg: str) -> None:
    print(f"::error::{msg}")


def main() -> int:
    if len(sys.argv) != 2:
        err("usage: validate_bench_gate.py <version>")
        return 2
    version = sys.argv[1].lstrip("v")
    path = Path(f"benchmarks/gate/v{version}.json")
    if not path.exists():
        err(
            f"{path} missing. Run benchmarks and commit the gate file, "
            f"or use [bench-gate-override] in the commit message."
        )
        return 1

    try:
        gate = json.loads(path.read_text())
    except json.JSONDecodeError as e:
        err(f"{path} is not valid JSON: {e}")
        return 1

    failures = []

    # 1. version stamp
    stamped = str(gate.get("pgmnemo_version", "")).lstrip("v")
    if stamped != version:
        failures.append(
            f"pgmnemo_version='{gate.get('pgmnemo_version')}' != tag '{version}'. "
            f"The gate file must be stamped with the version under release."
        )

    # 2. PASS
    if str(gate.get("gate_status", "")).upper() != "PASS":
        failures.append(f"gate_status='{gate.get('gate_status')}' (must be PASS).")

    # 3. reject working-note drafts
    if gate.get("do_not_push") is True:
        failures.append(
            'gate file is flagged "do_not_push": true — it is a working draft, '
            "not a release gate. Promote it to a real gate file before tagging."
        )
    if "release_decision" in gate and gate.get("release_decision") is None:
        failures.append(
            'gate file has "release_decision": null — undecided draft. '
            "Set an explicit decision before tagging."
        )

    # 4. quality-claim gates must stamp the corpus version they were measured on
    gate_type = str(gate.get("gate_type", "")).lower()
    is_quality = gate.get("significance_required") is True or any(
        h in gate_type for h in QUALITY_HINTS
    )
    if is_quality:
        corpus = gate.get("corpus") or {}
        measured = str(
            gate.get("measured_pgmnemo_version")
            or corpus.get("pgmnemo_version")
            or ""
        ).lstrip("v")
        if not measured:
            failures.append(
                "quality-claim gate (recall/overlap/significance) must record the "
                "corpus version it was measured against via "
                "'measured_pgmnemo_version' (or corpus.pgmnemo_version). "
                "Absent = cannot trust the number was produced on this release's code."
            )
        elif measured != version:
            failures.append(
                f"quality numbers were measured on pgmnemo {measured}, but this is "
                f"the v{version} release. Re-measure against {version} (fresh install "
                f"or ALTER EXTENSION ... UPDATE TO '{version}') before tagging."
            )

    if failures:
        for f in failures:
            err(f)
        return 1

    kind = "quality-claim" if is_quality else "correctness/parity"
    print(f"✓ {path} valid ({kind}) — pgmnemo_version={version}, gate_status=PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
