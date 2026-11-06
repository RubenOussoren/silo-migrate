# frozen_string_literal: true

require "digest"
require "json"

module SiloMigrate
  # Content identity intentionally excludes store-specific manifest/config IDs,
  # tags and history. Keep this algorithm in sync with the metal packager.
  module ImageIdentity
    module_function

    def sort_keys(value)
      case value
      when Hash then value.keys.sort.to_h { |key| [key, sort_keys(value.fetch(key))] }
      when Array then value.map { |item| sort_keys(item) }
      else value
      end
    end

    def content_id(inspect)
      config = inspect.fetch("Config")
      body = {
        "architecture" => inspect["Architecture"] || "", "os" => inspect["Os"] || "",
        "diff_ids" => inspect.fetch("RootFS")["Layers"] || [],
        "config" => %w[Cmd Entrypoint Env User WorkingDir].to_h do |key|
          [key, config[key] || (%w[Cmd Entrypoint Env].include?(key) ? [] : "")]
        end
      }
      "sha256:#{Digest::SHA256.hexdigest(JSON.generate(sort_keys(body)))}"
    end

    def resolve(runtime, image)
      result = runtime.run(["docker", "image", "inspect", image.fetch("ref")], capture: true, timeout: 30)
      if !result.success? && image.fetch("ref").include?("@sha256:")
        local_ref = "silo-migrate/loaded:#{image.fetch('content_id').delete_prefix('sha256:')}"
        result = runtime.run(["docker", "image", "inspect", local_ref], capture: true, timeout: 30)
      end
      raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH" unless result.success?

      documents = JSON.parse(result.stdout)
      document = documents.fetch(0)
      unless documents.size == 1 && content_id(document) == image.fetch("content_id") && document["Id"].to_s.match?(/\Asha256:[0-9a-f]{64}\z/)
        raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
      end
      document.fetch("Id")
    rescue JSON::ParserError, KeyError, TypeError, NoMethodError
      raise StandardWorkflowError, "STANDARD_RUNTIME_MISMATCH"
    end
  end
end
