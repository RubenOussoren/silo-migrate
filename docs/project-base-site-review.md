# Review on a Base site

The **Base site** is the customer's sandbox, before the source data is imported. The engineer takes a Discourse backup **without uploads** (`discourse backup --sql-only`), keeps its original file name, copies it into the project's drop folder and hands it over with `silo intake PROJECT`.

On the Project page's **Files** tab, select that one file and choose **Base site**. The page checks only its SQL-only backup name, gzip signature and regular-file identity (not SQL contents or every gzip member), and labels it **Base site v1** (then v2, and so on). It is separate from Development and Launch data: neither label changes the other. Once the workspace is ready, labelling also moves the original bytes into `inputs/`, read-only, and registers them as `base_site`. The page offers labels only once the workspace exists (the engineer creates it on the same tab: source platform, then **Create workspace**), so the source data can be labelled Development first and the Base site added whenever the sandbox backup arrives; neither waits for the other.

The Base site is readable by migration-data but is not a source export. Never load it into the source database or use it as converter settings or count checks. On a base site, destination checks must count imported rows, not whole tables. A source user merged by email into an existing sandbox account gets no import id: reconcile new imported users plus users merged into existing accounts against source users. Sandbox system and staff accounts remain unchanged.

## Automatic Discourse version selection

The engineer does not select images or edit runtime profiles for normal review runs:

- **No Base site:** a fresh review uses the current supported public `latest` build.
- **Base site supplied:** the tooling prefers its version and release track. It also compares the backup's migration IDs with the exact/current public builds' core inventories, so identical version strings do not hide missing core migrations. If necessary it selects a compatible newer build on the **same track**, never silently an older build or another track. Unknown/plugin-only migration IDs remain warnings; the tooling does not reproduce the hosted plugin stack.
- **Replacement Base backup:** label and take it normally, then propose/import again. Resolution runs again, even when the version string is unchanged. Pending plans bound to the earlier Base become stale. Existing runs/evidence retain their original runtime; reset the old review site explicitly when it is no longer needed. No running database is upgraded in place and no unrelated project is upgraded.

On an installed node, first-time preparation runs as one bounded, on-demand host worker. It pulls only the fixed public Discourse repository and builds the fixed importer overlay with no customer build context. The review site itself still has no outbound network. The Project page waits automatically and shows a preparation message; an agent tool may return `runtime_preparing`, in which case migration-data polls the same proposal after a short wait. No import starts during preparation. Ordinary approval and Start are still required.

Prepared images are cached and pinned by identity before approval. Public selector results are refreshed on demand (at most 15 minutes of request reuse); a changed Base version or migration inventory creates a new preparation request. No scheduled refresh/service is installed. Runtime preparation is checked for review/merge use (`review_ready`), **not** claimed as full historical synthetic-workflow qualification. The workspace's converter/control/database images and original profile are unchanged.

The plan shows the chosen Discourse version/track and image/core identities under Details. The run records the actual running version, schema observations and resolved image identity; migration-data can quote those through run evidence. If current-build comparison is unavailable, the plan says so instead of claiming complete core parity. Unsupported metadata, missing public builds, preparation failures or a build needing a newer database are explicit exceptions, not silent version/track fallbacks. A source checkout using Ruby directly without the installed host launcher selects only available local profiles; it does not provision public images.

Schema-only Base names (`-v<schema>.sql.gz`) are recognized at intake but cannot resolve a release track automatically: an original versioned backup is required, otherwise the proposal returns `STANDARD_REVIEW_RUNTIME_UNRESOLVED`. Rolling `-dev` and custom version strings are not currently supported by this public-image resolver. Historical beta/RC metadata is normalized consistently, but an actual public prebuilt image must exist (or a compatible same-track one must be available); the public listing checked on 11 November 2026 had no `3.4.0` tags. Parsing a version is not a promise that its historical image is available. Keep original backup names; never rename one to fake compatibility.

Private inventories/comparisons live only in the requesting workspace's host-owned queue; shared profiles contain only public image facts. Timeouts/crashes with an uncertain Docker outcome fence preparation for **all** projects sharing the cache, rather than assuming the daemon stopped. Recovery and deliberate retention/space cleanup are separately approved admin work: see [runtime preparation operations](review-runtime-operations.md). There is no agent recovery/prune command and no automatic deletion.

## Propose and approve

After a passed convert run, migration-data proposes a review import. It uses the current Base site automatically. An explicit `base_site` input id selects a particular registered backup; `fresh_site: true` opts out and proposes on a fresh site. Do not supply both options. A current labelled backup not yet taken must be taken before proposing, or explicitly opt out.

Before approval, the plan shows which Base site, selected review runtime and Discourse version it uses. A sandbox with a schema ahead of the selected image produces a warning and is restored anyway; a higher timestamp alone does not prove core drift. The resolver selects a compatible application version first; execution checks the actual runtime against the approved identity, scans the SQL, refuses concatenated gzip members and verifies that all image-known migrations are present after restore. Original backup bytes and their registered identity remain unchanged.

The one setting the tool writes is allow_restore: off. Discourse itself may regenerate push-notification (VAPID) keys for the local base URL during restore, and the generic importer may write its own settings; these are distinct from the tool's local review environment overrides.

The engineer approves and starts the import, then opens the local review site through the SSH tunnel. Base-site run stages are: preflight, site up, base restore, import, verify, backup, site setup, review URL. The **Backup** is SQL-only: sandbox plus imported data, without uploads, taken before review sign-in is added.

## Release backup

The pass shows **Base site** and **Backup** rows. **Release backup** copies the completed run's backup and manifest into `<workspace>/outbox/`, the project's **output folder**. Nothing is sent anywhere. The server returns the actual folder path and filenames; the page does not construct a destination path.

When checks differ or there are none, **Release anyway…** requires explicit acknowledgement and records it in the manifest. Release is separate from passing: a pass still requires a completed run, at least one check, and every check matched.

After release, the page shows the output folder, backup and manifest filenames, who released it and when, and a short SHA-256. Copy both files from the server. Restore the backup on the hosted migration site using the Discourse version noted on the page/in the manifest or newer. That hosted restore is an engineer handoff **outside this tool**.

## Reset, Start over and Remove

**Reset the site** removes its containers and site data, but keeps evidence and run artifacts, including an unreleased backup. Released copies stay in the output folder.

**Start over** removes the workspace, including run artifacts and **released backups in the output folder**, and returns received files to the drop folder. It does not keep an output from the old project state. **Remove project** removes the whole workspace and drop folder, including released backups. Both actions list what goes and require typing the project name. Neither can be undone.

The output folder is not an agent-facing area and is not included in default data-job mounts. Agents can read backup identity and release metadata, not browse released files through area/list/peek tools.
