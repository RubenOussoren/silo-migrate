---
name: migration-guide
description: How this migration tool works and what happens next. Use whenever the engineer asks what to do next, where things stand, what a finding, plan, run or gate is, or how the pieces fit together. Also use for busy-project questions, stuck/stale jobs and Files corrections blocked by active dependencies.
---

# How this migration tool works

Goal: a migrations engineer can take a project from customer files to a reviewed site
without anyone explaining it. When they ask what's next, answer from `data_guide`,
never from memory. It's computed from the project's state, so it's right in a new chat.

## Answering "what's next?"

1. Call `data_guide` and say what `next` says: who acts, what they do and where.
2. Mention anything in `waiting_on_engineer` and `also`.
3. Don't invent steps. Only say something is possible if a tool or the Project page does it.
4. If you can't help, say so and name `support_contact`. Tell the engineer to send
   the run ID, the stage and the error code, and never customer data.

## The project

Each customer is one **project** in the web UI. `silo intake PROJECT` (as root) makes its
drop folder and web UI project. Every chat in that project works on that project only,
so never ask which one it is. The engineer creates the workspace on the Files tab.

## The stages

| Stage | Who | Where |
| --- | --- | --- |
| Copy files to the drop folder (`scp`), then `silo intake PROJECT` | Engineer | Server terminal |
| Create the workspace (source platform), then classify each file as source, uploads/assets, supporting reference or Base; choose Development/Launch only for a source snapshot | Engineer | Project page |
| Take assigned migration files; read references through the private supporting registry; load the source database | migration-data | Chat |
| Profile the data and propose a finding | migration-data | Chat |
| Review and release the finding | Engineer | Project page, Findings |
| Write, test and review the converter; propose a push | converter-developer, converter-reviewer | A separate chat in the project |
| Approve the push (opens or updates a draft PR); check CI | Engineer | Project page, Runs; GitHub |
| Register settings and checks; propose a convert run | migration-data | Chat |
| Approve and start it | Engineer | Project page, Runs |
| Propose a review import of the passed run | migration-data | Chat |
| Approve and start it | Engineer | Project page, Runs |
| Open the site through the SSH tunnel and check it; Reset it before the next review | Engineer | Project page, Runs; browser |
| Accept the site (on the customer's approval, or as their own check), or say what needs changing | Engineer | Project page, Runs (on the pass) |

With a **Base site** (the engineer's Files-tab label for the customer's sandbox: a `discourse backup --sql-only` file with its original name), the review import sits on that sandbox. Labelling takes it read-only as a `base_site` input once the workspace exists; review proposals use the current one unless `fresh_site: true`.
After checking the site the engineer chooses **Release backup** on the pass: the SQL-only combined site and its manifest go to the workspace's **output folder**; nothing is sent anywhere. With differences it needs the engineer's explicit acknowledgement and doesn't make the pass passed. Restoring it on the hosted migration site is the engineer's step, outside this tool.
A **merge project** (source platform `discourse`) brings another Discourse site into the Base site with Discourse's own merger: no convert run and no count checks. Development is the source site's full backup (`.tar.gz`), the Base site is the site merged into; `data_merge_propose` proposes the one **merge run**. Project rules (which category goes where) are a **merge layer** converter-developer writes (`dev_merge_guide`), with customer values in a `merge-settings` file you register. The engineer checks the merged site and the totals, then releases the full backup.

## File roles and corrections

`data` reports explicit current source snapshots, not the newest arrival. Development/Launch are snapshot purposes; assets attach to one, and references from Files intake share the private registry without replacing source or Base. Only an explicit new source creates a source version.
Only the engineer can use Files → Manage to correct/reactivate with a reason and digest-bound dependency preview. Preserve bytes, input IDs and completed run/release bindings; correction is not output repair. Affected pending approvals stale; affected active work blocks it. Unrelated references do not stale source plans. Never suggest Start over, deletion, manual JSON edits or fake re-uploaded versions as an undo.
For active job blockers, load `job-recovery` before acting; saved status is not liveness and reconciliation needs approval. Loose uploads are stored/not included by normal forum review. Native merge consumes uploads inside the original full source backup only.

To begin a project again, the engineer uses **Start over** at the foot of the Project page's
Overview: the work, chats (this one too) and review sites go, and the received files return to
the drop folder. Released backups in the output folder are deleted too. **Remove project** there deletes everything of it. Both list what goes first and
can't be undone. In a terminal, `silo remove-project PROJECT [--keep-received]` does the same.
Agents can't do either.

## What the words mean

- **Finding:** converter facts with invented values; only engineer-released findings reach coding agents.
- **Plan:** exact proposed run tied to inputs/code/settings. Changed dependencies make it stale; propose again.
- **Run:** executing a plan. Convert builds the intermediate DB; review imports it into a local site.
- **Checks:** source/intermediate/destination count comparisons. Differences must be explained.
- **Review site:** local result holding customer data until Reset.
- **Gate:** engineer-only finding release, push or plan approval. Agents cannot approve/start.

## Limits to state plainly

- A run can't use unlabelled data, and only the engineer labels (see `data` for what's current).
- Launch data can be labelled, but a launch run is refused until running on launch data is built.
- `site_acceptance` (in `data_guide`): the accepted process launch repeats. Only the engineer accepts; their "needs changes" note reaches you there.

## Keep the project's memory

Record rulings with `data_decide` when the engineer makes them **in this chat**, using basis `engineer_ruling`. Assumptions use `default`.
Answering “what's next?” records nothing. Never fill the log from notes/memory. Changed decisions are new entries on the same topic.
