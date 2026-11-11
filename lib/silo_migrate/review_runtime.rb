# frozen_string_literal: true

require_relative "discourse_version"
require_relative "runtime_profiles"

module SiloMigrate
  # Per-plan selection only: never rewrites a catalog profile or workspace config.
  # A filename's public version/schema cannot identify an exact core commit.
  class ReviewRuntime
    UNRESOLVED = "STANDARD_REVIEW_RUNTIME_UNRESOLVED"
    DIGEST = /\Asha256:[0-9a-f]{64}\z/
    SCHEMA = /\A\d{14}\z/

    def initialize(profiles:, runtime:)
      @profiles, @runtime = profiles, runtime
    end

    def select(base: nil, preferred: nil, allow_unqualified: false)
      refuse unless [true, false].include?(allow_unqualified)
      refuse unless base.nil? || base.is_a?(Hash)
      requested = base && version(base.fetch("discourse_version"))
      schema = base && base.fetch("schema_version")
      refuse unless !base || (requested && schema.is_a?(String) && schema.match?(SCHEMA))
      refuse unless preferred.nil? || (preferred.is_a?(String) && preferred.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/))

      # Re-read on every call; adding a Base or updating the host catalog must
      # produce a fresh selection, rather than reusing an initialization choice.
      names = @profiles.names
      refuse if preferred && !names.include?(preferred)
      names = [preferred] if preferred
      candidates = names.filter_map do |name|
        begin
          candidate(name, allow_unqualified: allow_unqualified)
        rescue StandardWorkflowError, KeyError, TypeError, NoMethodError, ArgumentError, SystemCallError
          refuse if name == preferred
          nil
        end
      end
      candidates.select! do |entry|
        if requested
          entry[:track] == requested[:track] && entry[:version] >= requested[:version]
        else
          entry[:track] == "latest"
        end
      end
      # The host has already resolved/prepared this immutable profile. Never
      # silently substitute an installed baseline, even when its schema is unknown.
      candidates.select! { |entry| entry[:name] == preferred } if preferred
      chosen = candidates.min_by do |entry|
        # Gem::Version, not lexicographic sorting, also orders historical 3.x.
        [entry[:version], schema_rank(entry, schema), entry[:name]]
      end if requested
      unless requested
        newest = candidates.map { |entry| entry[:version] }.max
        chosen = candidates.select { |entry| entry[:version] == newest }
          .min_by { |entry| entry[:name] }
      end
      refuse unless chosen

      equal = requested && chosen[:version] == requested[:version]
      mode = if !base then "latest"
             elsif equal then schema_rank(chosen, schema).zero? ? "matched" : "version_match"
             else "newer"
             end
      profile = chosen.fetch(:profile)
      web = profile.fetch("images").fetch("web")
      selection = {
        "mode" => mode, "track" => chosen[:track],
        "requested_version" => base && base["discourse_version"],
        "actual_version" => profile.fetch("app").fetch("version"),
        "image_ref" => web.fetch("ref"), "content_id" => web.fetch("content_id"),
        "app_revision" => profile.fetch("app").fetch("revision"),
        "schema_version" => chosen[:schema]
      }
      digest = profile.dig("selector", "stock_index_digest") || profile.dig("provenance", "stock_index_digest")
      selection["stock_digest"] = digest if digest.is_a?(String) && digest.match?(DIGEST)
      { "name" => chosen[:name], "sha256" => chosen[:sha256], "profile" => profile, "selection" => selection }
    rescue KeyError, TypeError, NoMethodError, ArgumentError
      refuse
    end

    private

    def refuse
      raise StandardWorkflowError, UNRESOLVED
    end

    def version(value)
      DiscourseVersion.parse(value)
    end

    def candidate(name, allow_unqualified: false)
      shown = @profiles.show(name)
      # RuntimeProfiles uses symbol envelope keys; retain the original SHA binding.
      profile = shown.fetch(:profile)
      refuse unless shown.fetch(:name) == name && shown.fetch(:sha256).match?(/\A[0-9a-f]{64}\z/)
      refuse unless allow_unqualified || %w[qualified review_ready].include?(profile.fetch("qualification").fetch("status"))
      app = profile.fetch("app")
      parsed = version(app.fetch("version"))
      refuse unless parsed && app.fetch("revision").is_a?(String) && app["revision"].match?(/\A[0-9a-f]{40}\z/)
      selector = profile["selector"]
      if profile.key?("selector")
        refuse unless selector.is_a?(Hash) && selector.fetch("channel") == parsed[:track]
        if selector.key?("release")
          refuse unless selector["release"] == parsed[:release]
        end
      end
      metadata = profile.fetch("review_runtime", {})
      migrations = metadata.fetch("core_migrations", [])
      refuse unless migrations.is_a?(Array) && migrations.all? { |v| v.is_a?(String) && v.match?(SCHEMA) }
      schema = metadata["schema_version"] || metadata["schema"] || migrations.max
      refuse unless schema.nil? || (schema.is_a?(String) && schema.match?(SCHEMA))
      if schema && !migrations.empty?
        refuse unless schema == migrations.max
      end
      %w[web db redis].each do |role|
        image = profile.fetch("images").fetch(role)
        refuse unless image.fetch("ref").is_a?(String) && !image["ref"].empty? && image.fetch("content_id").match?(DIGEST)
        ImageIdentity.resolve(@runtime, image)
      end
      { name: name, sha256: shown[:sha256], profile: profile, version: parsed[:version],
        track: parsed[:track], migrations: migrations, schema: schema }
    end

    def schema_rank(entry, schema)
      return 0 if entry[:migrations].include?(schema) || entry[:schema] == schema
      return 1 if entry[:schema] && entry[:schema] > schema

      # A hosted plugin can account for a filename schema ahead of core. This
      # affects preference/evidence only, never makes a version incompatible.
      entry[:schema] ? 3 : 2
    end
  end
end
