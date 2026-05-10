#!/usr/bin/env python3
"""LongMemEval pgmnemo hybrid benchmark — bge-m3 + pgmnemo.recall_hybrid().

QUICK-B: Hypothesis B from 2026-05-09 strategy review.
Tests whether vector + BM25 weighted fusion (recall_hybrid) closes the gap
between pgmnemo vector-only (0.933 recall@10) and pure BM25 baseline (0.982).

Requires: pgmnemo >= 0.2.2 (recall_hybrid function).
Companion: run_longmemeval_pgmnemo.py (vector-only baseline, 0.933 recall@10)
           run_nollm.py (pure BM25 baseline, 0.982 recall@10)
"""
import argparse, hashlib, json, os, time
from collections import Counter, defaultdict
from pathlib import Path

import psycopg2
import torch
from sentence_transformers import SentenceTransformer

ROOT = Path(os.environ.get("LONGMEMEVAL_BENCH_ROOT", Path(__file__).parent.parent))
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"


def vec_to_pgvector(vec):
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"


def load_dataset(data_dir: Path):
    for candidate in ["longmemeval_s_cleaned.json", "longmemeval_oracle.json"]:
        p = data_dir / candidate
        if p.exists():
            return json.load(open(p)), candidate
    raise FileNotFoundError(f"No LongMemEval dataset found in {data_dir}")


def extract_items(data):
    items = []
    for entry in data:
        haystack_sessions    = entry.get("haystack_sessions", [])
        haystack_session_ids = entry.get("haystack_session_ids", [])
        answer_session_ids   = entry.get("answer_session_ids", [])
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
            "qid":          entry.get("question_id"),
            "qtype":        entry.get("question_type"),
            "question":     entry.get("question"),
            "corpus":       corpus,
            "ground_truth": set(answer_session_ids),
        })
    return items


def _agg(values):
    if not values:
        return {"n": 0, "mean": None, "ci95_lo": None, "ci95_hi": None}
    n = len(values)
    mean = sum(values) / n
    if n > 1:
        var = sum((v - mean) ** 2 for v in values) / (n - 1)
        ci_half = 1.96 * (var / n) ** 0.5
    else:
        ci_half = 0.0
    return {
        "n": n,
        "mean": round(mean, 4),
        "ci95_lo": round(max(0.0, mean - ci_half), 4),
        "ci95_hi": round(min(1.0, mean + ci_half), 4),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit",      type=int,   default=None)
    ap.add_argument("--out-dir",    default=str(ROOT / "longmemeval/results"))
    ap.add_argument("--data-dir",   default=str(ROOT / "data/longmemeval"))
    ap.add_argument("--vec-weight", type=float, default=0.4,  help="Vector cosine weight (default 0.4)")
    ap.add_argument("--bm25-weight",type=float, default=0.4,  help="BM25 weight (default 0.4)")
    ap.add_argument("--rrf-k",      type=int,   default=60,   help="RRF smoothing constant (default 60)")
    ap.add_argument("--dsn",        default="host=localhost port=15432 dbname=bench user=bench password=bench")
    args = ap.parse_args()

    t0 = time.time()
    data_dir = Path(args.data_dir)
    raw, dataset_file = load_dataset(data_dir)
    items = extract_items(raw)
    if args.limit:
        items = items[: args.limit]
    print(f"[hybrid] {len(items)} items, qtypes: {Counter(i['qtype'] for i in items)}", flush=True)

    print(f"[bge-m3] loading on {DEVICE}", flush=True)
    model = SentenceTransformer("BAAI/bge-m3", device=DEVICE)
    model.max_seq_length = 512

    print(f"[hybrid] flattening corpus...", flush=True)
    all_segs = []
    queries  = []
    for ii, item in enumerate(items):
        if not item["ground_truth"] or not item["corpus"]:
            continue
        queries.append((ii, item["question"]))
        for si, seg in enumerate(item["corpus"]):
            all_segs.append((ii, si, seg["sid"], seg["text"][:8000]))

    print(f"[bge-m3] embedding {len(all_segs)} segments (batch=8)...", flush=True)
    t = time.time()
    seg_embs = model.encode([s[3] for s in all_segs], batch_size=8, show_progress_bar=False)
    print(f"[bge-m3] segments done in {time.time()-t:.1f}s", flush=True)

    print(f"[bge-m3] embedding {len(queries)} queries...", flush=True)
    t = time.time()
    qry_embs = model.encode([q[1] for q in queries], batch_size=8, show_progress_bar=False)
    print(f"[bge-m3] queries done in {time.time()-t:.1f}s", flush=True)

    item_corpus = defaultdict(list)
    for (ii, si, sid, _txt), emb in zip(all_segs, seg_embs):
        item_corpus[ii].append((si, sid, emb.tolist()))
    item_qry = {ii: emb.tolist() for (ii, _q), emb in zip(queries, qry_embs)}

    conn = psycopg2.connect(args.dsn)
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("TRUNCATE pgmnemo.agent_lesson RESTART IDENTITY CASCADE")
    cur.execute("SELECT pgmnemo.version()")
    pgmnemo_ver = cur.fetchone()[0]
    print(f"[db] pgmnemo {pgmnemo_ver}", flush=True)

    # Verify recall_hybrid exists
    cur.execute("""
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'pgmnemo' AND p.proname = 'recall_hybrid'
    """)
    if not cur.fetchone():
        raise RuntimeError(
            "pgmnemo.recall_hybrid() not found — run migration "
            "pgmnemo--0.2.1--0.2.2-hybrid.sql first"
        )

    K_VALUES = [1, 5, 10, 20]
    K_MAX    = max(K_VALUES)

    raw_retrievals   = []
    per_qtype_recall = {k: defaultdict(list) for k in K_VALUES}
    per_qtype_mrr    = defaultdict(list)
    overall_recall   = {k: [] for k in K_VALUES}
    overall_mrr      = []

    print(f"[hybrid] running per-item retrieval through pgmnemo.recall_hybrid()...", flush=True)
    t = time.time()
    for ii, item in enumerate(items):
        if ii not in item_corpus:
            continue
        cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_lme_hybrid'")
        for (si, sid, emb), seg in zip(item_corpus[ii], item["corpus"]):
            cur.execute(
                """INSERT INTO pgmnemo.agent_lesson
                   (role, project_id, topic, lesson_text, importance, embedding,
                    commit_sha, source_run_id, metadata, verified_at)
                   VALUES ('bench_lme_hybrid', 1, %s, %s, 3, %s::vector,
                           'bench_v0.2.2', %s, %s::jsonb, NOW())""",
                (
                    f"lme/{item['qtype']}",
                    seg["text"][:8000],
                    vec_to_pgvector(emb),
                    f"{item['qid']}_{seg['sid']}",
                    json.dumps({"sid": seg["sid"]}),
                ),
            )

        cur.execute(
            """SELECT lesson_id, metadata->>'sid' AS sid
               FROM pgmnemo.recall_hybrid(
                   %s::vector, %s, %s, 'bench_lme_hybrid', 1, %s, %s, %s
               )
               ORDER BY score DESC LIMIT %s""",
            (
                vec_to_pgvector(item_qry[ii]),
                item["question"],
                K_MAX,
                args.vec_weight,
                args.bm25_weight,
                args.rrf_k,
                K_MAX,
            ),
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
            hits   = len(top_k & gt)
            recall = hits / len(gt) if gt else 0.0
            overall_recall[K].append(recall)
            per_qtype_recall[K][item["qtype"]].append(recall)
        overall_mrr.append(mrr)
        per_qtype_mrr[item["qtype"]].append(mrr)
        raw_retrievals.append({
            "qi": ii, "qid": item["qid"], "qtype": item["qtype"],
            "question": item["question"], "ground_truth": list(gt),
            "retrieved_top10": retrieved_sids[:10],
            "first_hit_rank": first_hit, "mrr": mrr,
        })
        if ii % 50 == 0:
            print(
                f"[hybrid] {ii}/{len(items)} "
                f"({ii / (time.time() - t + 0.001) * 60:.0f} items/min)",
                flush=True,
            )

    cur.close()
    conn.close()

    dataset_sha = hashlib.sha256(open(data_dir / dataset_file, "rb").read()).hexdigest()
    metrics = {
        "version":           "v0.2.2-hybrid",
        "date":              time.strftime("%Y-%m-%d"),
        "mode":              "real",
        "retrieval_method":  "pgmnemo.recall_hybrid() vector + BM25 fusion",
        "vec_weight":        args.vec_weight,
        "bm25_weight":       args.bm25_weight,
        "rrf_k":             args.rrf_k,
        "dataset":           f"xiaowu0162/longmemeval-cleaned ({dataset_file})",
        "dataset_sha256":    dataset_sha,
        "embedder":          "BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical",
        "deviation_rationale": (
            "Stella V5 modeling_qwen.py incompat with transformers 5.8; "
            "bge-m3 same dim, MTEB-strong, matches production embedding setup"
        ),
        "pgmnemo_version":   pgmnemo_ver,
        "n_items":           len(items),
        "n_evaluated":       sum(len(per_qtype_mrr[t]) for t in per_qtype_mrr),
        "qtype_distribution": dict(Counter(i["qtype"] for i in items)),
        "by_qtype": {
            qt: {
                "n": len(per_qtype_mrr[qt]),
                **{f"recall@{K}": _agg(per_qtype_recall[K][qt]) for K in K_VALUES},
                "mrr": _agg(per_qtype_mrr[qt]),
            }
            for qt in sorted(per_qtype_mrr)
        },
        "overall": {
            **{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
            "mrr": _agg(overall_mrr),
        },
        "baseline_vector_recall10": 0.9334,
        "baseline_bm25_recall10":   0.982,
        "wall_clock_sec": round(time.time() - t0, 1),
        "device": DEVICE,
    }

    label   = f"v0.2.1_hybrid_{time.strftime('%Y%m%d')}"
    out_dir = Path(args.out_dir) / label
    out_dir.mkdir(parents=True, exist_ok=True)

    json.dump(metrics, open(out_dir / "metrics.json", "w"), indent=2)
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    r10_overall = metrics["overall"]["recall@10"]
    delta_vs_vec  = round(r10_overall["mean"] - 0.9334, 4) if r10_overall["mean"] else None
    delta_vs_bm25 = round(r10_overall["mean"] - 0.982,  4) if r10_overall["mean"] else None

    report = f"""# LongMemEval Benchmark (pgmnemo hybrid) — pgmnemo {pgmnemo_ver}

**Date:** {metrics["date"]}
**Mode:** real (dry_run=false), retrieval-only
**Retrieval:** pgmnemo.recall_hybrid() vector + BM25 weighted fusion
**Embedder:** BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical
**Deviation rationale:** {metrics["deviation_rationale"]}
**Dataset:** {metrics["dataset"]}
**Storage:** pgmnemo v{pgmnemo_ver}
**Device:** {DEVICE}
**Weights:** vec={args.vec_weight}, bm25={args.bm25_weight}, rrf_k={args.rrf_k}

## Hypothesis

QUICK-B (2026-05-09): BM25 baseline (0.982 recall@10) outperforms vector-only (0.933).
Hybrid dense+sparse retrieval should close this gap per Maharana and Wu et al. papers.

## Baselines

| System | recall@10 |
|---|---|
| pgmnemo.recall_lessons() vector-only | 0.9334 |
| BM25 baseline (run_nollm.py) | 0.982 |

## Methodology

Conforms to Wu et al. ICLR 2025 retrieval-only evaluation.
New `recall_hybrid()` formula:
  score = {args.vec_weight}×cosine + {args.bm25_weight}×ts_rank_cd(lesson_tsv, q, 32)
         + 0.05×(importance/5) + 0.05×recency_90d
         + 0.05×prov_strength + graph_weight×graph_proximity

Union retrieval: candidates from vector OR BM25 match path.

## Overall Retrieval Metrics

| Metric | Value | 95% CI | Δ vs vector | Δ vs BM25 |
|---|---|---|---|---|
"""
    for K in K_VALUES:
        m = metrics["overall"][f"recall@{K}"]
        if m["mean"] is not None:
            report += f"| recall@{K} | {m['mean']} | [{m['ci95_lo']}, {m['ci95_hi']}] | {round(m['mean']-0.9334,4) if K==10 else '-'} | {round(m['mean']-0.982,4) if K==10 else '-'} |\n"
    m = metrics["overall"]["mrr"]
    report += f"| MRR | {m['mean']} | [{m['ci95_lo']}, {m['ci95_hi']}] | - | - |\n"

    report += f"\n## Per-Q-type recall@10 + MRR\n\n| Q-type | N | recall@10 | MRR |\n|---|---|---|---|\n"
    for qt in sorted(per_qtype_mrr):
        cm  = metrics["by_qtype"][qt]
        r10 = cm["recall@10"]
        mrr_m = cm["mrr"]
        report += f"| {qt} | {cm['n']} | {r10['mean']} [{r10['ci95_lo']}, {r10['ci95_hi']}] | {mrr_m['mean']} [{mrr_m['ci95_lo']}, {mrr_m['ci95_hi']}] |\n"

    gap_closed = ""
    if delta_vs_vec is not None and delta_vs_bm25 is not None:
        gap = 0.982 - 0.9334
        improvement = delta_vs_vec
        pct = round(improvement / gap * 100, 1) if gap > 0 else 0
        gap_closed = f"\n## Gap Analysis\n\nVector-BM25 gap: {round(gap,4)}\nHybrid improvement over vector: {delta_vs_vec} ({pct}% of gap closed)\nRemaining gap to BM25: {-delta_vs_bm25}\n"

    report += gap_closed
    report += f"\n\nWall clock: {metrics['wall_clock_sec']}s\n"
    open(out_dir / "report.md", "w").write(report)

    print(f"\n[done] wrote {out_dir}/", flush=True)
    print(f"[done] overall recall@10: {r10_overall}", flush=True)
    print(f"[done] overall MRR: {metrics['overall']['mrr']}", flush=True)
    if delta_vs_vec is not None:
        print(f"[done] Δ vs vector-only: {delta_vs_vec:+.4f}", flush=True)
        print(f"[done] Δ vs BM25 baseline: {delta_vs_bm25:+.4f}", flush=True)


if __name__ == "__main__":
    main()
