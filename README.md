# silo-migrate

`silo-migrate` is the Ruby replacement for the legacy `db-migration-toolkit`.
It creates per-customer migration workspaces, runs local Docker-backed source and
final database containers, stages and imports dumps, sets up
`discourse-converters`, and produces AI-safe converter-development artifacts.

The tool is usable today with Docker on macOS and Linux. The future Silo/Incus
runtime is intentionally behind the same runtime boundary, but is not the active
execution backend yet. See [`ARCHITECTURE.md`](ARCHITECTURE.md) for the full
architecture and phase history.

## What It Does

- Creates migration projects under `SILO_MIGRATE_BASE_PATH`, defaulting to
  `/migrations/customers`.
- Generates Docker Compose services for initial DB, final DB, and converter
  containers.
- Stages SQL dumps, tar archives containing SQL, and converted mysqldump XML.
- Imports dumps into MariaDB, MySQL, or PostgreSQL while streaming data instead
  of loading full dumps into memory.
- Exports source/final schema and AI-safe schema bundles.
- Clones and runs `discourse-converters` in the converter container.
- Captures converter runs as redacted logs, structured summaries, durable
  findings, and shape-only synthetic fixtures.
- Generates safe Normal Dev AI workspaces with only allowlisted converter,
  schema, redacted log, safe finding, fixture, and agent instruction artifacts.
- Provides an initial trusted-data workflow for audited raw-data inspection,
  restricted finding review, safe redacted derivatives, and Linux/Silo Bedrock
  session setup.

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
bin/silo-migrate run-converter acme --redacted-logs
bin/silo-migrate findings generate acme
bin/silo-migrate fixtures generate acme
bin/silo-migrate ai prepare acme
```

For a final database, initialize it up front or add it later:

```bash
bin/silo-migrate init acme --db-type mariadb --final-db-type postgres
bin/silo-migrate add-final-db acme --db-type postgres
bin/silo-migrate stage-dump acme final /path/to/final.sql.gz
bin/silo-migrate start acme --profile final-db --wait
bin/silo-migrate import-dump acme final
bin/silo-migrate schema bundle acme --phase final
```

## Guided Workflow

Guided mode is the primary operator experience. It shows project location,
configured databases, dump counts, schema-bundle status, and container status
before prompting for the next action.

Typical flow:

1. Select or create a project.
2. Configure the initial database.
3. Stage a SQL/tar dump, or convert mysqldump XML into a staged SQL dump.
4. Analyze the dump, suggest import options, and optionally exclude tables.
5. Start the database, wait for health, and import with progress.
6. Generate the initial schema bundle.
7. Optionally add a final database and repeat staging/import/schema generation.
8. Set up `discourse-converters`, build/start the converter, and install gems.
9. Run the converter command.
10. Generate an AI-safe redacted converter summary.
11. Generate structured findings from that summary.
12. Generate shape-only synthetic fixtures from those findings.
13. Iterate on converter code using safe artifacts, then rerun the converter.

Submenus include `Back` where returning to the project menu is useful. Path
prompts accept `back`, `b`, or `..`, and support tab completion in a normal
terminal.

Advanced actions expose direct service control, XML conversion, schema bundle
generation, converter execution, redacted summary generation, findings
generation, fixture generation, regeneration, reset, cleanup, and status.

## Command Workflow

### Project Lifecycle

```bash
bin/silo-migrate init acme --db-type mariadb
bin/silo-migrate list
bin/silo-migrate status acme
bin/silo-migrate cleanup acme --yes
```

`cleanup` is destructive and requires `--yes` in command-driven mode.

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
bin/silo-migrate replace-dump acme initial --yes
bin/silo-migrate analyze-dump /path/to/dump.sql.gz
bin/silo-migrate preprocess-dump /path/to/dump.sql.gz -o /path/to/fixed.sql.gz
bin/silo-migrate convert-xml /path/to/xml_dumps -c acme --phase initial --compress
bin/silo-migrate convert-xml /path/to/xml_dumps -c acme --phase initial --batch-size 250
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
filters matching table DDL/DML while streaming.

XML conversion writes import-friendly SQL without wrapping the dump in a single
large transaction. The default XML insert batch size is `1000`; lowering
`--batch-size` can help isolate a failing statement, but it may not fix Docker
Desktop storage or InnoDB fsync errors.

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

`schema export` writes raw schema SQL. `schema bundle` writes AI-safe schema
metadata with no row samples.

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
log entries, and write AI-safe artifacts.

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
bin/silo-migrate trusted review acme findings/finding-20260601-120000-001.yml --decision safe --reviewer alice
bin/silo-migrate trusted review acme findings/finding-20260601-120000-001.yml --decision reject --reviewer alice
bin/silo-migrate trusted redact acme trusted/findings/finding-20260601-120000-001.yml --reviewer alice
bin/silo-migrate trusted session acme --provider bedrock --runtime silo --reason "Inspect one approved raw-data edge case"
```

`trusted inspect` is for narrow, audited data-touching checks. Raw stdout/stderr
are written only under `trusted/inspections/`; normal command output shows the
artifact and audit paths, not the raw values. Audit records are written under
`trusted/audit/`.

`trusted review` can approve or reject `restricted` findings. A safe approval
writes a separate reviewed finding under `findings/` that normal fixture
generation can consume. `trusted_only` findings cannot be approved directly;
use `trusted redact` to write a safe derivative with raw message/exception
content removed.

`trusted session` is Linux/Silo-only and sets up a Trusted Data AI session for
Claude Bedrock mode. It writes a Silo config snippet under `trusted/silo/`, takes
a pre-launch snapshot through Silo, and records audit metadata under
`trusted/audit/`. On macOS it fails with guidance to use the Docker/local safe
workflow or run the trusted session command on a Linux/Silo host.

### Safe AI Workspaces

```bash
bin/silo-migrate ai prepare acme
bin/silo-migrate ai refresh acme
bin/silo-migrate ai prepare acme --output /tmp/acme-safe-ai
```

`ai prepare` creates a generated Normal Dev AI workspace under
`SILO_MIGRATE_SAFE_AI_BASE_PATH`, or a sibling `safe-ai-workspaces/` directory
outside the raw customer project. `ai refresh` is the same operation and
regenerates the workspace after new schema bundles, redacted logs, findings, or
fixtures are produced.

The safe workspace includes:

- `discourse-converters/`
- `schema/`
- `findings/redacted-logs/`
- `findings/finding-*.yml` only when `dev_visibility: safe`
- `synthetic-fixtures/`
- `AGENTS.md`, `CLAUDE.md`, `allowed-commands.json`
- `.silo/normal-dev-ai.yml`

It excludes `config.env`, `dumps/`, `trusted/`, `output/intermediate.db`, raw
logs, database credentials, restricted findings, and trusted-only findings.

## AI-Safe Converter Development Flow

The intended converter-development loop keeps raw customer data inside the
migration runtime while still giving engineers and general-purpose AI agents
enough context to fix converter code.

```text
1. Import source data in the Migration Runtime Zone.
2. Generate an AI-safe schema bundle.
3. Generate a safe AI workspace with `ai prepare`.
4. Develop converter code from schema, converter source, and safe docs.
5. Run the converter through silo-migrate.
6. Capture redacted logs and a redacted structured summary.
7. Convert the summary into durable findings.
8. Convert safe finding shapes into synthetic fixtures.
9. Reproduce and fix converter behavior using synthetic data.
10. Rerun the converter through the controlled runtime.
11. Refresh the safe AI workspace.
12. Escalate to the Trusted Data AI Zone only when raw data inspection is unavoidable.
```

Allowed in the normal Dev AI Zone:

- Converter source code.
- Schema bundles.
- Redacted converter process logs.
- Redacted converter summary JSON.
- Durable `dev_visibility: safe` findings.
- Shape-only synthetic fixtures.

Denied in the normal Dev AI Zone:

- Raw customer dumps.
- Source DB credentials.
- Direct source/final DB container access.
- Real row values.
- Raw converter output that may contain customer data.
- Names, emails, IPs, private messages, post bodies, secrets, or customer-specific text.
- `restricted` and `trusted_only` findings before review/redaction.

`run-converter` is the controlled execution surface. Use
`run-converter CUSTOMER TYPE` for standard platform converter runs and
`run-converter CUSTOMER -- COMMAND...` for unusual low-level commands.
Step-specific converter helpers are deferred until real migration use shows that
platform-level runs are too coarse.

### macOS AI-Assisted Quickstart

macOS uses Docker for migration execution and a generated safe workspace for
normal Codex or Claude development:

```bash
bin/silo-migrate start acme --profile initial-db --wait
bin/silo-migrate run-converter acme vbulletin --redacted-logs
bin/silo-migrate findings generate acme
bin/silo-migrate fixtures generate acme
bin/silo-migrate ai prepare acme
```

Run Codex or Claude from the generated safe workspace, not from the raw customer
project. After converter changes or new findings, rerun the controlled migration
commands and `bin/silo-migrate ai refresh acme`.

Trusted Bedrock sessions with raw data require a Linux/Silo host. On macOS, use
human-operated `trusted inspect`, `trusted review`, and `trusted redact` for
narrow local checks.

### Linux AI-Assisted Quickstart

Linux follows the same Docker baseline as macOS. If Silo is available, the
generated `.silo/normal-dev-ai.yml` snippet can be used for an isolated Normal
Dev AI session that mounts only the safe workspace.

For approved raw-data inspection, use:

```bash
bin/silo-migrate trusted session acme --provider bedrock --runtime silo --reason "Approved narrow inspection"
```

Trusted sessions mount the raw customer project only in the Trusted Data AI
environment, take a pre-launch Silo snapshot, and write audit records. Safe
handoff back to Normal Dev AI should happen through `trusted redact`, safe
findings, synthetic fixtures, and `ai refresh`.

### Safe Workspace Checklist

Before starting a normal AI agent from a generated workspace:

- Confirm `AGENTS.md`, `CLAUDE.md`, and `allowed-commands.json` exist.
- Confirm `dumps/`, `trusted/`, `config.env`, and `output/intermediate.db` are absent.
- Confirm every copied `findings/finding-*.yml` has `dev_visibility: safe`.
- Confirm `.silo/normal-dev-ai.yml` mounts only the safe workspace path.

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

Schema bundle artifacts are safe for normal AI-assisted development because
they contain metadata, not raw rows.

Finding files include safe fields such as:

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

- Normal Dev AI Workspace: converter code plus safe schema, logs, findings,
  fixtures, and generated agent instructions.
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
- Phase 2: AI-safe schema bundles, redacted converter summaries, durable
  findings, and shape-only synthetic fixtures.

The implemented and planned future architecture is:

- Phase 3: Trusted Data Workflow for approved raw-data inspection, visibility
  levels beyond `safe`, audit logs, and redaction review hooks. The initial
  slice is implemented through `trusted inspect`, `trusted review`, and
  `trusted redact`.
- Phase 4: Agent Runtime and Data Boundary. Implement safe Normal Dev AI
  workspaces, optional Linux/Silo agent sessions, Trusted Data AI Bedrock setup,
  snapshots, audit records, and Silo config snippets before replacing the
  Docker migration runtime.

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
