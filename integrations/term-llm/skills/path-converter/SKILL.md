---
name: path-converter
description: How a discourse-converters migration works (source -> intermediate database -> Discourse importer) and what data work it needs. Use when the project migrates a forum through discourse-converters, e.g. to plan a new converter or prepare a finding for one.
---

# The converter path

Pipeline: **source** (database or files) → a converter in discourse-converters writes an
**intermediate SQLite database** → Discourse's `script/bulk_import/generic_bulk.rb`
imports it into the site. The workbench runs this pipeline per plan; you prepare the
source and explain failures.

**The converter repository is the authority. Read it, don't recall it** (area
`converter` in `data_list`/`data_peek`):
- `AI-AGENTS.md`: rules for agents working on converters.
- `README.md`: running a conversion, architecture (BaseConverter, steps, output database,
  database adapters), "Creating a New Converter", running the import, known importer gaps.
- `converters/<platform>/README.md`, `settings.yml`, `converter.rb`, `steps/`: the
  nearest existing converter is the precedent. For a forum without a converter, pick the
  most similar one (e.g. MyBB → `converters/phpbb`; vBulletin, SMF, IPBoard also exist).
- `db/migrations/` and `db/models.rb`: what the intermediate database can hold.

What converter work needs from you, as a schema finding (`source-profile`):
1. For each intermediate entity the nearest converter fills (users, groups, categories,
   topics, posts, messages, polls, uploads, permalinks…): the source tables and columns
   that supply it, and how they differ from the nearest converter's source.
2. Value formats the converter must handle: timestamps, encodings, markup dialect,
   serialized fields, visibility/status codes, IDs that can collide.
3. Settings the converter will need (table prefix, database type, upload paths, base URL).
4. Counts to reconcile after the first run.

You don't write converter code: converter-developer does, from the released finding,
in the workspace's converter checkout. Converter runs on customer data are operational
actions the engineer plans and approves.
