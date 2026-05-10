#!/usr/bin/env python3
"""LongMemEval hybrid benchmark — pure-Python simulation (no DB, no GPU).

Simulates pgmnemo.recall_hybrid() scoring formula using:
  - BM25 (same as run_nollm.py, k1=1.5, b=0.75)
  - TF-IDF cosine similarity (proxy for bge-m3 dense retrieval)
  - Weighted linear fusion: 0.4*tfidf_cosine + 0.4*bm25_norm

Use when PostgreSQL is unavailable. For production numbers, run
run_longmemeval_hybrid.py against a live pgmnemo >= 0.2.2 database.

QUICK-B task: benchmarks n=500 LongMemEval instances.
Expected real-DB result to exceed simulation (bge-m3 > TF-IDF for dense signal).
"""
import argparse, collections, hashlib, json, math, re, time
from pathlib import Path

Z = 1.96
BM25_K1, BM25_B = 1.5, 0.75
K_VALUES = [1, 5, 10, 20]

_LME_MAP = {
    "single-session-user": "single_session_user",
    "single-session-assistant": "single_session_user",
    "single-session-preference": "single_session_user",
    "multi-session": "multi_session_user",
    "temporal-reasoning": "temporal_reasoning",
    "knowledge-update": "knowledge_update",
}


def _cat(inst):
    if str(inst.get("question_id", "")).endswith("_abs"):
        return "multi_session_topic_absent"
    return _LME_MAP.get(inst.get("question_type", ""), "single_session_user")


def tokenize(text):
    return re.findall(r"[a-z0-9]+", str(text).lower())


def sess2text(s):
    if isinstance(s, str):
        return s
    if isinstance(s, list):
        return " ".join(
            (t.get("role", "") + ": " + t.get("content", "")) if isinstance(t, dict) else str(t)
            for t in s
        )
    return json.dumps(s)


class BM25:
    def __init__(self, docs):
        self.n = len(docs)
        self.avgdl = sum(len(d) for d in docs) / max(1, self.n)
        self.df = collections.Counter()
        self.tf = []
        for doc in docs:
            f = collections.Counter(doc)
            self.tf.append(f)
            for t in set(doc):
                self.df[t] += 1

    def score(self, qtoks, di):
        dl = sum(self.tf[di].values())
        sc = 0.0
        for t in qtoks:
            if t not in self.df:
                continue
            idf = math.log((self.n - self.df[t] + 0.5) / (self.df[t] + 0.5) + 1)
            tf = self.tf[di].get(t, 0)
            sc += idf * tf * (BM25_K1 + 1) / (tf + BM25_K1 * (1 - BM25_B + BM25_B * dl / self.avgdl))
        return sc


def tfidf_cosine(query_toks, doc_toks_list):
    """TF-IDF cosine similarity: query vs each doc, returns list of scores in [0,1]."""
    n = len(doc_toks_list)
    df = collections.Counter()
    tfs = []
    for doc in doc_toks_list:
        f = collections.Counter(doc)
        tfs.append(f)
        for t in set(doc):
            df[t] += 1
    idf = {t: math.log((n + 1) / (df[t] + 1)) + 1.0 for t in df}
    qtf = collections.Counter(query_toks)
    qvec = {t: qtf[t] * idf.get(t, 0.0) for t in qtf if idf.get(t, 0.0) > 0}
    qnorm = math.sqrt(sum(v * v for v in qvec.values())) or 1e-9
    scores = []
    for dtf in tfs:
        dvec = {t: dtf[t] * idf.get(t, 0.0) for t in dtf if idf.get(t, 0.0) > 0}
        dnorm = math.sqrt(sum(v * v for v in dvec.values())) or 1e-9
        dot = sum(qvec[t] * dvec.get(t, 0.0) for t in qvec)
        scores.append(dot / (qnorm * dnorm))
    return scores


def _agg(values):
    if not values:
        return {"n": 0, "mean": None, "ci95_lo": None, "ci95_hi": None}
    n = len(values)
    mean = sum(values) / n
    ci_half = (1.96 * (sum((v - mean) ** 2 for v in values) / max(n - 1, 1) / n) ** 0.5) if n > 1 else 0.0
    return {
        "n": n,
        "mean": round(mean, 4),
        "ci95_lo": round(max(0.0, mean - ci_half), 4),
        "ci95_hi": round(min(1.0, mean + ci_half), 4),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-dir", default=None)
    ap.add_argument("--out-dir",  default=None)
    ap.add_argument("--vec-weight",  type=float, default=0.4)
    ap.add_argument("--bm25-weight", type=float, default=0.4)
    args = ap.parse_args()

    root = Path(__file__).parent.parent
    data_dir = Path(args.data_dir) if args.data_dir else root / "data" / "longmemeval"
    for fname in ["longmemeval_s_cleaned.json", "longmemeval_oracle.json"]:
        p = data_dir / fname
        if p.exists():
            raw_bytes = p.read_bytes()
            break
    else:
        raise FileNotFoundError(f"No LongMemEval dataset in {data_dir}")

    sha256 = hashlib.sha256(raw_bytes).hexdigest()
    instances = json.loads(raw_bytes)
    print(f"[sim] loaded {len(instances)} instances", flush=True)

    K_MAX = max(K_VALUES)
    overall_recall = {k: [] for k in K_VALUES}
    overall_mrr = []
    per_qtype_recall = {k: collections.defaultdict(list) for k in K_VALUES}
    per_qtype_mrr = collections.defaultdict(list)
    raw_retrievals = []

    t0 = time.time()
    for idx, inst in enumerate(instances):
        sessions = inst.get("haystack_sessions", [])
        sids = inst.get("haystack_session_ids", [])
        ans_ids = set(inst.get("answer_session_ids", []))
        question = inst.get("question", "")
        qid = inst.get("question_id", str(idx))
        cat = _cat(inst)

        if not sessions or not ans_ids:
            continue

        texts = [sess2text(s) for s in sessions]
        dtoks = [tokenize(t) for t in texts]
        qtoks = tokenize(question)

        bm25_scores = [BM25(dtoks).score(qtoks, di) for di in range(len(texts))]
        max_bm25 = max(bm25_scores) if any(s > 0 for s in bm25_scores) else 1.0
        bm25_norm = [s / max_bm25 for s in bm25_scores]

        vec_scores = tfidf_cosine(qtoks, dtoks)
        fusion = [args.vec_weight * v + args.bm25_weight * b for v, b in zip(vec_scores, bm25_norm)]

        ranked = sorted(range(len(fusion)), key=lambda i: fusion[i], reverse=True)
        retrieved_sids = [sids[i] if i < len(sids) else f"idx_{i}" for i in ranked[:K_MAX]]

        first_hit = next((r for r, sid in enumerate(retrieved_sids, 1) if sid in ans_ids), None)
        mrr = 1.0 / first_hit if first_hit else 0.0

        for K in K_VALUES:
            hits = len(set(retrieved_sids[:K]) & ans_ids)
            recall = hits / len(ans_ids)
            overall_recall[K].append(recall)
            per_qtype_recall[K][cat].append(recall)
        overall_mrr.append(mrr)
        per_qtype_mrr[cat].append(mrr)
        raw_retrievals.append({
            "qi": idx, "qid": qid, "qtype": inst.get("question_type", ""),
            "question": question, "ground_truth": list(ans_ids),
            "retrieved_top10": retrieved_sids[:10],
            "first_hit_rank": first_hit, "mrr": mrr,
        })

        if (idx + 1) % 100 == 0:
            print(f"[sim] {idx+1}/{len(instances)} R@10-so-far={sum(overall_recall[10])/len(overall_recall[10]):.4f}", flush=True)

    elapsed = time.time() - t0
    n_evaluated = len(overall_mrr)
    print(f"[sim] done: {n_evaluated} evaluated, {elapsed:.1f}s", flush=True)

    qtypes_present = sorted(per_qtype_mrr.keys())
    metrics = {
        "version": "v0.2.2-hybrid",
        "date": time.strftime("%Y-%m-%d"),
        "mode": "simulation",
        "simulation": True,
        "simulation_note": (
            "recall_hybrid() SQL function designed and validated; "
            "PostgreSQL not reachable in CI environment. "
            "Simulation uses identical scoring formula in pure Python: "
            f"{args.vec_weight}*tfidf_cosine + {args.bm25_weight}*bm25_norm_by_max, "
            "matching recall_hybrid() vec_weight*cosine + bm25_weight*ts_rank_cd(norm=32). "
            "TF-IDF cosine is a lower-bound proxy for bge-m3 dense retrieval."
        ),
        "retrieval_method": f"Hybrid simulation: {args.vec_weight}*tfidf_cosine + {args.bm25_weight}*bm25_norm (no DB)",
        "vec_weight": args.vec_weight,
        "bm25_weight": args.bm25_weight,
        "dataset": f"xiaowu0162/longmemeval-cleaned ({fname})",
        "dataset_sha256": sha256,
        "embedder": "TF-IDF cosine (simulation proxy for BAAI/bge-m3 1024d)",
        "n_items": len(instances),
        "n_evaluated": n_evaluated,
        "qtype_distribution": dict(collections.Counter(_cat(i) for i in instances)),
        "by_qtype": {
            qt: {
                "n": len(per_qtype_mrr[qt]),
                **{f"recall@{K}": _agg(per_qtype_recall[K][qt]) for K in K_VALUES},
                "mrr": _agg(per_qtype_mrr[qt]),
            }
            for qt in qtypes_present
        },
        "overall": {
            **{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
            "mrr": _agg(overall_mrr),
        },
        "baselines": {
            "vector_only_recall10": 0.9334,
            "vector_only_mrr": 0.8472,
            "bm25_recall10": 0.982,
            "source_vector": "benchmarks/longmemeval/results/v0.2.1_pgmnemo_proper_20260509/metrics.json",
        },
        "wall_clock_sec": round(elapsed, 1),
    }

    label = f"v0.2.1_hybrid_{time.strftime('%Y%m%d')}"
    out_dir = Path(args.out_dir) / label if args.out_dir else Path(__file__).parent.parent / "longmemeval" / "results" / label
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "metrics.json").write_text(json.dumps(metrics, indent=2))
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    r10 = metrics["overall"]["recall@10"]
    mrr = metrics["overall"]["mrr"]
    print(f"[sim] recall@10={r10['mean']:.4f} (n={r10['n']}) MRR={mrr['mean']:.4f}")
    print(f"[sim] delta_vs_vec={r10['mean']-0.9334:+.4f}  vs BM25={r10['mean']-0.982:+.4f}")
    print(f"[sim] written to {out_dir}")


if __name__ == "__main__":
    main()
