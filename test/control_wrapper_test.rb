# frozen_string_literal: true
require_relative 'test_helper'
require 'open3'

# Python is the host wrapper's only interpreter dependency; every Docker/Git
# command here is intercepted, never sent to the host or a Docker socket.
class ControlWrapperTest < SiloMigrateTest
  def python_test(body)
    prelude = <<~PY
      import contextlib, io, json, os, pathlib, runpy, subprocess, tempfile
      from unittest.mock import patch
      wrapper = runpy.run_path('bin/silo-migrate-control')
      globals_ = wrapper['main'].__globals__
      fixture = json.loads(pathlib.Path('test/fixtures/image-inspect-sample.json').read_text())[0]
      expected = pathlib.Path('test/fixtures/image-inspect-sample.content_id').read_text().strip()
    PY
    out, err, status = Open3.capture3('python3', '-I', '-c', prelude + body)
    assert status.success?, "#{out}\n#{err}"
  end

  def test_host_image_identity_matches_shared_ruby_fixture
    python_test <<~PY
      with patch.dict(globals_, inspect=lambda ref: fixture):
          output = io.StringIO()
          with contextlib.redirect_stdout(output):
              assert wrapper['main'](['image-identity', 'fixture:local']) == 0
          assert output.getvalue().strip() == expected
      fixture['Config']['WorkingDir'] = '/unicode/é'
      assert wrapper['identity'](fixture) == 'sha256:39405c5c2f3e42752430fb90b687c065af80810c1a131cc3d5c59062eee83fad'
    PY
  end

  def test_strict_config_is_literal_and_refuses_unknown_duplicate_and_missing_keys
    python_test <<~PY
      with tempfile.TemporaryDirectory() as temp:
          config = pathlib.Path(temp) / 'control.conf'
          with patch.dict(os.environ, {'SILO_CONTROL_CONFIG': str(config)}, clear=True):
              for text in ['UNKNOWN=x', 'SILO_CONTROL_GEMS=x\\nSILO_CONTROL_GEMS=y', 'export SILO_CONTROL_GEMS=x', 'SILO_CONTROL_GEMS=x']:
                  config.write_text(text)
                  try:
                      wrapper['settings']()
                      raise AssertionError('accepted invalid config')
                  except ValueError as error:
                      assert str(error) == 'STANDARD_CONTROL_CONFIG_INVALID'
              config.write_text('SILO_MIGRATE_BASE_PATH=/srv/work\\nSILO_CONTROL_GEMS=/srv/gems\\nSILO_CONTROL_SITE_CACHE=$(touch /never-execute)\\n')
              values, configured = wrapper['settings']()
              assert configured and values['SILO_CONTROL_SITE_CACHE'] == '$(touch /never-execute)'
    PY
  end

  def test_start_run_passes_the_claims_refusal_code_through
    python_test <<~PY
      class Done:
          def __init__(self, code, err):
              self.returncode, self.stdout, self.stderr = code, '', err
      cases = [('Error: STANDARD_DIRTY_INSTANCE\\n', 'STANDARD_DIRTY_INSTANCE'),
               ('Error: STANDARD_REVIEW_SOURCE_INVALID: artifact changed. Propose a review\\n', 'STANDARD_REVIEW_SOURCE_INVALID'),
               ('Traceback: secret value\\n', 'STANDARD_OPERATION_FAILED')]
      for stderr, code in cases:
          with patch('subprocess.run', return_value=Done(1, stderr)):
              try:
                  wrapper['capture'](['claim'], passthrough=True)
                  raise AssertionError('accepted a failed claim')
              except ValueError as error:
                  assert str(error) == code, (str(error), code)
          with patch('subprocess.run', return_value=Done(1, stderr)):
              try:
                  wrapper['capture'](['git'])
                  raise AssertionError('accepted a failed command')
              except ValueError as error:
                  assert str(error) == 'STANDARD_OPERATION_FAILED'
    PY
  end

  def test_configured_mounts_and_control_content_check_before_docker_run
    python_test <<~PY
      with tempfile.TemporaryDirectory() as temp:
          root = pathlib.Path(temp)
          config = root / 'control.conf'
          config.write_text('SILO_MIGRATE_BASE_PATH=' + str(root / 'work') + '\\nSILO_CONTROL_GEMS=/srv/gems\\nSILO_CONTROL_SITE_CACHE=/srv/site.yml\\nSILO_RUNTIME_PROFILES_DIR=/srv/profiles\\nSILO_CONTROL_IMAGE_REF=local:control\\n')
          def stop_exec(*args):
              raise RuntimeError(args)
          class Stat:
              st_gid = 99
          real_stat = pathlib.Path.stat
          def socket_stat(path, *args, **kwargs):
              return Stat() if str(path) == '/var/run/docker.sock' else real_stat(path, *args, **kwargs)
          with patch.dict(os.environ, {'SILO_CONTROL_CONFIG': str(config)}, clear=True), patch.dict(globals_, inspect=lambda ref: fixture), patch('os.execvp', side_effect=stop_exec):
              try:
                  wrapper['main'](['standard', 'runtime', 'list'])
                  raise AssertionError('accepted wrong payload')
              except ValueError as error:
                  assert str(error) == 'STANDARD_RUNTIME_MISMATCH'
              with patch.dict(globals_, control_image=lambda *args: {'content_id': expected, 'ref': 'local:control'}), patch('pathlib.Path.stat', socket_stat):
                  try:
                      wrapper['main'](['standard', 'runtime', 'list'])
                  except RuntimeError as error:
                      command = error.args[0][1]
                      assert fixture['Id'] in command and 'local:control' not in command
                      mounts = [command[i+1] for i, arg in enumerate(command) if arg == '--mount']
                      assert 'type=bind,src=/srv/profiles,dst=/srv/profiles,readonly' in mounts
                      assert 'type=bind,src=/srv/site.yml,dst=/srv/site.yml,readonly' in mounts
                      repo = str(pathlib.Path('bin/silo-migrate-control').resolve().parent.parent)
                      assert 'type=bind,src=' + repo + ',dst=' + repo + ',readonly' in mounts
    PY
  end

  def test_clone_and_update_are_host_git_only_and_ff_only
    python_test <<~PY
      with tempfile.TemporaryDirectory() as temp:
          base = pathlib.Path(temp)
          root = base / 'synthetic'
          marker = root / '.silo-migrate/named'
          marker.mkdir(parents=True)
          (marker / 'state.json').write_text('{}')
          self = pathlib.Path('bin/silo-migrate-control').resolve()
          commands = []
          def capture(args):
              commands.append(args)
              if 'status' in args:
                  return ''
              if '--abbrev-ref' in args:
                  return 'main'
              if '--git-common-dir' in args:
                  return '.git' + chr(10) + '.git'
              return ''
          with patch.dict(globals_, capture=capture):
              with contextlib.redirect_stdout(io.StringIO()):
                  wrapper['host_converter'](['converter', 'clone', 'synthetic'], {}, base, self)
              assert commands == [wrapper['converter_git'](root / 'converter', credentials=True, cwd=root) + ['clone', '--branch', 'main', '--', 'https://github.com/discourse-org/discourse-converters.git', str(root / 'converter')]]
              checkout = root / 'converter'
              (checkout / '.git').mkdir(parents=True)
              (checkout / '.git' / 'config').write_text('')
              try:
                  wrapper['host_converter'](['converter', 'clone', 'synthetic'], {}, base, self)
                  raise AssertionError('clobbered checkout')
              except ValueError as error:
                  assert str(error) == 'STANDARD_CONVERTER_EXISTS'
              standard = marker / 'standard'
              standard.mkdir()
              (standard / 'op.lock').touch()
              (standard / 'state.json').write_text(json.dumps({'config': {'converter_worktree': str(checkout), 'converter': {'branch': 'main'}}}))
              commands.clear()
              with patch('subprocess.call', return_value=0) as call:
                  assert wrapper['host_converter'](['converter', 'update', 'synthetic'], {}, base, self) == 0
                  call.assert_called_once_with([str(self), 'standard', 'converter', 'refresh', 'synthetic'], env={})
              assert wrapper['converter_git'](checkout, credentials=True) + ['fetch', 'origin'] in commands
              assert wrapper['converter_git'](checkout) + ['merge', '--ff-only', '--', 'refs/remotes/origin/main'] in commands
              assert not any('reset' in command for command in commands)
          with patch.dict(globals_, capture=lambda args: '.git' + chr(10) + '.git' if '--git-common-dir' in args else '' if '--list' in args or 'ls-files' in args else '?? dirty'):
              try:
                  wrapper['host_converter'](['converter', 'update', 'synthetic'], {}, base, self)
                  raise AssertionError('updated dirty checkout')
              except ValueError as error:
                  assert str(error).startswith('STANDARD_CONVERTER_DIRTY')
    PY
  end
end
