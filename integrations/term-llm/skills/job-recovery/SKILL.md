---
name: job-recovery
description: Diagnose busy-project messages and Files corrections blocked by active jobs; distinguish saved running status from container liveness and guide separately approved one-job reconciliation without resets, reruns or file changes. Use when the engineer asks what is going on with stuck work.
---

## Blocked corrections and stale jobs

Use this procedure when the engineer asks "what's going on?" about a busy project
or a Files correction blocked by affected work. Explain the next bounded step,
not just "settle it". Stay within this project's private migration-data chat.

1. **Distinguish the messages.** A floating `STANDARD_BUSY` notification means a
   request could not acquire a lock; it does not prove a migration is running,
   or that a correction failed or committed. Do not bypass the lock. A Files
   preview's **Active dependencies** lists saved job/run states and intentionally
   blocks confirmation. The preview does not check job-container liveness.
2. **Identify, don't guess.** Use the exact job ID from the preview. `data_status`
   can show cached metadata for the ten most recent jobs, not refresh liveness;
   absence there is not proof the job is gone. A `run-` dependency is a different
   workflow, not an argument to `data_job`. If a read-only liveness check is needed,
   ask the engineer/operator for a check scoped to that job's Docker state only,
   without logs, names, mounts, credentials or customer contents. You have no
   generic host shell: do not manufacture a `data_script` to inspect host state.
3. **Explain effects and obtain explicit approval for old-job recovery.** `data_job` is
   **not read-only**: it may record a terminal status, retain a private log tail,
   remove the job's exited/missing container, and for a `db_load` perform normal
   post-load database read-only-account hardening/checks. If a non-load job is
   still running, its low-disk protection may stop it. A question about status or
   a blocked correction alone is not permission for these recovery effects.
   Ask approval for one call on the exact job, including those applicable effects;
   do not promise a purely observational call. Normal polling of a job the
   engineer already authorized you to start is its normal completion lifecycle,
   not a reason to request approval for every poll.
4. **Reconcile once, then stop.** After explicit recovery approval, call
   `data_job(job_id=EXACT_ID)` once. If it remains running, its job record is
   missing/unreadable, or Docker is unavailable, report that uncertainty and leave
   the correction blocked; do not loop, kill, restart, re-load, rerun, reset, delete
   job/lock records or edit JSON. Do not escalate to generic scripts or another agent's
   permissions. A terminal failed/timed-out/lost job is not successful output.
   Preserve original files, partial outputs, audit records and run history.
5. **Report accurately and return control.** Summarize job kind, status, exit code,
   `oom_killed` and any applicable post-load checks. Keep logs and customer file
   names/contents private; never send them to coding agents. Exit 137 with
   `oom_killed=false` is classified `timed_out` by the tool, but does not prove
   timeout was the cause or that a memory limit was never reached. `finished_at`
   may be reconciliation time, not the actual container exit time. Tell
   the engineer to generate a **fresh correction preview**, inspect all remaining
   dependencies and choose whether to confirm. You cannot confirm it, and must
   not automatically retry the failed job or manufacture a replacement source.
