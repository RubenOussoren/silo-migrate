# Silo Migration Architecture

## Agent Brief

This repository contains three relevant codebases:

- `db-migration-toolkit/`: the current Python CLI to be rebuilt.
- `silo/`: the existing Go/Incus project isolation tool.
- `discourse-converters/`: the Ruby converter framework that migration engineers use to build source-specific converters.

The rebuild target is a new Ruby migration tool, tentatively called **Silo Migrate**. It should replace the Python migration toolkit while staying compatible with the current guided migration workflow and project layout. It should be designed so it can later integrate with Silo, but it must not require Silo for the first implementation.

The first implementation target is:

```text
Ruby CLI + Docker runtime + guided interactive workflow + tests
```

The AI/Silo/trusted-data architecture in this document should shape interfaces and boundaries, but should not distract from the first milestone: a working, tested Ruby replacement for the existing Python tool.

## Current Rebuild Status

As of 2026-06-10, the Ruby `silo-migrate/` rebuild has completed the main Phase 1 compatibility slice, the planned Phase 2 converter-aware slice, an initial Phase 3 trusted-data workflow slice, and the first Phase 4 agent-boundary slice. Phase 2 includes AI-safe schema bundles, redacted converter run summaries, durable structured findings, and shape-only synthetic fixtures. Phase 3 now includes explicit finding visibility, safe-only fixture generation, audited trusted inspection, restricted finding review, and trusted-only redaction. Phase 4 starts with safe Normal Dev AI workspace generation and Linux/Silo Trusted Data AI session setup. Future agents should resume from the existing Ruby implementation rather than starting a new port.

A 2026-06-10 refinement pass hardened the restore path and onboarding:

- Base path resolution: `SILO_MIGRATE_BASE_PATH` > user config (`~/.config/silo-migrate/config.env`, written by the interactive first-run prompt) > legacy `/migrations/customers` when writable; unconfigured machines get an actionable error, and non-TTY interactive use fails fast instead of hanging.
- `import-dump` waits for container health before streaming (`--health-timeout`, `--skip-health-wait`), fully verifies gzip integrity in preflight, honors explicit `--fix-collations` on mysql targets (mariadb auto-fix unchanged), and prints per-error-code diagnostics plus replace-dump/start/import recovery steps on failure.
- `cleanup` no longer deletes the project directory when compose down fails (`--force` overrides); converter output streams through a bounded 4 MB tail instead of an unbounded capture; `intermediate.db` is read read-only with busy/WAL handling.
- `run-converter CUSTOMER TYPE` now generates `converter-settings/TYPE.yml` (platform defaults merged with the in-network container host, internal port, and credentials; chmod 0600; mounted read-only at `/converter-settings`; excluded from AI workspaces) and passes it via `--settings` by default. Explicit `--settings` and the `--` escape hatch are unchanged.
- New `doctor` command (environment preflight) and `converter summary CUSTOMER` standalone command; per-command help via `help <command>` / `<command> --help`; the Docker-gated smoke test now runs a real fixture converter against the migration DB over the compose network, produces `intermediate.db`, and asserts redaction end-to-end (no raw values or passwords in findings or AI workspaces).

A second 2026-06-10 pass replaced the copy-based Normal Dev AI workspace with the **safe-artifacts model**: converter code is never copied — the Dev AI works directly in the project's `discourse-converters` git clone (normal commit/push), and `ai prepare/refresh` only write a locally git-ignored `safe-artifacts/` directory inside the clone (schema bundles, redacted logs, safe findings, synthetic fixtures) plus generated instruction files (`AGENTS.md`, `CLAUDE.md`, `.claude/settings.json` deny rules, `.silo/normal-dev-ai.yml`). Redacted-log, findings, and fixture generation auto-refresh `safe-artifacts/` in place. `SILO_MIGRATE_SAFE_AI_BASE_PATH` and `ai prepare -o` were removed. `trusted inspect --as-finding` writes a `trusted_only` finding stub (no raw payload embedded) so inspection conclusions can flow through `trusted redact` into the safe zone. **Do not reintroduce a copy-based workspace; `ai refresh` must only ever rebuild `safe-artifacts/`.**

Implemented:

- Ruby CLI entrypoint and command parser under `silo-migrate/`.
- Guided interactive mode via `silo-migrate`, `silo-migrate <customer>`, and `silo-migrate interactive [customer]`.
- Guided menus support returning to the project menu with `Back`; path prompts accept `back`, `b`, or `..` and use tab completion in a normal terminal.
- Docker runtime adapter for local Linux/macOS execution.
- Fake runtime adapter for command and orchestration tests, including runtime operation recording.
- Explicit Phase 1 runtime contract covering compose lifecycle, command execution, stdin streaming, container state/health checks, import command construction, and schema dump command construction.
- Silo runtime exposes the same method surface but remains a clear placeholder for full migration runtime replacement; Phase 4 now starts with agent runtime and data-boundary scaffolding instead of replacing Docker.
- Project lifecycle commands: `init`, `list`, `status`, `cleanup`, `start`, `stop`, and `regenerate`.
- `start --wait --health-timeout` supports command-driven DB health waits.
- Compatibility with the existing project layout and `config.env`.
- Docker Compose generation for initial DB, final DB, and converter services.
- Dump workflows: `stage-dump`, `import-dump`, `replace-dump`, `analyze-dump`, `preprocess-dump`, and `convert-xml`.
- Initial/final database support for MariaDB, MySQL, and PostgreSQL.
- Converter setup and execution commands: `setup-converter` and `run-converter`.
  - Standard converter shortcut: `silo-migrate run-converter CUSTOMER TYPE` runs `./convert --from TYPE --reset`.
  - Low-level escape hatch remains `silo-migrate run-converter CUSTOMER -- COMMAND...`.
- Converter setup SSH hardening:
  - GitHub SSH preflight before non-interactive clone attempts.
  - Guided retry using terminal SSH prompts for passphrase-protected keys.
  - Command mode support via `setup-converter --allow-ssh-prompt`.
  - Alternate repository URL retry in guided mode.
- Converter container setup now matches the legacy toolkit behavior for dependencies:
  - Build/start with Docker Compose.
  - Run post-start dependencies with direct `docker exec <customer>_converter bundle install`.
- Basic schema export via `silo-migrate schema export`.
- Phase 2 schema bundles via `silo-migrate schema bundle`, including `schema.sql`, `tables.json`, `columns.json`, `indexes.json`, `summary.json`, and `migration_notes.md`.
- Phase 2 redacted converter run artifacts via `silo-migrate run-converter CUSTOMER --redacted-logs` or `--redacted-summary`.
  - Redacted process output is written to `findings/redacted-logs/converter-run-YYYYMMDD-HHMMSS.log`.
  - AI-safe structured summaries are written to `findings/redacted-logs/converter-run-YYYYMMDD-HHMMSS.summary.json`.
  - `latest.log` and `latest.summary.json` are updated after each summary generation.
  - `output/intermediate.db` `log_entries` are read on the host through the `sqlite3` gem and summarized without emitting raw `details` payloads.
  - Converter stdout/stderr is treated as process/runtime context; intermediate DB log entries are treated as the primary source for data-related converter warnings and errors.
- Phase 2 durable findings via `silo-migrate findings generate CUSTOMER`, which reads redacted summary JSON and writes safe `findings/finding-YYYYMMDD-HHMMSS-001.yml` artifacts plus `findings/latest-findings.json`.
- Phase 2 shape-only synthetic fixtures via `silo-migrate fixtures generate CUSTOMER`, which reads safe findings and writes placeholder-only YAML fixtures under `synthetic-fixtures/`.
- Initial Phase 3 finding visibility policy:
  - Findings carry `dev_visibility: safe`, `restricted`, or `trusted_only`.
  - Fixture generation consumes only `safe` findings.
  - Restricted/trusted findings require review or redaction before normal Dev AI use.
- Initial Phase 3 trusted workflow commands:
  - `silo-migrate trusted inspect CUSTOMER --phase PHASE --reason REASON -- COMMAND...` writes raw output only under `trusted/inspections/` and records an audit event under `trusted/audit/`.
  - `silo-migrate trusted review CUSTOMER FINDING --decision safe|reject` reviews restricted findings and can write a safe derivative.
  - `silo-migrate trusted redact CUSTOMER FINDING` writes a safe derivative for trusted-only findings with raw message/exception content removed.
- Initial Phase 4 agent-boundary commands:
  - `silo-migrate ai prepare CUSTOMER` and `ai refresh CUSTOMER` write the locally git-ignored `safe-artifacts/` directory inside the project's `discourse-converters` clone (schema bundles, redacted logs, safe findings, synthetic fixtures, `allowed-commands.json`) plus generated `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`, and `.silo/normal-dev-ai.yml` beside the code. Converter code itself is never copied or touched.
  - Safe AI workspaces exclude `dumps/`, `trusted/`, `output/intermediate.db`, credentials, raw logs, restricted findings, and trusted-only findings.
  - `silo-migrate trusted session CUSTOMER --provider bedrock --runtime silo --reason REASON` is Linux/Silo-only and writes a Trusted Data AI Silo config plus audit metadata before snapshot and launch commands.
- Guided mode shows project path, configured databases, dump counts, and container status before prompting.
- Guided import paths detect dump format/source type, analyze large-table suggestions, allow table exclusions, detect port conflicts before Docker start, and wait for DB health before import.
- Guided import paths automatically generate the schema bundle for the imported phase after a successful import; bundle failures are warnings and do not invalidate the import.
- Guided mode shows schema bundle status in the project summary and exposes schema bundle generation from the main and advanced menus.
- Guided converter runs prompt for an AI-safe redacted converter summary after the run completes or fails, then offer structured findings and shape-only fixture generation. Advanced actions expose redacted summary, findings, and fixture generation.
- Guided converter setup keeps SSH recovery actionable through preflight, terminal SSH prompt retry, alternate repository URL retry, and manual recovery commands for converter start or bundle install failures.
- Opt-in Docker end-to-end smoke coverage uses only synthetic local data and a local fixture converter repository, and now exercises schema bundle generation against a real container.
- Compatibility aliases:
  - `migration-tool` forwards to `silo-migrate`.
  - `xml-to-sql` forwards to `silo-migrate convert-xml`.

Current verification:

- `cd silo-migrate && rake test` passes locally.
- Last observed result after the converter shortcut slice: `95 runs, 466 assertions, 0 failures, 0 errors, 1 skips`.
- Docker-dependent tests remain opt-in with `RUN_DOCKER_TESTS=1 rake test`.
- Last observed Docker-enabled result after the findings and synthetic fixtures slice: `90 runs, 472 assertions, 0 failures, 0 errors, 0 skips`.

Manual smoke status:

- A synthetic Docker-backed smoke path is now automated behind `RUN_DOCKER_TESTS=1`. It exercises `init`, `stage-dump`, `start --wait`, `import-dump`, `schema export`, `schema bundle`, `setup-converter` with a local fixture converter, `run-converter`, and `stop --remove`.
- Guided `Set up converter` was manually exercised on macOS with a passphrase-protected GitHub SSH key:
  - The non-interactive SSH preflight failed quickly with actionable guidance.
  - The terminal SSH prompt retry successfully cloned `discourse-converters`.
  - The converter image built and `test_converter` started.
  - Direct `docker exec test_converter bundle install` completed successfully.

## Goal

Rebuild the current Python `db-migration-toolkit` as a Ruby-based migration tool that:

- Runs on both Linux and macOS.
- Preserves the current guided interactive workflow for existing users.
- Keeps command-driven workflows for developers and automation.
- Adds proper automated tests.
- Improves internal structure by separating CLI, core migration logic, runtimes, and converter support.
- Supports local Docker first and optional Silo/Incus integration later.
- Enables safer AI-assisted converter development by separating schema/finding access from raw customer data access.

## Purpose

The tool exists to make Discourse migration work repeatable and safer. It should help migration engineers:

- Create per-customer migration workspaces.
- Start and stop source/final database containers.
- Import large SQL dumps.
- Convert mysqldump XML exports to SQL.
- Analyze dump size and source database compatibility.
- Fix known dump issues such as MySQL 8 collations and generated columns.
- Set up and run `discourse-converters`.
- Support converter development without unnecessarily exposing customer data to general-purpose AI agents.

## Architectural Outline

The rebuilt tool should be layered as follows:

```text
CLI / Guided UI
  - Parses commands and drives interactive prompts.
  - Contains no direct Docker, Silo, SQL parsing, or converter business logic.

Application Services
  - Project lifecycle.
  - Dump selection/import workflow.
  - XML conversion workflow.
  - Converter setup/run workflow.
  - Schema export, schema bundle, and redacted converter summary workflow.
  - Structured findings and shape-only synthetic fixture workflow.

Core Libraries
  - Config loading/writing.
  - Dump detection and analysis.
  - SQL streaming and filtering.
  - Generated-column preprocessing.
  - XML-to-SQL conversion.
  - Redaction and safe summary generation.
  - Finding generation in later phases.

Runtime Adapters
  - Docker runtime for Linux/macOS.
  - Silo runtime for future Linux isolation.
  - Fake runtime for tests.

External Projects
  - Silo provides optional isolated execution.
  - discourse-converters performs source-specific extraction/transformation.
```

Important rule for future agents: **do not start by merging Silo and the migration tool**. Start by rebuilding the migration tool with clean runtime boundaries. Silo integration is a later backend.

## Non-Goals For The First Milestone

- Do not require Silo or Incus.
- Do not redesign `discourse-converters`.
- Do not remove compatibility with existing customer project directories.
- Do not force users away from the guided interactive workflow.
- Do not build the full trusted AI workflow before the core migration tool works.
- Do not expose raw customer data to regular AI agents through logs, fixtures, prompts, or generated artifacts.

## Architecture Position

The goal is not to fold migration behavior directly into Silo core. The better boundary is:

- **Silo** remains the isolated execution environment for AI agents and project services.
- **Silo Migrate** becomes a migration-focused tool that can run standalone or use Silo as an execution backend.
- **AI agents** get different access depending on whether they are doing normal converter development or trusted customer-data work.

## Current Systems

### Existing Migration Toolkit

The current Python project provides a CLI for Discourse migration workflows:

- Creates customer migration projects under `/migrations/customers/<customer>`.
- Generates Docker Compose files for initial DB, final DB, and converter services.
- Starts, stops, resets, and inspects migration containers.
- Imports SQL dumps into MariaDB, MySQL, or PostgreSQL.
- Converts mysqldump XML exports to SQL.
- Analyzes dumps, excludes large tables, fixes MySQL 8 collations, and preprocesses generated columns.

### Existing Silo Tool

Silo is a Go CLI that creates isolated Linux development environments using Incus system containers.

Important primitives already present:

- Project config through `.silo.yml` and `.silo.local.yml`.
- Project bind mount into `/workspace/<project>`.
- Setup, sync, reset, update, daemons, ports, env, mounts, tools, and agent config.
- Agent modes such as OAuth and Bedrock, with isolated credential directories.
- Snapshots before AI sessions and manual snapshot management.

Current limitation: Silo requires a Linux host because Incus system containers are Linux-only. macOS support for the migration tool therefore needs a separate runtime path.

## Product Boundary

The rebuilt tool should be a separate Ruby package, tentatively named **Silo Migrate**.

Possible command shapes:

```bash
silo-migrate init acme
silo-migrate import-dump acme initial
silo-migrate convert-xml ./xml_dumps -o combined.sql.gz
```

Future Silo integration could expose:

```bash
silo migrate init acme
silo migrate run acme
silo migrate schema acme
```

The standalone command should come first. Silo integration should be added as a backend, plugin, or subcommand once the Ruby port is stable.

## Execution Surfaces

The architecture now has three explicit execution surfaces:

1. **Migration CLI**: `silo-migrate` runs imports, schema bundles, converter runs, findings, fixtures, and trusted review commands. Docker remains the default migration runtime on macOS and Linux.
2. **Normal Dev AI (converter clone + safe-artifacts)**: regular Codex or Claude works directly in the project's `discourse-converters` git clone — real `.git`, normal commit/push. `ai prepare/refresh` write only the locally git-ignored `safe-artifacts/` directory plus instruction/deny files beside the code. The agent must not read sibling raw paths (`../dumps`, `../output`, `../config.env`, `../converter-settings`, `../trusted`, `../uploads`). On macOS this boundary is soft (instructions + `.claude/settings.json` deny rules); Silo later makes it hard by mounting only the clone.
3. **Trusted Data AI Session**: a Linux/Silo Bedrock session for approved raw-data inspection, analysis-only (it never edits converter code). It may mount raw customer data only with an explicit reason, pre-session snapshot, audit record, and safe redaction/handoff path back to Normal Dev AI.

macOS flow:

```text
Migration CLI on macOS
  -> Docker migration runtime
  -> schema bundle / redacted logs / findings / synthetic fixtures
  -> ai prepare / ai refresh (writes safe-artifacts/ into the converter clone)
  -> Codex or Claude runs FROM the clone; edits code in place; commits/pushes normally

Trusted raw-data work on macOS (human-operated, analysis-only):
  -> trusted inspect --as-finding (audited raw query + trusted_only finding stub)
  -> human reviews the raw inspection (optionally via a Bedrock chat, manually)
  -> trusted redact writes a safe derivative into findings/
  -> next refresh mirrors it into safe-artifacts/
```

Linux flow:

```text
Migration CLI on Linux
  -> Docker migration runtime by default
  -> ai prepare / ai refresh
  -> optional Silo Normal Dev AI session mounting only the converter clone

Approved raw-data inspection (future, analysis-only)
  -> trusted session --provider bedrock --runtime silo
  -> Silo snapshot
  -> Trusted Data AI Session mounting raw project data
  -> trusted redact / safe findings / fixtures / ai refresh
```

## Critical Design Principles

The architecture should be judged against these principles:

1. **Do not make Silo a migration product.** Silo should provide isolation, snapshots, agent modes, mounts, ports, and process execution. Migration behavior should live in Silo Migrate.
2. **Do not make Silo Migrate require Silo.** The migration tool must remain useful on macOS and Linux with Docker because Silo is currently Linux-only.
3. **Treat guided interactive mode as the primary user experience.** Existing users mostly rely on the current interactive flow; the rebuild should preserve that style while using the new product naming and command language.
4. **Keep source data access behind explicit runtime boundaries.** Converter code can be developed from schema and findings, but raw rows should stay in trusted runtime paths.
5. **Make the runtime replaceable.** Docker, Silo, and test runtimes should expose the same high-level operations so core migration logic remains testable.
6. **Prefer incremental compatibility over a big-bang redesign.** The first Ruby version should preserve current workflows before adding higher-level AI orchestration.

## Primary User Experience

The current tool is mainly used through its interactive mode. The Ruby port should preserve that guided style, but the wording and command names should move forward with the new tool identity.

```bash
silo-migrate
silo-migrate acme
```

An explicit subcommand can also be supported for clarity and scripting:

```bash
silo-migrate interactive
silo-migrate interactive acme
```

`silo-migrate interactive [customer]` should be the canonical explicit form. Bare `silo-migrate` and `silo-migrate <customer>` can be convenience shortcuts if the CLI parser can support them cleanly. Customer names that collide with subcommands, such as `init`, `list`, or `status`, should require the explicit `interactive` form.

The guided mode should be implemented as a controller over the same command services used by explicit CLI commands. It should not contain separate business logic.

Required guided-mode behavior:

- List existing projects and create a new project when none exists.
- Jump directly into a project when a customer name is provided.
- Show project location, configured services, running state, and dump counts.
- Prompt for source data format: SQL dump, gzipped SQL dump, tar archive containing SQL, or mysqldump XML.
- Let users return from submenus to the project menu with a Back option.
- Support path-entry ergonomics for dump/XML prompts, including `back`, `b`, or `..` to return and tab completion in a normal terminal.
- Copy or extract dumps into the project.
- Convert XML to SQL when selected.
- Start the relevant DB service.
- Wait for database health in guided import paths.
- Analyze dump size and suggest import options.
- Detect dump format and likely source DB type before import.
- Import initial or final dumps.
- Add a final DB.
- Export source/final DB schema.
- Set up the converter.
- Run converter commands.
- Regenerate runtime config.
- Replace/reset DB data.
- Clean up the project.

Command-driven flows should remain available for developers and automation, but guided mode should be the continuity anchor for current users.

## Compatibility Strategy

The rebuild should support a transition period where old command names continue to work.

Recommended aliases:

```bash
migration-tool -> silo-migrate
xml-to-sql -> silo-migrate convert-xml
```

The old aliases should forward arguments to the new command. They can print a short notice:

```text
migration-tool has been replaced by silo-migrate.
```

Compatibility should cover:

- Project config files currently named `config.env`.
- Existing `/migrations/customers/<customer>` layout.
- Existing dump folders: `dumps/initial`, `dumps/final`.
- Existing generated `docker-compose.yml` where practical.
- Existing command names and flags for core workflows.

Breaking changes should require a migration command:

```bash
silo-migrate project upgrade acme
```

## Runtime Backends

Silo Migrate should separate migration logic from the environment that executes it.

```text
Ruby CLI
  |
  v
Migration Core
  |
  +-- Local Docker Runtime      Linux + macOS
  +-- Silo Runtime              Linux only, Incus-backed
  +-- Test Runtime              no containers, fixtures/mocks
```

### Local Docker Runtime

This is the default portable runtime for Linux and macOS.

Responsibilities:

- Generate or manage Docker Compose services.
- Run MariaDB, MySQL, PostgreSQL, and converter containers.
- Stream dumps into database containers.
- Work with Docker Desktop on macOS and Docker or Podman-compatible tooling on Linux where practical.

### Silo Runtime

This is the higher-isolation Linux runtime.

Responsibilities:

- Start or resume the Silo project container.
- Use Silo config for setup, sync, daemons, mounts, ports, and agent modes.
- Run migration commands inside controlled project environments.
- Use Silo snapshots before risky operations.

Silo Runtime should not require the agent to receive raw Docker socket access. The migration tool should call controlled runtime operations instead.

### Runtime Contract

Phase 1 has a concrete runtime contract in `silo-migrate/lib/silo_migrate/runtime/contract.rb`. It intentionally covers only the high-level operations currently needed by the CLI and application services:

```text
compose(customer, args, capture:, timeout:)
run(cmd, chdir:, capture:, timeout:, stdin_data:, separate_process_group:)
run_with_stdin(cmd, chdir:) { |stdin| ... }
container_running?(name)
wait_for_container_healthy(container_name, timeout:)
exec_import_command(container_name, db_type, db_name, password, max_packet:, disable_keys:)
schema_dump_command(container_name, db_type, db_name, password)
```

The Docker and Fake runtimes implement this complete contract. The Silo runtime currently implements the same method names only to fail clearly for full migration runtime replacement. Phase 4 agent-session work should extend Silo config and session boundaries first, then add migration runtime replacement as a later subphase rather than bypassing service boundaries with direct Docker or Incus calls.

The migration core should not know whether these operations are implemented with Docker Compose, Silo/Incus, or a fake test runtime. Later phases may add snapshot and restore operations when the Silo backend is implemented.

### Runtime Concerns

The Docker runtime is easiest to ship but has weaker isolation. The Silo runtime is safer for AI workflows but Linux-only. The architecture should avoid pretending one runtime satisfies every use case.

Important constraints:

- Docker Desktop on macOS has different filesystem and networking behavior than native Linux Docker.
- Incus/Silo should not expose a host Docker socket to untrusted agent sessions.
- Large dumps should be mounted or streamed efficiently; copying multi-GB files between layers should be avoided.
- Runtime logs may contain customer data and must be classified before being shown to regular AI agents.

## Data Access Model

Migration work should be split into explicit data zones and generated workspaces.

### Normal Dev AI (converter clone + safe-artifacts)

Used by regular Claude/Codex for converter development. The agent's working
directory is the project's real `discourse-converters` git clone — converter
code is edited in place, tested by `run-converter` against the same tree (the
compose file mounts it), and committed/pushed with normal git. There is **no
separate copy-workspace**: only data artifacts are zone-separated, via the
generated `safe-artifacts/` directory inside the clone.

Allowed (everything the agent needs is inside the clone):

- Converter source code (the clone itself; normal git workflow).
- `safe-artifacts/schema/` — schema bundles (tables, columns, types, indexes, row counts, sizes; no rows).
- `safe-artifacts/findings/redacted-logs/*.summary.json` and `*.log` — redacted converter run output.
- `safe-artifacts/findings/finding-*.yml` — findings with `dev_visibility: safe` only.
- `safe-artifacts/synthetic-fixtures/` — shape-only placeholder fixtures.
- Generated `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`, `safe-artifacts/allowed-commands.json`, `.silo/normal-dev-ai.yml`.

Denied (sibling raw paths the agent must never read):

- `../dumps/`, `../output/` (including `intermediate.db`), `../config.env`, `../converter-settings/`, `../trusted/`, `../uploads/`, `../shared/`, `../docker-compose.yml`.
- Source DB credentials, direct DB network access, real customer row values, raw logs.
- `restricted` and `trusted_only` findings (they never reach `safe-artifacts/`).

Mechanics and guarantees:

- `silo-migrate ai prepare CUSTOMER` writes `safe-artifacts/` and the instruction files; `ai refresh` rebuilds them. **Refresh only ever deletes/rebuilds `safe-artifacts/` — never converter code, `.git`, or user files.**
- All generated paths are listed in a managed block in `.git/info/exclude` (local-only, never committed) plus a self-ignoring `safe-artifacts/.gitignore`, so `git status` stays clean and nothing generated can be committed upstream by accident. Generated root files carry a `silo-migrate:generated` marker and are never written over unmanaged/upstream files (fallback: `safe-artifacts/AGENTS.md`).
- Redacted-log, findings, and fixture generation **auto-refresh `safe-artifacts/` in place** (gated on a prior `ai prepare`), so the agent's context updates without extra commands.
- Enforcement on macOS is soft (instructions + `.claude/settings.json` deny rules) per design; Silo later provides the hard boundary by mounting only the clone (`.silo/normal-dev-ai.yml`).

### Migration Runtime Zone

Used to actually process the migration.

Allowed:

- Source DB access.
- Final DB access.
- Converter container access.
- Raw dumps and migration volumes.

The regular AI agent should not shell directly into this zone. It can request controlled actions such as running the converter, running tests, or collecting a redacted failure summary.

Current implemented handoff:

- `silo-migrate run-converter CUSTOMER TYPE` runs the standard discourse-converters command `./convert --from TYPE --reset` through the configured runtime.
- `silo-migrate run-converter CUSTOMER TYPE --no-reset` omits the default reset; `--settings PATH` passes an explicit settings file to `./convert`.
- `silo-migrate run-converter CUSTOMER -- COMMAND...` remains the low-level command passthrough for unusual converter work.
- `silo-migrate run-converter CUSTOMER --redacted-logs` runs the converter through the configured runtime, captures stdout/stderr, and writes redacted artifacts.
- `--redacted-summary` is an alias for the same behavior.
- Redacted process logs are useful for runtime/process failures such as Ruby exceptions, missing gems, DB connection failures, and container failures.
- `output/intermediate.db` `log_entries` are read directly by the host tool and summarized as structured converter data logs.
- Full `details` JSON from `log_entries` is not emitted. The summary emits keys, inferred value types, safe value categories, string lengths, and nullability instead.
- If `output/intermediate.db` is absent, the tool still writes a process-only summary and marks `intermediate_db.available: false`.
- `silo-migrate findings generate CUSTOMER` converts redacted summary warnings/errors into durable `dev_visibility: safe` finding YAML files and updates `findings/latest-findings.json`.
- `silo-migrate fixtures generate CUSTOMER` converts safe finding shape metadata into placeholder-only YAML fixtures under `synthetic-fixtures/`.

### Trusted Data AI Zone

Used when real customer data must be inspected by an approved model, such as Bedrock.

Allowed:

- Controlled access to data-touching logs or query output.
- Narrow, task-scoped inspection of customer data.

Required:

- Redaction or summarization before results are sent back to the Normal Dev AI Workspace.
- Audit-friendly command logs.
- Linux/Silo host for Bedrock-backed raw-data sessions.
- Explicit reason/session metadata.
- Snapshot before agent launch.

Current implemented handoff:

- `silo-migrate trusted session CUSTOMER --provider bedrock --runtime silo --reason REASON` writes a Trusted Data AI Silo config under `trusted/silo/`, records audit metadata under `trusted/audit/`, requests a Silo snapshot, and launches Claude Bedrock mode through Silo.
- On macOS, this command fails with guidance to use Docker plus safe Normal Dev AI workspaces locally, or to run the trusted session on a Linux/Silo host.

## Converter Development Flow

Regular converter development should not require customer data exposure, and
converter code has exactly one home: the project's `discourse-converters` clone.

```text
1. Import or connect source DB in the Migration Runtime Zone.
2. Generate a schema bundle.
3. Run `silo-migrate ai prepare CUSTOMER` (writes safe-artifacts/ into the clone).
4. Run the regular AI agent FROM the clone directory.
5. AI edits converter code in place; commits/pushes with normal git.
6. AI asks the human operator to run
   `silo-migrate run-converter CUSTOMER TYPE --redacted-logs`
   — this executes the exact edited working tree inside the converter container
   (compose mounts ./discourse-converters).
7. Redacted process logs + AI-safe summary are written, and findings/fixtures
   can be generated; each of these auto-refreshes safe-artifacts/ in place.
8. AI re-reads safe-artifacts/findings/redacted-logs/latest.summary.json and iterates.
9. If raw data inspection is required, escalate to the Trusted Data AI Zone
   (analysis-only): trusted inspect --as-finding -> human review -> trusted redact
   -> the safe derivative reaches safe-artifacts/ on the next refresh.
```

Example schema bundle:

```text
schema/
  source_schema.sql
  source_schema.json
  table_stats.json
  indexes.json
  foreign_keys.json
  redacted_enums.json
  migration_notes.md
```

Example redacted failure:

```text
users import failed
source table: legacy_users
target column: email
error: NOT NULL violation
affected rows: 42
sample value: [REDACTED]
```

Implemented converter run summary shape:

```json
{
  "artifact_version": 1,
  "generated_at": "2026-06-01T12:00:00Z",
  "customer": "acme",
  "command": ["bundle", "exec", "ruby", "converter.rb"],
  "success": false,
  "exit_status": 1,
  "sources": {
    "process_output": {
      "stdout_lines": 20,
      "stderr_lines": 4,
      "detected_errors": []
    },
    "intermediate_db": {
      "available": true,
      "path": "[PROJECT_PATH]/output/intermediate.db",
      "log_entry_count": 12,
      "counts_by_type": {
        "warning": 9,
        "error": 3
      },
      "entries": []
    }
  },
  "contains_raw_rows": false,
  "dev_ai_visibility": "safe",
  "redaction_counts": {}
}
```

Intermediate DB entries preserve converter context but redact row-shaped details:

```json
{
  "created_at": "2026-06-01 12:00:00",
  "type": "error",
  "message": "Failed to process item",
  "exception": "NoMethodError: undefined method `strip' for nil",
  "details_shape": {
    "keys": ["bio", "created_at", "email", "id"],
    "value_types": {
      "bio": "text",
      "created_at": "null",
      "email": "email",
      "id": "integer"
    },
    "value_categories": {
      "bio": "[TEXT length=190]",
      "created_at": "[NULL]",
      "email": "[EMAIL]",
      "id": "[INTEGER]"
    },
    "redacted": true
  },
  "details": "[REDACTED_DETAILS]"
}
```

## Trusted-to-Dev Findings Handoff

Some converter bugs cannot be fixed from schema alone. Examples include malformed dates, unexpected sentinel values, mixed encodings, deleted users referenced by posts, or platform-specific HTML/BBCode patterns. In those cases, the Trusted Data AI Zone should pass **actionable facts and minimal reproductions** to the Dev AI Zone, not raw customer data.

The handoff should use structured artifacts:

```text
findings/
  finding-20260601-120000-001.yml
  latest-findings.json
  redacted-logs/
    converter-run-20260601-120000.log
    converter-run-20260601-120000.summary.json
    latest.log
    latest.summary.json
synthetic-fixtures/
  finding-20260601-120000-001.yml
```

Example finding:

```yaml
artifact_version: 1
id: finding-20260601-120000-001
source: findings/redacted-logs/latest.summary.json
source_entry_index: 0
failure: converter_log_error
severity: error
message: "Failed to process item"
exception_class: NoMethodError
observed_shape:
  keys:
    - email
    - bio
  value_types:
    email: email
    bio: text
dev_visibility: safe
recommended_next_step: "Reproduce with a shape-only fixture and update converter handling."
```

The Dev AI receives enough detail to change converter code, but not real names, emails, post bodies, IP addresses, private messages, or raw customer-specific text.

When source values are necessary to reproduce behavior, the trusted zone should generate synthetic fixtures that preserve type, shape, cardinality, nullability, length, encoding, and edge-case structure. For example, a real post body should become a synthetic post body with the same broken markup pattern, not the same text.

If the exact raw value is essential, keep it inside the Trusted Data AI Zone. The trusted zone can propose the converter patch or produce a narrow failing test with a synthetic equivalent. The Dev AI should review and integrate the patch without receiving the raw value.

### Finding Approval Levels

Not every finding can safely cross into the Dev AI Zone. Findings should have an explicit visibility level:

```yaml
dev_visibility: safe        # can be shown to regular AI
dev_visibility: restricted  # needs human review first
dev_visibility: trusted_only # stays inside Bedrock/trusted zone
```

Examples:

- `safe`: table names, column names, row counts, normalized data shapes, synthetic examples.
- `restricted`: short transformed snippets, rare values, customer-specific taxonomy labels.
- `trusted_only`: names, emails, IP addresses, private messages, raw post bodies, access tokens, legal/medical/financial text.

Restricted findings should require human approval or an explicit redaction pass before they are available to Claude/Codex.

## Converter Repository Integration

The `discourse-converters` repository already has the right shape for this model:

- Converters live under `converters/<platform>/`.
- Each converter has a `converter.rb`, `settings.yml`, database connector code, and step classes.
- Steps read from `source_db` and write normalized records through `Models` into the intermediate SQLite database.
- Source database adapters live under `support/db/`.

Silo Migrate should not replace this framework. It should orchestrate it.

Useful integration points:

- Generate source schema bundles from each converter's configured database connection. Implemented through `silo-migrate schema bundle`.
- Run standard platform converters in the Migration Runtime Zone. Implemented through `silo-migrate run-converter CUSTOMER TYPE`.
- Run unusual converter commands through the same runtime boundary. Implemented through `silo-migrate run-converter CUSTOMER -- COMMAND...`.
- Read intermediate DB log entries and convert them into AI-safe redacted summaries. Implemented through `silo-migrate run-converter --redacted-logs`.
- Convert redacted intermediate DB log entries and process-output errors into durable structured findings. Implemented through `silo-migrate findings generate`.
- Generate shape-only synthetic fixture YAML from safe findings. Implemented through `silo-migrate fixtures generate`.
- Pass settings into the converter without exposing credentials to the Dev AI Zone.

The database connector should remain available to the converter runtime, but source DB credentials and network access should be withheld from normal agent sessions.

## Configuration Model

Silo Migrate should keep project configuration readable and portable.

Recommended project files:

```text
/migrations/customers/acme/
  config.env                 # compatibility with current tool
  migrate.yml                # future structured config
  docker-compose.yml         # Docker runtime output
  dumps/
    initial/
    final/
  schema/
  findings/
    redacted-logs/
  synthetic-fixtures/
  output/
  uploads/
  shared/
  discourse-converters/
```

`config.env` should remain the compatibility source initially. `migrate.yml` can be introduced later for richer settings such as runtime, data-access policy, converter repo path, and schema bundle options.

The base path must be configurable:

```bash
SILO_MIGRATE_BASE_PATH=/migrations/customers
```

On macOS, defaulting to `/migrations/customers` may be inconvenient. The tool should either ask during first run or support a per-user config path.

## Proposed Ruby Package Structure

```text
bin/silo-migrate
lib/silo_migrate.rb
lib/silo_migrate/cli.rb
lib/silo_migrate/config.rb
lib/silo_migrate/project.rb
lib/silo_migrate/runtime/base.rb
lib/silo_migrate/runtime/docker.rb
lib/silo_migrate/runtime/silo.rb
lib/silo_migrate/compose_generator.rb
lib/silo_migrate/dump_analyzer.rb
lib/silo_migrate/dump_preprocessor.rb
lib/silo_migrate/xml_to_sql_converter.rb
lib/silo_migrate/schema_exporter.rb
lib/silo_migrate/services/schema_service.rb
lib/silo_migrate/services/converter_summary_service.rb
lib/silo_migrate/services/converter_findings_service.rb
lib/silo_migrate/services/synthetic_fixture_service.rb
test/
fixtures/
```

Core logic should avoid container assumptions. Runtime classes should own subprocess execution, container lifecycle, networking, and snapshots.

## CLI Capability Groups

### Guided Workflow

```bash
silo-migrate
silo-migrate acme
silo-migrate interactive
silo-migrate interactive acme
```

This is the primary user workflow and should remain stable.

### Project Lifecycle

```bash
silo-migrate init acme
silo-migrate list
silo-migrate status acme
silo-migrate cleanup acme
```

### Runtime Operations

```bash
silo-migrate start acme --profile initial-db
silo-migrate stop acme --profile all
silo-migrate regenerate acme
```

### Data Processing

```bash
silo-migrate analyze-dump dump.sql.gz
silo-migrate preprocess-dump dump.sql.gz
silo-migrate convert-xml xml_dumps/ -o combined.sql.gz
silo-migrate import-dump acme initial
```

### AI-Safe Converter Support

```bash
silo-migrate schema export acme
silo-migrate schema bundle acme
silo-migrate schema bundle acme --phase final
silo-migrate run-converter acme vbulletin
silo-migrate run-converter acme vbulletin --no-reset
silo-migrate run-converter acme vbulletin --settings /path/to/settings.yml
silo-migrate run-converter acme -- ./convert --from vbulletin --reset
silo-migrate run-converter acme --redacted-logs
silo-migrate run-converter acme --redacted-summary
silo-migrate findings generate acme
silo-migrate findings generate acme --from findings/redacted-logs/converter-run-20260601-120000.summary.json
silo-migrate fixtures generate acme
silo-migrate fixtures generate acme --from findings/latest-findings.json
```

Step-specific converter helper commands remain deferred unless real migration use shows that platform-level `run-converter CUSTOMER TYPE` is too coarse.

## Cross-Platform Strategy

The Ruby tool should support:

- macOS with Docker Desktop.
- Linux with Docker, and optionally Podman-compatible Compose.
- Linux with Silo/Incus for isolated AI execution.

Portability rules:

- Do not assume `/proc`, systemd, Incus, or Linux-only paths in core logic.
- Keep default customer data path configurable, for example `SILO_MIGRATE_BASE_PATH`.
- Use Ruby standard libraries for gzip, XML parsing, file operations, and subprocess management where possible.
- Keep shell commands behind runtime adapters.
- Normalize path handling with `Pathname`.
- Avoid host Docker socket exposure inside Silo containers unless a future security review explicitly allows it.

## Silo Integration Model

Silo can eventually treat migration as a project capability.

Example future `.silo.yml` extension:

```yaml
migration:
  enabled: true
  base_path: /workspace/migrations
  runtime: silo

  data_access:
    dev_ai:
      schema: allow
      synthetic_fixtures: allow
      source_db_network: deny
      raw_customer_rows: deny
    trusted_ai:
      provider: bedrock
      raw_customer_rows: allow
      output_policy: redact

  services:
    initial_db:
      type: mariadb
    final_db:
      type: postgres
    converter:
      repo: discourse-org/discourse-converters
```

This should be considered future-facing. The first Ruby version should not require Silo.

## Implementation Phases

### Phase 1: Ruby Compatibility Port

Goal: replace the Python tool without changing the user workflow.

Status: compatibility hardening is implemented in `silo-migrate/`. The remaining Phase 1 work should be limited to bug fixes found during real operator use, not redesign.

- Implement guided interactive mode under the new command naming.
- Preserve existing project layout and `config.env`.
- Implement Docker runtime.
- Port SQL dump import, XML conversion, dump analysis, generated-column preprocessing, and compose generation.
- Add compatibility aliases for `migration-tool` and `xml-to-sql`.
- Add tests for all pure logic and command parsing.
- Keep guided workflow ergonomic through project summaries, Back navigation, path completion, health waits, dump/source detection, large-table suggestions, port conflict recovery, and converter recovery instructions.
- Keep the Phase 1 runtime contract explicit and covered by Docker/Fake tests, with Silo as a Phase 4 placeholder.
- Keep the Docker end-to-end smoke path opt-in under `RUN_DOCKER_TESTS=1` and limited to synthetic local SQL plus a local fixture converter repository.

### Phase 2: Converter-Aware Workflow

Goal: make converter development easier without changing data access boundaries.

Status: implemented for the planned Phase 2 slice. AI-safe schema bundles, redacted converter run summaries, durable structured findings, and shape-only synthetic fixture generation are implemented in `silo-migrate/`.

- Implemented: `silo-migrate schema bundle` exports an AI-safe schema bundle with schema SQL, tables, columns, indexes, summary metadata, and migration notes.
- Implemented: guided imports automatically generate a schema bundle after successful import, and guided mode exposes bundle generation from the main and advanced menus.
- Implemented: Docker and Fake runtimes expose Phase 2 metadata command support; Silo keeps the same method surface as a Phase 4 placeholder.
- Implemented: `silo-migrate run-converter CUSTOMER TYPE` expands to `./convert --from TYPE --reset`, validates the converter directory, supports `--no-reset` and `--settings`, and keeps `-- COMMAND...` for low-level passthrough.
- Implemented: `silo-migrate run-converter CUSTOMER --redacted-logs` and `--redacted-summary` generate redacted process logs and AI-safe summary JSON under `findings/redacted-logs/`.
- Implemented: failed converter runs still write redacted artifacts before returning failure.
- Implemented: host-side `sqlite3` dependency reads `output/intermediate.db` `log_entries` without shelling into the converter container.
- Implemented: intermediate DB `details` payloads are not emitted; summaries include keys, inferred value types, safe value categories, string lengths, and nullability.
- Implemented: `silo-migrate findings generate CUSTOMER` writes durable structured finding files under `findings/` and updates `findings/latest-findings.json`.
- Implemented: `silo-migrate fixtures generate CUSTOMER` writes shape-only fixture YAML under `synthetic-fixtures/`.
- Implemented: guided converter runs prompt for redacted summary generation after success or failure, then offer findings and fixture generation; advanced actions can generate summaries, findings, and fixtures from latest artifacts.
- Deferred: add step-specific converter helpers only if real migration use shows that platform-level `run-converter CUSTOMER TYPE` is still too coarse.

### Phase 3: Trusted Data Workflow

Goal: formalize the Bedrock/customer-data path.

- Implemented initial slice: finding visibility levels.
- Implemented initial slice: safe-only fixture generation.
- Implemented initial slice: audited trusted-only inspection command.
- Implemented initial slice: restricted finding review and trusted-only redaction hooks.
- Implemented initial slice: Linux/Silo Bedrock trusted session setup with config generation, snapshot command construction, and audit metadata.
- Still future: broader policy/config integration and production hardening of Bedrock session launch behavior.

### Phase 4: Agent Runtime and Data Boundary

Goal: support safe Normal Dev AI and trusted Bedrock raw-data workflows without making Silo mandatory.

- Implemented: `silo-migrate ai prepare CUSTOMER` and `ai refresh CUSTOMER` write the locally git-ignored `safe-artifacts/` directory inside the project's `discourse-converters` clone (no copy-workspace; converter code stays in its one git home).
- Implemented: generated `AGENTS.md`, `CLAUDE.md`, `.claude/settings.json` deny rules, `safe-artifacts/allowed-commands.json`, and `.silo/normal-dev-ai.yml` beside the code; redacted-log/findings/fixture generation auto-refreshes `safe-artifacts/`.
- Implemented initial slice: `trusted session CUSTOMER --provider bedrock --runtime silo --reason REASON` is Linux/Silo-only and generates Trusted Data AI config, audit metadata, snapshot intent, and launch command construction.
- Keep Docker as the default migration runtime on macOS and Linux.
- Keep Silo optional and Linux-only for agent isolation.
- Defer full `Runtime::Silo` database/container replacement until the agent-session model is validated.

## Risk Register

### Risk: The port becomes a redesign and delays replacement

Mitigation: Phase 1 should preserve current workflows first, especially guided interactive mode.

### Risk: Runtime abstraction hides important platform differences

Mitigation: Keep runtime contracts small and explicit. Document behavior differences between Docker Desktop, Linux Docker, and Silo.

### Risk: Regular AI gets access to customer data through logs

Mitigation: Treat logs as data artifacts. Classify and redact them before crossing from Migration Runtime Zone to Dev AI Zone.

### Risk: Silo integration encourages Docker socket exposure

Mitigation: Do not use host Docker socket passthrough as the default design. Use controlled Silo runtime operations instead.

### Risk: Interactive mode becomes hard to test

Mitigation: Implement guided mode as a controller over command services, with prompt adapters that can be tested without a terminal. Keep Back navigation and path prompt behavior covered by fake-prompt tests.

### Risk: Large dump operations are too slow on macOS

Mitigation: Stream data where possible, avoid redundant copies, and document Docker Desktop file-sharing performance expectations.

### Risk: Converter setup hangs on GitHub SSH authentication

Mitigation: `setup-converter` now preflights GitHub SSH access in non-interactive mode, explains common SSH agent setups, supports `--allow-ssh-prompt` for passphrase-protected keys, and lets guided mode retry with terminal SSH prompts or an alternate repository URL.

### Risk: Converter dependency install hangs after container startup

Mitigation: Match the legacy Python toolkit by running post-start dependencies through direct `docker exec <customer>_converter bundle install` instead of Compose exec. Keep the command bounded and print manual recovery instructions using `docker exec -it <customer>_converter bundle install`.

### Risk: Data-zone policy is too heavy for day-to-day migration work

Mitigation: Make the policy strict for AI access, not for trusted human operators. Human migration engineers can still use local commands with appropriate access.

## Testing Strategy

The port should add tests from the beginning.

Recommended stack:

- `minitest` for low-dependency unit tests.
- Fixture SQL, gzipped SQL, XML, and generated-column dumps.
- Fake runtime adapter for CLI and orchestration tests.

Test priorities:

- Customer name validation.
- Config read/write and merge behavior.
- Compose file generation.
- Dump type detection.
- Large table analysis.
- XML-to-SQL conversion.
- Generated-column preprocessing.
- CLI option parsing and help output.
- Docker runtime command construction without executing containers.
- Guided interactive decision paths using fake prompts and a fake runtime.
- Guided Back navigation and path completion behavior.
- Explicit runtime contract coverage for Docker, Fake, and the Phase 4 Silo placeholder.
- Schema bundle artifact generation, normalized metadata JSON, and guided auto-generation after successful import.
- Redacted converter run artifact generation for successful and failed runs.
- Host-side intermediate DB `log_entries` reading from fixture SQLite databases.
- Redaction of process stdout/stderr, converter messages/exceptions, project paths, config secrets, emails, IPs, URLs, and structured details.
- Process-only summaries when `output/intermediate.db` is absent.
- Guided converter summary prompt and advanced summary generation action.
- Opt-in Docker end-to-end smoke coverage with synthetic local SQL, schema bundle generation, and a local fixture converter repository.
- Backward-compatible project loading from existing `config.env`.
- Silo runtime command construction when later-phase Silo features are implemented.

Integration tests should be optional because Docker, Docker Desktop, and Incus availability varies by host.

Current local status:

- `cd silo-migrate && rake test` passes.
- Last observed non-Docker result after the converter shortcut slice: `95 runs, 466 assertions, 0 failures, 0 errors, 1 skips`.
- Docker-enabled result was not rerun for the converter shortcut slice; last recorded Docker-enabled result with `RUN_DOCKER_TESTS=1 rake test`: `90 runs, 472 assertions, 0 failures, 0 errors, 0 skips`.

## Open Decisions

- Final product name and command name.
- Whether the Silo integration should be a plugin, built-in subcommand, or separate package invoked by Silo.
- Whether old `migration-tool` entry points remain as long-term aliases or only transition shims.
- Whether the current schema bundle artifact format is stable enough for downstream tooling, or should remain explicitly versioned as artifact version 1.
- Whether the current redacted converter summary artifact format is stable enough for downstream tooling, or should remain explicitly versioned as artifact version 1.
- Additional redaction rules for rare converter log formats and database errors discovered in real migrations.
- How Bedrock requests are authorized, logged, and separated from regular AI sessions.
- Whether Podman support is a first-class target or best-effort.
- Whether raw dump storage remains under `/migrations/customers` or moves to a configurable project-local path.
- Whether `migrate.yml` is introduced in Phase 1 or deferred until after compatibility is stable.

## Recommended Next Step

Resume from the existing Ruby `silo-migrate/` implementation, not by starting a new rebuild. Phase 1 is in compatibility-hardening shape, and the planned Phase 2 converter-aware slice now has schema bundle generation, redacted converter run summaries, durable findings, and shape-only synthetic fixtures.

Priority order:

1. Keep Phase 1 stable: fix bugs found in real migration use without changing public CLI behavior.
2. Keep the Docker smoke path green under `RUN_DOCKER_TESTS=1` when runtime behavior changes.
3. Keep Silo integration deferred until Phase 4.
4. Keep the Phase 2 command surfaces stable; preserve both `run-converter CUSTOMER TYPE` and `run-converter CUSTOMER -- COMMAND...`, and defer step-specific helpers until real migration use proves platform-level runs too coarse.
