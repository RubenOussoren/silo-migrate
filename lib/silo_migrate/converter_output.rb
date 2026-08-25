# frozen_string_literal: true

require "pathname"

module SiloMigrate
  class ConverterOutput
    EXCLUDED_BASENAMES = %w[uploads.sqlite3].freeze

    def initialize(customer, env: ENV, runtime: nil)
      @customer = customer
      @env = env
      @store = WorkflowStore.new(customer, env: env, runtime: runtime)
    end

    def selected_path(discover: true)
      state = @store.read
      relative = state.dig("converter", "output_db") || "output/intermediate.db"
      configured = resolve(relative, must_exist: false)
      return configured if File.file?(configured) && sqlite?(configured)
      return configured unless discover

      candidates = discover_candidates
      if candidates.length == 1
        select!(candidates.first)
        candidates.first
      else
        configured
      end
    end

    def selected_relative
      relative(selected_path)
    end

    def select!(path)
      resolved = resolve(path, must_exist: true)
      raise UsageError, "Converter output is not a valid SQLite database: #{path}" unless sqlite?(resolved)

      rel = relative(resolved)
      @store.update do |state|
        converter = state.fetch("converter")
        previous = converter["output_db"]
        converter["output_db"] = rel
        lineage = converter["output_lineage"]
        converter["output_lineage"] = nil if previous != rel && lineage && lineage["output_db"] != rel
        state.fetch("discourse")["state"] = "stale" if previous != rel && state.dig("discourse", "state") == "imported"
      end
      resolved
    end

    def discover_candidates
      Dir.glob(File.join(output_root, "**", "*"), File::FNM_DOTMATCH).select do |path|
        File.file?(path) && !File.symlink?(path) && !excluded?(path) && sqlite?(path)
      end.sort
    end

    def resolve(path, must_exist:)
      value = path.to_s
      value = File.join("output", value) unless value == "output" || value.start_with?("output/") || Pathname.new(value).absolute?
      candidate = File.expand_path(value, project_path)
      root = File.realpath(output_root)
      checked = must_exist ? File.realpath(candidate) : real_parent(candidate)
      unless checked == root || checked.start_with?("#{root}#{File::SEPARATOR}")
        raise UsageError, "Converter output path must remain beneath #{output_root}"
      end
      raise UsageError, "Converter output database not found: #{candidate}" if must_exist && !File.file?(candidate)

      candidate
    rescue Errno::ENOENT
      raise UsageError, "Converter output database not found: #{candidate || path}"
    end

    private

    def project_path
      Project.project_path(@customer, @env)
    end

    def output_root
      File.join(project_path, "output")
    end

    def relative(path)
      Pathname.new(path).relative_path_from(Pathname.new(project_path)).to_s
    end

    def real_parent(path)
      parent = File.dirname(path)
      until File.exist?(parent)
        next_parent = File.dirname(parent)
        break if next_parent == parent
        parent = next_parent
      end
      File.realpath(parent)
    end

    def sqlite?(path)
      File.open(path, "rb") { |file| file.read(16) == "SQLite format 3\0" }
    rescue SystemCallError
      false
    end

    def excluded?(path)
      basename = File.basename(path)
      EXCLUDED_BASENAMES.include?(basename) || path.include?("/discourse-backups/") || path.include?("/backups/") || basename.end_with?("-wal", "-shm")
    end
  end
end
