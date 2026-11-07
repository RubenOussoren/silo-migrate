---
name: export-to-sql
description: Convert XML, JSON/NDJSON or CSV exports into SQL or SQLite that a converter or the source database can read, with scripts in the no-network sandbox. Use when a source arrives as files instead of a database dump.
---

# Exports to SQL

1. **Understand the shape first** (`data_peek` head/search): root element and record
   element for XML; top-level array vs one object per line for JSON; delimiter, quoting,
   header row and encoding for CSV. Find every record type and its fields; note IDs and
   foreign keys (`user_id`, `parent_id`, `thread_id`).
2. **Use the existing converters when they fit.** silo-migrate is mounted at `/silo`:
   `cd /silo && bundle _2.6.9_ exec ruby bin/silo-migrate convert-xml --help` (mysqldump
   XML) and `convert-json --help` (JSON/NDJSON with a preparation profile). Read their
   `--help` before writing your own.
3. **Otherwise write a small script** (`data_script`, Ruby by default; Ruby stdlib has
   REXML, JSON, CSV and SQLite is not guaranteed: write SQL text or CSV per table):
   - read from `/in/…` (inputs, read-only), write only to `/out` (your work folder);
   - **stream** (REXML stream parser, `CSV.foreach`, line-by-line NDJSON): files can be
     larger than memory (4 GB limit);
   - one output table per record type, explicit columns, original IDs kept as-is;
   - escape SQL strings properly (or write CSV and load it), keep text as UTF-8, keep raw
     markup (BBCode/HTML) untouched: conversion to Markdown is converter work;
   - print counts per record type and any rows skipped with the reason (no values).
4. **Check** with `data_job` (log tail and outputs), then spot-check the output with
   `data_peek` and compare record counts with the source (`count-reconciliation`).
5. **Register** the final files with `data_register` (type e.g. `derived-sql`); provenance
   records the script hash and inputs. Load SQL with `data_db_load` if a database helps.

Keep scripts deterministic and re-runnable: same inputs, same outputs.
