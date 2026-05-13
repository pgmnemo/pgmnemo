#!/usr/bin/env python3
"""
render_progression.py — auto-render version-progression charts from metrics.json files

For each (dataset × embedder × mode) the script collects all metrics.json files
matching a pattern, sorts by version, and emits:
  - Pure-Python SVG line chart per metric (overall + per-category small-multiples)
  - Markdown table of (version × metric) with Δ-vs-prev annotation

No matplotlib / no chart libs — pure SVG. Output is committed to docs/img/.

Usage:
    python scripts/render_progression.py \\
        --pattern "benchmarks/locomo/results/v*_session_*/metrics.json" \\
        --out-svg docs/img/progression_locomo_session.svg \\
        --out-md docs/img/progression_locomo_session.md

For full release tracking call this from CI on every tag push.
"""
import argparse, glob, json, math, re, sys
from pathlib import Path

W, H = 720, 220     # per-panel size
PAD_L, PAD_R, PAD_T, PAD_B = 60, 20, 30, 40
COLORS = {
    "single_hop":   "#1f77b4",
    "multi_hop":    "#ff7f0e",
    "temporal":     "#d62728",   # red — explicit because we monitor regressions here
    "open_domain":  "#2ca02c",
    "adversarial":  "#9467bd",
    "OVERALL":      "#000000",
}


def parse_version(s):
    """v0.3.0 → (0,3,0). Returns sort key."""
    m = re.search(r"v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?", s)
    if not m:
        return (0, 0, 0, 0)
    return tuple(int(x) if x else 0 for x in m.groups())


def load_runs(pattern):
    files = sorted(glob.glob(pattern))
    runs = []
    for f in files:
        try:
            d = json.load(open(f))
        except Exception as e:
            print(f"skip {f}: {e}", file=sys.stderr)
            continue
        version = d.get("pgmnemo_version") or d.get("version") or "?"
        date = d.get("date", "")
        runs.append({"file": f, "version": version, "date": date, "data": d})
    runs.sort(key=lambda r: (parse_version(r["version"]), r["date"]))
    return runs


def svg_line_panel(x0, y0, runs, metric, scope, title):
    """Render one panel (line chart with CI95 bands) at offset (x0, y0)."""
    out = []
    inner_w = W - PAD_L - PAD_R
    inner_h = H - PAD_T - PAD_B
    points = []
    for r in runs:
        d = r["data"]
        if scope == "OVERALL":
            stats = d.get("overall", {}).get(metric)
        else:
            stats = d.get("by_category", {}).get(scope, {}).get(metric)
        if not stats:
            continue
        points.append({
            "version": r["version"],
            "mean": stats["mean"],
            "lo": stats.get("ci95_lo", stats["mean"]),
            "hi": stats.get("ci95_hi", stats["mean"]),
        })
    if not points:
        out.append(f'<text x="{x0+PAD_L}" y="{y0+PAD_T+inner_h/2}" font-family="sans-serif" font-size="11" fill="#999">no data: {scope}/{metric}</text>')
        return "\n".join(out)

    means = [p["mean"] for p in points]
    los = [p["lo"] for p in points]
    his = [p["hi"] for p in points]
    y_min = max(0, min(los) - 0.05)
    y_max = min(1, max(his) + 0.05)
    if y_max <= y_min: y_max = y_min + 0.05

    def x_pos(i):
        if len(points) == 1: return x0 + PAD_L + inner_w / 2
        return x0 + PAD_L + i * inner_w / (len(points) - 1)
    def y_pos(v):
        return y0 + PAD_T + inner_h * (1 - (v - y_min) / (y_max - y_min))

    color = COLORS.get(scope, "#444")

    # Title
    out.append(f'<text x="{x0+PAD_L}" y="{y0+PAD_T-10}" font-family="sans-serif" font-size="12" font-weight="bold">{title}</text>')

    # Y-axis ticks
    for frac in (0, 0.25, 0.5, 0.75, 1.0):
        yv = y_min + frac * (y_max - y_min)
        ypx = y0 + PAD_T + inner_h * (1 - frac)
        out.append(f'<line x1="{x0+PAD_L}" y1="{ypx}" x2="{x0+W-PAD_R}" y2="{ypx}" stroke="#eee" stroke-width="1"/>')
        out.append(f'<text x="{x0+PAD_L-6}" y="{ypx+3}" font-family="sans-serif" font-size="9" text-anchor="end" fill="#666">{yv:.2f}</text>')

    # CI95 band as polygon
    if len(points) >= 2:
        band_pts = []
        for i, p in enumerate(points):
            band_pts.append(f'{x_pos(i):.1f},{y_pos(p["hi"]):.1f}')
        for i, p in reversed(list(enumerate(points))):
            band_pts.append(f'{x_pos(i):.1f},{y_pos(p["lo"]):.1f}')
        out.append(f'<polygon points="{" ".join(band_pts)}" fill="{color}" fill-opacity="0.12" stroke="none"/>')

    # Line
    if len(points) >= 2:
        pts = " ".join(f"{x_pos(i):.1f},{y_pos(p['mean']):.1f}" for i, p in enumerate(points))
        out.append(f'<polyline points="{pts}" fill="none" stroke="{color}" stroke-width="2"/>')

    # Dots + version labels + value annotation
    for i, p in enumerate(points):
        xpx = x_pos(i); ypx = y_pos(p["mean"])
        out.append(f'<circle cx="{xpx:.1f}" cy="{ypx:.1f}" r="3" fill="{color}"/>')
        out.append(f'<text x="{xpx:.1f}" y="{ypx-8:.1f}" font-family="sans-serif" font-size="9" text-anchor="middle" fill="{color}">{p["mean"]:.3f}</text>')
        out.append(f'<text x="{xpx:.1f}" y="{y0+H-PAD_B+15:.1f}" font-family="sans-serif" font-size="10" text-anchor="middle" fill="#444">{p["version"]}</text>')

    # Delta indicators between consecutive points
    for i in range(1, len(points)):
        delta = (points[i]["mean"] - points[i-1]["mean"]) * 100
        if abs(delta) >= 1.0:
            xpx = (x_pos(i-1) + x_pos(i)) / 2
            ypx = y0 + PAD_T + 12
            col = "#2ca02c" if delta > 0 else "#d62728"
            out.append(f'<text x="{xpx:.1f}" y="{ypx}" font-family="sans-serif" font-size="10" fill="{col}" text-anchor="middle">{delta:+.1f}pp</text>')

    return "\n".join(out)


def render_svg(runs, out_path, title):
    metrics_to_show = ["recall@5", "recall@10", "recall@25", "mrr"]
    scopes_overall = ["OVERALL"]
    if runs:
        # find which categories exist in first run
        cats_present = list(runs[0]["data"].get("by_category", {}).keys())
    else:
        cats_present = []
    scopes_per_cat = cats_present

    # layout: 1 row OVERALL × 4 metrics, then 1 row per category × 4 metrics
    rows = 1 + len(scopes_per_cat)
    cols = len(metrics_to_show)
    total_w = cols * W
    total_h = rows * H + 40

    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{total_w}" height="{total_h}" viewBox="0 0 {total_w} {total_h}">']
    parts.append(f'<rect width="100%" height="100%" fill="white"/>')
    parts.append(f'<text x="{total_w/2}" y="20" font-family="sans-serif" font-size="14" font-weight="bold" text-anchor="middle">{title}</text>')

    for ri, scope in enumerate([*scopes_overall, *scopes_per_cat]):
        for ci, metric in enumerate(metrics_to_show):
            x0 = ci * W
            y0 = 40 + ri * H
            t = f"{scope} / {metric}"
            parts.append(svg_line_panel(x0, y0, runs, metric, scope, t))

    parts.append('</svg>')
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        f.write("\n".join(parts))
    print(f"[wrote] {out_path}  ({rows} rows × {cols} cols, {len(runs)} versions)")


def render_md_table(runs, out_path, title):
    metrics_to_show = ["recall@5", "recall@10", "recall@25", "recall@50", "mrr"]
    lines = [f"# {title}\n", "Auto-rendered by `scripts/render_progression.py`. Do not edit by hand.\n"]

    # Overall table
    lines.append("## OVERALL\n")
    hdr = "| version | date | " + " | ".join(metrics_to_show) + " |"
    sep = "|---" * (len(metrics_to_show) + 2) + "|"
    lines.append(hdr); lines.append(sep)
    prev = {m: None for m in metrics_to_show}
    for r in runs:
        row = [r["version"], r["date"]]
        for m in metrics_to_show:
            stats = r["data"].get("overall", {}).get(m)
            if not stats:
                row.append("—")
                continue
            v = stats["mean"]
            if prev[m] is None:
                row.append(f"{v:.4f}")
            else:
                delta_pp = (v - prev[m]) * 100
                arrow = "▲" if delta_pp > 0 else ("▼" if delta_pp < 0 else "—")
                row.append(f"{v:.4f} <sup>{arrow}{abs(delta_pp):.1f}pp</sup>")
            prev[m] = v
        lines.append("| " + " | ".join(row) + " |")

    # Per-category tables
    if runs:
        cats = list(runs[0]["data"].get("by_category", {}).keys())
        for cat in cats:
            lines.append(f"\n## {cat}\n")
            lines.append(hdr); lines.append(sep)
            prev = {m: None for m in metrics_to_show}
            for r in runs:
                row = [r["version"], r["date"]]
                stats = r["data"].get("by_category", {}).get(cat, {})
                for m in metrics_to_show:
                    if m not in stats:
                        row.append("—")
                        continue
                    v = stats[m]["mean"]
                    if prev[m] is None:
                        row.append(f"{v:.4f}")
                    else:
                        delta_pp = (v - prev[m]) * 100
                        arrow = "▲" if delta_pp > 0 else ("▼" if delta_pp < 0 else "—")
                        emoji = " 📉" if delta_pp < -1.0 else (" 📈" if delta_pp > 1.0 else "")
                        row.append(f"{v:.4f} <sup>{arrow}{abs(delta_pp):.1f}pp{emoji}</sup>")
                    prev[m] = v
                lines.append("| " + " | ".join(row) + " |")

    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        f.write("\n".join(lines))
    print(f"[wrote] {out_path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pattern", required=True, help='glob pattern for metrics.json files (e.g. "benchmarks/locomo/results/v*_session_*/metrics.json")')
    ap.add_argument("--out-svg", required=True)
    ap.add_argument("--out-md", required=True)
    ap.add_argument("--title", default="pgmnemo benchmark progression")
    args = ap.parse_args()

    runs = load_runs(args.pattern)
    if not runs:
        print("No runs found matching pattern", file=sys.stderr)
        sys.exit(2)
    print(f"Loaded {len(runs)} runs:")
    for r in runs:
        print(f"  {r['version']:<10} {r['date']:<12} {r['file']}")

    render_svg(runs, args.out_svg, args.title)
    render_md_table(runs, args.out_md, args.title)


if __name__ == "__main__":
    main()
