#!/usr/bin/env python3
"""LoCoMo session-level hybrid benchmark — pure-Python simulation (no DB, no GPU).

Simulates pgmnemo.recall_hybrid() scoring formula using:
  - BM25 (k1=1.5, b=0.75, matching run_nollm.py convention)
  - TF-IDF cosine similarity (proxy for dense retrieval)
  - Weighted linear fusion: 0.4*tfidf_cosine + 0.4*bm25_norm

Baseline: v0.2.1_session_20260509 (vector-only, recall@10=0.795, MRR=0.548)
Dataset:  snap-research/locomo locomo10.json (session-level granularity)

HYBRID_DECISION_2026-05-10: evidence run for WG option A vs B decision.
"""
import collections, json, math, re, time
from pathlib import Path

BM25_K1, BM25_B = 1.5, 0.75
K_VALUES = [1, 5, 10, 25, 50]
VEC_W, BM25_W = 0.4, 0.4

CATEGORY_NAMES = {1: "single_hop", 2: "multi_hop", 3: "temporal", 4: "open_domain", 5: "adversarial"}

ROOT = Path(__file__).parent.parent


def tokenize(text):
    return re.findall(r"[a-z0-9]+", str(text).lower())


def extract_session_corpus(locomo):
    corpus = []
    for conv in locomo:
        sample_id = conv["sample_id"]
        c = conv["conversation"]
        for k in sorted(c.keys()):
            if not k.startswith("session_") or k.endswith("_date_time"):
                continue
            dialog_idx = int(k.split("_")[1])
            session = c[k]
            if isinstance(session, list):
                lines = []
                for turn in session:
                    if isinstance(turn, dict):
                        speaker = turn.get("speaker", "")
                        text = turn.get("clean_text", turn.get("text", ""))
                        if text and text.strip():
                            lines.append(f"{speaker}: {text.strip()}")
                if lines:
                    corpus.append({
                        "conv_id": sample_id,
                        "dialog": dialog_idx,
                        "dia_id": f"D{dialog_idx}",
                        "text": "\n".join(lines),
                    })
    return corpus


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
    data_path = ROOT / "data/locomo/locomo10.json"
    locomo = json.loads(data_path.read_bytes())
    print(f"[locomo-hybrid-sim] loaded {len(locomo)} conversations", flush=True)

    corpus = extract_session_corpus(locomo)
    print(f"[locomo-hybrid-sim] {len(corpus)} session-level segments", flush=True)

    questions = []
    for conv in locomo:
        for q in conv["qa"]:
            qd = dict(q)
            qd["_conv_id"] = conv["sample_id"]
            questions.append(qd)
    print(f"[locomo-hybrid-sim] {len(questions)} questions", flush=True)

    per_cat_recall = {k: collections.defaultdict(list) for k in K_VALUES}
    per_cat_mrr = collections.defaultdict(list)
    overall_recall = {k: [] for k in K_VALUES}
    overall_mrr = []
    raw_retrievals = []

    # Group corpus by conv_id for per-conversation BM25/TF-IDF
    # (LoCoMo retrieval is within-conversation)
    conv_corpus = collections.defaultdict(list)
    for i, seg in enumerate(corpus):
        conv_corpus[seg["conv_id"]].append((i, seg))

    t0 = time.time()
    skipped = 0
    for qi, q in enumerate(questions):
        cat = q.get("category", 0)
        evidence_raw = q.get("evidence", [])
        evidence_sessions = set()
        for e in evidence_raw:
            if ":" in e:
                evidence_sessions.add(e.split(":")[0])
            else:
                evidence_sessions.add(e)
        if not evidence_sessions:
            skipped += 1
            continue

        conv_id = q["_conv_id"]
        segs = conv_corpus.get(conv_id, [])
        if not segs:
            skipped += 1
            continue

        texts = [s["text"] for _, s in segs]
        dtoks = [tokenize(t) for t in texts]
        qtoks = tokenize(q["question"])

        bm25 = BM25(dtoks)
        bm25_scores = [bm25.score(qtoks, di) for di in range(len(texts))]
        max_bm25 = max(bm25_scores) if any(s > 0 for s in bm25_scores) else 1.0
        bm25_norm = [s / max_bm25 for s in bm25_scores]

        vec_scores = tfidf_cosine(qtoks, dtoks)
        fusion = [VEC_W * v + BM25_W * b for v, b in zip(vec_scores, bm25_norm)]

        K_MAX = max(K_VALUES)
        ranked = sorted(range(len(fusion)), key=lambda i: fusion[i], reverse=True)
        ranked_segs = [segs[i][1] for i in ranked[:K_MAX]]
        retrieved_dia_ids = [s["dia_id"] for s in ranked_segs]

        first_hit = next(
            (r for r, did in enumerate(retrieved_dia_ids, 1) if did in evidence_sessions),
            None,
        )
        mrr = 1.0 / first_hit if first_hit else 0.0

        for K in K_VALUES:
            top_k = set(retrieved_dia_ids[:K])
            hits = len(top_k & evidence_sessions)
            recall = hits / len(evidence_sessions)
            overall_recall[K].append(recall)
            per_cat_recall[K][cat].append(recall)
        overall_mrr.append(mrr)
        per_cat_mrr[cat].append(mrr)

        raw_retrievals.append({
            "qi": qi, "conv_id": conv_id, "category": cat,
            "question": q["question"], "evidence": list(evidence_sessions),
            "retrieved_top10": retrieved_dia_ids[:10],
            "first_hit_rank": first_hit, "mrr": mrr,
        })

        if (qi + 1) % 200 == 0:
            n_done = len(overall_mrr)
            print(f"[sim] {qi+1}/{len(questions)} R@10-so-far={sum(overall_recall[10])/max(1,len(overall_recall[10])):.4f}", flush=True)

    elapsed = time.time() - t0
    n_evaluated = len(overall_mrr)
    print(f"[sim] done: {n_evaluated} evaluated, {skipped} skipped, {elapsed:.1f}s", flush=True)

    metrics = {
        "version": "v0.2.2-hybrid-locomo-sim",
        "date": time.strftime("%Y-%m-%d"),
        "mode": "simulation",
        "simulation": True,
        "simulation_note": (
            f"Pure-Python proxy: {VEC_W}*tfidf_cosine + {BM25_W}*bm25_norm_by_max. "
            "TF-IDF cosine is lower-bound proxy for dense retrieval. "
            "Retrieval is within-conversation (matching paper Maharana 2024 setup)."
        ),
        "granularity": "session-level",
        "dataset": "snap-research/locomo (locomo10.json)",
        "vec_weight": VEC_W,
        "bm25_weight": BM25_W,
        "n_conversations": len(locomo),
        "n_corpus_segments": len(corpus),
        "n_questions": len(questions),
        "n_evaluated": n_evaluated,
        "n_skipped": skipped,
        "by_category": {
            CATEGORY_NAMES.get(c, str(c)): {
                "n": len(per_cat_mrr[c]),
                **{f"recall@{K}": _agg(per_cat_recall[K][c]) for K in K_VALUES},
                "mrr": _agg(per_cat_mrr[c]),
            }
            for c in sorted(per_cat_mrr.keys())
        },
        "overall": {
            **{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
            "mrr": _agg(overall_mrr),
        },
        "baselines": {
            "vector_only_recall10": 0.7951,
            "vector_only_mrr": 0.548,
            "source_vector": "benchmarks/locomo/results/v0.2.1_session_20260509/metrics.json",
        },
        "wall_clock_sec": round(elapsed, 1),
    }

    label = f"v0.2.1_hybrid_locomo_sim_{time.strftime('%Y%m%d')}"
    out_dir = ROOT / "locomo" / "results" / label
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "metrics.json").write_text(json.dumps(metrics, indent=2))
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    r10 = metrics["overall"]["recall@10"]
    mrr_r = metrics["overall"]["mrr"]
    vec_r10 = metrics["baselines"]["vector_only_recall10"]
    vec_mrr = metrics["baselines"]["vector_only_mrr"]
    print(f"\n[result] recall@10={r10['mean']:.4f} [CI {r10['ci95_lo']:.4f},{r10['ci95_hi']:.4f}]")
    print(f"[result] MRR={mrr_r['mean']:.4f} [CI {mrr_r['ci95_lo']:.4f},{mrr_r['ci95_hi']:.4f}]")
    print(f"[result] Δrecall@10 vs vector-only: {r10['mean']-vec_r10:+.4f}")
    print(f"[result] ΔMRR vs vector-only: {mrr_r['mean']-vec_mrr:+.4f}")
    print(f"\n[per-category recall@10]")
    for cname, cdata in metrics["by_category"].items():
        r10c = cdata["recall@10"]
        print(f"  {cname}: {r10c['mean']:.4f} (n={r10c['n']})")
    print(f"\n[written] {out_dir}/")


if __name__ == "__main__":
    main()
