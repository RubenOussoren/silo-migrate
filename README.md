# silo-migrate

`silo-migrate` is the Ruby replacement for the legacy `db-migration-toolkit`.
It creates per-customer migration workspaces, runs local Docker-backed source and
final database containers, stages and imports dumps, sets up
`discourse-converters`, and prepares engineer-reviewed converter-development context.

The tool is usable today with Docker on macOS and Linux. The future Silo/Incus
runtime is intentionally behind the same runtime boundary, but is not the active
execution backend yet. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full
architecture and phase history, and
[`docs/migration-engineer-guide.md`](docs/migration-engineer-guide.md) for a
practical end-to-end overview (capabilities, limits, happy paths, diagrams).

## What It Does

- Creates migration projects under a configurable base path (see
  [Installation](#installation); legacy `/migrations/customers` still works on
  hosts where it exists).
- Generates Docker Compose services for initial DB, final DB, and converter
  containers.
- Stages SQL dumps, tar archives containing SQL, converted mysqldump XML, and
  converted JSON exports (generic relational shredding, e.g. Khoros API data).
- Imports dumps into MariaDB, MySQL, or PostgreSQL while streaming data instead
  of loading full dumps into memory.
- Exports source/final schema bundles privately; metadata-only is not release approval.
- Clones and runs `discourse-converters` in the converter container.
- Captures converter runs as redacted logs, structured summaries, durable
  findings, and shape-only synthetic fixtures.
- Publishes only explicitly approved, digest-bound private snapshots into
  `safe-artifacts/` inside the converter clone. Schema, logs, summaries, findings
  and fixtures stay private until approval; producer hooks do not publish.
- Provides an initial trusted-data workflow for audited raw-data inspection,
  restricted finding review, safe redacted derivatives, and Linux/Silo Bedrock
  session setup.

## Named file-only foundation (synthetic-only)

`named` is an opt-in fresh-workspace mode for named source/dataset/input identities
and a durable `validate-inputs` plan/run. It does not provision databases, parse
SQL, run converters or publish artifacts. Named and legacy modes cannot be mixed;
release commands are explicitly disabled in named mode. See
[Named workspaces](docs/named-workspaces.md) for the shared application contract,
CLI, locking, recovery and retained limitations. This is not migration rehearsal
or customer-use acceptance.

## Installation

Requirements:

- **Ruby >= 3.1** (e.g. via `rbenv`, `asdf`, or Homebrew) and Bundler
- **Docker** with Compose v2 — Docker Desktop on macOS, Docker Engine + compose
  plugin on Linux
- **git** (used by `setup-converter` to clone `discourse-converters`)
- Native gem build tools: a compiler toolchain, Ruby headers, SQLite headers,
  and `pkg-config` for gems such as `sqlite3`

### Global install

Install from the Git-managed checkout. This keeps a local clone, installs gems
there, and writes global shims for `silo-migrate`, `migration-tool`, and
`xml-to-sql`. The default repository URL is HTTPS so a fresh machine does not
need SSH keys just to install the CLI.

```bash
git clone https://github.com/RubenOussoren/silo-migrate.git
cd silo-migrate
script/install
```

On a fresh machine, use `--install-deps` to install host dependencies first.
The installer supports macOS, Debian/Ubuntu, and Fedora/RHEL family hosts. It
prompts before installing Docker, Homebrew, Oh My Zsh, or editing shell files
unless `--yes` is passed. It runs `silo-migrate doctor` at the end.
The installer is safe to rerun: package installs are idempotent, the managed
checkout is updated, shims are overwritten, `bundle install` is rerun, and the
marked PATH block is written only once.

```bash
script/install --install-deps
```

Common one-line installs:

```bash
# macOS or normal Linux user
script/install --install-deps

# non-interactive Debian/Ubuntu root setup
script/install --yes --install-dir /migrations/silo-migrate --bin-dir /usr/local/bin

# normal user, non-interactive, without Docker package installation
script/install --yes --skip-docker

# migration host with curated Oh My Zsh add-ons
script/install --yes --shell-preset migration --zsh-theme powerlevel10k
```

Docker packages default to Docker's official repositories on Linux. Use distro
packages instead when needed:

```bash
script/install --install-deps --docker-source distro
```

If `~/.local/bin` is not on `PATH`, add it to your shell profile:

```bash
export PATH="$HOME/.local/bin:$PATH"
```

Install/update settings can be overridden:

```bash
SILO_MIGRATE_REPO=https://github.com/RubenOussoren/silo-migrate.git
SILO_MIGRATE_BRANCH=main
SILO_MIGRATE_INSTALL_DIR="$HOME/.local/share/silo-migrate/source"
SILO_MIGRATE_BIN_DIR="$HOME/.local/bin"
```

Installer flags:

```bash
script/install --dry-run                 # print planned commands
script/install --with-oh-my-zsh          # explicitly opt into Oh My Zsh and zsh login shell
script/install --shell-preset migration  # Oh My Zsh + safe server add-ons
script/install --zsh-theme powerlevel10k # optional; requires a compatible local terminal font
script/install --zsh-plugins git,zsh-autosuggestions,zsh-syntax-highlighting
script/install --repo git@github.com:RubenOussoren/silo-migrate.git
script/install --branch main
```

The `migration` shell preset installs Oh My Zsh plus a server-safe plugin set:
`git`, `zsh-autosuggestions`, and `zsh-syntax-highlighting`. It configures
autosuggestions to use completion instead of shell history, keeps syntax
highlighting last in the plugin list, and adds history settings intended to keep
one-off AWS credential exports out of history. Prefer AWS profiles or IAM
Identity Center/SSO for persistent access, and prefix any sensitive one-off
export command with a leading space. When Oh My Zsh is requested, the installer
also sets zsh as the login shell when `chsh` can do that safely; start it in the
current session with `exec zsh -l` or log out and back in.

Powerlevel10k has an interactive first-run configuration:

```bash
exec zsh -l
p10k configure
```

If prompt icons render as boxes or question marks, install a Nerd Font in your
local terminal app or pick simpler/ASCII prompt options in the wizard.

If an earlier run left `/root/.oh-my-zsh` partially installed, move it aside
before retrying:

```bash
mv /root/.oh-my-zsh /root/.oh-my-zsh.broken-$(date +%Y%m%d%H%M%S)
script/install --yes --shell-preset migration --zsh-theme powerlevel10k
```

Upgrade after fixes are pushed:

```bash
silo-migrate self-update
```

`self-update` refreshes the managed checkout, runs `bundle install`, and rewrites
the global shims. Gem installation uses the repository's locked Bundler version
and keeps the managed lockfile frozen. It does not run OS package managers or
manage Docker. Run `script/install --install-deps` directly when host packages
or Docker setup need to be installed.

If an older installer changed `Gemfile.lock` inside the managed checkout, restore
that generated change once before updating:

```bash
git -C "${SILO_MIGRATE_INSTALL_DIR:-$HOME/.local/share/silo-migrate/source}" restore Gemfile.lock
silo-migrate self-update
```

Uninstall the global CLI artifacts:

```bash
silo-migrate uninstall
```

Uninstall removes only the global shims, the installer-managed PATH block, and
the managed checkout. It does not remove migration projects, dumps, Docker
volumes, Ruby gems, Homebrew, Docker, or OS packages. The installer script also
supports a dry run:

```bash
script/install --dry-run --uninstall
```

### New machine bootstrap

`script/bootstrap` remains as a compatibility wrapper for existing notes and
scripts. It delegates to `script/install --install-deps`; use `script/install`
directly for new setup flows.

```bash
git clone https://github.com/RubenOussoren/silo-migrate.git
cd silo-migrate
script/bootstrap
```

Useful bootstrap flags:

```bash
script/bootstrap --check-only        # show what would run
script/bootstrap --yes               # non-interactive package/PATH setup
script/bootstrap --with-oh-my-zsh    # explicitly opt into Oh My Zsh install
```

Docker may still need normal OS-specific startup after installation: open Docker
Desktop on macOS, or start/enable the Docker service on Linux.

### Development checkout

For local development without global shims:

```bash
cd silo-migrate
bundle install
bin/silo-migrate doctor
```

### Where projects are stored

Projects live under a base path, resolved in this order:

1. `SILO_MIGRATE_BASE_PATH` environment variable
2. `~/.config/silo-migrate/config.env` (written by the interactive first-run prompt)
3. The legacy `/migrations/customers` — only if it already exists and is writable
   (typical on dedicated Linux migration hosts)

On a fresh machine just run `bin/silo-migrate`: guided mode asks where to store
projects the first time and persists the answer.

### macOS notes

- Multi-GB imports through Docker Desktop are slower than on Linux and can fail
  during InnoDB commit/fsync; the generated compose files use safe InnoDB
  settings, and the import preflight warns (or blocks unsafe configurations) on
  large MariaDB imports. Linux is the preferred host for very large dumps.
- Non-interactive use (pipes, CI) fails fast with the equivalent standalone
  commands instead of hanging on a prompt.

## Quickstart

Use guided mode for normal migration work:

```bash
bin/silo-migrate
bin/silo-migrate acme
bin/silo-migrate interactive acme
```

The equivalent command-driven happy path is:

```bash
bin/silo-migrate init acme --db-type mariadb
bin/silo-migrate stage-dump acme initial /path/to/dump.sql.gz
bin/silo-migrate start acme --profile initial-db --wait
bin/silo-migrate import-dump acme initial
bin/silo-migrate schema bundle acme
bin/silo-migrate setup-converter acme --bundle-install
bin/silo-migrate converter source acme initial
bin/silo-migrate run-converter acme --redacted-logs
bin/silo-migrate findings generate acme
bin/silo-migrate fixtures generate acme
# Empty view until the engineer snapshots/reviews/approves exact contents:
bin/silo-migrate ai prepare acme
# See Engineer-reviewed artifact publication below for the complete release flow.
```

For a final database, initialize it up front or add it later:

```bash
bin/silo-migrate init acme --db-type mariadb --final-db-type postgres
bin/silo-migrate add-final-db acme --db-type postgres
bin/silo-migrate stage-dump acme final /path/to/final.sql.gz
bin/silo-migrate start acme --profile final-db --wait
bin/silo-migrate import-dump acme final
bin/silo-migrate schema bundle acme --phase final
bin/silo-migrate converter source acme final   # explicit cutover switch
```

For the optional Discourse handoff containers:

```bash
# one-time Linux launcher checkout setup; skip if /var/discourse already exists
bin/silo-migrate discourse install-launcher

bin/silo-migrate discourse setup acme
bin/silo-migrate discourse rebuild acme --role uploads
bin/silo-migrate discourse start acme --role uploads
bin/silo-migrate discourse prepare-deps acme --role uploads
bin/silo-migrate discourse run-uploads acme
bin/silo-migrate discourse rebuild acme --role import
bin/silo-migrate discourse start acme --role import
bin/silo-migrate discourse prepare-deps acme --role import
bin/silo-migrate discourse restore-import acme --backup /path/to/backup.tar.gz
bin/silo-migrate discourse import acme
bin/silo-migrate discourse backup-import acme
# Before another restore/import against the scratch import instance:
bin/silo-migrate discourse reset-import acme --yes
```

## Guided Workflow

Guided mode is a persistent dashboard. It refreshes after every action and shows
stateful cards, one recommended next action, alternatives, and blocked actions
with recovery reasons. It exits only through `Quit`. Menus fill the terminal
height and wrap around; lists longer than eight entries support live
type-to-filter, and a help line appears whenever choices are off-screen.

The durable, credential-free `.silo-migrate/workflow.json` tracks each database
as `empty`, `importing`, `ready`, `dirty`, `untracked`, or `unknown`; the active
converter source and selected output database; lineage; and the Discourse import
state. A live table-count check is made before any dump bytes are sent. A loaded,
dirty, untracked, or unknown database cannot be imported over.

Main workflows:

- **Initial dump** — stage or convert the initial dump, start the initial DB,
  wait for health, import, write the import marker, and generate the initial
  schema bundle.
- **Final dump** — add final DB configuration when needed, then stage/convert,
  start, import, mark, and bundle the final dump.
- **Converter setup** — clone or verify `discourse-converters`, recover from
  SSH/passphrase issues, and optionally build/start the converter container and
  run `bundle install`.
- **Discourse uploads container** — configure or start the container only when
  needed, then consume the selected SQLite converter output.
- **Discourse import container** — configure Discourse container files when
  selected, start it only when needed, then show an explicit action menu. Restore
  is allowed only while pristine; one generic import is allowed while pristine
  or restored. Repeat operations require a confirmed reset, available as
  `discourse reset-import` or the guided menu's "Reset import instance" action.

Typical flow:

1. Select or create a project.
2. Configure the initial database.
3. Stage a SQL/tar dump, or convert mysqldump XML or JSON export files into a
   staged SQL dump.
4. Analyze the dump, suggest import options, and optionally exclude tables.
5. Start the database, wait for health, and import with progress.
6. Generate the initial schema bundle.
7. Optionally add a final database and repeat staging/import/schema generation.
8. Set up `discourse-converters`, build/start the converter, and install gems.
9. Run the converter command.
10. Generate an private redacted converter summary.
11. Generate structured findings from that summary.
12. Generate shape-only synthetic fixtures from those findings.
13. Iterate on converter code using explicitly approved artifacts, then rerun the converter.
14. Use the Discourse uploads/import container workflows for the final handoff.

Submenus include `Back` where returning to the project menu is useful. Path
prompts accept `back`, `b`, or `..`, and support tab completion in a normal
terminal.

Advanced actions are grouped by the part of the migration they affect:

- Initial dump/database actions.
- Final dump/database actions.
- Conversion actions.
- Converter actions.
- Discourse uploads container actions.
- Discourse import container actions.
- Project/service actions.

Use advanced actions for direct service control, XML/JSON conversion, dump
analysis/preprocessing, schema bundle generation, converter execution, redacted
summary generation, findings/fixture generation, regeneration, reset, cleanup,
and status.

## Command Workflow

### Project Lifecycle

```bash
bin/silo-migrate init acme --db-type mariadb
bin/silo-migrate list
bin/silo-migrate status acme
bin/silo-migrate cleanup acme --yes
```

`cleanup` is destructive and requires `--yes` in command-driven mode. When a
project has Discourse handoff containers configured, cleanup destroys those
launcher containers too, while keeping the discourse_docker checkout, generated
container YAML, and shared Discourse data under `/var/discourse`.

### Runtime Operations

```bash
bin/silo-migrate start acme --profile initial-db --wait
bin/silo-migrate start acme --profile converter --build
bin/silo-migrate stop acme --profile all
bin/silo-migrate stop acme --profile all --remove
bin/silo-migrate regenerate acme
```

Profiles are `initial-db`, `final-db`, `converter`, and `all`.

### Dump Processing

```bash
bin/silo-migrate stage-dump acme initial /path/to/dump.sql.gz
bin/silo-migrate import-dump acme initial
bin/silo-migrate reset-db acme initial --yes
bin/silo-migrate history list acme
bin/silo-migrate analyze-dump /path/to/dump.sql.gz
bin/silo-migrate preprocess-dump /path/to/dump.sql.gz -o /path/to/fixed.sql.gz
bin/silo-migrate convert-xml /path/to/xml_dumps -c acme --phase initial --compress
bin/silo-migrate convert-xml /path/to/xml_dumps -c acme --phase initial --batch-size 250
bin/silo-migrate convert-json /path/to/json_exports -c acme --phase initial
bin/silo-migrate convert-json /path/to/json_exports -c acme --schema-dir /path/to/schemas
bin/silo-migrate convert-json /path/to/json_exports -c acme --records-path data.users
bin/silo-migrate convert-json /path/to/json_exports -c acme --ndjson --records-path data.users.edges
bin/silo-migrate convert-json /path/to/json_exports -c acme --recover-truncated
```

Useful import options:

```bash
bin/silo-migrate import-dump acme initial --file dump.sql.gz
bin/silo-migrate import-dump acme initial --exclude-tables sessions,logs
bin/silo-migrate import-dump acme initial --fast
bin/silo-migrate import-dump acme initial --turbo
bin/silo-migrate import-dump acme initial --no-fix-collations
```

`import-dump` streams dump content into the database container. Table exclusion
filters matching table DDL/DML while streaming. It is a whole-database operation:
repeat imports are rejected before streaming. `reset-db` archives lineage-based
schema, converter output, handoff markers, findings, and fixtures under
`history/<timestamp>-<reason>/`, while preserving staged dumps and final backups.

Converter runs use the persisted source (`initial` by default). Use `converter
source CUSTOMER final` for cutover, or `run-converter ... --phase final` for a
one-run override. `converter output-db CUSTOMER [RELATIVE_PATH]` manages the
SQLite file selected beneath `output/`; a sole valid candidate is discovered
automatically, and traversal or symlink escapes are rejected. Platform
shortcuts and the default `converter.rb` run require a ready source database
and record output lineage; arbitrary commands passed after `--` (for example
`run-converter acme -- bundle install`) run ungated and are not treated as
conversion runs.

XML conversion is for mysqldump XML exports, not arbitrary nested XML. It
streams each `.xml`/`.xml.gz` file with a SAX parser, so a directory of table
files and one large all-tables XML file use the same low-memory path. The
converter writes import-friendly SQL without wrapping the dump in a single large
transaction. The default XML insert batch size is `1000`; lowering
`--batch-size` can help isolate a failing statement, but it may not fix Docker
Desktop storage or InnoDB fsync errors.

JSON conversion (`convert-json`) turns arbitrary JSON export files into the
same import-friendly SQL via convention-based relational shredding: nested
objects flatten into prefixed columns (`avatar.url` -> `avatar_url`), arrays
become child tables keyed by `_sid`/`_parent_sid`/`_parent_id`/`_ordinal`, and
GraphQL `edges/node` wrappers unwrap automatically. Files are streamed (never
loaded whole), so GB-scale exports are fine. Column types are inferred from the
data, or taken exactly from Draft-07 `*.schema.json` files via `--schema-dir`,
which also carries `x-pii` annotations into column comments and a queryable
`_json_meta` manifest table. Use `--records-path` when the records array is
nested, for example `data.users` or `data.community.roles.edges`; `--schema-dir`
uses the same records path as inferred mode. For directories whose files use
different paths, pass `--records-path-config paths.yml` with keys matching the
JSON filename without `.json`, `.jsonl`, `.ndjson`, or the corresponding `.gz`
suffix:

```yaml
users: data.users.edges
roles: data.community.roles.edges
```

Per-file config entries override `--records-path` for listed files; unlisted
files fall back to `--records-path` or the default `data` detection. Relay
connection metadata such as `pageInfo`, `totalCount`, and edge `cursor` is
discarded during automatic `edges/node` unwrapping; the migrated rows come from
`node`.

Paginated API exports may be newline-delimited JSON (NDJSON), with one complete
JSON page per line. Directory conversion discovers `.jsonl`, `.ndjson`, and
their `.gz` variants in addition to regular JSON files. These line-delimited
extensions automatically select NDJSON parsing, including when compressed;
regular `.json` files use content-based auto-detection. Use `--ndjson` to force
this mode for another extension or `--no-ndjson` to force legacy
single-document parsing. With
`--recover-truncated`, malformed NDJSON lines are skipped and reported as a
file-level recovery warning; re-export or repair skipped lines for the full data.
For very wide flattened objects, the converter keeps indexed identifiers as
`VARCHAR` but automatically promotes enough other string columns to `TEXT` to
stay within MySQL/MariaDB's utf8mb4 row-size limit. Adjusted tables are reported
as conversion warnings and emitted with InnoDB's dynamic row format.
See `silo-migrate help convert-json` for all flags (table overrides, depth
limits, raw JSON columns).
Malformed or truncated JSON files produce a clear error naming the file and
position (truncated exports are called out explicitly). `--recover-truncated`
(or the guided-mode recovery prompt) keeps the complete records from a
truncated file — the partial tail record is discarded and the recovered vs
expected counts are reported as warnings — or exclude the file with
`-X`/`--exclude-files`. Re-exporting the broken file remains the real fix.
Maintainer-level design (module map, shredding conventions, type lattice,
extension points) lives in the workspace `ARCHITECTURE.md` under
"JSON-to-SQL Conversion Design".

For multi-GB MariaDB imports on macOS Docker Desktop, `import-dump` runs a
preflight that reports host/runtime details, key InnoDB variables, and container
free space. If unsafe InnoDB settings are active, regenerate compose, reset the
DB container, restart it, and retry the import. If a transaction-free
XML-converted dump still fails with `ERROR 1180 ... during COMMIT` and OS
`EPERM`, retry the same dump on Linux.

### Schema and AI-Safe Artifacts

```bash
bin/silo-migrate schema export acme
bin/silo-migrate schema bundle acme
bin/silo-migrate schema bundle acme --phase final
bin/silo-migrate schema bundle acme --output /tmp/acme-schema
```

`schema export` writes raw schema SQL. `schema bundle` writes private schema
metadata with no row samples. Names, defaults and DDL can still be confidential;
none of these outputs is published automatically.

### Converter Setup and Runs

```bash
bin/silo-migrate setup-converter acme --bundle-install
bin/silo-migrate setup-converter acme --repo git@github.com:discourse-org/discourse-converters.git
bin/silo-migrate setup-converter acme --allow-ssh-prompt
bin/silo-migrate run-converter acme
bin/silo-migrate run-converter acme vbulletin
bin/silo-migrate run-converter acme vbulletin --no-reset
bin/silo-migrate run-converter acme vbulletin --settings /path/to/settings.yml
bin/silo-migrate run-converter acme -- ruby converter.rb --dry-run
bin/silo-migrate run-converter acme --redacted-logs
bin/silo-migrate run-converter acme --redacted-summary
```

`run-converter CUSTOMER TYPE` is the standard discourse-converters shortcut. It
runs `./convert --from TYPE --reset` in the converter container. Use
`--no-reset` to omit `--reset`, or pass a custom command after `--` for low-level
container execution.

`--redacted-summary` is an alias for `--redacted-logs`. Both run the converter
through the runtime, redact stdout/stderr, summarize `output/intermediate.db`
log entries, and write private candidate artifacts. Redaction is not release approval.

### Findings and Synthetic Fixtures

```bash
bin/silo-migrate findings generate acme
bin/silo-migrate findings generate acme --from findings/redacted-logs/latest.summary.json
bin/silo-migrate fixtures generate acme
bin/silo-migrate fixtures generate acme --from findings/latest-findings.json
bin/silo-migrate fixtures generate acme --from findings/finding-20260601-120000-001.yml
bin/silo-migrate fixtures generate acme --from findings/
```

Findings are durable YAML files generated from converter summaries and carry an
explicit `dev_visibility` value: `safe`, `restricted`, or `trusted_only`.
Fixtures are placeholder-only YAML files generated only from `safe` finding
shape metadata.

### Trusted Workflow

```bash
bin/silo-migrate trusted inspect acme --phase initial --reason "Check one source edge case" -- COMMAND...
bin/silo-migrate trusted review acme findings/finding-20260601-120000-001.yml --decision safe --reviewer alice --released-message "Reviewed synthetic finding"
bin/silo-migrate trusted review acme findings/finding-20260601-120000-001.yml --decision reject --reviewer alice
bin/silo-migrate trusted redact acme trusted/findings/finding-20260601-120000-001.yml --reviewer alice --released-message "Reviewed synthetic finding"
bin/silo-migrate trusted session acme --provider bedrock --runtime silo --reason "Synthetic legacy non-interactive launch request"
```

`trusted inspect` is an engineer-operated, data-bearing command surface, not a
clean-agent tool or a sandbox. The privacy-hardening slice is tested only with
synthetic bytes and mocked execution; it does not authorize customer inspections.

Private inspection JSON now uses `artifact_version: 2`. Stdout/stderr, command
arguments, reason, optional message and audit actor are byte envelopes:
`encoding: base64`, `original_encoding`, byte count, SHA-256 and base64 `data`.
All available returned bytes (including invalid text encoding, NUL and empty
output) are preserved, not scrubbed or transcoded. A null stdout/stderr field
means capture was unavailable, distinct from an envelope containing zero bytes. Native Ruby pack/unpack is used; no extra
gem is needed. Base64 is **not redaction**. These records remain private under
`trusted/inspections/` and `trusted/audit/`, outside the publication source roots.
Never paste them into a coding-provider conversation or public diagnostics.
CLI option parsing uses a binary view of argument bytes to avoid invalid-text
regex failures; the envelope encoding label can therefore be `ASCII-8BIT` for
CLI metadata. Raw bytes, not that informational Ruby label, are authoritative.

New directories use 0700 and files 0600, with confined non-symlink paths and
atomic non-overwriting staging writes. Random invocation IDs replace timestamp-
only names. Success output contains generated opaque references, never workspace
paths, customer identity, reason, query arguments or result bytes. Operator-only
service return values still contain private artifact paths, but no raw runtime
result object; they are not a coding-tool response contract.

`--as-finding` writes a fixed-message `trusted_only` stub referencing the private
record. The supplied `--message` is retained in that record's byte envelope,
not interpolated into the YAML stub. An empty command name or NUL command argv is
rejected before execution; intentional empty argument values are retained.
A `requested` intent audit (write-once by this command, not tamper-proof) is written before the command, so runtime
or result-write failure does not erase the request trace. A separate result
audit is written only when result storage succeeds; neither is a run ledger.
A nonzero or signal-killed inspection result is preserved privately, then reported as fixed
`TRUSTED_INSPECT_COMMAND_FAILED`, not successful execution. Nested help/version/completion built-ins and abbreviated private flags are
refused rather than allowing OptionParser to print through global streams or
exit successfully. Use top-level `trusted --help` for static help. Literal metadata
that resembles a reserved completion token can use `--reason=VALUE`.
Parser/input errors, raised runtime/adapter exceptions and
storage/serialization/output errors return fixed
`TRUSTED_*` messages with sensitive exception causes suppressed. A storage or
output failure can happen after execution or after some private records were
written: inspect private storage before retrying; there is no exactly-once run
ledger or automatic retry/recovery in this slice. No available result bytes can
be guaranteed persisted if a reader fails, storage fails or the process dies.
Failures intentionally print a fixed code only, without even an opaque record
reference. Correlating failed concurrent requests therefore requires private
operator inspection; durable run IDs/ledger handling is a later slice.
Repeated `--reason` options retain only the last value. A session config can be
left privately orphaned if the following intent write fails; execution does not
start. These are not full request-accounting or crash-recovery guarantees.

Version-1 inspection JSON used plain text and timestamp names; it is not rewritten.
Existing consumers must explicitly handle version 2. For a private local review,
`record.fetch("stdout")&.fetch("data")&.unpack1("m0")` recovers available exact bytes; do not
print decoded customer bytes into shared logs or send them to coding providers.
Trusted calls request opt-in `capture: true, binary: true`: the Docker adapter
sets pipe binary mode before reads (independent of text encoding defaults) and
suppresses reader-thread exception reports so errors propagate to the fixed
boundary instead of printing privately valued tracebacks. Other callers retain
the previous text-capture default. Alternate adapters must support this contract;
there is no fallback to attached/text execution. Workspace preflight checks a
confined regular `config.env` existence anchor, not its database settings; missing
or unsafe workspaces return `TRUSTED_WORKSPACE_INVALID` before execution.
Capture still buffers output in memory; bounded streaming/query limits and real
runtime isolation are separate requirements before customer use.

`trusted review` can approve or reject `restricted` findings. `trusted_only`
findings cannot be approved directly; use `trusted redact`. Both safe decisions
require a quoted `--released-message TEXT`: the engineer must review that exact text for
release. `--notes` is private audit context, not released text. A flag is not an
automatic redactor or proof that the text is safe. Text must have valid encoding,
contain no NUL, not start with `--`, and be 1-4096 bytes. Extra positional
arguments are rejected rather than silently truncating an unquoted summary.
Reject decisions must not include release text. Private metadata must be
validly encoded text without NUL; parser/encoding failures are not echoed.

`FINDING` is relative to the selected customer workspace (not the current
working directory), or an absolute path inside its `findings/` or
`trusted/findings/`. Review/redaction reject symlink components, non-regular
files, hard-linked input files, invalid IDs and unknown visibility values.
Output and audit directories must also be non-symlink paths inside that workspace.
These checks assume operator-owned directories and do not protect against a
hostile concurrent filesystem writer; runtime isolation is still required.

Each approval creates an opaque, unique finding ID under `findings/`, with a
fixed field projection and only the explicitly released message. It does not
copy source messages, IDs, paths, unknown fields, nested shapes, reviewer
identity or notes. Private audits retain source provenance, reviewer identity,
notes and the intended derivative reference. Audit file contents are written and
fsynced before derivative writes; an audit entry alone is not proof publication
succeeded. Parent directories are not fsynced: crash/power-loss durability across
the two directories is not established.

New review audits and derivatives use mode 0600 staging files. Only after a
complete write, flush, fsync and close is a staging file atomically linked into
its final name, without replacing any existing entry. Write/flush/fsync/close or
link failures clean up staging files in `ensure`; a completed audit is retained
if the derivative fails. If staging removal itself fails, the command explicitly
distinguishes a written private audit (derivative not published) from a
published derivative; it does not claim cleanup succeeded. A second close error
while handling a write error does not mask that original failure when staging
removal succeeds. A post-write status-output failure likewise reports that artifacts
were written. Inspect the private workspace before retrying either case, since
retrying can create a second derivative. Temporary staging files are not matched
by the finding-publication globs. This is not crash recovery or a full artifact
release transaction.

Reviewed derivatives have no `observed_shape`; fixture generation will skip
them rather than silently release source keys or values. Providing reviewed
synthetic fixtures needs a separately designed release path. This finding-only
hardening alone is not publication approval. The snapshot release flow below
binds a separate approval to exact bytes before publication. Neither command
family authenticates the reviewer or establishes OS isolation. The byte/error
privacy boundary is synthetically tested as described above; actual runtime,
provider, credential and data-policy acceptance is still required before
customer-data use. These commands are not clean-agent privileged tools.

`trusted session` retains the legacy Linux/Silo/Bedrock command wiring, not an
approved work-node/Frontier analyst route. Both snapshot and launch calls now
use captured execution; launch output is **not attached/streamed to the terminal**.
Each available stage result is preserved as a private version-2 byte-envelope
JSON record under `trusted/session-results/`. No real session, provider or Silo compatibility has been tested. With the Docker
adapter, stdin is closed and stdout/stderr are pipes: this is non-interactive
and **cannot provide an interactive customer session**. A separate reviewed
broker/runtime design is needed, not a switch back to unsafe terminal attachment. The service cannot contain a runtime implementation that ignores its
capture contract or writes to unrelated channels, and capture is not OS isolation.

The requested-session audit is written before execution, explicitly marked
`requested`; it is not proof the snapshot or launch completed. A failed snapshot
stops launch; a failed launch or runtime/encoding/storage error produces only a
fixed cause-free message, with no captured output echoed. Available nonzero or
signal-killed stage output is retained privately. A raised runtime exception before a result returns
may leave only the intent audit. User-supplied session IDs and raw justification
stay private; filenames/success references use unrelated generated IDs. The Silo
config contains a fixed reference to the audit instead of raw justification.
Unsupported platform/provider/runtime/options are refused without echoing values.
No provider settings are changed and no session is launched by ordinary publication.

### Engineer-reviewed artifact publication

This local, engineer-operated flow does not run a converter, database or model.
Use it only in a private operator-owned workspace. The first implementation is
synthetically tested, not a customer-data isolation boundary.

```bash
# Prepare a bounded copy, not an approval of a mutable source file.
bin/silo-migrate release prepare acme schema/initial/summary.json --class summary
# Returns an opaque artifact ID, candidate state, SHA-256 and exact byte count.
# Privately inspect .silo-migrate/releases/snapshots/ARTIFACT_ID.bin.
# Review those exact contents; obtain DIGEST and BYTE_COUNT from that snapshot.
bin/silo-migrate release approve acme ARTIFACT_ID \
  --sha256 DIGEST --bytes BYTE_COUNT --reviewed --reviewer engineer
bin/silo-migrate release publish acme ARTIFACT_ID
bin/silo-migrate release status acme ARTIFACT_ID
bin/silo-migrate release revoke acme ARTIFACT_ID
```

`ARTIFACT_ID`, `DIGEST` and `BYTE_COUNT` above are placeholders, not valid IDs or
approval values. `--reviewed` is an explicit engineer attestation that the exact
snapshot contents were reviewed for release, not an automatic redactor or proof
of human identity. Digests establish byte identity, not de-identification.
Reviewer/optional `--notes` remain private; reviewer names are limited to 256
bytes without control characters, and notes to 4096 bytes. Avoid secrets in command arguments,
shell history and process listings. Do not paste private snapshot bytes into a
coding-provider conversation to ask whether they are safe.

**Inputs and limits:** source files must be within `schema/`, `findings/` or
`synthetic-fixtures/` in the selected workspace. Relative paths are workspace-
relative; absolute paths inside those roots also work. Traversal, symlinks,
hardlinks and non-regular files are refused. Supported classes are `schema`,
`log`, `summary`, `finding`, `fixture`; the class determines a controlled output
extension, never whether the content is safe. Each snapshot is at most 16 MiB,
there are at most 128 records (including revoked/abandoned candidates), private
serialized state is bounded to 8 MiB, and a published view is at most 64 MiB. Large
artifacts need a separate reviewed reduction, not an increased limit by default.
Snapshots use mode 0400, state uses 0600, and new private directories use 0700.
Snapshot/state approval binds the artifact, workspace, class, digest and byte
count; copying a release store to another workspace/root does not authorize it.

**Publish:** without IDs, `release publish`, `ai prepare` and `ai refresh` publish
all currently approved snapshots, never candidates. With no approvals they
produce a fixed empty view, not an implicit release. An explicit candidate,
unknown or revoked ID is refused. Source changes/deletion after preparation do
not substitute bytes; altered snapshots or descriptors fail closed. Publication
stages complete verified bytes privately, then switches the generated view via
rename; no partially copied view is used. Existing views are withdrawn before
replacement. A failed or interrupted publication is blocked, not silently
presented as current; use status and explicit recovery/republication.

Only controlled `artifacts/ARTIFACT_ID.sql|log|json|yml` filenames enter the view.
The manifest contains opaque IDs, classes, digests, sizes and a generation
counter. Original filenames, customer names, operational paths, reviewer
identity and private notes are not generated into it. Fixed `AGENTS.md`,
`CLAUDE.md` and an empty `allowed-commands.json` live **inside** `safe-artifacts/`.
No root instructions, `.claude` settings, Silo snippets or Git metadata are
created or rewritten. Legacy auto-generated root files may contain private
identifiers and stale deny rules; review/retire them privately before exposing
an older checkout, rather than relying on them as isolation. Converter code and existing operator-owned files are
untouched. The view's own `.gitignore` ignores its generated contents; ensure
nothing previously tracked is committed accidentally.

**No automatic release:** schema export, converter summary, finding generation
and fixture generation never refresh the view. `safe`, `contains_raw_rows:
false`, regex redaction and a previous manifest are not authorization. Previously
reviewed finding derivatives must still be snapshotted and approved. A legacy
automatically copied view is withdrawn, never grandfathered into approval.
Preexisting root instructions/code are outside this artifact view; the operator
must ensure the clean checkout itself contains no private material.

**Revoke:** revocation is terminal for that snapshot ID and removes the entire
current generated view. Other still-approved snapshots can be explicitly
republished afterward. The terminal decision is persisted before checking a
corrupt/interrupted view, so a tampered view cannot prevent recording revocation. Approval/revocation/publication use the same private lock.
If view removal fails, status is blocked and the command fails; it does not
claim successful cleanup. Revocation cannot retract context already read by an
agent, copied elsewhere, or retained in model history.

**Errors/recovery:** `RELEASE_*` errors and status contain no raw exception,
source path or review-note text. Input mistakes (such as an unknown status ID or
wrong approval digest) leave a healthy view untouched. Integrity and dirty
mutation failures attempt to persist blocked state before withdrawal; private
snapshot-write failure before authority changes leaves a healthy view alone.
Failed prepare/approve
working copies are not committed by the error handler. A status-output error can occur after a state
change; inspect status before retrying. Tampering with a published view is also
refused and withdraws it; a second explicit publish can rebuild from still-valid
approvals. A persisted `publishing` state is treated as interrupted, withdrawn
and refused once before explicit recovery. Record/snapshot writes and view
changes use content/directory fsync where performed, but this is not a verified
power-loss transaction or protection from hostile concurrent filesystem writers.
Status/prepare also remove stale views when state is absent or blocked. Orphaned
private view/retired directories and staging tempfiles are swept under the same
lock; this is not unattended automation. Complete snapshots, including revoked
or unregistered snapshots after a failed prepare, remain privately retained.
There is no discard/purge API in this bounded slice: the 128-record limit requires
a fresh workspace when exhausted, not manual approval transplantation. Cleanup
failures need operator repair; no retention/deletion policy is silently assumed.
Class labels are engineer-selected output types, not verified content semantics.
Tampering is detected on the next release operation, not continuously. The
existing writable converter mounts are not an isolation boundary and are not
changed by this slice. Default refresh includes every still-approved artifact;
if their total exceeds 64 MiB, select an explicit bounded subset or revoke
unneeded approvals rather than treating a failed refresh as current context.

`safe-artifacts/` is a reserved generated directory, not operator storage:
Any release operation that withdraws a view can remove that exact directory,
including tracked, operator-created or legacy contents. Do not store source
code or operator files there; Git tracking does not exempt it from cleanup. Repeating revocation also withdraws
the current view; explicitly publish the remaining approved set afterward.
A `RELEASE_STATE_BLOCKED` (or `RELEASE_STATE_AND_VIEW_BLOCKED`) error requires
private state inspection before any publish: with repeated storage failures a
previous write may have reached disk even if the command failed. The combined
code also means view withdrawal failed, so context may still be exposed. Do not
assume rollback, successful cleanup or approval absence after those errors.

Operator-owned state is trusted, not cryptographically signed: a malicious
administrator can forge records. Failed storage/cleanup can require operator
repair; no customer runtime or unrestricted privileged agent API is enabled.

## Artifact Layout

A project uses the existing customer workspace layout:

```text
/migrations/customers/acme/
  config.env
  docker-compose.yml
  dumps/
    initial/
    final/
  schema/
    initial/
      schema.sql
      tables.json
      columns.json
      indexes.json
      summary.json
      migration_notes.md
    final/
  findings/
    redacted-logs/
      converter-run-YYYYMMDD-HHMMSS.log
      converter-run-YYYYMMDD-HHMMSS.summary.json
      latest.log
      latest.summary.json
    finding-YYYYMMDD-HHMMSS-001.yml
    latest-findings.json
  synthetic-fixtures/
    finding-YYYYMMDD-HHMMSS-001.yml
  trusted/
    audit/
    inspections/
    silo/
  output/
    intermediate.db
  uploads/
  shared/
  discourse-converters/
```

Schema bundles and every other generated artifact remain private candidates.
They require exact-byte release approval even when they contain no raw rows.

Candidate finding files include fields such as:

- `artifact_version`
- `id`
- `source`
- `source_entry_index`
- `failure`
- `severity`
- `message`
- `exception_class`
- `observed_shape`
- `dev_visibility: safe`
- `recommended_next_step`

Restricted and trusted-only findings require a trusted review/redaction step
before they can be converted into normal Dev AI fixtures.

Synthetic fixture values use placeholders derived from shape metadata, for
example `synthetic@example.test`, `synthetic-value`, `1`, `1.0`, `true`, `null`,
`[]`, and `{}`.

## Architecture and Data Zones

The architecture is layered so migration behavior remains independent from the
runtime backend:

```text
CLI / Guided UI
  -> Application services
    -> Runtime adapter
      -> Docker migration runtime today, Silo migration runtime later, Fake in tests

External converter framework:
  -> discourse-converters
```

The complete intended system separates work into three zones:

- Normal Dev AI Workspace: clean converter code plus explicitly approved snapshot
  bytes and fixed non-customer-identifying instructions in the generated view.
- Migration Runtime Zone: raw dumps, DB containers, converter container, and raw output.
- Trusted Data AI Zone: approved Linux/Silo Bedrock path for narrow raw-data
  inspection with snapshots, audit, redaction, and safe handoff.

Today, Docker is the active runtime for local Linux/macOS work. The future Silo
runtime should provide stronger Linux isolation using the same high-level
runtime boundary rather than exposing Docker, Incus, or raw data directly to
normal AI sessions.

## Runtime Boundary

Application services call a small runtime contract instead of shelling directly
throughout the codebase:

- Docker Compose lifecycle through `compose`.
- Command execution through `run`.
- Import streaming through `run_with_stdin`.
- Container state checks through `container_running?`.
- Health waits through `wait_for_container_healthy`.
- Database-specific import and schema dump command construction.
- Schema metadata command construction for schema bundles.

`Runtime::Docker` and `Runtime::Fake` implement the full active contract.
`Runtime::Silo` exposes the same method surface but currently raises a clear
placeholder error for full migration runtime replacement. Phase 4 starts with
agent environment boundaries and Silo config snippets; full Silo-backed
migration execution remains a later subphase.

## Operator Recovery

Port conflicts are detected before Docker start. Stop the service using the
port, or edit `config.env` and regenerate:

```bash
bin/silo-migrate regenerate acme
bin/silo-migrate start acme --profile initial-db --wait
```

If converter setup fails on a private SSH repository, verify SSH manually, then
retry with terminal prompts or an alternate URL:

```bash
ssh -T git@github.com
ssh-add -l
bin/silo-migrate setup-converter acme --allow-ssh-prompt
bin/silo-migrate setup-converter acme --repo <alternate-url>
```

If converter start or dependency installation fails, recover manually:

```bash
bin/silo-migrate start acme --profile converter --build
docker exec -it acme_converter bundle install
bin/silo-migrate run-converter acme vbulletin --redacted-logs
```

If redacted summaries or findings are missing, regenerate from the previous
artifact layer:

```bash
bin/silo-migrate run-converter acme vbulletin --redacted-logs
bin/silo-migrate findings generate acme
bin/silo-migrate fixtures generate acme
```

## Testing

Run the Ruby test suite:

```bash
rake test
```

Docker-dependent checks are opt-in:

```bash
RUN_DOCKER_TESTS=1 rake test
```

The Docker smoke coverage uses synthetic local SQL and a local fixture converter
repository. It exercises project init, dump staging, DB start/health wait,
import, schema export, schema bundle, converter setup, converter run, and
cleanup.

## Future Architecture

The current implemented baseline is:

- Phase 1: Ruby CLI compatibility, Docker runtime, guided workflow, imports,
  converter setup/run, schema export, tests.
- Phase 2: private schema bundles, redacted converter summaries, durable
  findings, and shape-only synthetic fixtures. These are not release approvals.

The implemented and planned future architecture is:

- Phase 3: Trusted Data Workflow for approved raw-data inspection, visibility
  levels beyond `safe`, audit logs, and redaction review hooks. The initial
  slice is implemented through `trusted inspect`, `trusted review`, and
  `trusted redact`.
- Reviewed context: private snapshots, explicit exact-byte approval, guarded
  publication and terminal revocation replace automatic safe-artifacts copying.
- Agent/runtime isolation, authenticated caller policy and verified private
  analysis remain separate future work; generated instructions are not a sandbox.

Important boundaries for future work:

- Do not make Silo a migration product; Silo should provide isolation.
- Do not make `silo-migrate` require Silo; Docker must remain useful on macOS
  and Linux.
- Do not redesign `discourse-converters`; orchestrate it.
- Do not expose raw customer data through logs, fixtures, prompts, or generated
  artifacts intended for normal AI agents.
- Keep `run-converter` as the converter execution surface. Preserve both the
  platform shortcut and the explicit `-- COMMAND...` escape hatch until real
  migration use proves that narrower helpers are necessary.

## Notes

- The compatibility aliases `migration-tool` and `xml-to-sql` forward to
  `silo-migrate`.
- `config.env` remains the compatibility configuration source.
- `migrate.yml` is a future option for richer runtime and data-access policy.
- The deep design reference is [`ARCHITECTURE.md`](ARCHITECTURE.md).
