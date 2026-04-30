EXTENSION = pgmnemo
DATA = pgmnemo--0.0.1.sql pgmnemo--0.0.1--0.1.0.sql pgmnemo--0.1.0--0.1.1.sql
REGRESS = version gate_enforce gate_warn gate_off recall_basic recency_weight_guc
PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
