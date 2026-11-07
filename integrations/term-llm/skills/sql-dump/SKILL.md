---
name: sql-dump
description: Inspect and load SQL dumps into the project's source database - MySQL/MariaDB dumps and PostgreSQL dumps, including the dump.sql.gz inside a Discourse backup. Use after intake when an input is a database dump.
---

# SQL dumps

## Look before loading (`data_peek`)
- **Header** (`head`, ~4 KiB): tool and server version (`-- MySQL dump 10.13 … Server
  version 5.7.x`, `-- Dumped from database version 13.x`), `SET NAMES`, the database name
  (`CREATE DATABASE` / `USE` mean the dump creates its own database).
- **End** (`tail`, uncompressed dumps): mysqldump ends with `-- Dump completed on …`,
  pg_dump with `-- PostgreSQL database dump complete`. Missing → probably truncated: tell
  the engineer before loading.
- **Tables**: `search` for `CREATE TABLE` (up to 100 matches; search again with a narrower
  pattern such as a table prefix for more). The common prefix (`mybb_`, `phpbb_`) is the
  table prefix.
- **Charset**: per-table `DEFAULT CHARSET=` and the `SET NAMES` line. A `latin1` table
  holding UTF-8 bytes (mojibake like `Ã©`) is common in old forums: note it for the
  converter; don't "fix" the dump.

## Load
1. `data_db_up` with `mariadb` for MySQL/MariaDB dumps, `postgres` for PostgreSQL dumps
   and Discourse backups (PostgreSQL 18 with hstore, pg_trgm, unaccent, vector).
2. `data_db_load` with the `inputs/…` path. gzip/bzip2/xz are decompressed on the fly;
   PostgreSQL custom-format (`PGDMP`) dumps use pg_restore. Leave `charset` at the default
   unless the dump has no `SET NAMES` and you know its encoding.
3. Poll `data_job` until it finishes. On failure read the log tail: the first error and
   its line usually explain it (unknown collation from a newer server, a definer, a
   missing extension). Report it; `stop_on_error: false` only when the engineer agrees
   that skipping errors is acceptable, and list what was skipped.
4. `data_db_status`: schemas, table counts and sizes. Compare the table count with the
   `CREATE TABLE` count from the dump.

## Discourse backups (merge sources)
Extract the backup (`data_extract`), register `dump.sql.gz` as `postgres-dump` and the
`uploads/` tree separately (`uploads-sorting`). Discourse dumps may report harmless errors
for objects that already exist (schemas, extensions): load with `stop_on_error: false`
and check the log for anything else. The merge itself is done by Discourse's
`script/bulk_import/discourse_merger.rb`; read it before planning a merge.

Start over with `data_db_reset` (confirm) if a load went wrong; inputs are untouched.
