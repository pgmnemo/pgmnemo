#!/usr/bin/env python3
"""LongMemEval pgmnemo vector benchmark — full sessions, CPU mode, no truncation.

Hypothesis C (2026-05-09 strategy review):
  Does removing the 500-char per-session truncation lift recall?

Differences from run_longmemeval_pgmnemo.py (v0.2.1_pgmnemo_20260509 baseline):
  1. DEVICE forced to "cpu" — eliminates MPS OOM that forced the truncation
  2. Session text passed to embedder truncated to 8000 chars (bge-m3 max ctx ~8192 tokens,
     well above the paper-imposed limit; in practice sessions average ~2300 chars so
     essentially no truncation for the vast majority of segments)
  3. Loads longmemeval_s_cleaned.json explicitly (same dataset as baseline run)
  4. Output versioned as v0.2.1_full_<date>

Methodology: Wu et al., ICLR 2025 (https://arxiv.org/abs/2410.10813)
Mode: retrieval-only.

DEVIATION from paper-canonical Stella V5 1.5B (incompat with transformers 5.8 —
Qwen2Config.rope_theta AttributeError). Substituted BAAI/bge-m3 (1024d, MTEB-strong,
matches Agency production embedder).

Companion to benchmarks/longmemeval/run_nollm.py (pure BM25 baseline).
"""
import argparse, hashlib, json, math, os, sys, time
from collections import Counter, defaultdict
from pathlib import Path

import psycopg2
import torch
from sentence_transformers import SentenceTransformer

ROOT = Path(os.environ.get("LONGMEMEVAL_BENCH_ROOT", Path(__file__).parent.parent))

# CPU forced — eliminates MPS OOM that required 500-char truncation in baseline run
DEVICE = "cpu"

# Paper-allowed max; bge-m3 context window is ~8192 tokens.
# For s_cleaned sessions averaging ~2300 chars, this is effectively no truncation
# for the vast majority of segments.
TRUNCATE_CHARS = 8000


def vec_to_pgvector(vec):
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"


def load_s_cleaned(data_dir: Path):
    p = data_dir / "longmemeval_s_cleaned.json"
    if not p.exists():
        raise FileNotFoundError(f"Dataset not found: {p}\nSet LONGMEMEVAL_BENCH_ROOT or pass --data-dir")
    return json.load(open(p))


def extract_items(data):
    items = []
    for entry in data:
        haystack_sessions = entry.get("haystack_sessions", [])
        haystack_session_ids = entry.get("haystack_session_ids", [])
        answer_session_ids = entry.get("answer_session_ids", [])
        corpus = []
        for sid, session in zip(haystack_session_ids, haystack_sessions):
            if isinstance(session, list):
                txt = "\n".join(
                    f"{t.get('role','')}: {t.get('content','')}" if isinstance(t, dict) else str(t)
                    for t in session
                )
            else:
                txt = str(session)
            corpus.append({"sid": sid, "text": txt})
        items.append({
            "qid": entry.get("question_id"),
            "qtype": entry.get("question_type"),
            "question": entry.get("question"),
            "corpus": corpus,
            "ground_truth": set(answer_session_ids),
        })
    return items


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit", type=int, default=None)
    ap.add_argument("--data-dir", default=None,
                    help="Directory containing longmemeval_s_cleaned.json")
    ap.add_argument("--out-dir", default=None,
                    help="Output directory (default: <bench_root>/longmemeval/results)")
    ap.add_argument("--db-dsn", default=os.environ.get("PGMNEMO_DSN",
                    "host=localhost port=15432 dbname=bench user=bench password=bench"))
    args = ap.parse_args()

    data_dir = Path(args.data_dir) if args.data_dir else ROOT / "data/longmemeval"
    out_base = Path(args.out_dir) if args.out_dir else ROOT / "longmemeval/results"

    t0 = time.time()
    raw = load_s_cleaned(data_dir)
    sha256 = hashlib.sha256(open(data_dir / "longmemeval_s_cleaned.json", "rb").read()).hexdigest()
    items = extract_items(raw)
    if args.limit:
        items = items[: args.limit]
    print(f"[lme-pgm-full] {len(items)} items, qtypes: {Counter(i['qtype'] for i in items)}", flush=True)

    print(f"[bge-m3] loading on {DEVICE} (CPU mode — no MPS OOM risk)", flush=True)
    model = SentenceTransformer("BAAI/bge-m3", device=DEVICE)

    print(f"[lme-pgm-full] flattening corpus (truncate={TRUNCATE_CHARS} chars)...", flush=True)
    all_segs = []  # (item_idx, seg_idx, sid, text)
    queries = []   # (item_idx, question)
    for ii, item in enumerate(items):
        if not item["ground_truth"] or not item["corpus"]:
            continue
        queries.append((ii, item["question"]))
        for si, seg in enumerate(item["corpus"]):
            all_segs.append((ii, si, seg["sid"], seg["text"][:TRUNCATE_CHARS]))
    print(f"[lme-pgm-full] flat: {len(all_segs)} segments, {len(queries)} queries", flush=True)

    print(f"[bge-m3] embedding {len(all_segs)} segs in batch_size=16 (CPU)...", flush=True)
    t = time.time()
    seg_embs = model.encode([s[3] for s in all_segs], batch_size=16, show_progress_bar=True)
    print(f"[bge-m3] segs done in {time.time()-t:.1f}s", flush=True)

    print(f"[bge-m3] embedding {len(queries)} queries...", flush=True)
    t = time.time()
    qry_embs = model.encode([q[1] for q in queries], batch_size=16, show_progress_bar=True)
    print(f"[bge-m3] queries done in {time.time()-t:.1f}s", flush=True)

    item_corpus = defaultdict(list)
    for (ii, si, sid, _txt), emb in zip(all_segs, seg_embs):
        item_corpus[ii].append((si, sid, emb.tolist()))
    item_qry = {ii: emb.tolist() for (ii, _q), emb in zip(queries, qry_embs)}

    conn = psycopg2.connect(args.db_dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("TRUNCATE pgmnemo.agent_lesson RESTART IDENTITY CASCADE")
    cur.execute("SELECT pgmnemo.version()")
    pgmnemo_ver = cur.fetchone()[0]
    print(f"[db] pgmnemo {pgmnemo_ver}", flush=True)

    K_VALUES = [1, 5, 10, 20]
    K_MAX = max(K_VALUES)

    raw_retrievals = []
    per_qtype_recall = {k: defaultdict(list) for k in K_VALUES}
    per_qtype_mrr = defaultdict(list)
    overall_recall = {k: [] for k in K_VALUES}
    overall_mrr = []

    print(f"[lme-pgm-full] running per-item retrieval through pgmnemo...", flush=True)
    t = time.time()
    for ii, item in enumerate(items):
        if ii not in item_corpus:
            continue
        cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_lme_pgm_full'")
        for (si, sid, emb), seg in zip(item_corpus[ii], item["corpus"]):
            cur.execute(
                """INSERT INTO pgmnemo.agent_lesson
                   (role, project_id, topic, lesson_text, importance, embedding,
                    commit_sha, source_run_id, metadata, verified_at)
                   VALUES ('bench_lme_pgm_full', 1, %s, %s, 3, %s::vector, 'bench_v0.2.1_full', %s, %s::jsonb, NOW())""",
                (f"lme/{item['qtype']}", seg["text"][:TRUNCATE_CHARS], vec_to_pgvector(emb),
                 f"{item['qid']}_{seg['sid']}", json.dumps({"sid": seg["sid"]})),
            )

        cur.execute(
            """SELECT lesson_id, metadata->>'sid' AS sid
               FROM pgmnemo.recall_lessons(%s::vector, %s, 'bench_lme_pgm_full', 1, %s)
               ORDER BY score DESC LIMIT %s""",
            (vec_to_pgvector(item_qry[ii]), K_MAX, item["question"], K_MAX),
        )
        retrieved_sids = [r[1] for r in cur.fetchall()]
        gt = item["ground_truth"]
        first_hit = None
        for r, sid in enumerate(retrieved_sids, start=1):
            if sid in gt and first_hit is None:
                first_hit = r
        mrr = 1.0 / first_hit if first_hit else 0.0
        for K in K_VALUES:
            top_k = set(retrieved_sids[:K])
            hits = len(top_k & gt)
            recall = hits / len(gt) if gt else 0.0
            overall_recall[K].append(recall)
            per_qtype_recall[K][item["qtype"]].append(recall)
        overall_mrr.append(mrr)
        per_qtype_mrr[item["qtype"]].append(mrr)
        raw_retrievals.append({
            "qi": ii, "qid": item["qid"], "qtype": item["qtype"],
            "question": item["question"], "ground_truth": list(gt),
            "retrieved_top10": retrieved_sids[:10], "first_hit_rank": first_hit, "mrr": mrr,
        })
        if ii % 50 == 0:
            elapsed = time.time() - t
            rate = (ii + 1) / (elapsed + 0.001) * 60
            print(f"[lme-pgm-full] {ii}/{len(items)} ({rate:.0f} items/min)", flush=True)

    cur.close()
    conn.close()

    def _agg(values):
        if not values:
            return {"n": 0, "mean": None, "ci95_lo": None, "ci95_hi": None}
        n = len(values); mean = sum(values) / n
        if n > 1:
            var = sum((v - mean) ** 2 for v in values) / (n - 1)
            ci_half = 1.96 * (var / n) ** 0.5
        else:
            ci_half = 0.0
        return {"n": n, "mean": round(mean, 4),
                "ci95_lo": round(max(0, mean - ci_half), 4),
                "ci95_hi": round(min(1, mean + ci_half), 4)}

    run_date = time.strftime("%Y-%m-%d")
    run_date_compact = time.strftime("%Y%m%d")
    metrics = {
        "version": "v0.2.1_full", "date": run_date,
        "dry_run": False, "mode": "real",
        "retrieval_method": "pgmnemo.recall_lessons() vector + 5-component scoring",
        "dataset": "xiaowu0162/longmemeval-cleaned (longmemeval_s_cleaned.json — full haystacks, ~47.7 sessions/item)",
        "dataset_sha256": sha256,
        "embedder": "BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical",
        "deviation_rationale": "Stella V5 modeling_qwen.py incompat with transformers 5.8; bge-m3 same dim, MTEB-strong, matches Agency production",
        "truncation_chars": TRUNCATE_CHARS,
        "truncation_note": f"Sessions truncated to {TRUNCATE_CHARS} chars before embedding (bge-m3 ~8192 token ctx); baseline v0.2.1_pgmnemo used 500-char truncation",
        "device": DEVICE,
        "device_note": "CPU forced to avoid MPS OOM that required 500-char truncation in baseline",
        "pgmnemo_version": pgmnemo_ver,
        "n_items": len(items),
        "n_evaluated": sum(len(per_qtype_mrr[t]) for t in per_qtype_mrr),
        "qtype_distribution": dict(Counter(i["qtype"] for i in items)),
        "by_qtype": {
            qt: {"n": len(per_qtype_mrr[qt]),
                 **{f"recall@{K}": _agg(per_qtype_recall[K][qt]) for K in K_VALUES},
                 "mrr": _agg(per_qtype_mrr[qt])}
            for qt in sorted(per_qtype_mrr)
        },
        "overall": {**{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
                    "mrr": _agg(overall_mrr)},
        "wall_clock_sec": round(time.time() - t0, 1),
        "baseline_comparison": {
            "baseline_run": "v0.2.1_pgmnemo_20260509",
            "baseline_truncation_chars": 500,
            "baseline_device": "mps",
            "baseline_recall10": 0.9326,
            "baseline_mrr": 0.8554,
        },
    }

    out_dir = out_base / f"v0.2.1_full_{run_date_compact}"
    out_dir.mkdir(parents=True, exist_ok=True)

    # Compute delta vs baseline for report
    full_r10 = metrics["overall"]["recall@10"]["mean"]
    full_mrr = metrics["overall"]["mrr"]["mean"]
    delta_r10 = round(full_r10 - 0.9326, 4) if full_r10 is not None else None
    delta_mrr = round(full_mrr - 0.8554, 4) if full_mrr is not None else None

    json.dump(metrics, open(out_dir / "metrics.json", "w"), indent=2)
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    delta_r10_str = f"{delta_r10:+.4f}" if delta_r10 is not None else "N/A"
    delta_mrr_str = f"{delta_mrr:+.4f}" if delta_mrr is not None else "N/A"

    report = f"""# LongMemEval Benchmark (pgmnemo vector, full sessions) — pgmnemo {pgmnemo_ver}

**Date:** {run_date}
**Mode:** real (dry_run=false), retrieval-only
**Retrieval:** pgmnemo.recall_lessons() vector + 5-component scoring
**Embedder:** BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical
**Deviation rationale:** {metrics["deviation_rationale"]}
**Dataset:** xiaowu0162/longmemeval-cleaned, longmemeval_s_cleaned.json (full haystacks ~47.7 sessions/item)
**Storage:** pgmnemo v0.2.1, vector(1024) NATIVE
**Device:** {DEVICE} (CPU — forced to eliminate MPS OOM)
**Truncation:** {TRUNCATE_CHARS} chars (bge-m3 ~8192 token ctx; effectively no truncation for avg session)

**Hypothesis C (2026-05-09):** Remove 500-char truncation from baseline → does recall improve?

Companion: `run_nollm.py` provides pure-Python BM25 baseline on same dataset.

## Methodology

Conforms to Wu et al. ICLR 2025 retrieval-only evaluation. See:
- [arxiv 2410.10813](https://arxiv.org/abs/2410.10813)
- [github xiaowu0162/LongMemEval](https://github.com/xiaowu0162/LongMemEval)

## Statistics

| Metric | Value |
|---|---|
| Total items | {len(items)} |
| Items evaluated | {metrics["n_evaluated"]} |

## Overall Retrieval Metrics

| Metric | Value | 95% CI |
|---|---|---|
"""
    for K in K_VALUES:
        m = metrics["overall"][f"recall@{K}"]
        report += f"| recall@{K} | {m['mean']} | [{m['ci95_lo']}, {m['ci95_hi']}] |\n"
    m = metrics["overall"]["mrr"]
    report += f"| MRR | {m['mean']} | [{m['ci95_lo']}, {m['ci95_hi']}] |\n"

    report += f"""
## Delta vs Baseline (v0.2.1_pgmnemo_20260509, 500-char truncation, MPS)

| Metric | Baseline (500-char trunc) | Full (8000-char) | Delta |
|---|---|---|---|
| recall@10 | 0.9326 | {full_r10} | {delta_r10_str} |
| MRR | 0.8554 | {full_mrr} | {delta_mrr_str} |

"""

    report += f"\n## Per-Q-type recall@10 + MRR\n\n| Q-type | N | recall@10 | MRR |\n|---|---|---|---|\n"
    for qt in sorted(per_qtype_mrr):
        cm = metrics["by_qtype"][qt]; r10 = cm["recall@10"]; mrr_m = cm["mrr"]
        report += f"| {qt} | {cm['n']} | {r10['mean']} [{r10['ci95_lo']}, {r10['ci95_hi']}] | {mrr_m['mean']} [{mrr_m['ci95_lo']}, {mrr_m['ci95_hi']}] |\n"

    report += f"\n\nWall clock: {metrics['wall_clock_sec']}s\n"
    open(out_dir / "report.md", "w").write(report)
    print(f"\n[done] wrote {out_dir}/", flush=True)
    print(f"[done] overall recall@10: {metrics['overall']['recall@10']}", flush=True)
    print(f"[done] overall MRR: {metrics['overall']['mrr']}", flush=True)
    if delta_r10 is not None:
        print(f"[done] delta recall@10 vs baseline: {delta_r10_str}", flush=True)
    if delta_mrr is not None:
        print(f"[done] delta MRR vs baseline: {delta_mrr_str}", flush=True)


if __name__ == "__main__":
    main()
