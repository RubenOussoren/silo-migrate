# Review runtime preparation — operator recovery and retention

Normal engineers do not manage images: review/merge proposals resolve and prepare them automatically. This runbook is for **exceptional node-admin recovery**, not a new agent tool or automatic cleanup policy. Running any recovery/removal on a work node needs current approval for the exact resources and scope. No commands here were run on a work node during implementation/review.

## Authority and data boundary

The host launcher, its fixed worker and the Docker-authorized control container are trusted broker code. Control already has the Docker socket and authoritative workspace state; it is not an untrusted sandbox. This feature is not a kernel boundary against a compromised administrator/control broker.

The workspace-private queue is `<workspace>/.silo-migrate/data/review-runtime-jobs/` (0700, records 0600). It may contain the Base's migration-ID inventory and per-request comparison, so it is **not public**. Reads walk directory descriptors without following symlinks. These paths are not mounted into untrusted coding/data-job/review containers, and fixed agent operations do not allow arbitrary writes there. The Base-inventory optimization cache under `data/review-runtime-inputs/` is likewise host-only; execution still verifies the full registered input.

The shared cache is `<workspace-base-parent>/state/review-runtimes/`. Only image-derived public facts enter `profiles/`: actual image/core/version/dependency identities and core migration inventory. No requested schema, private inventory or per-customer comparison is published there. The worker passes no customer mounts, filenames, inventory, settings, Docker credentials or repository build context to image preparation commands. A Dockerfile-only context is used. Only two validated fixed comparison fields cross into the requesting workspace's plan: comparison completeness and missing-known-core count.

## Budgets, cleanup and unknown outcomes

One monotonic 20-minute preparation deadline covers serialized-lock waiting and command execution, reserving 30 seconds for cleanup. State publication has a separate bounded short grace; no asynchronous alarm interrupts a ready-state write. The synchronous proposal metadata scan has its own 90-second bound inside the existing 120/240-second tool request; it stops at the migration COPY terminator, and unchanged input stat identity reuses the private cache. Execution, not this hint scan, validates the complete archive.

Probe and bundle-check containers have unique `silo-rr-*` names, `silo-migrate.review-prep=true` and the preparation attempt label. They have no network or customer mounts and are resource constrained. Cleanup force-removes only that exact owned name and confirms absence, including on timeout. A cidfile acknowledges completed container creation: if a timed-out create was never acknowledged, an immediate absence check cannot exclude a late daemon create, so the attempt is fenced rather than assumed clean. CLI/plugin process groups are terminated, with bounded TERM/KILL/reap handling.

**Killing a Docker CLI does not by itself attest that a pull/build stopped.** Docker's build handler propagates request cancellation into its backend ([upstream implementation](https://github.com/moby/moby/blob/v28.0.0/api/server/router/build/build_routes.go)), but that is not effective-node cancellation proof. A client timeout/output interruption during pull/build, failed cleanup, or worker crash leaves a durable `.inflight.json` lease. No automatic replay is allowed while that lease exists. A worker lifetime lock distinguishes active work from a crashed job; PID reuse is never treated as proof or used to kill processes.

The lease scope is **the whole shared cache**, intentionally: an uncertain mutation of moving Docker tags or a build can affect other projects. `STANDARD_REVIEW_RUNTIME_RECOVERY_REQUIRED` therefore pauses preparation for all workspaces sharing that cache. It does not stop, upgrade or remove existing review sites or change their pinned runtime evidence.

## Recover an interrupted preparation

1. Do not repeatedly retry and do not remove `.inflight.json` merely because a timer elapsed. Keep workspace-private queue records private; never paste their JSON, inventories, paths or customer details into a coding chat.
2. Inspect only the lease's fixed public fields: attempt, status and phase (public image reference or exact owned probe name). Correlate the same attempt in the private worker lifetime record. Determine whether a worker/client operation is still active; do not infer this from an unverified PID alone.
3. Inventory containers by the exact `silo-migrate.review-attempt=<attempt>` label. Inspect/remove only a specifically approved owned probe, with its exact container ID/name and labels checked. Do not touch customer review containers or unrelated builds. If the record says a pull/build was interrupted, investigate the exact public reference/build and establish that its daemon operation has settled. Image presence alone is not proof a build has stopped. If the outcome cannot be established, keep the cache fenced and escalate; a global Docker/service restart is **not** the default remedy and requires separate current approval.
4. After all operations for that attempt are proven settled/cleaned, obtain exact approval to retire that one lease. Under the same `.prepare.lock`, recheck the attempt/lease identity has not changed, retain its record privately for audit, then remove only the approved lease. There is deliberately no agent-callable recovery command or broad automatic reset.
5. Make a fresh proposal. The ordinary public-image/metadata/frozen-bundle checks run again and pin the resulting profile before engineer approval. Never promote an unverified leftover tag by editing a profile or suppressing identity checks.

## Retention and space pressure

No unattended pruning was added. A new Base often reuses the same prepared overlay; changed image payload/recipe can add another image. The cache keeps profiles immutable so existing/historical plans and release lineage remain reproducible. Preparation checks headroom on the cache filesystem; this is not a guarantee about a separately mounted Docker data filesystem. `STANDARD_REVIEW_RUNTIME_CAPACITY` is an admin exception, not permission to delete data.

For a deliberate cleanup window:

1. Obtain approval for the exact cleanup scope; wait for/settle all preparation attempts and hold the preparation lock so the reference inventory cannot change mid-cleanup.
2. Inventory **all** workspaces using the cache, not just the active project. Include proposed/approved and retained consumed plans, their profile names/SHA/content identities, existing containers, retained run artifacts and released manifests. Do not publish customer filenames or raw records while collecting this inventory.
3. Exclude every referenced image/profile, active/uncertain worker and leased preparation. Historical/released references count too; reclaiming those requires a separate explicit retention decision, not just noticing their site was reset.
4. Produce a list of unreferenced generated `review-*` profiles and `silo-migrate/review-runtime:*` images with exact hashes/IDs. Do not include the release's shipped profiles, stock images required elsewhere, converter/control/database images, backups or workspace data. Have the node admin approve those exact candidates.
5. Recheck identities/references under the lock, remove only the approved candidates and preserve an audit of what was removed. Never use `docker system prune`, delete the cache wholesale, change a pinned profile in place, or remove images by a broad prefix alone.

This is a manual safety procedure, not a shipped garbage collector. If a complete reference inventory cannot be established, retain the images or explicitly approve additional capacity rather than risking an active migration.
