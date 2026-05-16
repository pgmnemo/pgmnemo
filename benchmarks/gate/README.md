# Benchmark Gate Files — Release Pre-Push Snapshots

This directory contains one `v<version>.json` file per tagged release. Each file is a
**consolidated snapshot** of every real-DB benchmark `metrics.json` produced for that
version. It exists to make the release-gate decision **mechanical**:

```
.github/workflows/release.yml  → check that benchmarks/gate/v<tag>.json exists and
                                  passes significance_test_extended.py vs the previous
                                  tag's gate file. Missing file or exit=2 = blocked tag push.
```

## Format

```json
{
  "version": "v0.3.0",
  "date": "2026-05-13",
  "schema_version": "v1",
  "tables": {
    "locomo_session":    { ...metrics.json content... },
    "locomo_segment":    { ...metrics.json content... },
    "longmemeval":       { ...metrics.json content... }
  }
}
```

The `tables` keys mirror the section labels in `benchmarks/METRICS_BY_VERSION.md`.
Adding a new bench means: add a key, run `scripts/significance_test_extended.py` on
that table separately, and document the mapping in `docs/BENCHMARK_PROTOCOL.md §3`.

## Per-release workflow

```bash
# 1. After the bench scripts finish for vX.Y.Z, consolidate:
python3 - <<EOF
import json
gate = {
    "version": "vX.Y.Z",
    "date": "$(date -u +%Y-%m-%d)",
    "schema_version": "v1",
    "tables": {
        "locomo_session":  json.load(open("benchmarks/locomo/results/vX.Y.Z_session_<date>/metrics.json")),
        "locomo_segment":  json.load(open("benchmarks/locomo/results/vX.Y.Z_<date>/metrics.json")),
        "longmemeval":     json.load(open("benchmarks/longmemeval/results/vX.Y.Z_<date>/metrics.json")),
    },
}
open("benchmarks/gate/vX.Y.Z.json", "w").write(json.dumps(gate, indent=2))
EOF

# 2. Run significance test (per table — overall verdict = worst-of-all-tables)
for table in locomo_session locomo_segment longmemeval; do
    jq ".tables.${table}"   benchmarks/gate/v<prev>.json  > /tmp/base_${table}.json
    jq ".tables.${table}"   benchmarks/gate/vX.Y.Z.json   > /tmp/cand_${table}.json
    python3 scripts/significance_test_extended.py /tmp/base_${table}.json /tmp/cand_${table}.json
done

# 3. Commit the gate file + push tag only if all tables pass (exit ≤ 1 or exit 3 with watchlist)
```

## What this prevents

- Tag pushed without running benchmarks → caught (missing gate file)
- Tag pushed despite regression → caught (significance_test_extended.py exit 2)
- Two consecutive releases with no measurement on a bench → caught (gate file shape
  must include all tables seen in the previous gate file; CI fails if a table disappears)

## Bypass

The only way to bypass the gate is a commit message containing `[bench-gate-override]`.
That string is auto-extracted into the public release notes as a disclosure (see
`docs/the release process §6`).
