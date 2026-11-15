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
- `producer_outcome` is independent of validation success and cleanup proof.
- `cleanup.status` comes from the resource journal, independently of the historic
  receipt. Recovery never turns a failed receipt into a passing one.
- `key_path_segments` is only a length; private key names, counts, SQL, paths,
  exception messages, settings, credentials and raw stderr are not echoed.
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

Custom proposal failures retain `STANDARD_MERGE_VALIDATION_FAILED` on stderr and
exit 1, but now also emit a safe JSON `validation` envelope on stdout containing
this attempt reference and diagnostics. Pre-attempt refusals have a null attempt
ID rather than fabricating a receipt. Existing consumers that only use the outer
fixed refusal remain compatible. Read the JSON rather than parsing private logs.

## Operational boundary

Publishing this source does not install it or authorize server updates, cleanup,
reset, re-Prepare, a new proposal, Approve or Start. Keep the existing Prepare and
its failed receipt. Do not reuse a spent recovery helper. First return the saved
status for the already-failed attempt; decide the next exact action from evidence.
A passing proposal still requires exact engineer approval and a separate Start.
term-llm remains the normal interface; the operator command is a narrow diagnostic
path, not a new orchestration service or a change to term-llm core.
