# frozen_string_literal: true

# Child-process stand-in for ONLY the process bridge. Actual contract/transfer
# protocols have their own tests; this isolates runner ordering/settings guards.
$LOADED_FEATURES << File.expand_path("../../runtime/prebuilt-discourse/merge_process_run.rb", __dir__)
module SiloMergeProcessRuntime
  module_function
  def load_contract = { "test_only" => true }
  def prepare(*)
    puts "EVENT:process-preflight"
    SiteSetting.authorized_extensions = "jpg|jpeg|png|gif" if ENV["TEST_PROCESS_WRITE"] == "preflight"
    Object.new
  end
  def transfer(*)
    puts "EVENT:process-transfer"
  end
  def finish(*)
    puts "EVENT:process-postflight"
    SiteSetting.authorized_extensions = "jpg|jpeg|png|gif" if ENV["TEST_PROCESS_WRITE"] == "postflight"
  end
end
