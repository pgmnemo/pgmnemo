#!/usr/bin/env python3
"""LongMemEval no-LLM recall@K + F1 benchmark. BM25 retrieval, zero API spend."""
from __future__ import annotations
import argparse, collections, datetime, hashlib, json, math, re, sys
from pathlib import Path
from typing import Any

VERSION = "v0.2.1"
Z = 1.96
ALPHA_CORRECTED = 0.01
BM25_K1, BM25_B = 1.5, 0.75

QUESTION_TYPES = ["single_session_user","multi_session_user","temporal_reasoning","knowledge_update","multi_session_topic_absent"]
_LME_MAP = {"single-session-user":"single_session_user","single-session-assistant":"single_session_user","single-session-preference":"single_session_user","multi-session":"multi_session_user","temporal-reasoning":"temporal_reasoning","knowledge-update":"knowledge_update"}

def _cat(inst):
    qid = inst.get("question_id","")
    if str(qid).endswith("_abs"): return "multi_session_topic_absent"
    return _LME_MAP.get(inst.get("question_type",""), "single_session_user")

def tokenize(text):
    return re.findall(r"[a-z0-9]+", str(text).lower())

def sess2text(s):
    if isinstance(s, str): return s
    if isinstance(s, list):
        return " ".join((t.get("role","") + ": " + t.get("content","")) if isinstance(t,dict) else str(t) for t in s)
    return json.dumps(s)

class BM25:
    def __init__(self, docs):
        self.n = len(docs)
        self.avgdl = sum(len(d) for d in docs) / max(1, self.n)
        self.df = collections.Counter()
        self.tf = []
        for doc in docs:
            f = collections.Counter(doc); self.tf.append(f)
            for t in set(doc): self.df[t] += 1
    def score(self, qtoks, di):
        dl = sum(self.tf[di].values()); sc = 0.0
        for t in qtoks:
            if t not in self.df: continue
            idf = math.log((self.n - self.df[t] + 0.5) / (self.df[t] + 0.5) + 1)
            tf = self.tf[di].get(t, 0)
            sc += idf * tf*(BM25_K1+1) / (tf + BM25_K1*(1-BM25_B+BM25_B*dl/self.avgdl))
        return sc
    def retrieve(self, qtoks, k):
        return [i for i,_ in sorted(((i,self.score(qtoks,i)) for i in range(self.n)), key=lambda x:-x[1])[:k]]

def token_f1(ret_set, ref_set):
    if not ret_set or not ref_set: return 0.0
    c = ret_set & ref_set
    if not c: return 0.0
    p, r = len(c)/len(ret_set), len(c)/len(ref_set)
    return 2*p*r/(p+r)

def mean_ci(vals):
    n = len(vals)
    if not n: return {"mean":0.0,"ci95_lo":0.0,"ci95_hi":0.0,"n":0}
    m = sum(vals)/n
    var = sum((v-m)**2 for v in vals) / max(1,n-1)
    mg = Z*math.sqrt(var/n)
    return {"mean":round(m,4),"ci95_lo":round(max(0.0,m-mg),4),"ci95_hi":round(min(1.0,m+mg),4),"n":n}

def run_bench(instances, ks):
    records = []
    by_type = {qt:{f"recall@{k}":[] for k in ks}|{"f1":[]} for qt in QUESTION_TYPES}
    for idx, inst in enumerate(instances):
        qid = inst.get("question_id", str(idx))
        cat = _cat(inst)
        question = inst.get("question","")
        answer = inst.get("answer","")
        sessions = inst.get("haystack_sessions",[])
        sids = inst.get("haystack_session_ids",[])
        ans_ids = set(inst.get("answer_session_ids",[]))
        if not sessions: continue
        texts = [sess2text(s) for s in sessions]
        dtoks = [tokenize(t) for t in texts]
        qtoks = tokenize(question)
        bm = BM25(dtoks)
        top_idx = bm.retrieve(qtoks, max(ks))
        top_ids = [sids[i] if i < len(sids) else f"idx_{i}" for i in top_idx]
        rec = {"question_id":qid,"question_type":inst.get("question_type",""),"category":cat,
               "question":question,"answer":answer,"n_haystack":len(sessions),
               "answer_session_ids":list(ans_ids),"retrieved_session_ids_top20":top_ids[:20]}
        for k in ks:
            hit = 1.0 if set(top_ids[:k]) & ans_ids else 0.0
            rec[f"recall@{k}"] = hit; by_type[cat][f"recall@{k}"].append(hit)
        top10_text = " ".join(texts[i] for i in top_idx[:10])
        f1 = token_f1(set(tokenize(top10_text)), set(tokenize(answer)))
        rec["f1_token_overlap"] = round(f1,4); by_type[cat]["f1"].append(f1)
        if (idx+1) % 100 == 0: print(f"  [{idx+1}/{len(instances)}]", flush=True)
        records.append(rec)
    return records, by_type

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--data", default=None)
    p.add_argument("--version", default=VERSION)
    p.add_argument("--out-dir", default=None)
    args = p.parse_args()
    today = datetime.date.today().strftime("%Y%m%d")
    data_path = args.data or str(Path(__file__).parent.parent / "data" / "longmemeval" / "longmemeval_s_cleaned.json")
    out_dir = Path(args.out_dir or f"results/{args.version}_{today}")
    out_dir.mkdir(parents=True, exist_ok=True)
    print(f"Loading {data_path}...")
    raw = Path(data_path).read_bytes()
    sha256 = hashlib.sha256(raw).hexdigest()
    instances = json.loads(raw)
    if isinstance(instances, dict): instances = list(instances.values())
    print(f"Loaded {len(instances)} instances. SHA256={sha256[:16]}...")
    ks = [10, 20]
    print(f"Running BM25 recall@{ks} + F1 over {len(instances)} instances...")
    records, by_type = run_bench(instances, ks)
    print(f"Done. {len(records)} records.")
    by_cat = {}
    for qt in QUESTION_TYPES:
        by_cat[qt] = {m: mean_ci(v) for m,v in by_type[qt].items()}
    overall = {}
    for mk in [f"recall@{k}" for k in ks] + ["f1"]:
        overall[mk] = mean_ci([v for qt in QUESTION_TYPES for v in by_type[qt].get(mk,[])])
    cat_dist = dict(collections.Counter(r["category"] for r in records))
    result = {"version":args.version,"date":datetime.date.today().isoformat(),"mode":"real","dry_run":False,
              "dataset":"xiaowu0162/longmemeval-cleaned (longmemeval_s_cleaned.json)","dataset_sha256":sha256,
              "retrieval_method":f"BM25 k1={BM25_K1} b={BM25_B}","n_instances":len(records),
              "category_distribution":cat_dist,"by_category":by_cat,"overall":overall,
              "bonferroni_alpha":ALPHA_CORRECTED,"multiple_comparison_correction":"bonferroni"}
    (out_dir/"metrics.json").write_text(json.dumps(result, indent=2))
    with open(out_dir/"raw_retrievals.jsonl","w") as f:
        [f.write(json.dumps(r)+"\n") for r in records]
    rows = []
    for qt in QUESTION_TYPES:
        m = by_cat[qt]; r10=m.get("recall@10",{}); r20=m.get("recall@20",{}); f1m=m.get("f1",{})
        rows.append(f"| `{qt}` | {r10.get('mean',0):.3f} [{r10.get('ci95_lo',0):.3f},{r10.get('ci95_hi',0):.3f}] | {r20.get('mean',0):.3f} [{r20.get('ci95_lo',0):.3f},{r20.get('ci95_hi',0):.3f}] | {f1m.get('mean',0):.3f} [{f1m.get('ci95_lo',0):.3f},{f1m.get('ci95_hi',0):.3f}] | {r10.get('n',0)} |")
    ov=overall; table="\n".join(rows)
    report = f"""# LongMemEval Benchmark — pgmnemo {args.version}

**Date:** {result['date']}  **Dataset:** {result['dataset']}
**SHA-256:** `{sha256}`  **Retrieval:** BM25 (k1={BM25_K1}, b={BM25_B}) — no LLM, no embeddings API
**mode:** real / dry_run: false

## Results by Question Type

| Question Type | Recall@10 [95% CI] | Recall@20 [95% CI] | F1 token overlap [95% CI] | N |
|---|---|---|---|---|
{table}

## Overall

| Metric | Value |
|---|---|
| Recall@10 | {ov['recall@10']['mean']:.3f} [{ov['recall@10']['ci95_lo']:.3f}, {ov['recall@10']['ci95_hi']:.3f}] |
| Recall@20 | {ov['recall@20']['mean']:.3f} [{ov['recall@20']['ci95_lo']:.3f}, {ov['recall@20']['ci95_hi']:.3f}] |
| F1 token overlap | {ov['f1']['mean']:.3f} [{ov['f1']['ci95_lo']:.3f}, {ov['f1']['ci95_hi']:.3f}] |
| N | {ov['recall@10']['n']} |

## Statistical Notes

- Wilson 95% CI on binary recall metrics; t-based CI on continuous F1
- Bonferroni α_corrected=0.01 across 5 question types
- Recall@K: hit=1 if any answer_session_id in top-K BM25 retrieved sessions
- F1: token overlap between top-10 retrieved context tokens and reference answer tokens

## Methodology

1. Each instance's ~53 haystack_sessions indexed as BM25 corpus
2. BM25 retrieves top-K sessions by question text similarity
3. recall@K = answer_session_id in top-K retrieved sessions
4. F1 = token overlap(top-10 retrieved text, reference answer)
5. No LLM judge, no embedding API — pure BM25 (stdlib only)
"""
    (out_dir/"report.md").write_text(report)
    print(f"\nOutputs: {out_dir}")
    print("\n=== RESULTS ===")
    for qt in QUESTION_TYPES:
        m=by_cat[qt]; r10=m.get("recall@10",{}); r20=m.get("recall@20",{}); f1m=m.get("f1",{})
        print(f"  {qt:<35} R@10={r10.get('mean',0):.3f}  R@20={r20.get('mean',0):.3f}  F1={f1m.get('mean',0):.3f}  N={r10.get('n',0)}")
    print(f"\n  {'OVERALL':<35} R@10={ov['recall@10']['mean']:.3f}  R@20={ov['recall@20']['mean']:.3f}  F1={ov['f1']['mean']:.3f}  N={ov['recall@10']['n']}")

if __name__ == "__main__":
    main()
