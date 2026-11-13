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
returning exactly true after policy validation. Stub tests do not prove private
mapping correctness, actual core compatibility or resulting permissions.

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
