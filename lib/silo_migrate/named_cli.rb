# frozen_string_literal: true

require "json"

module SiloMigrate
  # Deliberately independent of the legacy OptionParser-based CLI. Named mode
  # accepts only the fixed grammar below and emits only approved result fields.
  class NamedCLI
    HELP = <<~HELP.freeze
      Usage: silo-migrate named COMMAND
        init WORKSPACE
        source add WORKSPACE --platform LABEL [--label LABEL]
        dataset add WORKSPACE --source SOURCE_ID [--label LABEL]
        input add WORKSPACE --dataset DATASET_ID --path inputs/REL --sha256 HEX --bytes INTEGER --type LABEL
        plan validate-inputs WORKSPACE --dataset DATASET_ID
        run execute|show|recover WORKSPACE RUN_ID
    HELP
    PARSE_ERROR = "NAMED_ARGUMENTS_INVALID".freeze
    OPERATION_ERROR = "NAMED_OPERATION_FAILED".freeze
    OUTPUT_ERROR = "NAMED_OUTPUT_FAILED".freeze
    SERVICE_CODES = %w[
      NAMED_BUSY NAMED_WORKSPACE_INVALID NAMED_MODE_CONFLICT NAMED_NOT_INITIALIZED
      NAMED_ALREADY_INITIALIZED NAMED_PATH_INVALID NAMED_STATE_INVALID NAMED_SIZE_LIMIT
      NAMED_ARGUMENT_INVALID NAMED_REFERENCE_INVALID NAMED_STALE_PLAN NAMED_TRANSITION_INVALID
      NAMED_INPUT_CHANGED NAMED_IO_ERROR NAMED_VALIDATION_FAILED NAMED_OK NAMED_INTERRUPTED
    ].freeze
    ID_PREFIXES = {
      "workspace_id" => "workspace", "source_id" => "source", "dataset_id" => "dataset",
      "input_id" => "input", "plan_id" => "plan", "run_id" => "run", "attempt_id" => "attempt"
    }.freeze
    STATUSES = %w[initialized registered planned running completed failed interrupted].freeze

    def initialize(env: ENV, output: $stdout, error: $stderr)
      @env = env
      @output = output
      @error = error
    end

    def run(argv)
      return write_help if argv == ["--help"] || argv == ["-h"]

      begin
        invalid! unless argv.is_a?(Array) && argv.all? { |arg| arg.is_a?(String) && arg.valid_encoding? }
        service = SiloMigrate::Services::NamedWorkspaceService.new(env: @env)
        result = public_result(dispatch(argv, service))
        output_status = write_json(result)
        return 1 if output_status != 0
        argv[0, 2] == %w[run execute] && result["status"] == "failed" ? 1 : 0
      rescue SiloMigrate::NamedError => e
        write_error(safe_code(e))
      rescue SiloMigrate::UsageError
        write_error(PARSE_ERROR)
      rescue StandardError
        write_error(OPERATION_ERROR)
      end
    end

    private

    def dispatch(argv, service)
      args = argv.dup
      case args.shift
      when "init"
        require_count!(args, 1)
        service.init(args[0])
      when "source"
        expect!(args.shift, "add")
        workspace = take_positional!(args)
        opts = options!(args, "--platform" => :required, "--label" => :required)
        require_keys!(opts, "--platform")
        service.add_source(workspace, platform: opts.fetch("--platform"), label: opts["--label"])
      when "dataset"
        expect!(args.shift, "add")
        workspace = take_positional!(args)
        opts = options!(args, "--source" => :required, "--label" => :required)
        require_keys!(opts, "--source")
        service.add_dataset(workspace, source_id: opts.fetch("--source"), label: opts["--label"])
      when "input"
        expect!(args.shift, "add")
        workspace = take_positional!(args)
        opts = options!(args, "--dataset" => :required, "--path" => :required, "--sha256" => :required, "--bytes" => :required, "--type" => :required)
        require_keys!(opts, "--dataset", "--path", "--sha256", "--bytes", "--type")
        bytes = opts.fetch("--bytes")
        invalid! unless bytes.match?(/\A(?:0|[1-9][0-9]*)\z/)
        service.add_input(workspace, dataset_id: opts.fetch("--dataset"), path: opts.fetch("--path"), sha256: opts.fetch("--sha256"), bytes: Integer(bytes, 10), type: opts.fetch("--type"))
      when "plan"
        expect!(args.shift, "validate-inputs")
        workspace = take_positional!(args)
        opts = options!(args, "--dataset" => :required)
        require_keys!(opts, "--dataset")
        service.plan_validate_inputs(workspace, dataset_id: opts.fetch("--dataset"))
      when "run"
        action = args.shift
        invalid! unless %w[execute show recover].include?(action)
        require_count!(args, 2)
        service.public_send(action, args[0], run_id: args[1])
      else
        invalid!
      end
    end

    def options!(args, allowed)
      result = {}
      until args.empty?
        option = args.shift
        invalid! unless allowed.key?(option) && !result.key?(option)
        value = args.shift
        invalid! if value.nil? || value.start_with?("-")
        result[option] = value
      end
      result
    end

    def take_positional!(args)
      value = args.shift
      invalid! if value.nil? || value.start_with?("-")
      value
    end

    def require_keys!(hash, *keys)
      invalid! unless (keys - hash.keys).empty?
    end

    def require_count!(args, count)
      invalid! unless args.length == count
    end

    def expect!(actual, expected)
      invalid! unless actual == expected
    end

    def invalid!
      raise SiloMigrate::UsageError.new(PARSE_ERROR), cause: nil
    end

    def safe_code(error)
      code = error.respond_to?(:code) ? error.code.to_s : error.message.to_s
      SERVICE_CODES.include?(code) || code == PARSE_ERROR ? code : OPERATION_ERROR
    rescue StandardError
      OPERATION_ERROR
    end

    # JSON output is restricted to primitive safe fields: opaque IDs, status,
    # version and explicitly approved counters. Never serialize service objects.
    def public_result(value)
      raise TypeError unless value.is_a?(Hash)
      allowed = %w[version workspace_id source_id dataset_id input_id plan_id run_id attempt_id status code input_count bytes]
      result = {}
      value.each do |key, item|
        key = key.to_s
        next unless allowed.include?(key)
        case key
        when "version"
          result[key] = item if item == 1
        when *ID_PREFIXES.keys
          raise TypeError unless opaque_id?(item, ID_PREFIXES.fetch(key))
          result[key] = item
        when "status"
          raise TypeError unless STATUSES.include?(item)
          result[key] = item
        when "code"
          raise TypeError unless SERVICE_CODES.include?(item)
          result[key] = item
        when "input_count", "bytes"
          raise TypeError unless item.is_a?(Integer) && item >= 0
          result[key] = item
        end
      end
      raise TypeError unless result["version"] == 1 && result.key?("status")
      result
    end

    def opaque_id?(value, prefix)
      value.is_a?(String) && value.match?(/\A#{Regexp.escape(prefix)}-[0-9a-f]{32}\z/)
    end

    def write_help
      @output.write(HELP)
      0
    rescue StandardError
      write_error(OUTPUT_ERROR)
    end

    def write_json(result)
      @output.write(JSON.generate(result) + "\n")
      0
    rescue StandardError
      write_error(OUTPUT_ERROR)
    end

    def write_error(code)
      @error.write("Error: #{code}\n")
      1
    rescue StandardError
      1
    end
  end
end
