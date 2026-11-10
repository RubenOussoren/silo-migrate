# Review on a Base site

The **Base site** is the customer's sandbox, before the source data is imported. The engineer takes a Discourse backup **without uploads** (`discourse backup --sql-only`), keeps its original file name, copies it into the project's drop folder and hands it over with `silo intake PROJECT`.

On the Project page's **Files** tab, select that one file and choose **Base site**. The page checks only its SQL-only backup name, gzip signature and regular-file identity (not SQL contents or every gzip member), and labels it **Base site v1** (then v2, and so on). It is separate from Development and Launch data: neither label changes the other. Once the workspace is ready, labelling also moves the original bytes into `inputs/`, read-only, and registers them as `base_site`. The page offers labels only once the workspace exists, so the source data can be labelled Development first and the Base site added whenever the sandbox backup arrives; neither waits for the other.

The Base site is readable by migration-data but is not a source export. Never load it into the source database or use it as converter settings or count checks. On a base site, destination checks must count imported rows, not whole tables. A source user merged by email into an existing sandbox account gets no import id: reconcile new imported users plus users merged into existing accounts against source users. Sandbox system and staff accounts remain unchanged.

## Propose and approve

After a passed convert run, migration-data proposes a review import. It uses the current Base site automatically. An explicit `base_site` input id selects a particular registered backup; `fresh_site: true` opts out and proposes on a fresh site. Do not supply both options. A current labelled backup not yet taken must be taken before proposing, or explicitly opt out.

Before approval, the plan shows which Base site and Discourse version it uses. A sandbox on a newer schema produces a plain warning: this is normal for hosted-only plugins and it will be restored anyway. A backup from a newer Discourse release, or an invalid backup, is refused. The plan is the authoritative version compatibility check; execution scans the SQL and refuses concatenated gzip members before restoring.

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
