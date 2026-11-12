# frozen_string_literal: true

require "digest"
require "fileutils"
require "json"
require "yaml"

module SiloMigrate
  module Services
    # Two thin, optional additions to a plan body, both covered by the one plan digest:
    #
    # * run_inputs (convert plans): a manifest of already-registered named inputs that the
    #   pinned converter reads from one settings-named directory (for example Khoros'
    #   mappings.directory). Silo binds logical names, IDs, hashes, sizes, lineage and the
    #   applicable source snapshot; it never interprets the files. The converter's own
    #   parser validates their content at run time. Each run gets a fresh real copy (never
    #   a hardlink, never another run's directory); afterwards every change is checked
    #   against the declared contract and captured as private evidence.
    # * preparation (convert and merge plans): labelled analyst review metadata. Material
    #   questions must be resolved or explicitly excluded/narrowed; code readiness is
    #   computed from the plan's actual pinned consumer, not taken from the metadata.
    #
    # Neither is a DSL: nothing in either document is executed. Plans without them keep
    # exactly their previous body, digest and behavior.
    module StandardRunInputs
      RUN_INPUTS_VERSION = 1
      PREPARATION_VERSION = 1
      RUN_INPUT_TYPES = %w[run-input mapping].freeze
      RUN_INPUTS_MOUNT = "/run-inputs"
      RUN_INPUTS_PLACEHOLDER = "SILO_RUN_INPUTS_DIR"
      MAX_DOCUMENT_BYTES = 64 * 1024
      MAX_FILES = 256
      MAX_NAMES = 64
      MAX_ITEMS = 128
      MAX_REFERENCES = 32
      MAX_CAPTURED_NODES = 1024
      MAX_DEPTH = 4
      MAX_GENERATED_BYTES = 16 * 1024 * 1024
      NAME_SEGMENT = /\A[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}\z/
      SETTING = /\A[a-z_][a-z0-9_]{0,63}(?:\.[a-z_][a-z0-9_]{0,63}){0,7}\z/
      TOKEN = /\A[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}\z/
      ITEM_ID = /\A[a-z0-9][a-z0-9_-]{0,31}\z/
      SHA256 = /\A[0-9a-f]{64}\z/
      DISPOSITIONS = %w[stock setting prepared_input code manual excluded].freeze
      # The mapping mount is a data channel: only data formats a converter reads with its
      # own parser. Code (.rb, .sh, ...), extensionless and other files never pass.
      DATA_EXTENSIONS = %w[csv tsv yml yaml json ndjson jsonl txt xml xlsx].freeze
      CODE_CLAIM = "Pinned code is available at this exact revision. This is not proof that a requirement is implemented, tested or reviewed."
      QUESTION_STATUSES = %w[resolved excluded scope_narrowed].freeze

      # Bounded JSON read for the CLI; the document is then embedded in the plan body.
      def self.read_document(path, code)
        raise StandardWorkflowError.new(code, "file") unless path.is_a?(String) && File.file?(path) && !File.symlink?(path)

        bytes = File.open(path, File::RDONLY | File::NOFOLLOW) { |file| file.read(MAX_DOCUMENT_BYTES + 1) }.to_s
        raise StandardWorkflowError.new(code, "larger than 64 KiB") if bytes.bytesize > MAX_DOCUMENT_BYTES

        text = bytes.force_encoding("UTF-8")
        raise StandardWorkflowError.new(code, "not UTF-8") unless text.valid_encoding?

        JSON.parse(text)
      rescue JSON::ParserError
        raise StandardWorkflowError.new(code, "not JSON")
      rescue SystemCallError
        raise StandardWorkflowError.new(code, "file")
      end

      private

      # -- shared shape checks ----------------------------------------------------

      def doc_invalid!(code, detail)
        raise StandardWorkflowError.new(code, detail)
      end

      def doc_keys!(code, value, required, optional, label)
        doc_invalid!(code, label) unless value.is_a?(Hash) && (required - value.keys).empty? && (value.keys - required - optional).empty?
      end

      def doc_text!(code, value, limit, label, optional: false)
        return nil if optional && value.nil?

        valid = value.is_a?(String) && value.bytesize.between?(1, limit) && value.valid_encoding? && !value.match?(/[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/)
        doc_invalid!(code, label) unless valid
        value
      end

      def logical_name!(code, value, label)
        parts = value.is_a?(String) ? value.split("/", -1) : []
        unless value.is_a?(String) && value.bytesize <= 255 && parts.size.between?(1, 4) && parts.all? { |part| part.match?(NAME_SEGMENT) && !%w[. ..].include?(part) }
          doc_invalid!(code, label)
        end
        doc_invalid!(code, "#{label}: only data files (#{DATA_EXTENSIONS.join(', ')})") unless data_name?(value)
        value
      end

      def data_name?(name)
        extension = File.extname(name.to_s).delete_prefix(".").downcase
        DATA_EXTENSIONS.include?(extension)
      end

      # A reference is identified by an intake file (file roles registry) or a registered
      # named input, and always by the sha256 of the exact bytes the analyst used.
      def reference_entry!(code, entry, label)
        doc_keys!(code, entry, %w[sha256], %w[file_id input_id], label)
        doc_invalid!(code, label) unless entry["sha256"].is_a?(String) && entry["sha256"].match?(SHA256) && [entry["file_id"], entry["input_id"]].compact.size == 1
        doc_invalid!(code, label) if entry["file_id"] && !entry["file_id"].to_s.match?(/\Afile-[0-9a-f]{32}\z/)
        doc_invalid!(code, label) if entry["input_id"] && !entry["input_id"].to_s.match?(/\Ainput-[0-9a-f]{32}\z/)
        entry.slice("file_id", "input_id", "sha256")
      end

      # bytes: true re-reads the custody copy and compares its sha256 (proposal time);
      # otherwise the registered stat identity is checked (staleness, cheap).
      def reference_current?(entry, document, named, bytes: false)
        input_id = entry["input_id"]
        unless input_id
          file = document&.dig("files", entry["file_id"])
          return false unless file.is_a?(Hash) && file["role"] == "reference" && file["sha256"] == entry["sha256"]

          input_id = file["input_id"] || file["taken"]
          # An intake reference not (yet) taken into a dataset: the registry's recorded
          # digest is all Silo can bind here. Reported as such, never as a byte check.
          return true unless input_id
        end
        input = named.fetch("inputs")[input_id]
        return false unless input && input["sha256"] == entry["sha256"]

        @store.named.verify_input_identity(input)
        return true unless bytes

        Digest::SHA256.file(File.join(@store.workspace_root, input.fetch("path").unpack1("m0"))).hexdigest == entry["sha256"]
      rescue NamedError, SystemCallError
        false
      end

      def reference_verification(entry, document)
        return "custody_bytes" if entry["input_id"]

        file = document&.dig("files", entry["file_id"])
        file && (file["input_id"] || file["taken"]) ? "custody_bytes" : "registry_digest"
      end

      def references_current!(code, entries, document, named)
        entries.each_with_index do |entry, index|
          doc_invalid!(code, "reference #{index + 1} is not a current reference with that sha256") unless reference_current?(entry, document, named, bytes: true)
          entry["verified"] = reference_verification(entry, document)
        end
      end

      # Every reference bound anywhere in a body, for staleness.
      def bound_references(body)
        refs = Array(body.dig("preparation", "references"))
        Array(body.dig("run_inputs", "files")).each { |file| refs += Array(file.dig("lineage", "references")) }
        refs
      end

      def references_stale_reason(plan)
        refs = bound_references(plan.fetch("body"))
        return nil if refs.empty?

        document = file_roles.load
        named = @store.named_state
        refs.all? { |entry| reference_current?(entry.except("verified"), document, named) } ? nil : "preparation"
      rescue StandardWorkflowError
        "preparation"
      end

      # -- run-input manifest ------------------------------------------------------

      def run_inputs_binding!(manifest, named:, roles:, source:, platform:, delivery:, config:)
        code = "STANDARD_RUN_INPUTS_INVALID"
        doc_keys!(code, manifest, %w[version consumer source_sha256 files], %w[absent_defaults generated], "shape")
        doc_invalid!(code, "version") unless manifest["version"] == RUN_INPUTS_VERSION
        consumer = manifest["consumer"]
        doc_keys!(code, consumer, %w[platform setting], [], "consumer")
        doc_invalid!(code, "consumer platform differs from the source's platform") unless consumer["platform"] == platform
        doc_invalid!(code, "consumer setting") unless consumer["setting"].is_a?(String) && consumer["setting"].match?(SETTING)
        doc_invalid!(code, "source_sha256 differs from the plan's source") unless manifest["source_sha256"] == source.fetch("sha256")

        files = manifest["files"]
        # An explicit empty list is valid: no reviewed files, only declared defaults and/or
        # generated names (for example Khoros' generated trust_level_mapping.yml) in a fresh,
        # empty run directory. A header-only placeholder would change the converter's semantics.
        doc_invalid!(code, "files") unless files.is_a?(Array) && files.size <= MAX_FILES
        document = file_roles.load
        seen_inputs = []
        bound = files.each_with_index.map do |file, index|
          label = "file #{index + 1}"
          doc_keys!(code, file, %w[name input_id sha256 bytes], %w[lineage reuse], label)
          name = logical_name!(code, file["name"], "#{label}: name")
          id = file["input_id"]
          input = id.is_a?(String) ? named.fetch("inputs")[id] : nil
          doc_invalid!(code, "#{label}: input_id is not a registered input") unless input
          doc_invalid!(code, "#{label}: input type must be one of #{RUN_INPUT_TYPES.join(', ')}") unless RUN_INPUT_TYPES.include?(input["type"])
          doc_invalid!(code, "#{label}: input is already bound in another role") if roles.value?(id) || seen_inputs.include?(id)
          doc_invalid!(code, "#{label}: sha256/bytes differ from the registered input") unless file["sha256"] == input["sha256"] && file["bytes"] == input["bytes"]
          seen_inputs << id
          entry = { "name" => name, "input_id" => id, "sha256" => input["sha256"], "bytes" => input["bytes"] }
          entry["lineage"] = lineage!(code, file["lineage"], label, document, named) if file.key?("lineage")
          entry["reuse"] = reuse!(code, file["reuse"], label, named, source: source, input_id: id) if file.key?("reuse")
          entry
        end
        names = bound.map { |entry| entry["name"] }
        absent = name_list!(code, manifest.fetch("absent_defaults", []), "absent_defaults")
        generated = name_list!(code, manifest.fetch("generated", []), "generated")
        all = names + absent + generated
        doc_invalid!(code, "duplicate file name") unless names.map(&:downcase).uniq.size == names.size
        doc_invalid!(code, "absent_defaults/generated overlap a bound file") unless (absent + generated).none? { |name| names.map(&:downcase).include?(name.downcase) }
        all.each do |name|
          doc_invalid!(code, "#{name} is both a file and a directory") if all.any? { |other| other.downcase.start_with?("#{name.downcase}/") }
        end
        bound.each_with_index { |entry, index| run_input_dataset!(code, named, entry, index, source, delivery) }
        consumer_setting!(code, config, platform, consumer["setting"])

        { "version" => RUN_INPUTS_VERSION, "consumer" => consumer.slice("platform", "setting"), "source_sha256" => source.fetch("sha256"),
          "mount" => RUN_INPUTS_MOUNT, "writable" => !generated.empty?,
          "files" => bound.sort_by { |entry| entry["name"] }, "absent_defaults" => absent.sort, "generated" => generated.sort }
      end

      def name_list!(code, value, label)
        doc_invalid!(code, label) unless value.is_a?(Array) && value.size <= MAX_NAMES
        names = value.map { |name| logical_name!(code, name, label) }
        doc_invalid!(code, "#{label}: duplicate name") unless names.map(&:downcase).uniq.size == names.size
        names
      end

      def lineage!(code, lineage, label, document, named)
        doc_keys!(code, lineage, [], %w[references preparation], "#{label}: lineage")
        result = {}
        if lineage.key?("references")
          refs = lineage["references"]
          doc_invalid!(code, "#{label}: lineage references") unless refs.is_a?(Array) && refs.size <= MAX_REFERENCES
          result["references"] = refs.each_with_index.map { |ref, index| reference_entry!(code, ref, "#{label}: reference #{index + 1}") }
          references_current!(code, result["references"], document, named)
        end
        if lineage.key?("preparation")
          prep = lineage["preparation"]
          doc_keys!(code, prep, %w[job], %w[tool script_sha256 preparation_sha256], "#{label}: lineage preparation")
          doc_invalid!(code, "#{label}: preparation job") unless prep["job"].is_a?(String) && prep["job"].match?(TOKEN)
          doc_invalid!(code, "#{label}: preparation tool") if prep.key?("tool") && !(prep["tool"].is_a?(String) && prep["tool"].match?(TOKEN))
          %w[script_sha256 preparation_sha256].each do |key|
            doc_invalid!(code, "#{label}: preparation #{key}") if prep.key?(key) && !(prep[key].is_a?(String) && prep[key].match?(SHA256))
          end
          result["preparation"] = prep.slice("job", "tool", "script_sha256", "preparation_sha256")
        end
        result
      end

      # Explicit cross-delivery reuse: the file's own dataset and the digest of the source
      # snapshot it was prepared against. That digest must be an original source input of that
      # dataset: the same input type as this plan's source, and never the reused file itself.
      def reuse!(code, reuse, label, named, source:, input_id:)
        doc_keys!(code, reuse, %w[dataset_id source_sha256], [], "#{label}: reuse")
        unless reuse["dataset_id"].is_a?(String) && reuse["dataset_id"].match?(/\Adataset-[0-9a-f]{32}\z/) && reuse["source_sha256"].is_a?(String) && reuse["source_sha256"].match?(SHA256)
          doc_invalid!(code, "#{label}: reuse")
        end
        original = named.fetch("inputs").values.any? do |input|
          input["dataset_id"] == reuse["dataset_id"] && input["sha256"] == reuse["source_sha256"] &&
            input["type"] == source.fetch("type") && input["id"] != input_id
        end
        doc_invalid!(code, "#{label}: reuse source_sha256 is not a registered #{source.fetch('type')} source input of that dataset") unless original
        reuse.slice("dataset_id", "source_sha256")
      end

      # By default a run input belongs to the plan source's own dataset: an older or another
      # delivery's file can't be bound by re-registering or shuffling it. Reuse is declared per
      # file (bound by the digest and shown in review); it is never from a Base site's data.
      def run_input_dataset!(code, named, entry, index, source, delivery)
        dataset = named.fetch("inputs").fetch(entry["input_id"]).fetch("dataset_id")
        if entry["reuse"]
          doc_invalid!(code, "file #{index + 1}: reuse dataset_id differs from the input's dataset") unless entry.dig("reuse", "dataset_id") == dataset
          doc_invalid!(code, "file #{index + 1}: reuse is for another delivery's data; this input is the source's own") if dataset == source.fetch("dataset_id")
          record = delivery_record!(dataset)
          doc_invalid!(code, "file #{index + 1}: reused input belongs to data of another delivery kind") unless record["kind"] == delivery["kind"]
        else
          doc_invalid!(code, "file #{index + 1}: input is not in the plan source's dataset; declare reuse explicitly") unless dataset == source.fetch("dataset_id")
        end
      rescue StandardWorkflowError => error
        raise if error.code == code

        doc_invalid!(code, "file #{index + 1}: input's data is not labelled")
      end

      # The setting must exist in the converter's own committed settings template at the
      # bound revision: the converter's contract, not a Silo list of converter options.
      def consumer_setting!(code, config, platform, setting)
        shown = @runtime.run([*converter_git_argv(config.fetch("converter_worktree")), "show", "#{config.fetch('converter_revision')}:converters/#{platform}/settings.yml"],
                             capture: true, timeout: 30, binary: true)
        doc_invalid!(code, "converters/#{platform}/settings.yml is not committed") unless shown.success?

        template = YAML.safe_load(shown.stdout.to_s.dup.force_encoding("UTF-8"), aliases: true)
        node = template
        setting.split(".").each do |key|
          doc_invalid!(code, "consumer setting #{setting} is not in the converter's settings.yml") unless node.is_a?(Hash) && node.key?(key)
          node = node[key]
        end
      rescue Psych::Exception
        doc_invalid!(code, "converters/#{platform}/settings.yml is not YAML")
      end

      # Settings bind the mount by placeholder, exactly when a manifest is bound.
      def run_inputs_settings!(parsed, names, run_inputs)
        if run_inputs.nil?
          raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "unknown placeholder #{RUN_INPUTS_PLACEHOLDER}") if names.include?(RUN_INPUTS_PLACEHOLDER)
          return
        end
        raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "missing ${#{RUN_INPUTS_PLACEHOLDER}}") unless names.include?(RUN_INPUTS_PLACEHOLDER)

        value = run_inputs.dig("consumer", "setting").split(".").reduce(parsed) { |node, key| node.is_a?(Hash) ? node[key] : nil }
        unless value == RUN_INPUTS_MOUNT
          raise StandardWorkflowError.new("STANDARD_SETTINGS_INVALID", "#{run_inputs.dig('consumer', 'setting')} must be \"${#{RUN_INPUTS_PLACEHOLDER}}\"")
        end
      end

      # A fresh, real, run-owned copy of exactly the plan's bytes, from the run's already
      # verified input copies. Refuses an existing directory: never reuse a run's tree.
      def materialize_run_inputs(run_id, body, inputs)
        run_inputs = body["run_inputs"]
        return nil unless run_inputs

        root = @store.run_dir(run_id, "work", "run-inputs")
        begin
          Dir.mkdir(root, 0o700)
        rescue Errno::EEXIST
          raise StandardWorkflowError.new("STANDARD_RUN_INPUTS_MUTATED", "run-input directory already exists")
        end
        mode = run_inputs["writable"] ? 0o600 : 0o400
        run_inputs.fetch("files").each do |file|
          input = inputs.find { |entry| entry["id"] == file.fetch("input_id") }
          raise StandardWorkflowError.new("STANDARD_INPUT_CHANGED", "run input missing") unless input

          target = File.join(root, file.fetch("name"))
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          digest = Digest::SHA256.new
          copied = 0
          File.open(input_path(run_id, input), File::RDONLY | File::NOFOLLOW) do |source|
            File.open(target, File::WRONLY | File::CREAT | File::EXCL | File::NOFOLLOW, mode) do |output|
              while (chunk = source.read(1024 * 1024))
                digest.update(chunk)
                copied += chunk.bytesize
                output.write(chunk)
              end
            end
          end
          File.chmod(mode, target)
          stat = File.lstat(target)
          unless stat.file? && stat.nlink == 1 && digest.hexdigest == file.fetch("sha256") && copied == file.fetch("bytes")
            raise StandardWorkflowError.new("STANDARD_INPUT_CHANGED", "run input differs from plan")
          end
        end
        # Directories stay 0700 so reset can remove them; a read-only plan also mounts the
        # tree read-only and its files are 0400.
        root
      end

      def run_inputs_mount_args(root, body)
        return [] unless root

        ["--mount", "type=bind,src=#{root},dst=#{RUN_INPUTS_MOUNT}#{body.dig('run_inputs', 'writable') ? '' : ',readonly'}"]
      end

      # After the converter's container is gone: what it actually read and wrote. Bound
      # files must be byte-identical; only declared generated names may appear, as regular
      # files; anything else fails the run. Generated files are kept as private evidence and
      # are never promoted into a later plan.
      def capture_run_inputs!(run_id, body, root)
        run_inputs = body["run_inputs"]
        return unless run_inputs && root

        bound = run_inputs.fetch("files").to_h { |file| [file["name"], file] }
        generated_names = run_inputs.fetch("generated")
        # Directories the contract allows: parents of bound files and declared generated names.
        allowed_dirs = (bound.keys + generated_names).flat_map do |name|
          parts = name.split("/")
          (1...parts.size).map { |count| parts.first(count).join("/") }
        end.uniq
        found = {}
        violations = []
        nodes = 0
        walk = lambda do |relative, depth|
          Dir.children(File.join(root, relative)).sort.each do |child|
            nodes += 1
            if nodes > MAX_CAPTURED_NODES
              violations << "too many entries"
              throw :capture_limit
            end
            rel = relative.empty? ? child : File.join(relative, child)
            shown = rel.dump[0, 160]
            stat = File.lstat(File.join(root, rel))
            if stat.directory?
              if depth >= MAX_DEPTH || !allowed_dirs.include?(rel)
                violations << "#{shown}: undeclared directory"
              else
                walk.call(rel, depth + 1)
              end
            elsif !(stat.file? && stat.nlink == 1)
              violations << "#{shown}: not a regular file"
            elsif (stat.mode & 0o111).nonzero?
              violations << "#{shown}: executable file"
            elsif bound.key?(rel)
              # Never hash more than the bound size: a different size is already a change.
              found[rel] = { "bytes" => stat.size, "sha256" => stat.size == bound[rel]["bytes"] ? Digest::SHA256.file(File.join(root, rel)).hexdigest : nil }
            elsif generated_names.include?(rel)
              if stat.size > MAX_GENERATED_BYTES
                violations << "#{shown}: generated file larger than #{MAX_GENERATED_BYTES} bytes"
              else
                found[rel] = { "bytes" => stat.size, "sha256" => Digest::SHA256.file(File.join(root, rel)).hexdigest }
              end
            else
              violations << "#{shown}: undeclared file"
            end
          end
        end
        root_stat = File.lstat(root)
        raise StandardWorkflowError.new("STANDARD_RUN_INPUTS_MUTATED", "run-input directory replaced") unless root_stat.directory?

        catch(:capture_limit) { walk.call("", 1) }

        declared = bound.map do |name, file|
          current = found[name]
          status = if current.nil? then "removed"
                   elsif current == file.slice("bytes", "sha256") then "unchanged"
                   else "modified"
                   end
          violations << "#{name}: #{status}" unless status == "unchanged"
          { "name" => name, "input_id" => file["input_id"], "sha256" => file["sha256"], "bytes" => file["bytes"], "status" => status }
        end
        generated = (found.keys - bound.keys).map do |name|
          entry = { "name" => name }.merge(found[name])
          target = @store.run_dir(run_id, "private", "run-inputs-generated", name)
          FileUtils.mkdir_p(File.dirname(target), mode: 0o700)
          File.open(File.join(root, name), File::RDONLY | File::NOFOLLOW) { |source| @store.write_private(target, source.read(MAX_GENERATED_BYTES + 1).to_s) }
          entry["captured"] = Digest::SHA256.file(target).hexdigest == entry["sha256"]
          violations << "#{name.dump[0, 160]}: changed while being captured" unless entry["captured"]
          entry
        end
        defaults = run_inputs.fetch("absent_defaults").reject { |name| found.key?(name) }
        evidence(run_id, "run-inputs.json", { "version" => 1, "consumer" => run_inputs["consumer"], "declared" => declared, "generated" => generated,
                                              "absent_defaults_in_effect" => defaults, "violations" => violations })
        # Public results: counts only. Names, digests and violations stay in private evidence.
        record_results(run_id, run_inputs: { "files" => declared.size, "generated" => generated.size,
                                             "absent_defaults_in_effect" => defaults.size, "violations" => violations.size })
        raise StandardWorkflowError.new("STANDARD_RUN_INPUTS_MUTATED", violations.first.to_s[0, 200]) unless violations.empty?
      rescue SystemCallError => error
        raise StandardWorkflowError.new("STANDARD_RUN_INPUTS_MUTATED", "capture failed: #{error.class}")
      end

      # -- preparation review metadata ----------------------------------------------

      # code_readiness: { "kind" => "converter"|"merge_layer", ... } from the plan body itself.
      def preparation_binding!(preparation, roles:, run_inputs:, code_readiness:)
        code = "STANDARD_PREPARATION_INVALID"
        doc_keys!(code, preparation, %w[version analyst], %w[references outcomes questions exclusions], "shape")
        doc_invalid!(code, "version") unless preparation["version"] == PREPARATION_VERSION
        analyst = preparation["analyst"]
        doc_keys!(code, analyst, %w[label text], [], "analyst")
        result = { "version" => PREPARATION_VERSION,
                   "analyst" => { "label" => doc_text!(code, analyst["label"], 80, "analyst label"), "text" => doc_text!(code, analyst["text"], 8000, "analyst text") } }

        refs = preparation.fetch("references", [])
        doc_invalid!(code, "references") unless refs.is_a?(Array) && refs.size <= MAX_REFERENCES
        result["references"] = refs.each_with_index.map { |ref, index| reference_entry!(code, ref, "reference #{index + 1}") }
        references_current!(code, result["references"], file_roles.load, @store.named_state)

        exclusions = items!(code, preparation.fetch("exclusions", []), "exclusion", %w[id text], %w[reason]) do |item, label|
          { "id" => item["id"], "text" => doc_text!(code, item["text"], 1000, "#{label} text"), "reason" => doc_text!(code, item["reason"], 1000, "#{label} reason", optional: true) }.compact
        end
        exclusion_ids = exclusions.map { |item| item["id"] }

        questions = items!(code, preparation.fetch("questions", []), "question", %w[id text], %w[status resolution exclusion]) do |item, label|
          unless QUESTION_STATUSES.include?(item["status"])
            raise StandardWorkflowError.new("STANDARD_PREPARATION_UNRESOLVED", "#{label} has no resolution, exclusion or scope narrowing")
          end
          entry = { "id" => item["id"], "text" => doc_text!(code, item["text"], 1000, "#{label} text"), "status" => item["status"],
                    "resolution" => doc_text!(code, item["resolution"], 1000, "#{label} resolution") }
          if item["status"] == "excluded"
            doc_invalid!(code, "#{label}: excluded question must name an exclusion") unless exclusion_ids.include?(item["exclusion"])
            entry["exclusion"] = item["exclusion"]
          elsif item.key?("exclusion")
            doc_invalid!(code, "#{label}: exclusion only for excluded questions")
          end
          entry
        end

        file_names = Array(run_inputs&.fetch("files")).map { |file| file["name"] }
        outcomes = items!(code, preparation.fetch("outcomes", []), "outcome", %w[id requirement disposition], %w[input exclusion]) do |item, label|
          disposition = item["disposition"]
          doc_invalid!(code, "#{label}: disposition") unless DISPOSITIONS.include?(disposition)
          entry = { "id" => item["id"], "requirement" => doc_text!(code, item["requirement"], 1000, "#{label} requirement"), "disposition" => disposition }
          doc_invalid!(code, "#{label}: input only for prepared_input") if item.key?("input") && disposition != "prepared_input"
          doc_invalid!(code, "#{label}: exclusion only for excluded") if item.key?("exclusion") && disposition != "excluded"
          case disposition
          when "prepared_input"
            target = item["input"]
            valid = (target == "settings" && roles.key?("settings")) || file_names.include?(target)
            doc_invalid!(code, "#{label}: prepared_input must name a bound run-input file or bound settings") unless valid
            entry["input"] = target
          when "setting"
            doc_invalid!(code, "#{label}: setting outcome needs bound settings") unless roles.key?("settings")
          when "code"
            doc_invalid!(code, "#{label}: no pinned consumer code (#{code_readiness['kind']}) in this plan") unless code_readiness["present"]
          when "excluded"
            doc_invalid!(code, "#{label}: excluded outcome must name an exclusion") unless exclusion_ids.include?(item["exclusion"])
            entry["exclusion"] = item["exclusion"]
          end
          entry
        end

        readiness = code_readiness.merge("required" => outcomes.any? { |item| item["disposition"] == "code" },
                                         "claim" => code_readiness["present"] ? "pinned_code_available" : "no_pinned_code", "note" => CODE_CLAIM)
        result.merge("outcomes" => outcomes, "questions" => questions, "exclusions" => exclusions, "code_readiness" => readiness)
      end

      def items!(code, list, kind, required, optional)
        doc_invalid!(code, "#{kind}s") unless list.is_a?(Array) && list.size <= MAX_ITEMS
        ids = []
        list.each_with_index.map do |item, index|
          label = "#{kind} #{index + 1}"
          doc_keys!(code, item, required, optional, label)
          doc_invalid!(code, "#{label}: id") unless item["id"].is_a?(String) && item["id"].match?(ITEM_ID) && !ids.include?(item["id"])
          ids << item["id"]
          yield item, label
        end
      end

      # Manual and excluded outcomes become explicit plan exclusions (covered by the digest),
      # so a plan can never read as covering work the run will not perform.
      def preparation_not_included(preparation)
        manual = preparation["outcomes"].count { |item| item["disposition"] == "manual" }
        excluded = preparation["outcomes"].count { |item| item["disposition"] == "excluded" } + preparation["exclusions"].size
        lines = []
        lines << "#{manual} manual follow-up outcome(s) from the preparation review: not performed by this run" if manual.positive?
        lines << "#{excluded} excluded outcome(s)/exclusion(s) from the preparation review" if excluded.positive?
        lines
      end

      # Clean projection (agent/operator surfaces): no analyst-typed logical names or lineage,
      # only the contract, counts and digests. The engineer's detail view returns the body.
      def run_inputs_projection(run_inputs, detail:)
        return nil unless run_inputs
        return run_inputs if detail

        run_inputs.slice("version", "source_sha256", "mount", "writable").merge(
          "consumer" => run_inputs["consumer"], "files" => run_inputs["files"].size,
          "file_digests" => run_inputs["files"].map { |file| file.slice("sha256", "bytes") },
          "reused" => run_inputs["files"].count { |file| file["reuse"] },
          "absent_defaults" => run_inputs["absent_defaults"].size, "generated" => run_inputs["generated"].size
        )
      end

      # Engineer view carries the analyst's text; the agent projection only counts.
      def preparation_projection(preparation, detail:)
        return nil unless preparation
        return preparation if detail

        { "version" => preparation["version"], "analyst_label" => preparation.dig("analyst", "label"),
          "references" => preparation["references"].size, "outcomes" => preparation["outcomes"].group_by { |item| item["disposition"] }.transform_values(&:size),
          "questions" => preparation["questions"].group_by { |item| item["status"] }.transform_values(&:size),
          "exclusions" => preparation["exclusions"].size, "code_readiness" => preparation["code_readiness"] }
      end
    end
  end
end
