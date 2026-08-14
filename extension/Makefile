EXTENSION = pgmnemo
# Every pgmnemo--*.sql in this directory is an install or upgrade script and
# must be installed. This was a hand-maintained list until 2026-08-14, when it
# drifted: pgmnemo--0.18.0.sql and its upgrade script were added to the tree but
# not to the list, so `make install` skipped them and CREATE EXTENSION failed
# with "no installation script nor update path for version 0.18.0" — every CI
# job that installs the extension went red. Two older upgrade scripts
# (0.2.2--0.2.3, 0.5.2--0.6.0) turned out to have been missing the same way.
# The root Makefile already used a wildcard; this one now matches it.
DATA = $(wildcard pgmnemo--*.sql)
REGRESS = version recency_weight_guc prov_strength_tristate recall_lessons_pooled recall_lessons_smoke verifier_role source_run_task_ids ttl_expires_at state_machine mem_edge traverse_causal recall_graph traverse_temporal_smoke temporal_boost_guc bitemporality_smoke as_of_ts stress_recall rrf_sparse role_no_ambiguity test_confidence test_v071 test_v080 test_v082 test_v091 confidence_boost_guc reinforce_delta_guc recall_recency versioned_items provenance_gate recall_fast navigate_dispatch selective_embedding recall_hybrid_robustness test_v0101 typed_recall typed_recall_fast test_remember_fact test_v0120 add_edge_idempotent guc_guard_threshold t_posterior_confidence t_use_attribution t_class_imbalance t_confidence_mode_switch t_backward_compat test_v0140_classify consolidate test_v0141_hnsw_planner test_v0141_p1b undo_consolidate test_v0142_p2 test_v0150_episodic test_v0151_guc_situation test_v0160_entity_keys test_v0161_failure_vocab test_v0170_foreign_schema test_v0170_guc_consistency
REGRESS_OPTS = --load-extension=vector --load-extension=pgmnemo
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
