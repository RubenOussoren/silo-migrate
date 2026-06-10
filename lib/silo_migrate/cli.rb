# frozen_string_literal: true

require "optparse"
require "pathname"
require "set"

module SiloMigrate
  class CLI
    COMMANDS = %w[
      interactive go init list status cleanup start stop regenerate import-dump replace-dump
      analyze-dump preprocess-dump convert-xml stage-dump setup-converter add-final-db
      run-converter schema findings fixtures ai trusted help
    ].freeze

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
    end

    def run(argv)
      argv = argv.dup
      return run_interactive(nil) if argv.empty?
      return help(0) if argv.first == "--help" || argv.first == "-h"
      return version if argv.first == "--version" || argv.first == "-v"
      return run_interactive(argv.first) if argv.length == 1 && !COMMANDS.include?(argv.first)

      command = argv.shift
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
      when "stage-dump" then stage_dump(argv)
      when "setup-converter" then setup_converter(argv)
      when "add-final-db" then add_final_db(argv)
      when "run-converter" then run_converter(argv)
      when "schema" then schema(argv)
      when "findings" then findings(argv)
      when "fixtures" then fixtures(argv)
      when "ai" then ai(argv)
      when "trusted" then trusted(argv)
      when "help", nil then help(0)
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

        Commands:
          interactive [customer]       Guided workflow
          init CUSTOMER                Initialize a migration project
          list                         List migration projects
          status CUSTOMER              Show project and container status
          cleanup CUSTOMER             Remove a project
          start CUSTOMER               Start Docker Compose services (--wait checks DB health)
          stop CUSTOMER                Stop Docker Compose services
          regenerate CUSTOMER          Regenerate docker-compose.yml
          import-dump CUSTOMER PHASE   Import SQL dump into a database
          replace-dump CUSTOMER PHASE  Reset database container data
          analyze-dump DUMP_FILE       Analyze SQL dump tables and source type
          preprocess-dump DUMP_FILE    Fix generated-column INSERT values
          convert-xml SOURCE           Convert mysqldump XML to SQL
          stage-dump CUSTOMER PHASE SRC Copy/extract a dump into a project
          setup-converter CUSTOMER     Clone/setup discourse-converters (--bundle-install also builds/starts)
                                     Use --allow-ssh-prompt for passphrase-protected SSH keys
          add-final-db CUSTOMER        Add final database configuration
          run-converter CUSTOMER [TYPE] Run converter TYPE shortcut or container command after --
          schema export CUSTOMER       Export source/final DB schema
          schema bundle CUSTOMER       Export AI-safe schema metadata bundle
          findings generate CUSTOMER   Generate structured findings from a redacted summary
          fixtures generate CUSTOMER   Generate shape-only synthetic fixtures from findings
          ai prepare CUSTOMER          Generate a safe Normal Dev AI workspace
          ai refresh CUSTOMER          Regenerate the safe Normal Dev AI workspace
          trusted inspect CUSTOMER     Run audited trusted-only inspection command after --
          trusted review CUSTOMER FILE Approve/reject a restricted finding
          trusted redact CUSTOMER FILE Write a safe redacted derivative
          trusted session CUSTOMER     Launch a Linux/Silo Bedrock trusted data AI session
      HELP
      code
    end

    def run_interactive(customer)
      Interactive.new(
        project_service: @project_service,
        import_service: @import_service,
        schema_service: @schema_service,
        findings_service: @findings_service,
        fixture_service: @fixture_service,
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
      options = { phase: "initial", batch_size: 1000, schema_only: false, compress: false }
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
      end.parse!(argv)
      source = Pathname(required_existing_path(required_arg(argv, "SOURCE")))
      output = convert_xml_output_path(source, options)
      XMLToSQLConverter.new(
        batch_size: options[:batch_size],
        include_tables: options[:include_tables],
        exclude_tables: options[:exclude_tables],
        include_files: options[:include_files],
        exclude_files: options[:exclude_files],
        schema_only: options[:schema_only],
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

      options = {}
      OptionParser.new do |opts|
        opts.on("-o", "--output DIR") { |value| options[:output_dir] = value }
      end.parse!(argv)
      @ai_workspace_service.prepare(required_arg(argv, "CUSTOMER"), **options)
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
      options = { phase: "initial" }
      parser = OptionParser.new do |opts|
        opts.on("--phase PHASE") { |value| options[:phase] = validate_phase(value) }
        opts.on("--reason TEXT") { |value| options[:reason] = value }
      end
      separator_index = argv.index("--")
      raise UsageError, "Trusted inspection command must be passed after '--'." unless separator_index

      parser.parse!(argv[0...separator_index])
      command = argv[(separator_index + 1)..] || []
      @trusted_service.inspect(customer, phase: options[:phase], reason: options[:reason], command: command)
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

    def convert_xml_output_path(source, options)
      if options[:customer]
        dumps_dir = File.join(Project.project_path(options[:customer], @env), "dumps", options[:phase])
        raise UsageError, "Customer dumps directory not found: #{dumps_dir}\nRun 'silo-migrate init #{options[:customer]}' first to set up the project." unless Dir.exist?(dumps_dir)

        base = source.file? ? source.basename.to_s.sub(/\.gz\z/, "").sub(/\.xml\z/, "") : "combined"
        return Pathname(File.join(dumps_dir, "#{base}.sql#{options[:compress] ? '.gz' : ''}"))
      end

      path = if options[:output]
               Pathname(options[:output])
             elsif source.file?
               source.dirname.join("#{source.basename.to_s.sub(/\.gz\z/, '').sub(/\.xml\z/, '')}.sql")
             else
               source.join("combined.sql")
             end
      options[:compress] && path.extname != ".gz" ? Pathname("#{path}.gz") : path
    end
  end
end
