---
name: source-profile
description: Profile a migration source (forum database, export or another Discourse site) and write a schema finding - tables, columns, counts and invented example rows - that coding agents can safely use. Use when converter or merge work needs to know the source's shape.
---

# Source profile and schema finding

## Gather (from the loaded database, the dump and sandbox scripts)
With DBHub on (`db-<project>`): `search_objects` for tables, then **a table's columns before
you query it** (`object_type: column`, `schema`, `table`; guessed column names just fail),
then `execute_sql` for exact counts and value shapes, e.g. `SELECT visible,
COUNT(*) FROM mybb_posts GROUP BY visible`, `SELECT MIN(dateline), MAX(dateline) …`,
`SELECT LENGTH(message) …`. At most 50 rows come back: aggregate, don't page through rows.
Without DBHub: `data_db_status`, `CREATE TABLE` from the dump, and sandbox scripts.

- **Identity**: software and version (from a settings/version table or the dump header),
  table prefix, server version, charset/collation per table.
- **Tables that matter** for the migration (users, groups, categories/forums, topics/
  threads, posts, private messages, polls, attachments, likes/reputation, tags,
  permalinks, custom profile fields), and which are empty or irrelevant.
- **Columns** of those tables: name, type, nullability, keys, what it means. Mark
  serialized values (PHP `a:2:{…}`), comma lists, packed binary (IPs), Unix timestamps,
  bit flags and status codes, with their observed values (e.g. `visible`: 1, 0, -1).
- **Counts** per relevant table and per meaningful status (visible/deleted/unapproved),
  plus min/max dates. These feed `count-reconciliation` later.
- **Markup**: which BBCode/HTML features occur and roughly how often (search the dump
  or count with a script), embedded attachments, quotes, smilies, mentions.

## Write the finding (`data_propose_finding` without run_id)
Markdown (the engineer reads it rendered): start with `## Decisions needed` (numbered, each with
the facts and a suggested answer), then `## Identity`, `## Tables` (`###` per table: columns with
types and meaning; counts, a table is fine), `## Relationships`, `## Encodings and markup`,
`## Uploads`, `## Example rows`. Leave out anything code doesn't need that identifies the
customer: the source database name, hostnames, URLs, real record IDs (thread/post/user IDs).

Examples must be **invented**: `user_1`, `example@example.invalid`, `Example topic`,
timestamps like `1700000000`, IPs from `192.0.2.0/24`. Show value *shapes* (length,
format, encoding), never real values, names, text, emails, IPs, URLs or IDs that could
identify a person. Say which facts are verified and which are inferred.

The engineer reviews and may edit the finding before releasing it to converter-developer;
keep it focused on what code needs.
