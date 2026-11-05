# Standard local backup: launcher-based CLI slice

For the runtime-tested path, see [Standard local migration workbench](standard-workbench.md). It uses a frozen prebuilt image and has run end to end on synthetic data.

This page describes the older `discourse_docker` launcher route through `silo-migrate discourse`. It has only been tested with fake runtimes, and it needs a launcher role built from the same application revision as the checks below. No runtime/container/download/install/build action is included here.

## Same-destination import-role path

The intended standard path keeps the engineer-provided baseline and imported records in one local site: start the `import` role, save an explicitly named baseline backup before upload processing, run uploads against that same role, perform the standard import (including its processing database), then create an explicitly named final backup. Example command shape only:

```sh
silo-migrate discourse setup acme --standard-local
silo-migrate discourse rebuild acme --role import
silo-migrate discourse start acme --role import
silo-migrate discourse prepare-deps acme --role import
# Restore the engineer-provided baseline into the pristine import role.
silo-migrate discourse restore-import acme --backup /path/to/engineer-baseline.tar.gz
# Capture it under a distinct explicit local archive identity.
silo-migrate discourse backup-import acme --filename baseline-before-import.tar.gz
silo-migrate discourse run-uploads acme --role import
silo-migrate discourse import acme
silo-migrate discourse backup-import acme --filename final-local-migration.tar.gz \
  --required-upload uploads/default/original/sandbox.txt \
  --required-upload uploads/default/original/source.txt
```

`--filename` is the requested safe basename; upstream appends `-v<app-version>-<schema>.tar.gz`, so the actual archive has a longer, versioned name. The service reserves a new exclusive local directory for that requested stem before invoking upstream, and puts the returned exact archive and manifest there; a failed attempt keeps the reservation. Re-running requires a different requested stem. `--required-upload` is optional and repeatable; for a standard rehearsal supply exact expected archive member names for both sandbox and source attachments. Validation fails closed on PAX/extended tar entries, so this currently supports only the tiny fixture archive. The standard-local CPU guard requires actual `Etc.nprocessors == 1`; a quota or worker setting is not a substitute. The baseline command should likewise use an explicit, distinct requested basename.

`--standard-local` opts into the small local text-fixture profile; it does not remove global settings or make customer data safe. Keep the engineer baseline distinct from migration input. Import requires its processing database by default; `--no-uploads-db` is an explicit escape and is not the standard path. Standard import checks the single-use destination issue report with a 64 KiB bound; that check is not runtime acceptance. `prepare-deps` checks the frozen bundle and must not install or resolve dependencies.

The split uploads/import workflow remains available for legacy cases, but uploads processing alone does not transfer the complete site state. If those roles are deliberately separated, a post-upload full database-plus-uploads backup/restore bridge is required before import; the uploads SQLite file alone is insufficient.

## Boundaries and evidence

Backup member validation establishes archive contents only. It is not runtime readiness, successful import, backup-restore proof, hosted-review acceptance, or production portability. The returned archive and manifest are labelled `archive-validated`, not `restore-proven`. Do not describe an archive as restore-proven without a separately approved fresh-local restore and preservation/attachment checks.

Guided workflow's existing backup action does not supply the required explicit filename. Use the explicit `discourse backup-import ... --filename ...` CLI command for these baseline/final artifacts; this task does not modify Interactive. `--required-upload` member checks do not compensate for missing restore validation.

Distinct other-converter, new-converter, delta-import, multi-source, and native-merge paths remain distinct; this workflow does not replace them or globally remove settings. Hosted review restore, production restore, DNS/traffic changes, and operational acceptance remain human handoffs.

For this launcher route, launcher/templates/base digests and a matching final image remain unpinned. Static cache presence is not a ready image. Use only fresh, independent writable scratch copies in the existing project mounts; never mount accepted inputs/caches writable or hardlink SQLite inputs into scratch. Frozen dependencies and runtime must be prepared separately. Do not infer automation, readiness, or execution authorization from these CLI examples.

No customer/private data or runtime actions are authorized by this document.

## Offline checks and remaining runtime gates

The standard-only contract requires Discourse app revision
`3158c7503a59d0952c84cc8c032790e80167bf38`, Ruby `4.0.9`, Bundler `4.0.23`,
and app lock SHA256
`bacaa276aebc56385bf28c9fefbc6224e494e0361bd734933b4a20427e0f87d2`
(read from the prebuilt image; see `runtime/prebuilt-discourse/runtime-lock.json`).
These are not launcher/base/final-image pins. Dependency checks do not install, resolve, update platforms or rewrite locks.
Tiny generated settings (one worker, DB pool5, shared buffers128MB, connections20)
are a preparation profile, not verified resource sizing or a runtime approval.
Loopback ports, disabled email/Sidekiq and LocalStore checks are not network
isolation. Separate approval must pin the launcher/templates/base/final image,
frozen recipe/manifests, egress policy and CPU/memory/PID/storage/log/time budgets.
The inherited service operation timeouts are not a complete bounded run recipe.
Use a new owned disposable backup store: upstream backup retention cleanup can
remove older archives. Keep independently retained baseline/final archives on the
host; the new output identity is not a safety guarantee for an existing store.

Before upload processing, the approved synthetic baseline must explicitly disable
S3/secure uploads, anonymous-download restrictions and remote-image downloading.
One actual uploader worker requires `Etc.nprocessors == 1`, not just CPU quota.
Baseline durable records/ownership/settings and sandbox/source attachment bytes
still need an exact independent runtime oracle, collision refusal/decision and
fresh-local restore/HTTP checks. The code records baseline/input/output digests;
it does not establish semantic preservation or customer/plugin portability.
A new launch snapshot must start at the accepted PRE-import baseline, not the
development-imported review database. No automatic delta/merge is implied.

Ruby regression commands (when an authorized host toolchain is available):

```sh
ruby -Itest -e 'ARGV.each { |file| require_relative file }' \
  test/discourse_service_test.rb test/discourse_compatibility_test.rb \
  test/workflow_state_test.rb test/cli_test.rb
rake test
```

A supplemental host-only shell-contract check uses the existing Python and sh,
substitutes shell builtins for the importer, and runs no Ruby/Discourse/container:

```sh
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s test \
  -p offline_standard_import_shell_test.py -v
```

Passing that check is not passing the Ruby suite, readiness, real import or restore.
