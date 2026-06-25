EXTENSION    = pgmnemo
EXTVERSION   = 0.11.0

DATA         = $(wildcard extension/*--*.sql)
DOCS         =
# List only tests that have matching expected/*.out files.
# Historical tests (v060, v070) are kept in tests/sql/ for reference
# but excluded from REGRESS until expected files are authored.
REGRESS      = test_v071 test_v080 test_v0110_typed_recall
REGRESS_OPTS = --inputdir=tests --load-extension=vector --load-extension=$(EXTENSION)

PG_CONFIG    = pg_config
PGXS        := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)

# Convenience targets

.PHONY: help format lint

help:
	@echo "make            — build extension"
	@echo "make install    — install extension to $$($(PG_CONFIG) --sharedir)/extension/"
	@echo "make installcheck — run regression tests against running PG"
	@echo "make clean      — remove build artifacts"
	@echo "make uninstall  — remove installed extension files"
