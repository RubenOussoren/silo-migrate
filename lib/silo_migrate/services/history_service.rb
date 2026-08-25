# frozen_string_literal: true

require "fileutils"
require "json"
require "time"

module SiloMigrate
  module Services
    class HistoryService
      def initialize(env: ENV, output: $stdout)
        @env = env
        @output = output
      end

      def archive_for_phase(customer, phase, state:, reason: "reset-#{phase}")
        generation = state.dig("phases", phase, "generation").to_i
        paths = [File.join("schema", phase)]
        lineage = state.dig("converter", "output_lineage")
        if lineage && lineage["phase"] == phase && lineage["generation"].to_i == generation
          paths.concat([
            state.dig("converter", "output_db"), "output/uploads.sqlite3",
            "output/discourse-import-restored.txt", "output/discourse-import-complete.txt",
            "findings", "fixtures", "synthetic-fixtures", File.join("discourse-converters", "safe-artifacts")
          ])
        end
        archive(customer, paths.compact, reason: reason, metadata: { "phase" => phase, "generation" => generation })
      end

      def list(customer)
        root = history_root(customer)
        entries = Dir.exist?(root) ? Dir.children(root).sort : []
        entries.each { |entry| @output.puts entry }
        entries
      end

      def delete(customer, entry, yes: false)
        raise UsageError, "Deleting workflow history requires --yes." unless yes
        raise UsageError, "Invalid history entry: #{entry}" unless entry.to_s.match?(/\A[0-9]{8}-[0-9]{6}-[a-z0-9-]+\z/)

        target = File.join(history_root(customer), entry)
        raise UsageError, "History entry not found: #{entry}" unless Dir.exist?(target)

        FileUtils.rm_rf(target)
        @output.puts "[OK] Deleted history entry #{entry}"
      end

      private

      def archive(customer, relative_paths, reason:, metadata: {})
        project = Project.project_path(customer, @env)
        existing = relative_paths.uniq.filter_map do |relative|
          next if relative.to_s.empty? || relative.start_with?("dumps/") || relative.start_with?("output/discourse-backups/")
          source = File.expand_path(relative, project)
          next unless source.start_with?("#{File.expand_path(project)}#{File::SEPARATOR}") && File.exist?(source)

          [relative, source]
        end
        return nil if existing.empty?

        stamp = Time.now.utc.strftime("%Y%m%d-%H%M%S")
        safe_reason = reason.to_s.downcase.gsub(/[^a-z0-9]+/, "-").gsub(/\A-+|-+\z/, "")
        destination = File.join(history_root(customer), "#{stamp}-#{safe_reason}")
        suffix = 1
        while File.exist?(destination)
          destination = File.join(history_root(customer), "#{stamp}-#{safe_reason}-#{suffix}")
          suffix += 1
        end
        moved = []
        existing.each do |relative, source|
          target = File.join(destination, relative)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.mv(source, target)
          moved << relative
        end
        manifest = { "version" => 1, "archived_at" => Time.now.utc.iso8601, "reason" => reason, "moved" => moved }.merge(metadata)
        Project.atomic_write(File.join(destination, "manifest.json"), JSON.pretty_generate(manifest) + "\n")
        @output.puts "[OK] Archived stale artifacts: #{destination}"
        destination
      end

      def history_root(customer)
        File.join(Project.project_path(customer, @env), "history")
      end
    end
  end
end
