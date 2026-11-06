# frozen_string_literal: true
require_relative 'standard_workflow_test'

# The converter checkout's own .git/config must not be able to make the control
# container (which holds the Docker socket) run a command through Git.
class StandardConverterConfigTest < SiloMigrateTest
  include StandardTestWorkspace

  CLONE = [
    "core.repositoryformatversion\n0", "core.filemode\ntrue", "core.bare\nfalse", "core.logallrefupdates\ntrue",
    "remote.origin.url\nhttps://github.com/discourse-org/discourse-converters.git",
    "remote.origin.fetch\n+refs/heads/*:refs/remotes/origin/*",
    "branch.main.remote\norigin", "branch.main.merge\nrefs/heads/main",
    "user.name\nEngineer", "user.email\nengineer@example.test"
  ].freeze

  def listed(entries, scope: 'local', origin: 'file:.git/config')
    entries.map { |entry| "#{scope}\0#{origin}\0#{entry}\0" }.join + "command\0command line:\0core.hookspath\n/dev/null\0"
  end

  def git_commands
    @runtime.commands.select { |entry| entry[0] == :run && entry[1].include?('git') }.map { |entry| entry[1] }
  end

  def test_plain_clone_and_engineer_commit_config_is_accepted
    with_standard do
      @runtime.converter_config = listed(CLONE + ["branch.mvp/metal-installer.merge\nrefs/heads/mvp/metal-installer",
                                                   "remote.origin.url\ngit@github.com:discourse-org/discourse-converters.git"])
      assert_equal 'a' * 40, @service.converter_status[:commit]
    end
  end

  def test_command_capable_settings_are_refused_before_any_other_git_command
    {
      'filter driver' => "filter.x.clean\ntouch /tmp/pwned",
      'credential helper' => "credential.helper\n!touch /tmp/pwned",
      'ssh command' => "core.sshcommand\ntouch /tmp/pwned",
      'include' => "include.path\n/tmp/evil.config",
      'conditional include' => "includeif.gitdir:/.path\n/tmp/evil.config",
      'alias' => "alias.st\n!touch /tmp/pwned",
      'fsmonitor' => "core.fsmonitor\n/tmp/monitor",
      'hooks path' => "core.hookspath\n/tmp/hooks",
      'protocol' => "protocol.ext.allow\nalways",
      'ext remote' => "remote.origin.url\next::sh -c touch% /tmp/pwned",
      'other remote' => "remote.evil.url\nhttps://example.test/x.git",
      'foreign branch remote' => "branch.main.remote\nevil",
      'odd fetch refspec' => "remote.origin.fetch\n+refs/*:refs/*"
    }.each do |name, bad|
      with_standard do
        @runtime.converter_config = listed(CLONE + [bad])
        before = git_commands.length
        error = assert_raises(SiloMigrate::StandardWorkflowError, name) { @service.converter_status }
        assert_equal 'STANDARD_CONVERTER_CONFIG', error.code, name
        after = git_commands.drop(before)
        assert_equal 1, after.length, name
        assert_includes after.first, '--list', name
        assert_includes after.first, 'GIT_CONFIG_GLOBAL=/dev/null', name
        assert_includes after.first, '--show-origin', name
      end
    end
  end

  def test_config_loaded_from_anywhere_but_this_checkout_is_refused
    { 'other file' => { origin: 'file:/elsewhere/config' }, 'global' => { scope: 'global', origin: 'file:/home/x/.gitconfig' },
      'worktree' => { scope: 'worktree', origin: 'file:.git/config.worktree' } }.each do |name, where|
      with_standard do
        @runtime.converter_config = listed(CLONE.first(2), **where)
        error = assert_raises(SiloMigrate::StandardWorkflowError, name) { @service.converter_status }
        assert_equal 'STANDARD_CONVERTER_CONFIG', error.code, name
      end
    end
  end

  def test_redirected_repository_submodules_and_shared_files_are_refused
    { 'commondir' => ->(wt) { File.write(File.join(wt, '.git/commondir'), '../../evil') },
      'gitdir file' => ->(wt) { File.write(File.join(wt, '.git/gitdir'), '/elsewhere') },
      'worktree config' => ->(wt) { File.write(File.join(wt, '.git/config.worktree'), '') },
      'gitmodules' => ->(wt) { File.write(File.join(wt, '.gitmodules'), '') },
      'group-writable config' => ->(wt) { File.chmod(0o664, File.join(wt, '.git/config')) },
      'group-writable git dir' => ->(wt) { File.chmod(0o775, File.join(wt, '.git')) },
      'gitlink in index' => ->(_) { @runtime.converter_index = "100644 #{'b' * 40} 0\ttracked\n160000 #{'c' * 40} 0\tsub\n" },
      'common dir elsewhere' => ->(_) { @runtime.converter_dirs = ".git\n/elsewhere/.git\n" } }.each do |name, setup|
      with_standard do
        @runtime.converter_config = listed(CLONE)
        setup.call(@service.store.load.dig('config', 'converter_worktree'))
        before = git_commands.length
        error = assert_raises(SiloMigrate::StandardWorkflowError, name) { @service.converter_status }
        assert_equal 'STANDARD_CONVERTER_CONFIG', error.code, name
        refute git_commands.drop(before).any? { |cmd| cmd.include?('status') }, name
      end
    end
  end

  def test_credentials_in_remote_url_are_refused
    with_standard do
      @runtime.converter_config = listed(CLONE + ["remote.origin.url\nhttps://user:token@github.com/discourse-org/discourse-converters.git"])
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.converter_status }
      assert_equal 'STANDARD_CONVERTER_CONFIG', error.code
    end
  end

  def test_symlinked_or_missing_git_directory_is_refused
    with_standard do
      worktree = @service.store.load.dig('config', 'converter_worktree')
      FileUtils.rm_rf(File.join(worktree, '.git'))
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.converter_status }
      assert_equal 'STANDARD_CONVERTER_CONFIG', error.code
      FileUtils.mkdir_p(File.join(@root, 'elsewhere'))
      File.symlink(File.join(@root, 'elsewhere'), File.join(worktree, '.git'))
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.converter_status }
      assert_equal 'STANDARD_CONVERTER_CONFIG', error.code
    end
  end

  def test_every_converter_git_command_carries_the_hardening
    with_standard do
      @runtime.converter_config = listed(CLONE)
      @service.converter_status
      git_commands.reject { |cmd| cmd.include?('--list') }.each do |cmd|
        %w[core.hooksPath=/dev/null core.fsmonitor=false credential.helper= protocol.allow=never submodule.recurse=false GIT_CONFIG_GLOBAL=/dev/null].each do |flag|
          assert_includes cmd, flag
        end
        assert_includes cmd, '--ignore-submodules=all' if cmd.include?('status')
      end
    end
  end

  def test_unsafe_config_blocks_a_plan_rather_than_reporting_it_stale
    with_standard do
      plan = propose
      @runtime.converter_config = listed(CLONE + ["filter.x.smudge\ntouch /tmp/pwned"])
      error = assert_raises(SiloMigrate::StandardWorkflowError) { @service.approve_plan(plan_id: plan[:plan_id], sha256: plan[:digest], reviewer: 'engineer') }
      assert_equal 'STANDARD_CONVERTER_CONFIG', error.code
    end
  end
end
