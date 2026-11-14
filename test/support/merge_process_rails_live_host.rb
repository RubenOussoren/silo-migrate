# frozen_string_literal: true

# Local fixture transport for the production provisioning SQL. The lifecycle's
# host locks, custody journal and preclaim/receipt gate are NOT exercised here.
require "json"
require "tmpdir"
require "fileutils"
require "ostruct"
require_relative "../../lib/silo_migrate/named_workspace_store"
require_relative "../../lib/silo_migrate/standard_store"
require_relative "../../lib/silo_migrate/services/standard_merge_validation"
class LiveProvision
  include SiloMigrate::Services::StandardMergeValidation
  def initialize(spec)
    @spec = spec
  end
  def mv_write!(*); end
  def mv_path(*); "fixture-only"; end
  def mv_error!(_code); raise "provision_refused"; end
  def mv_sql!(_context, sql, database: "postgres")
    STDOUT.puts(JSON.generate("sql" => sql, "database" => database))
    STDOUT.flush
    response = JSON.parse(STDIN.readline)
    raise "sql_refused" unless response.fetch("ok")
    response.fetch("out")
  end
end
class LiveRefusalStore
  def initialize(root) = @root = root
  def run_dir(run, *parts) = File.join(@root, run, *parts)
  def write_private(path, bytes)
    FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
    File.write(path, bytes, mode: "wb", perm: 0o600)
  end
end

begin
  spec = JSON.parse(File.read(ARGV.fetch(0)))
  if spec.fetch("action") == "provision"
    adapter = LiveProvision.new(spec)
    journal = spec.fetch("journal")
    journal["templates"] = adapter.send(:mv_custody!, {})
    adapter.send(:mv_provision!, {}, journal, spec.fetch("password"))
  elsif spec.fetch("action") == "refusal"
    require_relative "../../lib/silo_migrate/services/standard_merge_process"
    Dir.mktmpdir("refusal-collector-") do |root|
      host = Object.new.extend(SiloMigrate::Services::StandardMergeProcess)
      store = LiveRefusalStore.new(root)
      host.instance_variable_set(:@store, store)
      host.define_singleton_method(:plan_for) do |*|
        { "body" => { "merge" => { "process" => { "engine" => "discourse-merger-v1", "physical_policy" => "carried" },
                                   "contract" => spec.fetch("contract") } } }
      end
      result = OpenStruct.new(success?: false, stdout: spec.fetch("output"))
      host.merge_process_collect!("invented", Object.new, result)
      evidence = host.merge_process_evidence("invented")
      unless evidence["available"] == true && evidence["complete"] == false &&
             evidence.dig("audit_aggregates", "preflight", "refused_policy") == 1 &&
             evidence.dig("failure", "write_boundary") == "before_constructor"
        raise "refusal_evidence_unproven"
      end
      path = store.run_dir("invented", "private", "merge-refusal.json")
      raise "refusal_receipt_missing" unless File.file?(path) && (File.stat(path).mode & 0o077).zero?
    end
  else
    require_relative "../../lib/silo_migrate/merge_process"
    require_relative "../../lib/silo_migrate/services/discourse_archive"
    require_relative "../../lib/silo_migrate/errors"
    checker = Object.new.extend(SiloMigrate::Services::DiscourseArchive)
    checked = checker.send(:validate_full_archive!, spec.fetch("archive"), spec.fetch("required"))
    valid = SiloMigrate::MergeProcess::Gate.new(SiloMigrate::MergeProcess.registry).verify_output(
      engine: "discourse-merger-v1", context: { upload_sha256: checked.fetch("upload_sha256"), baseline_assets: spec.fetch("baseline") },
      manifest: spec.fetch("manifest"))
    raise "output_refused" unless valid
    raise "negative_archive_accepted" if spec["expected_refusal"]
  end
  puts "LIVE:host_ok"
rescue Exception => error
  if spec && spec["expected_refusal"] && error.class.name == spec["expected_refusal"]
    puts "LIVE:host_ok"
    exit 0
  end
  puts "LIVE:host_error_class=#{error.class.name}"
  puts "LIVE:host_source_lines=" + JSON.generate(error.backtrace_locations.first(5).map { |loc| [File.basename(loc.path), loc.lineno] })
  exit 9
end
