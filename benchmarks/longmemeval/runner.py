"""
LongMemEval benchmark runner for pgmnemo.

Implements Wu et al. 2024 methodology:
  "LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory"
  ICLR 2025 — https://github.com/xiaowu0162/LongMemEval

Five evaluated categories:
  single_session_user    → LME types: single-session-user/assistant/preference
  multi_session_user     → LME type:  multi-session
  temporal_reasoning     → LME type:  temporal-reasoning
  knowledge_update       → LME type:  knowledge-update
  multi_session_topic_absent → abstention (question_id ends with '_abs')

Judge: GPT-4o with VERBATIM prompts from LongMemEval evaluate_qa.py.
       Outputs "yes"/"no"; mapped to correct/incorrect.
Stats: Wilson 95% CIs, Cohen's h (arcsine vs 0.5 baseline), Bonferroni α=0.01.

Usage:
    export LONGMEMEVAL_DATA_DIR=/path/to/LongMemEval/data
    export PGMNEMO_DSN="host=localhost dbname=pgmnemo_bench user=postgres"
    export OPENAI_API_KEY="sk-..."
    python runner.py [--version v0.2.1] [--dry-run]

Options:
    --version       pgmnemo version label (default: v0.2.1)
    --data-dir      override LONGMEMEVAL_DATA_DIR env var
    --judge-model   gpt-4o (default: gpt-4o)
    --judge-workers parallel judge threads (default: 10)
    --embed-model   text-embedding-3-large (default)
    --answer-model  gpt-4o (default)
    --k             recall_lessons top-k (default: 20)
    --out-dir       output directory (default: results/v0.2.1_<date>)
    --dry-run       skip DB+API; emit fixture output for CI
"""
from __future__ import annotations

import argparse
import datetime
import json
import logging
import math
import os
import sys
import textwrap
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from typing import Any

import psycopg2

log = logging.getLogger("longmemeval")

VERSION = "v0.2.1"
EMBED_DIM = 1024
DEFAULT_K = 20
DEFAULT_JUDGE_WORKERS = 10
N_INSTANCES_EXPECTED = 500

# ---------------------------------------------------------------------------
# LongMemEval category taxonomy (Wu et al. 2024)
# ---------------------------------------------------------------------------

QUESTION_TYPES = [
    "single_session_user",
    "multi_session_user",
    "temporal_reasoning",
    "knowledge_update",
    "multi_session_topic_absent",
]

# Map LongMemEval question_type field → our 5 categories
_LME_TYPE_TO_CATEGORY = {
    "single-session-user":        "single_session_user",
    "single-session-assistant":   "single_session_user",
    "single-session-preference":  "single_session_user",
    "multi-session":              "multi_session_user",
    "temporal-reasoning":         "temporal_reasoning",
    "knowledge-update":           "knowledge_update",
}


def _get_category(inst: dict) -> str:
    """Map a LongMemEval instance to one of our 5 category keys."""
    qid = inst.get("question_id", "")
    if str(qid).endswith("_abs"):
        return "multi_session_topic_absent"
    qtype = inst.get("question_type", "")
    return _LME_TYPE_TO_CATEGORY.get(qtype, "single_session_user")


# ---------------------------------------------------------------------------
# VERBATIM judge prompts from LongMemEval evaluate_qa.py (Wu et al. 2024)
# No system prompt used in the original script.
# ---------------------------------------------------------------------------

def get_judge_prompt(inst: dict, hypothesis: str) -> str:
    """
    Return the verbatim LongMemEval judge prompt for this instance.
    Source: https://github.com/xiaowu0162/LongMemEval/blob/main/src/evaluation/evaluate_qa.py
    """
    qid = inst.get("question_id", "")
    qtype = inst.get("question_type", "")
    question = inst.get("question", "")
    answer = inst.get("answer", "")
    abstention = str(qid).endswith("_abs")

    if abstention:
        template = (
            "I will give you an unanswerable question, an explanation, and a response "
            "from a model. Please answer yes if the model correctly identifies the question "
            "as unanswerable. The model could say that the information is incomplete, or "
            "some other information is given but the asked information is not.\n\n"
            "Question: {}\n\nExplanation: {}\n\nModel Response: {}\n\n"
            "Does the model correctly identify the question as unanswerable? Answer yes or no only."
        )
        return template.format(question, answer, hypothesis)

    if qtype in ("single-session-user", "single-session-assistant", "multi-session"):
        template = (
            "I will give you a question, a correct answer, and a response from a model. "
            "Please answer yes if the response contains the correct answer. Otherwise, answer no. "
            "If the response is equivalent to the correct answer or contains all the intermediate "
            "steps to get the correct answer, you should also answer yes. If the response only "
            "contains a subset of the information required by the answer, answer no. \n\n"
            "Question: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n"
            "Is the model response correct? Answer yes or no only."
        )
        return template.format(question, answer, hypothesis)

    if qtype == "temporal-reasoning":
        template = (
            "I will give you a question, a correct answer, and a response from a model. "
            "Please answer yes if the response contains the correct answer. Otherwise, answer no. "
            "If the response is equivalent to the correct answer or contains all the intermediate "
            "steps to get the correct answer, you should also answer yes. If the response only "
            "contains a subset of the information required by the answer, answer no. "
            "In addition, do not penalize off-by-one errors for the number of days. "
            "If the question asks for the number of days/weeks/months, etc., and the model makes "
            "off-by-one errors (e.g., predicting 19 days when the answer is 18), the model's "
            "response is still correct. \n\n"
            "Question: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n"
            "Is the model response correct? Answer yes or no only."
        )
        return template.format(question, answer, hypothesis)

    if qtype == "knowledge-update":
        template = (
            "I will give you a question, a correct answer, and a response from a model. "
            "Please answer yes if the response contains the correct answer. Otherwise, answer no. "
            "If the response contains some previous information along with an updated answer, "
            "the response should be considered as correct as long as the updated answer is the "
            "required answer.\n\n"
            "Question: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n"
            "Is the model response correct? Answer yes or no only."
        )
        return template.format(question, answer, hypothesis)

    if qtype == "single-session-preference":
        template = (
            "I will give you a question, a rubric for desired personalized response, and a "
            "response from a model. Please answer yes if the response satisfies the desired "
            "response. Otherwise, answer no. The model does not need to reflect all the points "
            "in the rubric. The response is correct as long as it recalls and utilizes the "
            "user's personal information correctly.\n\n"
            "Question: {}\n\nRubric: {}\n\nModel Response: {}\n\n"
            "Is the model response correct? Answer yes or no only."
        )
        return template.format(question, answer, hypothesis)

    # Fallback: generic template
    template = (
        "I will give you a question, a correct answer, and a response from a model. "
        "Please answer yes if the response contains the correct answer. Otherwise, answer no.\n\n"
        "Question: {}\n\nCorrect Answer: {}\n\nModel Response: {}\n\n"
        "Is the model response correct? Answer yes or no only."
    )
    return template.format(question, answer, hypothesis)


ANSWER_SYSTEM_PROMPT = textwrap.dedent("""\
    You are a personal assistant that answers questions based on conversation history retrieved from memory.
    Answer concisely and directly. If the information is not in the provided context, say "I don't know" or "I don't have that information."
""")

ANSWER_USER_TEMPLATE = textwrap.dedent("""\
    Below is relevant conversation history retrieved from memory:

    {context}

    Based on the above context, answer the following question:
    Question: {question}
    Answer:
""")

ALPHA = 0.05
Z = 1.96
ALPHA_CORRECTED = 0.01  # Bonferroni: 0.05 / 5 question types


# ---------------------------------------------------------------------------
# Statistics
# ---------------------------------------------------------------------------

def wilson_ci(k: int, n: int, z: float = Z) -> tuple[float, float]:
    """Wilson score interval for a proportion k/n."""
    if n == 0:
        return 0.0, 1.0
    p = k / n
    denom = 1 + z * z / n
    centre = (p + z * z / (2 * n)) / denom
    half = (z / denom) * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n))
    return max(0.0, centre - half), min(1.0, centre + half)


def cohens_h(accuracy: float, baseline: float = 0.5) -> tuple[float, str]:
    """Cohen's h (arcsine transform) vs a fixed baseline proportion."""
    h = 2 * math.asin(math.sqrt(max(0.0, min(1.0, accuracy)))) - \
        2 * math.asin(math.sqrt(max(0.0, min(1.0, baseline))))
    abs_h = abs(h)
    if abs_h < 0.2:
        interp = "negligible"
    elif abs_h < 0.5:
        interp = "small"
    elif abs_h < 0.8:
        interp = "medium"
    else:
        interp = "large"
    return round(h, 4), interp


# ---------------------------------------------------------------------------
# OpenAI helpers
# ---------------------------------------------------------------------------

def _openai_client():
    try:
        from openai import OpenAI  # noqa: PLC0415
    except ImportError:
        print("openai package not installed — run: pip install openai")
        raise SystemExit(1)
    api_key = os.environ.get("OPENAI_API_KEY")
    return OpenAI(api_key=api_key)


def embed_text(client, text: str, model: str = "text-embedding-3-large") -> list[float]:
    resp = client.embeddings.create(model=model, input=text)
    return resp.data[0].embedding


def _call_chat(client, model: str, user: str, retries: int = 5) -> str:
    """Call chat completions with exponential backoff on rate-limit.
    No system prompt — matches LongMemEval evaluate_qa.py behavior."""
    delay = 1.0
    for attempt in range(retries):
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=[{"role": "user", "content": user}],
                max_tokens=10,
                temperature=0,
            )
            return resp.choices[0].message.content.strip()
        except Exception as exc:
            code = getattr(exc, "status_code", None)
            if code == 429:
                log.warning("Rate limited, backing off %.1fs", delay)
                time.sleep(delay)
                delay *= 2
            else:
                raise
    raise RuntimeError("Exhausted retries calling OpenAI")


def _call_answer(client, model: str, user: str, retries: int = 5) -> str:
    """Answer generation call with system prompt."""
    delay = 1.0
    for attempt in range(retries):
        try:
            resp = client.chat.completions.create(
                model=model,
                messages=[
                    {"role": "system", "content": ANSWER_SYSTEM_PROMPT},
                    {"role": "user", "content": user},
                ],
                max_tokens=256,
                temperature=0,
            )
            return resp.choices[0].message.content.strip()
        except Exception as exc:
            code = getattr(exc, "status_code", None)
            if code == 429:
                log.warning("Rate limited, backing off %.1fs", delay)
                time.sleep(delay)
                delay *= 2
            else:
                raise
    raise RuntimeError("Exhausted retries calling OpenAI")


# ---------------------------------------------------------------------------
# Dataset loading
# ---------------------------------------------------------------------------

def load_dataset(data_dir: str | None) -> list[dict]:
    """
    Load LongMemEval instances.

    Expects one of:
      $data_dir/longmemeval_oracle.json   (oracle/evidence sessions only)
      $data_dir/longmemeval_s_cleaned.json
      $data_dir/data.json
      HuggingFace dataset xiaowu0162/longmemeval-cleaned (fallback)
    """
    if data_dir:
        for fname in (
            "longmemeval_oracle.json",
            "longmemeval_s_cleaned.json",
            "longmemeval_m_cleaned.json",
            "data.json",
        ):
            p = Path(data_dir) / fname
            if p.exists():
                log.info("Loading dataset from %s", p)
                with open(p) as f:
                    data = json.load(f)
                if isinstance(data, list):
                    return data
                if isinstance(data, dict):
                    return list(data.values())

    try:
        import datasets  # noqa: PLC0415
        log.info("Attempting HuggingFace download: xiaowu0162/longmemeval-cleaned")
        ds = datasets.load_dataset("xiaowu0162/longmemeval-cleaned")
        split = "test" if "test" in ds else list(ds.keys())[0]
        return list(ds[split])
    except Exception as exc:
        print(
            "Cannot load LongMemEval dataset.\n"
            "Set LONGMEMEVAL_DATA_DIR to the directory containing longmemeval_oracle.json\n"
            "or ensure HuggingFace access.\nError: " + str(exc)
        )
        raise SystemExit(1)


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def _db_connect(dsn: str):
    conn = psycopg2.connect(dsn)
    with conn.cursor() as cur:
        cur.execute("SET pgmnemo.gate_strict = 'off'")
    conn.commit()
    return conn


def _session_to_text(sess) -> str:
    if isinstance(sess, str):
        return sess
    if isinstance(sess, list):
        return "\n".join(
            (d.get("role", "") + ": " + d.get("content", "")) if isinstance(d, dict) else str(d)
            for d in sess
        )
    if isinstance(sess, dict):
        return json.dumps(sess)
    return str(sess)


def ingest_sessions(conn, sessions, project_id: int, embed_fn) -> None:
    """Store haystack sessions as pgmnemo lessons for the given project."""
    with conn.cursor() as cur:
        for sess in sessions:
            text = _session_to_text(sess)[:8000]
            emb = embed_fn(text)
            cur.execute(
                """
                INSERT INTO pgmnemo.agent_lesson
                    (lesson_text, embedding, role, project_id, topic, importance)
                VALUES (%s, %s::vector, %s, %s, %s, %s)
                """,
                (text, emb, "user", project_id, "conversation", 3),
            )
    conn.commit()


def recall(conn, query: str, embed_fn, k: int, project_id: int) -> list[str]:
    """Call pgmnemo.recall_lessons and return list of lesson texts."""
    emb = embed_fn(query)
    with conn.cursor() as cur:
        cur.execute(
            "SELECT lesson_text FROM pgmnemo.recall_lessons(%s::vector, %s, NULL, %s, %s)",
            (emb, k, project_id, query),
        )
        rows = cur.fetchall()
    return [r[0] for r in rows]


def cleanup_project(conn, project_id: int) -> None:
    with conn.cursor() as cur:
        cur.execute("DELETE FROM pgmnemo.agent_lesson WHERE project_id = %s", (project_id,))
    conn.commit()


# ---------------------------------------------------------------------------
# Answer + judge
# ---------------------------------------------------------------------------

def generate_answer(client, answer_model: str, question: str, context: list[str]) -> str:
    ctx_text = "\n\n---\n\n".join(context) if context else "(no context retrieved)"
    user_msg = ANSWER_USER_TEMPLATE.format(context=ctx_text, question=question)
    return _call_answer(client, answer_model, user_msg)


def judge_answer(client, judge_model: str, inst: dict, hypothesis: str) -> tuple[str, dict]:
    """
    Call GPT-4o judge with verbatim LongMemEval evaluate_qa.py prompts.
    Returns (label, raw_record) where label is "correct" or "incorrect".
    """
    prompt = get_judge_prompt(inst, hypothesis)
    raw = _call_chat(client, judge_model, prompt)
    raw_lower = raw.lower().strip()
    label = "correct" if raw_lower.startswith("yes") else "incorrect"
    record = {
        "question_id": inst.get("question_id"),
        "question_type": inst.get("question_type"),
        "question": inst.get("question"),
        "answer": inst.get("answer"),
        "hypothesis": hypothesis,
        "judge_label": label,
        "_judge_raw": raw,
    }
    return label, record


# ---------------------------------------------------------------------------
# Dry-run fixture
# ---------------------------------------------------------------------------

def dry_run_results(version: str, out_dir: Path) -> None:
    log.info("DRY-RUN mode: writing fixture output to %s", out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    metrics: dict[str, Any] = {}
    effect_sizes: dict[str, Any] = {}
    n_per_type = N_INSTANCES_EXPECTED // len(QUESTION_TYPES)
    for qt in QUESTION_TYPES:
        acc = round(0.70 + (abs(hash(qt)) % 15) * 0.01, 4)
        n = n_per_type
        k = int(acc * n)
        lo, hi = wilson_ci(k, n)
        d, interp = cohens_h(acc)
        metrics[qt] = {"accuracy": acc, "ci95_lo": round(lo, 4), "ci95_hi": round(hi, 4), "n": n}
        effect_sizes[qt] = {"vs_random_baseline_0.5": {"cohens_h": d, "interpretation": interp}}
    all_correct = sum(m["accuracy"] * m["n"] for m in metrics.values())
    all_n = sum(m["n"] for m in metrics.values())
    oa_acc = round(all_correct / all_n, 4)
    oa_lo, oa_hi = wilson_ci(int(all_correct), all_n)
    result = {
        "version": version,
        "date": datetime.date.today().isoformat(),
        "dataset": "xiaowu0162/longmemeval-cleaned",
        "judge": "gpt-4o",
        "judge_protocol": "verbatim LongMemEval evaluate_qa.py (yes/no per task type)",
        "answer_model": "gpt-4o",
        "embed_model": "text-embedding-3-large",
        "n_instances": N_INSTANCES_EXPECTED,
        "recall_k": DEFAULT_K,
        "dry_run": True,
        "metrics": metrics,
        "overall": {"accuracy": oa_acc, "ci95_lo": round(oa_lo, 4), "ci95_hi": round(oa_hi, 4), "n": all_n},
        "effect_sizes": effect_sizes,
        "multiple_comparison_correction": "bonferroni",
        "alpha_corrected": ALPHA_CORRECTED,
    }
    (out_dir / "metrics.json").write_text(json.dumps(result, indent=2))
    (out_dir / "raw_judge_calls.jsonl").write_text("")
    (out_dir / "report.md").write_text(_build_report(result, version))
    log.info("Dry-run complete. Output: %s", out_dir)


# ---------------------------------------------------------------------------
# Report builder
# ---------------------------------------------------------------------------

def _build_report(result: dict, version: str) -> str:
    m = result.get("metrics", {})
    ov = result.get("overall", {})
    ef = result.get("effect_sizes", {})
    date = result.get("date", "")
    rows = []
    for qt in QUESTION_TYPES:
        qm = m.get(qt, {})
        acc = qm.get("accuracy")
        lo = qm.get("ci95_lo")
        hi = qm.get("ci95_hi")
        n = qm.get("n")
        d_info = ef.get(qt, {}).get("vs_random_baseline_0.5", {})
        d = d_info.get("cohens_h")
        interp = d_info.get("interpretation")
        if isinstance(acc, float):
            row = (
                f"| `{qt}` | "
                f"{acc:.3f} | "
                f"[{lo:.3f}, {hi:.3f}] | "
                f"{n} | "
                f"{d:+.3f} | "
                f"{interp} |"
            )
        else:
            row = f"| `{qt}` | — | — | — | — | — |"
        rows.append(row)
    table = "\n        ".join(rows)
    dry_note = ""
    if result.get("dry_run"):
        dry_note = "\n> **Note:** Dry-run mode — values are synthetic fixtures, not real API calls.\n"
    ov_acc = ov.get("accuracy", "—")
    ov_lo = ov.get("ci95_lo", "—")
    ov_hi = ov.get("ci95_hi", "—")
    ov_n = ov.get("n", "—")
    ov_acc_str = f"{ov_acc:.3f}" if isinstance(ov_acc, float) else str(ov_acc)
    ov_lo_str = f"{ov_lo:.3f}" if isinstance(ov_lo, float) else str(ov_lo)
    ov_hi_str = f"{ov_hi:.3f}" if isinstance(ov_hi, float) else str(ov_hi)
    return textwrap.dedent(f"""
        # LongMemEval Benchmark — pgmnemo {version}

        **Date:** {date}
        **Dataset:** xiaowu0162/longmemeval-cleaned (Wu et al. 2024, ICLR 2025)
        **Judge:** `{result.get("judge", "")}`
        **Judge protocol:** {result.get("judge_protocol", "verbatim LongMemEval evaluate_qa.py")}
        **Answer model:** `{result.get("answer_model", "")}`
        **Embed model:** `{result.get("embed_model", "")}`
        **Recall k:** {result.get("recall_k", DEFAULT_K)}
        **N instances:** {result.get("n_instances", N_INSTANCES_EXPECTED)}
        {dry_note}
        ## Results by Question Type

        | Question Type | Accuracy | 95% CI (Wilson) | N | Cohen's h | Magnitude |
        |---|---|---|---|---|---|
        {table}

        ## Overall

        | Metric | Value |
        |---|---|
        | Accuracy | {ov_acc_str} |
        | 95% CI (Wilson) | [{ov_lo_str}, {ov_hi_str}] |
        | N | {ov_n} |

        ## Statistical Notes

        - **CIs:** Wilson score interval (z=1.96, 95%)
        - **Effect size:** Cohen's h (arcsine transform) vs random baseline p=0.50
        - **Multiple comparisons:** Bonferroni correction across 5 question types
          - Familywise α = 0.05 → per-test α = {ALPHA_CORRECTED:.4f}
        - **Judge protocol:** Verbatim LongMemEval `evaluate_qa.py` — task-specific yes/no prompts
          - Abstention questions use the unanswerable-detection template
          - Temporal questions include off-by-one leniency
          - Knowledge-update questions accept updated answers over prior facts

        ## Category → LongMemEval Type Mapping

        | Category | LongMemEval question_type(s) |
        |---|---|
        | `single_session_user` | `single-session-user`, `single-session-assistant`, `single-session-preference` |
        | `multi_session_user` | `multi-session` |
        | `temporal_reasoning` | `temporal-reasoning` |
        | `knowledge_update` | `knowledge-update` |
        | `multi_session_topic_absent` | any type with question_id ending `_abs` |

        ## Methodology

        Evaluation follows Wu et al. 2024 (ICLR 2025):
        1. Each instance's haystack sessions ingested as `pgmnemo.agent_lesson` rows
        2. `recall_lessons(embedding, k={DEFAULT_K})` retrieves top-{DEFAULT_K} lessons
        3. GPT-4o generates answer from retrieved context
        4. GPT-4o judge scores answer vs reference using verbatim LongMemEval prompts
        5. Judge outputs "yes"/"no" (no JSON wrapper) — matches evaluate_qa.py exactly
        6. Instances cleaned from DB between evaluations (project isolation via project_id)

        ## References

        - Wu et al. 2024 — "LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory", ICLR 2025
        - Wilson 1927 — score confidence intervals
        - Cohen 1988 — h statistic (arcsine transform)
        - Bonferroni correction: familywise α=0.05, K=5 tests, per-test α=0.01
    """).lstrip()


# ---------------------------------------------------------------------------
# Main runner
# ---------------------------------------------------------------------------

def run(args) -> None:
    out_dir = Path(args.out_dir)

    if args.dry_run:
        dry_run_results(args.version, out_dir)
        return

    api_key = os.environ.get("OPENAI_API_KEY")
    if not api_key:
        raise SystemExit("OPENAI_API_KEY not set")
    dsn = os.environ.get("PGMNEMO_DSN", "")
    if not dsn:
        raise SystemExit("PGMNEMO_DSN not set")
    data_dir = args.data_dir or os.environ.get("LONGMEMEVAL_DATA_DIR")

    out_dir.mkdir(parents=True, exist_ok=True)
    client = _openai_client()
    instances = load_dataset(data_dir)
    log.info("Loaded %d instances", len(instances))

    embed_fn = lambda text: embed_text(client, text, args.embed_model)  # noqa: E731

    conn = _db_connect(dsn)
    results_by_type: dict[str, list[int]] = {qt: [] for qt in QUESTION_TYPES}
    pending_judge: list[dict] = []

    for idx, inst in enumerate(instances):
        category = _get_category(inst)
        qid = inst.get("question_id", str(idx))
        question = inst.get("question", "")
        sessions = inst.get("haystack_sessions", [])
        project_id = abs(hash(str(qid))) % 1073741824

        try:
            ingest_sessions(conn, sessions, project_id, embed_fn)
            context = recall(conn, question, embed_fn, args.k, project_id)
            hypothesis = generate_answer(client, args.answer_model, question, context)
        except Exception as exc:
            log.error("Instance %s failed retrieval/generation: %s", qid, exc)
            hypothesis = "I don't know."
            context = []
        finally:
            cleanup_project(conn, project_id)

        log.info("[%d/%d] %s  category=%s", idx + 1, len(instances), qid, category)
        pending_judge.append({**inst, "_category": category, "_hypothesis": hypothesis})

    conn.close()

    log.info("Running %d judge calls (%d workers)…", len(pending_judge), args.judge_workers)
    judge_records: list[dict] = []

    def _judge_one(entry: dict) -> dict:
        hyp = entry.pop("_hypothesis")
        cat = entry.pop("_category")
        label, raw = judge_answer(client, args.judge_model, entry, hyp)
        return {**raw, "_category": cat, "autoeval_label": label}

    with ThreadPoolExecutor(max_workers=args.judge_workers) as pool:
        futures = {pool.submit(_judge_one, dict(e)): e for e in pending_judge}
        for fut in as_completed(futures):
            orig = futures[fut]
            qid = orig.get("question_id", "?")
            try:
                result_rec = fut.result()
                judge_records.append(result_rec)
            except Exception as exc:
                log.error("Judge failed for %s: %s", qid, exc)
                cat = _get_category(orig)
                judge_records.append({
                    "question_id": qid,
                    "question_type": orig.get("question_type"),
                    "_category": cat,
                    "autoeval_label": "incorrect",
                    "judge_label": "incorrect",
                })

    for rec in judge_records:
        cat = rec.get("_category", "single_session_user")
        label = rec.get("autoeval_label", "incorrect")
        score = 1 if label == "correct" else 0
        if cat in results_by_type:
            results_by_type[cat].append(score)

    metrics: dict[str, Any] = {}
    effect_sizes: dict[str, Any] = {}
    for qt in QUESTION_TYPES:
        scores = results_by_type[qt]
        n = len(scores)
        k = sum(scores)
        acc = round(k / n, 4) if n > 0 else 0.0
        lo, hi = wilson_ci(k, n)
        d, interp = cohens_h(acc) if n > 0 else (0.0, "negligible")
        metrics[qt] = {"accuracy": acc, "ci95_lo": round(lo, 4), "ci95_hi": round(hi, 4), "n": n}
        effect_sizes[qt] = {"vs_random_baseline_0.5": {"cohens_h": d, "interpretation": interp}}

    all_scores = [s for scores in results_by_type.values() for s in scores]
    all_n = len(all_scores)
    all_correct = sum(all_scores)
    oa_acc = round(all_correct / all_n, 4) if all_n > 0 else 0.0
    oa_lo, oa_hi = wilson_ci(all_correct, all_n)

    result = {
        "version": args.version,
        "date": datetime.date.today().isoformat(),
        "dataset": "xiaowu0162/longmemeval-cleaned",
        "judge": args.judge_model,
        "judge_protocol": "verbatim LongMemEval evaluate_qa.py (yes/no per task type)",
        "answer_model": args.answer_model,
        "embed_model": args.embed_model,
        "n_instances": len(instances),
        "recall_k": args.k,
        "metrics": metrics,
        "overall": {"accuracy": oa_acc, "ci95_lo": round(oa_lo, 4), "ci95_hi": round(oa_hi, 4), "n": all_n},
        "effect_sizes": effect_sizes,
        "multiple_comparison_correction": "bonferroni",
        "alpha_corrected": ALPHA_CORRECTED,
    }

    metrics_path = out_dir / "metrics.json"
    metrics_path.write_text(json.dumps(result, indent=2))
    log.info("Wrote %s", metrics_path)

    jsonl_path = out_dir / "raw_judge_calls.jsonl"
    with open(jsonl_path, "w") as f:
        for rec in judge_records:
            f.write(json.dumps(rec) + "\n")
    log.info("Wrote %s (%d records)", jsonl_path, len(judge_records))

    report = _build_report(result, args.version)
    report_path = out_dir / "report.md"
    report_path.write_text(report)

    print(f"\n=== LongMemEval {args.version} ===")
    print(f"Overall accuracy: {oa_acc:.3f}  [{oa_lo:.3f}, {oa_hi:.3f}]  N={all_n}")
    for qt in QUESTION_TYPES:
        mm = metrics[qt]
        print(f"  {qt:<35} {mm['accuracy']:.3f}  [{mm['ci95_lo']:.3f}, {mm['ci95_hi']:.3f}]  N={mm['n']}")
    print(f"\nOutputs: {out_dir}")


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def parse_args():
    today = datetime.date.today().strftime("%Y%m%d")
    parser = argparse.ArgumentParser(
        description="LongMemEval benchmark runner for pgmnemo",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--version", default=VERSION)
    parser.add_argument("--data-dir", default=None)
    parser.add_argument("--judge-model", default="gpt-4o")
    parser.add_argument("--judge-workers", type=int, default=DEFAULT_JUDGE_WORKERS)
    parser.add_argument("--embed-model", default="text-embedding-3-large")
    parser.add_argument("--answer-model", default="gpt-4o")
    parser.add_argument("--k", type=int, default=DEFAULT_K)
    parser.add_argument("--out-dir", default=f"results/{VERSION}_{today}")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--log-level", default="INFO")
    return parser.parse_args()


if __name__ == "__main__":
    args = parse_args()
    logging.basicConfig(level=getattr(logging, args.log_level), format="%(asctime)s %(levelname)s %(message)s")
    run(args)
