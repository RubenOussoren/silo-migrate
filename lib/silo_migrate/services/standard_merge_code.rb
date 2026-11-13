# frozen_string_literal: true

require "digest"
require "fileutils"

module SiloMigrate
  module Services
    # The project's own merge layer, in a standalone local Git repository with no remote:
    #
    #   <workspace root>/merger/
    #     merger.rb        the one entry point (one BulkImport::DiscourseMerger subclass)
    #     helpers/**.rb    optional Ruby files it requires
    #     test/            invented fixtures/tests: never executed by a merge
    #     README.md        generic contract/review notes: never executed
    #
    # The path is derived from the managed workspace, never given. Nothing is ever fetched or
    # pushed: every Git call runs with hooks, protocols, replace objects, inherited Git
    # environment and global/system config disabled, after a gate that refuses any repository
    # config or layout that could redirect objects or run a command. A merge plan binds one
    # commit and the SHA-256 manifest of its executable files; Start extracts exactly those
    # committed bytes again (never the working tree) and a per-plan ref keeps the commit.
    module StandardMergeCode
      MERGER_DIRECTORY = "merger"
      MERGER_ENTRY = "merger.rb"
      MERGER_STORE = "merger"
      MERGER_PLAN_REF = "refs/silo/merge-plans/"
      MERGER_LAYER_FILES = 32
      # Top-level entries a merger commit may hold; only merger.rb and helpers/ are executable.
      MERGER_TOP_LEVEL = %w[merger.rb helpers test README.md .gitignore].freeze
      MERGER_CONFIG_KEYS = /\A(?:core\.(?:repositoryformatversion|filemode|bare|logallrefupdates|ignorecase|precomposeunicode)|user\.(?:name|email))\z/
      MERGER_LAYER_PATH = %r{\A[A-Za-z0-9_][A-Za-z0-9_.-]*\.rb\z}

      # Creates the empty local repository once (no template, no remote, no commit). Idempotent.
      def merger_init
        @store.with_op_lock do
          @store.load
          path = merger_path
          unless File.exist?(File.join(path, ".git")) || File.symlink?(File.join(path, ".git"))
            if File.exist?(path) || File.symlink?(path)
              # Only an empty, privately owned directory is adopted.
              merger_owned!(path, directory: true)
              raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" unless Dir.empty?(path)
            else
              FileUtils.mkdir_p(File.dirname(path), mode: 0o700)
              Dir.mkdir(path, 0o700)
            end
            result = @runtime.run([*merger_git_argv(path), "init", "--quiet", "--template=", "--initial-branch=main"], capture: true, timeout: 30)
            raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" unless result.success?
          end
          merger_status
        end
      end

      # The engineer's direct-review facts: actual path, HEAD, cleanliness and the executable
      # manifest HEAD would bind. Never file contents.
      def merger_status
        path = merger_path
        unless merger_present?
          return { version: 1, path: path, initialized: false, commit: nil, branch: nil, dirty: nil, layer: nil, layer_error: nil }
        end

        assert_merger_store!
        commit = merger_head
        branch = merger_git!("symbolic-ref", "--quiet", "--short", "HEAD", allow_failure: true)
        status = { version: 1, path: path, initialized: true, commit: commit, branch: branch.to_s.strip.empty? ? "detached" : branch.strip,
                   dirty: merger_dirty?, layer: nil, layer_error: nil }
        return status.merge(layer_error: "STANDARD_MERGE_INTENT_MISMATCH") unless commit

        begin
          status[:layer] = merger_layer!(commit).first
        rescue StandardWorkflowError => error
          raise if error.code == "STANDARD_MERGER_CONFIG"

          status[:layer_error] = error.code
        end
        status
      end

      private

      def merger_path
        File.join(@store.workspace_root, MERGER_DIRECTORY)
      end

      # Anything at the store's .git (or a link in its place) is a store, to be gated.
      def merger_present?
        dot_git = File.join(merger_path, ".git")
        File.symlink?(merger_path) || File.exist?(dot_git) || File.symlink?(dot_git)
      end

      def merger_store_layer?(layer)
        layer.is_a?(Hash) && layer["store"] == MERGER_STORE
      end

      def merger_git_argv(path)
        # Git has more environment overrides than a fixed list (namespace, shallow
        # file, per-key config, future additions). Clear them all, then set our own.
        inherited = ENV.keys.grep(/\AGIT_/).sort.flat_map { |key| ["-u", key] }
        ["env", *inherited,
         "GIT_CONFIG_NOSYSTEM=1", "GIT_CONFIG_GLOBAL=/dev/null", "GIT_NO_REPLACE_OBJECTS=1", "GIT_TERMINAL_PROMPT=0",
         "git", "--no-replace-objects", "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false",
         "-c", "credential.helper=", "-c", "protocol.allow=never", "-c", "submodule.recurse=false", "-c", "fetch.recurseSubmodules=false",
         "-c", "gc.auto=0", "-c", "maintenance.auto=false", "-c", "core.attributesFile=/dev/null", "-c", "core.excludesFile=/dev/null",
         "-c", "safe.directory=#{File.realpath(path)}", "-C", path]
      end

      def merger_git!(*args, allow_failure: false, binary: false)
        result = @runtime.run([*merger_git_argv(merger_path), *args], capture: true, timeout: 30, binary: binary)
        return nil if allow_failure && !result.success?
        raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" unless result.success?

        result.stdout.to_s
      end

      def merger_owned!(path, directory:)
        stat = File.lstat(path)
        unless (directory ? stat.directory? : stat.file?) && !stat.symlink? && stat.uid == Process.uid && (stat.mode & 0o022).zero?
          raise StandardWorkflowError, "STANDARD_MERGER_CONFIG"
        end
      rescue SystemCallError
        raise StandardWorkflowError, "STANDARD_MERGER_CONFIG"
      end

      # Run before every other Git command on the store. Anything that could load config or
      # objects from elsewhere, or that names a remote, filter, include, URL rewrite or helper,
      # is refused rather than executed.
      def assert_merger_store!
        path = merger_path
        dot_git = File.join(path, ".git")
        merger_owned!(path, directory: true)
        merger_owned!(dot_git, directory: true)
        merger_owned!(File.join(dot_git, "config"), directory: false)
        %w[objects refs].each { |name| merger_owned!(File.join(dot_git, name), directory: true) }
        redirects = %w[commondir gitdir config.worktree shallow objects/info/alternates objects/info/http-alternates info/grafts].map { |name| File.join(dot_git, name) }
        if (redirects + [File.join(path, ".gitmodules")]).any? { |name| File.exist?(name) || File.symlink?(name) }
          raise StandardWorkflowError, "STANDARD_MERGER_CONFIG"
        end

        own = ["file:.git/config", "file:#{File.realpath(dot_git)}/config"]
        fields = merger_git!("config", "--list", "--show-origin", "--show-scope", "--null").split("\0", -1)
        fields.pop if fields.last == ""
        raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" unless (fields.length % 3).zero?

        fields.each_slice(3) do |scope, origin, entry|
          next if scope == "command"

          key, value = entry.split("\n", 2)
          safe = scope == "local" && own.include?(origin) && key.to_s.match?(MERGER_CONFIG_KEYS) && !value.to_s.include?("\n") &&
                 case key
                 when "core.repositoryformatversion" then value == "0"
                 when "core.bare" then value == "false"
                 else true
                 end
          raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" unless safe
        end
        dirs = merger_git!("rev-parse", "--git-dir", "--git-common-dir").split("\n")
        raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" unless dirs.length == 2 && dirs.all? { |dir| [".git", File.realpath(dot_git)].include?(dir) }
        raise StandardWorkflowError, "STANDARD_MERGER_CONFIG" if merger_git!("ls-files", "--stage").each_line.any? { |line| !line.start_with?("100644 ", "100755 ") }
      end

      def merger_head
        head = merger_git!("rev-parse", "--verify", "--quiet", "HEAD^{commit}", allow_failure: true).to_s.strip
        head.match?(/\A[0-9a-f]{40}\z/) ? head : nil
      end

      def merger_dirty?
        !merger_git!("--no-optional-locks", "status", "--porcelain", "--untracked-files=all", "--ignore-submodules=all").empty?
      end

      # The executable layer of one commit, read from objects only. Every blob's bytes are
      # rehashed against its object ID, so the extracted files are exactly the committed ones.
      def merger_layer!(commit)
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless commit.is_a?(String) && commit.match?(/\A[0-9a-f]{40}\z/)
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless merger_git!("cat-file", "-t", commit, allow_failure: true).to_s.strip == "commit"

        listing = merger_git!("ls-tree", "-r", "-l", "-z", "--full-tree", commit, binary: true).b
        files = {}
        manifest = []
        listing.split("\0").each do |entry|
          match = entry.match(/\A(\d{6}) (\w+) ([0-9a-f]{40}) +(-|\d+)\t(.+)\z/mn)
          raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless match

          mode, type, sha, size, name = match.captures
          parts = name.split("/", -1)
          # No links or submodules anywhere; unknown top-level entries are refused, not ignored.
          unless type == "blob" && %w[100644 100755].include?(mode) && MERGER_TOP_LEVEL.include?(parts.first) &&
                 parts.none? { |part| part.empty? || %w[. ..].include?(part) } && !name.match?(/[\x00-\x1f\\]/n)
            raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID"
          end
          next unless name == MERGER_ENTRY || parts.first == "helpers"

          unless mode == "100644" && parts.all? { |part| part.match?(/\A[A-Za-z0-9_][A-Za-z0-9_.-]*\z/) } && parts.last.match?(MERGER_LAYER_PATH) &&
                 files.size < MERGER_LAYER_FILES &&
                 size.to_i + files.values.sum(&:bytesize) <= StandardMergeRun::MERGE_LAYER_BYTES
            raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID"
          end
          bytes = merger_git!("cat-file", "blob", sha, binary: true).b
          unless bytes.bytesize == size.to_i && Digest::SHA1.hexdigest("blob #{bytes.bytesize}\0".b + bytes) == sha
            raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID"
          end
          files[name] = bytes
          manifest << "#{Digest::SHA256.hexdigest(bytes)} #{name}\n"
        end
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless files.key?(MERGER_ENTRY)

        [{ "present" => true, "store" => MERGER_STORE, "path" => MERGER_ENTRY, "revision" => commit, "files" => files.size,
           "bytes" => files.values.sum(&:bytesize), "sha256" => Digest::SHA256.hexdigest(manifest.sort.join) }, files]
      end

      # Proposal: the store's clean, committed HEAD. Anything uncommitted would be reviewed
      # but not run, so it is refused rather than silently left out.
      def merger_proposal_layer!
        raise StandardWorkflowError, "STANDARD_MERGE_INTENT_MISMATCH" unless merger_present?

        assert_merger_store!
        commit = merger_head
        raise StandardWorkflowError, "STANDARD_MERGE_INTENT_MISMATCH" unless commit
        raise StandardWorkflowError, "STANDARD_MERGER_DIRTY" if merger_dirty?

        merger_layer!(commit).first
      end

      # Ordinary local edits, resets or gc cannot remove a commit a plan binds.
      def merger_retain!(plan_id, commit)
        raise StandardWorkflowError, "STANDARD_ARGUMENT_INVALID" unless plan_id.match?(/\Aplan-[A-Za-z0-9]+\z/)

        merger_git!("update-ref", "#{MERGER_PLAN_REF}#{plan_id}", commit)
      end

      # Gate, then the bound commit's manifest again: equal or not current.
      def merger_layer_current?(layer)
        assert_merger_store!
        merger_layer!(layer.fetch("revision")).first == layer
      rescue StandardWorkflowError, KeyError
        false
      end

      # Start: identity re-checked, then the committed bytes extracted privately for this run.
      def merger_extract!(run_id, layer)
        assert_merger_store!
        current, files = merger_layer!(layer.fetch("revision"))
        raise StandardWorkflowError, "STANDARD_MERGE_LAYER_INVALID" unless current == layer

        files.each { |path, bytes| @store.write_private(@store.run_dir(run_id, "private", "merge", "layer", path), bytes) }
      end
    end
  end
end
