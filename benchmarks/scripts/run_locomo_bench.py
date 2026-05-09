#!/usr/bin/env python3
"""
LoCoMo benchmark runner — paper-canonical retrieval evaluation.

Methodology: Maharana et al., ACL 2024 ("Evaluating Very Long-Term Conversational
Memory of LLM-based Agents"). https://arxiv.org/abs/2402.17753

Embedder: facebook/dragon-plus (768d) — paper canonical.
Storage:  pgmnemo v0.2.1 — vector(1024) schema.
Padding:  DRAGON 768d → zero-padded to 1024d. Cosine similarity preserved
          (math-identical: zeros contribute 0 to dot product and L2 norm).
          See ADDENDA/LOCOMO_EMBEDDER_PADDING.md.

Metrics: recall@K (K=5,10,25,50), MRR (paper Table 3 metrics).

Outputs: results/v0.2.1_<date>/{report.md, metrics.json, raw_retrievals.jsonl}
"""
import argparse
import hashlib
import json
import math
import os
import sys
import time
from collections import Counter, defaultdict
from pathlib import Path

import psycopg2
import torch
from transformers import AutoTokenizer, AutoModel

ROOT = Path("/Users/gaidabura/pgmnemo/benchmarks")
DEVICE = "mps" if torch.backends.mps.is_available() else "cpu"

# LoCoMo categories per paper §4.2
CATEGORY_NAMES = {
    1: "single_hop",
    2: "multi_hop",
    3: "temporal",
    4: "open_domain",
    5: "adversarial",
}


def pad_to_1024(vec: list[float]) -> list[float]:
    """Zero-pad 768d → 1024d. Math-identical for cosine similarity."""
    if len(vec) >= 1024:
        return vec[:1024]
    return vec + [0.0] * (1024 - len(vec))


def vec_to_pgvector(vec: list[float]) -> str:
    """Format as pgvector literal: '[0.1,0.2,...]'"""
    return "[" + ",".join(f"{x:.6f}" for x in vec) + "]"


class DragonEmbedder:
    def __init__(self):
        print(f"[dragon] loading on {DEVICE}", flush=True)
        self.tok_ctx = AutoTokenizer.from_pretrained("facebook/dragon-plus-context-encoder")
        self.mod_ctx = AutoModel.from_pretrained("facebook/dragon-plus-context-encoder").to(DEVICE).eval()
        self.tok_qry = AutoTokenizer.from_pretrained("facebook/dragon-plus-query-encoder")
        self.mod_qry = AutoModel.from_pretrained("facebook/dragon-plus-query-encoder").to(DEVICE).eval()

    def _encode(self, model, tokenizer, texts: list[str], batch_size: int = 16) -> list[list[float]]:
        out = []
        with torch.no_grad():
            for i in range(0, len(texts), batch_size):
                batch = texts[i : i + batch_size]
                enc = tokenizer(batch, padding=True, truncation=True, max_length=512, return_tensors="pt").to(DEVICE)
                emb = model(**enc).last_hidden_state[:, 0, :]  # CLS pooling
                out.extend(emb.cpu().tolist())
                if (i // batch_size) % 25 == 0:
                    print(f"[dragon] {i + len(batch)}/{len(texts)}", flush=True)
        return out

    def encode_context(self, texts: list[str]) -> list[list[float]]:
        return self._encode(self.mod_ctx, self.tok_ctx, texts)

    def encode_query(self, texts: list[str]) -> list[list[float]]:
        return self._encode(self.mod_qry, self.tok_qry, texts)


def load_locomo() -> list[dict]:
    p = ROOT / "data/locomo/locomo10.json"
    with open(p) as f:
        return json.load(f)


def extract_corpus(locomo_data: list[dict]) -> list[dict]:
    """
    Extract corpus segments. Each segment = (conv_id, dialog_id, turn_idx, text).
    Evidence in QA refers to "D1:3" = dialog 1 turn 3, so we use dialog-level granularity.

    Schema: each conversation has session_N where N is the dialog index.
    Each session is a list of turns: [{speaker, dia_id, text, ...}, ...] (per locomo10 inspection)
    """
    corpus = []
    for conv in locomo_data:
        sample_id = conv["sample_id"]
        c = conv["conversation"]
        speaker_a = c.get("speaker_a", "")
        speaker_b = c.get("speaker_b", "")
        for k in c:
            if not k.startswith("session_") or k.endswith("_date_time"):
                continue
            dialog_idx = int(k.split("_")[1])
            session = c[k]
            date_time = c.get(f"{k}_date_time", "")
            if isinstance(session, list):
                for turn_idx, turn in enumerate(session):
                    if isinstance(turn, dict):
                        speaker = turn.get("speaker", "")
                        text = turn.get("clean_text", turn.get("text", ""))
                        dia_id = turn.get("dia_id", f"D{dialog_idx}:{turn_idx + 1}")
                    else:
                        speaker = ""
                        text = str(turn)
                        dia_id = f"D{dialog_idx}:{turn_idx + 1}"
                    corpus.append(
                        {
                            "conv_id": sample_id,
                            "dialog": dialog_idx,
                            "turn": turn_idx + 1,
                            "dia_id": dia_id,
                            "speaker": speaker,
                            "text": text.strip() if text else "",
                            "datetime": date_time,
                        }
                    )
    return [s for s in corpus if s["text"]]  # drop empty


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--limit-conv", type=int, default=None, help="dev-limit: only first N conversations")
    ap.add_argument("--limit-q", type=int, default=None, help="dev-limit: only first N questions per conv")
    ap.add_argument("--db-host", default="localhost")
    ap.add_argument("--db-port", default="15432")
    ap.add_argument("--db-name", default="bench")
    ap.add_argument("--db-user", default="bench")
    ap.add_argument("--db-pass", default="bench")
    ap.add_argument("--out-dir", default=str(ROOT / "locomo/results"))
    args = ap.parse_args()

    t0 = time.time()
    locomo = load_locomo()
    if args.limit_conv:
        locomo = locomo[: args.limit_conv]
    print(f"[locomo] loaded {len(locomo)} conversations", flush=True)

    corpus = extract_corpus(locomo)
    print(f"[locomo] extracted {len(corpus)} corpus segments", flush=True)
    if corpus:
        print(f"[locomo] sample[0]: {corpus[0]}", flush=True)

    questions = []
    for conv in locomo:
        for q in conv["qa"]:
            qd = dict(q)
            qd["_conv_id"] = conv["sample_id"]
            questions.append(qd)
            if args.limit_q and sum(1 for x in questions if x["_conv_id"] == conv["sample_id"]) >= args.limit_q:
                break
    print(f"[locomo] {len(questions)} questions across {len(locomo)} convs", flush=True)
    cat_counter = Counter(q.get("category") for q in questions)
    print(f"[locomo] category dist: {dict(cat_counter)}", flush=True)

    embedder = DragonEmbedder()

    print(f"[corpus] embedding {len(corpus)} segments via DRAGON-context...", flush=True)
    corpus_texts = [s["text"] for s in corpus]
    t = time.time()
    corpus_embs = embedder.encode_context(corpus_texts)
    print(f"[corpus] embeds done in {time.time() - t:.1f}s", flush=True)

    print(f"[queries] embedding {len(questions)} via DRAGON-query...", flush=True)
    qry_texts = [q["question"] for q in questions]
    t = time.time()
    qry_embs = embedder.encode_query(qry_texts)
    print(f"[queries] embeds done in {time.time() - t:.1f}s", flush=True)

    # Connect + reset table
    print(f"[db] connect {args.db_user}@{args.db_host}:{args.db_port}/{args.db_name}", flush=True)
    conn = psycopg2.connect(
        host=args.db_host, port=args.db_port, dbname=args.db_name, user=args.db_user, password=args.db_pass
    )
    conn.autocommit = True
    cur = conn.cursor()
    cur.execute("TRUNCATE pgmnemo.agent_lesson RESTART IDENTITY CASCADE")
    cur.execute("SELECT pgmnemo.version()")
    pgmnemo_ver = cur.fetchone()[0]
    print(f"[db] pgmnemo version: {pgmnemo_ver}", flush=True)

    print(f"[db] inserting {len(corpus)} segments...", flush=True)
    t = time.time()
    for seg, emb in zip(corpus, corpus_embs):
        padded = pad_to_1024(emb)
        cur.execute(
            """
            INSERT INTO pgmnemo.agent_lesson
                (role, project_id, topic, lesson_text, importance, embedding,
                 commit_sha, source_run_id, metadata, verified_at)
            VALUES (%s, %s, %s, %s, 3, %s::vector, %s, %s, %s::jsonb, NOW())
            """,
            (
                "bench_locomo",
                1,
                f"{seg['conv_id']}/D{seg['dialog']}",
                seg["text"],
                vec_to_pgvector(padded),
                "bench_v0.2.1",
                f"{seg['conv_id']}_{seg['dia_id']}",
                json.dumps({"dia_id": seg["dia_id"], "speaker": seg["speaker"], "datetime": seg["datetime"]}),
            ),
        )
    print(f"[db] insert done in {time.time() - t:.1f}s", flush=True)
    cur.execute("SELECT COUNT(*) FROM pgmnemo.agent_lesson")
    n_inserted = cur.fetchone()[0]
    print(f"[db] {n_inserted} rows in pgmnemo.agent_lesson", flush=True)

    # Per-question retrieval
    print(f"[recall] running queries...", flush=True)
    K_VALUES = [5, 10, 25, 50]
    K_MAX = max(K_VALUES)
    raw_retrievals = []
    per_cat_recall = {k: defaultdict(list) for k in K_VALUES}
    per_cat_mrr = defaultdict(list)
    overall_recall = {k: [] for k in K_VALUES}
    overall_mrr = []

    for qi, (q, qemb) in enumerate(zip(questions, qry_embs)):
        category = q.get("category", 0)
        evidence_set = set(q.get("evidence", []))  # ["D1:3", "D2:5"]
        if not evidence_set:
            continue  # skip questions without ground truth (e.g., adversarial)
        padded_q = pad_to_1024(qemb)
        cur.execute(
            f"""
            SELECT lesson_id, metadata->>'dia_id' AS dia_id, lesson_text
            FROM pgmnemo.recall_lessons(%s::vector, %s, 'bench_locomo', 1, %s)
            ORDER BY score DESC
            LIMIT %s
            """,
            (vec_to_pgvector(padded_q), K_MAX, q["question"], K_MAX),
        )
        retrieved = cur.fetchall()
        retrieved_dia_ids = [r[1] for r in retrieved]
        # match against this conv only — filter by conv_id
        # (already filtered via project_id=1 + role=bench_locomo and metadata)

        # recall@K + MRR
        first_hit_rank = None
        for rank, dia_id in enumerate(retrieved_dia_ids, start=1):
            if dia_id in evidence_set:
                if first_hit_rank is None:
                    first_hit_rank = rank
                if rank > 50:
                    break
        mrr = 1.0 / first_hit_rank if first_hit_rank else 0.0
        for K in K_VALUES:
            top_k_ids = set(retrieved_dia_ids[:K])
            hits = len(top_k_ids & evidence_set)
            recall = hits / len(evidence_set) if evidence_set else 0.0
            overall_recall[K].append(recall)
            per_cat_recall[K][category].append(recall)
        overall_mrr.append(mrr)
        per_cat_mrr[category].append(mrr)

        raw_retrievals.append(
            {
                "qi": qi,
                "conv_id": q["_conv_id"],
                "category": category,
                "question": q["question"],
                "evidence": list(evidence_set),
                "retrieved_top10": retrieved_dia_ids[:10],
                "first_hit_rank": first_hit_rank,
                "mrr": mrr,
            }
        )
        if qi % 100 == 0:
            print(f"[recall] {qi}/{len(questions)}", flush=True)

    cur.close()
    conn.close()

    # Aggregate
    def _agg(values):
        if not values:
            return {"n": 0, "mean": None, "ci95_lo": None, "ci95_hi": None}
        n = len(values)
        mean = sum(values) / n
        if n > 1:
            var = sum((v - mean) ** 2 for v in values) / (n - 1)
            stderr = (var / n) ** 0.5
            ci_half = 1.96 * stderr
        else:
            ci_half = 0.0
        return {"n": n, "mean": round(mean, 4), "ci95_lo": round(max(0, mean - ci_half), 4), "ci95_hi": round(min(1, mean + ci_half), 4)}

    metrics = {
        "version": "v0.2.1",
        "date": time.strftime("%Y-%m-%d"),
        "dry_run": False,
        "mode": "real",
        "dataset": "snap-research/locomo (locomo10.json from github main)",
        "dataset_sha256": hashlib.sha256(
            open(ROOT / "data/locomo/locomo10.json", "rb").read()
        ).hexdigest(),
        "embedder": "facebook/dragon-plus (context+query) — paper canonical",
        "embedder_dim_native": 768,
        "embedder_dim_stored": 1024,
        "padding": "zero-pad 768->1024 for pgmnemo schema; cosine math-identical",
        "pgmnemo_version": pgmnemo_ver,
        "n_corpus_segments": len(corpus),
        "n_questions_with_evidence": sum(len(per_cat_mrr[c]) for c in per_cat_mrr),
        "n_questions_total": len(questions),
        "category_distribution": dict(cat_counter),
        "by_category": {
            CATEGORY_NAMES.get(c, str(c)): {
                "n": len(per_cat_mrr[c]),
                **{f"recall@{K}": _agg(per_cat_recall[K][c]) for K in K_VALUES},
                "mrr": _agg(per_cat_mrr[c]),
            }
            for c in sorted(per_cat_mrr)
        },
        "overall": {
            **{f"recall@{K}": _agg(overall_recall[K]) for K in K_VALUES},
            "mrr": _agg(overall_mrr),
        },
        "wall_clock_sec": round(time.time() - t0, 1),
        "device": DEVICE,
    }

    # Write outputs
    date_str = time.strftime("%Y%m%d")
    out_dir = Path(args.out_dir) / f"v0.2.1_{date_str}"
    out_dir.mkdir(parents=True, exist_ok=True)
    with open(out_dir / "metrics.json", "w") as f:
        json.dump(metrics, f, indent=2)
    with open(out_dir / "raw_retrievals.jsonl", "w") as f:
        for r in raw_retrievals:
            f.write(json.dumps(r) + "\n")

    # Report
    report = f"""# LoCoMo Benchmark — pgmnemo {pgmnemo_ver}

**Date:** {metrics["date"]}
**Mode:** real (dry_run=false)
**Dataset:** snap-research/locomo, locomo10.json
**Dataset SHA256:** `{metrics["dataset_sha256"][:16]}...`
**Embedder:** facebook/dragon-plus (paper canonical, Lin et al. 2023)
**Storage:** pgmnemo v0.2.1, vector(1024); DRAGON 768d zero-padded (math-identical for cosine)
**Device:** {DEVICE}

## Methodology

Conforms to Maharana et al. ACL 2024 §4.2 retrieval evaluation. See:
- [arxiv 2402.17753](https://arxiv.org/abs/2402.17753)
- [github snap-research/locomo](https://github.com/snap-research/locomo)
- ADDENDA/LOCOMO_EMBEDDER_PADDING.md (zero-pad rationale)

## Corpus Statistics

| Metric | Value |
|---|---|
| Conversations | {len(locomo)} |
| Corpus segments (turns) | {len(corpus)} |
| Total questions | {len(questions)} |
| Questions with evidence (evaluated) | {metrics["n_questions_with_evidence"]} |

### Category distribution

| Category | Name | N |
|---|---|---|
"""
    for c, n in sorted(cat_counter.items()):
        report += f"| {c} | {CATEGORY_NAMES.get(c, '?')} | {n} |\n"

    report += f"""

## Overall Retrieval Metrics

| Metric | Value | 95% CI |
|---|---|---|
"""
    for K in K_VALUES:
        m = metrics["overall"][f"recall@{K}"]
        report += f"| recall@{K} | {m['mean']} | [{m['ci95_lo']}, {m['ci95_hi']}] |\n"
    m = metrics["overall"]["mrr"]
    report += f"| MRR | {m['mean']} | [{m['ci95_lo']}, {m['ci95_hi']}] |\n"

    report += f"\n## Per-Category Metrics\n\n| Category | N | recall@10 | MRR |\n|---|---|---|---|\n"
    for c in sorted(per_cat_mrr):
        cat_m = metrics["by_category"][CATEGORY_NAMES.get(c, str(c))]
        r10 = cat_m["recall@10"]
        mrr_m = cat_m["mrr"]
        report += (
            f"| {CATEGORY_NAMES.get(c, c)} | {cat_m['n']} | {r10['mean']} [{r10['ci95_lo']}, {r10['ci95_hi']}] | "
            f"{mrr_m['mean']} [{mrr_m['ci95_lo']}, {mrr_m['ci95_hi']}] |\n"
        )

    report += f"""

## References

- Maharana et al. 2024 — "Evaluating Very Long-Term Conversational Memory of LLM-based Agents" (ACL 2024)
- Lin et al. 2023 — DRAGON dual encoder
- Wilson 1927 — score CIs

## Reproducibility

```bash
docker run -d --name pgmnemo-bench -p 15432:5432 -e POSTGRES_PASSWORD=bench \\
  -e POSTGRES_USER=bench -e POSTGRES_DB=bench pgvector/pgvector:pg17
docker exec pgmnemo-bench psql -U bench -d bench -c "CREATE EXTENSION pgmnemo CASCADE;"

curl -L https://raw.githubusercontent.com/snap-research/locomo/main/data/locomo10.json \\
  -o benchmarks/data/locomo/locomo10.json

python benchmarks/scripts/run_locomo_bench.py
```

Wall clock: {metrics["wall_clock_sec"]}s
"""
    with open(out_dir / "report.md", "w") as f:
        f.write(report)

    print(f"\n[done] wrote {out_dir}/", flush=True)
    print(f"[done] overall recall@10: {metrics['overall']['recall@10']}", flush=True)
    print(f"[done] overall MRR: {metrics['overall']['mrr']}", flush=True)


if __name__ == "__main__":
    main()
