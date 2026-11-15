"""Connected INVENTED-DATA installed launcher -> Prepare -> custom -> backup.

Opt in: SILO_MERGE_CONNECTED_LIVE=1 python3 -I -B test/merge_connected_live_test.py
No pulls/builds/installs, customer inputs, published ports or external connections.
See docs/merge-connected-acceptance.md for the explicitly different socket transport.
Missing cached prerequisites FAIL when opted in; a skip is NOT acceptance evidence.
"""
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('connected_process', ROOT / 'test/merge_process_rails_live_test.py')
process = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(process)
SPEC = importlib.util.spec_from_file_location('connected_docker', ROOT / 'test/support/merge_connected_live_docker.py')
transport = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(transport)
SPEC = importlib.util.spec_from_file_location('connected_host', ROOT / 'test/support/merge_connected_live_host.py')
host = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(host)
GATE = os.environ.get('SILO_MERGE_CONNECTED_LIVE') == '1'
LABEL = 'silo-migrate.connected-merge-live'


def connected_prerequisites():
    missing = process.settings.prerequisites()
    if not process.settings.shared.PROFILE.is_file():
        return missing
    profile = json.loads(process.settings.shared.PROFILE.read_bytes())
    try:
        found = subprocess.run(['docker', 'image', 'inspect', profile['images']['control']['ref']],
                               capture_output=True, timeout=30)
        if found.returncode:
            missing.append('cached pinned control image')
    except (OSError, subprocess.TimeoutExpired):
        missing.append('cached pinned control image')
    cache = Path(os.environ.get('SILO_CONNECTED_GEMS', str(ROOT / '../../.runtime-cache/gems'))).resolve()
    if not (cache / 'ruby/3.3.0/specifications').is_dir():
        missing.append('cached control gems (no installs permitted)')
    return missing


def safe_validation_projection(value):
    spec = importlib.util.spec_from_file_location('connected_validation_projection', ROOT / 'bin/data_tools.py')
    wire = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(wire)
    return wire.validation_projection(value)


def private_json(path, value):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    path.write_text(json.dumps(value))
    path.chmod(0o600)


class ConnectedFixture(process.ProcessFixture):
    def __init__(self):
        super().__init__()
        self.name = 'silo-connected-live-' + self.token
        # The real admission gate needs >=8 GiB disk headroom. /tmp is a small
        # tmpfs on this node; use actual disk, never a mocked free-space result.
        self.directory.cleanup()
        scratch = ROOT / 'tmp'
        scratch.mkdir(mode=0o700, exist_ok=True)
        self.directory = tempfile.TemporaryDirectory(prefix=self.name + '-', dir=scratch)
        self.private = Path(self.directory.name)
        self.private.chmod(0o700)
        # One shared bounded acceptance budget, including seed backup creation.
        self.deadline = time.monotonic() + 1800
        self.phase = 'prerequisites'
        self.base = self.private / 'workspaces'
        self.workspace = self.base / 'invented'
        self.standard = self.workspace / '.silo-migrate/named/standard'
        self.routes = self.private / 'routes'
        self.routes.mkdir(mode=0o700)

    def invoke(self, *args, expected=0, data=None):
        remaining = self.deadline - time.monotonic()
        assert remaining > 0, 'connected fixture work deadline exceeded'
        result = subprocess.run([sys.executable, '-I', '-B', str(ROOT / 'test/support/merge_connected_live_host.py'),
            str(self.launcher), *args], input=data, capture_output=True,
            env=self.environment, timeout=min(remaining, 1200))
        self.outputs.extend([result.stdout, result.stderr])
        # Raw output stays private even when an actual CLI integration fails.
        if result.returncode != expected:
            codes = re.findall(rb'\b(?:STANDARD|NAMED)_[A-Z_]+\b', result.stderr)
            try:
                failed = json.loads(result.stdout)
                if failed.get('error') == 'STANDARD_MERGE_VALIDATION_FAILED' and isinstance(failed.get('validation'), dict):
                    safe_projection = safe_validation_projection(failed['validation'])
                    print('CONNECTED:unexpected_validation_projection=' + json.dumps(safe_projection, sort_keys=True, separators=(',', ':')), flush=True)
                    if safe_projection.get('reason') == 'assets_unproven':
                        self.project_asset_shape()
                code = failed.get('error') or (failed.get('failure') or {}).get('code')
                if isinstance(code, str) and re.fullmatch(r'(?:STANDARD|NAMED)_[A-Z_]+', code):
                    codes.append(code.encode())
                stage = failed.get('stage')
                run_id = failed.get('run_id')
                if isinstance(run_id, str) and re.fullmatch(r'run-[0-9a-f]{32}', run_id):
                    self.project_failure(run_id)
                if stage in ('preflight', 'site_up', 'base_restore', 'source_load', 'compatibility', 'checkpoint', 'inspection',
                             'activate', 'merge', 'finalize', 'verify', 'backup', 'site_setup', 'review_url', 'result_inspection'):
                    print('CONNECTED:failed_stage=' + stage, flush=True)
            except (ValueError, AttributeError):
                pass
            safe = ','.join(sorted({v.decode() for v in codes})) or 'no_fixed_code'
            raise AssertionError('installed CLI refused at ' + self.phase + ': ' + safe)
        if not result.stdout.strip():
            return None
        try:
            return json.loads(result.stdout)
        except ValueError:
            raise AssertionError('installed CLI returned non-JSON; raw output suppressed') from None

    def project_asset_shape(self):
        """Read only the untouched invented inspection copy; no rows/counts/paths."""
        dbs = [value['containers']['db'] for value in self.state()['instances'].values()
               if value.get('containers', {}).get('db')]
        if len(dbs) != 1:
            return
        db = dbs[0].get('id') if isinstance(dbs[0], dict) else dbs[0]
        predicates = {
            'invalid_digest_null': 'sha1 IS NULL',
            'invalid_digest_empty': "sha1 = ''",
            'invalid_digest_nonempty': "sha1 IS NOT NULL AND sha1 <> ''",
            'invalid_digest_nonpositive_id': 'id <= 0',
            'invalid_digest_positive_id': 'id > 0',
            'invalid_digest_packaged_image_url': "url LIKE '/images/%'",
            'invalid_digest_uploaded_url': "url LIKE '/uploads/%'",
        }
        bad = "(sha1 IS NULL OR sha1 !~ '^[0-9a-f]{40}$')"
        sql = 'SELECT ' + ','.join('EXISTS(SELECT 1 FROM uploads WHERE ' + bad + ' AND (' + condition + '))'
                                  for condition in predicates.values())
        result = self.docker('exec', db, 'psql', '-X', '-At', '-U', 'postgres', '-d',
                             'silo_inspect_source', '-c', sql, check=False)
        fields = result.stdout.strip().split(b'|')
        if result.returncode == 0 and len(fields) == len(predicates) and all(v in (b't', b'f') for v in fields):
            print('CONNECTED:source_asset_shape=' + json.dumps(dict(zip(predicates, (v == b't' for v in fields))), sort_keys=True), flush=True)

    def project_failure(self, run_id):
        """Only fixed shipped-source tags/shape booleans from invented evidence."""
        directory = self.standard / 'runs' / run_id
        path = directory / 'private/failure.json'
        if not path.is_file():
            return
        detail = json.loads(path.read_bytes()).get('detail', '')
        completion = directory / 'private/merge-site-settings-completion.json'
        if completion.is_file():
            report = json.loads(completion.read_bytes())
            definitions = self.private / 'site-settings.yml'  # exact public-image copy from install()
            names = report.get('unexpected_names', [])
            if definitions.is_file() and isinstance(names, list) and all(isinstance(name, str) for name in names):
                public_names = set(re.findall(r'^  ([a-z][a-z0-9_]{0,63}):', definitions.read_text(), re.M))
                state = report.get('state')
                state = state if state in ('verified', 'changed', 'restored', 'unproven') else 'unknown'
                safe = {'state': state, 'changed_public_core_names': sorted(set(names) & public_names),
                        'has_other_names': bool(set(names) - public_names)}
                print('CONNECTED:completion_setting_shape=' + json.dumps(safe, sort_keys=True), flush=True)
        stack_tag = detail.removeprefix('STANDARD_STACK_FAILED: ')
        if stack_tag in {'sidekiqs', 'environment', 'db settings', 'name already in use',
                         'database not ready', 'Discourse web not ready', 'network create',
                         'volume create', 'network connect', 'create db', 'create redis',
                         'create web', 'create proxy', 'id db', 'id redis', 'id web', 'id proxy'}:
            print('CONNECTED:stack_failure_tag=' + stack_tag.replace(' ', '_'), flush=True)
        fixed = {'unexpected databases', 'seal', 'sizes', 'copies not as expected',
                 'copy differs from sealed state', 'inspection database identity', 'sessions remain',
                 'base-seal-name', 'base-copy', 'base-seal', 'source-copy', 'source-seal', 'quiesce'}
        value = detail.removeprefix('STANDARD_MERGE_ENVIRONMENT_DIRTY: ')
        if value in fixed:
            print('CONNECTED:checkpoint_failure_tag=' + value.replace(' ', '_'), flush=True)
        quiesce = re.match(r'^quiesce: reason=(quiesced|stop_failed|workers_remain|app_server_not_down|no_service_user|no_ps|no_sv|process_table_unreadable) ', value)
        if quiesce:
            print('CONNECTED:checkpoint_failure_tag=quiesce_' + quiesce[1], flush=True)
        if value == 'seal':
            log = directory / 'logs/merge-environment-seal.log'
            if log.is_file():
                text = log.read_text()
                stdout = text.split('--- stdout\n', 1)[-1].split('\n--- stderr', 1)[0].strip()
                fields = stdout.split('|')
                negative = len(fields) == 4 and bool(re.fullmatch(r'-?[0-9]+(?:,-?[0-9]+){3}', fields[-1])) and any(int(v) < 0 for v in fields[-1].split(','))
                print('CONNECTED:seal_sql_exit_zero=' + str(text.startswith('exit=0\n')).lower(), flush=True)
                print('CONNECTED:seal_max_ids_have_negative=' + str(negative).lower(), flush=True)

    def cli(self, *args, **kwargs):
        return self.invoke('standard', *args, **kwargs)

    def install(self):
        self.phase = 'install_cached_control'
        cache = Path(os.environ.get('SILO_CONNECTED_GEMS', str(ROOT / '../../.runtime-cache/gems'))).resolve()
        assert cache.is_dir(), 'missing cached control gems; no dependency installation allowed'
        release = self.private / 'installation/releases/fixture'
        release.mkdir(parents=True, mode=0o700)
        items = ('bin', 'lib', 'runtime', 'Gemfile', 'Gemfile.lock', 'silo-migrate.gemspec')
        def snapshot(root):
            files = []
            for item in items:
                path = root / item
                files.extend(sorted(p for p in path.rglob('*') if p.is_file() and '__pycache__' not in p.parts) if path.is_dir() else [path])
            return {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
        before = snapshot(ROOT)
        for item in items:
            src, dst = ROOT / item, release / item
            if src.is_dir():
                shutil.copytree(src, dst, ignore=shutil.ignore_patterns('__pycache__'))
            else:
                shutil.copyfile(src, dst)
        assert snapshot(ROOT) == before == snapshot(release), 'concurrent source change during installed snapshot; retry only after source stabilizes'
        print('CONNECTED:installed_source_sha256=' + hashlib.sha256(json.dumps(before, sort_keys=True).encode()).hexdigest(), flush=True)
        stable = self.private / 'installation/bin'
        stable.mkdir(mode=0o700)
        (stable.parent / 'current').symlink_to('releases/fixture')
        self.launcher = stable / 'silo-migrate-control'
        self.launcher.symlink_to('../current/bin/silo-migrate-control')
        tools = self.private / 'tools'
        tools.mkdir(mode=0o700)
        shutil.copyfile(ROOT / 'test/support/merge_connected_live_docker.py', tools / 'docker')
        (tools / 'docker').chmod(0o700)
        self.base.mkdir(mode=0o700)
        site = self.private / 'site-settings.yml'
        self.docker('cp', self.web + ':/var/www/discourse/config/site_settings.yml', str(site))
        site.chmod(0o600)
        config = self.private / 'control.env'
        config.write_text('SILO_MIGRATE_BASE_PATH=' + str(self.base) + '\nSILO_CONTROL_GEMS=' + str(cache) +
                          '\nSILO_CONTROL_SITE_CACHE=' + str(site) + '\n')
        config.chmod(0o600)
        self.environment = {key: value for key, value in os.environ.items() if not key.startswith(('GIT_', 'SILO_'))}
        self.environment.update(SILO_CONTROL_CONFIG=str(config), PATH=str(tools) + ':' + os.environ['PATH'],
            SILO_CONNECTED_SUPPORT=str(ROOT / 'test/support/merge_connected_live_transport.rb'),
            SILO_CONNECTED_TOKEN=self.token, SILO_CONNECTED_ROUTE_DIR=str(self.routes))

    def seed_backups(self):
        self.phase = 'seed_invented_archives'
        self.setup(site=True)
        self.quiesce()
        # Reuse only the seed/backup driver, not its guest composition lifecycle.
        driver = (ROOT / 'test/support/merge_process_rails_live_driver.rb').read_text()
        driver = driver.replace('kind == "source" ? "merge_source" : "discourse"', '"discourse"')
        driver = driver.replace('kind == "source" ? %w[carried excluded] : %w[baseline]', 'kind == "source" ? %w[carried excluded] : []')
        driver = driver.replace('publish_to_message_bus: false).run', 'publish_to_message_bus: false, with_uploads: ENV["LIVE_SQL_ONLY"] != "1").run')
        self.stage('merge_process_rails_live_driver.rb', driver)
        for name, color in [('carried', (255, 0, 0)), ('excluded', (0, 255, 0)), ('baseline', (0, 0, 255))]:
            self.stage('live-' + name + '.png', process.png(color))
        result = {}
        self.seed_names = {}
        for kind in ('destination', 'source'):
            assert self.drive('seed', 'LIVE_KIND=' + kind).returncode == 0, 'invented core API seed failed'
            if kind == 'source':
                result.update(self.guest_json('/tmp/live-seed-source.json'))
            else:
                self.invented_base_migrations = self.sql('SELECT version FROM schema_migrations ORDER BY version', 'discourse').splitlines()
            sql_only = kind == 'destination'
            assert self.drive('backup', 'LIVE_SQL_ONLY=' + ('1' if sql_only else '0')).returncode == 0, 'invented real seed backup failed'
            extension = '*.sql.gz' if sql_only else '*.tar.gz'
            names = self.docker('exec', self.web, 'find', '/shared/backups', '-type', 'f', '-name', extension).stdout.decode().splitlines()
            assert len(names) == 1, 'seed backup inventory differs'
            self.seed_names[kind] = Path(names[0]).name
            target = self.private / (kind + ('.sql.gz' if sql_only else '.tar.gz'))
            self.docker('cp', self.web + ':' + names[0], str(target), timeout=120)
            target.chmod(0o600)
            self.docker('exec', self.web, 'rm', '--', names[0])
        spec = importlib.util.spec_from_file_location('connected_public_metadata', ROOT / 'bin/review_runtime.py')
        metadata = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(metadata)
        actual = json.loads(self.docker('exec', self.web, 'ruby', '-e', metadata.PROBE).stdout)
        missing = sorted(set(self.invented_base_migrations) - set(actual['core_migrations']))
        base_version = metadata._VERSIONS.backup(self.seed_names['destination'])
        assert base_version, 'core seed backup did not retain a parseable SQL-only name'
        print('CONNECTED:invented_base_version_matches_cached=' + str(actual['version'] == base_version['discourse_version']).lower(), flush=True)
        print('CONNECTED:invented_base_schema_matches_inventory=' + str(self.invented_base_migrations[-1] == base_version['schema_version']).lower(), flush=True)
        print('CONNECTED:invented_base_ids_absent_from_current_migration_filenames=' + str(len(missing)), flush=True)
        # Historical IDs may live only in the pinned image's shipped structure.
        # Do not filter the Base or fabricate an inventory: the actual installed
        # launcher's strict core-history union gate is the admission authority.
        return result

    def git_fixture(self, directory):
        """Ephemeral invented repositories only; never commit this source checkout."""
        directory.mkdir(parents=True, exist_ok=True, mode=0o700)
        def git(*args):
            out = subprocess.run(['git', '-c', 'core.hooksPath=/dev/null', '-c', 'user.name=Invented fixture',
                '-c', 'user.email=fixture@example.invalid', '-C', str(directory), *args],
                env={**self.environment, 'GIT_CONFIG_GLOBAL': '/dev/null', 'GIT_CONFIG_NOSYSTEM': '1'},
                umask=0o077, capture_output=True, timeout=30)
            assert out.returncode == 0, 'ephemeral fixture git operation failed; output suppressed'
        if not (directory / '.git').exists():
            git('init', '--quiet', '--template=', '--initial-branch=main')
        git('add', '.')
        git('commit', '--quiet', '-m', 'Invented acceptance fixture')
        return git

    def register(self, dataset, name, path, kind):
        target = self.workspace / 'inputs' / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        target.chmod(0o400)
        return self.invoke('named', 'input', 'add', 'invented', '--dataset', dataset,
            '--path', 'inputs/' + name, '--sha256', hashlib.sha256(target.read_bytes()).hexdigest(),
            '--bytes', str(target.stat().st_size), '--type', kind)['input_id']

    def register_inputs(self, source):
        self.phase = 'registration'
        self.invoke('named', 'init', 'invented')
        source_id = self.invoke('named', 'source', 'add', 'invented', '--platform', 'discourse')['source_id']
        development = self.invoke('named', 'dataset', 'add', 'invented', '--source', source_id)['dataset_id']
        base = self.invoke('named', 'dataset', 'add', 'invented', '--source', source_id)['dataset_id']
        # Named CLI owns all input records. Delivery labels have no Ruby CLI yet;
        # seed only this static registration metadata, never plans/runs/evidence.
        deliveries = {development: {'kind': 'development', 'version': 1}, base: {'kind': 'base_site', 'version': 1}}
        private_json(self.workspace / '.silo-migrate/named/deliveries.json', {'version': 1, 'deliveries': deliveries})
        source_input = self.register(development, 'source/' + self.seed_names['source'], self.private / 'source.tar.gz', 'discourse-backup')
        base_input = self.register(base, 'base/' + self.seed_names['destination'], self.private / 'destination.sql.gz', 'base_site')
        converter = self.workspace / 'converter'
        converter.mkdir(mode=0o700)
        (converter / 'README.md').write_text('Invented fixture; no converter is executed.\n')
        git = self.git_fixture(converter)
        git('remote', 'add', 'origin', '/invented-no-fetch')
        self.cli('init', 'invented', '--converter-worktree', str(converter))
        merger = self.cli('merger', 'init', 'invented')
        layer = Path(merger['path'])
        shutil.copyfile(ROOT / 'test/support/merge_connected_live_layer.rb', layer / 'merger.rb')
        contract = {'version': 1, 'engine': 'discourse-merger-v1', 'settings_schema': {
            'type': 'object', 'additionalProperties': False,
            'required': ['asset_mode', 'semantic_ok', 'upload_id', 'sha1', 'raw'],
            'properties': {'asset_mode': {'type': 'string', 'enum': ['selected']}, 'semantic_ok': {'type': 'boolean'},
                'upload_id': {'type': 'integer', 'minimum': 1}, 'sha1': {'type': 'string'}, 'raw': {'type': 'string'}}},
            'asset_policy_key': 'asset_mode', 'asset_policies': {'selected': 'carried'},
            'audit_aggregates': {'preflight': ['selected_uploads', 'refused_policy'], 'postflight': ['selected_uploads']}}
        private_json(layer / 'workflow-contract.json', contract)
        self.git_fixture(layer)
        ids = {}
        for accepted in (False, True):
            path = self.private / ('settings-' + str(accepted) + '.json')
            private_json(path, {'asset_mode': 'selected', 'semantic_ok': accepted, 'upload_id': source['carried']['id'],
                                'sha1': source['carried']['sha1'], 'raw': source['raw']})
            ids[accepted] = self.register(development, path.name, path, 'merge-settings')
        return source_input, base_input, ids

    def approve(self, plan):
        self.cli('plan', 'approve', 'invented', plan['plan_id'], '--sha256', plan['digest'], '--reviewer', 'Invented fixture engineer')

    def state(self):
        return json.loads((self.standard / 'state.json').read_bytes())

    def assert_no_validation_resources(self, attempt):
        journal = json.loads((self.standard / 'validations' / (attempt + '.resources.json')).read_bytes())
        assert journal['cleanup_confirmed'] is True and journal['status'] == 'cleaned', 'validation cleanup unproven'
        # Independently check actual PG catalogue after cleanup, not only a flag.
        state = self.state()
        dbs = [v['containers']['db'] for v in state['instances'].values() if v.get('containers', {}).get('db')]
        assert len(dbs) == 1, 'expected one preparation stack'
        db = dbs[0]
        db = db.get('id') if isinstance(db, dict) else db
        query = "SELECT count(*) FROM pg_database WHERE datname IN ('%s','%s'); SELECT count(*) FROM pg_roles WHERE rolname='%s'" % (journal['source'], journal['base'], journal['role'])
        out = self.docker('exec', db, 'psql', '-X', '-At', '-U', 'postgres', '-d', 'postgres', '-c', query).stdout
        assert out.split() == [b'0', b'0'], 'validation database/role survived cleanup'
        if journal.get('redis_id'):
            names = self.docker('ps', '-a', '--no-trunc', '--format', '{{.ID}}').stdout.decode().splitlines()
            assert journal['redis_id'] not in names, 'validation Redis survived cleanup'
        if journal.get('guest_directory'):
            web = journal['runtime_binding']['web_id']
            absent = self.docker('exec', web, 'test', '!', '-e', journal['guest_directory'], check=False)
            assert absent.returncode == 0, 'validation guest credentials/directory survived cleanup'

    def connected_acceptance(self, inputs):
        self.phase = 'prepare_proposal'
        source, base, settings = inputs
        prep_plan = self.invoke('--cached-review-runtime', 'standard', 'plan', 'propose', 'invented',
                                '--operation', 'merge-prepare', '--source', source, '--base-site', base)
        assert isinstance(prep_plan, dict) and 'plan_id' in prep_plan, 'installed launcher has no ready cached runtime admission; preparation is not permitted'
        self.approve(prep_plan)
        self.phase = 'prepare_execution'
        prepared = self.cli('run', 'start', 'invented', prep_plan['plan_id'])
        assert prepared['status'] == 'completed', 'Prepare did not complete'
        prep_id = prepared['run_id']
        ready = self.state()['runs'][prep_id]['merge_environment']
        assert ready['phase'] == 'ready', 'Prepare generation not ready'
        generation = ready['generation']
        before = self.state()
        args = ('plan', 'propose', 'invented', '--operation', 'merge', '--prepared-from', prep_id,
                '--generation', generation, '--intent', 'custom')
        self.phase = 'expected_policy_refusal'
        refusal = self.cli(*args, '--settings', settings[False], expected=1)
        assert refusal and refusal['error'] == 'STANDARD_MERGE_VALIDATION_FAILED', 'proposal lost compatible outer refusal'
        projected = refusal['validation']
        refused = self.cli('workflow', 'validation-status', 'invented', '--attempt', 'latest')
        safe_projection = safe_validation_projection(refused)
        print('CONNECTED:validation_projection=' + json.dumps(safe_projection, sort_keys=True, separators=(',', ':')), flush=True)
        assert projected == refused, 'installed proposal dropped safe saved diagnostics'
        attempt = refused['attempt_id']
        assert re.fullmatch('[0-9a-f]{32}', attempt or ''), 'installed refusal missing attempt reference'
        assert refused['status'] == 'refused' and refused['work']['reason'] == 'preflight_refused', 'saved result is not the expected custom-policy refusal'
        assert refused['work']['stage'] != 'unknown' and refused['producer_outcome'] == 'completed', 'policy refusal lacks completed producer/stage diagnostics'
        assert refused['cleanup']['status'] == 'confirmed', 'policy refusal left cleanup unconfirmed'
        self.assert_no_validation_resources(attempt)
        frozen = {path.name: path.read_bytes() for path in (self.standard / 'validations').glob(attempt + '*')}
        exact = self.cli('workflow', 'validation-status', 'invented', '--attempt', attempt)
        assert exact == refused, 'exact saved status differs'
        assert frozen == {p.name: p.read_bytes() for p in (self.standard / 'validations').glob(attempt + '*')}, 'saved status mutated evidence'
        assert self.state()['runs'][prep_id]['merge_environment'] == before['runs'][prep_id]['merge_environment'], 'refusal consumed prepared generation'
        assert self.state()['plans'] == before['plans'], 'refused proposal created a plan'
        print('CONNECTED:policy_refusal_saved_diagnostics_cleanup_no_reset=true', flush=True)
        self.phase = 'successful_custom_proposal'
        plan = self.cli(*args, '--settings', settings[True])
        self.approve(plan)
        receipts_before_claim = {p.name for p in (self.standard / 'validations').glob('*.json') if not p.name.endswith('.resources.json')}
        self.phase = 'separate_start_claim_freshness'
        claim = self.cli('run', 'claim', 'invented', plan['plan_id'])
        fresh_receipts = [p for p in (self.standard / 'validations').glob('*.json')
                          if not p.name.endswith('.resources.json') and p.name not in receipts_before_claim]
        assert len(fresh_receipts) == 1, 'Start did not perform exactly one fresh validation'
        fresh = json.loads(fresh_receipts[0].read_bytes())
        assert fresh['status'] == 'passed' and fresh['cleanup_confirmed'], 'fresh Start validation/cleanup did not pass'
        assert claim['run_id'] != prep_id, 'merge did not claim a separate run'
        self.phase = 'stock_merge_assets_backup'
        completed = self.cli('run', 'execute', 'invented', claim['run_id'])
        assert completed['status'] == 'completed', 'merge executor did not complete'
        saved = self.state()['runs'][claim['run_id']]
        assert saved['status'] == 'completed' and saved['finished_at'], 'completed run not durable'
        assert all(v['status'] == 'passed' for v in saved['stages'].values()), 'stage completion evidence incomplete'
        backup = saved['artifacts']['backup']
        assert backup['merge_generation'] == generation and backup['preparation_run_id'] == prep_id, 'backup lost exact prepared-generation lineage'
        # Bind real archived bytes to the engine's durable backup identity.
        paths = list(self.workspace.rglob(backup['filename']))
        assert len(paths) == 1, 'completed backup path ambiguous'
        archive = paths[0]
        assert archive.stat().st_size == backup['bytes'] and hashlib.sha256(archive.read_bytes()).hexdigest() == backup['sha256'], 'persisted backup identity differs'
        run_dir = self.standard / 'runs' / claim['run_id']
        reports = json.loads((run_dir / 'private/merge-process.json').read_bytes())['phases']
        assert [r['phase'] for r in reports] == ['preflight', 'transfer', 'postflight'] and reports[-1]['complete'], 'persisted process evidence incomplete'
        manifest = json.loads((run_dir / 'private/merge-asset-manifest.json').read_bytes())
        baseline = json.loads((run_dir / 'private/merge-baseline-assets.json').read_bytes())
        with tarfile.open(archive, 'r:gz') as tar:
            names = tar.getnames()
            assert 'dump.sql.gz' in names and any(n.startswith('uploads/') for n in names), 'not a full database/uploads backup'
            for entry in manifest['entries']:
                member = 'uploads/default/' + entry['destination']
                if entry['disposition'] == 'exclude':
                    assert member not in names, 'excluded asset present in backup'
                else:
                    algorithm, digest = entry['digest']['algorithm'], entry['digest']['value']
                    assert hashlib.new(algorithm, tar.extractfile(member).read()).hexdigest() == digest, 'selected backup bytes differ'
            for entry in baseline['files']:
                member = 'uploads/default/' + entry['path']
                assert hashlib.sha256(tar.extractfile(member).read()).hexdigest() == entry['sha256'], 'baseline backup bytes differ'
        assert self.cli('run', 'show', 'invented', claim['run_id'])['status'] == 'completed', 'fresh launcher cannot read completed run'
        assert frozen == {p.name: p.read_bytes() for p in (self.standard / 'validations').glob(attempt + '*')}, 'successful retry rewrote failed evidence'
        print('CONNECTED:installed_prepare_custom_approval_claim_stock_assets_full_backup_persisted=true', flush=True)

    def close(self):
        # Fixture token labels supplement (never replace) production ownership.
        # They also catch create-before-store windows without broad Docker pruning.
        self.deadline = time.monotonic() + 180
        controls = self.docker('ps', '-a', '--filter', 'label=' + LABEL + '=' + self.token,
            '--filter', 'label=silo-migrate.connected-control=true', '--format', '{{.ID}}').stdout.decode().splitlines()
        for identity in controls:
            self.docker('rm', '--force', identity)
        violations = []
        for kind in ('container', 'volume', 'network'):
            listing = ['container', 'ls', '-a'] if kind == 'container' else [kind, 'ls']
            names = self.docker(*listing, '--filter', 'label=' + LABEL + '=' + self.token,
                '--format', '{{.Names}}' if kind == 'container' else '{{.Name}}').stdout.decode().splitlines()
            for name in names:
                doc = json.loads(self.docker(kind, 'inspect', name).stdout)[0]
                labels = doc['Config']['Labels'] if kind == 'container' else doc['Labels']
                assert labels.get(LABEL) == self.token, 'refusing unowned cleanup'
                if kind == 'container' and doc['HostConfig']['PortBindings']:
                    violations.append('fixture unexpectedly published a port')
                if kind == 'network' and not doc['Internal']:
                    violations.append('fixture unexpectedly created an external network')
                ident = doc.get('Id') or doc.get('ID') or doc['Name']
                self.docker(kind, 'rm', *(['--force'] if kind == 'container' else []), ident)
        super().close()
        assert not violations, '; '.join(violations)


class TransportTests(unittest.TestCase):
    def test_site_up_projection_emits_only_fixed_source_tag(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ConnectedFixture.__new__(ConnectedFixture)
            fixture.standard = Path(directory)
            path = fixture.standard / 'runs/run-fixture/private/failure.json'
            for detail, expected in (
                    ('STANDARD_STACK_FAILED: database not ready', 'CONNECTED:stack_failure_tag=database_not_ready\n'),
                    ('STANDARD_STACK_FAILED: PRIVATE /customer/settings password=never', '')):
                private_json(path, {'detail': detail})
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    fixture.project_failure('run-fixture')
                self.assertEqual(expected, output.getvalue())

    def test_completion_diagnostic_never_emits_private_setting_names_or_values(self):
        with tempfile.TemporaryDirectory() as directory:
            fixture = ConnectedFixture.__new__(ConnectedFixture)
            fixture.standard = Path(directory) / 'standard'
            fixture.private = Path(directory)
            (fixture.private / 'site-settings.yml').write_text('public:\n  has_login_hint:\n    default: true\n')
            root = fixture.standard / 'runs/run-fixture/private'
            private_json(root / 'failure.json', {'detail': 'final settings verification failed'})
            private_json(root / 'merge-site-settings-completion.json', {
                'state': 'changed', 'unexpected_names': ['has_login_hint', 'PRIVATE_CUSTOMER_SETTING'],
                'values': {'PRIVATE_CUSTOMER_SETTING': 'NEVER_EMIT'}})
            with contextlib.redirect_stdout(io.StringIO()) as output:
                fixture.project_failure('run-fixture')
            value = output.getvalue()
            self.assertIn('has_login_hint', value)
            self.assertIn('"has_other_names": true', value)
            self.assertNotIn('PRIVATE_CUSTOMER_SETTING', value)
            self.assertNotIn('NEVER_EMIT', value)

    def test_runtime_worker_is_refused_before_spawn(self):
        with self.assertRaises(PermissionError):
            host.refuse_runtime_worker('subprocess.Popen', ('python3', ['python3', '-I', '-B', '/fixture/bin/review_runtime_job.py', '/fixture/job.json'], None, {}))
        host.refuse_runtime_worker('subprocess.Popen', ('docker', ['docker', 'image', 'inspect', 'cached'], None, {}))

    def test_audit_guard_blocks_a_real_spawn_attempt(self):
        support = str(ROOT / 'test/support/merge_connected_live_host.py')
        code = ('import runpy,subprocess,sys; '
                'm=runpy.run_path(sys.argv[1]); sys.addaudithook(m["refuse_runtime_worker"]); '
                'subprocess.Popen([sys.executable,"/nonexistent/fixture/review_runtime_job.py"])')
        result = subprocess.run([sys.executable, '-I', '-B', '-c', code, support], capture_output=True, timeout=10)
        self.assertNotEqual(0, result.returncode)
        self.assertIn(b'PermissionError: connected fixture refuses runtime preparation', result.stderr)

    def test_metadata_probe_is_real_networkless_and_labelled(self):
        argv = ['run', '--name', 'silo-rr-' + 'a' * 32, '--rm', '--pull=never', '--network=none',
                '--read-only', '--entrypoint=ruby', 'sha256:cached', '-e', 'puts :actual_metadata']
        out = transport.control_command(argv, Path('/s'), 'invocation', Path('/r'))
        self.assertEqual([argv[0], '--label', LABEL + '=invocation', *argv[1:]], out)
        self.assertNotIn('RUBYOPT=-W0 -r/connected-transport.rb', out)
        for unsafe in (['--mount=type=bind,src=/x,dst=/x'], ['--volume', '/x:/x'],
                       ['-p', '8080:8080'], ['--network=host']):
            candidate = [v for v in argv if v != '--network=none'] if unsafe == ['--network=host'] else argv
            with self.assertRaises(ValueError):
                transport.control_command([*candidate[:1], *unsafe, *candidate[1:]], Path('/s'), 't', Path('/r'))

    def test_only_control_launch_is_transformed(self):
        argv = ['run', '--network', 'host', '-e', 'RUBYOPT=-W0', 'sha256:cached', 'bundle', 'exec', 'ruby', 'bin/silo-migrate', 'standard', 'status', 'invented']
        out = transport.control_command(argv, Path('/support.rb'), 'invented', Path('/routes'))
        self.assertEqual('none', out[out.index('--network') + 1])
        self.assertEqual(argv[-8:], out[-8:])
        self.assertEqual(['image', 'inspect', 'cached'], transport.control_command(['image', 'inspect', 'cached'], Path('/s'), 't', Path('/r')))
        self.assertIn('RUBYOPT=-W0 -r/connected-transport.rb', out)
        for argv in (['pull', 'uncached'], ['image', 'pull', 'uncached'], ['build', '.']):
            with self.assertRaises(ValueError):
                transport.control_command(argv, Path('/s'), 't', Path('/r'))


@unittest.skipUnless(GATE, 'opt in with SILO_MERGE_CONNECTED_LIVE=1 (invented data only)')
class ConnectedAcceptance(unittest.TestCase):
    def test_installed_launcher_through_full_backup(self):
        missing = connected_prerequisites()
        self.assertFalse(missing, 'missing cached prerequisites: ' + ', '.join(missing))
        f = ConnectedFixture()
        try:
            source = f.seed_backups()
            f.install()
            # Seed archives are independent bytes; keep no extra running Rails/PG
            # site while the production host lifecycle provisions its own stack.
            for kind, name in f.resources:
                if kind == 'container':
                    identity = f.owned(kind, name)['Id']
                    f.docker('stop', '--time', '20', identity)
            f.connected_acceptance(f.register_inputs(source))
        finally:
            phase = f.phase
            f.close()
            print('CONNECTED:owned_cleanup_confirmed=true last_phase=' + phase, flush=True)


if __name__ == '__main__':
    unittest.main()
