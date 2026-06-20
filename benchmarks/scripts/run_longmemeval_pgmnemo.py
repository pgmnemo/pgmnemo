#!/usr/bin/env python3
"""LongMemEval pgmnemo vector benchmark — bge-m3 + pgmnemo.recall_lessons().

Methodology: Wu et al., ICLR 2025 (https://arxiv.org/abs/2410.10813)
Mode: retrieval-only.

DEVIATION from paper-canonical Stella V5 1.5B (incompat with transformers 5.8 —
Qwen2Config.rope_theta AttributeError). Substituted BAAI/bge-m3 (1024d, MTEB-strong,
matches production embedding setup).

Companion to benchmarks/longmemeval/run_nollm.py (pure BM25 baseline).
"""
import argparse, hashlib, json, math, os, sys, time
from collections import Counter, defaultdict
from pathlib import Path

import psycopg2
import torch
from sentence_transformers import SentenceTransformer

ROOT = Path(__file__).resolve().parents[1]  # benchmarks/ (was hardcoded home path)
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"


def vec_to_pgvector(vec):
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"


def load_oracle():
    p = ROOT / "data/longmemeval/longmemeval_oracle.json"
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
    ap.add_argument("--out-dir", default=str(ROOT / "longmemeval/results"))
    args = ap.parse_args()

    t0 = time.time()
    raw = load_oracle()
    items = extract_items(raw)
    if args.limit:
        items = items[: args.limit]
    print(f"[lme-pgm] {len(items)} items, qtypes: {Counter(i['qtype'] for i in items)}", flush=True)

    print(f"[bge-m3] loading on {DEVICE}", flush=True)
    model = SentenceTransformer("BAAI/bge-m3", device=DEVICE)

    print(f"[lme-pgm] flattening corpus...", flush=True)
    all_segs = []  # (item_idx, seg_idx, sid, text)
    queries = []  # (item_idx, question)
    for ii, item in enumerate(items):
        if not item["ground_truth"] or not item["corpus"]:
            continue
        queries.append((ii, item["question"]))
        for si, seg in enumerate(item["corpus"]):
            all_segs.append((ii, si, seg["sid"], seg["text"][:8000]))
    print(f"[lme-pgm] flat: {len(all_segs)} segments, {len(queries)} queries", flush=True)

    print(f"[bge-m3] embedding {len(all_segs)} segs in batch_size=32...", flush=True)
    t = time.time()
    seg_embs = model.encode([s[3] for s in all_segs], batch_size=32, show_progress_bar=False)
    print(f"[bge-m3] segs done in {time.time()-t:.1f}s", flush=True)

    print(f"[bge-m3] embedding {len(queries)} queries...", flush=True)
    t = time.time()
    qry_embs = model.encode([q[1] for q in queries], batch_size=32, show_progress_bar=False)
    print(f"[bge-m3] queries done in {time.time()-t:.1f}s", flush=True)

    item_corpus = defaultdict(list)
    for (ii, si, sid, _txt), emb in zip(all_segs, seg_embs):
        item_corpus[ii].append((si, sid, emb.tolist()))
    item_qry = {ii: emb.tolist() for (ii, _q), emb in zip(queries, qry_embs)}

    conn = psycopg2.connect(host="localhost", port="15432", dbname="bench", user="bench", password="bench")
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

    print(f"[lme-pgm] running per-item retrieval through pgmnemo...", flush=True)
    t = time.time()
    for ii, item in enumerate(items):
        if ii not in item_corpus:
            continue
        cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_lme_pgm'")
        for (si, sid, emb), seg in zip(item_corpus[ii], item["corpus"]):
            cur.execute(
                """INSERT INTO pgmnemo.agent_lesson
                   (role, project_id, topic, lesson_text, importance, embedding,
                    commit_sha, source_run_id, metadata, verified_at)
                   VALUES ('bench_lme_pgm', 1, %s, %s, 3, %s::vector, 'bench_v0.2.1', %s, %s::jsonb, NOW())""",
                (f"lme/{item['qtype']}", seg["text"][:8000], vec_to_pgvector(emb),
                 f"{item['qid']}_{seg['sid']}", json.dumps({"sid": seg["sid"]})),
            )

        cur.execute(
            """SELECT lesson_id, metadata->>'sid' AS sid
               FROM pgmnemo.recall_lessons(%s::vector, %s, 'bench_lme_pgm', 1, %s)
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
            print(f"[lme-pgm] {ii}/{len(items)} ({(ii)/(time.time()-t+0.001)*60:.0f} items/min)", flush=True)

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
        return {"n": n, "mean": round(mean, 4), "ci95_lo": round(max(0, mean - ci_half), 4), "ci95_hi": round(min(1, mean + ci_half), 4)}

    metrics = {
        "version": "v0.2.1", "date": time.strftime("%Y-%m-%d"),
        "dry_run": False, "mode": "real",
        "retrieval_method": "pgmnemo.recall_lessons() vector + 5-component scoring",
        "dataset": "xiaowu0162/longmemeval-cleaned (oracle split)",
        "dataset_sha256": hashlib.sha256(open(ROOT / "data/longmemeval/longmemeval_oracle.json", "rb").read()).hexdigest(),
        "embedder": "BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical",
        "deviation_rationale": "Stella V5 modeling_qwen.py incompat with transformers 5.8; bge-m3 same dim, MTEB-strong, matches production embedding setup",
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
        "device": DEVICE,
    }

    out_dir = Path(args.out_dir) / f"v0.2.1_pgmnemo_{time.strftime('%Y%m%d')}"
    out_dir.mkdir(parents=True, exist_ok=True)
    json.dump(metrics, open(out_dir / "metrics.json", "w"), indent=2)
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    report = f"""# LongMemEval Benchmark (pgmnemo vector) — pgmnemo {pgmnemo_ver}

**Date:** {metrics["date"]}
**Mode:** real (dry_run=false), retrieval-only
**Retrieval:** pgmnemo.recall_lessons() vector + 5-component scoring
**Embedder:** BAAI/bge-m3 (1024d) — DEVIATION from Stella V5 paper canonical
**Deviation rationale:** {metrics["deviation_rationale"]}
**Dataset:** xiaowu0162/longmemeval-cleaned, oracle split
**Storage:** pgmnemo v0.2.1, vector(1024) NATIVE
**Device:** {DEVICE}

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

    report += f"\n## Per-Q-type recall@10 + MRR\n\n| Q-type | N | recall@10 | MRR |\n|---|---|---|---|\n"
    for qt in sorted(per_qtype_mrr):
        cm = metrics["by_qtype"][qt]; r10 = cm["recall@10"]; mrr_m = cm["mrr"]
        report += f"| {qt} | {cm['n']} | {r10['mean']} [{r10['ci95_lo']}, {r10['ci95_hi']}] | {mrr_m['mean']} [{mrr_m['ci95_lo']}, {mrr_m['ci95_hi']}] |\n"

    report += f"\n\nWall clock: {metrics['wall_clock_sec']}s\n"
    open(out_dir / "report.md", "w").write(report)
    print(f"\n[done] wrote {out_dir}/", flush=True)
    print(f"[done] overall recall@10: {metrics['overall']['recall@10']}", flush=True)
    print(f"[done] overall MRR: {metrics['overall']['mrr']}", flush=True)


if __name__ == "__main__":
    main()
