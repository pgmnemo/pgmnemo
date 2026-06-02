EXTENSION    = pgmnemo
EXTVERSION   = 0.7.2

DATA         = $(wildcard extension/*--*.sql)
DOCS         = $(wildcard doc/*.md)
# List only tests that have matching expected/*.out files.
# Historical tests (v060, v070) are kept in tests/sql/ for reference
# but excluded from REGRESS until expected files are authored.
REGRESS      = test_v071
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
