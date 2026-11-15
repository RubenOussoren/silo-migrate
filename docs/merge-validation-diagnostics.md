# Saved Merge validation diagnostics and owned cleanup

## Read the existing failure — do not rerun it

From the service account (`silo shell`), after the release containing this command
is installed, use the **installed prefix launcher**, not `current/bin`:

```sh
CONTROL=/srv/silo-migrate/bin/silo-migrate-control
"$CONTROL" standard workflow validation-status PROJECT --attempt latest
# Pin the returned attempt_id for subsequent inspection:
"$CONTROL" standard workflow validation-status PROJECT --attempt ATTEMPT_ID
```

Replace `PROJECT` with the existing project name. `ATTEMPT_ID` is the returned
32-character lowercase hexadecimal ID, not a Prepare run ID. This command reads
only existing, workspace-scoped validation receipt/resource-journal files. It does
not validate, load settings or custom code, query PostgreSQL, inspect/start Docker
resources, clean anything, change workflow state or obtain a Start binding.
The control launcher still performs its normal control-image identity checks.
The new command is engineer/trusted-only, not an added coding-agent capability.

The JSON is deliberately safe to return to the coding agent:

- `attempt_id`, `evidence.receipt` and `evidence.journal` identify what was found.
- `work.reason` is the preserved primary fixed refusal when available;
  `reason` is the outer saved result (which may be recovery-required).
- `work.stage`, `deadline_reached` and `command_outcome` report recorded facts,
  not guesses. A recorded stage is not proof that its operation completed.
- Optional `work.error_class` / `cleanup.error_class` contain only an allowlisted
  exception class (`other` for unknown/custom classes), never its message. Fixed
  host execution substages distinguish image verification, sidecar create/readiness,
  private staging, guest copy/launch and result verification. A host-side failure
  before Ruby starts is not mislabeled as a guest diagnostic. Legacy records omit
  the class instead of inventing one.
- `producer_outcome` is independent of validation success and cleanup proof.
- `cleanup.status` comes from the resource journal, independently of the historic
  receipt. Recovery never turns a failed receipt into a passing one.
- `key_path_segments` is only a length; private key names, counts, SQL, paths,
  exception messages, settings, credentials and raw stderr are not echoed.
- Optional `guest_diagnostic` retains a fixed guest stage, allowlisted native/error
  class, generic shipped-source component and bounded public-source line. Custom
  class names and private layer paths/line numbers are never projected. This can
  distinguish a Rails boot/database/guard failure from a policy-hook refusal
  without exposing the exception message or query.
- `next_action` is guidance, not authorization or an automatic retry.

Legacy journals may have no producer evidence. Missing, unreadable, malformed,
symlinked, oversized or publicly readable evidence is **unknown**, never success.
The legacy `latest` selector uses newest saved file modification time; equal times
across different IDs are ambiguous and require an explicit ID. Recovery or manual
file changes can affect that ordering. Once identified, always use the exact ID.
A missing receipt with an existing journal is an incomplete attempt, not a pass.
A generic recorded reason may be all the old release retained; this command cannot
reconstruct an exception or a producer outcome that was never saved. In particular,
no saved timeout field alone proves an SQL timeout or that a child stopped.
A false overall work deadline also does not rule out a narrower guest-command
timeout. New attempts record a guest timeout/interruption separately while keeping
producer completion unknown; this does not raise or otherwise change any timeout.

Custom proposal failures retain `STANDARD_MERGE_VALIDATION_FAILED` on stderr and
exit 1, but now also emit a safe JSON `validation` envelope on stdout containing
this attempt reference and diagnostics. Pre-attempt refusals have a null attempt
ID rather than fabricating a receipt. Existing consumers that only use the outer
fixed refusal remain compatible. Read the JSON rather than parsing private logs.

## Incremental ownership and exact-attempt recovery (new attempts)

New attempts save version-2 resource journals. Each CREATE intent is written before
its effect, and its exact successful object identity is saved before later
restrictions/checks. Clones start closed to connections while ownership and access
restrictions are recorded. Resource outcome, work outcome, producer completion,
stage events and cleanup are separate facts. A typed policy refusal remains a
failed validation even when all scratch resources are successfully removed.
Unknown/lost CREATE responses remain quarantined; generated names are not ownership.
The normal cleanup reconciles known subsets and recorded deletions, but is not a
provisioning-resume engine and never retries validation automatically. Guest and
SQL terminal outcomes use exact invocation nonces; a bare Docker CLI status is
not proof. A nonce-proven bootstrap exit remains failed work, but can clean its
known owned subset. Missing/mismatched terminal frames remain unknown, even when
current resources happen to be absent. Guest diagnostics are retained in both
saved receipt/journal evidence so a subsequent read does not require another run.

These engineer-only commands are distinct from saved status:

```sh
# Explicit live read-only runtime/catalogue checks; not the first diagnostic step:
"$CONTROL" standard workflow validation-recovery-preview PROJECT --attempt ATTEMPT_ID
# Only after reviewing that exact preview AND authorizing this cleanup scope:
"$CONTROL" standard workflow validation-recovery-apply PROJECT --attempt ATTEMPT_ID --intent-sha256 REVIEWED_SHA256
```

Recovery never accepts `latest`. Preview checks current runtime/container binding,
protected template custody, exact object identities, producer completion, sessions,
role dependencies and relevant guest/Redis ownership. It does not delete resources
or rewrite the receipt/journal. Apply rechecks those facts under locks and requires
the exact preview digest, saving a separate immutable recovery intent before any
cleanup. A changed journal, receipt, resource identity or runtime requires a new
preview/review, not repinning to force an old approval to pass. Partial cleanup
can be re-previewed only when known ownership/producer facts still permit it.

Recovery will not terminate sessions, use DROP FORCE/CASCADE, remove an unproved
guest directory, adopt a name-only resource or force-remove a running Redis
sidecar. A running sidecar needs a separately authorized stop and a fresh preview;
the recovery command does not silently expand approval to stop it. Failed receipts,
workflow state and approvals remain unchanged; cleanup cannot make validation pass.
Normal exact-owned cleanup retains its existing clone-session/Redis-stop behavior;
that behavior is deliberately NOT extended to explicit recovery.

Legacy version-1 journals, incomplete ownership, ambiguous CREATE windows and
unknown executors still refuse recovery. Installing this release does not create
missing historical ownership. Such attempts need explicit reviewed reconciliation;
do not rerun validation, reset/Prepare or reuse an older spent helper to evade it.
For new completed failures, ordinary cleanup should avoid that manual loop.

## Cached/pinned-only local acceptance admission

The ordinary launcher resolves/prepares a public review runtime and may enqueue
its fixed on-demand preparation worker. For local fixtures or an engineer who
explicitly wants **no image acquisition/preparation**, the installed launcher now
supports this invocation-only prefix on an initial Base-backed proposal:

```sh
"$CONTROL" --cached-review-runtime standard plan propose PROJECT --operation merge-prepare --source SOURCE_INPUT --base-site BASE_INPUT
```

It is not a tool-JSON field, persistent environment setting, or a Start override.
It admits only the workspace's hash-bound, qualified/review-ready catalog profile:
actual cached web content identity, version/revision/Ruby/Bundler/lock metadata,
all supplied Base migration IDs and PostgreSQL requirements must match. It runs
fixed short public-image metadata and frozen-bundle probes with no network or data
mounts. Missing images, an unknown/plugin migration, version mismatch or failed
bundle check refuses; there is no pull, build, background worker or preparation
fallback. The standard backend still rechecks profile/image/version/qualification,
input identities and all normal workflow gates. No ready-job record is fabricated.
Prepared custom proposals and Start continue using the Prepare's exact frozen
runtime and do not accept this flag. Ordinary term-llm operation is unchanged.

## Operational boundary

Publishing this source does not install it or authorize server updates, cleanup,
reset, re-Prepare, a new proposal, Approve or Start. Keep the existing Prepare and
its failed receipt. Do not reuse a spent recovery helper. First return the saved
status for the already-failed attempt; decide the next exact action from evidence.
A passing proposal still requires exact engineer approval and a separate Start.
term-llm remains the normal interface; the operator command is a narrow diagnostic
path, not a new orchestration service or a change to term-llm core.
