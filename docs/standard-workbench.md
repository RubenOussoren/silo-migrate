# Standard local migration workbench

The first verified recipe: one full source snapshot becomes a validated, restore-proven Discourse database-and-uploads backup. It runs on synthetic data on one local machine. Hosted review, production restore, transfers, DNS and cutover are engineer handoffs and aren't automated.

silo-migrate owns the operations, durable state, approvals, validation and artifacts. Engineers use the CLI directly. term-llm reaches the same operations through a narrow adapter.

## What it does

`standard run start` executes one approved plan through these stages, in order:

| Stage | What happens |
| --- | --- |
| `preflight` | Rechecks registered inputs by content hash and the selected profile and every image’s store-independent content identity. |
| `convert` | Runs the Khoros converter at a pinned revision against a disposable source database with no network. |
| `site_up` | Starts the review instance and checks its runtime identity. |
| `baseline` | Seeds a synthetic sandbox and takes a named backup, or restores an accepted pre-import baseline. Refuses identity collisions. |
| `uploads` | Processes uploads on the same instance, then restores the baseline's site settings. |
| `import` | Runs the standard generic import. Refuses a report with errors or skips. |
| `verify_site` | Checks baseline preservation and imported content, and downloads attachments over the published port. |
| `final_backup` | Takes a named full backup, then checks its members and required attachments. |
| `review_url` | Applies the local port to the review site. This happens after the backup so the port doesn't travel in it. |
| `restore` | Restores into a fresh instance with a different hostname and no bind mounts. |
| `verify_restore` | Repeats the checks independently. Only this stage can label the backup `restore-proven`. |

## Running it without an LLM

This host has no Ruby, so `bin/silo-migrate-control` runs silo-migrate in its pinned control container. On a machine with Ruby and the locked gems, use `bin/silo-migrate` with the same arguments.

```sh
C=bin/silo-migrate-control
WS=my-synthetic-project
P=$(cd ../.. && pwd -P)

$C named init "$WS"
$C converter clone "$WS" # host Git; defaults to discourse-org/discourse-converters, branch main
$C standard init "$WS" \
  --site-settings "$P/.runtime-cache/runtime-prereqs/site-cache/site_settings.yml"
$C standard fixture register "$WS" --snapshot development --label dev-snapshot \
  --fixture-dir "$P/worktrees/discourse-converters-runtime-prereqs/test/fixtures/khoros/inline_community_database"

$C standard plan propose "$WS" --dataset DATASET_ID
$C standard plan show "$WS" PLAN_ID
$C standard plan approve "$WS" PLAN_ID --sha256 DIGEST --reviewer "Your Name"
$C start-run "$WS" PLAN_ID
$C standard status "$WS"
```

`start-run` reports any refusal straight away, then continues in a background container, so the run survives the terminal closing. To stay attached instead, use `$C standard run start "$WS" PLAN_ID`, which prints the final result.

For a launch snapshot, accept the development run's pre-import baseline, reset that run's instances, register the launch dataset and plan from the baseline. Don't layer a full snapshot over an imported site.

```sh
$C standard baseline accept "$WS" DEV_RUN_ID --reviewer "Your Name"
$C standard run reset "$WS" DEV_RUN_ID --yes
$C standard fixture register "$WS" --snapshot launch --label launch-snapshot --fixture-dir ...
$C standard plan propose "$WS" --dataset LAUNCH_DATASET_ID --baseline BASELINE_ID
```

## Convert runs on real data

A convert plan (`standard_convert`) runs only `preflight`, `convert` and `reconcile`. It
converts a customer's registered dump into the intermediate database and counts what
arrived. Nothing is imported into Discourse yet. migration-data prepares the inputs and
proposes the plan (`data_plan_propose`), which first rebinds the workspace to the
converter's committed branch head (`standard converter refresh`; a dirty checkout refuses).
You approve and start it in the web UI's **Runs** widget (see below), or as the service
account:

```sh
$C standard plan propose "$WS" --operation convert --source INPUT_ID --settings INPUT_ID \
  [--reconciliation INPUT_ID] [--charset utf8mb4]
$C standard plan approve "$WS" PLAN_ID --sha256 DIGEST --reviewer "Your Name"
$C start-run "$WS" PLAN_ID
```

- **Inputs, chosen by ID** (registered inputs, bound by the digest like any plan):
  - **source:** a MariaDB/MySQL SQL dump, plain or gzip/bzip2/xz. An archive is refused
    when the plan is proposed (`STANDARD_DUMP_KIND_UNSUPPORTED`): extract it first. The
    dump must create its tables in the current database. A dump that creates and `USE`s
    its own (`mysqldump --databases`) fails with `STANDARD_SOURCE_EMPTY`: remove those
    lines first.
  - **settings:** type `converter-settings`, the platform converter's `settings.yml`. Where
    it needs the database connection it uses `${SILO_DB_HOST}`, `${SILO_DB_PORT}`,
    `${SILO_DB_USER}`, `${SILO_DB_PASSWORD}` and `${SILO_DB_NAME}`. The run fills them in
    privately, so no password is ever registered. `${SILO_DB_PASSWORD}` is required; any
    other `${SILO_…}` is refused (`STANDARD_SETTINGS_INVALID`).
  - **reconciliation** (optional): type `reconciliation`, JSON:
    `{"version": 1, "checks": [{"name": "users", "source_sql": "SELECT COUNT(*) FROM mybb_users WHERE …", "intermediate_sql": "SELECT COUNT(*) FROM users", "expect": "equal", "note": "why the filter"}]}`.
    At most 100 checks. Each query is a single `SELECT`/`WITH`: no comments, no `;` in the
    middle, no `INTO`/file or lock functions, and no `ATTACH`/`PRAGMA` on the intermediate
    side. `expect` is `equal` (the default) or `report`.
- **Platform:** the workspace's source platform (`mybb` for arc) selects
  `converters/<platform>` at the bound commit; `STANDARD_CONVERTER_PLATFORM_MISSING` if
  that commit has none.
- **The converter's gems:** the plan binds the converter-deps key (see "Dependencies").
  `STANDARD_CONVERTER_DEPS_MISSING` means no `dev_test` has prepared it for this commit
  yet. `data_plan_propose`, or `silo-migrate-control converter deps WS`, prepares it.
- **What the run does:**
  1. Copies the inputs by content hash.
  2. Loads the dump into a disposable MariaDB, with its data on disk under the run's
     private folder and no network (load limit 6 h). The load runs as root with the client
     in `--sandbox`. File reads and writes are confined to an empty run folder
     (`--secure-file-priv`).
  3. Creates the converter's and the counting user's accounts after the load, so the dump
     can't change them.
  4. Counts the source side of each check right after that, as a SELECT-only user, inside a
     scalar subquery (one value at most).
  5. Runs the converter (limit 12 h; its output goes to a private log, read after the
     container is gone).
  6. Deletes the database, the dump copy and the generated passwords (the kept settings
     copy shows `[removed]`), and keeps `intermediate.sqlite` as an artifact.
     `run reset` does the same after a killed run.
- **Size:** each container gets up to 2 CPUs and 8 GiB, at most a quarter of the host's
  memory (the DB's buffer pool is half of that), fixed when the plan is proposed.
  Admission refuses (`STANDARD_CAPACITY`) when these memory limits plus those of running
  managed containers exceed three quarters of the host's memory.
- **Disk:** the run checks before copying that the copy plus the database fit: dump × (1 + 3),
  or × (1 + 12) if compressed, above the profile minimum.
- **Reconciliation only reports.** Per-check numbers (`evidence/reconciliation.json`) are
  derived from customer data. They stay private: migration-data reads them with
  `data_run_evidence`, and you read them on the server. Public status (`standard status`,
  migration-operator) shows only totals: `reconciliation_checks`, `_matched`, `_differs`
  and `_errors`.
- **Findings on a completed convert run are allowed:** differences are what converter work
  fixes.

## Review runs on real data

A review plan (`standard_review`) imports a **completed convert run's** intermediate database
into one local Discourse review site. Nothing is converted again. migration-data proposes it
(`data_plan_propose` with `from_run`). You approve and start it in the Project page's Runs tab, or as the
service account:

```sh
$C standard plan propose "$WS" --operation review --from-run RUN_ID [--reconciliation INPUT_ID] [--port N]
$C standard run admin-password "$WS" RUN_ID      # the review admin's sign-in (the widget shows it on click)
```

- **What the digest binds:**
  - the convert run, its plan digest, and the intermediate database's SHA-256, size and file
    identity (if it changes, the plan goes stale: `STANDARD_REVIEW_SOURCE_INVALID`);
  - the reconciliation input (by default the convert run's);
  - code, the runtime profile and its images;
  - the site's name, loopback port and limits. These are sized to the host at proposal, never
    below the profile's: web up to 2 CPUs and 6 GiB, the database up to 2 CPUs and 4 GiB.
- **Stages:**
  1. `preflight`: rehashes the intermediate database and resolves the images.
  2. `site_up`: the profile's stack. Web is on an `--internal` network with no route out,
     published only on `127.0.0.1:PORT`, with SMTP at `smtp.invalid` and
     `DISCOURSE_DISABLE_EMAILS=yes`.
  3. `site_setup`:
     - sets `login_required`, no restore and the port, before any data arrives (so nothing is
       remapped);
     - creates the admin `silo_review_admin`. Its password is private to the run.
  4. `import`:
     - runs `generic_bulk.rb`, and the `import:ensure_consistency` pass it runs itself, without an
       uploads database (uploads are deferred);
     - first, `review_import.rb` pauses Sidekiq and the scheduler. It sets Discourse's pause key
       without an expiry and waits until no job or scheduled job is running. Otherwise background
       jobs, such as rebaking imported posts, deadlock the bulk updates (seen on arc). Both
       `SILO_SIDEKIQ` markers must appear in the log;
     - only the importer's completion line is required. Its "Import issues" are counted
       (public `import_issues`); the categories and the details file stay private.
  5. `verify`:
     - emails are still disabled and login is still required;
     - reconciliation: intermediate counts again; destination counts where a check has
       `destination_sql`;
     - source counts come from the convert run, for checks whose name and `source_sql` are
       byte-identical to it.
  6. `review_url`: over the published port, the site answers and an anonymous visitor gets no
     topic list.
- **Destination counts:**
  - each check may carry `destination_sql`, one SELECT/WITH count with the same rules as the
    other queries, and no `pg_*`, `SET`, `COPY` or locking;
  - it runs inside a scalar subquery, in a read-only transaction with a statement timeout, as
    `silo_count`;
  - `silo_count` is a login role created after the import, with SELECT on the public schema
    only.
  - Imported records have `import_id` custom fields. Users without an email get a random
    `…@email.invalid` address from the importer.
- **Opening the site:** an SSH tunnel with the **same** local port, because Discourse's base URL
  is `http://127.0.0.1:PORT`. Run `ssh -N -L PORT:127.0.0.1:PORT SERVER`, then open
  `http://127.0.0.1:PORT/` and sign in as `silo_review_admin`. The Project page's Runs tab shows the
  password on click.
- **Other accounts:** imported admins and moderators keep their flags. If a converter ever
  imports password hashes, those accounts could sign in too, but only through your tunnel.
- **Destination errors:** they keep only the SQLSTATE, because PostgreSQL messages can quote
  values. `silo_count` can't read session, API-key or password tables.
- **Lifetime:** the site holds customer data and stays until you **Reset** the run. Reset
  removes its containers, networks and volumes and deletes the admin password. Admission counts
  running sites, so reset old ones before starting another.

## The Runs tab (Project page)

The **Runs** tab of the web UI's Project page (`<base>/widgets/project/`; its logic is `widgets/runs/server.py`) is where the engineer makes the decisions
that used to be terminal commands as the service account. The **Project** tab on the chat page
counts what is waiting and links into it. Per project, it shows:

- **Plans:** what each plan binds (operation, platform, converter branch and commit, inputs by
  path and hash, limits). For a convert plan, it also shows the converter settings and the
  reconciliation checks themselves. Buttons:
  - **Approve:** the exact digest the page shows, with your commit identity as the reviewer.
  - **Start run:** in the background, as `start-run`.
  - **Discard:** a proposal nobody will approve, e.g. a stale one.
- **Runs:** stages, failure code and recovery text, and the reconciliation table with its
  numbers (you may see them; the operator sees only totals), plus the converter summary.
  Buttons:
  - **Reset:** finished or failed runs.
  - **Recover:** abandoned or never-started runs.
- **Review runs:**
  - the Destination column;
  - the review URL with its SSH-tunnel line (same port);
  - **Show admin password**: fetched only when clicked, never in status;
  - **Reset**: removes the site.
- **Converter pushes:** converter-developer's proposals, with the PR text, commits, files and
  diff stat. **Push and open draft PR** (exact digest) replaces `converter push WS --sha256 D`.

It runs as the service account on a Unix socket behind the web UI sign-in, like the Findings
widget. Every button runs the same `silo-migrate-control` command a terminal would, which
validates and records it. Agents have no web UI sign-in.
The tab's counts come straight from disk; lists and details use `standard status`, `plan show`
and `run show`, so stale plans and abandoned runs are shown as such.

## Approvals and refusals

A plan's digest covers its inputs, code identity, selected profile file SHA256, image content IDs, converter repo/branch/commit, baseline decision, target instances, ports and output names. Changing any of these makes the plan stale, and an approved plan can run only once.

| Code | Meaning |
| --- | --- |
| `STANDARD_NOT_APPROVED` | The plan hasn't been approved. |
| `STANDARD_APPROVAL_MISMATCH` | The digest doesn't match the plan. |
| `STANDARD_STALE_PLAN` | Something the plan depends on has changed. Propose a new plan. |
| `STANDARD_CONVERTER_DIRTY` | Commit changes (optionally on a development branch) or stash, then run `standard converter refresh WS`. |
| `STANDARD_RUNTIME_UNQUALIFIED` | Candidate profiles require the explicit engineer planning override. |
| `STANDARD_RUNTIME_MISMATCH` | An image or runtime assertion differs from the selected profile. Do not bypass the check. |
| `STANDARD_INPUT_CHANGED` | A registered input file changed. Register a new dataset. |
| `STANDARD_PLAN_CONSUMED` | This plan has already been used. |
| `STANDARD_BUSY` | Another operation is running. |
| `STANDARD_DIRTY_INSTANCE` | An earlier run left an instance dirty. Reset that run. |
| `STANDARD_CAPACITY` | Retained instances leave too little CPU, memory or disk. Reset an earlier run. |
| `STANDARD_REVIEW_SOURCE_INVALID` | A review plan's convert run is missing, not completed, or its intermediate database changed. |

## Failure and recovery

State is on disk, so a new process or chat sees the same picture. A failed run keeps its evidence and records a fixed code with a recovery instruction. Nothing retries on its own.

If the executing process dies, `status` reports the run as `abandoned`. To recover:

```sh
$C standard run recover "$WS" RUN_ID
$C standard run reset "$WS" RUN_ID --yes
$C standard plan propose "$WS" --dataset DATASET_ID
```

`reset` removes only that run's containers, networks and volumes, using recorded names and checking ownership labels. It keeps plans, evidence and backups.

Private evidence is under `.silo-migrate/named/standard/runs/RUN_ID/`. `standard run private-paths` prints the directory and the review site's admin password file.

## Conversational use

Select the operator agent by path:

```sh
term-llm ask --agent ./integrations/term-llm/migration-operator "Workspace my-project: what's the status?"
```

It can read safe status, propose plans and read released findings. It can't approve, start, reset, release or read logs. These limits come from its tool set and the `standard agent` command surface, which doesn't include those operations. It can also search the web for public documentation; its instructions keep workspace names, IDs and tool output out of queries.

## Investigation and release

1. A migration-data session (restricted to the `cdck_frontier` route) reads one run's private evidence and proposes a finding:
   `term-llm ask --agent ./integrations/term-llm/migration-data "Investigate run RUN_ID in workspace WS"`. It can also propose a **schema finding** with no run (`standard finding propose WS --kind schema --file -`): a source's tables, columns, counts and invented examples for converter work.
   `standard analyst evidence WS RUN_ID` returns the run's stages, assertions, results and failure record first, then every evidence file and log with its size and stage, then the ends of the most relevant files: failed assertion groups, then the failed stage's logs (the step named in the failure first, then latest first), then earlier stages. The whole document stays under 40 KiB, because term-llm 0.9.93 cuts tool output at 50 KiB. An entry whose `tail_bytes` is below its `bytes` wasn't read in full; `tails_omitted` counts files with no tail. A completed run gets no finding: `finding propose` refuses it with `STANDARD_RUN_COMPLETED`.
2. The engineer reads it, checks it against the evidence, and writes the text to release. It doesn't have to match the proposal, and often shouldn't. On a node this happens in the web UI's **Findings** widget (see `docs/node-operations.md`); from a shell, `standard finding review`.
3. The engineer releases that exact text: in the widget with **Release**, or `standard finding release WS FINDING_ID --file PATH|- --sha256 DIGEST --reviewer NAME`. A synthetic reproduction can be attached the same way (CLI only).
4. Coding work reads it with `standard agent finding-show`. Unreleased findings aren't listed and can't be read through this surface.
5. To correct a released finding, `standard finding amend WS FINDING_ID --file -|PATH --sha256 DIGEST --reviewer NAME` (widget: **Amend**) releases the new text as a new finding that replaces it: the old one becomes `superseded` and coding agents see only the replacement, whose `supersedes` names the old ID. `standard finding withdraw WS FINDING_ID --reviewer NAME` (widget: **Withdraw**) takes one back without a replacement. Rejected, superseded and withdrawn findings stay on record.
5. Fixing the code invalidates earlier plans, so a new plan and run validate the fix.

## Converter development (converter-developer and converter-reviewer)

Two agents work on a workspace's converter checkout (`workspaces/WS/converter`) without
ever seeing customer data. converter-developer runs on ChatGPT/Codex (`chatgpt`);
converter-reviewer on Claude (`claude-bin`, which must be configured and signed in).

- **What they see:** files whose *content* Git or the agent vouches for: tracked at HEAD
  and unchanged from the HEAD blob, or last written by the developer's tools (SHA-256
  recorded in `.silo-migrate/named/standard/converter-dev-files.json`). Anything else in
  the checkout (untracked files, or tracked files a run or a person changed) is invisible
  whatever `.gitignore` says, and so are `.git`, symlinks and everything outside the
  checkout. Agents can't overwrite content they can't see: the engineer cleans it up or
  commits it. Switching to an existing `migration/WS/*` branch is allowed only for
  branches the agent created or whose tip is already on the remote. Released findings
  come through `standard agent`.
- **What the developer may change:** those files, except `.gitignore`, `.gitattributes`,
  `.gitmodules`, `.git/`, `.github/workflows/`, `Gemfile`, `Gemfile.lock` and `.bundle/`
  (dependencies come from upstream's committed lockfile).
- **Dependencies:** the converter image's bundle was frozen when it was built, and upstream's
  lockfile keeps moving. Before tests, `dev_test` makes sure a cache in
  `<prefix>/state/converter-deps/<key>` exists for (image, committed `Gemfile`, committed
  `Gemfile.lock`). Building it is the only step with network: one container, the same limits
  as tests, that sees only copies of those two files and the cache folder (no agent code,
  no workspace content). It runs `bundle install` for just the gems the image lacks, layered over
  the image's own bundle. It also fetches Discourse's emoji table (three public JSON files from
  `raw.githubusercontent.com/discourse/discourse-emojis`), which the converter otherwise downloads
  at run time. The lockfile must use only `https://rubygems.org/` (no git, path or plugin
  sources) and Bundler 2.6.3; otherwise `STANDARD_DEV_DEPS_UNSUPPORTED` (a new converter image
  is needed). Upstream's lockfile has no checksums, so gems are pinned by version and trusted
  from rubygems.org over TLS. Built once per key (about 4 s and 1 MB for a markbridge bump);
  other workspaces with the same lockfile reuse it. Old keys aren't pruned yet. The step uses
  Docker's default bridge network, so a gem's build code could reach the host and the LAN, not
  only rubygems.org. Customer data services aren't on that network: source databases and
  Discourse stacks are on internal networks, and published ports bind to `127.0.0.1`. Restricting
  outbound traffic from that network to port 443 with a host firewall would narrow it further.
  The emoji table is frozen per key; if upstream changes its emoji URL, `dev_test` warns
  (`emoji_warning`).
- **Tests:** `dev_test` copies only the visible files into a temporary directory and runs
  `rake test` (or `rubocop`) in the profile's converter image, verified by content ID,
  with no network, a read-only root, no capabilities and CPU/memory/PID/time limits, and
  with the dependency cache mounted read-only. So is Discourse's `site_settings.yml`, the
  workspace's bound copy (sha256 checked), at `tmp/requires/discourse/config/`, where `convert`'s
  `SiteSetting.load_settings` finds it offline, exactly as in workflow runs.
- **CI parity:** suite `lint` runs Rubocop and `stree check` on Gemfile and `*.rb`/`*.rake`/`*.thor`,
  as `.github/workflows/ci.yml` does, and reports `syntax_tree` and the unformatted files. `dev_format`
  (developer) runs `stree write` (the repository's `.streerc`) in the same sandbox. It writes the
  results back through the recorded write path, reading the export without following any symlink:
  code in the container could plant one.
- **One branch per project:** `dev_branch` refuses to create a second `migration/WS/*` branch
  (`STANDARD_DEV_ONE_BRANCH`) unless `new_pr: true` (the engineer asked for a separate PR), so each
  push updates the project's one draft PR.
- **Commits:** only on `migration/WS/TOPIC` branches; built in a temporary index from the
  verified bytes of the visible changed paths (`hash-object`, `commit-tree`, compare-and-swap
  `update-ref`; no hooks), so nothing else in the working tree or the engineer's index can
  enter a commit; authored as the engineer with an
  `Assisted-by: converter-developer (term-llm agent)` trailer. Identity comes from the
  checkout's `user.name`/`user.email`, else `~/.config/silo-migrate/git-identity`
  (`name=...` and `email=...` lines, not group/world writable).
- **Push:** the developer calls `dev_push_propose`, which records a proposal and its
  SHA-256 digest (repository, branch, base, head, commits, files, PR title and body).
  Nothing is pushed until the engineer runs:

  ```sh
  silo-migrate-control converter push-show WS            # full PR text, files, diff stat
  silo-migrate-control converter push WS --sha256 DIGEST   # add --no-pr to skip the PR
  ```

  Review the diff first (ask converter-reviewer, or `git -C WS/converter show`): the digest
  binds the proposal, not your reading of it. The pushed branch runs the repository's CI.

  It refuses if anything changed since the proposal, pushes non-force to `origin` (which
  must be `https://github.com/OWNER/REPO`), then opens a **draft** PR as the engineer.
  The token is read only here, from `~/.config/silo-migrate/github/token-OWNER`
  (mode 0600, owned by the account), through a one-command credential helper: never in
  argv, a URL or Git config. Marking ready and merging stay with people.
- After commits, run `standard converter refresh WS` before planning a run on the new code.
- **Other branches (converter-developer and migration-data, read-only):** `dev_branches` lists the converter's branches on
  GitHub (newest first, ahead/behind `main`, and the PR when this project opened it), fetching first
  at most once a minute and never while a run holds the workspace; `dev_branch_diff` compares one with
  `main` as its pull request shows it; `dev_branch_read` reads one of its files. They read only
  committed branch content (never the working tree) and change nothing. The fetch uses the same token
  file through the same credential helper as `converter update`, download only; the agent never sees
  the token. Private converter links and PR numbers go through `dev_branch_resolve` (or
  `data_branch_resolve` for migration-data), never web tools. migration-data's server-enforced
  reader role has only resolve/list/diff/read, not tests or writes. Code changes remain the
  converter-developer's job. By the owner's decision of 2026-11-10, web tools stay on for all agents
  for public reference only; migration-data must never put customer-derived values in web requests
  and treats web text as untrusted reference, not instructions (see `docs/node-operations.md`).
- `converter clone`/`update` use the same token file for a github.com remote when one
  exists, so a workspace can clone the private converter repository:
  `silo-migrate-control converter clone WS --repo https://github.com/discourse-org/discourse-converters.git --branch main`.

Limits: same-account processes (and an engineer approving server-support writes) are
inside the trust boundary; the checks are not an OS sandbox. The developer writes code
that later runs on customer data in conversion runs: review it (and what it logs) before
`standard converter refresh`. Runs use a materialized copy, not the checkout, and anything
written into the checkout by other means is invisible to the agents by the content rule
above. Commits an engineer makes by hand on an agent's branch are trusted as they are. Files whose
checked-out bytes Git rewrites (`.gitattributes` `eol`, `ident`, `working-tree-encoding`)
are never visible to the agents; the converter repository has no `.gitattributes` today,
and agents can't add one. Switching branches may overwrite ignored files the target branch
tracks. Tests run converter code
in a container with Docker's default seccomp/AppArmor, not a VM.

## Converter selection

```text
standard init WS [--converter-worktree PATH] [--discourse-profile NAME] [--site-settings PATH]
standard converter status WS
standard converter refresh WS
silo-migrate-control converter clone WS [--repo URL] [--branch BRANCH]
silo-migrate-control converter update WS
```

Create the named workspace first (`named init WS`), then clone before `standard init`.
Without `--converter-worktree`, init selects `WS/converter` inside
`SILO_MIGRATE_BASE_PATH`. An explicit absolute path still selects an existing
checkout. The service never modifies it. There is no `--converter-revision`:
init reads HEAD, branch (or `detached`), and the origin URL with userinfo removed.
`--site-settings` defaults to `SILO_CONTROL_SITE_CACHE` when set; otherwise supply it.

Proposal, approval and execution require a clean checkout (including untracked
files) at the recorded commit. Commit your changes, optionally on a development
branch, or stash them, then explicitly `standard converter refresh WS` to record
the clean HEAD. Every refresh invalidates existing plans, even at the same HEAD.
Status reports current repo/branch/commit and dirty state; ahead/behind remain
`unknown` because status does not fetch. Plans and backup manifests retain the
selected converter lineage.

Clone and update are **host-side wrapper commands**, using the account's Git
credentials; those credentials are never mounted in the control container. Clone
refuses an existing `WS/converter`. Update requires the managed checkout and its
recorded non-detached branch, refuses a dirty tree, fetches origin, then merges
`refs/remotes/origin/BRANCH` with `--ff-only` and refreshes the workspace binding.
It never resets, force-pulls or silently resolves divergence. Update failure leaves
any fetched refs intact and asks the engineer to resolve the checkout deliberately.

## Runtime profiles

```text
standard runtime list
standard runtime show NAME
standard plan propose WS --dataset ID [--baseline seed|ID] [--ports A,B] [--allow-unqualified-runtime]
```

Default: `discourse-2026.11.0-latest-3158c750`, a qualified profile in
`runtime/profiles/`. Profiles also come from `SILO_RUNTIME_PROFILES_DIR`, an optional
server-local candidate directory, not a reason to put local settings in Git.
Names are filename stems; duplicate names across directories are refused rather
than shadowing an active profile. List reports name, qualification status,
selector (channel/release/stock index digest), and whether **every** image resolves
locally with matching content. Show returns the profile and its file SHA256.
No discovery command pulls an image or starts a container.

Init records the profile name and exact file SHA256. Plans bind that SHA. Editing
(including formatting) or deleting the file makes plans stale and blocks new
plans for that workspace; a new server candidate never switches an active
project. Keep pinned profiles immutable and choose a new profile name when
initializing a fresh migration. A profile whose `qualification.status` is not
`qualified` requires `plan propose --allow-unqualified-runtime`; the override and
`runtime_qualified: false` are carried in the approved body/public view and backup
manifest. The agent planning surface cannot supply this engineer override.

The default application is the stock prebuilt `discourse/discourse` image with a
small overlay adding only locked `sqlite3` and `redcarpet` gems. All application
revision, Ruby, Bundler, lock hash, extensions and PostgreSQL/Redis major checks
come from the selected profile. The profile records both the Dockerfile hash
used for the qualified overlay (`qualified_dockerfile_sha256`) and the current
parameterized Dockerfile hash (`dockerfile_sha256`); changing build parameters
is not qualification. Build preparation, **not an instruction to rebuild a live
runtime**:

```sh
docker build --platform linux/amd64 --pull=false \
  --build-arg STOCK_IMAGE=docker.io/discourse/discourse@sha256:f847da87e77b0506eae2167d75f0cce500cf174fde7127b60e33baaafeab65ec \
  --build-arg EXPECTED_LOCK_SHA256=bacaa276aebc56385bf28c9fefbc6224e494e0361bd734933b4a20427e0f87d2 \
  --tag silo-migrate/discourse-migration:3158c750-overlay1 \
  -f runtime/prebuilt-discourse/Dockerfile runtime/prebuilt-discourse
```

Each image has `ref`, `content_id`, and `source` (`public-digest` or `package`).
Docker containerd and classic stores can expose different `.Id` values for the
same payload. `content_id` is `sha256:` plus SHA256 of UTF-8 canonical JSON
(recursively sorted keys, no whitespace, Ruby `JSON.generate`) of:

```json
{"architecture":".Architecture","os":".Os","diff_ids":".RootFS.Layers","config":{"Cmd":".Config.Cmd","Entrypoint":".Config.Entrypoint","Env":".Config.Env","User":".Config.User","WorkingDir":".Config.WorkingDir"}}
```

Null lists become `[]`; null strings become `""`. List order is preserved.
Preflight inspects each ref locally, recomputes content, refuses a mismatch, then
runs the resolved local `.Id`, never the mutable tag. Resolved IDs are stored in
run artifacts, `runtime-images.json` evidence, and backup manifest lineage.
`bin/silo-migrate-control image-identity REF` prints the same ID without Ruby on
the host. A rebuild may change payload content (the discarded build stage uses
floating Debian packages); select and qualify a new immutable profile deliberately.

## Server control configuration

The wrapper requires Python 3 on the host (the migration service still runs in
the pinned Ruby container). With no config it keeps the existing project-root,
gem-cache, workspace and control-image defaults. `SILO_CONTROL_SITE_CACHE` and
`SILO_RUNTIME_PROFILES_DIR`, if set, are also forwarded and mounted read-only.
With `SILO_CONTROL_CONFIG=/absolute/path/control.conf`, read strict literal
`KEY=VALUE` lines: no shell evaluation, export syntax, quotes or substitutions.
Blank lines and whole-line `#` comments are allowed; unknown or duplicate keys
are refused. Required keys:

```text
SILO_MIGRATE_BASE_PATH=/srv/silo/workspaces
SILO_CONTROL_GEMS=/srv/silo/gems
SILO_CONTROL_SITE_CACHE=/srv/silo/site_settings.yml
```

Optional: `SILO_RUNTIME_PROFILES_DIR=/srv/silo/profiles` and
`SILO_CONTROL_IMAGE_REF=ruby@sha256:32ca6f94a3ffe387eb1b9d34edc4be8e9308da1c80a3dce8b7b8310d84949240`.
Paths are absolute; don't quote values. The configured wrapper mounts the
repository root read-only at its own path, not its grandparent. Workspaces are
read/write, gems/cache/profile directory read-only. The control image is inspected
and its content ID verified before any control container starts, then the resolved
local `.Id` is used. The expected control content ID is the documented constant
`CONTROL_CONTENT_ID` in `bin/silo-migrate-control`, also recorded in the qualified
profile: `sha256:c04e168879ee10209715c71cf0eb1814e7308fa794329c55ae59c508f1e7d165`.
Changing the image ref does not bypass that content check. Docker socket access
makes this trusted operator tooling, not a sandbox.

Each instance's web container sits on an internal Docker network with no route out. Only a small proxy publishes HTTP, on `127.0.0.1` in the range 18080–18089. Containers have CPU, memory and PID limits, bounded logs and no restart policy. Docker enforces each container's limit, and admission refuses a run that would exceed 4 CPUs or 8GiB in total. Storage isn't quota-enforced; admission checks free disk.

## Hands-on check

1. Open the review site and find **Sandbox welcome topic created before migration** next to the imported topics.
2. Download the attachments from the sandbox topic and an imported topic, and check their text.
3. Log in as `sandbox_admin` with the password from `standard run private-paths`. Check that the Admin area loads.
4. Open the restored site and repeat. The same password works, because the accounts came from the backup.
5. In a new terminal or chat, run `standard status` and see the same state.
6. Ask the operator agent to approve a plan, and see it refuse.
7. Touch a registered file under the workspace's `inputs/`, then run `standard plan show` on an approved plan and see `stale`.

Email is disabled and the sites have no route out, so anything involving email won't work there.

## Limitations

- **Synthetic only.** Customer data needs separately approved isolation that this doesn't provide.
- **One source platform.** The Khoros converter is the only one wired in. Other converters, new-converter development, delta imports and multi-source merge aren't implemented here, and `status` reports them as such. Merging one Discourse site into another with Discourse's own merger is a run of its own: see [Merging another Discourse site](project-merge-run.md).
- **Same OS user.** The analyst, coding and control paths are separated by interface and storage, not by the operating system. Prompts and role labels aren't isolation, and the release boundary doesn't stop a process running as the same user from reading private files directly.
- **Local restore only.** `restore-proven` means a fresh local instance passed the checks. It doesn't cover hosted environments, S3, or plugins beyond those in the stock image.
- **Background rebake isn't awaited.** A restored site rebakes posts in the background, so system posts can briefly show the old hostname in protocol-relative image URLs.
