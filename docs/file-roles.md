# File roles, source snapshots and correcting assignments

This is part of the pending private-attachment change. It is not a deployment or a
repair of any live project. Native chat references still require the paired
term-llm build in [chat-attachments.md](chat-attachments.md).

## Choose a role, then an association

The Project page's **Files** tab separates these decisions:

| Role | Association | Effect |
| --- | --- | --- |
| Source export / source-site backup | New Development or Launch snapshot | Creates a genuine source version; explicitly makes it current |
| Uploads / assets | An existing source snapshot | Adds files to that snapshot, not another source version |
| Supporting reference | This project | Registers private reference material; does not replace source or Base |
| Base-site backup | A target baseline version | Deliberate independent Base replacement with the existing checks |

Select only files that belong together. Incoming files are not selected by
default. Classifying a mixed batch as a new source is not a way to make documents
available to the agent. A workbook is not a Discourse source backup; source/Base
classification must satisfy the platform's format contract. Early format checks
do not replace the run's full backup, checksum and schema validation.

**New source snapshot** and **Add files to this snapshot** are different actions.
The active Development/Launch source is an explicit pointer, not the newest
arrival. Selecting an earlier valid snapshot as current does not copy the backup
or manufacture another Development version. Plans explicitly selecting an older
valid source retain that selection even if another snapshot later becomes current.

### Supporting references from intake and chat

For an intake XLSX, CSV/TSV or document, select **Supporting reference**, inspect the
preview, then confirm. It is copied into the same project-private registry used by
protected chat attachments. Original intake/registered bytes and provenance are
preserved. There is no migration dataset/version merely because a reference was
registered. `data_supporting_list` and `data_supporting_read` make it available to
migration-data in this project's protected chat; the engineer does not grant the
agent arbitrary host-path access.

References remain untrusted data, not instructions. Formulas are not executed,
external workbook links are not fetched, and supported spreadsheet reads are
bounded. Reading a mapping does not insert it into settings, approve a proposal
or change an existing run. Deliberate settings use still follows registered
settings and exact-plan approval. Coding agents receive only engineer-reviewed
released findings with invented examples, never reference bytes or cell values.

### Uploads are not automatically imported

Multiple archives can belong to one snapshot without replacing its primary
source. The associated input inventory has revisions so prospective plans can
bind an exact set rather than silently acquiring later additions. Changes to a
bound inventory can conservatively require affected pending work to be proposed
and approved again. An unrelated reference does not revise a source inventory.

**Stored—not included by this workflow** is intentional: normal forum review
still defers loose uploads/avatars. Native Discourse merge handles uploads inside
the source's original full backup. Neither assigning a loose archive nor attaching
one in chat adds a new media-import engine or implements Launch execution.

## Correct an incorrect assignment

Use the file's **Manage → Correct assignment** action. For a misclassified source
spreadsheet, choose **Supporting reference**, select the genuine earlier source
to restore as current if appropriate, and supply a reason. Use **Make current**
for an intact earlier source when no file-role correction is needed.

The preview is a read-only description, not an approval. Inspect:

- exact selected file IDs, current and proposed roles and snapshot association;
- the current-pointer changes, including any source being restored;
- affected pending approvals, active work, completed runs and released outputs;
- retained bytes/checksums and the distinction between metadata correction and
  actually rebuilding an output.

Confirming submits that exact preview digest and intent. The host rechecks project
membership, identities, metadata revision and dependencies under the project and
workflow-state locks. A changed file, racing proposal/run or another assignment
can make a preview stale: reload and inspect a new preview rather than blindly
retrying. An affected active run blocks correction; unrelated reference work must
not stop an unrelated run. Only the engineer can confirm these actions; no agent
mutation tool is provided.

Corrections are append-only audit events with actor, reason and before/after
links. Original deliveries/named inputs are provenance, not mutable labels to
erase. Historical plan bodies, consumed approvals, run bindings and released
artifacts stay unchanged. A completed run that used the wrong material requires
explicit reassessment/new work; relabelling does not fix its output. If a completed
run never used the mistaken file, correcting it does not automatically rerun or
reset that run. Removed reference assignments retain private custody/provenance,
not a destructive file deletion.

**Do not use Start over, delete JSON records, relabel the spreadsheet Launch/Base,
or re-upload the original backup as a fake next Development version as an undo.**

Correction targets are reference, uploads/assets or unassigned. An unchanged
original still in intake can be unassigned, then deliberately classified again
with its stable file ID and audit history retained. Taken input dataset IDs are
not silently rewritten, and chat-only references are not promoted into migration
source data: those require an explicitly reviewed original-input registration
path. Soft-unassignment of a chat reference is reversible using its retained
private custody ID. A small file wrongly stored as an asset can be admitted as a
reference from the immutable asset copy, not from possibly changed intake bytes;
reference quotas still apply.

If source/Base classification is interrupted after recording a delivery but
before publishing effective roles, Files exposes that snapshot as **inactive /
incomplete**. Reads do not change active pointers, resume ingestion or create a
new version. Inspect its retained identities and use a fresh, reason/digest-bound
**Make current** preview (including **Make this Base backup current**) to recover.
An untaken Base remains untaken until the existing `data_take type=base_site`
path is requested. This is bounded recovery, not a full transaction journal or
ACID rollback. Only the latest 20 audit events are displayed; older events remain
in the private project history.

Start over/removal are different destructive project operations. Live correction
is a separate operator decision after the reviewed feature is installed and the
actual project's dependency preview has been inspected.

## Backend contract and compatibility

Effective role metadata lives privately in `.silo-migrate/data/file-roles.json`,
separate from original named inputs and delivery records. It records explicit
active pointers, snapshot revisions, effective file assignments and correction
history. New plan digests bind role-aware identities/revisions without adding
private original filenames to coding-agent projections. Pending legacy proposals
that depend on a corrected assignment must be re-proposed; consumed histories
are not retroactively rebound to today's metadata. Projects without this registry
retain their legacy interpretation until role-aware work establishes it.

Engineer-only host operations are `file_roles_preview` and `file_roles_commit`,
through the signed-in Project widget's `/api/files/preview` and
`/api/files/commit`. The server injects the engineer actor and allowlists intent
fields; it does not forward arbitrary host paths, data operations or chat flags.
Existing path/custody and native session/provider gates remain in force. This is
a cooperative trusted-node broker boundary, not new multi-tenant authorization
or global data-loss prevention.
