# Named workspace foundation (synthetic-only)

This opt-in foundation registers synthetic file inputs and records one operation,
`validate-inputs`. It is not a converter, database runner, analyst session,
publication mechanism or separate orchestration framework. The application
service is the authority; CLI and future adapters call the same operations.

## Mode and identity seam

A fresh named workspace owns one opaque root-bound workspace identity in
`.silo-migrate/named/state.json`. Presence of `.silo-migrate/named` (including
corrupt state or a dangling symlink) refuses legacy project paths. Unreadable or
looping authority paths are also refused, never treated as absent. A workspace
containing both the named marker and legacy `config.env` blocks the legacy `list`
and interactive picker with a fixed error before any config is printed; other
projects are not listed until the mixed state receives private operator review.
Named mode has no `config.env`, Compose configuration or initial/final workflow authority.
Do not remove the marker to repair a workspace or transplant state to a new root.

Named mode is deliberately **release-disabled**. The legacy release store refuses
it before looking for `config.env` or creating its own identity. No shared release
identity is introduced. Existing legacy release snapshots, approvals, revocations
and views are not migrated, reset or rebound. Registration/checksums/completion
never approve bytes for release. A later publication bridge needs a separately
reviewed identity/locking design and explicit approval.

All named mutations use `.silo-migrate/named/lock`; operation ownership covers
input checking. Atomic private state replacement occurs under that lock. Legacy
workflow/release stores retain their existing locks because co-residence is
unsupported, not because those locks form a common authority. This is cooperative
locking on an operator-owned filesystem, not authentication or an OS sandbox.

## Supported intent

- Initialize a fresh file-only workspace.
- Register a named source, datasets under it, and exact synthetic files under
  `inputs/`. No input is copied into a converter checkout or release view.
- Plan `validate-inputs` for the exact inputs of one dataset, then execute the
  returned run ID once. No SQL parsing or semantic format validation occurs.
- Show a run's safe structured outcome.
- Explicitly recover a persisted running run after its process loses the lock,
  recording `interrupted`. No elapsed-time inference, retries or auto-resume.

Sources, datasets, inputs, plans and runs have opaque typed IDs. Private labels
are not identity. Development and launch are optional operator labels; two full
snapshots remain independent datasets and do not imply delta or merge semantics.

The lifecycle is `planned -> running -> completed | failed`; explicit recovery
can change an abandoned `running` record to `interrupted`. A planned record is
not proof of execution. A process/storage failure may leave running state requiring
manual recovery; failure to durably save completion never returns success.

## CLI

```
silo-migrate named init WORKSPACE
silo-migrate named source add WORKSPACE --platform LABEL [--label LABEL]
silo-migrate named dataset add WORKSPACE --source SOURCE_ID [--label LABEL]
silo-migrate named input add WORKSPACE --dataset DATASET_ID --path inputs/FILE --sha256 HEX --bytes INTEGER --type LABEL
silo-migrate named plan validate-inputs WORKSPACE --dataset DATASET_ID
silo-migrate named run execute WORKSPACE RUN_ID
silo-migrate named run show WORKSPACE RUN_ID
silo-migrate named run recover WORKSPACE RUN_ID
```

WORKSPACE uses the existing configured base directory. Files must be explicitly
supplied synthetic regular files: no symlinks, hardlinks or path traversal. File
identity, expected size and SHA-256 are bound privately and checked for mutation
or replacement. A checksum proves byte agreement, not safety or SQL validity.

The named CLI uses strict exact options. It outputs versioned JSON with opaque
IDs, fixed statuses/error codes and allowed counters only. Paths, labels, digests,
input content and raw exception causes do not belong in default output. Supply
these only through the private operator interface, never customer data in coding
chat. This slice's use is synthetic-only even though the interface is file-based.

## Budgets and conservative invalidation

The initial registry has fixed lifetime limits: 128 records per kind (sources,
datasets, inputs, plans and runs), 1 KiB per private metadata value, 16 MiB per
input, 64 MiB across registered inputs, and 1 MiB serialized state. There is no
automatic pruning, retention job or reset-on-exhaustion behavior. These modest
limits are for synthetic foundation tests, not a production SQL dump sizing
claim. Saves reserve the largest terminal representation for every planned or
running run, so new registry/plan records cannot consume already accepted runs'
completion/failure/recovery headroom. Input type is a bounded lowercase label,
not inferred content validation.

Registry source/dataset/input mutations conservatively invalidate older plans,
even when the mutation affects another dataset. Plans/runs themselves do not
change the registry generation. Re-plan explicitly; no stale plan is rewritten
or silently retried. Lock contention returns a fixed busy error rather than
waiting indefinitely or assuming that a running record has crashed.

## Recovery and diagnostic limits

A failed validation records the failing opaque input ID and a fixed reason code
privately; terminal output retains only the safe run outcome. Raw exception text
and causes are not retained or printed by this foundation. After hashing, a final
identity pass checks all selected inputs again before completion. This narrows
cross-input mutation windows; completion does not promise lasting immutability
or that an unrelated writer cannot change inputs immediately afterward.

If initialization fails before any `state.json` exists, an explicit `named init`
retry may reuse only the lock/marker and an **empty private** `inputs/` directory.
It never adopts files or an existing identity. Unknown state/temp files or
nonempty inputs block initialization; nothing is automatically deleted. Preserve
that directory and use a new workspace name, or obtain approval for an exact
manual repair after private inspection. Never remove the marker to regain legacy
access, transplant a state file or erase an existing identity. If state already
exists, initialization refuses even if an earlier terminal response was lost.

`run execute` exits nonzero on a persisted failed validation while returning its
safe JSON descriptor. `run show` exits zero when it successfully reads that same
failed record; it does not retry or reinterpret it. Command/parser/storage/output
failures exit nonzero with fixed errors. Fatal signals/interrupts are not a
universal fixed-error containment guarantee. Init fsync behavior is tested through
injected sync failure, not power-loss simulation; a retry does not rediscover
base-path ancestors created by an earlier failed attempt. A command's lost output
is not proof that its durable operation did not complete; inspect private state
before taking action.

## Exclusions

No Docker/provider call, credential, database, SQL parsing/execution, conversion,
import, real session, destination lineage, delta/merge, legacy upgrade, release
bridge, cleanup/retention automation or customer-use acceptance. No runtime
sandbox or authenticated-caller claim. Further operations require approval.
