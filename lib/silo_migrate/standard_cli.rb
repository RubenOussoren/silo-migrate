# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"

module SiloMigrate
  # Strict structured interface over StandardWorkflowService. Two surfaces:
  #
  #   standard ...        Engineer. Includes approve, reset, release and private paths.
  #   standard agent ...  Exactly what a coding/conversational adapter may call. It can
  #                       inspect safe status, propose a plan, request an approved run
  #                       and read released findings. It cannot approve, reset, release
  #                       or see private material. The adapter exposes only this.
  class StandardCLI
    HELP = <<~HELP.freeze
      Usage: silo-migrate standard COMMAND

      Engineer (operates without any LLM):
        init WORKSPACE [--converter-worktree PATH] [--discourse-profile NAME] [--site-settings PATH]
        runtime list
        runtime show NAME
        converter status WORKSPACE
        converter refresh WORKSPACE [--if-changed]    (--if-changed: keep plans valid when nothing changed)
        fixture register WORKSPACE --fixture-dir DIR --snapshot NAME [--label LABEL]
        status WORKSPACE
        plan propose WORKSPACE --dataset ID [--baseline seed|BASELINE_ID] [--ports A,B] [--allow-unqualified-runtime]
        plan propose WORKSPACE --operation convert --source INPUT_ID --settings INPUT_ID [--reconciliation INPUT_ID] [--charset NAME]
                                                       (real data: convert and reconcile counts only; no import)
        plan show WORKSPACE PLAN_ID
        plan approve WORKSPACE PLAN_ID --sha256 DIGEST --reviewer NAME
        plan discard WORKSPACE PLAN_ID --reviewer NAME          (a proposal nobody will approve)
        baseline accept WORKSPACE RUN_ID --reviewer NAME
        run start WORKSPACE PLAN_ID
        run claim WORKSPACE PLAN_ID
        run execute WORKSPACE RUN_ID
        run show WORKSPACE RUN_ID
        run private-paths WORKSPACE RUN_ID
        run recover WORKSPACE RUN_ID
        run reset WORKSPACE RUN_ID --yes
        finding review WORKSPACE FINDING_ID
        finding release WORKSPACE FINDING_ID --file PATH --sha256 DIGEST --reviewer NAME [--reproduction PATH --reproduction-sha256 DIGEST]
        finding reject WORKSPACE FINDING_ID --reviewer NAME
        finding amend WORKSPACE FINDING_ID --file PATH|- --sha256 DIGEST --reviewer NAME   (replace a released finding)
        finding withdraw WORKSPACE FINDING_ID --reviewer NAME                            (take a released finding back)

      Trusted analyst path (separate private investigation session only):
        analyst evidence WORKSPACE RUN_ID
        finding propose WORKSPACE --run RUN_ID --file PATH|- [--kind finding|reproduction]
        finding propose WORKSPACE --kind schema --file PATH|-   (source schema; no run)

      Conversational adapter (safe projections only):
        agent status WORKSPACE
        agent plan-propose WORKSPACE --dataset ID [--baseline seed|BASELINE_ID]
        agent plan-show WORKSPACE PLAN_ID
        agent run-claim WORKSPACE PLAN_ID
        agent run-execute WORKSPACE RUN_ID
        agent run-show WORKSPACE RUN_ID
        agent findings WORKSPACE
        agent finding-show WORKSPACE FINDING_ID
    HELP

    PARSE_ERROR = "STANDARD_ARGUMENTS_INVALID"
    DETAILED = %w[STANDARD_SETTINGS_INVALID STANDARD_RECONCILIATION_INVALID STANDARD_CONVERTER_DEPS_MISSING
                  STANDARD_CONVERTER_PLATFORM_MISSING STANDARD_INPUTS_INCOMPLETE STANDARD_DUMP_KIND_UNSUPPORTED].freeze
    OPERATION_ERROR = "STANDARD_OPERATION_FAILED"
    # Exit codes are per the contract: failed run returns its JSON and exits 1.

    def initialize(env: ENV, output: $stdout, error: $stderr, runtime: nil, code_root: nil)
      @env = env
      @output = output
      @error = error
      @runtime = runtime
      @code_root = code_root
    end

    def run(argv)
      return write_help if argv == ["--help"] || argv == ["-h"] || argv.empty?

      begin
        raise UsageError, PARSE_ERROR unless argv.all? { |arg| arg.is_a?(String) && arg.valid_encoding? }

        result = dispatch(argv.dup)
        write_json(result)
        failed_run?(argv, result) ? 1 : 0
      rescue StandardWorkflowError => e
        if %w[STANDARD_CONVERTER_DIRTY STANDARD_CONVERTER_CONFIG].include?(e.code)
          @error.write("Error: #{e.code}. #{Services::StandardWorkflowService::RECOVERY.fetch(e.code)}\n")
          1
        elsif DETAILED.include?(e.code)
          # Fixed details written by the convert-plan checks (which check, which placeholder),
          # never file content.
          @error.write("Error: #{e.message}. #{Services::StandardWorkflowService::RECOVERY.fetch(e.code, '')}".rstrip + "\n")
          1
        else
          write_error(e.code)
        end
      rescue NamedError => e
        write_error(e.message.to_s.match?(/\ANAMED_[A-Z_]+\z/) ? e.message : OPERATION_ERROR)
      rescue UsageError
        write_error(PARSE_ERROR)
      rescue ::StandardError
        write_error(OPERATION_ERROR)
      end
    end

    private

    def service(workspace)
      options = { env: @env }
      options[:runtime] = @runtime if @runtime
      options[:code_root] = @code_root if @code_root
      Services::StandardWorkflowService.new(workspace, **options)
    end

    def findings(workspace)
      Services::StandardFindingsService.new(workspace, env: @env)
    end

    def dispatch(args)
      group = args.shift
      case group
      when "init" then init(args)
      when "runtime"
        action = args.shift
        case action
        when "list" then no_more!(args); { version: 1, profiles: service("runtime-catalog").profiles.list }
        when "show"
          name = positional!(args)
          no_more!(args)
          service("runtime-catalog").profiles.show(name)
        else invalid!
        end
      when "converter"
        action = args.shift
        if_changed = action == "refresh" && args.size == 2 && args.delete("--if-changed")
        single_workspace(args) do |workspace|
          case action
          when "status" then service(workspace).converter_status
          when "refresh" then service(workspace).converter_refresh(if_changed: !!if_changed)
          else invalid!
          end
        end
      when "fixture" then fixture(args)
      when "status" then single_workspace(args) { |workspace| service(workspace).status }
      when "plan" then plan(args)
      when "baseline" then baseline(args)
      when "run" then run_group(args)
      when "finding" then finding(args)
      when "analyst" then analyst(args)
      when "agent" then agent(args)
      else invalid!
      end
    end

    def init(args)
      workspace = positional!(args)
      opts = options!(args, "--converter-worktree", "--discourse-profile", "--site-settings", optional: %w[--converter-worktree --discourse-profile --site-settings])
      service(workspace).init(converter_worktree: opts["--converter-worktree"], discourse_profile: opts.fetch("--discourse-profile", RuntimeProfiles::DEFAULT), site_settings: opts["--site-settings"])
    end

    # Convenience over the existing named registry: copies one synthetic fixture
    # snapshot into a new dataset as immutable inputs. No separate registry.
    def fixture(args)
      expect!(args.shift, "register")
      workspace = positional!(args)
      opts = options!(args, "--fixture-dir", "--snapshot", "--label", optional: %w[--label])
      dir = opts.fetch("--fixture-dir")
      snapshot = opts.fetch("--snapshot")
      invalid! unless snapshot.match?(/\A[a-z][a-z0-9_-]{0,30}\z/) && File.directory?(dir)
      Services::StandardFixture.new(env: @env).register(workspace, dir: dir, snapshot: snapshot, label: opts["--label"])
    end

    def plan(args)
      action = args.shift
      case action
      when "propose"
        workspace = positional!(args)
        invalid! if args.count("--allow-unqualified-runtime") > 1
        allow = args.delete("--allow-unqualified-runtime")
        if args[0, 2] == %w[--operation convert]
          args.shift(2)
          opts = options!(args, "--source", "--settings", "--reconciliation", "--charset", optional: %w[--reconciliation --charset])
          return service(workspace).propose_convert_plan(source: opts.fetch("--source"), settings: opts.fetch("--settings"), reconciliation: opts["--reconciliation"],
                                                         charset: opts.fetch("--charset", "utf8mb4"), allow_unqualified_runtime: !allow.nil?)
        end
        opts = options!(args, "--dataset", "--baseline", "--ports", optional: %w[--baseline --ports])
        service(workspace).propose_plan(dataset_id: opts.fetch("--dataset"), baseline: opts.fetch("--baseline", "seed"), ports: ports(opts["--ports"]), allow_unqualified_runtime: !allow.nil?)
      when "show"
        workspace = positional!(args)
        plan_id = positional!(args)
        no_more!(args)
        service(workspace).show_plan(plan_id)
      when "approve"
        workspace = positional!(args)
        plan_id = positional!(args)
        opts = options!(args, "--sha256", "--reviewer")
        service(workspace).approve_plan(plan_id: plan_id, sha256: opts.fetch("--sha256"), reviewer: opts.fetch("--reviewer"))
      when "discard"
        workspace = positional!(args)
        plan_id = positional!(args)
        opts = options!(args, "--reviewer")
        service(workspace).discard_plan(plan_id: plan_id, reviewer: opts.fetch("--reviewer"))
      else invalid!
      end
    end

    def baseline(args)
      expect!(args.shift, "accept")
      workspace = positional!(args)
      run_id = positional!(args)
      opts = options!(args, "--reviewer")
      service(workspace).accept_baseline(run_id: run_id, reviewer: opts.fetch("--reviewer"))
    end

    def run_group(args)
      action = args.shift
      workspace = positional!(args)
      identifier = positional!(args)
      case action
      when "start" then no_more!(args); service(workspace).run_plan(plan_id: identifier)
      when "claim" then no_more!(args); service(workspace).claim(plan_id: identifier)
      when "execute" then no_more!(args); service(workspace).execute(run_id: identifier)
      when "show" then no_more!(args); service(workspace).show_run(identifier)
      when "private-paths" then no_more!(args); service(workspace).private_paths(identifier)
      when "recover" then no_more!(args); service(workspace).recover(run_id: identifier)
      when "reset"
        expect!(args.shift, "--yes")
        no_more!(args)
        service(workspace).reset_run(run_id: identifier, yes: true)
      else invalid!
      end
    end

    def finding(args)
      action = args.shift
      workspace = positional!(args)
      case action
      when "propose"
        # A schema finding describes the source, not a run: it has no --run.
        opts = options!(args, "--run", "--file", "--kind", optional: %w[--run --kind])
        kind = opts.fetch("--kind", "finding")
        invalid! unless (kind == "schema") == opts["--run"].nil?
        findings(workspace).propose(run_id: opts["--run"], text: read_bounded(opts.fetch("--file")), kind: kind)
      when "review"
        identifier = positional!(args)
        no_more!(args)
        { version: 1, finding_id: identifier, status: "proposed", proposal: findings(workspace).review_text(identifier) }
      when "release"
        identifier = positional!(args)
        opts = options!(args, "--file", "--sha256", "--reviewer", "--reproduction", "--reproduction-sha256", optional: %w[--reproduction --reproduction-sha256])
        reproduction = opts["--reproduction"] && read_bounded(opts["--reproduction"])
        findings(workspace).release(finding_id: identifier, released_text: read_bounded(opts.fetch("--file")), sha256: opts.fetch("--sha256"), reviewer: opts.fetch("--reviewer"), reproduction: reproduction, reproduction_sha256: opts["--reproduction-sha256"])
      when "reject"
        identifier = positional!(args)
        opts = options!(args, "--reviewer")
        findings(workspace).reject(finding_id: identifier, reviewer: opts.fetch("--reviewer"))
      when "amend"
        identifier = positional!(args)
        opts = options!(args, "--file", "--sha256", "--reviewer")
        findings(workspace).amend(finding_id: identifier, released_text: read_bounded(opts.fetch("--file")), sha256: opts.fetch("--sha256"), reviewer: opts.fetch("--reviewer"))
      when "withdraw"
        identifier = positional!(args)
        opts = options!(args, "--reviewer")
        findings(workspace).withdraw(finding_id: identifier, reviewer: opts.fetch("--reviewer"))
      else invalid!
      end
    end

    def analyst(args)
      expect!(args.shift, "evidence")
      workspace = positional!(args)
      run_id = positional!(args)
      no_more!(args)
      findings(workspace).private_evidence(run_id)
    end

    # The complete adapter surface. Nothing here approves, resets or releases.
    def agent(args)
      action = args.shift
      workspace = positional!(args)
      case action
      when "status" then no_more!(args); service(workspace).status
      when "plan-propose"
        opts = options!(args, "--dataset", "--baseline", optional: %w[--baseline])
        service(workspace).propose_plan(dataset_id: opts.fetch("--dataset"), baseline: opts.fetch("--baseline", "seed"))
      when "plan-show"
        plan_id = positional!(args)
        no_more!(args)
        service(workspace).show_plan(plan_id)
      when "run-claim"
        plan_id = positional!(args)
        no_more!(args)
        service(workspace).claim(plan_id: plan_id)
      when "run-execute"
        run_id = positional!(args)
        no_more!(args)
        service(workspace).execute(run_id: run_id)
      when "run-show"
        run_id = positional!(args)
        no_more!(args)
        service(workspace).show_run(run_id)
      when "findings" then no_more!(args); findings(workspace).released_list
      when "finding-show"
        finding_id = positional!(args)
        no_more!(args)
        findings(workspace).released_show(finding_id)
      else invalid!
      end
    end

    def failed_run?(argv, result)
      request = [%w[run start], %w[run execute], %w[agent run-execute]].include?(argv[0, 2])
      request && result[:status] != "completed"
    end

    def single_workspace(args)
      workspace = positional!(args)
      no_more!(args)
      yield workspace
    end

    def ports(value)
      return nil unless value

      invalid! unless value.match?(/\A\d+,\d+\z/)
      value.split(",").map { |port| Integer(port, 10) }
    end

    def read_bounded(path)
      if path == "-"
        text = $stdin.read(Services::StandardFindingsService::MAX_BYTES + 1).to_s
        invalid! if text.bytesize > Services::StandardFindingsService::MAX_BYTES
        return text
      end
      invalid! unless File.file?(path) && !File.symlink?(path) && File.size(path) <= Services::StandardFindingsService::MAX_BYTES
      File.read(path)
    end

    def options!(args, *allowed, optional: [])
      result = {}
      until args.empty?
        option = args.shift
        invalid! unless allowed.include?(option) && !result.key?(option)
        value = args.shift
        invalid! if value.nil? || (value.start_with?("-") && !(value == "-" && option == "--file"))
        result[option] = value
      end
      invalid! unless (allowed - optional - result.keys).empty?
      result
    end

    def positional!(args)
      value = args.shift
      invalid! if value.nil? || value.start_with?("-")
      value
    end

    def no_more!(args)
      invalid! unless args.empty?
    end

    def expect!(actual, expected)
      invalid! unless actual == expected
    end

    def invalid!
      raise UsageError, PARSE_ERROR
    end

    def write_help
      @output.write(HELP)
      0
    end

    def write_json(result)
      @output.write(JSON.generate(result) + "\n")
    end

    def write_error(code)
      @error.write("Error: #{code}\n")
      1
    end
  end

  module Services
    # Registers a synthetic fixture snapshot through the named-workspace service.
    class StandardFixture
      def initialize(env: ENV)
        @env = env
      end

      def register(workspace, dir:, snapshot:, label:)
        named = NamedWorkspaceService.new(env: @env)
        source = named.add_source(workspace, platform: "khoros", label: "synthetic #{snapshot}")
        dataset = named.add_dataset(workspace, source_id: source.fetch(:source_id), label: label || snapshot)
        dataset_id = dataset.fetch(:dataset_id)
        store = NamedWorkspaceStore.new(workspace, env: @env)
        slug = dataset_id.delete_prefix("dataset-")[0, 8]
        expected_all = JSON.parse(File.read(File.join(dir, "expected.json")))
        raise StandardWorkflowError, "STANDARD_FIXTURE_INVALID" unless expected_all.key?(snapshot)

        root = "inputs/#{slug}"
        files = {
          File.join(dir, "#{snapshot}.sql") => ["#{root}/source.sql", "source-sql"],
          File.join(dir, "settings.yml") => ["#{root}/settings.yml", "converter-settings"]
        }
        Dir.glob("**/*", File::FNM_DOTMATCH, base: File.join(dir, "mappings")).each do |rel|
          path = File.join(dir, "mappings", rel)
          files[path] = ["#{root}/mappings/#{rel}", "mapping"] if File.file?(path)
        end
        Dir.glob("**/*", File::FNM_DOTMATCH, base: File.join(dir, "uploads")).each do |rel|
          path = File.join(dir, "uploads", rel)
          files[path] = ["#{root}/uploads/#{rel}", "upload"] if File.file?(path)
        end
        created = []
        files.each do |path, (relative, type)|
          created << copy_and_register(named, store, workspace, dataset_id, File.binread(path), relative, type)
        end
        created << copy_and_register(named, store, workspace, dataset_id, JSON.pretty_generate(expected_all.fetch(snapshot)) + "\n", "#{root}/expected.json", "expected")
        { version: 1, source_id: source.fetch(:source_id), dataset_id: dataset_id, input_count: created.size, status: "registered" }
      end

      private

      def copy_and_register(named, store, workspace, dataset_id, bytes, relative, type)
        target = File.join(store.root, relative)
        FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
        File.open(target, File::WRONLY | File::CREAT | File::EXCL, 0o400) do |file|
          file.binmode
          file.write(bytes)
        end
        named.add_input(workspace, dataset_id: dataset_id, path: relative, sha256: Digest::SHA256.hexdigest(bytes), bytes: bytes.bytesize, type: type)
      end
    end
  end
end
