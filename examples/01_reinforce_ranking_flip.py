"""
01_reinforce_ranking_flip.py — pgmnemo outcome-learning demo
=============================================================
Demonstrates pgmnemo's **outcome-learning** loop (the core differentiator):
  1. Ingest 5 lessons about the same topic (identical text-query signal).
  2. Recall — print rank order and confidence for each.
  3. Reinforce lesson A ('success') × 3 → confidence rises +0.30.
  4. Recall again — show A's rank improved and confidence delta in output.

Why this matters: standard RAG ranks purely on embedding/BM25 similarity.
pgmnemo adds a learned confidence signal updated by runtime outcomes, so
lessons that keep working rise; lessons that fail fall — without re-embedding.

Requires: psycopg2-binary, PG 17 + pgmnemo ≥ 0.9.0 installed.
Connection: default PG env vars (PGHOST/PGPORT/PGUSER/PGPASSWORD/PGDATABASE).

Usage:
    export PGDATABASE=pgmnemo PGUSER=postgres PGPASSWORD=pgmnemo
    python examples/01_reinforce_ranking_flip.py
"""

import sys
import os
import psycopg2
import psycopg2.extras

DSN = os.environ.get("PGMNEMO_DSN", "")

LESSONS = [
    ("lesson_A", "Always validate JWT expiry before trusting the payload"),
    ("lesson_B", "Prefer RS256 over HS256 for cross-service JWT verification"),
    ("lesson_C", "Store refresh tokens in httpOnly cookies, not localStorage"),
    ("lesson_D", "Set a maximum JWT TTL of 15 minutes for sensitive operations"),
    ("lesson_E", "Log every JWT rejection with the failure reason for audit"),
]

QUERY_TEXT = "JWT token security best practices"
ROLE       = "security_engineer"
PROJECT_ID = 42
COMMIT_SHA = "deadbeef00000000000000000000000000000001"  # synthetic provenance


def connect():
    if DSN:
        return psycopg2.connect(DSN)
    # Fall back to PG env vars
    return psycopg2.connect(
        host=os.environ.get("PGHOST", "localhost"),
        port=int(os.environ.get("PGPORT", 5432)),
        dbname=os.environ.get("PGDATABASE", "pgmnemo"),
        user=os.environ.get("PGUSER", "postgres"),
        password=os.environ.get("PGPASSWORD", "pgmnemo"),
    )


def ingest_lessons(cur):
    ids = {}
    for label, text in LESSONS:
        cur.execute(
            """
            SELECT pgmnemo.ingest(
                p_role        := %s,
                p_project_id  := %s,
                p_topic       := 'jwt_security',
                p_lesson_text := %s,
                p_importance  := 3,
                p_commit_sha  := %s
            )
            """,
            (ROLE, PROJECT_ID, text, COMMIT_SHA),
        )
        ids[label] = cur.fetchone()[0]
    return ids


def recall(cur, project_id, k=5):
    """
    recall_hybrid: fuses BM25 + vector proximity + recency + confidence.
    With no embeddings here we rely on BM25 (query_text only, NULL embedding).
    Output cols (v0.9.0): lesson_id, score, ..., lesson_text, confidence, match_confidence.
    """
    cur.execute(
        """
        SELECT lesson_id,
               score,
               confidence,
               match_confidence,
               lesson_text
        FROM pgmnemo.recall_hybrid(
            query_embedding   := NULL,
            query_text        := %s,
            k                 := %s,
            role_filter       := %s,
            project_id_filter := %s
        )
        ORDER BY score DESC
        """,
        (QUERY_TEXT, k, ROLE, project_id),
    )
    return cur.fetchall()


def print_ranking(rows, ids_by_label, label):
    label_by_id = {v: k for k, v in ids_by_label.items()}
    print(f"\n{'='*62}")
    print(f"  {label}")
    print(f"{'='*62}")
    print(f"  {'Rank':<5} {'Label':<10} {'Score':>8}  {'Conf':>6}  {'MatchConf':>9}  Lesson (truncated)")
    print(f"  {'-'*55}")
    for rank, (lid, score, conf, mconf, text) in enumerate(rows, 1):
        lbl = label_by_id.get(lid, f"id={lid}")
        print(f"  {rank:<5} {lbl:<10} {score:>8.5f}  {conf:>6.3f}  {mconf:>9.5f}  {text[:45]}")
    print()


def main():
    print("pgmnemo outcome-learning demo — reinforce() ranking flip")
    print(f"  Query: '{QUERY_TEXT}'")
    print(f"  Role: {ROLE}  Project: {PROJECT_ID}")

    conn = connect()
    conn.autocommit = False
    cur = conn.cursor()

    # Clean up any prior run for this project/role to keep demo deterministic
    cur.execute(
        "DELETE FROM pgmnemo.agent_lesson WHERE project_id = %s AND role = %s",
        (PROJECT_ID, ROLE),
    )

    # 1. Ingest
    print("\n[1] Ingesting 5 lessons …")
    ids = ingest_lessons(cur)
    conn.commit()
    for label, lid in ids.items():
        print(f"    {label} → id={lid}")

    # 2. Recall BEFORE reinforcement
    rows_before = recall(cur, PROJECT_ID)
    print_ranking(rows_before, ids, "BEFORE reinforcement (initial confidence = 0.500 each)")

    # Save rank and confidence for lesson_A
    id_A = ids["lesson_A"]
    before_by_id = {row[0]: row for row in rows_before}
    rank_before  = next(i+1 for i, r in enumerate(rows_before) if r[0] == id_A)
    conf_before  = before_by_id[id_A][2]

    # 3. Reinforce lesson_A × 3 (success)
    print("[2] Reinforcing lesson_A with 'success' × 3 …")
    for i in range(3):
        cur.execute("SELECT pgmnemo.reinforce(%s, 'success')", (id_A,))
        new_conf = cur.fetchone()[0]
        print(f"    reinforce #{i+1} → new confidence = {new_conf:.3f}")
    conn.commit()

    # 4. Recall AFTER reinforcement
    rows_after = recall(cur, PROJECT_ID)
    print_ranking(rows_after, ids, "AFTER reinforcement (lesson_A confidence += 0.30)")

    after_by_id = {row[0]: row for row in rows_after}
    rank_after  = next(i+1 for i, r in enumerate(rows_after) if r[0] == id_A)
    conf_after  = after_by_id[id_A][2]

    # 5. Summary
    print("─" * 62)
    print("  OUTCOME SUMMARY for lesson_A:")
    print(f"    confidence : {conf_before:.3f}  →  {conf_after:.3f}  (Δ = {conf_after - conf_before:+.3f})")
    print(f"    rank       : {rank_before}  →  {rank_after}")
    if rank_after < rank_before:
        print("  ✓ Rank IMPROVED — outcome-learning works as expected.")
    elif rank_after == rank_before:
        print("  ~ Rank unchanged (BM25 signal already dominant for this query).")
    else:
        print("  ✗ Rank dropped — unexpected; check data or query signal strength.")
    print("─" * 62)

    cur.close()
    conn.close()

    # Exit 1 if confidence didn't rise (smoke check)
    expected_delta = 0.30  # 3 × +0.10
    actual_delta   = conf_after - conf_before
    if abs(actual_delta - expected_delta) > 0.001:
        print(f"\nERROR: expected confidence delta {expected_delta}, got {actual_delta:.3f}", file=sys.stderr)
        sys.exit(1)

    print("\nDemo complete — exit 0")
    sys.exit(0)


if __name__ == "__main__":
    main()
