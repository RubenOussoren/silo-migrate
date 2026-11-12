# Intake references → one exact plan

Engineer flow: **upload once through intake (Files → Supporting reference) →
say the desired outcome → answer material questions or explicitly narrow scope →
review one plan → approve, then Start.** No fifth file role, per-file "use for" grid,
mapping toggles, decision DSL or separate mapping approval. The agent guidance is
the `intake-preparation` skill; this page documents the tool/backend contract.

## What migration-data can do

| Tool / argument | Effect | Needs |
| --- | --- | --- |
| `data_supporting_list` | Active project references (incl. intake-admitted) + this chat's admitted upload refs when the host supplies a manifest | protected session; manifest optional, malformed refuses |
| `data_supporting_take(ref)` | Copy a chat upload into the private registry | protected session + valid upload manifest |
| `data_supporting_read(id, …)` | Bounded sheets/rows/text of a registered reference | protected session only (manifest never forwarded) |
| `data_supporting_prepare(id, …)` | Deterministic table → converter-native file job (below) | protected session only |
| `data_script(…, references=[support-…])` | Existing sandbox job; each reference is a verified read-only copy at `/reference/<id>` | protected session; references optional |
| `data_register` | Unchanged; provenance now also keeps `references` and `preparation_sha256` when the producing job had them | protected session |
| `data_plan_propose(…, run_inputs={…}, preparation={…})` | Convert plan binds a run-input manifest and analyst-labelled preparation metadata | protected session |
| `data_merge_propose(…, preparation={…})` | Native merge binds preparation metadata beside source/Base/merge-settings/layer | protected session |
| `data_master_lists_propose(source, settings, list?, charset?, run_inputs?)` | One `standard_master_lists` plan: the converter's committed exporter on a disposable source copy (mutates staging there); the engineer approves and starts it; CSVs become that run's bound artifacts | protected session |

**Every** migration-data tool (all `data_*` tools above and the four `data_branch_*`
tools) requires the protected session; the "Needs" column lists what each needs in
addition. Without it the adapter refuses before any backend call.

Without the new arguments existing operations retain their request/flag/document
shape **after** the mandatory protected-session check. Unsupported stock hosts now
refuse every migration-data tool before dispatch. Source publication is not native
enablement: coordinate the separately approved generic-native update before using
the release with private data. Chat uploads remain an optional legacy capability,
not required or implemented by the new generic protection build; use intake.

### Deterministic preparation (`data_supporting_prepare`)

Projects one bounded table region of an XLSX sheet or CSV/TSV reference into the
format the converter's own contract expects. It is a column projection, not a
language: `columns: [{from: exact header, to: field, type: string|integer|boolean,
required}]`, `format: csv|json|yaml`, `shape: rows|map` (map = two columns, unique
key; JSON/YAML only), `name` (matching extension), `header_row`, `max_rows ≤ 10000`.

- Runs as a normal data job (`kind: prepare`) in the control image: no network,
  read-only root, no `/in` delivery mount, no gem cache, 5-minute limit. The
  reference is a checksum-verified per-job copy (custody files are never mounted);
  the copy is deleted when the job finishes or is found lost.
- Uses the existing bounded `supporting_reader` parser. Headers are matched in the
  first 100 columns; a header row using column 101+ refuses
  (`PREPARE_HEADER_TOO_WIDE`). Short rows are padded with empty cells by that reader. Formula and error cells,
  missing/ambiguous headers, non-integer/boolean values, empty required cells,
  duplicate map keys and more rows than `max_rows` refuse with a fixed code (and
  row/column indices), never cell text. Fully blank selected rows are skipped and
  counted. Raw stored numbers/dates are kept as text; nothing is evaluated.
- Same spec + same bytes → same output bytes. The job records the normalized spec,
  its SHA-256, the reference ID/digest/size and the preparer code digest
  (`supporting_prepare.py` + `supporting_reader.py`) as `script_sha256`.
- Then `data_peek` the output and `data_register` it: type `mapping` (or
  `run-input`), named as the converter expects, or `merge-settings` for a merge.
  Anything that needs logic uses `data_script` with `references`.
  Engineer-supplied prepared files/manual exports continue through `data_take`.

## Plan backend contract

Backend: `lib/silo_migrate/services/standard_run_inputs.rb` (`standard plan propose …
--run-inputs FILE --preparation FILE`, bounded 64 KiB JSON; it owns validation,
digest binding, materialization, evidence capture and display). The Python side
accepts inline objects from the agent, completes them from this workspace's own
records, writes each to a private `0600` file under
`.silo-migrate/data/plan-documents/`, passes its path and removes it after the call.
The agent never supplies paths.

`run_inputs` (convert only). Agent gives `consumer.setting`, `files[{name, input_id}]`,
optional `absent_defaults`/`generated`. Python adds `version: 1`,
`consumer.platform` (workspace platform), `source_sha256` (the plan source's
registered digest) and per file `sha256`/`bytes` from named state (a mismatching
agent value refuses). Files must be registered inputs of type `run-input` or
`mapping` and not Base-site roles. **Lineage is computed, never accepted**: from the
input's `derived` provenance record and producing job →
`lineage.preparation = {job, tool (data_supporting_prepare|data_script|data_extract),
script_sha256, preparation_sha256 (prepare jobs: the normalized spec digest)}` and
`lineage.references = [{file_id, sha256}]`, where `sha256` is the digest of the
snapshot the job actually read and must equal the reference's current registered
digest (otherwise refused), for each reference the
job read. Inputs taken directly (manual exports) carry no lineage.

`files` may be empty (every optional file at its converter default, e.g. Khoros with
only the generated `trust_level_mapping.yml` expected): the plan still binds the
consumer setting and source digest, and the run gets a fresh empty writable
directory. Nothing is synthesized: no placeholder or header-only input is created.

A file normally must belong to the plan source's own dataset. To bind one registered
in another delivery, the file entry declares `reuse: {dataset_id, source_sha256}`
(that dataset, and the digest of the source registered there that it was prepared
against). Both the agent and the engineer path accept it; Python checks its shape
and passes it on, and the backend decides applicability against the plan's source.

**Contract check:** `test/intake_preparation_test.py`
(`test_ruby_backend_accepts_the_adapters_plan_documents`, opt-in with
`SILO_RUBY_CONTRACT_IMAGE=<local Ruby image>`) builds the documents through the real
Python path (reference → prepare job → register → propose), then runs
`test/support/run_inputs_contract.rb` in a no-network, read-only container, which
applies the backend's own `run_inputs_binding!`/`preparation_binding!` and
`FileRoleStore` to the same workspace (only the converter-settings git lookup and the
delivery lookup are stubbed).

`preparation` (convert and merge). Agent gives `analyst.text`, `references`,
`outcomes`, `questions`, `exclusions` in the backend schema. Python sets
`version: 1`, fixes `analyst.label` to "migration-data analyst (interpretation, not
evidence)" and turns each reference `{support_id}` / `{file_id}` / `{input_id}` into
`{file_id|input_id, sha256}`. A `support_id` must have exactly one reference entry
in the persisted Files registry (`file-roles.json`), which is what the backend
rechecks: intake-admitted references always do; a chat-only attachment does after
the engineer's next Files role change. Code readiness is computed by the backend.

**Who may submit them.** Model-facing calls (the fixed adapter always sets
`via: chat`; the model cannot choose or drop it) need the protected session for
`run_inputs` and `preparation`, and may not supply lineage. The engineer's own
proposal from the Project page or a shell (no `via`, e.g. **Run again**) is the
trusted signed-in path and needs no native chat context; it may resubmit a plan's
bound form (`sha256` on references, `lineage`, `mount`, `writable`), but every
reference digest must still be current and every lineage must equal what the
workspace records say now, otherwise it refuses. Reader/preparer/script tools keep
requiring the session on every path.

Plans without these keys keep exactly their previous arguments, body and digest;
review (`from_run`) plans refuse both keys.

## Protected-session context (generic core contract)

The separately reviewed generic native build (`term-llm capabilities --json` →
`session_scope_lock: 1`, `custom_tool_session_context: 1`) strips inherited reserved
values and rejects per-tool configuration of them. Only an admitted locked run gets
`TERM_LLM_PRIVATE_SESSION=1` and `TERM_LLM_SESSION_ID` (its own native session ID).
`TERM_LLM_UPLOADS_JSON` is reserved but **never emitted** by this generic build;
chat upload plumbing is outside scope. Intake references do not need a manifest.
The adapter has two parsers:

- **session proof** — marker `1` and a valid session ID, required by every gated call.
  Unsupported stock hosts refuse with `STANDARD_SUPPORTING_NODE_UPDATE_REQUIRED`
  before any backend call. The installer refuses their private-tool enablement.
- **legacy upload manifest** — needed only to take an upload; shown by list when
  present. A present-but-malformed manifest refuses every gated call. Readers,
  preparation and plan citations never receive it. The old attachment package is
  historical, not a way to satisfy the new capability gate.

Actual local tests against the reviewed generic binary use an isolated temporary
HOME, invented data and loopback fake providers: normal engineer intake → new locked
migration-data chat → own-project list/read and real sandbox preparation, with zero
forbidden-provider dispatch. The old chat-upload test deliberately skips when the
host lacks that separate legacy capability. These are not deployed-node tests.

The host and same-account operator remain trusted. This is not OS isolation or
universal data-loss prevention; tool permissions must independently constrain egress.

## Uniform gate, search and DBHub

- **Uniform tool gate.** Both fixed adapters (`scripts/data_tool.py`,
  `scripts/dev_tool.py`) refuse every tool unless the host supplied the private
  marker and a valid session ID (and, if present, a well-formed legacy upload
  manifest). Context reaches the backend only for references/preparation, where it
  is rechecked. Model JSON look-alike keys are dropped. The gate is in the adapters,
  the only chat entry; trusted engineer/shell paths (`via` absent) are unchanged.
- **No web search.** `migration-data` has `search: false`. Public research belongs
  in a separate clean chat with generic questions; the engineer relays public facts
  only. The generic native build clamps the locked agent's setting so request/UI/
  host defaults cannot re-enable it. Actual offered-tool tests show neither
  `web_search` nor `read_url`. Older unsupported stock hosts did not enforce this
  and are blocked by the native gate. This cannot stop an engineer pasting customer
  values into a different chat.
- **DBHub (free SQL over MCP).** MCP servers don't receive custom-tool session
  context. DBHub is enabled only when the installer-managed, account-owned control
  config (`SILO_CONTROL_CONFIG`) literally contains `SILO_PROTECTED_SESSIONS=1`;
  inherited values are never consulted. Same-account operator writes remain trusted.
  The file must be regular, single-link, non-group/world-writable, bounded and
  unchanged while read. Without the grant `data_db_up` does not register the server
  and removes an existing entry, and `silo-migrate-control dbhub WS` refuses to start
  (including stale `mcp.json` entries). The installer verifies native capabilities
  before project wiring, clears the grant before native selection/early failure,
  restores the previous binary after an incapable replacement and grants only after
  final host/agent checks. An unlocked rollback removes the literal for older control
  parser compatibility. A capability failure refuses before release selection;
  an invalid old grant is revoked, not left true. Doctor reports project-server
  **counts** as FAIL without native protection; diagnostics never change configuration.
- **Auxiliary calls.** Auto titles stay disabled in fresh node config. The generic
  native lock keeps titles/classification within its saved model policy, skips
  locked memory mining/freshening and suppresses transcript debug logging. Side
  questions, manual compaction, summarized branch notes, cross-model handovers,
  Hub delegation and MCP sampling refuse locked conversations. Automatic compaction
  uses the admitted model. Direct ask/loop/chat TUI and progressive runs refuse
  locks because they do not use the protected per-turn runner.

## Host boundary

The wrappers fix `via: chat`, derive the workspace from the chat's project folder
and forward only each tool's listed keys; the control backend trusts that JSON from
its host. This is a host/process convention on one service account, **not OS
isolation**. Coding agents (converter-developer/-reviewer) have no shell/file tools
and only the `converter dev WS --role <fixed>` route (source-tested). The
`server-support` agent does have `shell`, `edit_file` and `write_file` on that
account: it is a trusted operator agent outside this boundary and could reach
workspace files directly.

## Deployment compatibility (coordinate core and Silo installs)

This Silo source **requires** the protected-session native host for every
migration-data tool. Unsupported hosts refuse the release update before enabling
private tools; there is no stock fallback. Files/Runs in the Project page remain
engineer-controlled. The separately approved deployment must verify the reviewed
native build, this Silo release and the final DBHub grant, then start a **new**
migration-data chat per project. No installed binary/configuration/service was
changed by this source implementation.

The current source receipt, `runtime/private-node-source.json`, binds
`integrations/term-llm/patches/conversation-scope.patch` to upstream base
`70523473fa89952f8312be6136a92c51ffae1f4c` (version `0.9.103`). Build/test that exact
source and preserve provenance, then use `script/private-node package` / `verify`
from a private custody-safe source/artifact directory outside customer storage.
The package helper checks ELF structure, exact source/hash receipts, capability,
version and CLI support using sealed bytes and disposable HOME/XDG probes. It does
not install anything. Transfer, service-account custody handoff, installed config,
selection and service restart remain subject to separate deployment approval.
The custody rules in the historical [attachment documentation](chat-attachments.md)
still apply, but its old patch/version/capability instructions do not.

## Compatibility verification and remaining gates

Local fake-provider tests cover protected intake/preparation, own-project IDs,
forbidden-provider non-dispatch, restart/config widening refusal, allowed continuation
and branching, child native identity and ordinary unlocked provider routing. The
core suite also covers reserved-environment impersonation, auxiliary refusals,
stored policy/database invariants, search clamping and debug suppression. Repeat
these checks on any future candidate upstream build before claiming equivalence.

Project Files/Runs rendering, exact preparation review and scoped Khoros master-list
export are implemented; they are not pending worker tasks. Uniform gating and the
search change are implemented under the approved source scope, not proposals.
Remaining gates are separately approved package transfer/installation/restart,
invented-data acceptance on the actual node, then separately approved real
provider/customer-data work. No deployed-node or customer acceptance is implied.
