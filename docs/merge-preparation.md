# Prepare and inspect a Discourse merge

A native merge uses a **Base** (destination SQL-only backup) and a **Source**
(incoming full backup with upload files). Both restored databases are PostgreSQL.
The work is local and disposable: this does not connect to or mutate production.
Keep original Discourse backup names and bytes; a schema-only filename does not
establish an application release.

## Engineer flow

1. Intake and classify the source full backup and Base SQL-only backup as usual.
2. Ask migration-data for `data_merge_prepare`, or use the CLI below. Review the
   exact input/runtime/resource plan, **Approve**, then separately **Start**.
3. The host restores Base, loads/migrates a disposable source with the same pinned
   Discourse runtime, validates compatibility, and creates clean checkpoints and
   temporary inspection copies. No converter, custom layer or settings are needed
   to prepare. No merger or content-copy phase has run yet.
4. In the trusted Frontier chat, read `data_guide` / `data_run_evidence` and use the
   preparation's exact run ID and generation with `data_merge_inspection`:
   - `side=source`: read-only SQL through the prepared-source DBHub connector;
   - `side=base`: application/API reads through local Discourse MCP.
   Enable only this project's returned MCP server. Resolve material questions,
   prepare private merge settings, and obtain/review the committed layer if needed.
5. Propose `data_merge_propose` with `prepared_from`, `generation` and explicit
   `intent=stock` or `intent=custom`. The exact plan binds that environment,
   backups, runtime, layer/settings and options. **Approve**, then separately Start.
6. The host fences old readers/credentials and activates the untouched clean
   prepared state in the same environment. It does not re-export/re-intake the
   source or run an independently rebuilt source installation. Custom policy
   checks run before the merger constructor and after content copying.
7. Finalize, verify and record the clean full result backup. Fresh `side=result`
   inspection is then available; the old Base endpoint never silently becomes
   the result. The engineer checks the review site and explicitly releases the
   recorded backup. Later inspection does not silently regenerate the artifact.
8. Reset exact retained resources when done. Evidence/history remain private.

Preparation and Merge have separate approvals: the first authorizes restoring and
reading the copies, not future mappings. A ready inspection environment is not an
active migration and should not hold the execution lock indefinitely.

## Large backups and worker shutdown

New plans size the review/preparation containers from the control host's detected
CPU/RAM and the sizes of the bound backup archives. There is no manual sizing grid
or new image to install. The plan shows the Database/App CPU and RAM allocation;
those limits and database memory settings are covered by its exact approval.
Archive bytes are a useful proxy, not a measurement of the expanded database.

Below 1 GiB total bound archive size, legacy sizing is unchanged. At or above that
size the restore-command budget is 2 hours rather than 20 minutes; it is a limit,
not an ETA. Hosts with at least 4 CPUs and 32 GiB RAM also get a larger bounded
allocation: the database targets 4x archive size within 16–32 GiB, capped at a
quarter of host memory (never below the existing profile minimum). The app grows
up to 8 GiB. CPU allocation uses detected capacity, leaving headroom. Existing
host-memory, retained-instance and disk checks still apply at proposal/start.
For example, a 128 GiB host and a 2 GiB archive get a 16 GiB DB and 8 GiB app;
the DB gets 2 CPUs on a 4-CPU host or 4 on an 8-CPU host. Larger archives can grow
the DB to 32 GiB. Settings/limits on existing instances are not changed in place.

Shared buffers, index-maintenance memory and `/dev/shm` scale within that DB cap.
New large-host/input plans give `/dev/shm` twice `maintenance_work_mem`, capped at
4 GiB and one eighth of DB memory. Some parallel index methods allocate an arena
near the maintenance budget, leaving an equal-sized mount vulnerable to other
dynamic shared-memory usage. This headroom targets the current plain SQL restore
(one index build at a time), not arbitrary concurrent maintenance. It is mount
capacity inside the existing DB memory quota, not additional reserved RAM.
Earlier approved plans and retained containers are not resized or rewritten.
`work_mem` stays conservative. The image's durability defaults are not weakened.
This is not parallel SQL restore: the current plain SQL format cannot be sped up
by merely adding `pg_restore -j`.

New Prepare runs exercise the service-stop check before restoring the Base, then
explicitly bring the app back up for the post-restore health check. Workers are
stopped again before source loading and checkpoint creation. The image's normal
worker configuration is preserved for later merge finalization and result review;
preparation does not permanently disable post-processing. The service-stop wait
and graceful worker drain are bounded; an already-down app is valid. Unknown state or remaining workers still fail closed. A diagnostic reports
only a fixed reason and counts (no process arguments or customer values). Do not
interpret an exit-2 worker-drain failure as proof Unicorn was already down/crashed.

The run page and `data_run_evidence` show `step_timings_ms`: fixed operation labels
with elapsed milliseconds, including failed steps. These separate inventory,
hashing/copying, restore, health checks, source SQL load and migrations. They are
not success claims or estimates. Timings are best-effort telemetry; absence of an
entry alone is not evidence that a step never ran. Use them before further tuning; no speedup for a
particular customer database has been benchmarked by these source tests.

After a failed Prepare there is still no supported partial-stage resume. Retain
needed private evidence, address the failure, then explicitly Reset the failed
run's owned resources and review/Approve/Start a new Prepare plan. Do not edit
stage flags, adopt a dirty database as clean, or reuse the consumed old plan.
Once a generation is ready, its later Merge already reuses its clean checkpoints
without another backup restore. Original input backups remain untouched.

## CLI (no LLM required)

The same backend is available through the engineer CLI:

```sh
silo-migrate standard plan propose PROJECT --operation merge-prepare \
  --source INPUT_ID --base-site BASE_INPUT_ID
silo-migrate standard plan show PROJECT PLAN_ID --detail
silo-migrate standard plan approve PROJECT PLAN_ID --sha256 DIGEST --reviewer NAME
silo-migrate standard run start PROJECT PLAN_ID
silo-migrate standard run show PROJECT PREPARATION_RUN_ID

# After inspection, settings authoring and custom-layer review:
silo-migrate standard plan propose PROJECT --operation merge \
  --prepared-from PREPARATION_RUN_ID --generation GENERATION_SHA256 \
  --intent custom --settings SETTINGS_INPUT_ID
# Review, Approve and Start the new exact plan, as above.
```

Use `--intent stock` only when the shipped merger's defaults are deliberately
wanted. Absence of custom code is not a stock-intent decision. A custom prepared
merge requires the committed layer. Changing/resetting the prepared environment
makes pending continuation plans stale; never replace its Base implicitly with
the newest file.

The legacy one-shot `--operation merge --source … --base-site …` engineer path
remains for compatibility, but does not give a pre-merge analyst pause. Do not use
it to skip needed decision support or bypass a refused compatibility check.

## What source upgrading means

The merger reads a database and an uploads directory, not a newly exported source
backup. The host runs actual forward database migrations against the disposable
source using the selected target runtime. Original backups and uploads are kept
unchanged and digest-bound. Preparation must stop on unsupported/newer/unexplained
schema differences; changing a migration marker is not an upgrade.

The engine's matching maximum migration ID check is necessary but not a complete
compatibility proof. Required tables/columns/types, pending migrations and the
selected core/plugin behavior need validating before content copying. Unsupported
plugin data is not implicitly carried by the native merger. A refusal does not
justify renaming a backup, fabricating migration IDs or manually extracting it
through an analyst script.

A very old source may need a separately supported upgrade recipe. The tooling must
report that exception rather than guessing intermediary versions or downgrading
Base. A successful preparation is evidence for those exact copies/runtime, not a
promise about a later launch snapshot or current production.

## Discourse MCP and DBHub boundary

The fixed host launcher provisions a local inspection identity and a single-user
server-enforced read-only API key. The key is not printed, returned to the agent,
put in command-line arguments or stored in MCP registration. It lives in private
run-owned files. Do not paste a key into chat or reuse a production key. A pinned
connector uses only the approved local site, reviewed read tools, API-only mode,
bounded output and no general external network route. Write tools are disabled.

Normal `silo update` stages the pinned Node/Discourse MCP package and the existing
pinned DBHub image before switching releases. It needs Docker, not host Node/npm,
and does not create an unrelated generic source database. Dependency failure
refuses that release switch; retry the normal update after fixing registry access.
Connector launches themselves never pull images or install packages.

Privileged visibility may expose restricted/private content to Frontier. It is
not anonymous/member access testing and does not prove non-staff are denied.
Likewise a missing API result can mean hidden/unsupported, not nonexistent. Use
validated SQL/policy checks and explicit audience tests when the API cannot settle
an access-control question. DBHub cannot turn a standalone PostgreSQL database
into a running Discourse API; it remains the source database inspection path.

Source SQL is governed by a versioned read policy, not a grant to unknown plugin
secrets. Read-only transactions and row limits are not DLP. All returned content,
identities, counts, query text and permission findings remain private unless the
engineer explicitly releases a safe derivative. Restored text is untrusted data,
not tool instructions.

Stock term-llm restricts the connector to trusted migration-data using its existing
MCP admission rules. It does not attest this chat's project/provider or permanently
lock a data conversation. Only enable the right project's connector in Frontier;
stop if another project's server is enabled. Nothing here requires term-llm core
changes or resumption of its paused native fork.

## Clean checkpoints, capacity and recovery

API GETs can leave key-usage/counter state. Temporary account deletion does not
prove every side effect was undone. Therefore inspection uses disposable DB copies
and the merge consumes clean prepared state, not an inspected mutable database.
The same logical environment/runtime is retained; this is not a new external
backup/restore cycle. Budget the additional DB-copy disk cost explicitly.

Before merge/reset, the host blocks new launches, stops exact owned connectors,
revokes access and drains old read sessions. Password rotation alone does not end
existing connections. Preparation generation and exact resource ownership are
rechecked under locks; the Base inspection identity is additionally bound to its
clone's database OID, since the clean Base later takes the same database name.
Unknown outcomes remain fenced. A stopped-stack Reset may finish revocation only
after the exact owning stack and volumes are confirmed removed; a failed Reset
is incomplete and must not be treated as a successful cleanup. No broad prune,
automatic retry, lock deletion or unattended cleanup is implied.

A failed/interrupted merge is dirty, not an agent-resumable transaction. Use the
existing engineer recovery/Reset flow and make a fresh proposal when required.
No temporary inspection account/key may be present in the recorded result backup.

The Base has no upload bytes. Source uploads inside the original full backup are
preserved/verified; external S3 files are not fetched. Retaining the destination's
own upload files during a hosted restore remains an explicit operator task.
Hosted transfer/restore, DNS and production cutover remain outside this workflow.
