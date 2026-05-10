## What changed and why

<!-- Required: one-sentence summary of the change and its motivation -->

## User-visible change

- [ ] No user-visible change
- [ ] Yes — describe: <!-- what a user will observe differently -->

## Docs impact

- [ ] No docs update needed
- [ ] Docs updated in this PR
- [ ] Docs update required in follow-up (link issue): 

## Benchmark impact

- [ ] No performance impact expected
- [ ] Benchmarked — results: <!-- paste or link benchmark diff -->
- [ ] Performance impact expected but not yet measured (explain): 

## Upgrade impact

- [ ] No upgrade steps required
- [ ] Migration required — describe steps: <!-- schema changes, config changes, extension reload, etc. -->

## Release note needed

- [ ] No — internal/invisible change
- [ ] Yes — draft note: <!-- one sentence suitable for CHANGELOG -->

## Checklist

- [ ] Tests added or updated
- [ ] `make check` passes locally
- [ ] No new compiler warnings

## WG Sign-off (required for schema changes and releases)

Skip this section for doc-only / config-only PRs. Required for any SQL schema change, retrieval logic change, or release tag PR.

**Stage gate reached:** RESEARCH | PLAN | IMPL | REVIEW | BENCH | SHIP  
**Iteration:** v0.X.Y  
**Hypothesis:** H-XX | fix: [description] | N/A

### Required sign-offs

Per `spec/v2/pgmnemo/PGMNEMO_WG_CHARTER_2026-05-10.md §3` and `PGMNEMO_AGENT_PROMPT_TEMPLATE_2026-05-10.md`:

| Role | Required for | Sign-off |
|---|---|---|
| technical_lead | All schema / retrieval changes | `[ ]` LGTM |
| experiment_designer | Bench protocol changes + BENCH stage GO/NO-GO | `[ ]` LGTM |
| research_supervisor | Statistical methodology changes | `[ ]` LGTM |
| principal_investigator | Ship/hold decision (release PRs only) | `[ ]` SHIP / HOLD |
| process_guardian | Phantom-DONE check: all listed files exist on disk | `[ ]` Verified |

### BENCH GO/NO-GO (fill for release PRs)

```
BENCH GO/NO-GO — [experiment_designer_84]
Decision: GO | NO-GO
Primary metric (recall@10 LME): current vs baseline, delta, p_corr
Primary metric (recall@10 LoCoMo): current vs baseline, delta, p_corr
Concern (if NO-GO):
```

### Artifact checklist (process_guardian verification)

- [ ] All files listed in PR description exist on disk (no phantom-DONE)
- [ ] Migration script column names match actual source schema (not assumed)
- [ ] `make check` output shown (pass or documented exception)
- [ ] No prohibited claims (see `docs/RELEASE_PROCESS.md §5.2`)
