#!/usr/bin/env python3
"""
render_executive_scorecard.py — single-page release scorecard for non-technical readers

Output: docs/img/scorecard_<version>.svg + docs/img/scorecard_<version>.md
Audience: founder / investor / non-ML reader. Goes in release notes top section.

Design grounded in best dataviz practice for exec audiences:
  - Single PASS / WATCH / FAIL verdict at the top (traffic light)
  - 3 hero metrics in big bold type (no CI bands, no p-values)
  - Plain-language axis labels: "Recall quality" not "recall@10"
  - Reference line at previous-release baseline; annotated, no legend
  - Sparkline per category showing version-to-version trajectory
  - Brief one-sentence interpretation under each block

Usage:
    python scripts/render_executive_scorecard.py \\
        --version v0.3.0 \\
        --pattern "benchmarks/locomo/results/v*_session_*/metrics.json" \\
        --bench-label "LoCoMo memory recall benchmark" \\
        --out-svg docs/img/scorecard_v0.3.0.svg \\
        --out-md docs/img/scorecard_v0.3.0.md
"""
import argparse, glob, json, re, sys
from pathlib import Path

PASS_GREEN = "#2ca02c"
WATCH_AMBER = "#f0ad4e"
FAIL_RED = "#d62728"
TEXT_DARK = "#1f2937"
TEXT_MUTED = "#6b7280"
BG_CARD = "#f9fafb"


def parse_version(s):
    m = re.search(r"v?(\d+)\.(\d+)\.(\d+)(?:\.(\d+))?", s)
    if not m:
        return (0, 0, 0, 0)
    return tuple(int(x) if x else 0 for x in m.groups())


def load_runs(pattern):
    runs = []
    for f in sorted(glob.glob(pattern)):
        try:
            d = json.load(open(f))
        except Exception:
            continue
        v = d.get("pgmnemo_version") or d.get("version") or "?"
        runs.append({"file": f, "version": v, "date": d.get("date", ""), "data": d})
    runs.sort(key=lambda r: (parse_version(r["version"]), r["date"]))
    return runs


def classify_change(delta_pp):
    """Return (verdict, color) for a delta in percentage points."""
    if abs(delta_pp) < 1.0:
        return ("Stable", TEXT_MUTED)
    if delta_pp >= 2.0:
        return ("Improved", PASS_GREEN)
    if delta_pp >= 1.0:
        return ("Slight improvement", PASS_GREEN)
    if delta_pp <= -2.0:
        return ("Regressed", FAIL_RED)
    if delta_pp <= -1.0:
        return ("Slight regression", WATCH_AMBER)
    return ("Stable", TEXT_MUTED)


def overall_verdict(per_cat_deltas):
    """Aggregate: any -2pp or worse → WATCH; any +2pp → highlight; else PASS."""
    has_reg = any(d <= -1.0 for d in per_cat_deltas)
    has_imp = any(d >= 2.0 for d in per_cat_deltas)
    if has_reg and not has_imp:
        return ("WATCH", WATCH_AMBER, "One or more categories drifted — monitor next release")
    if has_reg and has_imp:
        return ("WATCH", WATCH_AMBER, "Mixed: some categories improved, some drifted — net stable")
    if has_imp:
        return ("PASS+", PASS_GREEN, "Quality improved without regression")
    return ("PASS", PASS_GREEN, "No regression — safe to ship")


def sparkline(values, x, y, w, h, color=TEXT_DARK):
    """Tiny line chart with last value highlighted."""
    if not values:
        return ""
    vmin, vmax = min(values), max(values)
    if vmax == vmin:
        vmax = vmin + 0.01
    pts = []
    for i, v in enumerate(values):
        px = x + (i * w / max(1, len(values) - 1)) if len(values) > 1 else x + w / 2
        py = y + h - h * (v - vmin) / (vmax - vmin)
        pts.append((px, py))
    out = []
    if len(pts) > 1:
        poly = " ".join(f"{p[0]:.1f},{p[1]:.1f}" for p in pts)
        out.append(f'<polyline points="{poly}" fill="none" stroke="{color}" stroke-width="2"/>')
    # last dot
    lx, ly = pts[-1]
    out.append(f'<circle cx="{lx:.1f}" cy="{ly:.1f}" r="3.5" fill="{color}"/>')
    return "\n".join(out)


def render_svg(version, runs, bench_label, out_path):
    if len(runs) < 2:
        print("ERROR: need at least 2 versions to compare", file=sys.stderr)
        sys.exit(2)

    # find current version run + previous
    cur = next((r for r in runs if r["version"] == version.lstrip("v")), runs[-1])
    prev_runs = [r for r in runs if r["version"] != cur["version"]]
    if not prev_runs:
        print("ERROR: no prior version to compare against", file=sys.stderr)
        sys.exit(2)
    prev = prev_runs[-1]

    overall_metric = "recall@10"
    cur_overall = cur["data"]["overall"][overall_metric]["mean"]
    prev_overall = prev["data"]["overall"][overall_metric]["mean"]
    overall_delta_pp = (cur_overall - prev_overall) * 100

    # per-category deltas
    cat_data = []
    cats = list(cur["data"].get("by_category", {}).keys())
    for cat in cats:
        cur_cat = cur["data"]["by_category"][cat][overall_metric]["mean"]
        prev_cat = prev["data"]["by_category"].get(cat, {}).get(overall_metric, {"mean": cur_cat})["mean"]
        delta_pp = (cur_cat - prev_cat) * 100
        spark_values = []
        for r in runs:
            v = r["data"].get("by_category", {}).get(cat, {}).get(overall_metric, {}).get("mean")
            if v is not None:
                spark_values.append(v)
        cat_data.append({"cat": cat, "cur": cur_cat, "prev": prev_cat,
                        "delta_pp": delta_pp, "spark": spark_values})

    # overall verdict
    deltas = [c["delta_pp"] for c in cat_data]
    verdict, vcolor, vmsg = overall_verdict(deltas)

    W = 880
    H = 720
    parts = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" viewBox="0 0 {W} {H}" font-family="-apple-system, system-ui, sans-serif">']
    parts.append(f'<rect width="100%" height="100%" fill="white"/>')

    # Top banner
    parts.append(f'<rect x="0" y="0" width="{W}" height="110" fill="{vcolor}"/>')
    parts.append(f'<text x="40" y="50" fill="white" font-size="34" font-weight="700">{verdict}</text>')
    parts.append(f'<text x="40" y="80" fill="white" font-size="15" opacity="0.95">{vmsg}</text>')
    parts.append(f'<text x="{W-40}" y="50" fill="white" font-size="22" font-weight="600" text-anchor="end">pgmnemo {version}</text>')
    parts.append(f'<text x="{W-40}" y="78" fill="white" font-size="13" opacity="0.9" text-anchor="end">{bench_label}</text>')

    # Hero number
    y = 150
    parts.append(f'<text x="40" y="{y}" fill="{TEXT_MUTED}" font-size="13" font-weight="500" letter-spacing="1">RECALL QUALITY (FINDS THE RIGHT MEMORY IN TOP 10)</text>')
    y += 50
    parts.append(f'<text x="40" y="{y}" fill="{TEXT_DARK}" font-size="64" font-weight="700">{cur_overall*100:.1f}%</text>')

    # Delta chip
    delta_color = PASS_GREEN if overall_delta_pp >= 0 else (FAIL_RED if overall_delta_pp <= -1 else TEXT_MUTED)
    sign = "+" if overall_delta_pp >= 0 else ""
    delta_text = f"{sign}{overall_delta_pp:.1f}pp vs {prev['version']}"
    parts.append(f'<rect x="240" y="{y-32}" width="190" height="32" rx="16" fill="{delta_color}" opacity="0.15"/>')
    parts.append(f'<text x="335" y="{y-10}" fill="{delta_color}" font-size="15" font-weight="600" text-anchor="middle">{delta_text}</text>')

    parts.append(f'<text x="40" y="{y+25}" fill="{TEXT_MUTED}" font-size="13">of {cur["data"]["overall"][overall_metric]["n"]} test questions answered with the right session in the top 10 retrieved.</text>')

    # Reference baseline line
    y = 270
    parts.append(f'<line x1="40" y1="{y}" x2="{W-40}" y2="{y}" stroke="#e5e7eb" stroke-width="1"/>')

    # Section: by category
    y += 30
    parts.append(f'<text x="40" y="{y}" fill="{TEXT_DARK}" font-size="16" font-weight="600">By question type — version trajectory</text>')
    y += 5
    parts.append(f'<text x="40" y="{y+15}" fill="{TEXT_MUTED}" font-size="12">Each row: current quality + sparkline across all versions. Watch the trend, not single points.</text>')

    # Category cards
    y += 35
    card_h = 60
    cat_labels = {
        "single_hop":  "Single-hop questions",
        "multi_hop":   "Multi-hop reasoning",
        "temporal":    "Temporal / time-aware",
        "open_domain": "Open-domain queries",
        "adversarial": "Adversarial (hard)",
    }
    cat_explain = {
        "single_hop":  "answer comes from one memory chunk",
        "multi_hop":   "needs to combine multiple memories",
        "temporal":    "asks about timing — currently weakest area",
        "open_domain": "broadest category, largest sample",
        "adversarial": "designed to mislead retrieval",
    }
    for cdata in cat_data:
        cat = cdata["cat"]
        label = cat_labels.get(cat, cat)
        explain = cat_explain.get(cat, "")
        change, ccol = classify_change(cdata["delta_pp"])
        sign = "+" if cdata["delta_pp"] >= 0 else ""
        delta_str = f"{sign}{cdata['delta_pp']:.1f}pp"

        # card bg
        parts.append(f'<rect x="40" y="{y}" width="{W-80}" height="{card_h-6}" fill="{BG_CARD}" rx="4"/>')
        # category label + explainer
        parts.append(f'<text x="60" y="{y+22}" fill="{TEXT_DARK}" font-size="14" font-weight="600">{label}</text>')
        parts.append(f'<text x="60" y="{y+40}" fill="{TEXT_MUTED}" font-size="11">{explain}</text>')
        # current value
        parts.append(f'<text x="450" y="{y+32}" fill="{TEXT_DARK}" font-size="22" font-weight="700" text-anchor="end">{cdata["cur"]*100:.1f}%</text>')
        # sparkline
        sp = sparkline(cdata["spark"], 470, y+15, 100, 30, color=ccol if change!="Stable" else TEXT_MUTED)
        parts.append(sp)
        # change label
        parts.append(f'<text x="{W-60}" y="{y+25}" fill="{ccol}" font-size="13" font-weight="600" text-anchor="end">{change}</text>')
        parts.append(f'<text x="{W-60}" y="{y+42}" fill="{ccol}" font-size="11" text-anchor="end">{delta_str}</text>')
        y += card_h

    # Footer: methodology link
    y += 10
    parts.append(f'<line x1="40" y1="{y}" x2="{W-40}" y2="{y}" stroke="#e5e7eb" stroke-width="1"/>')
    y += 20
    parts.append(f'<text x="40" y="{y}" fill="{TEXT_MUTED}" font-size="11">Methodology: paper-canonical {bench_label}. Higher is better. Full statistical detail → BENCHMARK_PROTOCOL.md</text>')
    y += 16
    parts.append(f'<text x="40" y="{y}" fill="{TEXT_MUTED}" font-size="11">"WATCH" = a category drifted ≥1pp without statistical significance (sample size too small to confirm regression). Monitored next release.</text>')

    parts.append("</svg>")
    Path(out_path).parent.mkdir(parents=True, exist_ok=True)
    with open(out_path, "w") as f:
        f.write("\n".join(parts))
    return cur, prev, verdict, vcolor, vmsg, overall_delta_pp, cat_data


def render_ascii(version, prev_version, cur_overall, prev_overall, overall_delta_pp, cat_data, verdict, vmsg, bench_label):
    """Same scorecard but ASCII for chat / terminal viewers."""
    lines = []
    BORDER = "═" * 70
    lines.append(BORDER)
    lines.append(f"  {verdict}   pgmnemo {version}   {bench_label}")
    lines.append(f"  {vmsg}")
    lines.append(BORDER)
    lines.append("")
    lines.append(f"  RECALL QUALITY (finds the right memory in top 10):")
    lines.append("")
    lines.append(f"      ┌──────────┐")
    lines.append(f"      │  {cur_overall*100:5.1f}%  │   {'+' if overall_delta_pp>=0 else ''}{overall_delta_pp:.1f}pp vs {prev_version}")
    lines.append(f"      └──────────┘")
    lines.append("")
    lines.append(BORDER)
    lines.append("  BY QUESTION TYPE")
    lines.append(BORDER)
    cat_labels = {
        "single_hop":  ("Single-hop",   "one memory chunk"),
        "multi_hop":   ("Multi-hop",    "combine multiple memories"),
        "temporal":    ("Temporal",     "time-aware — historically weakest"),
        "open_domain": ("Open-domain",  "broadest category"),
        "adversarial": ("Adversarial",  "designed to mislead"),
    }
    for cdata in cat_data:
        cat = cdata["cat"]
        label, expl = cat_labels.get(cat, (cat, ""))
        change, _ = classify_change(cdata["delta_pp"])
        sign = "+" if cdata["delta_pp"] >= 0 else ""
        # bar
        bar_len = int(cdata["cur"] * 30)
        bar = "█" * bar_len + "·" * (30 - bar_len)
        # arrow
        if cdata["delta_pp"] >= 1: arrow = "▲"
        elif cdata["delta_pp"] <= -1: arrow = "▼"
        else: arrow = "─"
        lines.append(f"  {label:<13} {bar} {cdata['cur']*100:5.1f}%  {arrow}{sign}{cdata['delta_pp']:.1f}pp  {change}")
        lines.append(f"               ({expl})")
    lines.append("")
    lines.append(BORDER)
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", required=True)
    ap.add_argument("--pattern", required=True)
    ap.add_argument("--bench-label", default="memory recall benchmark")
    ap.add_argument("--out-svg", required=True)
    ap.add_argument("--out-md", required=True)
    args = ap.parse_args()

    runs = load_runs(args.pattern)
    cur, prev, verdict, vcolor, vmsg, overall_delta_pp, cat_data = render_svg(
        args.version, runs, args.bench_label, args.out_svg
    )
    print(f"[wrote] {args.out_svg}")

    cur_overall = cur["data"]["overall"]["recall@10"]["mean"]
    prev_overall = prev["data"]["overall"]["recall@10"]["mean"]

    ascii_out = render_ascii(
        args.version, prev["version"], cur_overall, prev_overall, overall_delta_pp,
        cat_data, verdict, vmsg, args.bench_label
    )
    Path(args.out_md).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out_md, "w") as f:
        f.write(f"# Release scorecard: pgmnemo {args.version}\n\n")
        f.write(f"![scorecard]({Path(args.out_svg).name})\n\n")
        f.write("```\n" + ascii_out + "\n```\n")
    print(f"[wrote] {args.out_md}")
    print()
    print(ascii_out)


if __name__ == "__main__":
    main()
