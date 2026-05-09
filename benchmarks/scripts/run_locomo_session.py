#!/usr/bin/env python3
"""LoCoMo session-level granularity (vs turn-level in run_locomo_bench.py).

Hypothesis A: paper Maharana evaluates retrieval at SESSION level, not turn level.
Evidence "D1:3" likely = dialog 1 session 3 (one segment per session, not per turn).

Change vs original: extract_corpus() returns ONE row per (conv, session) with
text = concatenated turns of that session. ~270 segments instead of 5882.
"""
import argparse, hashlib, json, os, sys, time
from collections import Counter, defaultdict
from pathlib import Path

import psycopg2
import torch
from transformers import AutoTokenizer, AutoModel

ROOT = Path("/Users/gaidabura/pgmnemo/benchmarks")
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"

CATEGORY_NAMES = {1: "single_hop", 2: "multi_hop", 3: "temporal", 4: "open_domain", 5: "adversarial"}


def pad_to_1024(vec):
    if len(vec) >= 1024:
        return vec[:1024]
    return vec + [0.0] * (1024 - len(vec))


def vec_to_pgvector(vec):
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"


class DragonEmbedder:
    def __init__(self):
        print(f"[dragon] loading on {DEVICE}", flush=True)
        self.tok_ctx = AutoTokenizer.from_pretrained("facebook/dragon-plus-context-encoder")
        self.mod_ctx = AutoModel.from_pretrained("facebook/dragon-plus-context-encoder").to(DEVICE).eval()
        self.tok_qry = AutoTokenizer.from_pretrained("facebook/dragon-plus-query-encoder")
        self.mod_qry = AutoModel.from_pretrained("facebook/dragon-plus-query-encoder").to(DEVICE).eval()

    def _enc(self, model, tok, texts, batch_size=8):
        out = []
        with torch.no_grad():
            for i in range(0, len(texts), batch_size):
                batch = texts[i:i+batch_size]
                enc = tok(batch, padding=True, truncation=True, max_length=512, return_tensors="pt").to(DEVICE)
                emb = model(**enc).last_hidden_state[:, 0, :]
                out.extend(emb.cpu().tolist())
        return out

    def encode_context(self, texts):
        return self._enc(self.mod_ctx, self.tok_ctx, texts)

    def encode_query(self, texts):
        return self._enc(self.mod_qry, self.tok_qry, texts)


def extract_session_corpus(locomo):
    """One segment per (conversation, session) — concatenate all turns within session."""
    corpus = []
    for conv in locomo:
        sample_id = conv["sample_id"]
        c = conv["conversation"]
        for k in c:
            if not k.startswith("session_") or k.endswith("_date_time"):
                continue
            dialog_idx = int(k.split("_")[1])
            session = c[k]
            date_time = c.get(f"{k}_date_time", "")
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
                        "dia_id": f"D{dialog_idx}",  # session-level id matches evidence "D1:3" → "D1"-prefix
                        "text": "\n".join(lines),
                        "datetime": date_time,
                    })
    return corpus


def main():
    locomo = json.load(open(ROOT / "data/locomo/locomo10.json"))
    print(f"[locomo-session] loaded {len(locomo)} convs", flush=True)
    corpus = extract_session_corpus(locomo)
    print(f"[locomo-session] {len(corpus)} session-level segments", flush=True)

    questions = []
    for conv in locomo:
        for q in conv["qa"]:
            qd = dict(q)
            qd["_conv_id"] = conv["sample_id"]
            questions.append(qd)
    print(f"[locomo-session] {len(questions)} questions", flush=True)

    embedder = DragonEmbedder()
    t = time.time()
    corpus_embs = embedder.encode_context([c["text"] for c in corpus])
    print(f"[corpus] embed done in {time.time()-t:.1f}s", flush=True)
    t = time.time()
    qry_embs = embedder.encode_query([q["question"] for q in questions])
    print(f"[queries] embed done in {time.time()-t:.1f}s", flush=True)

    conn = psycopg2.connect(host="localhost", port="15432", dbname="bench", user="bench", password="bench")
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE role='bench_locomo_session'")
    cur.execute("SELECT pgmnemo.version()")
    pgmnemo_ver = cur.fetchone()[0]

    print(f"[db] inserting {len(corpus)} session segments...", flush=True)
    t = time.time()
    for seg, emb in zip(corpus, corpus_embs):
        padded = pad_to_1024(emb)
        cur.execute(
            """INSERT INTO pgmnemo.agent_lesson
               (role, project_id, topic, lesson_text, importance, embedding,
                commit_sha, source_run_id, metadata, verified_at)
               VALUES ('bench_locomo_session', 1, %s, %s, 3, %s::vector, 'bench_v0.2.1', %s, %s::jsonb, NOW())""",
            (f"{seg['conv_id']}/D{seg['dialog']}", seg["text"][:32000],
             vec_to_pgvector(padded), f"{seg['conv_id']}_D{seg['dialog']}",
             json.dumps({"dia_id": seg["dia_id"], "datetime": seg["datetime"]})),
        )
    print(f"[db] insert done in {time.time()-t:.1f}s", flush=True)

    K_VALUES = [1, 5, 10, 25, 50]
    K_MAX = max(K_VALUES)
    raw = []
    per_cat_recall = {k: defaultdict(list) for k in K_VALUES}
    per_cat_mrr = defaultdict(list)
    overall_recall = {k: [] for k in K_VALUES}
    overall_mrr = []

    for qi, (q, qemb) in enumerate(zip(questions, qry_embs)):
        cat = q.get("category", 0)
        evidence = q.get("evidence", [])
        # Evidence like "D1:3" → session "D1"
        evidence_sessions = set()
        for e in evidence:
            if ":" in e:
                evidence_sessions.add(e.split(":")[0])
            else:
                evidence_sessions.add(e)
        if not evidence_sessions:
            continue
        padded_q = pad_to_1024(qemb)
        cur.execute(
            """SELECT lesson_id, metadata->>'dia_id' AS dia_id
               FROM pgmnemo.recall_lessons(%s::vector, %s, 'bench_locomo_session', 1, %s)
               ORDER BY score DESC LIMIT %s""",
            (vec_to_pgvector(padded_q), K_MAX, q["question"], K_MAX),
        )
        retrieved = [r[1] for r in cur.fetchall()]
        first_hit = None
        for r, sid in enumerate(retrieved, start=1):
            if sid in evidence_sessions and first_hit is None:
                first_hit = r
        mrr = 1.0 / first_hit if first_hit else 0.0
        for K in K_VALUES:
            top_k = set(retrieved[:K])
            hits = len(top_k & evidence_sessions)
            recall = hits / len(evidence_sessions) if evidence_sessions else 0.0
            overall_recall[K].append(recall)
            per_cat_recall[K][cat].append(recall)
        overall_mrr.append(mrr)
        per_cat_mrr[cat].append(mrr)
        raw.append({"qi": qi, "conv_id": q["_conv_id"], "category": cat,
                    "question": q["question"], "evidence": list(evidence_sessions),
                    "retrieved_top10": retrieved[:10], "first_hit_rank": first_hit, "mrr": mrr})
        if qi % 200 == 0:
            print(f"[recall] {qi}/{len(questions)}", flush=True)

    cur.close(); conn.close()

    def _agg(vs):
        if not vs:
            return {"n": 0, "mean": None}
        n = len(vs); m = sum(vs)/n
        if n > 1:
            v = sum((x-m)**2 for x in vs)/(n-1)
            ci = 1.96*(v/n)**0.5
        else:
            ci = 0.0
        return {"n": n, "mean": round(m,4), "ci95_lo": round(max(0,m-ci),4), "ci95_hi": round(min(1,m+ci),4)}

    metrics = {
        "version": "v0.2.1", "date": time.strftime("%Y-%m-%d"),
        "dry_run": False, "mode": "real",
        "granularity": "session-level (was turn-level in v0.2.1_20260509)",
        "dataset": "snap-research/locomo (locomo10.json)",
        "dataset_sha256": hashlib.sha256(open(ROOT / "data/locomo/locomo10.json","rb").read()).hexdigest(),
        "embedder": "facebook/dragon-plus (paper canonical)",
        "embedder_dim_native": 768, "embedder_dim_stored": 1024,
        "padding": "zero-pad 768->1024",
        "pgmnemo_version": pgmnemo_ver,
        "n_corpus_segments": len(corpus),
        "n_questions": sum(len(per_cat_mrr[c]) for c in per_cat_mrr),
        "by_category": {
            CATEGORY_NAMES.get(c, str(c)): {"n": len(per_cat_mrr[c]),
                **{f"recall@{K}": _agg(per_cat_recall[K][c]) for K in K_VALUES},
                "mrr": _agg(per_cat_mrr[c])}
            for c in sorted(per_cat_mrr)
        },
        "overall": {**{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
                    "mrr": _agg(overall_mrr)},
        "device": DEVICE,
    }
    out = ROOT / f"locomo/results/v0.2.1_session_{time.strftime('%Y%m%d')}"
    out.mkdir(parents=True, exist_ok=True)
    json.dump(metrics, open(out / "metrics.json","w"), indent=2)
    with open(out / "raw_retrievals.jsonl","w") as f:
        for r in raw: f.write(json.dumps(r)+"\n")
    print(f"\n[done] wrote {out}/", flush=True)
    print(f"[done] overall recall@10: {metrics['overall']['recall@10']}", flush=True)
    print(f"[done] overall MRR: {metrics['overall']['mrr']}", flush=True)


if __name__ == "__main__":
    main()
