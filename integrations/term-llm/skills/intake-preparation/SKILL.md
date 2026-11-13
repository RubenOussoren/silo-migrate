---
name: intake-preparation
description: Turn a supporting reference (requirements workbook, mapping sheet, customer wishes) into one exact, approvable plan - desired outcome, material questions or explicit exclusions, converter-native prepared files/settings with lineage - without a new role, grid or mapping language. Use when the engineer asks to use a reference for a migration, merge or mapping.
---

# Intake → outcome → questions/exclusions → one plan

The engineer uploads once through intake (Files: **Supporting reference**),
says what they want, answers the questions that matter, and approves **one** plan.
Nothing here starts a run: Start stays the engineer's explicit action in Runs.

1. **Find the reference.** `data_supporting_list`, then `data_supporting_read`
   (`sheets`, then bounded `rows`). A file dropped in chat is not read
   (`STANDARD_SUPPORTING_USE_INTAKE`): ask for an intake upload classified on Files.
   Never read it another way (paths, `data_script` without `references`, another chat).
2. **State the desired outcome** back in one or two plain sentences and confirm it.
   Identify the source snapshot, Base (merge) and converter/merge path from
   `data_guide`; the reference never replaces them.
3. **Classify each wish** (cite only what the reader returned; sheet/row numbers
   only from actual reader output):
   - `stock` - the converter/merger already does it;
   - `setting` - an existing option or settings key (converter-settings / merge-settings);
   - `prepared_input` - a file the converter's own contract reads (e.g. a mapping CSV/YAML);
   - `code` - reviewed code pinned by this plan (converter revision or merge layer)
     already does it. If no such code exists yet it is clean-coding work via a
     finding with invented examples, and is **not implemented** until reviewed
     code is pinned: until then it is an exclusion or a deferred follow-up;
   - `manual` - an explicit follow-up outside the run;
   - `excluded` - explicitly out of scope, naming an exclusion.
   Read the converter's contract (`data_list`/`data_peek` area `converter`, or the
   branch tools) for file names, headers and absent/header-only/populated meaning.
   Do not invent formats; do not make every converter use CSV.
4. **Ask only material questions**, grouped, in plain English: choices that change
   what lands in Discourse. The engineer either answers or makes an explicit
   scope choice (omit/defer/use a stated default). Record each with `data_decide`
   (`engineer_ruling` only if said in this chat). Never turn silence into a default.
   Cosmetic notes can stay as visible follow-ups.
5. **Prepare converter-native inputs** deterministically:
   - If the customer's decisions start from the converter's master lists (e.g.
     Khoros), propose the export with `data_master_lists_propose`; the engineer
     approves and starts it, and its CSVs are that run's artifacts.
   - Plain table → file: `data_supporting_prepare` (exact headers, renamed/typed
     columns, CSV/JSON/YAML rows or a two-column key map). It refuses formulas,
     missing headers, empty required cells, duplicate keys and oversize ranges
     instead of guessing - fix the spec or ask; never hand-copy cells.
   - Anything that needs logic: `data_script` with `references: [support-…]`
     (read-only at `/reference/<id>`), plus `/in` source files if needed.
   - Poll `data_job`, preview with `data_peek`, then `data_register`: type
     `mapping` (or `run-input`) named as the converter expects, or `merge-settings`
     for a native merge. Provenance keeps the reference digest, spec/script digest
     and job; the plan tools turn it into lineage themselves. Already-prepared
     files/manual exports from the engineer remain fine: `data_take` them as usual.
   - A file the converter treats as optional and the engineer chose to leave at its
     default goes in `absent_defaults`, not as an empty file; header-only is not absent.
     Files the converter writes itself during a run (e.g. Khoros' trust-level map)
     go in `generated`. If every optional file stays at its default, use
      `files: []` with those `absent_defaults`/`generated`: the fresh directory is
      writable only for declared generation. Never create a placeholder or header-only file.
6. **Propose one plan** with the exact bindings and a `preparation` record:
   - convert: `data_plan_propose` with `source`, `settings` (its directory key set
     to `"${SILO_RUN_INPUTS_DIR}"`), optional `reconciliation`, `run_inputs`
     (`consumer.setting`, `files: [{name, input_id}]`, `absent_defaults`,
     `generated`) and `preparation`;
   - native merge: `data_merge_propose` with `settings` (merge-settings) and
     `preparation`; the committed merge layer is pinned automatically.
   `preparation` = `analyst.text` (your interpretation; the label is fixed),
   `references` (`{support_id}`), `outcomes` (`stock`, `setting`, `prepared_input`
   with `input`, `code`, `manual`, `excluded` with `exclusion`), `questions` (each
   `resolved`, `excluded` or `scope_narrowed`, with `resolution`) and
   `exclusions`. It is labelled analyst-authored; it is not evidence that a file
   implements a wish - the bound bytes are. `code` is accepted only when the plan
   pins consumer code; otherwise it is clean-coding work (a finding) or an exclusion.
7. **Tell the engineer** the plan waits in Runs: approve, then Start. A changed file
   or answer means a new proposal; approved/completed plans never change.

Generated defaults a converter writes during a run (e.g. a missing trust-level map)
are run evidence, not next run's inputs; reusing one is a new selection and approval.
Customer values stay in private settings/mapping files, never in code, coding findings/notes, search queries or web requests.
