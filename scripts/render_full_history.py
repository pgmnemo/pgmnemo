#!/usr/bin/env python3
"""
render_full_history.py — Tufte-style "all metrics × all versions" dashboard

Single dense table-graphic: each row is one (bench × scope × metric); columns
are every version that has a real-DB run, plus a sparkline trajectory and the
latest-vs-first delta in pp. No CI bands at this level (rows would be too noisy);
significance is computed separately via significance_test_extended.py.

Design references:
  - Tufte: sparklines embedded in data tables ("word-sized graphics")
  - FT Lex: tabular sparkline columns
  - Bloomberg terminal: dense small-multiples, fixed-width font

Output: docs/img/all_metrics_history.svg + .md

Usage:
    python scripts/render_full_history.py \\
        --out-svg docs/img/all_metrics_history.svg \\
        --out-md docs/img/all_metrics_history.md
"""
import argparse, glob, json, re, sys
from pathlib import Path


# Bench groups — each group's runs are version-comparable inside it
BENCH_GROUPS = [
    {
        "label": "LoCoMo session-level  (DRAGON, paper-canonical headline)",
        "pattern": "benchmarks/locomo/results/v*_session_*/metrics.json",
        "exclude": ["hybrid", "sim"],
        "metrics": ["recall@5", "recall@10", "recall@25", "recall@50", "mrr"],
    },
    {
        "label": "LoCoMo segment-level  (DRAGON, retrieval-primitive gate)",
        "pattern": "benchmarks/locomo/results/v*_*/metrics.json",
        "exclude": ["session", "hybrid", "sim"],
        "metrics": ["recall@5", "recall@10", "recall@25", "recall@50", "mrr"],
    },
    {
        "label": "LongMemEval-S  (bge-m3, production methodology)",
        "pattern": "benchmarks/longmemeval/results/v*_pgmnemo*/metrics.json",
        "exclude": ["sim"],
        "metrics": ["recall@1", "recall@5", "recall@10", "recall@20", "mrr"],
    },
]

TEXT = "#1f2937"
MUTED = "#6b7280"
GRID = "#e5e7eb"
POS = "#16a34a"
NEG = "#dc2626"
NEUTRAL = "#9ca3af"
CARD = "#f9fafb"


def parse_version(s):
    m = re.search(r"v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?", s)
    if not m:
        return (0, 0, 0, 0)
    return tuple(int(x) if x else 0 for x in m.groups())


def load_group(group):
    files = []
    for f in sorted(glob.glob(group["pattern"])):
        if any(ex in f for ex in group.get("exclude", [])):
            continue
        files.append(f)
    runs = []
    for f in files:
        try:
            d = json.load(open(f))
        except Exception:
            continue
        v = d.get("pgmnemo_version") or d.get("version") or "?"
        runs.append({"file": f, "version": v, "date": d.get("date", ""), "data": d})
    runs.sort(key=lambda r: (parse_version(r["version"]), r["date"]))
    # dedupe by version (keep latest by file mtime if duplicates)
    seen = {}
    for r in runs:
        seen[r["version"]] = r
    return list(seen.values())


def sparkline_svg(values, x, y, w=70, h=14, color=TEXT):
    """Tufte word-sized sparkline."""
    if not values or len(values) < 2:
        # single point
        if values:
            return f'<circle cx="{x+w/2}" cy="{y+h/2}" r="2" fill="{color}"/>'
        return ""
    vmin_raw, vmax_raw = min(values), max(values)
    vmin, vmax = vmin_raw, vmax_raw
    if vmax == vmin:
        vmax = vmin + 0.001
    pts = []
    for i, v in enumerate(values):
        px = x + i * w / (len(values) - 1)
        py = y + h - h * (v - vmin) / (vmax - vmin)
        pts.append((px, py))
    poly = " ".join(f"{p[0]:.1f},{p[1]:.1f}" for p in pts)
    out = [f'<polyline points="{poly}" fill="none" stroke="{color}" stroke-width="1.2"/>']
    # last dot
    lx, ly = pts[-1]
    out.append(f'<circle cx="{lx:.1f}" cy="{ly:.1f}" r="1.8" fill="{color}"/>')
    # min/max dots in light
    mn_i = values.index(vmin_raw)
    mx_i = values.index(vmax_raw)
    if mn_i != len(values) - 1:
        out.append(f'<circle cx="{pts[mn_i][0]:.1f}" cy="{pts[mn_i][1]:.1f}" r="1.5" fill="{NEG}"/>')
    if mx_i != len(values) - 1:
        out.append(f'<circle cx="{pts[mx_i][0]:.1f}" cy="{pts[mx_i][1]:.1f}" r="1.5" fill="{POS}"/>')
    return "\n".join(out)


def cell_value(val, prev=None):
    """Format a cell value with delta vs prev if given."""
    if val is None:
        return ("—", MUTED)
    if prev is None:
        return (f"{val:.3f}", TEXT)
    delta_pp = (val - prev) * 100
    if abs(delta_pp) < 0.1:
        return (f"{val:.3f}", TEXT)
    return (f"{val:.3f}", TEXT)


def render(out_svg, out_md):
    # Build row list across all groups
    sections = []
    for group in BENCH_GROUPS:
        runs = load_group(group)
        if not runs:
            continue
        scopes_overall = ["OVERALL"]
        cats = list(runs[-1]["data"].get("by_category", {}).keys()) if runs else []
        rows = []
        for scope in [*scopes_overall, *cats]:
            for metric in group["metrics"]:
                series = []
                for r in runs:
                    if scope == "OVERALL":
                        stats = r["data"].get("overall", {}).get(metric)
                    else:
                        stats = r["data"].get("by_category", {}).get(scope, {}).get(metric)
                    series.append(stats["mean"] if stats else None)
                # skip rows where all values missing
                if all(v is None for v in series):
                    continue
                rows.append({"scope": scope, "metric": metric, "series": series})
        sections.append({"label": group["label"], "runs": runs, "rows": rows, "metrics": group["metrics"]})

    if not sections:
        print("No data", file=sys.stderr)
        sys.exit(2)

    # SVG layout
    ROW_H = 18
    HEADER_H = 50
    SECTION_GAP = 30
    LABEL_W = 130
    METRIC_W = 80
    VER_W = 65
    SPARK_W = 70
    DELTA_W = 70

    # Calculate width based on max versions in any section
    max_versions = max(len(s["runs"]) for s in sections)
    INNER_W = LABEL_W + METRIC_W + max_versions * VER_W + SPARK_W + DELTA_W + 40
    PAGE_W = INNER_W + 40

    # Compute height
    total_h = 90  # title block
    for s in sections:
        total_h += SECTION_GAP + HEADER_H + ROW_H * len(s["rows"])
    total_h += 40

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{PAGE_W}" height="{total_h}" viewBox="0 0 {PAGE_W} {total_h}" font-family="-apple-system, system-ui, sans-serif">']
    parts.append(f'<rect width="100%" height="100%" fill="white"/>')

    # Title
    parts.append(f'<text x="20" y="30" fill="{TEXT}" font-size="20" font-weight="700">pgmnemo — all metrics × all versions</text>')
    parts.append(f'<text x="20" y="52" fill="{MUTED}" font-size="12">Each row is one (benchmark × scope × metric). Columns: every version that has a real-DB run, plus a sparkline showing the full trajectory and the latest-vs-first delta in pp.</text>')
    parts.append(f'<text x="20" y="70" fill="{MUTED}" font-size="11">Sparkline encoding: red dot = lowest historical value (if not latest), green dot = highest historical value (if not latest), filled dot at end = latest. Tufte word-sized graphic.</text>')

    y = 90
    for s in sections:
        runs = s["runs"]
        nver = len(runs)

        y += SECTION_GAP
        # section title bar
        parts.append(f'<rect x="20" y="{y}" width="{INNER_W}" height="28" fill="{CARD}"/>')
        parts.append(f'<text x="30" y="{y+18}" fill="{TEXT}" font-size="13" font-weight="600">{s["label"]}</text>')
        y += 28

        # version header
        x = 20
        parts.append(f'<text x="{x+5}" y="{y+15}" fill="{MUTED}" font-size="10" font-weight="600">SCOPE</text>')
        parts.append(f'<text x="{x+LABEL_W+5}" y="{y+15}" fill="{MUTED}" font-size="10" font-weight="600">METRIC</text>')
        for i, r in enumerate(runs):
            cx = x + LABEL_W + METRIC_W + i * VER_W
            parts.append(f'<text x="{cx + VER_W/2}" y="{y+15}" fill="{MUTED}" font-size="10" font-weight="600" text-anchor="middle">v{r["version"]}</text>')
            parts.append(f'<text x="{cx + VER_W/2}" y="{y+25}" fill="{MUTED}" font-size="9" text-anchor="middle">{r["date"][-5:] if r["date"] else ""}</text>')
        sx = x + LABEL_W + METRIC_W + nver * VER_W
        parts.append(f'<text x="{sx + SPARK_W/2}" y="{y+15}" fill="{MUTED}" font-size="10" font-weight="600" text-anchor="middle">trajectory</text>')
        parts.append(f'<text x="{sx + SPARK_W + 5}" y="{y+15}" fill="{MUTED}" font-size="10" font-weight="600">Δpp first→latest</text>')
        y += HEADER_H - 28

        # Rows
        prev_scope = None
        for ri, row in enumerate(s["rows"]):
            row_y = y + ri * ROW_H

            # alternating bg
            if ri % 2 == 0:
                parts.append(f'<rect x="20" y="{row_y}" width="{INNER_W}" height="{ROW_H}" fill="#fafafa"/>')

            # scope label (only on first metric of scope)
            scope_changed = row["scope"] != prev_scope
            if scope_changed:
                col = TEXT if row["scope"] == "OVERALL" else "#374151"
                weight = "700" if row["scope"] == "OVERALL" else "500"
                parts.append(f'<text x="25" y="{row_y+13}" fill="{col}" font-size="11" font-weight="{weight}">{row["scope"]}</text>')
            prev_scope = row["scope"]

            # metric
            parts.append(f'<text x="{LABEL_W+25}" y="{row_y+13}" fill="{TEXT}" font-size="11" font-family="monospace">{row["metric"]}</text>')

            # per-version values
            for i, v in enumerate(row["series"]):
                cx = 20 + LABEL_W + METRIC_W + i * VER_W
                if v is None:
                    parts.append(f'<text x="{cx + VER_W/2}" y="{row_y+13}" fill="{MUTED}" font-size="10" text-anchor="middle">—</text>')
                else:
                    parts.append(f'<text x="{cx + VER_W/2}" y="{row_y+13}" fill="{TEXT}" font-size="10" text-anchor="middle" font-family="monospace">{v:.3f}</text>')

            # sparkline
            sx = 20 + LABEL_W + METRIC_W + nver * VER_W + 5
            non_null = [v for v in row["series"] if v is not None]
            parts.append(sparkline_svg(non_null, sx, row_y+2, w=SPARK_W-10, h=ROW_H-4))

            # delta first → latest
            firsts = [v for v in row["series"] if v is not None]
            if len(firsts) >= 2:
                delta_pp = (firsts[-1] - firsts[0]) * 100
                col = POS if delta_pp > 0.5 else (NEG if delta_pp < -0.5 else NEUTRAL)
                arrow = "▲" if delta_pp > 0.05 else ("▼" if delta_pp < -0.05 else "─")
                dx = sx + SPARK_W
                parts.append(f'<text x="{dx + 5}" y="{row_y+13}" fill="{col}" font-size="11" font-family="monospace">{arrow}{abs(delta_pp):5.2f}pp</text>')

        y += len(s["rows"]) * ROW_H

    # Footer
    y += 20
    parts.append(f'<line x1="20" y1="{y}" x2="{PAGE_W-20}" y2="{y}" stroke="{GRID}"/>')
    y += 18
    parts.append(f'<text x="20" y="{y}" fill="{MUTED}" font-size="10">Generated by scripts/render_full_history.py. Statistical significance per-cell: scripts/significance_test_extended.py. Raw artefacts: benchmarks/&lt;bench&gt;/results/v&lt;ver&gt;_&lt;date&gt;/.</text>')

    parts.append("</svg>")
    Path(out_svg).parent.mkdir(parents=True, exist_ok=True)
    with open(out_svg, "w") as f:
        f.write("\n".join(parts))
    print(f"[wrote] {out_svg}  ({sum(len(s['rows']) for s in sections)} rows, {len(sections)} sections)")

    # Markdown table version
    md = [f"# pgmnemo — all metrics × all versions\n",
          "Tufte-style sparkline table. Each row is one (benchmark × scope × metric).\n",
          f"![all metrics history]({Path(out_svg).name})\n\n"]
    for s in sections:
        md.append(f"\n## {s['label']}\n")
        hdr = "| scope | metric | " + " | ".join(f"v{r['version']}" for r in s['runs']) + " | Δ first→latest |"
        sep = "|---" * (2 + len(s['runs']) + 1) + "|"
        md.append(hdr); md.append(sep)
        for row in s["rows"]:
            cells = []
            for v in row["series"]:
                cells.append(f"{v:.3f}" if v is not None else "—")
            non_null = [v for v in row["series"] if v is not None]
            if len(non_null) >= 2:
                d = (non_null[-1] - non_null[0]) * 100
                arrow = "▲" if d > 0.5 else ("▼" if d < -0.5 else "─")
                delta_str = f"{arrow}{abs(d):.2f}pp"
            else:
                delta_str = "—"
            md.append(f"| **{row['scope']}** | `{row['metric']}` | " + " | ".join(cells) + f" | {delta_str} |")
    with open(out_md, "w") as f:
        f.write("\n".join(md))
    print(f"[wrote] {out_md}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out-svg", default="docs/img/all_metrics_history.svg")
    ap.add_argument("--out-md", default="docs/img/all_metrics_history.md")
    args = ap.parse_args()
    render(args.out_svg, args.out_md)


if __name__ == "__main__":
    main()
