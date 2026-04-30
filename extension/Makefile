EXTENSION = pgmnemo
DATA = pgmnemo--0.0.1.sql pgmnemo--0.0.1--0.1.0.sql pgmnemo--0.1.0--0.1.1.sql pgmnemo--0.1.1--0.1.2.sql pgmnemo--0.1.2--0.1.3.sql
REGRESS = version gate_enforce gate_warn gate_off recall_basic recency_weight_guc prov_strength_tristate recall_lessons_pooled verifier_role
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
