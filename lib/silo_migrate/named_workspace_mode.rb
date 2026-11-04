# frozen_string_literal: true

module SiloMigrate
  # A deliberate mode boundary, not an identity bridge. A named workspace has
  # no legacy config, workflow or release authority. Presence (even corrupt
  # state) is enough to refuse legacy operations; never silently reinitialize.
  module NamedWorkspaceMode
    module_function

    def named_path?(path)
      File.lstat(File.join(path, ".silo-migrate", "named"))
      true
    rescue Errno::ENOENT, Errno::ENOTDIR
      false
    rescue SystemCallError
      # An unreadable/looping authority path is unknown, never legacy-safe.
      true
    end

    def reject_legacy_path!(path)
      raise UsageError, "NAMED_MODE_UNSUPPORTED", cause: nil if named_path?(path)
    end
  end
end
