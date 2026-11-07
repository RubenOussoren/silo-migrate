---
name: count-reconciliation
description: Compare record counts across a migration - source, intermediate database and Discourse destination - and explain every difference. Use after a conversion or import run, or when the engineer asks whether everything arrived.
---

# Count reconciliation

Compare, per entity, three numbers: **source** (what should migrate), **intermediate**
(what the converter wrote, e.g. discourse-converters' intermediate database) and
**destination** (what Discourse imported). For a merge or delta, compare against what
was already in the destination before the run too.

| Entity | Source filter to agree on first |
| --- | --- |
| users | exclude guests/bots/system accounts; banned and inactive count separately |
| groups, group members | custom groups only; built-in groups map to Discourse's own |
| categories | forums/categories; link forums usually become permalinks, not categories |
| topics | visible + unapproved + soft-deleted, each separately |
| posts | including first posts; per visibility state |
| private messages | conversations vs messages (one PM to 5 people may be 1 topic) |
| polls, votes; likes; tags | as present in the source |
| uploads | attachments in records, files present, files imported |
| permalinks | old URLs covered |

Explain every non-zero difference with a **reason and a count**, for example: skipped by
design (spam users, empty forums), merged (duplicate emails into one user), dropped by an
error (see the run's logs), unsupported by the importer, or a source filter mismatch.
"About right" is not a result. A difference with no explanation is a finding.

Source counts: migration-data measures them with DBHub (`execute_sql`, `COUNT(*)` with the
agreed filter) on the project's source database; other agents use the numbers it reports.

**For a convert run** the checks are an input the engineer approves with the plan: a JSON
file, registered with type `reconciliation`:

```json
{"version": 1, "checks": [
  {"name": "users", "source_sql": "SELECT COUNT(*) FROM mybb_users WHERE usergroup <> 7",
   "intermediate_sql": "SELECT COUNT(*) FROM users", "expect": "equal", "note": "banned users excluded (decision)"},
  {"name": "posts", "source_sql": "SELECT COUNT(*) FROM mybb_posts WHERE visible = 1",
   "intermediate_sql": "SELECT COUNT(*) FROM posts"}
]}
```

- **Names:** lowercase.
- **Queries:** each query is one `SELECT COUNT(*)` (or `WITH ... SELECT`). No comments, no
  `;` inside, no `INTO`/file/lock functions, and no `ATTACH`/`PRAGMA` on the intermediate side.
- **Expectations:** `expect: report` is for a number you only want to see.
- **When counts are taken:** the run counts the source side on its own copy of the dump,
  right after loading it (before the converter runs), and the intermediate side on the
  converter's output.
- **Results:** in `data_run_evidence` under `results.reconciliation`, as matched, differs,
  reported or error. They are private: only totals are public. Never put the per-check
  numbers in a finding with real names; counts are fine.
- **Intermediate tables:** check `db/migrations/` in the converter checkout for the table
  names before writing the intermediate queries.

Report a table: entity, source, intermediate, destination, difference, reason. Say which
numbers were measured and which were taken from earlier reports. Never include real
names or values; counts and categories are enough.
