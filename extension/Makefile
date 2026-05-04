EXTENSION = pgmnemo
DATA = pgmnemo--0.0.1.sql pgmnemo--0.0.1--0.1.0.sql pgmnemo--0.1.0--0.1.1.sql pgmnemo--0.1.1--0.1.2.sql pgmnemo--0.1.2--0.1.3.sql pgmnemo--0.1.3--0.1.4.sql pgmnemo--0.1.3--0.1.4-provenance.sql pgmnemo--0.1.3--0.1.4-ttl.sql pgmnemo--0.1.3--0.1.4-state-machine.sql pgmnemo--0.1.4--0.2.0-mem-edge.sql
REGRESS = version gate_enforce gate_warn gate_off recall_basic recency_weight_guc prov_strength_tristate recall_lessons_pooled verifier_role source_run_task_ids ttl_expires_at state_machine mem_edge
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
