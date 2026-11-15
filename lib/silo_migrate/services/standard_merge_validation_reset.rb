# frozen_string_literal: true

module SiloMigrate
  module Services
    # Retire an unresolved v1 attempt ONLY by destroying its entire prepared
    # execution domain. Never infer producer completion or drop scratch SQL in
    # place. The original receipt/journal remain byte-identical.
    module StandardMergeValidationReset
      RESET_KIND = "legacy_validation_reset"
      RESET_CONTAINER_FORMAT = '{"id":{{json .Id}},"name":{{json .Name}},"created":{{json .Created}},"started":{{json .State.StartedAt}},"labels":{{json .Config.Labels}},"mounts":{{json .Mounts}}}'.freeze
      RESET_NETWORK_FORMAT = '{"id":{{json .Id}},"name":{{json .Name}},"created":{{json .Created}},"labels":{{json .Labels}},"containers":{{json .Containers}}}'.freeze
      RESET_VOLUME_FORMAT = '{"name":{{json .Name}},"created":{{json .CreatedAt}},"driver":{{json .Driver}},"options":{{json .Options}},"labels":{{json .Labels}}}'.freeze

      def merge_validation_reset_preview(attempt_id:)
        mr_id!(attempt_id)
        @store.with_read_only_execution_locks do
          if File.exist?(mv_path(attempt_id, "reset-retirement.json"))
            mr_refuse! unless mr_retired!(attempt_id)
            retirement = mr_read_json!(mv_path(attempt_id, "reset-retirement.json"))
            return mr_projection(mr_read_intent!(attempt_id, retirement.fetch("intent_sha256")), retired: true)
          end
          intent = mr_existing_intent(attempt_id) || mr_review!(attempt_id)
          mr_resume_check!(intent) if File.exist?(mr_intent_path(attempt_id, mr_digest(intent)))
          mr_projection(intent)
        end
      rescue StandardWorkflowError
        raise
      rescue StandardError
        mr_refuse!
      end

      def merge_validation_reset_apply(attempt_id:, intent_sha256:, yes: false)
        mr_id!(attempt_id)
        mr_refuse!("STANDARD_CONFIRMATION_REQUIRED") unless yes
        mr_refuse!("STANDARD_ARGUMENTS_INVALID") unless intent_sha256.is_a?(String) && StandardMergeValidation::VALIDATION_SHA.match?(intent_sha256)
        @store.with_host_lock do
          @store.with_op_lock do
            if File.exist?(mv_path(attempt_id, "reset-retirement.json"))
              mr_refuse! unless mr_retired!(attempt_id, expected_digest: intent_sha256)
              return mr_projection(mr_read_intent!(attempt_id, intent_sha256), retired: true)
            end
            intent = mr_existing_intent(attempt_id) || mr_review!(attempt_id)
            mr_refuse!("STANDARD_MERGE_RESET_INTENT_STALE") unless mr_digest(intent) == intent_sha256
            mr_write_once!(mr_intent_path(attempt_id, intent_sha256), intent)
            mr_resume_check!(intent)
            # Both execution locks are already held. Use the same reset lifecycle
            # as ordinary reset, without recursive op locking or automatic Prepare.
            reset_run_locked(intent.fetch("prepared_from"))
            mr_binding!(intent, reset: true)
            mr_absent!(intent)
            mr_refuse!("STANDARD_MERGE_RESET_WORK_UNSAVED") unless mr_persistent_work!(intent.fetch("settings")) == intent.fetch("persistent_work")
            retirement = { "version" => 1, "kind" => RESET_KIND, "attempt_id" => attempt_id,
              "intent_sha256" => intent_sha256, "prepared_from" => intent.fetch("prepared_from"),
              "generation" => intent.fetch("generation"), "state" => "reset_retired",
              "historical_producer" => "unproven" }
            mr_write_once!(mv_path(attempt_id, "reset-retirement.json"), retirement)
            mr_refuse! unless mr_retired!(attempt_id, expected_digest: intent_sha256)
            mr_projection(intent, retired: true)
          end
        end
      rescue StandardWorkflowError
        raise
      rescue StandardError
        mr_refuse!
      end

      private

      def mr_refuse!(code = "STANDARD_MERGE_RESET_UNPROVEN")
        raise StandardWorkflowError, code, cause: nil
      end

      def mr_id!(id)
        mr_refuse!("STANDARD_ARGUMENTS_INVALID") unless id.is_a?(String) && StandardMergeValidation::VALIDATION_ID.match?(id)
      end

      def mr_digest(value)
        sort = lambda do |item|
          case item
          when Hash then item.keys.sort.to_h { |key| [key, sort.call(item.fetch(key))] }
          when Array then item.map { |child| sort.call(child) }
          else item
          end
        end
        Digest::SHA256.hexdigest(JSON.generate(sort.call(value)))
      end

      def mr_records!(id)
        mr_id!(id)
        mv_saved_directory!(File.join(@store.root, "validations"))
        receipt, receipt_state = mv_saved_record(id, "json")
        journal, journal_state = mv_saved_record(id, "resources.json")
        mr_refuse! unless receipt_state == "saved" && journal_state == "saved" && journal["version"] == 1 &&
          journal["cleanup_confirmed"] == false && receipt["prepared_from"] == journal["prepared_from"] &&
          receipt["generation"] == journal["generation"] && receipt["templates"] == journal["templates"]
        [receipt, journal]
      end

      def mr_record_binding!(id)
        receipt, journal = mr_records!(id)
        { "attempt_id" => id, "prepared_from" => journal.fetch("prepared_from"), "generation" => journal.fetch("generation"),
          "settings" => receipt.fetch("settings"),
          "receipt_sha256" => Digest::SHA256.hexdigest(mv_recovery_read!(mv_path(id, "json"), 4 * 1024 * 1024)),
          "journal_sha256" => Digest::SHA256.hexdigest(mv_recovery_read!(mv_path(id, "resources.json"), 64 * 1024)) }
      end

      def mr_binding!(intent, reset: false)
        mr_refuse! unless mr_record_binding!(intent.fetch("attempt_id")) == intent.slice("attempt_id", "prepared_from", "generation", "settings", "receipt_sha256", "journal_sha256")
        id, generation = intent.values_at("prepared_from", "generation")
        mr_refuse! unless id.is_a?(String) && id.match?(/\Arun-[0-9a-f]{32}\z/) && generation.is_a?(String) && StandardMergeValidation::VALIDATION_SHA.match?(generation)
        state = @store.load
        run = state.fetch("runs").fetch(id)
        environment = run.fetch("merge_environment")
        mr_refuse! unless run["status"] == "completed" && environment["preparation_run_id"] == id &&
          environment["generation"] == generation && environment["consumed_by"].nil? &&
          (reset ? environment["phase"] == "reset" : %w[ready reset].include?(environment["phase"])) &&
          state.fetch("plans").fetch(run.fetch("plan_id")).dig("body", "operation") == "standard_merge_prepare"
        name = run.fetch("instances").fetch("review")
        mr_refuse! unless run.fetch("instances").keys == ["review"] && environment["instance"] == name
        record = state.fetch("instances").fetch(name)
        mr_refuse! unless environment["containers"] == record["containers"]
        compact = record.slice("name", "containers", "networks", "volumes")
        mr_refuse! if intent["instance"] && compact != intent["instance"]
        mr_refuse! unless !reset || record["state"] == "removed"
        [state, compact]
      end

      def mr_persistent_work!(settings)
        mr_refuse!("STANDARD_MERGE_RESET_WORK_UNSAVED") unless settings.is_a?(String) && settings.match?(/\Ainput-[0-9a-f]{32}\z/)
        assert_merger_store!
        head = merger_head
        mr_refuse!("STANDARD_MERGE_RESET_WORK_UNSAVED") unless head && !merger_dirty?
        named = @store.named_state
        inputs = named.fetch("inputs")
        mr_refuse!("STANDARD_MERGE_RESET_WORK_UNSAVED") unless inputs.fetch(settings)["type"] == "merge-settings"
        inputs.each_value { |input| @store.named.verify_input_identity(input) }
        { "merger_commit" => head, "inputs_sha256" => @store.named.input_binding(named, inputs.keys.sort),
          "registry_sha256" => mr_digest(named) }
      rescue StandardError
        mr_refuse!("STANDARD_MERGE_RESET_WORK_UNSAVED")
      end

      def mr_run(argv, seconds = 20)
        result = @runtime.run(argv, capture: true, timeout: seconds)
        mr_refuse! unless result.success?
        mr_refuse! unless result.stdout.to_s.bytesize <= 256 * 1024
        result.stdout.to_s
      end

      def mr_list(kind, filter)
        format = kind == "volume" ? "{{.Name}}" : "{{.ID}}"
        command = ["docker", kind, "ls", *(kind == "container" ? ["-a"] : []), *(kind == "volume" ? [] : ["--no-trunc"]), "--format", format, "--filter", filter]
        values = mr_run(command).split
        mr_refuse! unless values.size <= 128 && values.uniq.size == values.size
        values.sort
      end

      def mr_metadata(kind, identity)
        format = { "container" => RESET_CONTAINER_FORMAT, "network" => RESET_NETWORK_FORMAT, "volume" => RESET_VOLUME_FORMAT }.fetch(kind)
        value = JSON.parse(mr_run(["docker", kind, "inspect", "--format", format, identity]))
        mr_refuse! unless value.is_a?(Hash)
        value
      end

      def mr_daemon
        id = mr_run(["docker", "info", "--format", "{{.ID}}"], 15).strip
        mr_refuse! unless id.match?(/\A[A-Za-z0-9:._-]{8,128}\z/)
        id
      end

      def mr_auxiliary_absent!(intent)
        id = intent.fetch("attempt_id")
        # No adoption or stopping of an attempt sidecar/host credential directory.
        mr_refuse!("STANDARD_MERGE_RESET_AUXILIARY_PRESENT") unless
          mr_list("container", "name=^/silo-val-redis-#{id}$").empty? &&
          mr_list("container", "label=silo-migrate.validation=#{id}").empty?
        begin
          File.lstat(File.join(@store.root, "validations", id))
          mr_refuse!("STANDARD_MERGE_RESET_AUXILIARY_PRESENT")
        rescue Errno::ENOENT
          nil
        end
      end

      def mr_inspection_ids(intent)
        id = intent.fetch("prepared_from")
        result = mr_run(["docker", "ps", "-aq", "--no-trunc", "--filter", "label=silo.merge-run=#{id}", "--filter", "label=silo.workspace=#{@workspace}"]).split.sort
        mr_refuse! unless result.size <= 128 && result.uniq == result && result.all? { |value| StandardMergeValidation::VALIDATION_SHA.match?(value) }
        result.each do |container|
          labels = mr_metadata("container", container).fetch("labels")
          mr_refuse! unless labels.is_a?(Hash) && labels["silo.merge-run"] == id && labels["silo.workspace"] == @workspace &&
            %w[merge-mcp merge-dbhub].include?(labels["silo.role"])
        end
        result
      end

      def mr_snapshot!(intent, resuming: false)
        instance = intent.fetch("instance")
        name = instance.fetch("name")
        mr_refuse! unless name.is_a?(String) && name.match?(/\Asilomig-[a-z0-9-]{1,110}\z/) &&
          instance.fetch("containers").keys.sort == %w[db proxy redis web] &&
          instance.fetch("networks").sort == ["#{name}-int", "#{name}-pub"] &&
          instance.fetch("volumes").sort == %w[pg redis shared].map { |suffix| "#{name}-#{suffix}" }.sort
        saved = intent["runtime"]
        daemon = mr_daemon
        mr_refuse! if saved && saved["daemon_id"] != daemon
        leases = mr_inspection_ids(intent)
        mr_refuse! if saved && (leases - saved.fetch("inspection_ids")).any?
        resources = {}
        %w[container network volume].each do |kind|
          identities = kind == "container" ? instance.fetch("containers").values : instance.fetch("#{kind}s")
          identities.sort.each do |identity|
            mr_refuse! unless identity.is_a?(String) && (kind == "container" ? StandardMergeValidation::VALIDATION_SHA.match?(identity) : identity.start_with?(name + "-"))
            found = mr_list(kind, kind == "container" ? "id=#{identity}" : "name=^#{Regexp.escape(identity)}$")
            key = "#{kind}:#{identity}"
            if found.empty?
              mr_refuse! unless resuming && saved && saved.fetch("resources").key?(key)
              if kind == "container"
                role = instance.fetch("containers").key(identity)
                mr_refuse! unless mr_list("container", "name=^/#{name}-#{role}$").empty?
              end
              next
            end
            mr_refuse! unless found.size == 1 && (kind != "container" || found.first == identity)
            metadata = mr_metadata(kind, identity)
            labels = metadata.fetch("labels")
            mr_refuse! unless labels.is_a?(Hash) && labels["silo-migrate.managed"] == "true" &&
              labels["silo-migrate.instance"] == name && labels["silo-migrate.run"] == intent.fetch("prepared_from")
            mr_refuse! unless metadata["created"].is_a?(String) && metadata["created"].match?(/\A[0-9TZ:.+-]{10,64}\z/)
            if kind == "container"
              mr_refuse! unless metadata["started"].is_a?(String) && metadata["started"].match?(/\A[0-9TZ:.+-]{10,64}\z/)
              role = instance.fetch("containers").key(identity)
              mr_refuse! unless metadata["id"] == identity && metadata["name"] == "/#{name}-#{role}"
              mounts = metadata.fetch("mounts")
              mr_refuse! unless mounts.is_a?(Array) && mounts.all? { |mount| %w[volume tmpfs].include?(mount["Type"]) }
              expected = { "db" => ["#{name}-pg"], "redis" => ["#{name}-redis"], "web" => ["#{name}-shared"], "proxy" => [] }.fetch(role)
              mr_refuse! unless mounts.select { |mount| mount["Type"] == "volume" }.map { |mount| mount["Name"] }.sort == expected
            elsif kind == "network"
              mr_refuse! unless metadata["name"] == identity && StandardMergeValidation::VALIDATION_SHA.match?(metadata.fetch("id"))
              mr_refuse! unless metadata["containers"].is_a?(Hash) &&
                (metadata["containers"].keys - instance.fetch("containers").values - leases).empty?
            else
              mr_refuse! unless metadata["name"] == identity && metadata["driver"] == "local" && [nil, {}].include?(metadata["options"])
              mr_refuse! unless (mr_list("container", "volume=#{identity}") - instance.fetch("containers").values).empty?
            end
            mr_refuse! if saved && saved.fetch("resources")[key].reject { |field, _| field == "containers" } != metadata.reject { |field, _| field == "containers" }
            resources[key] = metadata
          end
          listed = mr_list(kind, "label=silo-migrate.run=#{intent.fetch('prepared_from')}")
          expected = kind == "container" ? instance.fetch("containers").values : kind == "network" ? resources.select { |key, _| key.start_with?("network:") }.values.map { |value| value.fetch("id") } : instance.fetch("volumes")
          mr_refuse! unless (listed - expected).empty?
        end
        mr_auxiliary_absent!(intent)
        { "daemon_id" => daemon, "inspection_ids" => leases, "resources" => resources }
      end

      def mr_review!(id)
        intent = { "version" => 1, "kind" => RESET_KIND }.merge(mr_record_binding!(id))
        state, instance = mr_binding!(intent)
        mr_refuse! unless state.fetch("runs").fetch(intent.fetch("prepared_from")).dig("merge_environment", "phase") == "ready"
        mr_refuse! if state.fetch("runs").values.any? { |run| %w[claimed running].include?(run["status"]) }
        intent["instance"] = instance
        intent["persistent_work"] = mr_persistent_work!(intent.fetch("settings"))
        intent["runtime"] = mr_snapshot!(intent)
        mr_other_journals!(id)
        intent
      end

      def mr_resume_check!(intent)
        state, = mr_binding!(intent)
        mr_refuse! if state.fetch("runs").values.any? { |run| %w[claimed running].include?(run["status"]) }
        mr_refuse!("STANDARD_MERGE_RESET_WORK_UNSAVED") unless mr_persistent_work!(intent.fetch("settings")) == intent.fetch("persistent_work")
        mr_other_journals!(intent.fetch("attempt_id"))
        mr_snapshot!(intent, resuming: true)
      end

      def mr_other_journals!(id)
        paths = Dir.glob(File.join(@store.root, "validations", "*.resources.json"))
        mr_refuse! if paths.size > 4096
        paths.each do |path|
          other = File.basename(path).delete_suffix(".resources.json")
          next if other == id
          _, journal = mr_records_for_gate!(other)
          mr_refuse! unless (journal["status"] == "cleaned" && journal["cleanup_confirmed"] == true) || mr_retired!(other)
        end
      end

      def mr_absent!(intent)
        mr_refuse! unless mr_daemon == intent.fetch("runtime").fetch("daemon_id")
        instance = intent.fetch("instance")
        instance.fetch("containers").each do |role, id|
          mr_refuse! unless mr_list("container", "id=#{id}").empty? && mr_list("container", "name=^/#{instance.fetch('name')}-#{role}$").empty?
        end
        %w[network volume].each do |kind|
          instance.fetch("#{kind}s").each { |name| mr_refuse! unless mr_list(kind, "name=^#{Regexp.escape(name)}$").empty? }
        end
        %w[container network volume].each { |kind| mr_refuse! unless mr_list(kind, "label=silo-migrate.run=#{intent.fetch('prepared_from')}").empty? }
        mr_refuse! unless mr_inspection_ids(intent).empty?
        mr_auxiliary_absent!(intent)
      end

      def mr_intent_path(id, digest) = mv_path(id, "reset-#{digest}.intent.json")

      def mr_read_json!(path)
        value = JSON.parse(mv_recovery_read!(path, 256 * 1024))
        mr_refuse! unless value.is_a?(Hash)
        value
      end

      def mr_read_intent!(id, digest)
        value = mr_read_json!(mr_intent_path(id, digest))
        mr_refuse! unless value["version"] == 1 && value["kind"] == RESET_KIND && value["attempt_id"] == id && mr_digest(value) == digest
        instance = value.fetch("instance")
        resources = value.fetch("runtime").fetch("resources")
        expected = instance.fetch("containers").values.map { |name| "container:#{name}" } +
          instance.fetch("networks").map { |name| "network:#{name}" } + instance.fetch("volumes").map { |name| "volume:#{name}" }
        mr_refuse! unless instance.fetch("containers").keys.sort == %w[db proxy redis web] && expected.size == 9 &&
          resources.is_a?(Hash) && resources.keys.sort == expected.sort && resources.values.all? { |item| item.is_a?(Hash) }
        value
      end

      def mr_existing_intent(id)
        paths = Dir.glob(mv_path(id, "reset-*.intent.json"))
        return nil if paths.empty?
        mr_refuse! unless paths.size == 1
        match = /\.reset-([0-9a-f]{64})\.intent\.json\z/.match(paths.first)
        mr_refuse! unless match
        mr_read_intent!(id, match[1])
      end

      def mr_write_once!(path, value)
        bytes = JSON.generate(value) + "\n"
        mr_refuse! if bytes.bytesize > 256 * 1024
        temporary = "#{path}.#{SecureRandom.hex(16)}.tmp"
        begin
          mv_raw_write!(temporary, bytes)
          begin
            File.link(temporary, path)
          rescue Errno::EEXIST
            nil
          end
          mr_refuse! unless mv_recovery_read!(path, 256 * 1024) == bytes
          File.open(File.dirname(path), File::RDONLY) { |directory| directory.fsync }
        ensure
          File.unlink(temporary) if File.exist?(temporary)
        end
      end

      def mr_records_for_gate!(id)
        mr_id!(id)
        receipt, = mv_saved_record(id, "json")
        journal, status = mv_saved_record(id, "resources.json")
        mr_refuse! unless status == "saved"
        [receipt, journal]
      end

      def mr_retired!(id, expected_digest: nil, live: true)
        return false unless File.exist?(mv_path(id, "reset-retirement.json")) || File.symlink?(mv_path(id, "reset-retirement.json"))
        retirement = mr_read_json!(mv_path(id, "reset-retirement.json"))
        digest = retirement.fetch("intent_sha256")
        mr_refuse! unless digest.is_a?(String) && StandardMergeValidation::VALIDATION_SHA.match?(digest) && (!expected_digest || digest == expected_digest)
        intent = mr_existing_intent(id)
        mr_refuse! unless intent && mr_digest(intent) == digest
        expected = { "version" => 1, "kind" => RESET_KIND, "attempt_id" => id, "intent_sha256" => digest,
          "prepared_from" => intent.fetch("prepared_from"), "generation" => intent.fetch("generation"),
          "state" => "reset_retired", "historical_producer" => "unproven" }
        mr_refuse! unless retirement == expected
        mr_binding!(intent, reset: true)
        mr_absent!(intent) if live
        true
      end

      def mr_projection(intent, retired: false)
        { "version" => 1, "attempt_id" => intent.fetch("attempt_id"), "prepared_from" => intent.fetch("prepared_from"),
          "generation" => intent.fetch("generation"), "intent_sha256" => mr_digest(intent), "status" => retired ? "reset_retired" : "preview",
          "actions" => %w[fence_inspection remove_preparation_stack verify_runtime_absence retire_legacy_quarantine],
          "persistent_work" => { "merger_commit" => intent.fetch("persistent_work").fetch("merger_commit"), "registered_inputs" => "verified" },
          "historical_producer" => "unproven", "next_action" => retired ? "prepare_new_environment" : "review_reset_scope_before_apply" }
      end
    end
  end
end
