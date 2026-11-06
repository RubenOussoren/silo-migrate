# Debian metal installer (single account; synthetic MVP)

`script/metal` installs the containerised control runtime, not host Ruby, Node or
compilers. It is a Bash `set -euo pipefail` entry point with an isolated Python
stdlib engine (`python3 -I`), shared with the package/identity tools. Debian 12
amd64 is the supported target. Python 3 and Bash are bootstrap requirements
(the Debian cloud image includes them); the planner installs only missing
packages from its documented prerequisite list, with `--no-upgrade --no-remove`.
These flags do not pin versions or prevent new dependency installs or package
maintainer scripts from enabling/starting services.

**This is not customer-data isolation, target deployment approval or hosted
acceptance.** Docker group membership is root-equivalent. The term-llm service bearer token
is therefore also a **root-equivalent credential**, not a narrow migration API key. No Hub registration,
provider credentials, extension installation, memory mining, jobs or cron are
configured. Existing Docker installations, running containers and existing
account term-llm configuration are preserved. Do not run verification against a
live demo's workspace. Verification creates a fresh synthetic workspace.

## Review, then apply

Run from a checkout readable/executable by the service account. Put the literal
config somewhere that account can read; it must contain **no credentials**.
`config/metal.example.conf` documents every accepted key. Unknown/duplicate keys,
quotes, shell syntax, credential-bearing URLs and unsafe paths are refused.
Only the exact `$SILO_PREFIX/workspaces` default token is expanded; this is not a
shell script. A separate `SILO_WORKSPACES` disk is supported.

```sh
cp config/metal.example.conf /appropriate/readable/location/metal.conf
# Edit repository/branch, prefix, workspaces, artifact directory and service policy.
script/metal preflight --config /appropriate/readable/location/metal.conf
script/metal preflight --config /appropriate/readable/location/metal.conf --json
script/metal plan --config /appropriate/readable/location/metal.conf
script/metal plan --config /appropriate/readable/location/metal.conf --plan ./reviewed-plan.json
# Review the exact ordered root/account sections and recorded SHA256.
script/metal apply --config /appropriate/readable/location/metal.conf --plan ./reviewed-plan.json
script/metal status --config /appropriate/readable/location/metal.conf
```

Without `--plan`, plan writes **nothing**, including no temporary clone or
binary download. With it, the only write is an exclusive mode-0600 JSON plan
file containing the plan and SHA256 of its canonical JSON. Use a new filename
when replanning. Apply recomputes it and refuses *any* difference before root
steps. A changed branch commit, artifact package, account/config state or
installer bytes requires fresh review. Successful unchanged re-apply prints
`METAL_UNCHANGED: no writes`; the Debian VM test checks that nothing under the
prefix changes, including `state/tmp`. A changed companion helper (`script/package-artifacts`,
`image_identity.py`, `image_archive.py`) also stales the plan; run from a
checkout so they sit beside `script/metal`. After account creation the read-only plan/status
snapshot is taken as that account where the invoking admin cannot traverse the
0750 prefix. Apply escalates its serialized root phase explicitly; account
steps still execute as the configured non-root account. Preflight never invokes sudo.

Preflight reports OS, architecture, logical/physical CPUs, load, total/available
RAM, swap use and optional `vmstat 1 3` si/so sample, `/tmp` filesystem/usage,
free disk, Docker version/source/storage/container count and summed running
container CPU/memory limits (uncapped counts separate), occupied ports, account,
groups, directory ownership, existing term-llm/config/units, missing packages,
linger and repository branch reachability. Unknown/unreadable state is reported,
not treated as permission to replace it. No container names, inspect environments
or credentials are printed. Missing Git is handled by read-only bare refs or a
bounded smart-HTTP ref advertisement until apt installs Git.

OS/architecture refusal is fatal. `--allow-untested-os` only permits Debian 13
or Ubuntu with warnings; automatic Docker installation still requires Debian 12.
Capacity needs 4 logical CPUs, **8 GiB available** RAM and **48 GiB free** (40 GiB
new plus 8 GiB reserve) on both relevant filesystems. Capacity is reported, not
a shell-install refusal, so the deliberately undersized test VM can install the
control shell. `metal verify` refuses below these thresholds before creating a workspace;
full migration admission also remains enforced by the workflow.
Swap usage, load and other workloads are informational, never swap-based refusal.
The profile's 4.0-CPU/8-GiB aggregate migration envelope is admission-checked and
Docker-enforced **per container**, not a host-wide quota; it has **not** been
sized against other workloads on migrations05. Engineer-supplied hardware/OS
beliefs are not baked into detection. RAID, LUKS and boot/EFI changes are out of
scope. Existing Docker, including docker.io, is never replaced with Docker CE.

The root plan's Docker action refuses existing `/etc/apt/keyrings/docker.asc`
and `/etc/apt/sources.list.d/docker.list`; neither is overwritten. It verifies
Docker's primary signing fingerprint
`9DC858229FC7DD38854AE2D88D81803C0EBFCD88` with GnuPG before publishing the key.
The plan explicitly reports that apt maintainer scripts may enable/start
Docker/containerd and Docker can change iptables/nftables forwarding/NAT rules.
This is not a no-services/no-firewall operation on the installation target.
These root effects are **not executed by the offline regression tests**.

## Files and service

Managed directories are owned by the regular account with mode 0750. Existing
wrong-owner directories or symlink directory conflicts are refused, never
recursively chowned. Releases are detached clean checkouts under
`releases/<commit>`; `current` and `previous` switch atomically. No data is copied
from the engineer's home. Large downloads, release/cache staging and child
`TMPDIR` use **`$SILO_PREFIX/state/tmp`**, never the host's RAM-backed `/tmp`.
Apply copies the entire package into an account-owned **0700** temporary
snapshot under `state/tmp`, verifies that copy against the approved hashes, and
uses only the snapshot for load/extraction. It is removed on success or failure.
Plan records UID/GID/mode for the package directory and **all** ancestors of it,
managed directories, the workspace and account home. Root/account ownership and
no group/world-write are required, even on sticky temporary directories. Deliver
packages to an appropriate trusted filesystem, not `/tmp`. Managed directory
creation walks directory descriptors with `O_NOFOLLOW`, refuses wrong owners,
and never recursively repairs ownership. Prefix is canonicalised once during
configuration; workspaces may be separate or exactly `P/workspaces`, never
elsewhere overlapping the prefix. Stale installer-owned `.metal-link-*` symlinks
are cleaned without deleting ordinary files.

The pinned term-llm v0.9.93 linux_amd64 archive must match **both** the installer
SHA256 `2d264d175d7f8a7108a3d3530338efa2b81dadcaf5ce02c3d0f701fa88ad3d4e`
and release `checksums.txt`. A binary hash receipt detects later corruption.
`bin/term-llm` points at `term-llm/0.9.93/term-llm`.
`etc/silo-control.env` provides:

- `SILO_MIGRATE_BASE_PATH`: workspace root;
- `SILO_CONTROL_GEMS`: content-addressed extracted gem cache;
- `SILO_CONTROL_SITE_CACHE`: **the `site_settings.yml` file**, not its directory;
- `SILO_RUNTIME_PROFILES_DIR`: `state/runtime-profiles` (server-local candidates,
  **not** a second mount of the release's own `runtime/profiles`). Empty/different
  local profiles leave release names resolvable; a duplicate name is refused.

The shim exports `SILO_CONTROL_CONFIG` and execs the installed control wrapper.
No artifact package means a deliberately **not migration-ready**, shell/service
installation; images/cache loading is explicitly skipped and status says so.

Fresh term-llm directories get config-only provider discovery, empty providers,
`approval.default_mode: prompt`, `serve.approval_mode: prompt`, empty
`serve.extensions`, `serve.auto_title: false`, and `serve.projects.enabled: false`.
Existing config/data are never overwritten or imported. Agent links point at
`current/integrations/term-llm/{migration-operator,migration-analyst}`; conflicting
existing definitions are refused. Existing config safety requires manual review,
especially before any customer data. Same-user agents are not OS isolation.

Confirmed against the **real 0.9.93 binary's help**: `service install web`,
`--binary`, `--no-start`, `--dry-run`, and serve flags `--host`, `--port`,
`--auth bearer`, `--approval prompt`, `--agent migration-operator`, `--no-projects`,
`--disable-extensions`, `--disable-widgets`. Plan uses stock service dry-run when
the installed binary/account exist, otherwise explicitly defers it; apply runs
it before writing service files. `install` writes without starting;
`install-and-start` additionally enables/starts; `skip` changes neither linger nor
service. A non-secret systemd user drop-in supplies `SILO_CONTROL` (the installed
shim), `SILO_CONTROL_CONFIG` and `TMPDIR` to the linked agent adapters; it does not
import credentials or modify the stock generated unit. For interactive `ask`,
export those two SILO variables in the account shell too. Unmanaged existing units are refused, not adopted. The listener is
127.0.0.1 only; no firewall, reverse proxy, remote access or Hub configuration.

Config schema reference: <https://term-llm.com/reference/configuration/>;
service behavior: <https://term-llm.com/guides/background-services/>.
**No widget-disable or automatic-memory-mining config key was confirmed.** The
installer does not guess either: widgets/extensions use the confirmed CLI disable
flags, and it registers no jobs/mining automation. Existing jobs are not removed.
Do not infer that preserving an existing config makes it work-only.

Provision provider access **as the account**, separately, using `term-llm auth`
or `term-llm service install web --secret NAME` with masked input. `NAME` is a
credential variable name, **never its value**. Do not pass token/API-key values
on argv, paste them into config, or use service token output in logs. Hub
registration is opt-in only after an approved Hub and access policy.

**Token authority:** checked `term-llm serve --help`, `term-llm agents --help`
and `--version` on the installed **0.9.93** binary, without starting a server.
`--agent migration-operator` selects the startup agent; it is not an agent
allowlist. The official [agents guide](https://term-llm.com/guides/agents/)
describes named agent selection and native Web/CLI handovers to other agents
with their own tool permissions. The [Web guide](https://term-llm.com/guides/web-ui-and-api/)
also documents an authenticated interactive shell and explicitly says a shared
bearer token represents one operator security domain. Thus a token holder must
be trusted as the service account, including choosing other available agents;
prompt approval and `--no-projects` are not a security boundary against that
operator. This is documentation/help evidence, **not** a live HTTP authorization
probe. Do not distribute this token to restricted/customer users.

Per the [official service guide](https://term-llm.com/guides/background-services/#where-credentials-live),
Linux secrets are mode-0600 files in the private
`~/.config/term-llm/services/web/` directory (or the corresponding
`$XDG_CONFIG_HOME` location), alongside `service.json`; the launch specification
contains names, not values. No token/secret file was opened for this check.
`service token web` explicitly discloses it: never capture that output in logs.
An existing systemd user manager does not acquire `usermod -aG docker` changes
until it is restarted/newly started; schedule an explicitly approved manager
restart/logout, not merely a unit daemon-reload or service restart.

`state/install-manifest.json` and `state/history.jsonl` record repository/branch/
commit, term version/archive SHA, package id/checksum, image refs/content_ids/
local ids, config and plan hashes, operation and timestamps. Logs in
`state/logs/` contain fixed event labels/identities only. Child output is captured
and never logged: failures report fixed stage codes, not raw stderr or argv.
This deliberately limits failure diagnostics; inspect prerequisites locally
without dumping service/config credentials, fix them and generate a new plan.
Apply is not a transactional rollback of apt/account changes after a later error.

## Offline artifact allowlist

```sh
python3 -I script/package-artifacts build \
  --profile runtime/profiles/discourse-2026.11.0-latest-3158c750.json \
  --gems /approved/public-gem-cache \
  --site-settings /approved/public-site-cache/site_settings.yml \
  --output /new/package-dir
# Optional --include-public also saves public-digest images, including control.
script/metal artifacts verify /new/package-dir
```

Only package-source images are saved by default, with Docker's
`image save --platform linux/amd64` and gzip. Public images, including control,
are pulled by digest on the target unless explicitly included. The source
profile, image tarballs, deterministic sorted/numeric-owner gem archive,
`site_settings.yml`, manifest and `SHA256SUMS` are the entire allowlist.
Symlinks/special files, credential-like gem names (`*.pem`, `*.key`, `.netrc`,
`credentials*`, `*token*`), unlisted/missing/tampered files, duplicate archive
members and profile mismatch are refused. SHA256SUMS covers every other file
(not itself). The manifest SHA is the package id; SHA256SUMS has a separate hash.
No `.runtime-cache` tree, config, sessions or memory is copied wholesale.

Before extraction/load, apply verifies the package against the exact release
profile filename (`manifest.profile.name + ".json"`), then verifies **every**
runtime image plus control by portable
content_id. IDs retain the `sha256:` prefix; control's profile identity is
`sha256:c04e168879ee10209715c71cf0eb1814e7308fa794329c55ae59c508f1e7d165`.
`python3 -I script/image_identity.py REF` or `--inspect-json FILE` canonicalises
architecture, OS, diff IDs and Cmd/Entrypoint/Env/User/WorkingDir, with UTF-8
(non-ASCII not escaped) matching Ruby. These are not Docker local image IDs. Missing Architecture/OS normalises to
an empty string; shared Unicode/control-character Env fixtures test Ruby,
Python and the wrapper. The wrapper reads control's identity from the bound
profile (including its persisted profile SHA), never a fixed content ID.

Before Docker sees an image tar, a stdlib parser checks `manifest.json` and/or
OCI `index.json`: exactly one image, matching config digest, actual uncompressed
layer SHA256/diff_ids and expected content ID. Docker RepoTags must be `[]` or
exactly `[expected_ref]`; foreign OCI reference annotations are refused too.
All existing tags are snapshotted using `docker image ls --no-trunc --format`
before/after load. Any unrelated tag change refuses with
`METAL_IMAGE_TAG_CHANGED`; it is reported, **not automatically rolled back**.
This also detects concurrent unrelated retagging conservatively.

A Docker archive is not proof that a registry digest reference was restored.
If `docker image inspect ORIGINAL_DIGEST_REF` cannot resolve after load, the
installer inspects the validated config image ID, requires its content ID, then
tags `silo-migrate/loaded:<content-id-hex>` (refusing a conflicting existing tag).
Receipts distinguish original `ref` and actual `resolved_ref`; wrapper, Ruby
resolver, status and update/rollback validate this fallback by content too.
The digest-missing daemon behavior is simulated in tests here, **not exercised
with a real image load**. Real large-package ingestion remains unqualified.

## Verify, update and rollback

```sh
script/metal verify --config /appropriate/readable/location/metal.conf # --keep retains instances
script/metal update --config /appropriate/readable/location/metal.conf --branch APPROVED_BRANCH
script/metal rollback --config /appropriate/readable/location/metal.conf
# Optional --term-llm also swaps a retained bin/term-llm.previous symlink.
```

Verify uses the installed shim as the account, creates `verify-<UTC>-<nonce>`,
clones the configured synthetic smoke converter branch, standard-inits it,
registers the development inline-community fixture, proposes and explicitly
engineer-approves a plan, starts/polls the exact run (one-hour timeout), requires
`completed` and final artifact `label=restore-proven`, and prints run id and backup
SHA. Success resets that run unless `--keep`; failed runs are retained for exact
status/recover/reset with a fixed failure code. Evidence and backups survive reset.

Apply/update/rollback are serialized by nonblocking exclusive
`P/state/install.lock` for their mutating phases (including the account child).
First installation must create the lock's missing parent directories before
opening it; no account/package/service/release mutation precedes that lock.
The approved installer SHA is rechecked in the account child and immediately
before root actions. Apply rechecks mutable state after acquiring the lock.

Update/rollback hold nonblocking exclusive locks on the existing host execution
lock `W/.silo-standard-execution.lock` (the **same path/inode** used by
`StandardStore#with_host_lock`) and every existing workspace op.lock and reject claimed/running registry
state. Workspace lock files are never created by these commands; the installer
lock is maintained separately. Update clones a new detached
release, re-derives all image receipts from the bound release profile and
checks local content IDs regardless of old verification. Rollback performs the
same fresh gate. No package binding means `images=[]` and
`image_verification=skipped-no-package`, never inherited `verified`. Update
switches/records and prunes only managed commit directories beyond KEEP_RELEASES
while protecting current and previous by release **name**, including through
a symlinked prefix ancestor. It never pulls images or alters
workspaces, converter checkouts, backups or image data. Rollback uses history and
the retained previous release and deletes nothing. Neither command restarts the
term service; schedule a separate explicitly approved restart if needed.

## Tests and actual evidence (2026-11-05)

```sh
python3 -I -m unittest discover -s test/metal -v
bash -n script/metal test/metal/vm/*.sh
# Docker build installs QEMU/tools inside the disposable harness only.
test/metal/vm/run.sh small
# Larger explicitly approved resource envelope; not run in this task:
test/metal/vm/run.sh full --cpus 4 --memory 12g --disk 96G --artifacts /approved/package
```

The VM harness pins the Debian 12 container digest and cloud release
`bookworm/20261026-2643`, verifying its official SHA512SUMS. It uses KVM through
`--device /dev/kvm`, ephemeral SSH, cloud-init test admin, no host-published port,
and container-loopback-only SSH forwarding. Defaults: container 0.5 CPU/1408m,
VM 1 vCPU/1024MiB, sparse 64G overlay. Larger flags increase guest resources too
(container memory minus 384MiB overhead). All disk/evidence is under a fresh
`../../.runtime-cache/metal-installer-tests/run-*`. Public shallow local Git input
is cloned with `--no-local` to preserve shallow boundaries, copied into the VM,
and a **disposable bare-fixture** second commit is created there (no worktree
commit/push). No existing host container/volume is stopped or modified.

Real successful small-VM evidence:
`../../.runtime-cache/metal-installer-tests/run-LRTNuq9N/{scenarios.log,harness.log,guest-state.tar.gz}`.
Observed: Debian 12/amd64 preflight and arm64 refusal, missing-Git installation,
real official Docker CE install on a no-Docker VM, pinned term-llm download and
both checksum gates, account creation, lingering, stock service dry-run/install/
start (`active`), config sentinel preserved, unchanged re-apply with an identical
filesystem snapshot, status, second-local-commit update and rollback.
Output ended `GUEST_SCENARIOS_OK small` / `VM_SCENARIOS_OK small`, exit 0.
The installed release in that run was `dbc58bab60e0c552ca9ed4cec43eb45a49ef50b7`
(the branch's then-current committed Ruby half, not uncommitted installer files).

Earlier retained VM attempts failed at missing-Git commit resolution, local Git
ownership/shallow-history transfer, and admin traversal of the private prefix;
those defects were corrected before the successful run. They are not acceptance
runs. **Large artifact loading and full synthetic verify were explicitly skipped**
in every small VM; package tampering, identity mismatch, lock refusal, update
workspace preservation, secret suppression and full verify's structured command
contract are host-side synthetic/stub tests, not VM runtime acceptance. A final
post-hardening rerun/result is recorded below when executed. No migrations05
connection, customer data, provider authentication or Hub test was performed.

### Final post-hardening verification

- **22 host tests pass**, 0 failures/errors/skips, including Unicode UTF-8 identity,
  exact Ruby fixture match, both held-lock paths, claimed registry state, read-only
  preflight/plan and missing-Git bare-ref resolution. No Ruby-owned files changed.
- Bash syntax checks pass. **ShellCheck passes** on `script/metal` and all VM shell
  scripts; ShellCheck was installed/run only inside a disposable, bounded harness
  container, not on the host.
- Real post-hardening VM reruns: `run-MHYzYN1V`, then `run-aQDdV5wq`, both
  exit 0, `VM_SCENARIOS_OK small`. The latter additionally asserts
  `METAL_SERVICE_CONTROL_ENV_OK` for the non-secret systemd adapter environment.
  It additionally forced a real account reconfiguration (`KEEP_RELEASES=4`) with
  a pre-existing config sentinel, verified its checksum was unchanged, then
  proved the following unchanged apply made zero filesystem changes. The final
  installer included available-RAM/shared-pressure reporting, state/tmp staging,
  site-settings **file** integration and pinned binary receipts. Both Debian cloud
  image verification and stock term service installation/start ran for real.
- Still **not run**: real large-image package load/extraction and full synthetic
  migration verify, term-version rollback with two installed versions, non-default
  separate-disk target, Debian 13/Ubuntu execution, provider auth or target host.
  The small VM's unavailable remote converter branches were reported as such;
  its Silo input came from the transferred local bare repository.
- All failed/successful VM overlays/evidence were retained under the designated
  private cache, and harness containers used `--rm`. The local harness image is
  retained. Nothing was installed on the host or changed in host services; no
  `silomig-*` / `silo-control-*` container or volume was modified. No worktree
  commit or push was made by the installer developer.

After that real VM run, plan reporting was tightened to distinguish existing
versions/releases from actual downloads/clones, bind observed image identities
into the plan SHA, and enumerate exact load/pull/verify/cache paths when a package
is supplied. Re-apply of an existing installation now also holds the same idle
locks as update/rollback. These final package/planning safeguards were covered by
the host suite, together with a no-workspace-on-insufficient-capacity verify
gate; the real large-package/full-verify path remains unrun.


## Independent-review fixes (offline, 2026-11-05)

Converter Git (host clone/status/fetch/merge and container identity/status) uses
`GIT_CONFIG_NOSYSTEM=1`, disabled hooks, fsmonitor and untracked cache, and an
exact checkout `safe.directory`; status also uses `--no-optional-locks`.
Credential helpers are disabled except the explicit host fetch. Converter update
holds the workspace `op.lock` across checks/fetch/merge and refuses claimed or
running runs. Refresh takes its own op.lock and also refuses those states.
The lock is released before the separate refresh subprocess to avoid a
self-deadlock; refresh revalidates cleanliness and identity under its own lock.

Current review regression evidence supersedes earlier host-test counts above.
No VM harness, real host installer apply, real-workspace control operation,
Docker load/pull/build/tag or host package/service mutation ran in this fix task.
Real local fixture Git/fsmonitor/hooks, lock contention, filesystem pruning,
private snapshot cleanup and tiny synthetic Docker/OCI tar parsing are exercised;
Docker tag inventory/load/inspect and root provisioning paths are mocked.

Final bounded verification for this fix set:

- `timeout 300 python3 -I -B -m unittest discover -s test/metal -p 'test_*.py'`:
  **44 tests, 0 failures/errors/skips**.
- Full isolated Ruby suite: **698 runs, 6395 assertions, exactly the 3 expected
  InstallServiceTest baseline failures, 0 errors, 1 DockerIntegration skip**;
  seed `20261105`. Pinned image
  `sha256:32ca6f94a3ffe387eb1b9d34edc4be8e9308da1c80a3dce8b7b8310d84949240`,
  `--rm`, network none, read-only root/source/gems, private scratch bind,
  1 CPU / 1 GiB / 128 PIDs, `RUN_DOCKER_TESTS=0`, 300-second timeout.
- `bash -n script/metal`, Python AST syntax checks and `git diff --check` pass.
- Disk before and after: `/dev/sda2` 139G total, 52G used, **80G available**
  (40%). Scratch was confined to `../../.runtime-cache/metal-review-fix-tmp/`
  and removed after verification; no image tarballs retained.

The three baseline failures are Bundler 2.5.22 versus expected 2.6.9 output,
a pre-existing shell preset dry-run assertion, and a pre-existing installer
fetch-versus-clone dry-run assertion. Their assertions were not weakened.
