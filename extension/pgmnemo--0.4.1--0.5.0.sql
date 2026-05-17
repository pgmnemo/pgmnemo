-- pgmnemo--0.4.1--0.5.0.sql
-- Migration: v0.4.1 → v0.5.0
--
-- R10: Remove traverse_causal_chain 4-arg overload deprecated in v0.4.1.
--      The 5-arg form pgmnemo.traverse_causal_chain(BIGINT,INT,TEXT[],BOOLEAN,TEXT) is unchanged.

DROP FUNCTION IF EXISTS pgmnemo.traverse_causal_chain(BIGINT, INT, TEXT[], BOOLEAN);
