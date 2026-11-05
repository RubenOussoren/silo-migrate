# Standard local migration workbench

The first verified recipe: one full source snapshot becomes a validated, restore-proven Discourse database-and-uploads backup. It runs on synthetic data on one local machine. Hosted review, production restore, transfers, DNS and cutover are engineer handoffs and aren't automated.

silo-migrate owns the operations, durable state, approvals, validation and artifacts. Engineers use the CLI directly. term-llm reaches the same operations through a narrow adapter.

## What it does

`standard run start` executes one approved plan through these stages, in order:

| Stage | What happens |
| --- | --- |
| `preflight` | Rechecks registered inputs by content hash and the exact image IDs. |
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
$C standard init "$WS" \
  --converter-worktree "$P/worktrees/discourse-converters-runtime-prereqs" \
  --converter-revision 4e180c2dfd4dd6ea353c6da25f7cc1e8786429fc \
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

A plan's digest covers its inputs, code identity, runtime lock, image IDs, converter revision, baseline decision, target instances, ports and output names. Changing any of these makes the plan stale, and an approved plan can run only once.

| Code | Meaning |
| --- | --- |
| `STANDARD_NOT_APPROVED` | The plan hasn't been approved. |
| `STANDARD_APPROVAL_MISMATCH` | The digest doesn't match the plan. |
| `STANDARD_STALE_PLAN` | Something the plan depends on has changed. Propose a new plan. |
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

It can read safe status, propose plans, request an already-approved run and read released findings. It can't approve, reset, release or read logs. These limits come from its tool set and the `standard agent` command surface, which doesn't include those operations.

## Investigation and release

1. An analyst session reads one run's private evidence and proposes a finding:
   `term-llm ask --agent ./integrations/term-llm/migration-analyst "Investigate run RUN_ID in workspace WS"`. This agent is restricted to the `cdck_frontier` route.
2. The engineer reads it with `standard finding review`, checks it against the evidence, and writes the text to release. It doesn't have to match the proposal, and often shouldn't.
3. The engineer releases that exact text: `standard finding release WS FINDING_ID --file PATH --sha256 DIGEST --reviewer NAME`. A synthetic reproduction can be attached the same way.
4. Coding work reads it with `standard agent finding-show`. Unreleased findings aren't listed and can't be read through this surface.
5. Fixing the code invalidates earlier plans, so a new plan and run validate the fix.

## Runtime

`runtime/prebuilt-discourse/runtime-lock.json` freezes every identity. The application is the stock prebuilt `discourse/discourse` image with a small overlay adding only the locked `sqlite3` and `redcarpet` gems. `Gemfile.lock` is unchanged. Rebuild the overlay with:

```sh
docker build --platform linux/amd64 --pull=false \
  --tag silo-migrate/discourse-migration:3158c750-overlay1 \
  -f runtime/prebuilt-discourse/Dockerfile runtime/prebuilt-discourse
```

A rebuild may produce a different image ID, because the discarded build stage uses floating Debian packages to compile `redcarpet`. If the ID changes, update the lock deliberately. Existing plans then become stale.

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
