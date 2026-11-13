# Private chat attachments and supporting reference files

> **Historical attachment-fork contract only.** The current supported workflow uses
> official, unmodified term-llm and [Files intake](intake-preparation.md), with no
> custom native package or session marker. Chat drag/drop import and stronger
> conversation protection are deferred. Do not use the package/version/capability
> installation instructions below for the stock release. Original source and test
> history are retained in Git; no equivalent stock privacy guarantee is claimed.
> Server changes and customer-data work remain separately approved operations.

## Intended workflow

Use a **new migration-data chat in the correct Project**, on a node with the paired native support described below. Attach a small file with the normal term-llm attachment control and explain its purpose, for example: “Use this spreadsheet as reference for the category mapping.”

The agent calls:

1. `data_supporting_list`: current chat's admitted upload refs plus this project's previously registered supporting files.
2. `data_supporting_take(ref=...)`: copy an admitted upload into the project's private supporting registry, retaining original bytes, checksum, filename and chat provenance.
3. `data_supporting_read(id=..., mode="sheets")`, then `mode="rows"` with an exact sheet name and bounded offset/row/column counts. For supported UTF-8 reference text, use `mode="text"`.

A supporting file is **not** a Development/Launch/Base delivery, registered migration input, converter setting, reconciliation check or approval. Attaching or reading one does not replace the source/Base, stale a plan, change a converter, start a job/import or approve a run. To use a reference to make migration decisions, the engineer and migration-data must still deliberately produce/register the appropriate settings and obtain ordinary plan approval. Large dumps and original Discourse backups continue using normal intake.

## Supported content and limits

- XLSX: sheet names and bounded row/cell values, including shared/inline strings, sparse rows, booleans and raw numbers/dates. Excel display formatting and serial-date conversion are not inferred.
- CSV/TSV: bounded rows, quoting and UTF-8 BOM handling. Delimiters are inspected locally; fields remain strings.
- TXT, JSON, YAML/YML and Markdown: a bounded UTF-8 text preview, not evaluation of their contents.
- Other files can be retained as private references, but unsupported readers/formats return a fixed refusal. PDF/OCR, legacy XLS, encrypted workbooks and complete Excel rendering are not part of this first version.
- **Formulas never execute.** XLSX formula cells are marked as formulas, with null values; neither formula text nor a cached result is treated as verified data. CSV fields starting with `=` remain literal text, not evaluated expressions.
- External relationships, macro/binary workbook parts and unsafe XML/archive structures are refused. No external link is fetched. No workbook/CSV content is an instruction or permission to change a run.
- File limit: 20 MiB. Registry quota: 100 files / 200 MiB per project. Native tool context: at most 32 admitted file refs / 64 KiB metadata. Reader defaults: 20 rows / 20 columns; maxima: 100 rows / 50 columns, bounded scan and 32 KiB JSON result. Large requested ranges return a refusal rather than misleading truncated JSON.
- XLSX archive limits also bound member count, each member, total expansion, XML depth/node count, shared strings and cell lengths. Unusual but valid documents can be conservatively refused; simplify the workbook or export a CSV rather than bypassing validation.

## Privacy and custody

Registered references live in `<workspace>/.silo-migrate/data/supporting/`, with private 0700 directories, 0600 registry records and immutable 0400 file copies. Original node uploads remain unchanged. No unattended deletion or cleanup policy is added.

The fixed adapter has no model-selectable workspace/session/path argument. The native tool host supplies a reserved session ID, a bounded admitted-user-upload manifest and a private-session marker; inherited variables, per-tool environment entries and model JSON cannot override them. The backend reopens only the fixed node-upload root using directory descriptors, rejects symlinks/non-regular or unsafe files, verifies identity during copying, and hashes the actual bytes. Reading a registered file takes and verifies a separate immutable snapshot.

Spreadsheet parsing uses the existing checksum-qualified control image and a fixed stdlib-only reader in a non-root, no-network, read-only, resource/time-limited container. Only the chosen reference snapshot and clean reader source are available; delivery input folders, credentials, Docker socket and gem cache are not mounted. Exact named reader containers are removed and absence checked. There are no new database/runtime image selections.

`migration-data` remains Frontier-only and now opts into native `lock_session`. The effective model-policy chain, agent identity and project workspace are sticky in the durable conversation, including forks. Retargeting a protected conversation to another agent/provider/project is refused before provider dispatch; durable continuation requests may instead ignore wire overrides and retain their already-admitted Frontier runtime. Compaction also checks the saved policy. Debug/raw provider logging and progressive runs are refused for locked sessions. Locked agents require the native runner: interactive TUI chat/handover is currently refused rather than silently weakening the boundary.

Existing pre-lock conversations are not silently retrofitted: start a **new** migration-data chat after installing the paired build. Project-registered supporting files remain available to later migration-data chats in that same project. Upload refs are limited to structured user attachments still admitted in that chat's active context; arbitrary file mentions, tool/assistant outputs and approval-only history prefixes are not new upload capabilities. Register needed references promptly; compaction can remove old attachment context.

Do not attach customer files to coding chats or manually forward/copy their contents there. The lock prevents automatic retarget/replay of the protected conversation; it cannot prevent an authorized engineer from deliberately copying data into an unrelated new conversation. Ordinary text attachments may also be represented in Frontier's chat by term-llm's existing file transport; only the fixed spreadsheet reader's output has the row/cell bounds above. Customer values reach coding agents solely through the existing engineer-reviewed finding release workflow.

This is a trusted, single-account operator/broker boundary, not a new multi-tenant OS sandbox. Authenticated node operators already have broad node authority. Keep auto titles disabled as in the shipped fresh node config, and do not add unapproved memory/auxiliary provider routes. No real provider/model or deployed-server acceptance is implied by local fake-provider tests.

## Intake files, snapshots and corrections

The Project page uses **file roles**, not Development/Launch as catch-all labels.
For an intake spreadsheet or document choose **Supporting reference**: the engineer
admits it into the same private registry as chat attachments, without creating a
source dataset/version. In a protected migration-data chat, `data_supporting_list`
then shows it with other project references. Reference admission does not weaken
the native session gate or allow arbitrary host paths in chat tools.

Source backups create explicit Development/Launch snapshots; loose uploads attach
to an existing snapshot instead of replacing its source. The active source is
explicit. **Manage → Correct assignment** previews dependencies and requires an
engineer reason and digest-bound confirmation; originals and completed run/release
history are retained. See [file-roles.md](file-roles.md) for the workflow, correction
limits and legacy behavior. Loose uploads are **stored—not included** by normal
forum review; native Discourse merge uses uploads inside the original full backup.

## Paired native build and packaging

Stock term-llm **0.9.99 does not implement these new interfaces**. A tools/YAML-only update is insufficient. Supporting tools fail closed with `STANDARD_SUPPORTING_NODE_UPDATE_REQUIRED` when the protected context is absent; do not work around this with raw paths, generic filesystem tools or a coding provider.

### Persistent `STANDARD_SUPPORTING_NODE_UPDATE_REQUIRED`

This refusal comes from the Python tool adapter before it calls the project
supporting-file backend: the native tool host has not supplied a valid protected
session marker, session ID and upload-context manifest. Successful unrelated tools
or an up-to-date Silo release do not establish that native support is installed.
There is no separate supporting-file service/package to restart independently:
the paired term-llm host supplies context to its fixed tool subprocess.

Ask the operator for sanitized `silo doctor` capability results and the selected
service-account binary's `--version` and `capabilities --json` output. A warning
about private attachments confirms the checked binary has not demonstrated the
required capabilities; it does not provide its exact build stamp or establish
whether project references exist. Fix/verify the paired package using the custody
and approval procedure below, not another ordinary stock update or an environment
variable forged into a tool call. Installation/update restarts the web service.
After verified installation, use a **new migration-data chat in the same project**;
a new chat alone cannot fix a missing binary, and pre-lock chats are not retrofitted.

Files-tab admission/correction and protected chat reading have separate gates.
A successful admission may already have preserved reference custody even while
chat tools refuse. Do not infer absence, automatically re-admit, or relabel a
reference as source just to read it. Establish the capability first, then inspect
project reference metadata through the protected tool path under the appropriate
customer-data approval. Use invented data for node acceptance before customer reads.

The historical attachment patch is `integrations/term-llm/patches/private-attachments.patch`; its original base/hash are retained in Git history, not the current source receipt. `runtime/private-node-source.json` now binds the generic `conversation-scope.patch` described in [intake-preparation.md](intake-preparation.md). The following attachment capability/build instructions are historical and cannot be used with the current package helper. Native capability reporting itself can be checked without inference:

```sh
term-llm capabilities --json
```

Required fields are `private_upload_context: 1` and `session_scope_lock: 1`. `silo doctor` reports **private chat attachments** as OK only when those capabilities are present; an ordinary 0.9.99 node reports a warning and should continue using intake.

For release preparation, build/test the paired Linux/amd64 binary from the pinned clean source plus this patch; preserve its build/source evidence. Then package it outside Git/customer storage:

```sh
python3 -I -B script/private-node package /PRIVATE/ARTIFACT/node-package --binary /PATH/TO/TESTED/term-llm
python3 -I -B script/private-node verify /PRIVATE/ARTIFACT/node-package
```

This creates an executable, manifest and SHA256SUMS. Checksums detect changed bytes; they do not establish an unreviewed binary's origin. The publisher/operator must deliberately approve the build provenance and exact package. Do not package or download a binary from a customer workspace.

The helper rejects package, input binary and installation destinations inside the workspace or intake roots. Its CLI reads those roots from the literal metal config (`--metal-config`, default `$SILO_METAL_CONFIG` or `/etc/silo-migrate/metal.conf`), and also honors `SILO_PREFIX` / `SILO_WORKSPACES` location exclusions. When preparing a package for a custom config, pass `--metal-config /absolute/path/to/metal.conf`; additional customer locations can be excluded with repeatable `--customer-root /absolute/root`. No shell evaluation or customer-file inspection occurs. The installer passes its actual configured workspace and `<prefix>/intake` roots directly to the helper.

Every directory ancestor must be owned by root or the account running the check and not group/other-writable; symlink components are refused. The sole shared-parent exception is a root-owned sticky directory (such as `/tmp`): other users cannot replace this custodian's child there. Files must be single-link regular files with the same ownership/write restrictions, without setuid/setgid bits. Existing directories are never chmodded/chowned to make a check pass. Use a dedicated private artifact/release directory, not a customer-writable or foreign-account build tree.

**Root-to-service handoff:** root-side package inspection explicitly accepts the configured service UID as intended custodian, but is not proof that the service account can traverse/read it. Before the separately approved installer run, the operator must explicitly hand off the package and its private directory to the intended service account (or make root-owned ancestors traversable and files readable without allowing other users to write). A root-private `0700` ancestor remains inaccessible and is refused when the installer repeats verification as the service account, before selecting the binary. No automatic permission repair occurs; the helper accepts only root/current-account ownership, not an arbitrary publisher UID.

The helper validates ELF64 little-endian Linux/amd64 headers, entry/load segments and bounds **before execution**; scripts, truncated files and wrong architectures are not packages. Capability, version and required service/serve CLI probes run against an executable **sealed anonymous Linux memfd** containing the verified bytes, passed as a held descriptor. They never reopen the supplied source/destination executable pathname. Package reads and destination writes use held, custody-checked directory descriptors. Existing destination reuse additionally requires identical binary bytes, executable permission and exact `binary.sha256` / `private-node.json` receipts; missing or modified receipts are refused, not regenerated.

After publication and explicit deployment approval, stage the exact package privately on the node, readable by its service account, outside intake/workspaces. Set the literal `TERM_LLM_PACKAGE=/absolute/private/package-directory` in the root-managed metal config. The installer checks source/patch identity, binary checksum, native capability probe, version and required service CLI flags, uses a separate `0.9.99-private-<source-sha256>` directory (SHA-256 of canonical compact JSON containing the complete `version`, `base_commit` and `patch_sha256`) and retains the previous binary for rollback. It does not compile, download dependencies or change the official 0.9.99 checksum receipt. Even when that directory is already selected, an update revalidates the explicitly configured package, installed bytes, receipts, capability, version and CLI checks before returning unchanged. A refusal never falls back to stock or changes the binary symlink/service. Same patch on a different base commit selects a different directory, leaving the previous binary available for rollback. The normal update/service lifecycle remains operator-controlled.

An interrupted **new** installation may leave a never-selected variant with missing
receipts. It is deliberately refused on retry rather than repaired in place. Keep
the active and previous binary links unchanged; an operator must first inspect
those links, the exact selected package and the partial directory. Only after
confirming the directory was never selected should a separately authorized
maintenance action quarantine that partial variant and retry the same reviewed
package. Do not remove or overwrite an active/previous variant to make checks pass.

Without this explicit package, the existing official-download path/intake workflow remains unchanged and private supporting tools remain unavailable. Changing/removing the package setting is a deliberate binary selection, not a mechanism to unlock a protected conversation. A source patch alone is not a published or installed package. No package transfer, service restart, node update or customer-file test is authorized merely by these instructions.
