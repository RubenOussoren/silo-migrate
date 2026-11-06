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

It can read safe status, propose plans, request an already-approved run and read released findings. It can't approve, reset, release or read logs. These limits come from its tool set and the `standard agent` command surface, which doesn't include those operations. It can also search the web for public documentation; its instructions keep workspace names, IDs and tool output out of queries.

## Investigation and release

1. An analyst session reads one run's private evidence and proposes a finding:
   `term-llm ask --agent ./integrations/term-llm/migration-analyst "Investigate run RUN_ID in workspace WS"`. This agent is restricted to the `cdck_frontier` route.
   `standard analyst evidence WS RUN_ID` returns the run's stages, assertions, results and failure record first, then every evidence file and log with its size and stage, then the ends of the most relevant files: failed assertion groups, then the failed stage's logs (the step named in the failure first, then latest first), then earlier stages. The whole document stays under 40 KiB, because term-llm 0.9.93 cuts tool output at 50 KiB. Files listed in `omitted` weren't included. A completed run gets no finding: `finding propose` refuses it with `STANDARD_RUN_COMPLETED`.
2. The engineer reads it with `standard finding review`, checks it against the evidence, and writes the text to release. It doesn't have to match the proposal, and often shouldn't.
3. The engineer releases that exact text: `standard finding release WS FINDING_ID --file PATH --sha256 DIGEST --reviewer NAME`. A synthetic reproduction can be attached the same way.
4. Coding work reads it with `standard agent finding-show`. Unreleased findings aren't listed and can't be read through this surface.
5. Fixing the code invalidates earlier plans, so a new plan and run validate the fix.

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
- **One source platform.** The Khoros converter is the only one wired in. Other converters, new-converter development, delta imports, multi-source merge and native Discourse merge aren't implemented here, and `status` reports them as such.
- **Same OS user.** The analyst, coding and control paths are separated by interface and storage, not by the operating system. Prompts and role labels aren't isolation, and the release boundary doesn't stop a process running as the same user from reading private files directly.
- **Local restore only.** `restore-proven` means a fresh local instance passed the checks. It doesn't cover hosted environments, S3, or plugins beyond those in the stock image.
- **Background rebake isn't awaited.** A restored site rebakes posts in the background, so system posts can briefly show the old hostname in protocol-relative image URLs.
