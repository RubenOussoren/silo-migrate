# frozen_string_literal: true

require_relative "merge_contract"

# Privacy-safe, bounded guest failure diagnostic. Never include exception
# messages, raw file paths, settings keys/values, audit counters, SQL or stderr.
module SiloMergeValidationDiagnostic
  PREFIX = "SILO_MERGE_BOOTSTRAP_DIAGNOSTIC:"
  MAX_BYTES = 1024
  MAX_LINE = 1_000_000
  MAX_CAUSE_DEPTH = 4
  FIELDS = %w[version stage error_class component line].freeze

  STAGES = %w[
    unknown
    bootstrap
    context
    checks_database
    rails_boot
    runtime_binding
    contract_settings
    contract_validation
    settings
    layer_load
    connections
    hook_validation
    policy_preflight
    asset_selection
    audit
    existence_checks
    asset_preflight
    result_persistence
    result_close
  ].freeze

  COMPONENTS = %w[
    validation_runner
    validation_config
    contract
    asset_adapter
    asset_references
    baseline_assets
    stock_runtime
    custom_layer
    unknown
  ].freeze

  LINE_COMPONENTS = %w[
    validation_runner
    validation_config
    contract
    asset_adapter
    asset_references
    baseline_assets
    stock_runtime
  ].freeze

  ERROR_CLASSES = %w[
    none
    other
    SiloMergeValidation::Refused
    SiloMergeValidation::Finding
    SiloMergeValidationConfig::Refused
    SiloMergeContract::Error
    SiloMergeAssets::Error
    SiloMergeRefusal::Error
    SiloMergeValidationDiagnostic::Error
    SiloDiscourseMergeAdapter::Error
    SiloDiscourseAssetReferences::Error
    SiloDiscourseBaselineAssets::Error
    ArgumentError
    EncodingError
    Encoding::InvalidByteSequenceError
    Encoding::UndefinedConversionError
    EOFError
    Errno::EACCES
    Errno::ECONNREFUSED
    Errno::EEXIST
    Errno::EINVAL
    Errno::EISDIR
    Errno::ENOENT
    Errno::ENOSPC
    Errno::ENOTDIR
    Errno::EPERM
    Errno::EPIPE
    Errno::EROFS
    Errno::ETIMEDOUT
    FrozenError
    IndexError
    IOError
    JSON::NestingError
    JSON::ParserError
    KeyError
    LoadError
    LocalJumpError
    NameError
    NoMemoryError
    NoMethodError
    NotImplementedError
    Psych::AliasesNotEnabled
    Psych::BadAlias
    Psych::DisallowedClass
    Psych::Exception
    Psych::SyntaxError
    RangeError
    RegexpError
    RuntimeError
    ScriptError
    SecurityError
    SignalException
    StandardError
    StopIteration
    SyntaxError
    SystemCallError
    SystemExit
    SystemStackError
    ThreadError
    Timeout::Error
    TypeError
    ZeroDivisionError
    PG::CheckViolation
    PG::ConnectionBad
    PG::DeadlockDetected
    PG::Error
    PG::ExclusionViolation
    PG::FeatureNotSupported
    PG::ForeignKeyViolation
    PG::InsufficientPrivilege
    PG::InvalidAuthorizationSpecification
    PG::InvalidCatalogName
    PG::InvalidParameterValue
    PG::InvalidSchemaName
    PG::LockNotAvailable
    PG::NotNullViolation
    PG::ObjectInUse
    PG::QueryCanceled
    PG::ReadOnlySqlTransaction
    PG::ServerError
    PG::SyntaxError
    PG::SyntaxErrorOrAccessRuleViolation
    PG::UnableToSend
    PG::UndefinedColumn
    PG::UndefinedFunction
    PG::UndefinedObject
    PG::UndefinedTable
    PG::UniqueViolation
    ActiveModel::MissingAttributeError
    ActiveModel::UnknownAttributeError
    ActiveModel::ValidationError
    ActiveRecord::ActiveRecordError
    ActiveRecord::AdapterNotSpecified
    ActiveRecord::ConfigurationError
    ActiveRecord::ConnectionNotEstablished
    ActiveRecord::ConnectionTimeoutError
    ActiveRecord::Deadlocked
    ActiveRecord::EnvironmentMismatchError
    ActiveRecord::IrreversibleOrderError
    ActiveRecord::LockWaitTimeout
    ActiveRecord::MissingAttributeError
    ActiveRecord::NoDatabaseError
    ActiveRecord::PendingMigrationError
    ActiveRecord::PreparedStatementCacheExpired
    ActiveRecord::QueryCanceled
    ActiveRecord::ReadOnlyError
    ActiveRecord::ReadOnlyRecord
    ActiveRecord::RecordInvalid
    ActiveRecord::RecordNotFound
    ActiveRecord::RecordNotSaved
    ActiveRecord::RecordNotUnique
    ActiveRecord::SerializationTypeMismatch
    ActiveRecord::SoleRecordExceeded
    ActiveRecord::StatementInvalid
    ActiveRecord::StatementTimeout
    ActiveRecord::TransactionIsolationError
    ActiveRecord::UnknownAttributeError
    ActiveRecord::UnknownPrimaryKey
    ActiveRecord::ValueTooLong
  ].freeze

  SHIPPED_FILES = {
    "merge_validate.rb" => "validation_runner",
    "merge_validation_config.rb" => "validation_config",
    "merge_contract.rb" => "contract",
    "merge_refusal.rb" => "contract",
    "merge_validation_diagnostic.rb" => "contract",
    "merge_adapter.rb" => "asset_adapter",
    "merge_assets.rb" => "asset_adapter",
    "merge_asset_references.rb" => "asset_references",
    "merge_baseline_assets.rb" => "baseline_assets"
  }.freeze

  STOCK_RUNTIME_PREFIXES = %w[
    /var/www/discourse/
    /gems/
    /usr/local/lib/ruby/
    /usr/lib/ruby/
    /usr/local/bundle/
    <internal:
  ].freeze

  STDLIB_WRAPPER_PREFIXES = %w[
    <internal:
    /usr/local/lib/ruby/
    /usr/lib/ruby/
  ].freeze

  INTERNAL_RAISE_LABELS = %w[refuse! refuse fail!].freeze

  class Error < StandardError
    def initialize = super("MERGE_VALIDATION_DIAGNOSTIC_INVALID")
  end

  module_function

  def raw_class_name(error)
    return nil unless error
    name = error.class.name
    name if name.is_a?(String) && name.bytesize <= 256 && name.ascii_only?
  rescue Exception
    nil
  end

  def classify_error_class(error)
    return "none" if error.nil?
    name = raw_class_name(error)
    return "other" unless name && name != "none"
    if name.start_with?("ActiveRecord::") && ERROR_CLASSES.include?(name)
      seen = { error.object_id => true }
      current = error
      MAX_CAUSE_DEPTH.times do
        cause = current.respond_to?(:cause) ? current.cause : nil
        break if cause.nil? || seen[cause.object_id]
        seen[cause.object_id] = true
        if defined?(SiloMergeValidationConfig::Refused) && cause.is_a?(SiloMergeValidationConfig::Refused)
          nested = validate!(cause.guest_diagnostic).fetch("error_class")
          return nested if ERROR_CLASSES.include?(nested) && !%w[none other].include?(nested)
        end
        cause_name = raw_class_name(cause)
        if cause_name && cause_name.start_with?("PG::") && ERROR_CLASSES.include?(cause_name)
          return cause_name
        end
        current = cause
      end
      return name
    end
    ERROR_CLASSES.include?(name) ? name : "other"
  rescue Exception
    "other"
  end

  def shipped_directory?(dir)
    return false unless dir.is_a?(String)
    return true if [".", "/tmp", File.expand_path(__dir__), File.expand_path("../prebuilt-discourse", __dir__)].include?(dir)
    return true if dir.match?(/\A\/shared\/silo-validation-[0-9a-f]{32}\z/)
    dir.end_with?("/runtime/shared", "/runtime/prebuilt-discourse") ||
      dir == "runtime/shared" || dir == "runtime/prebuilt-discourse"
  end

  def classify_path(raw_path)
    return "unknown" unless raw_path.is_a?(String) && raw_path.valid_encoding? && !raw_path.empty? && raw_path.bytesize <= 4096 && !raw_path.match?(/[[:cntrl:]]/)
    path = raw_path.tr("\\", "/")
    return "custom_layer" if path.match?(/(?:\A|\/)layer\/[^\/]/)
    basename = File.basename(path)
    if SHIPPED_FILES.key?(basename) && shipped_directory?(File.dirname(path))
      return SHIPPED_FILES.fetch(basename)
    end
    return "stock_runtime" if STOCK_RUNTIME_PREFIXES.any? { |prefix| path.start_with?(prefix) }
    "unknown"
  rescue Exception
    "unknown"
  end

  def extract_frames(error)
    return [] unless error
    if error.respond_to?(:backtrace_locations)
      locations = error.backtrace_locations
      if locations.is_a?(Array) && !locations.empty?
        return locations.first(8).filter_map do |loc|
          path = loc.respond_to?(:path) ? loc.path : nil
          lineno = loc.respond_to?(:lineno) ? loc.lineno : nil
          label = loc.respond_to?(:base_label) ? loc.base_label : (loc.respond_to?(:label) ? loc.label : nil)
          [path, lineno, label] if path.is_a?(String)
        end
      end
    end
    if error.respond_to?(:backtrace)
      trace = error.backtrace
      if trace.is_a?(Array) && !trace.empty?
        return trace.first(8).filter_map do |entry|
          next unless entry.is_a?(String) && entry.valid_encoding? && entry.bytesize <= 4096
          match = /\A(.+):([0-9]+)(?::in\s+`?([^']+)'?)?\z/.match(entry)
          [match[1], match[2].to_i, match[3]] if match
        end
      end
    end
    []
  rescue Exception
    []
  end

  def classify_location(error, stage)
    if error.nil?
      return [stage == "bootstrap" ? "validation_config" : "validation_runner", nil]
    end
    frames = extract_frames(error)
    return ["unknown", nil] if frames.empty?
    if frames.any? { |path, _, _| STDLIB_WRAPPER_PREFIXES.none? { |prefix| path.start_with?(prefix) } }
      frames = frames.drop_while { |path, _, _| STDLIB_WRAPPER_PREFIXES.any? { |prefix| path.start_with?(prefix) } }
    end
    first_path, first_lineno, first_label = frames.first
    component = classify_path(first_path)
    lineno = first_lineno
    if INTERNAL_RAISE_LABELS.include?(first_label.to_s) && frames[1]
      second_component = classify_path(frames[1][0])
      if second_component == component
        lineno = frames[1][1]
      end
    end
    line = if LINE_COMPONENTS.include?(component) && lineno.is_a?(Integer) && lineno.between?(1, MAX_LINE)
      lineno
    end
    [component, line]
  rescue Exception
    ["unknown", nil]
  end

  def capture(stage:, error: nil)
    if defined?(SiloMergeValidationConfig::Refused) && error.is_a?(SiloMergeValidationConfig::Refused)
      validated = validate!(error.guest_diagnostic)
      return STAGES.include?(stage) ? validated.merge("stage" => stage) : validated.dup
    end
    normalized_stage = STAGES.include?(stage) ? stage : "context"
    error_class = classify_error_class(error)
    component, line = classify_location(error, normalized_stage)
    {
      "version" => 1,
      "stage" => normalized_stage,
      "error_class" => error_class,
      "component" => component,
      "line" => line
    }
  rescue Exception
    {
      "version" => 1,
      "stage" => "context",
      "error_class" => "other",
      "component" => "unknown",
      "line" => nil
    }
  end

  def validate!(value)
    SiloMergeContract.tree!(value)
    raise Error unless value.is_a?(Hash) && value.keys.sort == FIELDS.sort &&
      value["version"].is_a?(Integer) && value["version"] == 1 &&
      STAGES.include?(value["stage"]) &&
      ERROR_CLASSES.include?(value["error_class"]) &&
      COMPONENTS.include?(value["component"])
    line = value["line"]
    raise Error unless line.nil? || (line.is_a?(Integer) && line.between?(1, MAX_LINE))
    raise Error if %w[custom_layer unknown].include?(value["component"]) && !line.nil?
    raise Error if JSON.generate(value).bytesize > MAX_BYTES
    value
  rescue Exception
    raise Error, cause: nil
  end
end
