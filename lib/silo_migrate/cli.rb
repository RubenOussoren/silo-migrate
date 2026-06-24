# frozen_string_literal: true

require "optparse"
require "pathname"
require "set"

module SiloMigrate
  class CLI
    COMMANDS = %w[
      interactive go init list status cleanup start stop regenerate import-dump replace-dump
      analyze-dump preprocess-dump convert-xml convert-json stage-dump setup-converter add-final-db
      run-converter converter discourse schema findings fixtures ai trusted doctor self-update uninstall help
    ].freeze

    COMMAND_HELP = {
      "interactive" => <<~HELP,
        Usage: silo-migrate interactive [CUSTOMER]   (alias: go)

        Guided workflow: create/select a project, then drive the migration
        through five workflow-level actions: Initial dump, Final dump,
        Converter setup, Discourse uploads container, and Discourse import
        container. Granular recovery and maintenance actions live under grouped
        Advanced actions.
        Shortcut: 'silo-migrate' (no args) or 'silo-migrate CUSTOMER'.
      HELP
      "init" => <<~HELP,
        Usage: silo-migrate init CUSTOMER [options]
          --db-type TYPE        mariadb (default), mysql, or postgres
          --initial-port PORT   host port for the initial DB
          --db-name NAME        initial database name
          --password PASSWORD   database password
          --final-db-type TYPE  also configure a final database
          --final-port PORT     host port for the final DB
      HELP
      "cleanup" => <<~HELP,
        Usage: silo-migrate cleanup CUSTOMER --yes [--force]
          -y, --yes   confirm deletion of the project directory and volumes
          --force     delete the project directory even if containers/volumes
                      could not be stopped (default: abort and keep the directory)
      HELP
      "start" => <<~HELP,
        Usage: silo-migrate start CUSTOMER [options]
          --profile PROFILE          all (default), initial-db, final-db, or converter
          --build                    rebuild images before starting
          --force                    ignore host port conflicts
          --wait                     wait for database health after starting
          --health-timeout SECONDS   health wait limit (default 60)
      HELP
      "stop" => <<~HELP,
        Usage: silo-migrate stop CUSTOMER [--profile PROFILE] [--remove]
          --remove   also remove containers (compose down)
      HELP
      "import-dump" => <<~HELP,
        Usage: silo-migrate import-dump CUSTOMER PHASE [options]   (PHASE: initial|final)
          -f, --file FILE            dump filename (required when multiple dumps staged)
          -x, --exclude-tables T1,T2 skip INSERTs for these tables
          --fast                     disable keys/checks during import
          --turbo                    fast mode + 1G max packet (recommended >1GB dumps)
          --max-packet VALUE         max_allowed_packet (default 512M)
          --fix-collations           force MySQL 8 collation mapping (mariadb auto-detects)
          --no-fix-collations        disable the mariadb collation auto-fix
          --health-timeout SECONDS   wait limit for container health (default 60)
          --skip-health-wait         do not wait for container health
          --skip-validation          skip dump format and gzip integrity checks
          --trust-dump               alias for --skip-validation
      HELP
      "replace-dump" => <<~HELP,
        Usage: silo-migrate replace-dump CUSTOMER PHASE --yes
        Stops the phase DB container and removes its volume (reset before re-import).
      HELP
      "analyze-dump" => <<~HELP,
        Usage: silo-migrate analyze-dump DUMP_FILE [options]
          --large-threshold MB   highlight tables above this size (default 100)
          --full                 scan the whole dump instead of the first 200MB
      HELP
      "preprocess-dump" => <<~HELP,
        Usage: silo-migrate preprocess-dump DUMP_FILE [options]
          -o, --output FILE   output path (default: *_preprocessed.sql)
          --dry-run           only report what would change
          -f, --force         overwrite an existing output file
      HELP
      "convert-xml" => <<~HELP,
        Usage: silo-migrate convert-xml SOURCE [options]   (alias: xml-to-sql)
          -o, --output FILE          output SQL path (default: alongside source)
          -c, --customer CUSTOMER    write into the customer's dumps directory
          --phase PHASE              initial (default) or final (with --customer)
          -t, --include-tables T1,T2 only convert these tables
          -x, --exclude-tables T1,T2 skip these tables
          -f, --include-files F1,F2  only convert these XML files
          -X, --exclude-files F1,F2  skip these XML files
          -b, --batch-size SIZE      rows per INSERT batch (default 1000)
          --schema-only              emit CREATE TABLE statements only
          --compress                 gzip the output
          --no-scrub-invalid-xml-chars
                                     fail on XML-forbidden control characters
                                     instead of removing them
          --invalid-xml-report FILE   audit summary path for removed controls
      HELP
      "convert-json" => <<~HELP,
        Usage: silo-migrate convert-json SOURCE [options]
          -o, --output FILE          output SQL path (default: alongside source)
          -c, --customer CUSTOMER    write into the customer's dumps directory
          --phase PHASE              initial (default) or final (with --customer)
          -t, --include-tables T1,T2 only convert these tables (a root table
                                     includes its child tables automatically)
          -x, --exclude-tables T1,T2 skip these tables (a root table excludes
                                     its child tables automatically)
          -f, --include-files F1,F2  only convert these JSON files
          -X, --exclude-files F1,F2  skip these JSON files
          -b, --batch-size SIZE      rows per INSERT batch (default 1000)
          --schema-only              emit CREATE TABLE statements only
          --compress                 gzip the output
          --schema-dir DIR           use FILE.schema.json (Draft-07) files from DIR
                                     to drive column types, NULLability, and x-pii
                                     annotations instead of inferring them
          --records-path KEY         top-level key holding the records array
                                     (default: data, with auto-detection fallback)
          --table NAME               root table name override (single-file input)
          --max-depth N              flatten depth before storing raw JSON (default 5)
          --json-columns P1,P2       dotted record paths kept as raw JSON columns
          --no-graphql-unwrap        keep edges/node wrappers as literal structure
          --raw-dates                keep ISO-8601 strings as text, not DATETIME
          --no-meta-table            do not emit the _json_meta PII manifest table
          --recover-truncated        keep the complete records from truncated files
                                     (the partial tail record is discarded; recovered
                                     counts are reported as warnings)

        Nested objects flatten into prefixed columns (avatar.url -> avatar_url);
        arrays become child tables with _sid/_parent_sid/_parent_id/_ordinal keys.
      HELP
      "stage-dump" => <<~HELP,
        Usage: silo-migrate stage-dump CUSTOMER PHASE SOURCE [--sql-file FILE]
        Copies a .sql/.sql.gz dump (or extracts one from a tar archive) into the
        project's dumps/PHASE directory. --sql-file selects a file inside a tar.
      HELP
      "setup-converter" => <<~HELP,
        Usage: silo-migrate setup-converter CUSTOMER [options]
          --repo REPO          converter repository (default: discourse-converters via SSH)
          --branch BRANCH      branch to clone (default: main)
          --start              build and start the converter container
          --bundle-install     also run bundle install inside the container
          --allow-ssh-prompt   allow an interactive SSH passphrase prompt
      HELP
      "add-final-db" => <<~HELP,
        Usage: silo-migrate add-final-db CUSTOMER [options]
          --db-type TYPE   mariadb, mysql, or postgres (default: same as initial)
          --port PORT      host port (default: initial port + 1)
          --db-name NAME   database name
          --password PW    database password
      HELP
      "run-converter" => <<~HELP,
        Usage: silo-migrate run-converter CUSTOMER PLATFORM [options]
               silo-migrate run-converter CUSTOMER [options] -- COMMAND...
          --settings PATH      converter settings file (default: generated with the
                               migration DB container host/credentials and mounted
                               at /converter-settings inside the container)
          --no-reset           omit --reset from the platform shortcut
          --redacted-logs      write redacted log + summary artifacts afterwards
          --redacted-summary   alias for --redacted-logs

        Examples:
          silo-migrate run-converter acme vbulletin
          silo-migrate run-converter acme -- ./convert --from vbulletin --settings /converter-settings/vbulletin.yml
      HELP
      "converter" => <<~HELP,
        Usage: silo-migrate converter summary CUSTOMER
        Generates redacted converter log/summary artifacts from output/intermediate.db
        without re-running the converter.
      HELP
      "discourse" => <<~HELP,
        Usage: silo-migrate discourse install-launcher [options]
               silo-migrate discourse setup CUSTOMER [options]
               silo-migrate discourse rebuild CUSTOMER [--role uploads|import|both]
               silo-migrate discourse start CUSTOMER [--role uploads|import|both]
               silo-migrate discourse stop CUSTOMER [--role uploads|import|both]
               silo-migrate discourse status CUSTOMER [--role uploads|import|both]
               silo-migrate discourse prepare-deps CUSTOMER [--role uploads|import|both]
               silo-migrate discourse run-uploads CUSTOMER
               silo-migrate discourse restore-import CUSTOMER --backup PATH
               silo-migrate discourse import CUSTOMER [--no-uploads-db]
               silo-migrate discourse backup-import CUSTOMER

        import uses output/intermediate.db. If output/uploads.sqlite3 exists it is
        passed to generic_bulk.rb too; --no-uploads-db skips it explicitly.

        setup writes two discourse_docker container YAML files:
          <customer>-uploads on 127.0.0.1:8080
          <customer>-import  on 127.0.0.1:8081

        install-launcher clones the discourse_docker launcher checkout on Linux.
        It does not run Discourse's interactive public-site setup wizard.

        Options for install-launcher:
          --docker-path PATH          discourse_docker checkout (default /var/discourse)
          --branch BRANCH            discourse_docker branch (default main)
          --repo REPO                discourse_docker repository

        Options for setup:
          --docker-path PATH          discourse_docker checkout (default /var/discourse)
          --uploads-port PORT         uploads instance host port (default 8080)
          --import-port PORT          import instance host port (default 8081)
          --guest-root PATH           mount root inside both containers (default /migrations/CUSTOMER)
          --developer-emails EMAILS   Discourse developer emails
          --uploads-hostname HOST     hostname for uploads instance
          --import-hostname HOST      hostname for import instance
          --workers N                 Unicorn workers
          --db-pool N                 Rails DB pool
          --shared-buffers VALUE      Postgres shared buffers
          --max-connections N         Postgres max connections
      HELP
      "schema" => <<~HELP,
        Usage: silo-migrate schema export CUSTOMER [--phase PHASE] [-o DIR]
               silo-migrate schema bundle CUSTOMER [--phase PHASE] [-o DIR]
        export writes raw schema SQL; bundle writes the AI-safe metadata bundle
        (schema.sql, tables/columns/indexes JSON, summary, migration notes).
      HELP
      "findings" => <<~HELP,
        Usage: silo-migrate findings generate CUSTOMER [--from FILE]
        Generates structured findings from the latest (or given) redacted summary.
      HELP
      "fixtures" => <<~HELP,
        Usage: silo-migrate fixtures generate CUSTOMER [--from FILE_OR_DIR]
        Generates shape-only synthetic fixtures from safe findings.
      HELP
      "ai" => <<~HELP,
        Usage: silo-migrate ai prepare CUSTOMER
               silo-migrate ai refresh CUSTOMER
        Writes/refreshes the locally git-ignored safe-artifacts/ directory inside
        the project's discourse-converters clone (schema bundles, redacted logs,
        safe findings, synthetic fixtures) plus agent instruction files.
        Never raw data or credentials; never touches converter code - the Dev AI
        works directly in the clone and commits/pushes normally. Redacted-log,
        findings, and fixture generation auto-refresh safe-artifacts afterwards.
      HELP
      "trusted" => <<~HELP,
        Usage: silo-migrate trusted inspect CUSTOMER [--phase PHASE] [--reason TEXT] [--as-finding] [--message TEXT] -- COMMAND...
               silo-migrate trusted review CUSTOMER FINDING [--decision safe|rejected] [--reviewer NAME] [--notes TEXT]
               silo-migrate trusted redact CUSTOMER FINDING [--reviewer NAME] [--notes TEXT]
               silo-migrate trusted session CUSTOMER [--provider bedrock] [--runtime silo] [--reason TEXT] [--session-id ID]

        Example inspection:
          silo-migrate trusted inspect acme --phase initial --reason "check edge case" -- \\
            mysql -u root -e "SELECT COUNT(*) FROM users"

        --as-finding also writes a trusted_only finding stub (no raw output embedded)
        so the conclusion can later flow to the safe zone via:
          silo-migrate trusted redact acme trusted/findings/finding-inspect-....yml --notes "safe summary"
      HELP
      "doctor" => <<~HELP,
        Usage: silo-migrate doctor
        Checks Ruby/Bundler/gems, the Docker daemon, Compose v2, git, and the
        configured base path; exits non-zero when a required check fails.
      HELP
      "self-update" => <<~HELP,
        Usage: silo-migrate self-update
        Pulls the managed Git checkout, runs bundle install, and refreshes the
        global shims for silo-migrate, migration-tool, and xml-to-sql.
        Skips Docker host package and service management; run script/install
        --install-deps directly when you want Docker setup handled.
      HELP
      "uninstall" => <<~HELP
        Usage: silo-migrate uninstall
        Removes global shims, the installer-managed PATH block, and the managed
        checkout. Does not remove migration projects, Docker volumes, Ruby gems,
        Homebrew, Docker, or OS packages.
      HELP
    }.freeze

    def initialize(runtime: Runtime::Docker.new, env: ENV, output: $stdout, error: $stderr)
      @runtime = runtime
      @env = env
      @output = output
      @error = error
      @project_service = Services::ProjectService.new(runtime: runtime, env: env, output: output)
      @import_service = Services::ImportService.new(runtime: runtime, env: env, output: output)
      @schema_service = Services::SchemaService.new(runtime: runtime, env: env, output: output)
      @findings_service = Services::ConverterFindingsService.new(env: env, output: output)
      @fixture_service = Services::SyntheticFixtureService.new(env: env, output: output)
      @ai_workspace_service = Services::AIWorkspaceService.new(env: env, output: output)
      @trusted_service = Services::TrustedWorkflowService.new(runtime: runtime, env: env, output: output)
      @discourse_service = Services::DiscourseService.new(runtime: runtime, env: env, output: output)
    end

    def run(argv)
      argv = argv.dup
      return run_interactive(nil) if argv.empty?
      return help(0) if argv.first == "--help" || argv.first == "-h"
      return version if argv.first == "--version" || argv.first == "-v"
      return run_interactive(argv.first) if argv.length == 1 && !COMMANDS.include?(argv.first)

      command = argv.shift
      return command_help(command) if argv.first == "--help" || argv.first == "-h"

      case command
      when "interactive", "go" then run_interactive(argv.shift)
      when "init" then init(argv)
      when "list" then @project_service.list
      when "status" then status(argv)
      when "cleanup" then cleanup(argv)
      when "start" then start(argv)
      when "stop" then stop(argv)
      when "regenerate" then regenerate(argv)
      when "import-dump" then import_dump(argv)
      when "replace-dump" then replace_dump(argv)
      when "analyze-dump" then analyze_dump(argv)
      when "preprocess-dump" then preprocess_dump(argv)
      when "convert-xml" then convert_xml(argv)
      when "convert-json" then convert_json(argv)
      when "stage-dump" then stage_dump(argv)
      when "setup-converter" then setup_converter(argv)
      when "add-final-db" then add_final_db(argv)
      when "run-converter" then run_converter(argv)
      when "converter" then converter(argv)
      when "discourse" then discourse(argv)
      when "schema" then schema(argv)
      when "findings" then findings(argv)
      when "fixtures" then fixtures(argv)
      when "ai" then ai(argv)
      when "trusted" then trusted(argv)
      when "doctor" then return doctor
      when "self-update" then return self_update
      when "uninstall" then return uninstall
      when "help", nil then return argv.empty? ? help(0) : command_help(argv.shift)
      else
        raise UsageError, "Unknown command: #{command}"
      end
      0
    rescue UsageError, OptionParser::ParseError => e
      @error.puts "Error: #{e.message}"
      1
    end

    private

    def version
      @output.puts "silo-migrate #{VERSION}"
      0
    end

    def help(code = 0)
      @output.puts <<~HELP
        Usage: silo-migrate [command] [options]

        Shortcuts:
          silo-migrate                 Start guided interactive mode
          silo-migrate <customer>      Start guided mode for a customer
          silo-migrate help <command>  Show a command's flags and examples
          (compat aliases: migration-tool = silo-migrate, xml-to-sql = convert-xml)

        Commands:
          interactive [customer]       Guided workflow (alias: go)
          doctor                       Check Ruby, Docker, git, and base path setup
          self-update                  Pull updates and refresh global shims
          uninstall                    Remove global shims and managed checkout
          init CUSTOMER                Initialize a migration project
          list                         List migration projects
          status CUSTOMER              Show project and container status
          cleanup CUSTOMER             Remove a project (--force deletes even if Docker fails)
          start CUSTOMER               Start Docker Compose services (--wait checks DB health)
          stop CUSTOMER                Stop Docker Compose services
          regenerate CUSTOMER          Regenerate docker-compose.yml
          import-dump CUSTOMER PHASE   Import SQL dump into a database
          replace-dump CUSTOMER PHASE  Reset database container data
          analyze-dump DUMP_FILE       Analyze SQL dump tables and source type
          preprocess-dump DUMP_FILE    Fix generated-column INSERT values
          convert-xml SOURCE           Convert mysqldump XML to SQL
          convert-json SOURCE          Convert JSON exports to SQL (generic shredding)
          stage-dump CUSTOMER PHASE SRC Copy/extract a dump into a project
          setup-converter CUSTOMER     Clone/setup discourse-converters (--bundle-install also builds/starts)
                                     Use --allow-ssh-prompt for passphrase-protected SSH keys
          add-final-db CUSTOMER        Add final database configuration
          run-converter CUSTOMER [TYPE] Run converter TYPE shortcut or container command after --
          converter summary CUSTOMER   Generate redacted converter summary from existing output
          discourse setup CUSTOMER     Configure two discourse_docker handoff containers
          discourse import CUSTOMER    Run final generic_bulk import in the import container
          schema export CUSTOMER       Export source/final DB schema
          schema bundle CUSTOMER       Export AI-safe schema metadata bundle
          findings generate CUSTOMER   Generate structured findings from a redacted summary
          fixtures generate CUSTOMER   Generate shape-only synthetic fixtures from findings
          ai prepare CUSTOMER          Write safe-artifacts/ into the converter clone
          ai refresh CUSTOMER          Refresh safe-artifacts/ (never touches converter code)
          trusted inspect CUSTOMER     Run audited trusted-only inspection command after --
          trusted review CUSTOMER FILE Approve/reject a restricted finding
          trusted redact CUSTOMER FILE Write a safe redacted derivative
          trusted session CUSTOMER     Launch a Linux/Silo Bedrock trusted data AI session

        Run 'silo-migrate help <command>' (or '<command> --help') for flags and examples.
      HELP
      code
    end

    def command_help(command)
      entry = COMMAND_HELP[command]
      if entry
        @output.puts entry
        0
      else
        help(0)
      end
    end

    def doctor
      Services::DoctorService.new(runtime: @runtime, env: @env, output: @output).run ? 0 : 1
    end

    def self_update
      Services::InstallService.new(runtime: @runtime, env: @env, output: @output).self_update
      0
    end

    def uninstall
      Services::InstallService.new(runtime: @runtime, env: @env, output: @output).uninstall
      0
    end

    def converter(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      raise UsageError, "Unknown converter command: #{subcommand}. Did you mean 'converter summary'?" unless subcommand == "summary"

      @project_service.generate_converter_summary(required_arg(argv, "CUSTOMER"))
    end

    def discourse(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      case subcommand
      when "install-launcher" then discourse_install_launcher(argv)
      when "setup" then discourse_setup(argv)
      when "rebuild" then discourse_role_command(argv) { |customer, role| @discourse_service.rebuild(customer, role: role) }
      when "start" then discourse_role_command(argv) { |customer, role| @discourse_service.start(customer, role: role) }
      when "stop" then discourse_role_command(argv) { |customer, role| @discourse_service.stop(customer, role: role) }
      when "status" then discourse_role_command(argv) { |customer, role| @discourse_service.status(customer, role: role) }
      when "prepare-deps" then discourse_role_command(argv) { |customer, role| @discourse_service.prepare_deps(customer, role: role) }
      when "run-uploads"
        @discourse_service.run_uploads(required_arg(argv, "CUSTOMER"))
      when "restore-import"
        options = {}
        OptionParser.new { |opts| opts.on("--backup PATH") { |value| options[:backup] = value } }.parse!(argv)
        raise UsageError, "Missing required option: --backup PATH" if options[:backup].to_s.empty?

        @discourse_service.restore_import(required_arg(argv, "CUSTOMER"), backup: options[:backup])
      when "import"
        options = { no_uploads_db: false }
        OptionParser.new { |opts| opts.on("--no-uploads-db") { options[:no_uploads_db] = true } }.parse!(argv)
        @discourse_service.import(required_arg(argv, "CUSTOMER"), **options)
      when "backup-import"
        @discourse_service.backup_import(required_arg(argv, "CUSTOMER"))
      else
        raise UsageError, "Unknown discourse command: #{subcommand}"
      end
    end

    def discourse_install_launcher(argv)
      options = {
        docker_path: Services::DiscourseService::DEFAULT_DOCKER_PATH,
        branch: "main",
        repo: Services::DiscourseService::DEFAULT_DOCKER_REPO
      }
      OptionParser.new do |opts|
        opts.on("--docker-path PATH") { |value| options[:docker_path] = value }
        opts.on("--branch BRANCH") { |value| options[:branch] = value }
        opts.on("--repo REPO") { |value| options[:repo] = value }
      end.parse!(argv)
      @discourse_service.install_launcher(**options)
    end

    def discourse_setup(argv)
      options = {}
      OptionParser.new do |opts|
        opts.on("--docker-path PATH") { |value| options[:docker_path] = value }
        opts.on("--uploads-port PORT", Integer) { |value| options[:uploads_port] = value }
        opts.on("--import-port PORT", Integer) { |value| options[:import_port] = value }
        opts.on("--guest-root PATH") { |value| options[:import_guest_root] = value }
        opts.on("--developer-emails EMAILS") { |value| options[:developer_emails] = value }
        opts.on("--uploads-hostname HOST") { |value| options[:uploads_hostname] = value }
        opts.on("--import-hostname HOST") { |value| options[:import_hostname] = value }
        opts.on("--workers N", Integer) { |value| options[:workers] = value }
        opts.on("--db-pool N", Integer) { |value| options[:db_pool] = value }
        opts.on("--shared-buffers VALUE") { |value| options[:db_shared_buffers] = value }
        opts.on("--max-connections N", Integer) { |value| options[:db_max_connections] = value }
      end.parse!(argv)
      @discourse_service.setup(required_arg(argv, "CUSTOMER"), options)
    end

    def discourse_role_command(argv)
      options = { role: "both" }
      OptionParser.new do |opts|
        opts.on("--role ROLE") { |value| options[:role] = validate_discourse_role(value) }
      end.parse!(argv)
      yield required_arg(argv, "CUSTOMER"), options[:role]
    end

    def run_interactive(customer)
      Interactive.new(
        project_service: @project_service,
        import_service: @import_service,
        schema_service: @schema_service,
        findings_service: @findings_service,
        fixture_service: @fixture_service,
        discourse_service: @discourse_service,
        output: @output
      ).run(customer)
      0
    end

    def init(argv)
      options = {}
      parser = OptionParser.new do |opts|
        opts.on("--db-type TYPE") { |value| options[:db_type] = validate_db_type(value) }
        opts.on("--initial-port PORT", Integer) { |value| options[:initial_port] = value }
        opts.on("--db-name NAME") { |value| options[:db_name] = value }
        opts.on("--password PASSWORD") { |value| options[:password] = value }
        opts.on("--final-db-type TYPE") { |value| options[:final_db_type] = validate_db_type(value) }
        opts.on("--final-port PORT", Integer) { |value| options[:final_port] = value }
      end
      parser.parse!(argv)
      customer = required_arg(argv, "CUSTOMER")
      @project_service.init(customer, options)
    end

    def start(argv)
      options = { profile: "all", build: false, force: false, wait_for_health: false, health_timeout: 60 }
      OptionParser.new do |opts|
        opts.on("--profile PROFILE") { |value| options[:profile] = validate_profile(value) }
        opts.on("--build") { options[:build] = true }
        opts.on("--force") { options[:force] = true }
        opts.on("--wait") { options[:wait_for_health] = true }
        opts.on("--health-timeout SECONDS", Integer) { |value| options[:health_timeout] = value }
      end.parse!(argv)
      @project_service.start(required_arg(argv, "CUSTOMER"), **options)
    end

    def stop(argv)
      options = { profile: "all", remove: false }
      OptionParser.new do |opts|
        opts.on("--profile PROFILE") { |value| options[:profile] = validate_profile(value) }
        opts.on("--remove") { options[:remove] = true }
      end.parse!(argv)
      @project_service.stop(required_arg(argv, "CUSTOMER"), **options)
    end

    def status(argv)
      @project_service.status(required_arg(argv, "CUSTOMER"))
    end

    def regenerate(argv)
      @project_service.regenerate(required_arg(argv, "CUSTOMER"))
    end

    def cleanup(argv)
      options = { yes: false, force: false }
      OptionParser.new do |opts|
        opts.on("-y", "--yes") { options[:yes] = true }
        opts.on("--force") { options[:force] = true }
      end.parse!(argv)
      @project_service.cleanup(required_arg(argv, "CUSTOMER"), **options)
    end

    def add_final_db(argv)
      options = {}
      OptionParser.new do |opts|
        opts.on("--db-type TYPE") { |value| options[:db_type] = validate_db_type(value) }
        opts.on("--port PORT", Integer) { |value| options[:port] = value }
        opts.on("--db-name NAME") { |value| options[:db_name] = value }
        opts.on("--password PASSWORD") { |value| options[:password] = value }
      end.parse!(argv)
      @project_service.add_final_db(required_arg(argv, "CUSTOMER"), options)
    end

    def setup_converter(argv)
      options = {
        repo: Services::ProjectService::DEFAULT_CONVERTER_REPO,
        branch: "main",
        start: false,
        bundle_install: false,
        allow_ssh_prompt: false
      }
      OptionParser.new do |opts|
        opts.on("--repo REPO") { |value| options[:repo] = value }
        opts.on("--branch BRANCH") { |value| options[:branch] = value }
        opts.on("--start") { options[:start] = true }
        opts.on("--bundle-install") { options[:bundle_install] = true }
        opts.on("--allow-ssh-prompt") { options[:allow_ssh_prompt] = true }
      end.parse!(argv)
      @project_service.setup_converter(required_arg(argv, "CUSTOMER"), **options)
    end

    def import_dump(argv)
      options = { max_packet: "512M" }
      OptionParser.new do |opts|
        opts.on("-f", "--file FILE") { |value| options[:file] = value }
        opts.on("-x", "--exclude-tables TABLES") { |value| options[:exclude_tables] = value }
        opts.on("--skip-validation") { options[:skip_validation] = true }
        opts.on("--trust-dump") { options[:trust_dump] = true }
        opts.on("--max-packet VALUE") { |value| options[:max_packet] = value }
        opts.on("--fast") { options[:fast] = true }
        opts.on("--turbo") { options[:turbo] = true }
        opts.on("--fix-collations") { options[:fix_collations] = true }
        opts.on("--no-fix-collations") { options[:fix_collations] = false }
        opts.on("--health-timeout SECONDS", Integer) { |value| options[:health_timeout] = value }
        opts.on("--skip-health-wait") { options[:skip_health_wait] = true }
      end.parse!(argv)
      customer = required_arg(argv, "CUSTOMER")
      phase = validate_phase(required_arg(argv, "PHASE"))
      @import_service.import_dump(customer, phase, options)
    end

    def replace_dump(argv)
      options = { yes: false }
      OptionParser.new { |opts| opts.on("-y", "--yes") { options[:yes] = true } }.parse!(argv)
      customer = required_arg(argv, "CUSTOMER")
      phase = validate_phase(required_arg(argv, "PHASE"))
      @import_service.replace_dump(customer, phase, **options)
    end

    def analyze_dump(argv)
      options = { large_threshold: 100, full: false }
      OptionParser.new do |opts|
        opts.on("--large-threshold MB", Integer) { |value| options[:large_threshold] = value }
        opts.on("--full") { options[:full] = true }
      end.parse!(argv)
      path = required_existing_path(required_arg(argv, "DUMP_FILE"))
      @output.puts "\nAnalyzing: #{File.basename(path)}"
      @output.puts "File size: #{DumpTools.format_size(File.size(path))}"
      if DumpTools.gzip_file?(path)
        verification = DumpTools.verify_gzip(path)
        @output.puts "[WARN] gzip quick check failed: #{verification[:message]}" unless verification[:valid]
      end
      detection = SQLTools.detect_dump_type(path)
      @output.puts "Detected type:    #{detection[:detected]}" if detection[:detected]
      @output.puts "Recommended:      #{DATABASE_TYPES.dig(detection[:recommended], :display_name) || detection[:recommended]}" if detection[:recommended]
      analysis = SQLTools.analyze_sql_dump(path, sample_bytes: options[:full] ? nil : 200 * 1024 * 1024)
      @output.puts "Tables found:             #{analysis[:total_tables]}"
      analysis[:tables].sort_by { |_, info| -info[:size] }.first(30).each do |table, info|
        @output.puts format("%-40s %12s %15s", table, DumpTools.format_size(info[:size]), info[:rows])
      end
    end

    def preprocess_dump(argv)
      options = { dry_run: false, force: false }
      OptionParser.new do |opts|
        opts.on("-o", "--output FILE") { |value| options[:output] = value }
        opts.on("--dry-run") { options[:dry_run] = true }
        opts.on("-f", "--force") { options[:force] = true }
      end.parse!(argv)
      path = required_existing_path(required_arg(argv, "DUMP_FILE"))
      info = SQLTools.detect_generated_columns(path, validate_inserts: true)
      unless info[:has_generated_columns]
        @output.puts "[OK] No generated columns found in this dump."
        return
      end
      if options[:dry_run]
        @output.puts "DRY RUN - No changes made"
        return
      end
      output = options[:output] || default_preprocess_output(path)
      raise UsageError, "Output file exists: #{output}" if File.exist?(output) && !options[:force]

      result = SQLTools.preprocess_mysql_dump(path, output, info)
      raise UsageError, result[:error] unless result[:success]

      @output.puts "[OK] Dump preprocessed successfully!"
      @output.puts "Output file: #{output}"
    end

    def convert_xml(argv)
      options = { phase: "initial", batch_size: 1000, schema_only: false, compress: false, scrub_invalid_xml_chars: true }
      OptionParser.new do |opts|
        opts.on("-o", "--output FILE") { |value| options[:output] = value }
        opts.on("-c", "--customer CUSTOMER") { |value| options[:customer] = value }
        opts.on("--phase PHASE") { |value| options[:phase] = validate_phase(value) }
        opts.on("-t", "--include-tables TABLES") { |value| options[:include_tables] = csv(value) }
        opts.on("-x", "--exclude-tables TABLES") { |value| options[:exclude_tables] = csv(value) }
        opts.on("-f", "--include-files FILES") { |value| options[:include_files] = csv(value) }
        opts.on("-X", "--exclude-files FILES") { |value| options[:exclude_files] = csv(value) }
        opts.on("-b", "--batch-size SIZE", Integer) { |value| options[:batch_size] = value }
        opts.on("--schema-only") { options[:schema_only] = true }
        opts.on("--compress") { options[:compress] = true }
        opts.on("--no-scrub-invalid-xml-chars") { options[:scrub_invalid_xml_chars] = false }
        opts.on("--invalid-xml-report FILE") { |value| options[:invalid_xml_report_path] = value }
      end.parse!(argv)
      source = Pathname(required_existing_path(required_arg(argv, "SOURCE")))
      output = converted_output_path(source, options, input_ext: ".xml")
      XMLToSQLConverter.new(
        batch_size: options[:batch_size],
        include_tables: options[:include_tables],
        exclude_tables: options[:exclude_tables],
        include_files: options[:include_files],
        exclude_files: options[:exclude_files],
        schema_only: options[:schema_only],
        scrub_invalid_xml_chars: options[:scrub_invalid_xml_chars],
        invalid_xml_report_path: options[:invalid_xml_report_path] || default_invalid_xml_report_path(output, project_style: !!options[:customer]),
        verbose: true
      ).convert(source, output)
      @output.puts "\nTo import this dump, run:\n  silo-migrate import-dump #{options[:customer]} #{options[:phase]}" if options[:customer]
    end

    def convert_json(argv)
      options = { phase: "initial", batch_size: 1000, schema_only: false, compress: false, max_depth: JSONToSQLConverter::DEFAULT_MAX_DEPTH, graphql_unwrap: true, raw_dates: false, meta_table: true }
      OptionParser.new do |opts|
        opts.on("-o", "--output FILE") { |value| options[:output] = value }
        opts.on("-c", "--customer CUSTOMER") { |value| options[:customer] = value }
        opts.on("--phase PHASE") { |value| options[:phase] = validate_phase(value) }
        opts.on("-t", "--include-tables TABLES") { |value| options[:include_tables] = csv(value) }
        opts.on("-x", "--exclude-tables TABLES") { |value| options[:exclude_tables] = csv(value) }
        opts.on("-f", "--include-files FILES") { |value| options[:include_files] = csv(value) }
        opts.on("-X", "--exclude-files FILES") { |value| options[:exclude_files] = csv(value) }
        opts.on("-b", "--batch-size SIZE", Integer) { |value| options[:batch_size] = value }
        opts.on("--schema-only") { options[:schema_only] = true }
        opts.on("--compress") { options[:compress] = true }
        opts.on("--schema-dir DIR") { |value| options[:schema_dir] = value }
        opts.on("--records-path KEY") { |value| options[:records_path] = value }
        opts.on("--table NAME") { |value| options[:table_name] = value }
        opts.on("--max-depth N", Integer) { |value| options[:max_depth] = value }
        opts.on("--json-columns PATHS") { |value| options[:json_columns] = csv(value) }
        opts.on("--no-graphql-unwrap") { options[:graphql_unwrap] = false }
        opts.on("--raw-dates") { options[:raw_dates] = true }
        opts.on("--no-meta-table") { options[:meta_table] = false }
        opts.on("--recover-truncated") { options[:recover_truncated] = true }
      end.parse!(argv)
      source = Pathname(required_existing_path(required_arg(argv, "SOURCE")))
      output = converted_output_path(source, options, input_ext: ".json")
      JSONToSQLConverter.new(
        batch_size: options[:batch_size],
        include_tables: options[:include_tables],
        exclude_tables: options[:exclude_tables],
        include_files: options[:include_files],
        exclude_files: options[:exclude_files],
        schema_only: options[:schema_only],
        schema_dir: options[:schema_dir],
        records_path: options[:records_path],
        table_name: options[:table_name],
        max_depth: options[:max_depth],
        json_columns: options[:json_columns],
        graphql_unwrap: options[:graphql_unwrap],
        raw_dates: options[:raw_dates],
        meta_table: options[:meta_table],
        recover_truncated: options.fetch(:recover_truncated, false),
        verbose: true
      ).convert(source, output)
      @output.puts "\nTo import this dump, run:\n  silo-migrate import-dump #{options[:customer]} #{options[:phase]}" if options[:customer]
    end

    def stage_dump(argv)
      options = {}
      OptionParser.new do |opts|
        opts.on("--sql-file FILE") { |value| options[:sql_filename] = value }
      end.parse!(argv)
      customer = required_arg(argv, "CUSTOMER")
      phase = validate_phase(required_arg(argv, "PHASE"))
      source = required_existing_path(required_arg(argv, "SOURCE"))
      @project_service.stage_dump(customer, phase, source, **options)
    end

    def run_converter(argv)
      options = { redacted_logs: false, reset: true }
      customer = required_arg(argv, "CUSTOMER")
      parser = OptionParser.new do |opts|
        opts.on("--redacted-logs") { options[:redacted_logs] = true }
        opts.on("--redacted-summary") { options[:redacted_logs] = true }
        opts.on("--no-reset") { options[:reset] = false }
        opts.on("--settings PATH") { |value| options[:settings] = value }
      end

      separator_index = argv.index("--")
      if separator_index
        option_argv = argv[0...separator_index]
        command = argv[(separator_index + 1)..] || []
        parser.parse!(option_argv)
        @project_service.run_converter(customer, command: command, redacted_logs: options[:redacted_logs])
        return
      end

      parser.parse!(argv)
      case argv.length
      when 0
        @project_service.run_converter(customer, command: [], redacted_logs: options[:redacted_logs])
      when 1
        @project_service.run_converter_platform(
          customer,
          argv.first,
          reset: options[:reset],
          settings: options[:settings],
          redacted_logs: options[:redacted_logs]
        )
      else
        raise UsageError, "Custom converter commands must be passed after '--', for example: silo-migrate run-converter #{customer} -- #{argv.join(' ')}"
      end
    end

    def schema(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      raise UsageError, "Unknown schema command: #{subcommand}" unless %w[export bundle].include?(subcommand)

      options = { phase: "initial" }
      OptionParser.new do |opts|
        opts.on("--phase PHASE") { |value| options[:phase] = validate_phase(value) }
        opts.on("-o", "--output DIR") { |value| options[:output_dir] = value }
      end.parse!(argv)
      customer = required_arg(argv, "CUSTOMER")
      if subcommand == "bundle"
        @schema_service.bundle(customer, **options)
      else
        @project_service.export_schema(customer, **options)
      end
    end

    def findings(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      raise UsageError, "Unknown findings command: #{subcommand}" unless subcommand == "generate"

      options = {}
      OptionParser.new do |opts|
        opts.on("--from FILE") { |value| options[:from] = value }
      end.parse!(argv)
      artifacts = @findings_service.generate(required_arg(argv, "CUSTOMER"), **options)
      @output.puts "[OK] Findings index: #{artifacts.fetch(:index_path)}"
      artifacts.fetch(:findings).each { |path| @output.puts "[OK] Finding: #{path}" }
    end

    def fixtures(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      raise UsageError, "Unknown fixtures command: #{subcommand}" unless subcommand == "generate"

      options = {}
      OptionParser.new do |opts|
        opts.on("--from FILE_OR_DIR") { |value| options[:from] = value }
      end.parse!(argv)
      artifacts = @fixture_service.generate(required_arg(argv, "CUSTOMER"), **options)
      artifacts.fetch(:fixtures).each { |path| @output.puts "[OK] Synthetic fixture: #{path}" }
      @output.puts "[WARN] No synthetic fixtures were generated." if artifacts.fetch(:fixtures).empty?
    end

    def ai(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      raise UsageError, "Unknown ai command: #{subcommand}" unless %w[prepare refresh].include?(subcommand)

      @ai_workspace_service.prepare(required_arg(argv, "CUSTOMER"))
    end

    def trusted(argv)
      subcommand = required_arg(argv, "SUBCOMMAND")
      case subcommand
      when "inspect" then trusted_inspect(argv)
      when "review" then trusted_review(argv)
      when "redact" then trusted_redact(argv)
      when "session" then trusted_session(argv)
      else
        raise UsageError, "Unknown trusted command: #{subcommand}"
      end
    end

    def trusted_inspect(argv)
      customer = required_arg(argv, "CUSTOMER")
      options = { phase: "initial", as_finding: false }
      parser = OptionParser.new do |opts|
        opts.on("--phase PHASE") { |value| options[:phase] = validate_phase(value) }
        opts.on("--reason TEXT") { |value| options[:reason] = value }
        opts.on("--as-finding") { options[:as_finding] = true }
        opts.on("--message TEXT") { |value| options[:message] = value }
      end
      separator_index = argv.index("--")
      raise UsageError, "Trusted inspection command must be passed after '--'." unless separator_index

      parser.parse!(argv[0...separator_index])
      command = argv[(separator_index + 1)..] || []
      @trusted_service.inspect(
        customer,
        phase: options[:phase],
        reason: options[:reason],
        command: command,
        as_finding: options[:as_finding],
        message: options[:message]
      )
    end

    def trusted_review(argv)
      customer = required_arg(argv, "CUSTOMER")
      finding = required_existing_path(required_arg(argv, "FINDING"))
      options = { decision: "safe" }
      OptionParser.new do |opts|
        opts.on("--decision DECISION") { |value| options[:decision] = value }
        opts.on("--reviewer NAME") { |value| options[:reviewer] = value }
        opts.on("--notes TEXT") { |value| options[:notes] = value }
      end.parse!(argv)
      @trusted_service.review(customer, finding, **options)
    end

    def trusted_redact(argv)
      customer = required_arg(argv, "CUSTOMER")
      finding = required_existing_path(required_arg(argv, "FINDING"))
      options = {}
      OptionParser.new do |opts|
        opts.on("--reviewer NAME") { |value| options[:reviewer] = value }
        opts.on("--notes TEXT") { |value| options[:notes] = value }
      end.parse!(argv)
      @trusted_service.redact(customer, finding, **options)
    end

    def trusted_session(argv)
      customer = required_arg(argv, "CUSTOMER")
      options = { provider: "bedrock", runtime: "silo" }
      OptionParser.new do |opts|
        opts.on("--provider PROVIDER") { |value| options[:provider] = value }
        opts.on("--runtime RUNTIME") { |value| options[:runtime] = value }
        opts.on("--reason TEXT") { |value| options[:reason] = value }
        opts.on("--session-id ID") { |value| options[:session_id] = value }
      end.parse!(argv)
      @trusted_service.session(customer, **options)
    end

    def required_arg(argv, name)
      value = argv.shift
      raise UsageError, "Missing required argument: #{name}" if value.nil? || value.empty?

      value
    end

    def required_existing_path(path)
      raise UsageError, "Path not found: #{path}" unless File.exist?(path)

      path
    end

    def validate_db_type(value)
      raise UsageError, "Invalid database type: #{value}" unless DATABASE_TYPES.key?(value)

      value
    end

    def validate_profile(value)
      raise UsageError, "Invalid profile: #{value}" unless %w[initial-db final-db converter all].include?(value)

      value
    end

    def validate_discourse_role(value)
      raise UsageError, "Invalid Discourse role: #{value}" unless %w[uploads import both].include?(value)

      value
    end

    def validate_phase(value)
      raise UsageError, "Invalid phase: #{value}" unless %w[initial final].include?(value)

      value
    end

    def csv(value)
      value.split(",").map(&:strip).reject(&:empty?)
    end

    def default_preprocess_output(path)
      return path.sub(/\.sql\.gz\z/, "_preprocessed.sql.gz") if path.end_with?(".sql.gz")
      return path.sub(/\.sql\z/, "_preprocessed.sql") if path.end_with?(".sql")

      "#{path}_preprocessed"
    end

    def converted_output_path(source, options, input_ext:)
      if options[:customer]
        dumps_dir = File.join(Project.project_path(options[:customer], @env), "dumps", options[:phase])
        raise UsageError, "Customer dumps directory not found: #{dumps_dir}\nRun 'silo-migrate init #{options[:customer]}' first to set up the project." unless Dir.exist?(dumps_dir)

        base = source.file? ? source.basename.to_s.sub(/\.gz\z/, "").sub(/#{Regexp.escape(input_ext)}\z/, "") : "combined"
        return Pathname(File.join(dumps_dir, "#{base}.sql#{options[:compress] ? '.gz' : ''}"))
      end

      path = if options[:output]
               Pathname(options[:output])
             elsif source.file?
               source.dirname.join("#{source.basename.to_s.sub(/\.gz\z/, '').sub(/#{Regexp.escape(input_ext)}\z/, '')}.sql")
             else
               source.join("combined.sql")
             end
      options[:compress] && path.extname != ".gz" ? Pathname("#{path}.gz") : path
    end

    def default_invalid_xml_report_path(output, project_style:)
      return nil unless project_style

      output.dirname.join("xml-invalid-chars-#{Time.now.strftime('%Y%m%d-%H%M%S')}.summary.json")
    end
  end
end
