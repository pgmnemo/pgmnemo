# pgmnemo — Agent Dispatch Integration Guide

**Version:** 0.10.0  
**Closes:** #79  
**Status:** Production-ready (v0.10.0+)

This guide answers one question: **how do you give a running agent access to pgmnemo memory without turning it into a write-everything firehose?**

Four rules drive the answer:

1. **Attach at dispatch time, not agent startup** — fire `recall` once you know the task; avoid loading memory before the intent is known.
2. **Filter hard** — `role_filter + project_id_filter + exclude_dag_id` collapse result sets to signal. Unfil­tered recall returns noise.
3. **Whitelist `recall` + `patch`, block `ingest`** — agents correct memory but should not create it unsupervised during task execution.
4. **Supplement, don't replace** — prepend recalled context to your existing system prompt or task prefix; do not overwrite it.

---

## 1. When to attach MCP recall

### Attach at dispatch time

Fire the recall call **after task routing, before agent invocation.** The dispatcher knows the task text and the target agent's role, so it can issue a precise query. An agent given recall at startup lacks task context and will either query too broadly or not at all.

```
[Orchestrator task queue]
        │
        ▼
 route_task(task_id)          ← role and project_id now known
        │
        ▼
 recall(query=task_text,      ← targeted, low-latency (recall_fast, O(k log n))
        role_filter=role,
        project_id_filter=pid,
        exclude_dag_id=dag_id)
        │
        ▼
 build_system_prompt(base_prompt, recalled_lessons)   ← supplementary-to-prefix
        │
        ▼
 invoke_agent(system_prompt, task, tools=["recall","patch"])
```

### Do NOT attach at:
- **Startup / cold registration** — role not yet bound, query would be `"general"` with no filter.
- **Every tool call** — agent already carries the recalled context in its system prefix; repeated recall re-queries the same lessons at extra latency.
- **Post-task teardown** — teardown is the right time for `ingest` (committing new lessons), not recall.

### When `deep=True` is appropriate

The default MCP call uses `recall_fast` (pure HNSW, O(k log n), ~1–2 ms on a warmed index). Use `deep=True` only when:

- The task is exploratory/ambiguous and keyword co-occurrence matters (adds BM25 signal).
- The task corpus has sparse embeddings (e.g., code snippet libraries with low semantic density).
- You can afford 5–15× extra latency for the RRF fusion pass.

For routine dispatch, `deep=False` (the default) is the correct choice.

---

## 2. Filter usage

All three filters narrow the candidate set in the database, before scoring. Pass them always; omitting any one widens the result set unpredictably.

### `role_filter`

Restricts recall to lessons written under a specific agent role. Each agent role accumulates a distinct lesson corpus; mixing roles at recall time produces irrelevant results.

```python
# MCP tool call — pass in dispatch context
result = mcp.call("pgmnemo.recall", {
    "query": task_text,
    "top_k": 5,
    "role_filter": "software_developer",   # ← agent's registered role
    "project_id_filter": project_id,
    "exclude_dag_id": dag_run_id,
})
```

**Rule:** match `role_filter` to the dispatched agent's `role` column value. If your system uses a role hierarchy, pass the most-specific role.

### `project_id_filter`

Restricts recall to lessons for the active project. Without this, cross-project lessons pollute results (e.g., a Rails pattern surfacing in a Python project).

```sql
-- Same filter in raw SQL if calling the extension directly
SELECT * FROM pgmnemo.recall_fast(
    query_embedding  := $1::vector(1024),
    k                := 5,
    role_filter      := 'software_developer',
    project_id_filter := 12,               -- ← active project
    exclude_dag_id   := 'dag-run-xyz'
);
```

### `exclude_dag_id`

Prevents a workflow from recalling its own in-flight outputs. Without this, a multi-step DAG that writes intermediate lessons will pull them back as if they were validated prior knowledge.

```python
# Good: exclude the current DAG run's own lessons
result = mcp.call("pgmnemo.recall", {
    "query":             task_text,
    "role_filter":       role,
    "project_id_filter": project_id,
    "exclude_dag_id":    current_dag_run_id,   # ← required for multi-step DAGs
})
```

**Set `exclude_dag_id` to:** the workflow/DAG run identifier used in `source_dag_id` on ingest calls for the same run. Typically a UUID or `{dag_name}-{run_timestamp}`.

### All three together — complete dispatch call

```python
def dispatch_with_memory(
    task_text: str,
    role: str,
    project_id: int,
    dag_run_id: str,
    top_k: int = 5,
) -> list[dict]:
    """Recall relevant lessons at dispatch time, before agent invocation."""
    return mcp.call("pgmnemo.recall", {
        "query":             task_text,
        "top_k":             top_k,
        "role_filter":       role,
        "project_id_filter": project_id,
        "exclude_dag_id":    dag_run_id,
        "deep":              False,   # fast by default; flip only for exploratory tasks
    })
```

---

## 3. Tool whitelist — `recall` + `patch`, never `ingest`

During task execution an agent should have access to **two** MCP tools, not three.

| Tool | Allow during task | Reason |
|---|---|---|
| `pgmnemo.recall` | ✅ Yes | Agent may need to look up a specific lesson mid-task. |
| `pgmnemo.patch`  | ✅ Yes | Agent may discover a prior lesson is wrong; in-place correction is controlled (increments `version_n`, logged). |
| `pgmnemo.ingest` | ❌ No  | Unsupervised writes during task execution bypass provenance review. Ingest belongs to the post-task teardown phase, not the active agent. |

### Why block `ingest` during execution

`pgmnemo.ingest` requires a `commit_sha` or `artifact_hash` for verified writes (under `gate_strict`). Agents mid-task don't yet have a completed, verifiable artifact — the write would be either:
- **Blocked** by the gate (wasted call), or
- **Unverified** (lesson written with `verified_at IS NULL`, lower confidence weight in future recalls).

Grant `ingest` only to the post-task summarizer or to a dedicated memory-commit step with a real `commit_sha`.

### Configuring the whitelist

```python
# Agency / Claude SDK dispatch — restrict available tools
tools = [
    {"name": "pgmnemo.recall", ...},
    {"name": "pgmnemo.patch",  ...},
    # ← do NOT include pgmnemo.ingest here
]
agent_result = sdk.invoke(system_prompt=..., tools=tools)
```

```yaml
# MCP config — if using role-scoped server config
tools:
  - pgmnemo.recall
  - pgmnemo.patch
  # pgmnemo.ingest is registered server-side but excluded from agent tool grants
```

---

## 4. Supplementary-to-prefix rule

Recalled context **supplements** an existing system prompt — it is prepended as a structured block, never substituted for the base prompt.

### Why prefix, not replace

The base system prompt carries role definition, behavioral constraints, output format instructions, and safety rules. Recalled lessons add task-specific factual context. Merging or overwriting the base with recall output destroys the role constraints. Always treat recalled memory as additive.

### Prefix template

```python
RECALL_PREFIX_TEMPLATE = """\
## Recalled Memory ({n} lessons — role: {role}, project: {project_id})

The following lessons are retrieved from prior runs. Treat them as supplementary
context — they inform but do not override your task instructions.

{lessons}

---

"""

def build_system_prompt(base_prompt: str, lessons: list[dict]) -> str:
    if not lessons:
        return base_prompt

    formatted = "\n".join(
        f"- [{l['topic']}] {l['lesson_text']}"
        for l in lessons
    )
    prefix = RECALL_PREFIX_TEMPLATE.format(
        n=len(lessons),
        role=lessons[0].get("role", "unknown"),
        project_id=lessons[0].get("project_id", "?"),
        lessons=formatted,
    )
    return prefix + base_prompt   # ← recalled context BEFORE base prompt
```

### Prefix ordering

```
[system_prompt assembled at dispatch time]

## Recalled Memory (3 lessons — role: software_developer, project: 12)

The following lessons are retrieved from prior runs. ...

- [psycopg2] agent_run has no updated_at — use created_at, completed_at, started_at
- [orchestration] SAVEPOINT pattern required when wrapping risky SQL in nested tx
- [deploy] Docker image tag must be pushed before workflow starts or pull fails

---

[base system prompt — role definition, behavioral constraints, output format]
[task prefix — task_id, task_description, due_date]
```

The agent reads top-to-bottom; recalled context appears first, is contextually grounded, and the base constraints follow to enforce behavior.

### Token budget guidance

`top_k=5` with `recall_fast` returns ~5 lesson texts. At ~120 tokens each this is ~600 tokens — well within a 200k-token context window. Increase `top_k` only when the task is known to require broad prior-art coverage. For most dispatch scenarios, `top_k ∈ [3, 7]` is sufficient.

---

## 5. Complete dispatch example

```python
import psycopg2

conn = psycopg2.connect("postgresql://localhost/mydb")

def run_agent_task(
    task_text: str,
    role: str,
    project_id: int,
    dag_run_id: str,
    query_embedding,        # vector(1024) from your embedding model
    base_system_prompt: str,
) -> str:
    with conn.cursor() as cur:
        # 1. Recall at dispatch time — filtered, fast path
        cur.execute(
            """
            SELECT lesson_id, topic, lesson_text, score
            FROM pgmnemo.recall_fast(
                %s::vector(1024), %s, %s, %s, %s
            )
            """,
            (query_embedding, 5, role, project_id, dag_run_id),
        )
        lessons = cur.fetchall()

    # 2. Build system prompt — supplementary-to-prefix
    system_prompt = build_system_prompt(base_system_prompt, lessons)

    # 3. Invoke agent with whitelist (recall + patch only)
    result = sdk.invoke(
        system_prompt=system_prompt,
        task=task_text,
        tools=["pgmnemo.recall", "pgmnemo.patch"],
    )

    with conn.cursor() as cur:
        # 4. Post-task: ingest outcome lesson (outside agent, with commit_sha)
        if result.commit_sha:
            cur.execute(
                "SELECT pgmnemo.ingest(%s, %s, %s, %s, %s, %s, NULL::vector(1024), %s)",
                (role, project_id, "outcome", result.outcome_summary,
                 3, result.commit_sha, dag_run_id),
            )

            # 5. Reinforce lessons that contributed to a good outcome
            if result.lesson_ids_used and result.quality_score >= 0.8:
                cur.execute(
                    "SELECT pgmnemo.reinforce(%s::BIGINT[], %s)",
                    (result.lesson_ids_used, "success"),
                )
    conn.commit()
    return result.output
```

---

## 6. Anti-patterns

| Anti-pattern | Problem | Fix |
|---|---|---|
| Recall at agent startup before task is known | Query is too broad; no role/project context | Recall after routing, at dispatch time |
| No `role_filter` | Cross-role lessons pollute results | Always pass the dispatched agent's role |
| No `exclude_dag_id` | In-flight DAG outputs resurface as prior lessons | Pass current DAG run ID |
| Give `ingest` to the active agent | Unverified writes bypass provenance gate | Remove `ingest` from the agent tool list; ingest post-task only |
| Replace base prompt with recalled context | Destroys role constraints and safety rules | Prepend recalled context; keep base prompt intact |
| `top_k=50` for every call | 6,000+ tokens of context bloat on every dispatch | Use `top_k ∈ [3, 7]`; `deep=True` only for ambiguous tasks |
| `deep=True` for every call | 5–15× latency overhead for no benefit on focused tasks | `deep=False` (default) for routine dispatch |

---

## 7. Reference

| Concept | Source |
|---|---|
| `recall_fast()` SQL function | `extension/pgmnemo--0.9.7--0.10.0.sql` |
| `recall_hybrid()` SQL function | `extension/pgmnemo--0.9.6.sql` |
| MCP `pgmnemo.recall` tool | `pgmnemo_mcp/pgmnemo_mcp/server.py` |
| MCP `pgmnemo.patch` tool | `pgmnemo_mcp/pgmnemo_mcp/server.py` |
| `role_filter` / `project_id_filter` / `exclude_dag_id` filter history | `cdc1524b` (v0.9.7) |
| `deep` parameter (fast/hybrid dispatch) | `extension/pgmnemo--0.9.7--0.10.0.sql` (v0.10.0) |
| `confidence_boost_weight` tuning | `docs/USAGE.md` §"Outcome-learning" |
| Provenance gate modes | `docs/USAGE.md` §"Provenance-gated writes" |
| Token-economy navigation | `SQL_REFERENCE.md` §"navigate_locate / navigate_expand" |
