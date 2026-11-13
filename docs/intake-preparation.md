# Intake references → one exact plan

Engineer flow: **upload once through intake (Files → Supporting reference) →
say the desired outcome → answer material questions or explicitly narrow scope →
review one plan → approve, then Start.** No fifth file role, per-file "use for" grid,
mapping toggles, decision DSL or separate mapping approval. The agent guidance is
the `intake-preparation` skill; this page documents the tool/backend contract.

## What migration-data can do

| Tool / argument | Effect | Needs |
| --- | --- | --- |
| `data_supporting_list` | Active references from this project's intake registry | current project registry; no native context |
| `data_supporting_read(id, …)` | Bounded sheets/rows/text of a registered reference | current project registry |
| `data_supporting_prepare(id, …)` | Deterministic table → converter-native file job (below) | current project registry |
| `data_script(…, references=[support-…])` | Existing sandbox job; each reference is a verified read-only copy at `/reference/<id>` | references optional |
| `data_register` | Unchanged; provenance now also keeps `references` and `preparation_sha256` when the producing job had them | current project/workspace |
| `data_plan_propose(…, run_inputs={…}, preparation={…})` | Convert plan binds a run-input manifest and analyst-labelled preparation metadata | current project/workspace |
| `data_merge_propose(…, preparation={…})` | Native merge binds preparation metadata beside source/Base/merge-settings/layer | current project/workspace |
| `data_master_lists_propose(source, settings, list?, charset?, run_inputs?)` | One `standard_master_lists` plan: the converter's committed exporter on a disposable source copy (mutates staging there); the engineer approves and starts it; CSVs become that run's bound artifacts | current project/workspace |

Every migration-data tool uses the fixed adapter's project routing and argument
whitelist. No experimental native context is required. Native chat-upload import
is deliberately not advertised: use the same intake-first flow for all references.

### XLSX hyperlinks are inert metadata

Ordinary external hyperlink relationships are ignored, never followed or resolved.
Their presence alone does not block reading sheet names or literal cell values.
A successful XLSX read includes `ignored_external_hyperlinks` only when nonzero;
it is a whole-workbook count (including other sheets/parts), not a list of targets,
hosts or URLs. No relationship target metadata
is returned. URLs written as literal cell text remain ordinary untrusted cell data.

This is not permission to import external data: external worksheet/shared-string/
workbook-data relationships and unknown external relationship types still refuse.
Archive target/path validation, XML/DTD/entity and expansion limits, macro/binary
refusals, formula non-evaluation and no-network sandboxing remain unchanged.
Ignored links neither prove that linked content is in the file nor resolve a
migration ambiguity. The parser has not visited those links.

Internal OPC references such as `../drawings/drawing1.xml` are resolved relative
to the source part, entirely inside the ZIP namespace. Every resolved target must
exist in that archive; attempted package-root escape, filesystem/network/encoded
URI ambiguity and directory targets still refuse. Archive member names themselves
remain strict: dot-segment ZIP entries are not admitted. This is not a general URI
resolver or permission to ignore data relationships.

If a registered reference is visible but refused, do not move it between source
deliveries, Make-current a different dataset, re-export or mutate its bytes merely
to bypass the reader. A refusal may append `reader_line=N; part_kind=...` to the
original fixed error code. These are a **public parser source line, not a workbook
row**, and a fixed package-part category, not the actual ZIP filename or sheet
name. No exception text, target URL/host, path or cell contents are included.
Report that bounded diagnostic and the installed Silo release (`silo doctor`);
source locations must be interpreted against that exact release. A generic
`INVALID_DOCUMENT` alone does not establish the presence of macros, external data
or a particular hyperlink. Do not request the private workbook or finding merely
to diagnose this reader. Existing references need not be re-admitted for updates.

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
`via: chat`; the model cannot choose or drop it) use the chat's project and may not
supply lineage. The engineer's own
proposal from the Project page or a shell (no `via`, e.g. **Run again**) is the
trusted signed-in path; it may resubmit a plan's
bound form (`sha256` on references, `lineage`, `mount`, `writable`), but every
reference digest must still be current and every lineage must equal what the
workspace records say now, otherwise it refuses. Reader/preparer/script tools keep
using the same workspace/path and digest validation on every path.

Plans without these keys keep exactly their previous arguments, body and digest;
review (`from_run`) plans refuse both keys.

## Stock term-llm support

The supported host is the official, unmodified **term-llm 0.9.103** release, pinned
by version and archive checksum in `script/metal`. No fork, capability command,
`lock_session` key or custom native package is required for intake references,
preparation, script references, plan citations or the ordinary migration-data tools.

The fixed adapters derive the workspace from the web project's working directory,
fix `via: chat` and forward only listed arguments. They do not accept a model-supplied
workspace, route or native session proof. Historical `TERM_LLM_PRIVATE_SESSION`,
`TERM_LLM_SESSION_ID` and `TERM_LLM_UPLOADS_JSON` values are ignored and removed from
child environments, not treated as credentials or fabricated on stock hosts.

References enter through **Project → Files → Supporting reference**. Listing and
reading use that workspace's private registry; preparation gets checksum-verified
copies in its existing confined sandbox. Chat-upload taking is not supported:
`STANDARD_SUPPORTING_USE_INTAKE` means use Files, not install a fork or set a marker.
Historical reference custody/provenance is retained; missing native chat IDs are
not invented.

## Retained boundaries and explicitly deferred protections

- `migration-data` retains its Frontier-only `allowed_models`. Stock term-llm's
  ordinary agent/model checks apply; they are **not a permanent conversation lock**.
  Restart/retarget/config-widening privacy guarantees are deferred.
- Both adapters retain fixed project/workspace routing, argument whitelists and
  scoped branch-reader operations. Broad analyst host-shell/file tools are not added.
- Custody, digest rechecks, source/Base roles, run-input lineage, no-network/read-only
  sandboxing, parser/formula/size/disk limits, exact plan review, approval and separate
  Start remain enforced. Deferring conversation locking does not relax these gates.
- `search: false` remains a preference. Stock web-tool availability must not be
  described as enforced DLP. The real 0.9.103 acceptance run still offered
  `web_search` and `read_url`; no external requests were made. Do not put
  customer-derived values in web requests;
  keep public research in a clean chat. Initial acceptance uses invented data.
- DBHub no longer requires the experimental `SILO_PROTECTED_SESSIONS` grant. It still
  requires the stock-supported `mcp.servers.NAME.agents: [migration-data]` rule and
  trusted installed agents; query sessions remain read-only. This is agent-scoped,
  not a customer/project authorization boundary: enable only the current project's
  server. Doctor reports misconfigured rules without editing them.
- The service account/operator and server-support's root-equivalent Docker authority
  remain trusted. This is not OS isolation or universal data-loss prevention.

The stronger generic native lock/context work is parked for later. Its branch,
patch and historical tests remain in Git history; they are not prerequisites for
this stock workflow and no equivalent privacy attestation is claimed.

## Updating an existing stock node

Use the normal `sudo silo update` on an installer already tracking
`mvp/metal-installer`, during an approved idle maintenance window. The release pins
and checks the official binary; existing 0.9.93/0.9.99 version settings are recognized
as older pins. Keep `TERM_LLM_PACKAGE` empty/unset; it is not needed. If a previous
experiment explicitly configured a package, review that configuration before
returning to stock rather than silently ignoring it.

Existing control-runtime artifacts, provider configuration and workspaces are
preserved and verified; the native helper package is not the runtime artifact
package. No host Go/Node compiler install or fork-package transfer is needed.
The ordinary update restarts the web service and interrupts chats. Use a **new
migration-data chat** after updating so the current tool definitions are selected;
do not edit old session rows, fabricate context or delete locks to retrofit them.

## Acceptance and remaining gates

Run stock-host acceptance with `STOCK_TERM_LLM_BINARY` pointing to the verified
unmodified official release and `SILO_SUPPORTING_LIVE=1`: normal Files intake →
list/read → real sandbox preparation, with no native context and forged legacy
variables ignored. These tests measure the ordinary model-policy control and
report web-tool availability; they do not attest durable conversation privacy.
Backend/contract and browser tests cover registration, exact plan review and the
separate Approve/Start workflow. Chat drag/drop import remains deferred.

Source verification/publication does not authorize a server update/restart or
customer-data access. After deployment approval, start with invented data on the
actual node. Revisit durable conversation isolation separately once the full flow
is accepted; do not describe it as implemented by stock configuration.
