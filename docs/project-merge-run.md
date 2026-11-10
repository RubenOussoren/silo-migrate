# Merging another Discourse site

A **merge run** brings one Discourse site (the **source site**) into another (the **target**, the customer's sandbox) with Discourse's own merger, `script/bulk_import/discourse_merger.rb`. Nothing is converted: there is no convert run, no intermediate database and no count checks. The run restores the target in a local review site, merges the source into it, takes a full backup and leaves the site up for the engineer to check.

What is specific to one customer (which categories go where, what to skip) lives in a **merge layer**: a small Ruby file that converter-developer writes in the project's converter checkout. The tool supplies the frame; the node's agents write and review the layer.

## What the engineer does

1. Copy two files into the project's drop folder, each with the name Discourse gave it:
   - the **source site's full backup** (`.tar.gz`, with uploads);
   - the **target's backup without uploads** (`discourse backup --sql-only`, `.sql.gz`).
2. As root: `silo intake PROJECT`.
3. On the Project page's Files tab, create the workspace with source platform **`discourse`**. Label the source backup **Development** (or Launch) and the target backup **Base site**. Either can come first.
4. In a chat in the project, ask migration-data to propose the merge. It takes the source backup (type `discourse-backup`) and proposes a merge run on the current Base site.
5. On the Runs tab: read the plan, **Approve**, **Start**.
6. When it finishes, open the merged site through the SSH tunnel and check it. The run shows totals for the Base site before, the source site and the merged site.
7. **Release backup…** copies the merged site's full backup and a manifest to the project's output folder. Nothing is sent anywhere. Restoring it on the hosted migration site is the engineer's step, outside this tool.
8. **Reset the site** when done: it holds customer data until then.

Neither backup is ever extracted, loaded or opened by an agent: only the run reads them. Their file names start with the sites' names, so the page shows the delivery (Development v1, Base site v1) instead.

## The merge layer

Without a layer, the run is Discourse's merger exactly as shipped. To change what it does (route topics into other categories, skip some content, rename on collision), ask converter-developer in its own chat in the project. It calls `dev_merge_guide`, which states the contract and links the stock merger at the server's pinned Discourse revision.

- The layer is `mergers/<project>/merger.rb` in the converter checkout, with any sibling `.rb` files it requires; tests go in `test/mergers/<project>/`.
- It defines exactly **one subclass of `BulkImport::DiscourseMerger`** and overrides its methods, calling `super`. It does not reopen Discourse's classes.
- A run applies the layer **as committed**: the plan names its path, commit, file count and checksum. A later commit makes the plan out of date; propose again.
- Up to 32 regular `.rb` files, 512 KiB in total. Anything else under that folder is refused (`STANDARD_MERGE_LAYER_INVALID`).

**Customer values never go in the layer.** Category names, ids, user names and the like go in a **merge settings** file: migration-data writes a small YAML mapping with a data job, registers it as `merge-settings` and passes it to the proposal. The layer reads it from the path in `SILO_MERGE_SETTINGS`. migration-data tells converter-developer the key names and value shapes in a finding, with invented values; the engineer releases that finding as usual. The plan shows the settings file's text before approval.

The layer may report its own totals by printing lines of the form `SILO_MERGE_TOTAL: name=integer` (a lowercase name written out in the layer's code, up to 20 of them). The run keeps those and nothing else from the merger's output, and shows them to the engineer on the run and to migration-data. converter-developer is told only which commit ran, where a run stopped, the fixed site counts and how many totals were reported: a total's value reaches it when the engineer passes it on. The merge log stays private on the server; migration-data can read its end to explain a failure.

converter-reviewer checks a layer like any converter change, and also that it holds no customer values and moves no data out or sideways: no network, no file writes, no shelling out, no data in totals or error messages. The engineer's approval of the plan is the gate: the plan says which commit of the layer will run next to the customer data.

## What the run does

Stages: preflight, site up, base restore, source load, merge, finalize, verify, backup, site setup, review URL.

- **Source load** unpacks the source backup inside the run's private folder, loads its database as a separate, disposable copy next to the target and migrates that copy to the server's Discourse schema. Uploads come from the backup's own files.
- **Merge** runs the merger (with the layer, if any) with the options the plan shows.
- **Finalize** runs Discourse's consistency, rebake and search reindex tasks.
- **Verify** checks the site is still locked down and that the merge changed no site settings.
- **Backup** takes a full backup (database and uploads) before the review sign-in is added, and checks that every source upload file is in it, byte for byte.

Refused before anything runs: a source site from a newer Discourse release than the server (`STANDARD_MERGE_SOURCE_NEWER`), a file that isn't an original full backup (`STANDARD_MERGE_SOURCE_INVALID`), a project whose platform isn't `discourse`, a project without a Base site, settings that aren't one small YAML mapping.

## What it does not do

- **No automatic count checks.** A merge joins users with the same email, categories and tags with the same name, and identical uploads, so the merged site rarely has the sum. The totals and the engineer's own check of the site are what there is; that is why release always asks.
- **No accept or needs-changes verdict** on the pass yet, and no restore proof of the released backup.
- **The layer's code is not shown on the page yet.** The plan names its path and commit: read it on the branch, and have converter-reviewer check it. The layer can write anything into the merged site (that is its job), and nothing checks afterwards that it wrote only what it should, so that review is the control.
- While the merged site is up it accepts uploads of any file type (the merger needs that). The setting is not in the backup.
- **Uploads stored outside the backup** (S3) are not fetched: the source backup must contain its upload files. The target backup is SQL-only, so the local merged site does not show the target's own uploads.
- **No hosted restore**, DNS or cutover. Those stay with the engineer.
- A failed merge is not resumed: reset the run and propose again (**Run again** on the pass does that with the same source, settings and options, the current Base site and the layer as committed now).
