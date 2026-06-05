# frozen_string_literal: true

require "pathname"

module SiloMigrate
  class Interactive
    BACK = :__back
    BACK_LABEL = "Back"
    BACK_COMMANDS = %w[b back ..].freeze

    def initialize(project_service:, import_service:, schema_service: nil, findings_service: nil, fixture_service: nil, prompt: nil, output: $stdout)
      @project_service = project_service
      @import_service = import_service
      @schema_service = schema_service
      @findings_service = findings_service
      @fixture_service = fixture_service
      @external_prompt = !prompt.nil?
      @prompt = prompt || default_prompt
      @output = output
    end

    def run(customer = nil)
      selection = choose_or_create_customer(customer)
      return unless selection

      customer, create_requested = selection

      project_path = @project_service.project_path(customer)
      unless File.exist?(File.join(project_path, "config.env"))
        return create_project_and_continue(customer, confirm: !create_requested)
      end

      loop do
        show_project_summary(customer)
        action = select_next_action(customer)
        break if run_action(customer, action) != BACK
      end
    end

    private

    def choose_or_create_customer(customer)
      return [Project.validate_customer_name!(customer), false] if customer

      projects = @project_service.respond_to?(:list_projects) ? @project_service.list_projects : []
      if projects.empty?
        @output.puts "\nNo existing projects found.\n"
        return nil unless confirm?("Create a new project?", default: true)

        return [Project.validate_customer_name!(ask("Customer name")), true]
      end

      choices = projects.to_h { |name| [name, name] }
      choices["Create new project"] = :new
      choices["Quit"] = :quit
      choice = select("Select project", choices)
      return nil if choice == :quit
      return [Project.validate_customer_name!(ask("Customer name")), true] if choice == :new

      [Project.validate_customer_name!(choice), false]
    end

    def create_project_and_continue(customer, confirm: true)
      if confirm
        @output.puts "\nProject '#{customer}' not found." unless @project_service.list_projects.include?(customer)
        return unless confirm?("Create it now?", default: true)
      end

      return if create_project(customer) == BACK

      prompt_dump_flow(customer, "initial")
    end

    def create_project(customer)
      db_type = select("Initial database type", DATABASE_TYPES.keys.to_h { |key| [key, key] }, allow_back: true)
      return BACK if db_type == BACK

      initial_port = ask_optional_integer("Initial port (blank for default)")
      return BACK if initial_port == BACK

      @project_service.init(customer, compact_options(db_type: db_type, initial_port: initial_port))
    end

    def show_project_summary(customer)
      config = Project.load_config(customer, env_for_project)
      path = @project_service.project_path(customer)
      initial_dumps = dump_files(customer, "initial")
      final_dumps = dump_files(customer, "final")

      @output.puts "\n#{'=' * 50}"
      @output.puts "PROJECT: #{customer}"
      @output.puts "=" * 50
      @output.puts "\nLocation: #{path}"
      @output.puts "Initial DB: #{config['INITIAL_DB_TYPE'] || 'not set'} on port #{config['INITIAL_PORT'] || 'not set'}"
      @output.puts "Final DB: #{config['FINAL_DB_TYPE']} on port #{config['FINAL_PORT']}" if config["FINAL_DB_TYPE"]
      @output.puts "Dumps: #{initial_dumps.length} initial, #{final_dumps.length} final"
      @output.puts "Schema bundle: #{schema_bundle_status(customer)}"
      @output.puts "\nContainer status:"
      @output.puts @project_service.container_status(customer) if @project_service.respond_to?(:container_status)
    end

    def select_next_action(customer)
      config = Project.load_config(customer, env_for_project)
      actions = {}
      actions["Add/import initial source dump"] = :initial_dump if dump_files(customer, "initial").empty?
      actions["Start initial DB and import dump"] = :import_initial if dump_files(customer, "initial").any?
      actions["Add final database"] = :add_final_db unless config["FINAL_DB_TYPE"]
      actions["Add/import final dump"] = :final_dump if config["FINAL_DB_TYPE"] && dump_files(customer, "final").empty?
      actions["Start final DB and import dump"] = :import_final if config["FINAL_DB_TYPE"] && dump_files(customer, "final").any?
      actions["Generate initial schema bundle"] = :bundle_initial_schema if dump_files(customer, "initial").any?
      actions["Generate final schema bundle"] = :bundle_final_schema if config["FINAL_DB_TYPE"] && dump_files(customer, "final").any?
      actions["Set up converter"] = :setup_converter unless Dir.exist?(File.join(@project_service.project_path(customer), "discourse-converters"))
      actions["Run converter command"] = :run_converter if Dir.exist?(File.join(@project_service.project_path(customer), "discourse-converters"))
      actions["View detailed status"] = :status
      actions["Advanced actions"] = :advanced
      actions["Quit"] = :quit
      select("Recommended next step", actions)
    end

    def run_action(customer, action)
      case action
      when :initial_dump then prompt_dump_flow(customer, "initial")
      when :final_dump then prompt_dump_flow(customer, "final")
      when :import_initial then offer_start_and_import(customer, "initial", dump_files(customer, "initial").first)
      when :import_final then offer_start_and_import(customer, "final", dump_files(customer, "final").first)
      when :add_final_db
        return BACK if add_final_db(customer) == BACK

        prompt_dump_flow(customer, "final") if confirm?("Add a final dump now?", default: true)
      when :setup_converter then setup_converter(customer)
      when :bundle_initial_schema then generate_schema_bundle(customer, "initial")
      when :bundle_final_schema then generate_schema_bundle(customer, "final")
      when :run_converter then run_converter(customer)
      when :status then @project_service.status(customer)
      when :advanced then run_advanced_action(customer)
      when :quit then @output.puts "No changes made."
      end
    end

    def prompt_dump_flow(customer, phase)
      existing = dump_files(customer, phase)
      if existing.any?
        @output.puts "\nExisting #{phase} dump found: #{File.basename(existing.first)} (#{DumpTools.format_size(File.size(existing.first))})"
        choice = select(
          "What would you like to do?",
          {
            "Use existing dump" => :use_existing,
            "Select a new dump file" => :new_dump,
            "Skip import for now" => :skip
          },
          allow_back: true
        )
        return BACK if choice == BACK
        return offer_start_and_import(customer, phase, existing.first) if choice == :use_existing
        return if choice == :skip
      end

      format = select(
        "What format is your source data?",
        {
          "SQL dump file (.sql or .sql.gz)" => :sql,
          "Tar archive containing SQL" => :tar,
          "XML dump files (mysqldump --xml)" => :xml,
          "Skip for now" => :skip
        },
        allow_back: true
      )
      return BACK if format == BACK
      return if format == :skip

      source = ask_path("Path to source data")
      return BACK if source == BACK

      if source.to_s.strip.empty?
        @output.puts "\nNo path provided."
        return
      end

      dump_path = if format == :xml
                    convert_xml_to_project(customer, phase, source)
                  else
                    @project_service.stage_dump(customer, phase, source)
                  end
      offer_start_and_import(customer, phase, dump_path)
    end

    def offer_start_and_import(customer, phase, dump_path)
      return unless dump_path

      return unless confirm?("Start #{phase}-db and import this dump now?", default: true)

      begin
        @project_service.start(
          customer,
          profile: "#{phase}-db",
          wait_for_health: true,
          on_port_conflict: proc { |conflicts| confirm_port_conflicts(customer, conflicts) }
        )
      rescue UsageError => e
        @output.puts "[WARN] #{e.message}"
        return
      end
      options = prompt_import_options(dump_path)
      options[:file] = File.basename(dump_path)
      options[:quiet_validation] = true
      @import_service.import_dump(customer, phase, options)
      generate_schema_bundle(customer, phase)
    end

    def prompt_import_options(dump_path)
      options = { max_packet: "512M" }
      file_size = File.size(dump_path)
      default_exclude = large_table_suggestions(dump_path)

      if confirm?("Exclude any tables from import?", default: !default_exclude.empty?)
        exclude = ask("Tables to exclude (comma-separated#{default_exclude.empty? ? '' : ", default: #{default_exclude}"})")
        exclude = default_exclude if exclude.to_s.strip.empty?
        options[:exclude_tables] = exclude unless exclude.to_s.strip.empty?
      end

      turbo_default = file_size > 1024 * 1024 * 1024
      if confirm?("Use turbo mode for fastest import?#{turbo_default ? ' (recommended for large dumps)' : ''}", default: turbo_default)
        options[:turbo] = true
      elsif confirm?("Use fast mode? (disables keys during import)", default: true)
        options[:fast] = true
      end

      options
    end

    def large_table_suggestions(dump_path)
      @output.puts "\nAnalyzing dump for large tables..."
      analysis = SQLTools.analyze_sql_dump(dump_path, sample_bytes: File.size(dump_path) < 100 * 1024 * 1024 ? nil : 200 * 1024 * 1024)
      large = analysis[:tables].select { |_, info| info[:size] >= 100 * 1024 * 1024 }
      if large.empty?
        @output.puts "No large tables detected."
        return ""
      end

      @output.puts "Large tables detected:"
      large.sort_by { |_, info| -info[:size] }.first(10).each do |name, info|
        @output.puts "  #{name}: #{DumpTools.format_size(info[:size])}"
      end
      large.keys.first(5).join(",")
    rescue StandardError => e
      @output.puts "[WARN] Could not analyze dump: #{e.message}"
      ""
    end

    def add_final_db(customer)
      db_type = select("Final database type", DATABASE_TYPES.keys.to_h { |key| [key, key] }, allow_back: true)
      return BACK if db_type == BACK

      port = ask_optional_integer("Final port (blank for initial port + 1)")
      return BACK if port == BACK

      @project_service.add_final_db(customer, compact_options(db_type: db_type, port: port))
    end

    def run_advanced_action(customer)
      action = select(
        "Advanced action",
        {
          "Show status" => :status,
          "Start services" => :start,
          "Stop services" => :stop,
          "Convert XML dump" => :convert_xml,
          "Generate schema bundle" => :schema_bundle,
          "Run converter command" => :run_converter,
          "Generate redacted summary from latest converter logs" => :converter_summary,
          "Generate findings from latest redacted summary" => :findings,
          "Generate synthetic fixtures from latest findings" => :fixtures,
          "Regenerate runtime config" => :regenerate,
          "Replace/reset DB data" => :replace_dump,
          "Clean up project" => :cleanup,
          "Quit" => :quit
        },
        allow_back: true
      )
      return BACK if action == BACK

      case action
      when :status then @project_service.status(customer)
      when :start
        profile = select_profile
        return BACK if profile == BACK

        @project_service.start(
          customer,
          profile: profile,
          on_port_conflict: proc { |conflicts| confirm_port_conflicts(customer, conflicts) }
        )
      when :stop
        profile = select_profile
        return BACK if profile == BACK

        @project_service.stop(customer, profile: profile, remove: confirm?("Remove stopped containers?", default: false))
      when :convert_xml then convert_xml(customer)
      when :schema_bundle
        phase = select_phase
        return BACK if phase == BACK

        generate_schema_bundle(customer, phase)
      when :run_converter then run_converter(customer)
      when :converter_summary then generate_converter_summary(customer)
      when :findings then generate_findings(customer)
      when :fixtures then generate_synthetic_fixtures(customer)
      when :regenerate then @project_service.regenerate(customer)
      when :replace_dump
        phase = select_phase
        return BACK if phase == BACK

        @import_service.replace_dump(customer, phase, yes: confirm!("Reset #{phase} database data?"))
      when :cleanup
        @project_service.cleanup(customer, yes: confirm!("Delete project #{customer}?"))
      when :quit
        @output.puts "No changes made."
      end
    end

    def convert_xml(customer)
      phase = select_phase
      return BACK if phase == BACK

      source = ask_path("Path to XML file or directory")
      return BACK if source == BACK

      output = convert_xml_to_project(customer, phase, source)
      @output.puts "[OK] XML converted: #{output}"
    end

    def generate_schema_bundle(customer, phase)
      unless @schema_service
        @output.puts "[WARN] Schema bundle service is not available."
        return
      end

      @schema_service.bundle(customer, phase: phase)
    rescue UsageError => e
      @output.puts "[WARN] #{e.message}"
      @output.puts "Start the database first:"
      @output.puts "  silo-migrate start #{customer} --profile #{phase}-db --wait"
    end

    def run_converter(customer)
      command_text = ask("Converter command (blank for bundle exec ruby converter.rb)").to_s.strip
      command = command_text.empty? ? [] : command_text.split
      begin
        @project_service.run_converter(customer, command: command)
      rescue UsageError => e
        @output.puts "[WARN] #{e.message}"
        @output.puts "Recovery commands:"
        @output.puts "  silo-migrate start #{customer} --profile converter --build"
        @output.puts "  docker exec -it #{customer}_converter bundle install"
        @output.puts "  silo-migrate run-converter #{customer}"
      ensure
        generate_converter_summary(customer, command: command) if confirm?("Generate AI-safe redacted converter summary?", default: true)
      end
    end

    def generate_converter_summary(customer, command: nil)
      result = @project_service.last_converter_result if @project_service.respond_to?(:last_converter_result)
      command ||= @project_service.last_converter_command if @project_service.respond_to?(:last_converter_command)
      @project_service.generate_converter_summary(customer, command: command || [], result: result)
      generate_findings(customer) if confirm?("Generate structured findings from this summary?", default: true)
    rescue UsageError => e
      @output.puts "[WARN] #{e.message}"
    end

    def generate_findings(customer)
      unless @findings_service
        @output.puts "[WARN] Findings service is not available."
        return
      end

      artifacts = @findings_service.generate(customer)
      @output.puts "[OK] Findings index: #{artifacts.fetch(:index_path)}"
      artifacts.fetch(:findings).each { |path| @output.puts "[OK] Finding: #{path}" }
      generate_synthetic_fixtures(customer) if confirm?("Generate shape-only synthetic fixtures?", default: true)
    rescue UsageError => e
      @output.puts "[WARN] #{e.message}"
    end

    def generate_synthetic_fixtures(customer)
      unless @fixture_service
        @output.puts "[WARN] Synthetic fixture service is not available."
        return
      end

      artifacts = @fixture_service.generate(customer)
      artifacts.fetch(:fixtures).each { |path| @output.puts "[OK] Synthetic fixture: #{path}" }
      @output.puts "[WARN] No synthetic fixtures were generated." if artifacts.fetch(:fixtures).empty?
    rescue UsageError => e
      @output.puts "[WARN] #{e.message}"
    end

    def convert_xml_to_project(customer, phase, source)
      source_path = Pathname(source)
      base = source_path.file? ? source_path.basename.to_s.sub(/\.gz\z/, "").sub(/\.xml\z/, "") : "combined"
      output = Pathname(File.join(@project_service.project_path(customer), "dumps", phase, "#{base}.sql.gz"))
      XMLToSQLConverter.new(verbose: false).convert(source_path, output)
      @output.puts "[OK] XML converted and staged: #{output}"
      output
    end

    def setup_converter(customer)
      begin
        @project_service.setup_converter(customer)
      rescue UsageError => e
        @output.puts e.message
        if confirm?("Retry using terminal SSH prompts? (for passphrase-protected keys)", default: true)
          begin
            @project_service.setup_converter(customer, allow_ssh_prompt: true)
          rescue UsageError => retry_error
            @output.puts retry_error.message
            return unless confirm?("Try an alternate converter repository URL?", default: false)

      repo = ask("Alternate repository URL").to_s.strip
      return if repo.empty?

            @project_service.setup_converter(customer, repo: repo)
          end
        else
          return unless confirm?("Try an alternate converter repository URL?", default: false)

          repo = ask("Alternate repository URL").to_s.strip
          return if repo.empty?

          @project_service.setup_converter(customer, repo: repo)
        end
      end
      if confirm?("Build/start converter and run bundle install now?", default: true)
        @project_service.start_converter(customer, bundle_install: true, hard_fail: false)
      else
        @output.puts "\nTo start the converter later:"
        @output.puts "  silo-migrate start #{customer} --profile converter --build"
        @output.puts "  docker exec -it #{customer}_converter bundle install"
      end
    end

    def confirm_port_conflicts(customer, conflicts)
      @output.puts "\n[WARN] The following configured ports appear to be in use:"
      conflicts.each { |entry| @output.puts "  - Port #{entry[:port]} (#{entry[:service]})" }
      @output.puts "To recover, stop the conflicting service or edit config.env and run:"
      @output.puts "  silo-migrate regenerate #{customer}"
      confirm?("Continue anyway?", default: false)
    end

    def dump_files(customer, phase)
      dir = File.join(@project_service.project_path(customer), "dumps", phase)
      (Dir[File.join(dir, "*.sql")] + Dir[File.join(dir, "*.sql.gz")]).select { |path| File.file?(path) }.sort
    end

    def schema_bundle_status(customer)
      phases = %w[initial final].select do |phase|
        File.exist?(File.join(@project_service.project_path(customer), "schema", phase, "summary.json"))
      end
      phases.empty? ? "none" : phases.join(", ")
    end

    def env_for_project
      @project_service.respond_to?(:env) ? @project_service.env : ENV
    end

    def select_phase
      select("Dump phase", { "initial" => "initial", "final" => "final" }, allow_back: true)
    end

    def select_profile
      select(
        "Service profile",
        {
          "all" => "all",
          "initial-db" => "initial-db",
          "final-db" => "final-db",
          "converter" => "converter"
        },
        allow_back: true
      )
    end

    def default_prompt
      require "tty-prompt"
      TTY::Prompt.new
    rescue LoadError
      nil
    end

    def ask(message)
      return @prompt.ask(message) if @prompt&.respond_to?(:ask)

      @output.print "#{message}: "
      $stdin.gets&.chomp.to_s
    end

    def ask_path(message)
      answer = if @external_prompt && @prompt&.respond_to?(:suggest)
                 ask_path_with_prompt_suggestions(message)
               elsif @external_prompt && @prompt&.respond_to?(:ask)
                 @prompt.ask("#{message} (type 'back' to return)")
               else
                 ask_path_with_readline(message)
               end
      return BACK if back_command?(answer)

      answer
    end

    def select(message, choices, allow_back: false)
      choices = choices.merge(BACK_LABEL => BACK) if allow_back
      return @prompt.select(message, choices) if @prompt&.respond_to?(:select)

      @output.puts message
      choices.keys.each_with_index { |label, idx| @output.puts "  #{idx + 1}. #{label}" }
      index = ask("Choice").to_i - 1
      choices.values.fetch(index)
    end

    def ask_optional_integer(message)
      value = ask(message).to_s.strip
      return BACK if back_command?(value)

      value.empty? ? nil : Integer(value, 10)
    end

    def confirm?(message, default: false)
      suffix = default ? "[Y/n]" : "[y/N]"
      answer = ask("#{message} #{suffix}").to_s.strip.downcase
      return default if answer.empty?

      answer == "y" || answer == "yes"
    end

    def confirm!(message)
      confirmed = confirm?(message, default: false)
      raise UsageError, "Action cancelled." unless confirmed

      confirmed
    end

    def compact_options(options)
      options.reject { |_, value| value.nil? }
    end

    def ask_path_with_prompt_suggestions(message)
      @prompt.suggest("#{message} (type 'back' to return)") do |suggest|
        suggest.choices = path_suggestions
      end
    rescue NoMethodError, ArgumentError
      @prompt.ask("#{message} (type 'back' to return)")
    end

    def ask_path_with_readline(message)
      require "readline"
      previous_completion_proc = Readline.completion_proc
      previous_completer_word_break_characters = Readline.completer_word_break_characters
      Readline.completion_proc = method(:complete_path)
      Readline.completer_word_break_characters = " \t\n\"\\'`@$><=;|&{("
      Readline.readline("#{message} (type 'back' to return): ", true).to_s
    rescue LoadError
      ask("#{message} (type 'back' to return)")
    ensure
      if defined?(Readline)
        Readline.completion_proc = previous_completion_proc
        Readline.completer_word_break_characters = previous_completer_word_break_characters
      end
    end

    def complete_path(input)
      prefix = input.to_s.empty? ? "*" : "#{input}*"
      Dir.glob(File.expand_path(prefix)).map do |path|
        display = path.start_with?(Dir.pwd) ? path.sub(%r{\A#{Regexp.escape(Dir.pwd)}/?}, "") : path
        File.directory?(path) ? "#{display}/" : display
      end
    end

    def path_suggestions
      Dir.glob("*", File::FNM_DOTMATCH).reject { |path| [".", ".."].include?(path) }.sort.map do |path|
        File.directory?(path) ? "#{path}/" : path
      end
    end

    def back_command?(value)
      BACK_COMMANDS.include?(value.to_s.strip.downcase)
    end
  end
end
