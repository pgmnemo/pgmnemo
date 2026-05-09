# LongMemEval Benchmark — pgmnemo v0.2.1

        **Date:** 2026-05-09
        **Dataset:** xiaowu0162/longmemeval-cleaned (Wu et al. 2024, ICLR 2025)
        **Judge:** `gpt-4o`
        **Judge protocol:** verbatim LongMemEval evaluate_qa.py (yes/no per task type)
        **Answer model:** `gpt-4o`
        **Embed model:** `text-embedding-3-large`
        **Recall k:** 20
        **N instances:** 500

> **Note:** Dry-run mode — values are synthetic fixtures, not real API calls.

        ## Results by Question Type

        | Question Type | Accuracy | 95% CI (Wilson) | N | Cohen's h | Magnitude |
        |---|---|---|---|---|---|
        | `single_session_user` | 0.700 | [0.604, 0.781] | 100 | +0.411 | small |
        | `multi_session_user` | 0.800 | [0.711, 0.867] | 100 | +0.643 | medium |
        | `temporal_reasoning` | 0.730 | [0.636, 0.807] | 100 | +0.478 | small |
        | `knowledge_update` | 0.800 | [0.711, 0.867] | 100 | +0.643 | medium |
        | `multi_session_topic_absent` | 0.800 | [0.711, 0.867] | 100 | +0.643 | medium |

        ## Overall

        | Metric | Value |
        |---|---|
        | Accuracy | 0.766 |
        | 95% CI (Wilson) | [0.727, 0.801] |
        | N | 500 |

        ## Statistical Notes

        - **CIs:** Wilson score interval (z=1.96, 95%)
        - **Effect size:** Cohen's h (arcsine transform) vs random baseline p=0.50
        - **Multiple comparisons:** Bonferroni correction across 5 question types
          - Familywise α = 0.05 → per-test α = 0.0100
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
        2. `recall_lessons(embedding, k=20)` retrieves top-20 lessons
        3. GPT-4o generates answer from retrieved context
        4. GPT-4o judge scores answer vs reference using verbatim LongMemEval prompts
        5. Judge outputs "yes"/"no" (no JSON wrapper) — matches evaluate_qa.py exactly
        6. Instances cleaned from DB between evaluations (project isolation via project_id)

        ## References

        - Wu et al. 2024 — "LongMemEval: Benchmarking Chat Assistants on Long-Term Interactive Memory", ICLR 2025
        - Wilson 1927 — score confidence intervals
        - Cohen 1988 — h statistic (arcsine transform)
        - Bonferroni correction: familywise α=0.05, K=5 tests, per-test α=0.01
