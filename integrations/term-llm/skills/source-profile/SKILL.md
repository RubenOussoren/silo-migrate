---
name: source-profile
description: Profile a migration source (forum database, export or another Discourse site) and write a schema finding - tables, columns, counts and invented example rows - that coding agents can safely use. Use when converter or merge work needs to know the source's shape.
---

# Source profile and schema finding

## Gather (from the loaded database status, the dump and sandbox scripts)
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
Plain text, short sections: Identity; Tables (one block per table: columns with types and
meaning; counts); Relationships; Encodings and markup; Uploads; Open questions.

Examples must be **invented**: `user_1`, `example@example.invalid`, `Example topic`,
timestamps like `1700000000`, IPs from `192.0.2.0/24`. Show value *shapes* (length,
format, encoding), never real values, names, text, emails, IPs, URLs or IDs that could
identify a person. Say which facts are verified and which are inferred.

The engineer reviews and may edit the finding before releasing it to converter-developer;
keep it focused on what code needs.
