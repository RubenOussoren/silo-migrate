# Intake-first references and the plan view (Project page)

This document describes Project page source; it is not a deployment. It covers the Files
tab's supporting references and the plan view in the Runs tab. Both read the optional
preparation and run-input fields that the backend binds into a plan body
(`lib/silo_migrate/services/standard_run_inputs.rb`). The workflow stays:
**upload once through intake → describe the outcome → answer the material questions or
explicitly narrow the scope → review one exact plan → Approve, then Start.**

## What the engineer sees

### Files → Supporting references

- Source/Development/Launch/Base snapshots stay explicit and separate. There is no fifth
  role, no Use-for grid and no per-file toggle.
- Each reference shows **Original retained in private custody · checksum recorded** when the
  registry has its checksum. The reference is never executed, and a plan says how it is used.
- A **derived use label** comes from plan bodies and run records; nothing stores it:
  - *Reference only*: no plan cites it.
  - *Cited by a plan*: a proposed or approved plan binds these exact bytes.
  - *Cited by a running run*: a claimed or running run's plan bound these exact bytes.
  - *Cited by a run that did not complete*: a run planned with these bytes failed, was
    interrupted or was abandoned, and nothing above applies.
  - *Cited by an earlier plan, not run*: only plans that were never run (for example out of
    date or discarded) cited it.
  - *Used by a completed run*: a completed run's plan bound these exact bytes.
  Precedence: completed > running > waiting plan > run that did not complete > never run.
  - *Use unknown*: plans could not be read. It is never shown as "unused".
  A citation of a different sha256 under the same file ID does not count as use of
  these bytes. **Used by (n)** lists the plan and run IDs.
- **Copy request for migration-data** copies plain text that names the project and the agent
  (`migration-data`, this project's private chat). The text asks for interpretation,
  questions and one proposed plan, and says not to start, approve or change anything. It
  carries labelled exact identities, so nothing has to be matched by hand or by file name
  (names can repeat):
  - **Private reader ID (for data_supporting_read):** the reference's `support-…` ID, when the
    registry has one;
  - **Files tab identity:** the `file-…` ID;
  - **Exact SHA-256:** the recorded checksum. The agent is asked to confirm that the reader ID's
    digest equals it.
  If there is no reader ID, the text says so and tells the agent to find it with
  `data_supporting_list` by the exact SHA-256, never by file name alone. No ID is made up.
  Nothing is sent, inserted into any chat or run. These private identities reach only the
  engineer's clipboard after their own click. If the clipboard is refused, the page shows the
  same text in a read-only box to copy by hand. `insertComposerText` is deliberately not used:
  it cannot choose or attest the correct agent/project chat.
- **Manage → Correct assignment** is unchanged.

### Runs → plan

Plans whose bodies have `preparation` and/or `run_inputs` get progressive sections between
the summary and the actions:

1. **What will happen**: the analyst text. Every analyst-written section is labelled
   *"Written by … an interpretation, not evidence."*
2. **Needs your answer / Not ready to approve**: every readiness blocker.
3. **How wishes are handled**: each outcome and its disposition (built-in, setting, prepared
   input, depends on code, manual follow-up, not included). A code-dependent outcome says
   *"Handled by pinned code, not proven by this page"*.
4. **Analyst-recorded answers and scope choices — confirm in this exact plan review**: each
   question with its *recorded answer*, *recorded exclusion* or *recorded scope narrowing*.
   migration-data records these, so they are labelled as such and are not independent proof
   that the engineer decided them. There is no separate approval: approving this exact plan
   is the engineer's one confirmation. Anything wrong is corrected in the chat, which leads
   to a new plan.
5. **Files and code this run will actually use**:
   - each converter input and any prepared settings, with its verification state;
   - a **preview of the exact verified bytes** (text formats, first 64 KiB), with lineage
     back to references and the preparation job/tool;
   - for an explicitly reused file: *"Explicitly reused from an earlier source snapshot, not this
     plan's source"*. Its snapshot ID and that source's sha256 are under the collapsed
     **Identity**, together with the preparation job, preparation spec sha256
     (`preparation_sha256`) and preparer script sha256;
   - for each reference, what the backend actually checked when proposing: *"bytes re-checked
     when proposed"* (`verified: custody_bytes`) or *"registry checksum matched; bytes not
     re-read"* (`verified: registry_digest`). A registry-only reference is never presented as
     byte-verified;
   - the converter setting/mount. An **empty manifest** (`files: []`, e.g. Khoros with no reviewed
     maps) says so plainly: the converter gets a fresh, empty run-owned directory, its own
     defaults apply, and no placeholder or header-only file is added (which would change the
     meaning). Absent defaults and generated files stay visible, and the one plan approval covers it; deliberately absent files (converter default applies) and
     declared generated files (captured as evidence, never reused automatically);
   - **Code that will run**: the converter or merge layer path and pinned revision from the
     backend's computed `code_readiness`. Its presence identifies the code, nothing more. It is
     not evidence that requested behavior is implemented or reviewed, and the page never says
     it is. For a convert plan the converter is always present. When outcomes depend on code,
     a caveat asks for the reviewed change to be checked before approval;
   - references cited as provenance only.
   Prepared settings are shown by role, never by their private file name. Hashes and IDs
   sit under collapsed **Identity** sections.
6. **Not included**: the plan's exclusions and their reasons (analyst-recorded, labelled).

Approve and Start are the existing buttons and the existing exact-digest decisions. This
adds no mapping approval. While a plan has blockers, both are disabled and
`aria-describedby` points to the reason. The project server also refuses
`/api/runs/approve` and `/api/runs/start` for such a plan with `STANDARD_PLAN_NOT_READY`,
before any control command runs. Plans without either field keep their previous view,
behavior and decisions, and the page makes no readiness claim for them.

### Run again keeps the earlier choices, as a new proposal

**Run again** and **Start pass N** on a convert or merge pass send a *new* proposal through the
existing `plan_propose` / `merge_propose` data operations. That proposal carries the earlier
plan's bound choices:

- `run_inputs`: `consumer {platform, setting}`, `source_sha256`,
  `files [{name, input_id, sha256, bytes, reuse?, lineage?}]`, `absent_defaults`, `generated`.
  The adapter re-checks each file against its registered input and the plan's source.
  - An explicit **`reuse {dataset_id, source_sha256}`** (a file from an earlier delivery: its own
    dataset and that dataset's registered source digest) is always carried, never dropped. The
    top-level `source_sha256` still binds the new plan's own source.
  - The bound **`lineage`** (reference `{file_id|input_id, sha256}` and preparation
    `{job, tool, script_sha256?, preparation_sha256?}`) is repeated without the display-only
    `verified` field. The adapter requires the workspace's records to still derive exactly
    that lineage.
- `preparation`: `analyst.text`, `references` (as `{file_id}` / `{input_id}`; the page first checks
  that each cited sha256 is still the registered one, and the adapter fills the same digest), `outcomes`,
  `questions` with their recorded resolutions, and `exclusions`. The fixed analyst label and
  `code_readiness` are computed again by the adapter and backend. The pinned code is
  whatever is committed now, as before.

It never carries an approval, digest, plan or run ID. The new plan still needs a fresh
Approve and a separate Start. Nothing is approved or started automatically.

The page refuses rather than silently dropping anything it cannot carry exactly:

- a field it does not understand, or a malformed `reuse`, lineage or `verified` value
  (`STANDARD_RUN_INPUTS_INVALID` / `STANDARD_PREPARATION_INVALID`);
- a question without a recorded resolution (`STANDARD_PREPARATION_UNRESOLVED`);
- a cited reference whose registered sha256 changed or that is no longer a supporting
  reference (`STANDARD_PREPARATION_INVALID`).

Plans without these fields propose exactly the same request as before. **Import into a review
site** is unchanged (review plans carry neither field).

**Engineer path:** this signed-in Project page call is the engineer's own trusted proposal.
The data adapter accepts it (`ws.chat` false) through the trusted signed-in engineer path.
Neither this page nor stock chat adapters manufacture native session markers. Chat proposals
retain fixed project routing and argument whitelists. On the engineer path the adapter also
accepts the repeated bound `lineage` and
refuses if it differs from what the workspace's records derive now.

### Preparation jobs (master-list export)

`standard_master_lists` plans and runs appear under **PREPARATION** in Runs, not as passes. They
are never numbered or counted as conversion/import, and they don't affect the
"what's next" banner. The plan says *"master-list export (preparation)"*. It explains that a
disposable source copy is loaded and its staging tables are rebuilt (not a read-only check),
that nothing is converted or imported, and that using the CSVs needs a new plan. It shows the
exporter script and list, plus the converter settings. A finished run says the same. The
existing Approve → Start decisions apply. Run again is not offered for preparation jobs;
ask migration-data for a new one.

## Readiness: fails closed

`integrations/term-llm/widgets/project/intake.py` re-checks the bound fields and blocks when:

| Code | Cause |
| --- | --- |
| `PREPARATION_UNREADABLE` / `RUN_INPUTS_UNREADABLE` | Field malformed against the backend vocabulary. This includes unsafe logical names, files both bound and absent/generated, exclusions that don't exist, and references naming both file and input. |
| `QUESTION_UNRESOLVED` | A question lacks `resolved` / `excluded` / `scope_narrowed` status. It never becomes a default. |
| `CODE_MISSING` | A `code` outcome without a present, pinned consumer. A present consumer only lifts this block; it is not shown as fulfilment. |
| `INPUT_NOT_BOUND` | A manifest file or prepared target is not in `input_binding` with the same sha256, or settings are named but not bound. |
| `INPUT_MISSING` / `INPUT_CHANGED` / `INPUT_UNREADABLE` | A selected registered input's bytes are absent, a link, of a different hash or not a regular file. |

Exact-hash re-verification streams the whole file; only the preview is bounded (first 64 KiB,
cut at a whole UTF-8 character). A file over 2 GiB is not re-hashed in the page request. It is
shown as *"Bound by checksum; too large to re-check on this page (the run checks it before
use)"*, is never labelled verified, gets no preview and does not block. Size alone does not
block a contract-valid input.

The backend is the authority. It refuses unresolved questions and unsupported code or input
claims when a plan is proposed (`STANDARD_PREPARATION_UNRESOLVED`,
`STANDARD_PREPARATION_INVALID`). At approval and Start, its stale-plan validation rechecks the
bound inputs and references. The widget check is defence in depth for the page's own routes,
so a plan never looks ready because of later byte changes or a malformed record. It is not
the only gate and is not needed to stop a CLI bypass. It reads the shapes described below.

## Server projections and API

- `GET /api/files`: the existing `deliveries` view. Each `roles.references[]` gains
  `usage_status` and `used_by: {plans: [{plan_id, status, operation, sha256[]}], runs: [{run_id, plan_id, status}]}`.
  If the workbench folder is absent, the status is `reference_only`. If plans can't be read,
  the status is `unknown` with `used_by: null`.
- `GET /api/runs/plan`: unchanged fields plus `intake`, projected from the stored plan body
  (the same bound fields `standard plan show` returns in its detail view): `null` for older plans, otherwise
  `{preparation, run_inputs, inputs[{input_id, name, origin, sha256, bytes, lineage, state, preview?}], blockers[{code, text}], ready}`.
- `POST /api/runs/approve` and `/api/runs/start`: the existing decisions behind the readiness
  guard above.
- `POST /api/runs/again`: as before, plus the retained `run_inputs` / `preparation` request
  fields described above.
- `GET /api/boards` → `runs.preparations[]`: `{kind, name, plan_id, plan_status, run_id, run_status, stage, list, delivery, at}`.

Bound shapes the projection reads (keep them in step with `standard_run_inputs.rb`):

```text
preparation: {version: 1, analyst: {label, text}, references: [{file_id|input_id, sha256, verified?: custody_bytes|registry_digest}],
              outcomes: [{id, requirement, disposition: stock|setting|prepared_input|code|manual|excluded, input?, exclusion?}],
              questions: [{id, text, status: resolved|excluded|scope_narrowed, resolution, exclusion?}],
              exclusions: [{id, text, reason?}], code_readiness: {kind: converter|merge_layer, present, required, path?, revision?}}
run_inputs:  {version: 1, consumer: {platform, setting}, source_sha256, mount, writable,
              files (may be []): [{name, input_id, sha256, bytes, reuse?: {dataset_id, source_sha256},
                       lineage?: {references?: [...], preparation?: {job, tool?, script_sha256?, preparation_sha256?}}}],
              absent_defaults: [name], generated: [name]}
```

## Tests (invented data only)

```sh
python3 -I -B test/intake_plan_widget_test.py
PLAYWRIGHT_CORE=… CHROMIUM=… node test/intake_plan_browser.mjs   # optional INTAKE_SCREENSHOTS=DIR
```

The browser test runs at 1280 px and 360 px. It covers:

- no horizontal overflow, page errors or outside requests;
- no per-file toggles;
- Copy request (clipboard success and fallback carry identical text), including the actual
  `support-…` reader ID, the Files ID and the same checksum. A same-named reference without
  a reader ID gets digest-based resolution instructions and no made-up ID. No request is sent;
- a blocked plan with Approve disabled and described;
- analyst-recorded answers worded as recorded, never as the engineer's own answers;
- a ready plan's previews, defaults, generated files and code facts, with no claim that
  pinned code fulfils a wish;
- keyboard Tab/Enter approval, and that Approve never starts the run;
- a plan without preparation keeping the existing behavior;
- a master-list export listed under PREPARATION and worded as preparation, not conversion or import.

Empty manifests are covered in both tests: ready with visible defaults, no previews or toggles,
one Approve, and carried exactly (`files: []`) on re-proposal. Plans without a manifest are
unchanged. The browser test also checks the reuse and verification wording, and that hashes stay
collapsed until Identity is opened. The Python test also covers explicit `reuse` and the exact
earlier source version carried (not dropped) on re-proposal; bound lineage repeated and
`verified` stripped; cited reference hashes checked before proposing; and malformed
reuse/verification refused. It also covers truthful usage for running/failed/never-run citations, large
inputs (no block, no verified claim) and UTF-8-safe bounded previews. It also covers Run again: exact retained fields, no computed or approval fields,
merge reference lineage, unchanged requests for older plans, and refusal for unknown, unresolved
or changed-reference cases.

## Legacy Runs surface

The standalone legacy Runs handler cannot render this private intake review. For
plans containing `run_inputs` or `preparation` it refuses Approve and Start with
`STANDARD_PROJECT_PLAN_REVIEW_REQUIRED`; use the existing Project page instead.
There is no client-supplied flag that bypasses that refusal. Unprepared legacy
plans and non-execution actions retain their prior behavior. The Project handler
continues through its exact-byte/readiness projection and the backend's digest
checks. This is not a new mapping approval: there is still one plan approval,
then explicit Start.

## Known gaps

- No engineer-side bounded reference **preview** yet. `supporting_read` is the
  agent's project-scoped reader; this page does not expose reference contents.
- Copy request is the safe MVP. Opening a draft in the correct chat needs a verified
  generic term-llm mechanism.
- Answers are given in the migration-data chat and produce a new plan. The page doesn't
  record answers itself.
- Cell/sheet locations are not shown. The backend does not yet bind reader-grounded locations.
