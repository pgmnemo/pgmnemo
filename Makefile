EXTENSION    = pgmnemo
EXTVERSION   = 0.7.0

DATA         = $(wildcard extension/*--*.sql)
DOCS         = $(wildcard doc/*.md)
TESTS        = $(wildcard tests/sql/*.sql)
REGRESS      = $(patsubst tests/sql/%.sql,%,$(TESTS))
REGRESS_OPTS = --inputdir=tests --load-extension=$(EXTENSION)

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
