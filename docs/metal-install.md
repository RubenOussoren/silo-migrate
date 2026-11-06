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
is therefore also a **root-equivalent credential**, not a narrow migration API key. No Hub registration (unless opted in, below),
provider credentials, extension installation, memory mining, jobs or cron are
configured. Existing Docker installations, running containers and existing
account term-llm configuration are preserved. Do not run verification against a
live demo's workspace. Verification creates a fresh synthetic workspace.

## Quick start on a server

1. Copy the artifact package directory to a trusted, root-owned location that
   is not group/world-writable and not `/tmp` (e.g. `/srv/silo-artifacts/`), then
   `script/metal artifacts verify DIR` and compare the manifest SHA256 with the
   one you were given.
2. Clone this repository's `mvp/metal-installer` branch somewhere the service
   account can read. Run `script/metal` from that checkout: its companions
   (`package-artifacts`, `image_identity.py`, `image_archive.py`) must sit beside it.
3. Copy `config/metal.example.conf`, set `ARTIFACT_PACKAGE` (and anything else you
   need), then `preflight`, `plan --plan FILE`, review, `apply --plan FILE`.
4. `script/metal verify` runs the full synthetic workflow; `status` reports what
   is installed. Provision provider access afterwards, as the account.

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
127.0.0.1 only; no firewall or reverse-proxy change. Remote access is only through
the opt-in reverse Hub connection below.

Config schema reference: <https://term-llm.com/reference/configuration/>;
service behavior: <https://term-llm.com/guides/background-services/>.
**No widget-disable or automatic-memory-mining config key was confirmed.** The
installer does not guess either: widgets/extensions use the confirmed CLI disable
flags, and it registers no jobs/mining automation. Existing jobs are not removed.
Do not infer that preserving an existing config makes it work-only.

Provision provider access **as the account**, separately, using `term-llm auth`
or `term-llm service install web --secret NAME` with masked input. `NAME` is a
credential variable name, **never its value**. Do not pass token/API-key values
on argv, paste them into config, or use service token output in logs.

### Optional reverse Hub connection

For a server that accepts no inbound connections, the web node can dial out to a
term-llm Hub and keep a websocket open (`--hub-connect reverse --hub-register`).
The Hub then proxies to it and injects the node's bearer token server-side.
**Anyone with access to that Hub can operate this node's agents with the
service account's root-equivalent Docker authority**, so use only a Hub whose
access policy you have approved. Web passkey auth does not support reverse
registration; the installer already uses bearer auth.

It is a second step after the base install, because the token file must be
owned by the service account:

```sh
sudo -iu silomig
install -d -m 0700 ~/.config/silo-migrate
( umask 077; read -rsp 'Hub registration token: ' t; echo
  printf 'TERM_LLM_HUB_REGISTRATION_TOKEN=%s\n' "$t" > ~/.config/silo-migrate/hub.env; unset t )
exit
```

Then set in the config, plan, review and apply again:

```
HUB_URL=https://YOUR-HUB/hub/
HUB_NODE_ID=migrations05
HUB_NODE_NAME=Migrations05
HUB_SECRETS_FILE=/home/silomig/.config/silo-migrate/hub.env
```

The installer validates the URL (HTTPS, no credentials) and the file's owner,
mode 0600 and single link, but never reads it or records its hash. It passes
only the path to the stock `service install --secrets-file`, which imports the
token into term-llm's private service store; the reverse flags go into the
service spec, never a token. If the service was already running, restart it as
the account (`term-llm service restart web`). The node keeps serving locally
when the Hub is unreachable and retries registration in the background. The
dry-run with these exact flags was checked against the real 0.9.93 binary
(isolated home, fake token); a live Hub registration has not been tested.

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

Before Docker sees an image tar, a stdlib parser reads it in one forward pass,
hashing each file as stored and, for gzip streams, uncompressed. It checks
`manifest.json` and/or OCI `index.json`: exactly one image manifest (no nested
index), matching config digest, uncompressed layer SHA256s equal to the config's
diff_ids (gzip or plain tar layers; zstd/unknown encodings refused) and the
expected content ID. Every file must be reachable from that one image. Tags
(RepoTags, `repositories`, OCI `ref.name` and `io.containerd.image.name`) may
only name the expected ref in Docker's spellings: as given, `docker.io/`-
normalized, or the bare tag that containerd records in `ref.name`.
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
Real package ingestion (pre-load parse, load, tag snapshot, content check) has
run on a fresh Debian 12 VM with the two tag-referenced package images. The
digest-ref fallback is still only simulated: no packaged image currently uses a
digest ref (control is pulled by digest from Docker Hub).

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

## Converter Git safety

Converter Git (host clone/status/fetch/merge and container identity/status) uses
`GIT_CONFIG_NOSYSTEM=1`, disabled hooks, fsmonitor and untracked cache, and an
exact checkout `safe.directory`; status also uses `--no-optional-locks`.
Credential helpers are disabled except for the explicit host fetch. Converter
update holds the workspace `op.lock` across checks/fetch/merge and refuses claimed
or running runs. Refresh takes its own `op.lock`, refuses those states and
revalidates cleanliness and identity.

## Tests and actual evidence (2026-11-05)

```sh
python3 -I -B -m unittest discover -s test/metal -p 'test_*.py'
bash -n script/metal test/metal/vm/*.sh
# Disposable KVM harness; installs QEMU only inside its own container.
test/metal/vm/run.sh small
test/metal/vm/run.sh full --cpus 4 --memory 8g --disk 64G --artifacts DIR
```

The harness boots the dated official Debian 12 cloud image
(`bookworm/20261026-2643`, checked against its SHA512SUMS) under KVM. It uses
ephemeral SSH, no host-published port and a sparse guest disk. Before starting
it refuses unless host free space covers the disk cap plus a 12 GiB reserve.
It deletes the guest disk and repo copies on exit, and sweeps leftovers of
killed runs on the next start. Evidence stays in
`../../.runtime-cache/metal-installer-tests/run-*`.

**Fresh Debian 12 VM, real package, full scenario:**
- **Install:** preflight with an arm64 refusal, plan with a path-authority
  refusal, then apply (real Docker CE install, pinned term-llm download, account,
  stock service install and start, package verify, pre-load parse and image load).
- **Re-apply:** apply with an existing config preserved, then an unchanged
  re-apply with an identical `find` snapshot of the whole prefix.
- **Update and verify:** status, update and rollback, then `metal verify`.

Verify runs the synthetic workflow end to end and requires a `restore-proven`
final backup. It ran with `VERIFY_MIN_AVAILABLE_MIB=6144`, because the test VM
had 7.6 GiB of RAM. Results:

| Run | Result |
| --- | --- |
| full-16, -17, -18 | `METAL_VERIFY_OK` (first final backup `e14a8563…`) |
| full-15 | `METAL_VERIFY_RUN_FAILED` at `verify_restore`, `STANDARD_RESTORE_FAILED` |

**Known intermittent failure (open):** 1 of 4 completed full runs failed the
restored-site comparison. No failure detail was retained for that run (the
harness now exports bounded failure records). The suspected cause is a race with
Discourse's post-restore background rebake: `verify_restore` fingerprints cooked
HTML without waiting for it. If it fails on a server, `standard status` gives the
run ID; the run's `private/failure.json` and `evidence/restore.failures.json`
name the failed assertion. Reset that exact run and verify again.

**Defects the VM runs found and fixed:**
- Packages built from a renamed profile copy failed apply. Build now requires the
  release `runtime/profiles/` file and runs apply's name-bound verification.
- The archive parser rejected real containerd-store saves (normalized names, gzip
  layers). See above.
- A partial installer copy failed mid-apply. It now refuses up front, and companion
  hashes are bound into the plan.
- Bash spooled the >64 KiB engine here-document into `TMPDIR`, i.e.
  `state/tmp`, on every read-only re-invocation. The engine is now read through
  a pipe, and a test asserts `TMPDIR` is untouched.

**Not exercised on a real target:**
- **Docker:** an existing Docker installation with other workloads; every VM
  started without Docker.
- **Layout and versions:** a separate workspaces disk, Debian 13/Ubuntu, and
  rolling back term-llm across two installed versions.
- **Credentials and access:** provider authentication, Hub registration, remote
  access to the term-llm service, and customer data.

Host suites at installer commit `7947dd7`:
- 49 installer tests pass, 0 failures/errors/skips.
- Full isolated Ruby suite (last run at `9847b99`, no Ruby changes since): 698
  runs, 6395 assertions, the 3 long-standing `InstallServiceTest` failures, 0
  errors, 1 disabled Docker-integration skip. Those failures are Bundler 2.5.22
  versus expected 2.6.9 output, a shell preset dry-run assertion and a
  fetch-versus-clone dry-run assertion; their assertions were not weakened.

Independent review of the installer found 5 blockers and 8 major issues; all
were addressed in `9847b99` (Git hook/fsmonitor hardening, name-based release
pruning, pre-load image checks, private package snapshot, path authority, locks).
The fixes since then, listed above, have not been re-reviewed.
