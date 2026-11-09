---
name: migration-guide
description: How this migration tool works and what happens next. Use whenever the engineer asks what to do next, where things stand, what a finding, plan, run or gate is, or how the pieces fit together.
---

# How this migration tool works

Goal: a migrations engineer can take a project from customer files to a reviewed site
without anyone explaining it. When they ask what's next, answer from `data_guide`,
never from memory. It's computed from the project's state, so it's right in a new chat.

## Answering "what's next?"

1. Call `data_guide` and say what `next` says: who acts, what they do and where.
2. Mention anything in `waiting_on_engineer` and `also`.
3. Don't invent steps. Only say something is possible if a tool or widget does it.
4. If you can't help, say so and name `support_contact`. Tell the engineer to send
   the run ID, the stage and the error code, and never customer data.

## The project

Each customer is one **project** in the web UI. `silo intake PROJECT` (as root) makes its
drop folder and web UI project. Every chat in that project works on that project only,
so never ask which one it is. The first chat creates the workspace with `data_create`.

## The stages

| Stage | Who | Where |
| --- | --- | --- |
| Copy files to the drop folder (`scp`), then `silo intake PROJECT` | Engineer | Server terminal |
| Create the workspace, take the files, load the source database | migration-data | Chat |
| Profile the data and propose a finding | migration-data | Chat |
| Review and release the finding | Engineer | Findings widget |
| Write, test and review the converter; propose a push | converter-developer, converter-reviewer | A separate chat in the project |
| Approve the push (opens or updates a draft PR); check CI | Engineer | Runs widget, GitHub |
| Register settings and checks; propose a convert run | migration-data | Chat |
| Approve and start it | Engineer | Runs widget |
| Propose a review import of the passed run | migration-data | Chat |
| Approve and start it | Engineer | Runs widget |
| Open the site through the SSH tunnel and check it; Reset it before the next review | Engineer | Runs widget, browser |

Nothing after that is tracked yet. Taking a backup and restoring it on hosted are the
engineer's own steps today. Don't suggest the tool does them.

## What the words mean

- **Finding:** what converter work needs to know about the data, with invented example
  values. Only a finding the engineer has **released** reaches the coding agents.
- **Plan:** an exact, proposed run, tied to specific files, code and settings. Any change
  to those makes it **stale**, and it must be proposed again. That's deliberate.
- **Run:** a plan being carried out. **Convert** builds the intermediate database;
  **review import** puts it into a local Discourse site.
- **Checks:** count comparisons between source, intermediate and destination. A run passes
  only when all match. Any difference stops the process until it's explained.
- **Review site:** the local result. It holds customer data until **Reset**.
- **Gate:** a decision only the engineer can make, in a widget: releasing a finding,
  approving a push, approving a plan. Agents propose; they can't approve or start.

## Limits to state plainly

- Which data a run uses is **not labelled** as development or launch yet (see `data_purpose`).
- A site's review isn't recorded yet (see `site_acceptance`).

## Keep the project's memory

Record the engineer's rulings with `data_decide` when they make them in this chat (for
example, what to do with empty posts), with basis `engineer_ruling`. An assumption is
basis `default`. Answering "what's next?" records nothing. Never copy earlier notes into
the log. To change a decision, record a new one on the same topic.
