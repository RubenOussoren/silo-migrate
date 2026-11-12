# frozen_string_literal: true

# Cross-language contract check (driven by test/intake_preparation_test.py, opt-in):
# the plan documents the Python data adapter writes for --run-inputs/--preparation must
# be accepted by the Ruby plan backend's own validators, against the same workspace's
# registry files. Only what isn't the adapter's contract is stubbed: the converter's
# settings template lookup (git) and the delivery record lookup (read from the
# workspace's deliveries.json). Prints the bound documents as JSON; exits 1 with the
# backend's refusal code/detail otherwise.
#
#   ruby run_inputs_contract.rb REPO WORKSPACE DOCUMENTS.json
require "json"

repo, workspace, documents = ARGV
$LOAD_PATH.unshift(File.join(repo, "lib"))
require "silo_migrate/errors"
require "silo_migrate/named_workspace_store"
require "silo_migrate/standard_store"
require "silo_migrate/file_role_store"
require "silo_migrate/services/standard_run_inputs"

class RunInputsContract
  include SiloMigrate::Services::StandardRunInputs

  Store = Struct.new(:named_state)

  def initialize(workspace)
    @workspace = workspace
    @store = Store.new(JSON.parse(File.read(File.join(workspace, ".silo-migrate/named/state.json"))))
  end

  def file_roles
    SiloMigrate::FileRoleStore.new(@workspace)
  end

  # The converter's own settings contract is checked against its committed template in the
  # real backend; it is not part of what the data adapter produces.
  def consumer_setting!(*); end

  def delivery_record!(dataset)
    path = File.join(@workspace, ".silo-migrate/named/deliveries.json")
    record = File.file?(path) && JSON.parse(File.read(path)).dig("deliveries", dataset)
    raise SiloMigrate::StandardWorkflowError, "STANDARD_DELIVERY_UNLABELLED" unless record

    record
  end

  def check(documents, source_id, platform)
    named = @store.named_state
    source = named.fetch("inputs").fetch(source_id)
    delivery = delivery_record!(source.fetch("dataset_id"))
    result = {}
    if documents["run_inputs"]
      result["run_inputs"] = run_inputs_binding!(documents["run_inputs"], named: named, roles: { "source" => source_id }, source: source,
                                                 platform: platform, delivery: delivery, config: {})
    end
    if documents["preparation"]
      result["preparation"] = preparation_binding!(documents["preparation"], roles: { "source" => source_id, "settings" => "settings" },
                                                   run_inputs: result["run_inputs"], code_readiness: { "kind" => "converter", "present" => false })
    end
    result
  end
end

begin
  input = JSON.parse(File.read(documents))
  puts JSON.generate(RunInputsContract.new(workspace).check(input.fetch("documents"), input.fetch("source"), input.fetch("platform")))
rescue SiloMigrate::StandardWorkflowError => error
  warn "Error: #{error.code}: #{error.message}"
  exit 1
end
