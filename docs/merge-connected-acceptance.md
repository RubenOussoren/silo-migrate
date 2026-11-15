# Connected invented-data Merge acceptance (Stage C)

**Accepted local checkpoint (2026-11-15): 7 tests passed in 655.056s.** The real
installed launcher completed Prepare, preserved an expected policy refusal with
normal cleanup, accepted corrected settings without reset/re-Prepare, required
exact approval and a separate fresh claim/execute, ran stock merge/assets/full
backup, passed independent archive-byte checks and read durable completion through
a fresh CLI process. Failed evidence stayed unchanged; exact-owned fixture cleanup
was confirmed. Copied public-source snapshot (independently recomputed):
`82f9180682c58a2c1e03809dc389f1913b0d2b9724af00fec2072912cb5a7a16`.

This is invented-data Development acceptance with the headless transport below,
not customer/server acceptance, hosted restore, release approval, large-input
performance or nonempty Base-upload proof. Detailed earlier failures remain below;
they are not rewritten as successes. No customer operation is implied.

Run from the repository:

```sh
SILO_MERGE_CONNECTED_LIVE=1 python3 -I -B test/merge_connected_live_test.py
```

Without the opt-in only the small transport/guard tests run; the live test **skips**.
That is not acceptance. Opted-in missing prerequisites fail, never silently skip.
The fixture uses the cached profile selected by
`runtime/profiles/discourse-2026.11.0-latest-3158c750.json`, cached control gems
(default `../../.runtime-cache/gems`, overridable with `SILO_CONNECTED_GEMS`),
Docker and approximately 4 GiB available RAM. It installs no dependencies, pulls
or builds no images and never accesses an existing workspace/site or customer
input. Budget: 1,800 seconds of work plus bounded exact-owned cleanup.

## What is genuinely connected

`test/merge_connected_live_test.py` stages a private installed release layout with
`installation/bin/silo-migrate-control -> ../current/bin/silo-migrate-control` and
an ordinary control configuration. The launcher, Ruby CLI and service code are
copied unchanged. This exercises the installed launcher dispatch/configuration,
not the installer/package publication or an already deployed installation.

Two tiny invented seed backups are made with the cached Rails image's actual
Discourse backup implementation: a SQL-only Base and a full source archive with
two real PNG uploads and one post/reference. Both input generation and the service's
Prepare/merge stack retain normal plugin loading. No migration records are deleted
or forged. Original version-bearing backup names are preserved at registration. The source's original-only asset subset and
seed/backup helpers reuse `merge_process_rails_live_test.py`; **its guest validation,
provision/run/backup composition is not used as the lifecycle under test**.
The seed stack is stopped before the host workflow starts its own stack.

The fixture then invokes the actual installed CLI for:

1. Named workspace/source/dataset/input registration and standard initialization.
2. A real Prepare proposal, exact digest approval and execution. The persisted
   ready environment supplies the generation for subsequent commands.
3. A committed invented custom layer/contract and immutable registered settings.
   The layer inherits the real pinned stock constructor and `start` unchanged.
4. An expected custom-policy proposal refusal; compatible outer code, attempt
   reference and independent saved work/cleanup diagnostics must survive the CLI.
   Exact saved-status lookup must not mutate the receipt/journal. Real PG catalogue,
   Redis container absence and guest directory absence supplement cleanup flags.
   The prepared environment and existing plans must be unchanged.
5. A successful custom proposal **without reset or re-Prepare**, exact digest
   approval, a separate fresh `run claim`, and a separate `run execute` process.
6. Stock merge, selective physical assets, checks/rebake, real full backup and
   durable completed run/stages. The fixture independently compares archive bytes
   to the stored artifact identity, selected/excluded manifest and whatever the
   runtime baseline inventory contains (possibly empty), and reads completion
   through a fresh installed CLI process. This SQL-only Base seeds no destination
   upload: it does **not** prove nonempty Base-upload preservation. The existing
   nonempty-baseline Rails composition remains separate authority. The
   original failed validation evidence must remain byte-for-byte unchanged.

Only static delivery-label registration metadata is fixture-seeded because the
Named Ruby CLI has no delivery-label command. All input records are registered
through the real Named CLI. No plan/run/approval/generation/receipt/journal/process
report/backup evidence is fabricated. This does not cover Project-page intake or
file-role UI acceptance. Local commits exist only in disposable invented converter
and merger repositories, which the production freshness gates require. The fixture
itself never commits or pushes this source checkout; publication is separate.

## Headless transport, not lifecycle mocks

Production `PrebuiltStack` currently always creates a publishing network and
loopback listener; the installed control launcher uses host networking. Those are
not authorized for this fixture. Three new support files adapt **transport only**:

- `merge_connected_live_host.py` executes the unchanged installed launcher through
  `runpy`, with a Python audit hook that refuses a runtime-preparation worker
  **before spawn**. It supplies no ready result. Cache absence remains a refusal.
- `merge_connected_live_docker.py` forwards real Docker commands, switching only
  the control container to `--network none` and injecting the Ruby transport.
- `merge_connected_live_transport.rb` forwards the runtime's actual Docker calls,
  makes created networks internal, labels resources with a unique fixture token,
  removes the proxy's host port publication, and records its private route.
  Host HTTP checks issue actual `curl` requests through the actual socat proxy via
  `docker exec`, returning the actual HTTP status/body. No successful response is
  canned. SQL, Rails processes, resource creation/deletion, locks, store,
  validation, freshness, claim, orchestration, stock merger and backup verification
  methods are **not replaced**.

A passing run would prove the host lifecycle with that explicit socket-transport
difference; it would **not** prove normal host-network/loopback listener reachability or the
installer. A first-class headless production transport could remove these adapters
later, but is not required to weaken any gate now. Cleanup removes only exact
resources bearing this invocation's random token; it checks isolation and never
uses broad Docker prune, recovery scripts or customer/server operations.

## Evidence status

Development run evidence is recorded here after execution, not inferred from the
fixture's existence. The first opted-in run created real seed archives and reached
actual installed registration, then refused `STANDARD_CONVERTER_CONFIG` because
the host's permissive umask made the disposable converter Git metadata writable.
The fixture now creates that repository with a private umask. Both real seed and
all fixture-owned resources were cleaned. This was **not a full lifecycle pass**.

The fixture's next run reached installed Prepare admission but refused runtime
resolution because generic archive names had discarded the public version/schema.
The fixture now keeps original version-bearing names and creates the required
SQL-only Base with core's actual `with_uploads: false` backup option.

The third run reached installed Prepare admission but got `runtime_preparing`,
not a plan. The launcher unconditionally asks its runtime-job cache before the Ruby
CLI; a new private workspace has no ready request attestation even when all pinned
images are present. That run **unexpectedly enqueued a preparation worker** before
this boundary was understood. No worker remained when checked after cleanup and no
new image was observed, but its detailed execution/outbound activity was not
captured: a claim that this earlier run proved zero network activity would be
unsupported. The fixture now refuses that worker before spawn via the audit guard.

The fourth opted-in run used the audit guard and failed closed at actual installed
Prepare admission with `STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED` (156.535s),
after real SQL-only Base/full-source seed backups and actual Named/standard
registration. The worker spawn was denied; fixture-owned cleanup completed.
This is a successful safety-boundary check, **not a passing Stage C acceptance**.

The parent subsequently supplied an invocation-only `--cached-review-runtime`
operator API. The fixture uses it only for the initial Prepare proposal, with no
`--allow-unqualified-runtime` override. Its actual networkless `silo-rr-*` metadata
and frozen bundle probes are forwarded unchanged except for invocation labels;
no probe mounts, published ports or image acquisition are allowed. The denied
worker-spawn audit hook remains active.

An initial cached-only diagnostic refused: all public image metadata matched,
and the invented Base version/schema matched, but the boot had 2,611 migration IDs
versus 1,814 migration filenames enumerated by the metadata probe. A trial with
core's `LOAD_PLUGINS=0` did not change that (65.386s, failed prerequisite, cleanup
confirmed). Independent actual networkless inspection of the pinned public image
then proved its own `db/structure.sql` declares exactly 2,611 core history IDs:
797 are historical IDs no longer represented by migration filenames. The source
union is 2,611, matching the invented Base; the earlier plugin attribution was
incorrect. The temporary plugin-loader override was removed. No migration rows
were deleted, no gate bypassed, and no later stage is claimed passing.

The parent then added the strict `CACHED_CORE_HISTORY_PROBE`: one bounded literal
migration block from the pinned public `db/structure.sql`, unioned with actual
current migration filenames, with **all** registered Base IDs still required to
be covered. C removed its redundant filename-only assertion and defers admission
to that actual installed gate. No supplied Base inventory is filtered or forged.
The full no-override, normal-plugin-loading live run is being retried against this
source; results below remain unproven until its runtime assertions complete.

The next actual installed attempt passed the prior cached-history boundary but
refused Prepare proposal with `STANDARD_CAPACITY` (158.034s), cleanup confirmed.
The disposable workspace was on `/tmp` tmpfs with about 5 GiB free, below the
unchanged profile's 8 GiB plus input headroom gate. C now creates its private
workspace under the project's disk-backed `tmp/` (about 54 GiB free at diagnosis),
without mocking free space or lowering profile/capacity checks. The same command
is being retried there; no later-stage success is claimed yet.

The disk-backed run then executed real Prepare through restore, source load and
compatibility, but failed at checkpoint with `STANDARD_MERGE_ENVIRONMENT_DIRTY`
(371.518s), cleanup confirmed. One unchanged diagnostic repeat projected only
fixed source tags/booleans from the invented private failure before cleanup:

```text
command: SILO_MERGE_CONNECTED_LIVE=1 python3 -I -B test/merge_connected_live_test.py
result: FAILED, 357.986s
installed_source_sha256: 674d0d7ae999ccde422fc20bf3f7f167af281a3c1465a50d3de309d8c66a5bbf
checkpoint_failure_tag=seal
seal_sql_exit_zero=true
seal_max_ids_have_negative=true
failed_stage=checkpoint
code=STANDARD_MERGE_ENVIRONMENT_DIRTY
owned_cleanup_confirmed=true
```

The query succeeds but `MERGE_SEAL` accepts only unsigned maxima; the tiny real
input has built-in negative IDs and no positive human user. No service seal was
changed and no migration/ID bookkeeping was fabricated. Parent decision remains
whether to correct bounded signed-ID representation or explicitly choose an
invented positive-ID user input. Prepare completion, custom refusal/cleanup,
Start and final backup remain **unproven** until a real passing run.

Stage B integration now separates the saved reader's version-1 receipt check from
its accepted version-1/version-2 journal checks in the concurrent working source.
That source change was observed after the guarded run; it has not been exercised
by this fixture yet. No fixture assertion was weakened to accommodate it.

Subsequent integrated runs completed real Prepare but still refused before the
intended policy hook. One saved attempt failed at `guest_validation` in 212ms,
with completed producer and confirmed normal cleanup. Source inspection found
validation reading a nonexistent catalog `redis.id`; the transport fake had hidden
that actual profile entries provide `ref`/`content_id`. The host now reuses the
existing content-verified immutable resolver; changed-content tests refuse before
sidecar creation and retain `--pull=never`.

The first post-fix run stopped earlier at `site_up` with `STANDARD_STACK_FAILED`
(318.524s), before reaching that path; exact fixture cleanup was confirmed. The
serial repeat completed Prepare but still refused before guest boot (424.250s),
with completed producer/confirmed normal cleanup. A separate real cached-Redis
probe reproduced failure under the production cap-drop/read-only options with
its default root entrypoint. The identical probe with `--user redis:redis` stayed
running and answered `PONG`; both exact-owned probes were removed and absence
checked. The fix retains all dropped capabilities and the read-only filesystem.

The next connected attempt saved a bounded diagnostic instead of losing it:
`guest_launch`, known failed child, `LoadError` / `bootstrap` /
`validation_config` line139 (`require "pg"`), completed producer and confirmed
normal cleanup. A real networkless pinned-image probe proved the PG gem is not
available to the initial bundle-launcher Ruby, but is available in `bundle exec
ruby`. Production now passes `-r<guard>` to that bundle-activated Ruby child,
never `RUBYOPT` to the earlier launcher. Another actual source-hook probe with an
invented config proved both native PG and GlobalSetting guards installed before
the child body executes. No guard or ACL was relaxed, no owner fallback added,
and no dependency installed. The probe's initial empty-config variant itself
failed safely; its nonempty invented-config correction passed.

The next real run reached the intended policy hook, but the host's result
verification replaced it with `SiloMergeContract::Error`. The strict parser's
`UniqueObject` detects duplicate JSON keys during ingestion; host code then tried
to overwrite existing optional-evidence keys on that subclass. The host now
normalizes the validated outer result with `to_h` before mutable normalization.
A regression using the actual duplicate-detecting parser retains the typed
refusal and still rejects duplicate input keys. Focused tests: 149 / 2,508 / pass.

On public-source snapshot
`4cb10d0661f9162bef5abc03a064181dcc968e5b6aee6c212bebba17268fd853`, the real
fixture subsequently passed `policy_refusal_saved_diagnostics_cleanup_no_reset`:
`preflight_refused` survives proposal/status/exact reads, the producer completed,
PG/Redis/guest scratch resources are absent, the prepared generation/plans and
failed evidence remain unchanged. This is now observed, not a fake transport pass.
The subsequent corrected-settings proposal still refused (465.360s total), with
fixture-owned cleanup confirmed. Its unexpected-refusal branch previously printed
only the outer code. It now projects the same strictly validated safe saved
diagnostic before cleanup, so the next bounded local run can locate that later
failure without weakening policy or reading raw output.

The positive proposal's later `assets_unproven` is now located at its actual
metadata digest check. The untouched invented inspection copy reports only
nonpositive packaged `/images/` records with nonempty non-hex SHA1s, not invalid
positive/upload-path rows. Pinned core's `db/fixtures/010_uploads.rb` recreates six
fixed negative-ID packaged image records on migration, using deliberately fake
`_`-prefixed digests. Do NOT delete/filter them to get a green test.

The adapter now proves exact known ID, packaged URL, size, fake digest against
bounded regular NOFOLLOW public-image files, no secure/original digest, plus one
identical unambiguous existing destination record. Stock SQL retains every row
and stock mappings; this proof separates only already-packaged reuse from physical
uploads, binds it into selection freshness and rechecks after construction.
All unknown/nonpositive/unproven, changed/missing counterpart, duplicate digest,
symlink and invalid customer-upload cases still refuse. Positive uploads and every
physical file remain subject to the existing policy/baseline checks. Discovery
still reads all rows; no `WHERE id > 0`, migration filtering or plugin disable.

The exact pinned method also allocated ID0 when destination MAX(id) was negative.
A unit reproduced that; the adapter now floors that starting allocation at0 before
incrementing, preserving stock empty/positive behavior and all existing records.
Its equivalence test explicitly verifies these TWO copied-method differences:
deferred physical IO and positive allocation floor. The pinned stock source,
constructor and start are unchanged. The actual public-image packaged-file proof
passes; focused integration is353/4781/pass. Normal helper staging now includes
the new diagnostic dependency used by the stock execution child.

The next real run reached successful proposal, approval, fresh claim, stock merge,
assets and backup, then failed the unchanged final settings gate at completion
(`STANDARD_MERGE_SITE_SETTINGS_FAILED`,669.852s, cleanup confirmed). Full independent
archive/completed-state assertions were not yet run. Pinned core's first-active-
admin callback clears `has_login_hint` and `global_notice`; local review/inspection
identities are not legitimate customer-admin signups. The two helpers now suppress
only that callback on their new instance, never globally or by ignoring differences
in the final check. Both actual-helper isolated tests prove preserved settings and
ordinary callbacks still active. That first correction was insufficient: the next
real diagnostic identified `global_notice`, `has_login_hint` and
`include_s3_uploads_in_backups` as changed public core settings. Native #activate
confirms a token via a DIFFERENT loaded User, losing an instance-only guard; the
helpers now retain already-saved active/approved/confirmed identities and refresh
groups directly instead. Native backup CLI's ensure redundantly invokes the S3
backup setter even without its flag, creating a stored override where none existed.
A merge-only Ruby-child guard keeps the actual CLI/Creator, permits only a no-op
for equal effective values and refuses an actual setting change. It never repairs
or whitelists differences after the fact. All final exact settings gates remain.
Focused settings/inspection/integration:203/21255/pass, with a corrected harness
that models the native fresh-instance activation path.

## Accepted complete run

Command: `SILO_MERGE_CONNECTED_LIVE=1 python3 -I -B test/merge_connected_live_test.py`.
**7 tests / 655.056s / OK**, no skips. Public-source snapshot:
`82f9180682c58a2c1e03809dc389f1913b0d2b9724af00fec2072912cb5a7a16`.
Both actual checkpoints passed:

- `policy_refusal_saved_diagnostics_cleanup_no_reset=true`
- `installed_prepare_custom_approval_claim_stock_assets_full_backup_persisted=true`

Final frozen-source verification also records Ruby **1,392 runs / 38,711
assertions**, zero errors/one skip and only the two established installer
expectation failures (missing mounted Git checkout and zsh login-shell expectation).
Python **945 discovered / 914 passed / 31 opt-in skips**. Actual PG16 lifecycle and
native-pg guard test passes (17.083s, nine constructors,54 real queries,18 endpoint
rebindings,81 exact refusals); actual PG18 custody-size regression passes (3.614s),
both with exact-owned cleanup. The separate real Rails composition also passes
(**1 test / 163.569s**): nonempty baseline bytes, native refusal/digest backstops,
selective assets/references, actual backup and corrupt/missing/tampered/excluded
archive rejection. Its SQL-only fixture transport now keeps a local identity record
for the changed provision API, never invented daemon/producer/durable-v2 evidence;
the connected test above remains the lifecycle authority. Ruby/Python syntax, gem
build and all **130 packaged files byte-identical** checks pass. No independent
model review is claimed.

Fixture-owned cleanup confirmed. All claimed CLI/stock/asset/archive/settings/
persisted-state assertions ran, including the formerly failing final gate; no
canned lifecycle success or bypass was substituted. None of these local findings
reconstructs the customer's discarded exception.

A passing run, once obtained, is not hosted restore, production readiness, release
approval, customer-policy validation, an optimized-source test or permission to
resume any customer operation. Restricted backup release/hosted restore remain
separate later steps. No existing customer/server service is deployed or restarted,
and no infrastructure/provider configuration is changed; all runtime effects are
confined to this invocation's disposable local fixture resources.
