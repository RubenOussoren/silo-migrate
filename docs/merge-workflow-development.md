# Local merger development and proposal revisions

This flow uses stock term-llm. Do not install a native fork or change provider routes.
The existing successful Prepare can be reused while its inputs/delivery/runtime and
ready, unused generation remain valid. Updating Silo code does not rewrite that
historical preparation or authorize a Merge. Existing Merge approvals bind code;
re-propose after updating rather than reuse an old approval.

## Standalone local merger code

New prepared **custom** merges use `<workspace root>/merger/`, a local Git repository
with **no remote**. Neither Discourse core nor discourse-converters is modified.
Do not put private YAML, workbook data or real customer values in this repository,
its tests, comments or commit messages. Private settings remain registered inputs.

The engineer may create/check it from the service-account shell:

```sh
silo-migrate-control standard merger init PROJECT
silo-migrate-control standard merger status PROJECT
```

These do not reset, Prepare or Merge anything. Status prints the actual absolute
review path, local commit, dirty state and executable layer manifest/digest. Use
that returned path on Metal, not a guessed prefix or the converter checkout.

The coding chat uses:

1. `dev_merge_guide`: actual review path, contract and the exact ready Prepare's
   Discourse core revision/source links. It works before the store exists. Multiple
   ready preparations or an unreadable ready-core pin are explicit blockers, not a
   reason to use main or a profile fallback.
2. `dev_merger_init` once; `dev_merger_list/read/search/status` to inspect clean code.
3. `dev_merger_write/edit/delete` for `merger.rb`, optional Ruby `helpers/`, invented
   `test/` fixtures and `README.md`.
4. `dev_merger_test` (suite `test`, optional `test/..._test.rb` file) and
   `dev_merger_format`. Tests use the pinned converter image's Ruby/minitest in a
   no-network container, without a converter repository, dependency installation,
   Bundler or a Discourse app. Stub the stock merger and any Rails models. Formatting
   uses the image's syntax_tree; no dependency is downloaded at tool time.
5. `dev_merger_commit`, then `dev_merger_diff` with `scope: commit` and, optionally,
   a local commit SHA. The reviewer has the corresponding read-only tools, not init,
   write, commit or remote operations. This code has no push/PR step.
6. Engineer reviews the path/commit directly on Metal. Only then ask migration-data
   to propose the custom Merge using the prepared run/generation and private settings.

The content gate shows/exports only unchanged tracked files or bytes last written
by the developer tools. Untracked private files and human-modified tracked bytes
are not automatically trusted. Dirty/hidden changes can block a plan: ask the
engineer, never broaden visibility or auto-commit them. Ignored untracked files
remain outside the committed layer and are never executed.

A Merge executes only committed `merger.rb` and `helpers/**/*.rb`: at most 32 regular
Ruby files, 512 KiB together. Tests/docs are reviewed and committed but not selected
for execution. Links/submodules/unsafe Git configuration or a remote refuse. One
subclass of `BulkImport::DiscourseMerger`, stock classes unedited; prepared custom
layers require class-level `silo_merge_preflight!` and `silo_merge_postflight!` hooks
returning exactly true after policy validation. **Both class hooks, construction and
copying (`start`) execute in the same Ruby process on the same loaded subclass.**
Preflight can retain its observations in class-instance variables for postflight;
constructor/copy overrides must not clear or replace that baseline. Preflight cannot
store state on a merger instance that does not yet exist. No files are needed or
permitted for these snapshots. The state does not survive this merge invocation or
extend into later finalize/rebake processes. Stub tests do not prove private mapping
correctness, actual core compatibility or resulting permissions.

The plan binds a commit and content manifest; referenced commits are retained.
Start rechecks/extracts those committed bytes into the run-private directory,
never executes the mutable working tree, and cannot silently use another checkout.
A later commit does not substitute itself into an approved plan. New requirements
or settings require review and a new exact plan: **Approve → separate Start**.
Legacy one-shot converter-held layers retain their old contract on projects without
a standalone store. Once a standalone store is initialized, one-shot proposals
refuse: use a ready Prepare with explicit stock/custom intent. They must not silently
ignore that separate code store.

Settings are a safely loaded YAML root mapping, at most **256 KiB**, aliases disabled.
There is no 200-line/100-entry execution cap. The layer's documented key/value shapes
use invented examples; migration-data supplies private values.

## Destination site-setting preservation

The layer calls `super` first in `initialize`, imports no source site settings and
introduces no site-setting changes of its own. This is **not a zero-write claim**:
the pinned stock constructor assigns `authorized_extensions`. Class-level preflight
runs before that constructor and can validate destination state; code after `super`
in the layer's initializer cannot run before it.

Silo, not the layer, owns the narrow exception. Before loading any layer it captures
all destination stored raw values/types privately, plus the permitted setting's
explicit-override presence or absence and effective value. Row IDs and timestamps
are not restored or used as policy identity. A SHA-256 binds
the capture copied into the run. After copying it restores only
`authorized_extensions`, refreshes and re-reads it, and checks every other stored
setting without repairing differences. **Postflight, finalization/rebaking and the
deliverable backup run only after restoration.** Host checks independently compare
stored rows after merge, around finalization, before backup and before completion;
the Rails verify stage also checks the effective extension value. Masked connector
values are never the comparison source. These boundary checks do not prove that
reviewed layer code made no transient write between checks; code review still
forbids all layer-owned setting writes.

Silo uses the supported `Post#rebake!(priority: :ultra_low)` API for every post,
rather than the stock `posts:rebake` wrapper: that wrapper writes a second setting,
`disable_system_edit_notifications`, and swallows individual rebake failures.
Silo permits neither another temporary-setting exception nor silent partial success.
Cooking and baked-version updates finish synchronously; follow-up jobs remain
queued as in the stock task, not forced inline. This is not proof that all queued
post-processing, customer plugins or external content have been validated.

Failures attempt only the permitted restoration and report names/counts privately,
not values in logs, totals or agent output. An unknown execution outcome or failed
verification is unproven, never success. When guest termination is unknown
(timeout, interrupted executor or recovery), the guarded restoration attempt is
read-only: it reports observed differences but refuses a write that could race the
still-running merger. This may leave the permitted setting unrestored; no automatic
repair or reuse is claimed. The engineer diagnoses/resets the failed environment.
Recovery does not make a failed/dirty consumed generation ready. `STANDARD_MERGE_SITE_SETTINGS_FAILED` is a hard gate,
not permission to patch stock core, skip `super`, broaden setting writes or weaken
checks. Invented helper/runtime tests are not proof of the customer's complete
layer, policy or actual Merge. Keep its adapter, `merger.rb` and required hooks as
separate completion/review work.

### Source basis and local regression checks

The integration was checked against public core
[`2769139d59ca8284ff148fdc54094d414092700e`](https://github.com/discourse/discourse/tree/2769139d59ca8284ff148fdc54094d414092700e):
[`discourse_merger.rb`](https://github.com/discourse/discourse/blob/2769139d59ca8284ff148fdc54094d414092700e/script/bulk_import/discourse_merger.rb)
(constructor assignment and direct file/SQL upload copying),
[`posts.rake`](https://github.com/discourse/discourse/blob/2769139d59ca8284ff148fdc54094d414092700e/lib/tasks/posts.rake)
(the second setting write and swallowed rebake exceptions), and
[`Post#rebake!`](https://github.com/discourse/discourse/blob/2769139d59ca8284ff148fdc54094d414092700e/app/models/post.rb)
(synchronous cooking and queued follow-up work). The supported temporary stock value
is `jpg|jpeg|png|gif`; a different value/type is refused, not silently permitted.
A new selected runtime still requires its own compatibility checks.

Focused Ruby checks are `test/merge_site_settings_test.rb`,
`test/merge_layer_checks_test.rb`, `test/merge_rebake_test.rb` and
`test/standard_merge_site_settings_test.rb`. The last also proves that an existing
completed Prepare survives a code-identity change without rewriting its recorded
plan, digest, generation or seals; old Merge approvals must be re-proposed.

The optional real Rails/PostgreSQL check is:

```sh
SILO_MERGE_SITE_SETTINGS_LIVE=1 python3 -I -B test/merge_site_settings_live_test.py
```

It requires cached images, uses only an invented disposable site, never pulls or
builds images, and checks its labelled-resource cleanup. Opting in with missing
prerequisites fails rather than silently skips. It records the actual cached app
revision: this is not a customer-ready runtime or an end-to-end custom Merge test.
Default Python discovery skips these checks explicitly.

## Revise an unreleased finding

In migration-data:

1. `data_finding_proposal(finding_id)` returns current private text, revision and
   `proposal_sha256`. Follow `next_offset` for long text (character offsets). If the
   digest changes between pages, reread/reconcile before editing.
2. `data_revise_finding(finding_id, expected_proposal_sha256, text)` checks that
   exact current revision under the store lock and creates a private revision.
   The ID, kind and run association stay fixed. It cannot release, reject or change
   a decided finding. Same text is a no-op refusal, not another revision.
3. The engineer loads the current proposal in Findings, edits **Text to release**
   if needed and releases only safe requirements/invented reproductions. A revision
   while the page is open makes Release/Reject fail safely; the page keeps unsaved
   edits and offers to load/compare the revised proposal.

There are at most 20 private revisions of 256 KiB per finding; past that, propose a
replacement. Older proposals are revision 1 without a storage migration. Released
Amend/Withdraw remains engineer-only. Coding lists and reads show released
derivatives only, never private proposals or revision history.

Engineer CLI (the proposal digest is different from the edited release-text digest):

```sh
silo-migrate-control standard finding review PROJECT FINDING_ID
silo-migrate-control standard finding revise PROJECT FINDING_ID --file FILE --expected-proposal-sha256 PROPOSAL_DIGEST
silo-migrate-control standard finding release PROJECT FINDING_ID --file SAFE_FILE --sha256 SAFE_TEXT_DIGEST --expected-proposal-sha256 PROPOSAL_DIGEST --reviewer NAME
silo-migrate-control standard finding reject PROJECT FINDING_ID --expected-proposal-sha256 PROPOSAL_DIGEST --reviewer NAME
```

Missing/stale digests refuse. Do not copy private proposal text into coding chats
or place it in this public repository merely to supply that review.

## Inspection: bind observations to the correct run

Server names identify the **project**, not a run. Use current `data_guide` / run
state, not the failed run last discussed in chat. Call `data_merge_inspection` with
that exact completed ready/result run and generation; its response repeats the
binding. Enable only the returned project connectors. After rebinding/updating,
disable/re-enable the selected connectors so an already-running process is not
mistaken for a different run. Do not probe another project's server for comparison.

- **Source** grants are deliberately column-level. Table-level SELECT can be false
  while reviewed-column reads and `COUNT(*)` work. Check `has_any_column_privilege`
  or `has_column_privilege`; do not broaden grants to fix an intended restriction.
- **Base/result** have admin visibility for restricted-category inspection but a
  GET-only `global:read` API key, no mutation tools and hidden email fields. The
  connectable app inspection clone is not the sealed Base checkpoint; a separate
  database named inspect-base is not required.
- **Category pagination**: the pinned connector first tries search POST, refused
  by that GET-only key, then GET fallback. A one-request budget can return an empty
  **incomplete** result. Use defaults, or `max_pages: 1, max_requests: 4` for a small
  probe. Honor `complete`, `has_more` and truncation metadata. Do not reinterpret
  returned-row `meta.total` as a true upstream inventory.

Launcher admission now checks current completed ready/result state and the exact
manifest/generation; result access also requires the matching recorded backup.
Failure/recovery fences inspection that this run opened, including failures after
open. If a fence cannot be proved, evidence says `inspection_fence: unproven`;
operator recovery is required, not a successful-cleanup claim. Computed staleness
is also checked before analyst registration; it is not automatic revocation of an
already-running connector. Merge activation/reset use the exclusive fence and
remove owned launchers. Nothing here automatically resets a project.

## Prepared custom workflow discovery and validation

A prepared custom layer commits `workflow-contract.json` beside `merger.rb`.
The host reads the actual committed bytes; the layer must not read that file.
This is a clean code artifact, not private settings or model credentials. The
version-1 contract has exactly these fields (illustrative policy, no customer schema):

```json
{
  "version": 1,
  "engine": "discourse-merger-v1",
  "settings_schema": {
    "type": "object",
    "properties": {"upload_policy": {"type": "string", "enum": ["carried_live_posts"]}},
    "required": ["upload_policy"],
    "additionalProperties": false
  },
  "asset_policy_key": "upload_policy",
  "asset_policies": {"carried_live_posts": "carried"},
  "audit_aggregates": {"preflight": [], "postflight": []}
}
```

Discover **actual** enum values, declared audit keys and engine facts from the
committed contract, not this example. Only shipped supported engine adapters may
execute; a contract cannot register a production engine. `settings_schema` is the
strict bounded subset implemented by `runtime/shared/merge_contract.rb`: type,
properties, required, additionalProperties, items, minItems/maxItems, uniqueItems,
minLength/maxLength, minimum/maximum, enum, const, anyOf/oneOf/allOf, description.
The root is a closed object. Nested objects must be closed or have a schema for
dynamic values. No `$ref`, patterns, coercion, defaults, executable checks or IO.
Contract bounds are 128 KiB, depth 16 and 4096 tree nodes; settings retain the
256 KiB safe YAML limit. Unknown keys/keywords refuse rather than being ignored.

Read-only class hooks `self.silo_merge_asset_ids` and
`self.silo_merge_audit(phase)` supply required source asset IDs and fixed declared
nonnegative integer aggregates. Audit phases are `preflight` and `postflight`;
keys are clean code-defined identifiers, never names built from private rows.
The existing preflight/constructor/copy/postflight same-process contract remains.
Required media cannot be independently deselected. Actual file transfers and stock
compatibility belong to the host adapter: no layer file IO, upstream core changes
or global `FileUtils` patch.

The first shipped adapter is deliberately pinned to the verified stock Discourse
merger implementation; a changed stock method refuses until separately supported.
It duplicates that method into a scoped adapter, defers only its physical `cp_r`,
and retains the stock source/destination upload mapping. This is not a universal
merge algorithm. A separate test-only adapter exercises the shared contract,
registry, gate, transfer and evidence seams without Discourse assumptions.

`carried` means the layer's required IDs, not a separately editable file allowlist;
`all` must be explicitly declared and selected. The stock merger can still insert
upload ownership/bookkeeping rows that are not content references. Private evidence
therefore distinguishes upload rows inserted, bookkeeping references, content
references, and rows without content references instead of calling them all
"uploads copied". Required bytes must be either verified copies or verified
same-content destination reuse. Excluded files, dangling mappings and unsupported
content-reference tables fail closed. Secure-upload identity uses the real
`original_sha1` when present; an unverifiable synthetic identity cannot establish
content equality. Unclassified source `optimized/` assets are currently unsupported,
not silently copied or dropped.

Destination original-file inventory is captured independently before transfer,
bound into validation, rechecked after merging and verified against the backup.
`optimized/` destination derivatives are explicitly counted as regenerable, not
promised bit-for-bit preservation. Descriptor-based traversal rejects unsafe paths,
symlinks and special files; the one known pinned image upload mountpoint symlink is
normalized by the adapter, not enabled as a general follow-symlinks option. Capacity
bounds (including at most 100,000 inventory entries) refuse oversized work. These
checks supplement, rather than replace, existing T2 site-setting preservation.

Trusted migration-data alone receives:

- `data_workflow_contract({})`: actual committed contract and supported engine facts.
- `data_workflow_validate({run, generation, settings})`: registered merge-settings
  input ID, prepared run ID and exact generation; typed private result receipt,
  including offending key path/reason on failure, not scraped freeform logs.
- `data_workflow_exists({run, generation, queries})`: 1–100 exact queries, at most
  64 KiB serialized JSON. A category query is
  `{"kind":"category","path":["Invented Root","Invented Child"]}` with the full
  root-to-leaf path (1–32 components). Group/tag queries use
  `{"kind":"group","name":"Invented"}` or kind `tag`. Each name/component is
  1–256 UTF-8 bytes without control characters. No extra fields or arbitrary SQL.
  Results distinguish `found`, `absent`, `ambiguous`, `unproven`; incomplete
  listings never prove absence. Names use whole-name, case-insensitive matching,
  consistent with core creation uniqueness (including each category ancestor),
  not fuzzy search. `count: 2` means at least two matches, not an exhaustive count.
  Oversized structured output refuses, not truncates.

Engineer equivalents (private output):

```sh
silo-migrate-control standard workflow describe PROJECT
silo-migrate-control standard workflow validate PROJECT --prepared-from RUN --generation SHA --settings INPUT
# Send the queries array on stdin, never private names in argv:
silo-migrate-control standard workflow exists PROJECT --prepared-from RUN --generation SHA --queries-file -
```

These calls grant no Approve, Start, reset or deployment capability. Validation
uses a 180-second monotonic work budget plus a separate 45-second cleanup budget,
inside the trusted tool's 240-second backend timeout. Database cloning may use
that existing remaining work budget (at most 180 seconds), rather than the ordinary
120-second per-SQL cap. Each clone shares the original deadline; it does not receive
a fresh allowance. Other SQL keeps its 120-second cap, also bounded by the remaining
deadline, and cleanup keeps its separate 45-second budget.

Completed failed host calls add private `diagnostics.work` and/or
`diagnostics.cleanup` to the receipt. They contain fixed-vocabulary `step`/`reason`,
`deadline_reached`, and when available `command_outcome` and
`command_timeout_seconds`. Work diagnostics are captured before cleanup, so a
secondary cleanup failure cannot erase the original step. No SQL, command output,
exception messages or credentials are copied. `timeout_or_interrupted` means an
uncertain command outcome, not proof that PostgreSQL stopped. These host diagnostics
are separate from the guest's policy-refusal counters and add no clean projection.
Existing receipts/journals gain no retroactive evidence or recovery authorization.

A timeout or uncertain guest execution is a refusal with quarantined ownership
evidence, not permission to reset or reuse the generation. Large data sets may
exceed this conservative budget and
require an explicitly designed capacity change; the runner never silently retries.
Start's engineer request budget is 295 seconds to accommodate fresh preclaim
validation; this does not change the separate approval or asynchronous run model.

For a large contract, `data_workflow_contract` supplies `contract_file` (area `work`,
relative path, byte length and SHA-256) and, when needed, `contract_omitted: true`.
Read the complete derivative using `data_peek` and its byte-offset pagination;
never invent omitted schema keys. The derivative is private, immutable by digest
and byte-identical to the bound contract. Validation responses expose
`approved_assets_count` rather than a potentially oversized approved-ID list; the
full list remains in the private, digest-bound host receipt.

A reviewed layer may raise `SiloMergeValidation::Finding.new(key_path, reason)`
from preflight for a semantic settings error. The private key path contains only
bounded property-name/index components; reason must be one of
`unknown_source_id`, `destination_exists`, `destination_missing`,
`destination_ambiguous`, `policy_conflict`, `permission_unproven`,
`selection_unproven`, or `schema_unsupported`. Do not put customer values in the
exception message; clean stdout projection excludes the private path.

Existing `data_merge_propose` fields stay unchanged; the host automatically requires passing
process validation for prepared custom proposals. A refusal must not silently
switch to one-shot execution. Validation is bound to the exact prepared baseline,
settings, contract and code; generation alone does not prove a mutable inspection
copy is authoritative. Stale/unsupported/unproven validation blocks execution.

`data_run_evidence` continues to return backend private merge evidence, including
new audit records when present; it does not scrape logs to invent counters.
T7 source counts are authoritative through audit, not widened source connector
grants. T2 preservation already exists: dirty/unproven remains failure, never a
manual fallback to success. Neither private schema paths/settings nor audit values
are automatically projected into clean project info. Clean developer/reviewer
agents receive no new runtime or raw-data tools; release remains a separate,
engineer-reviewed decision.

### Structured evidence when policy preflight refuses

A policy refusal remains a refusal. The runner now asks the same loaded class for
its declared `silo_merge_audit("preflight")` counters after a failed preflight
(and `"postflight"` after a failed postflight). Keep meaningful numeric refusal
flags assigned before raising; do not rely on parsing `SILO_MERGE_AUDIT` log lines.
An already validated preflight audit is reused if a later validation step fails,
without calling the project hook a second time.

Failure collection is best effort, bounded to two seconds for a callback, and
cannot grant a success binding or replace the primary policy refusal. Its private
`failure` envelope contains phase/reason, a bounded exception **class name only**,
`complete: false`, `audit_status`, `counts` and `missing_keys`. It never copies
exception messages/tags, raw settings or undeclared metrics. Status is:

- `partial`: declared numeric observations were captured, possibly only a subset.
- `unavailable`: no eligible audit callback was available.
- `invalid`: callback data or optional telemetry failed schema validation.
- `hook_failed`: the audit callback raised/exited/timed out.

Missing values stay absent/unknown, never synthetic zeros. The layer must report
only observations it actually has; numeric shape validation is not an independent
proof that a layer's business-policy counts are correct. Successful phase audits
still require every declared key. A failed phase is never marked complete merely
because every key happened to be returned.

For class-only validation, read `data_workflow_validate`'s private `audit` and
`failure` fields and its private receipt. Refusal happens without claiming a Merge
run, so it does **not** create a fictitious run or attach a Merge result to an
already completed Prepare. A later Start gate can also refuse before claim; rerun
explicit validation to obtain the current diagnostic receipt, without reset.

For an executed Merge, the trusted `merge.audit_aggregates` evidence block has
`complete: false`, `failure`, and numeric phase values under its nested
`audit_aggregates`. The host stores a private `merge-refusal.json` even when the
ordinary process phase report was never reached. Invalid/multiple frames yield
fixed unavailable/invalid diagnostics, not free-form data or a replacement primary
failure. A successful process carrying a refusal frame is rejected before backup.
Ordinary coder-facing plan/project projections do not gain these private fields.

`write_boundary` is `read_only_clones` for validation, `before_constructor` for
execution preflight and `after_constructor` for execution postflight. These describe
the runner's control flow/connection boundary, **not an OS sandbox or blanket
attestation that arbitrary project code performed no writes**. All existing
settings-preservation, failed/dirty environment and backup gates remain in force.

### Real Rails acceptance and operator rollout

The separately opted-in, invented-data acceptance test is:

```sh
SILO_MERGE_PROCESS_RAILS_LIVE=1 python3 -I -B test/merge_process_rails_live_test.py
```

It requires cached pinned Docker images and about 4 GiB available RAM, creates only
owned disposable resources on an internal network, and never pulls/builds images,
publishes ports or mounts customer data. A missing prerequisite fails when opted in.
It uses real Rails, production read-only provisioning/custody checks, isolated Redis,
stock merger `start`, selective physical transfer, T2 preservation, reference checks
and an actual Discourse backup checked by the host archive validator and engine gate.
Negative cases cover semantic/physical refusal, an execution-digest mismatch before
stock writes, corrupt archive CRC, missing/tampered carried bytes and an excluded
member appearing in the archive. Known typed adapter errors return the fixed
`assets_unproven` reason without relaying private messages or paths; unrelated
exceptions still return `validation_unproven`.

This is **guest composition, not complete host Prepare/claim/release acceptance**.
Host locks, durable validation journal/receipt orchestration, rebake and restore of a
released backup are outside this test. It deliberately constructs an original-only
supported subset, removing inherited boot upload metadata through core APIs before
seeding two source PNGs and a destination baseline. It does not prove support for
synthetic upload identities or unclassified source optimized assets. Never remove
customer records/files or weaken a gate to imitate this fixture.

After the tested commit is published to the installation's tracked delivery branch,
the engineer may use an approved idle window for `sudo silo update`, then
`sudo silo doctor`. Update restarts the web service and interrupts chats: retain
previous-release receipts and a consistent private session/configuration backup.
Verify the installed commit, reload the UI and start a new migration-data chat.
First discover the actual committed contract and validate exact registered settings
against the current ready run/generation. A missing contract/hooks belongs to the
layer owner; unsupported assets need an engine-support decision, not manual repair.
Do not reset/re-Prepare merely for a tooling update, and do not revive an old custom
approval. A customer Merge still requires a new exact proposal, review/approval and
separate Start; neither this test nor source publication grants those permissions.
