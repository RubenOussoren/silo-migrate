# frozen_string_literal: true

require "json"
require "digest"
require_relative "image_identity"

module SiloMigrate
  class RuntimeProfiles
    DEFAULT = "discourse-2026.11.0-latest-3158c750"

    def initialize(code_root:, env:, runtime:)
      @dirs = [File.join(code_root, "runtime", "profiles"), env["SILO_RUNTIME_PROFILES_DIR"]].compact.reject(&:empty?).uniq
      @dirs = @dirs.map { |dir| File.directory?(dir) ? File.realpath(dir) : dir }.uniq
      @runtime = runtime
    end

    def names
      @dirs.flat_map { |dir| Dir.glob(File.join(dir, "*.json")).map { |file| File.basename(file, ".json") } }.uniq.sort
    end

    # Ambiguous names are refused, never silently shadowed by a server candidate.
    def path(name)
      raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless name.is_a?(String) && name.match?(/\A[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}\z/)

      paths = @dirs.map { |dir| File.join(dir, "#{name}.json") }.select { |file| File.file?(file) }
      raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH" unless paths.size == 1

      paths.first
    end

    def read(name, expected_sha256: nil)
      bytes = File.binread(path(name))
      if expected_sha256 && Digest::SHA256.hexdigest(bytes) != expected_sha256
        raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
      end
      profile = JSON.parse(bytes)
      images = profile.fetch("images")
      valid = %w[web db redis converter source_db].all? { |role| images.key?(role) } && images.values.all? do |image|
        image.fetch("ref").is_a?(String) && !image.fetch("ref").empty? &&
          image.fetch("content_id").match?(/\Asha256:[0-9a-f]{64}\z/) && %w[public-digest package].include?(image.fetch("source"))
      end
      raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH" unless valid

      profile
    rescue JSON::ParserError, KeyError, NoMethodError, TypeError
      raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
    end

    def sha256(name)
      Digest::SHA256.file(path(name)).hexdigest
    end

    def show(name)
      { version: 1, name: name, sha256: sha256(name), profile: read(name) }
    end

    def list
      names.map do |name|
        profile = read(name)
        matches = profile.fetch("images").values.all? do |image|
          begin
            ImageIdentity.resolve(@runtime, image)
            true
          rescue StandardWorkflowError
            false
          end
        end
        { name: name, status: profile.dig("qualification", "status"), selector: profile["selector"], local_images_match: matches }
      end
    end
  end
end
