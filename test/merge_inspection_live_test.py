"""Opt-in, INVENTED-DATA-only integration tests. No downloads or customer mounts.

    SILO_MERGE_INSPECTION_LIVE=1 python3 -I -B test/merge_inspection_live_test.py

Requires cached images selected by runtime/profiles, Docker, and roughly 4 GiB
free RAM. Missing prerequisites FAIL when opted in. Creates only uniquely labelled
resources on an internal network; publishes no ports. Never uses an existing site.
The DB test exercises PostgreSQL's actual quiesce/template/switch protocol; the
site test runs the production merge_inspection_access.rb, HTTP middleware, and
verified pinned @discourse/mcp package using merge_mcp.mcp_profile. Set XDG_DATA_HOME
to the separately prepared connector-data directory. Only its verified public install
and this fixture's private profile are mounted, read-only, into the connector.
This proves guest-helper/connector composition, source role SQL/HBA and pinned DBHub
composition on the profile's PostgreSQL server, not host workflow/launcher admission
or a complete Prepare -> Merge pipeline.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import selectors
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
GATE = os.environ.get('SILO_MERGE_INSPECTION_LIVE') == '1'
LABEL = 'silo-migrate.merge-inspection-live'
PROFILE = ROOT / 'runtime/profiles/discourse-2026.11.0-latest-3158c750.json'


class Fixture:
    """No broad cleanup, pulls, published ports, customer mounts, or secret diagnostics."""
    def __init__(self):
        self.token = secrets.token_hex(8)
        self.name = 'silo-mi-live-' + self.token
        self.resources = []
        self.directory = tempfile.TemporaryDirectory(prefix=self.name + '-')
        self.private = Path(self.directory.name)
        self.private.chmod(0o700)
        self.deadline = time.monotonic() + 900
        self.outputs = []
        self.allowed_binds = {}

    def docker(self, *args, data=None, timeout=60, check=True, env=None):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise AssertionError('invented-data live fixture exceeded 900s budget')
        try:
            result = subprocess.run(['docker', *args], input=data, capture_output=True, env=env,
                                    timeout=min(timeout, remaining))
        except (OSError, subprocess.TimeoutExpired):
            # Do not expose subprocess argv/output: a future helper could contain secrets.
            raise AssertionError('Docker unavailable or timed out (output suppressed)') from None
        self.outputs.extend([result.stdout, result.stderr])
        if check and result.returncode:
            raise AssertionError('Docker operation failed: ' + args[0] + ' (output suppressed)')
        return result

    def owned(self, kind, identity):
        doc = json.loads(self.docker(kind, 'inspect', identity).stdout)[0]
        labels = doc['Config']['Labels'] if kind == 'container' else doc['Labels']
        if labels.get(LABEL) != self.token:
            raise AssertionError('refusing cleanup of non-owned resource')
        return doc

    def create(self, kind, suffix, *args):
        name = self.name + '-' + suffix
        # Record a unique name BEFORE a fallible create, reconcile it on cleanup.
        self.resources.append((kind, name))
        out = self.docker(kind, 'create', '--label', LABEL + '=' + self.token,
                          *args, name).stdout.decode().strip()
        return out

    def container(self, role, image, *args, command=(), start=True):
        name = self.name + '-' + role
        self.resources.append(('container', name))
        identity = self.docker('create', '--pull=never', '--name', name,
                               '--label', LABEL + '=' + self.token,
                               '--network', self.network, '--network-alias', role,
                               '--cpus', '1', '--memory', '2304m' if role == 'web' else '768m',
                               '--pids-limit', '512', *args, image, *command).stdout.decode().strip()
        if start:
            self.docker('start', identity)
        return identity

    def setup(self, site=False):
        profile = json.loads(PROFILE.read_text())
        images = {}
        for role in ('db', 'web', 'redis') if site else ('db',):
            ref = profile['images'][role]['ref']
            document = json.loads(self.docker('image', 'inspect', ref).stdout)[0]
            images[role] = document['Id']  # exact cached image, never pull
        self.network = self.create('network', 'int', '--internal')
        self.pg_volume = self.create('volume', 'pg')
        password = secrets.token_hex(32)
        env = self.private / 'db.env'
        env.write_text('DB_PASSWORD=' + password + '\nDISCOURSE_DB_PASSWORD=' + password + '\n')
        env.chmod(0o600)
        self.db = self.container('db', images['db'], '-v', self.pg_volume + ':/var/lib/postgresql',
                                 '--env-file', str(env), '-e', 'DB_SHARED_BUFFERS=128MB', '-e', 'DB_WORK_MEM=8MB')
        self.wait(lambda: self.docker('exec', self.db, 'pg_isready', '-U', 'postgres', check=False).returncode == 0)
        if site:
            redis = self.create('volume', 'redis')
            shared = self.create('volume', 'shared')
            self.container('redis', images['redis'], '-v', redis + ':/data')
            self.web = self.container('web', images['web'], '-v', shared + ':/shared',
                '--env-file', str(env), '-e', 'DISCOURSE_DB_HOST=db', '-e', 'DISCOURSE_REDIS_HOST=redis',
                '-e', 'DISCOURSE_HOSTNAME=merge-fixture.invalid', '-e', 'DISCOURSE_DISABLE_EMAILS=yes',
                '-e', 'DISCOURSE_SMTP_ADDRESS=smtp.invalid', '-e', 'UNICORN_WORKERS=1', '-e', 'UNICORN_SIDEKIQS=1')
            self.wait(lambda: self.docker('exec', self.web, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
                'http://127.0.0.1/srv/status', check=False).stdout == b'200', timeout=360)
        self.assert_isolation()

    def assert_isolation(self):
        assert self.owned('network', self.network)['Internal'] is True
        for kind, name in self.resources:
            doc = self.owned(kind, name)
            if kind == 'container':
                assert not doc['HostConfig']['PortBindings']
                binds = {m['Destination']: m['Source'] for m in doc['Mounts'] if m['Type'] == 'bind'}
                assert binds == self.allowed_binds.get(name, {})
                assert all(m['Type'] == 'volume' or (m['Type'] == 'bind' and not m['RW']) or
                           (name in self.allowed_binds and m['Type'] == 'tmpfs' and m['Destination'] == '/tmp')
                           for m in doc['Mounts'])
                assert len(doc['NetworkSettings']['Networks']) == 1

    def wait(self, predicate, timeout=60):
        deadline = min(self.deadline, time.monotonic() + timeout)
        while time.monotonic() < deadline:
            if predicate():
                return
            time.sleep(2)
        raise AssertionError('invented-data runtime readiness deadline exceeded; output suppressed')

    def sql(self, sql, database='postgres'):
        return self.docker('exec', '-i', self.db, 'psql', '-X', '-qAt', '-U', 'postgres',
                           '-d', database, '-v', 'ON_ERROR_STOP=1', data=sql.encode()).stdout.decode().strip()

    def copy(self, path, guest):
        self.docker('cp', str(path), self.web + ':' + guest)
        self.docker('exec', self.web, 'chown', 'discourse:discourse', guest)

    def runner(self, path, env=(), check=True):
        args = [item for pair in env for item in ('-e', pair)]
        return self.docker('exec', *args, self.web, 'su', 'discourse', '-c',
            'cd /var/www/discourse && exec env BUNDLE_WITH=generic_import RAILS_ENV=production '
            'bundle exec rails runner ' + path, timeout=180, check=check)

    def close(self):
        # Cleanup gets its own finite budget even after the test budget has expired.
        self.deadline = time.monotonic() + 180
        failures = []
        for kind, name in reversed(self.resources):
            try:
                found = self.docker(kind, 'inspect', name, check=False)
                if found.returncode:
                    # Absence must be confirmed by a successful exact-name listing.
                    listed = self.docker(kind, 'ls', '--format', '{{.Name}}').stdout.decode().splitlines() if kind != 'container' else self.docker('container', 'ls', '-a', '--format', '{{.Names}}').stdout.decode().splitlines()
                    if name in listed:
                        raise AssertionError('resource outcome unknown')
                    continue
                doc = self.owned(kind, name)
                identity = doc.get('Id') or doc.get('ID') or doc.get('Name')
                args = (kind, 'rm', '--force', identity) if kind == 'container' else (kind, 'rm', identity)
                self.docker(*args)
                after = self.docker(kind, 'inspect', identity, check=False)
                if after.returncode == 0:
                    raise AssertionError('resource still present')
            except AssertionError:
                failures.append(kind + ':' + name)
        self.directory.cleanup()
        if failures:
            raise AssertionError('owned-resource cleanup unresolved: ' + ', '.join(failures))


class JsonRpc:
    """Bounded newline-delimited MCP stdio; never include raw responses in failures."""
    def __init__(self, fixture, container):
        self.fixture = fixture
        self.process = subprocess.Popen(['docker', 'start', '-ai', container], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.selector = selectors.DefaultSelector()
        self.selector.register(self.process.stdout, selectors.EVENT_READ)
        self.selector.register(self.process.stderr, selectors.EVENT_READ)
        self.buffer = b''
        self.sequence = 0
        self.closed = False

    def send(self, message):
        try:
            self.process.stdin.write(json.dumps(dict(jsonrpc='2.0', **message)).encode() + b'\n')
            self.process.stdin.flush()
        except (BrokenPipeError, OSError):
            raise AssertionError('MCP stdio closed; output suppressed') from None

    def request(self, method, params):
        self.sequence += 1
        self.send({'id': self.sequence, 'method': method, 'params': params})
        deadline = min(self.fixture.deadline, time.monotonic() + 45)
        received = 0
        while time.monotonic() < deadline:
            while b'\n' in self.buffer:
                line, self.buffer = self.buffer.split(b'\n', 1)
                try:
                    response = json.loads(line)
                except ValueError:
                    raise AssertionError('non-JSON MCP stdout; output suppressed') from None
                if response.get('id') == self.sequence:
                    if 'error' in response:
                        raise AssertionError('MCP JSON-RPC error; output suppressed')
                    return response['result']
            for event, _ in self.selector.select(timeout=1):
                data = os.read(event.fileobj.fileno(), 65536)
                self.fixture.outputs.append(data)
                received += len(data)
                if received > 1024 * 1024:
                    raise AssertionError('MCP response exceeded 1MiB bound')
                if not data:
                    self.selector.unregister(event.fileobj)
                    if event.fileobj is self.process.stdout:
                        raise AssertionError('MCP exited before response; output suppressed')
                elif event.fileobj is self.process.stdout:
                    self.buffer += data
        raise AssertionError('MCP request exceeded 45s deadline; output suppressed')

    def initialize(self):
        result = self.request('initialize', {'protocolVersion': '2024-11-05', 'capabilities': {},
                              'clientInfo': {'name': 'silo-invented-live-test', 'version': '1'}})
        if 'tools' not in result.get('capabilities', {}):
            raise AssertionError('pinned MCP did not advertise tools')
        self.send({'method': 'notifications/initialized'})

    def close(self):
        if self.closed:
            return
        self.closed = True
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        try:
            self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()  # only our docker attach client; fixture owns container cleanup
            self.process.wait(timeout=10)
        for pipe in (self.process.stdout, self.process.stderr):
            self.fixture.outputs.append(pipe.read())
            pipe.close()
        self.selector.close()


def connector_module():
    spec = importlib.util.spec_from_file_location('live_merge_mcp', ROOT / 'bin/merge_mcp.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(GATE, 'opt-in: set SILO_MERGE_INSPECTION_LIVE=1; cached images, invented data only')
class MergeInspectionLiveTest(unittest.TestCase):
    def fixture(self, site=False):
        fixture = Fixture()
        self.addCleanup(fixture.close)
        fixture.setup(site=site)
        return fixture

    def test_postgres_quiesce_clone_and_pristine_switch(self):
        f = self.fixture()
        f.sql('CREATE DATABASE invented_base')
        f.sql("CREATE TABLE invented_marker (value text); INSERT INTO invented_marker VALUES ('pristine');", 'invented_base')
        # A real active connection makes PostgreSQL refuse template cloning.
        holder = subprocess.Popen(['docker', 'exec', f.db, 'psql', '-X', '-U', 'postgres', '-d',
            'invented_base', '-c', 'SELECT pg_sleep(60)'], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            f.wait(lambda: f.sql("SELECT count(*) FROM pg_stat_activity WHERE datname='invented_base' AND pid <> pg_backend_pid()") == '1')
            blocked = f.docker('exec', f.db, 'createdb', '-U', 'postgres', '-T', 'invented_base', 'must_not_exist', check=False, timeout=15)
            self.assertNotEqual(0, blocked.returncode)
            f.sql('ALTER DATABASE invented_base ALLOW_CONNECTIONS false')
            f.sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='invented_base'")
            f.sql('CREATE DATABASE invented_inspection TEMPLATE invented_base')
        finally:
            holder.wait(timeout=15)
        f.sql('ALTER DATABASE invented_inspection ALLOW_CONNECTIONS true')
        f.sql("INSERT INTO invented_marker VALUES ('inspection-only-identity')", 'invented_inspection')
        self.assertEqual(['pristine', 'inspection-only-identity'], f.sql('TABLE invented_marker', 'invented_inspection').splitlines())
        f.sql('ALTER DATABASE invented_inspection ALLOW_CONNECTIONS false')
        f.sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='invented_inspection'")
        f.sql('DROP DATABASE invented_inspection')
        f.sql('ALTER DATABASE invented_base ALLOW_CONNECTIONS true')
        self.assertEqual('pristine', f.sql('TABLE invented_marker', 'invented_base'))

    def source_dbhub(self, f, database, role, password):
        """Actual pinned DBHub with the production private TOML, on the owned internal network."""
        spec = importlib.util.spec_from_file_location('live_data_tools', ROOT / 'bin/data_tools.py')
        data = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(data)
        # Missing cached prerequisites must fail explicitly; this test never downloads.
        f.docker('image', 'inspect', data.DBHUB_IMAGE)
        config = f.private / 'source.dbhub.toml'
        config.write_text(connector_module().dbhub_toml({'database': database, 'role': role}, password, data))
        config.chmod(0o600)
        f.allowed_binds[f.name + '-source-dbhub'] = {'/config/dbhub.toml': str(config.resolve())}
        container = f.container('source-dbhub', data.DBHUB_IMAGE, '-i', '--read-only',
            '--tmpfs', '/tmp:rw,size=64m,mode=1777', '--user', f'{os.getuid()}:{os.getgid()}',
            '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--log-driver', 'none',
            '-e', 'HOME=/tmp', '--mount', f'type=bind,src={config.resolve()},dst=/config/dbhub.toml,readonly',
            command=('--transport', 'stdio', '--config', '/config/dbhub.toml'), start=False)
        rpc = JsonRpc(f, container)
        try:
            rpc.initialize()
            f.assert_isolation()
            tools = rpc.request('tools/list', {})['tools']
            self.assertEqual({'execute_sql', 'search_objects', 'explain_sql'}, {tool['name'] for tool in tools})
            tool = next(tool for tool in tools if tool['name'] == 'execute_sql')
            def execute(sql):
                arguments = {'sql': sql}
                if 'source_id' in tool['inputSchema'].get('properties', {}):
                    arguments['source_id'] = 'source'
                return rpc.request('tools/call', {'name': 'execute_sql', 'arguments': arguments})
            result = execute('SELECT id, username FROM users')
            self.assertFalse(result.get('isError', False), 'real DBHub approved-column read failed')
            self.assertIn('invented_reader', json.dumps(result))
            denied = execute('SELECT value FROM plugin_secrets')
            self.assertIs(denied.get('isError'), True, 'real DBHub exposed an unreviewed source table')
            self.assertNotIn('invented-secret', json.dumps(denied))
            inspected = f.owned('container', f.name + '-source-dbhub')
            self.assertNotIn(password, json.dumps(inspected), 'DBHub password leaked into Docker configuration')
        finally:
            rpc.close()
            f.docker('stop', '--time', '5', container)
        self.assertTrue(all(password.encode() not in output for output in f.outputs),
                        'DBHub password leaked to captured connector output')

    def source_role_hba(self, f):
        """Production SQL/rule generators on the real DB, not the host manifest/DBHub path."""
        role = 'silo_mi_' + secrets.token_hex(4)
        database = 'invented_source_inspection'
        password = secrets.token_hex(24)
        inputs = f.private / 'source-input.json'
        inputs.write_text(json.dumps({'role': role, 'database': database, 'password': password}))
        inputs.chmod(0o600)
        f.copy(inputs, '/tmp/source-input.json')
        f.copy(ROOT / 'lib/silo_migrate/services/standard_merge_inspection.rb', '/tmp/source-module.rb')
        builder = f.private / 'source-build.rb'
        builder.write_text('''require "json"
require "/tmp/source-module.rb"
helper = Object.new.extend(SiloMigrate::Services::StandardMergeInspection)
input = JSON.parse(File.read("/tmp/source-input.json"))
output = {
  sql: helper.send(:source_role_sql, input.fetch("role"), input.fetch("password"), input.fetch("database"), {"users" => %w[id username]}),
  hba: helper.send(:source_hba_lines, input.fetch("role"), input.fetch("database")),
  marker: helper.send(:source_hba_marker, input.fetch("role")),
  script: SiloMigrate::Services::StandardMergeInspection::SOURCE_HBA_SCRIPT
}
File.open("/tmp/source-generated.json", File::WRONLY | File::CREAT | File::EXCL, 0600) { |file| file.write(JSON.generate(output)) }
''')
        f.copy(builder, '/tmp/source-build.rb')
        f.docker('exec', f.web, 'su', 'discourse', '-c', 'ruby /tmp/source-build.rb')
        generated_path = f.private / 'source-generated.json'
        f.docker('cp', f.web + ':/tmp/source-generated.json', str(generated_path))
        generated = json.loads(generated_path.read_text())
        f.sql('CREATE DATABASE ' + database)
        f.sql("CREATE TABLE users (id integer, username text, email text); "
              "INSERT INTO users VALUES (1, 'invented_reader', 'never-return@example.invalid'); "
              "CREATE TABLE plugin_secrets (value text); INSERT INTO plugin_secrets VALUES ('invented-secret');", database)
        f.sql(generated['sql'], database)
        hba_path = f.sql('SHOW hba_file')
        self.assertRegex(hba_path, r'\A/[A-Za-z0-9_./-]+\Z')
        self.assertNotIn('..', hba_path)
        def hba(content):
            f.docker('exec', '-i', f.db, 'sh', '-c', generated['script'], 'sh', hba_path,
                     generated['marker'], data=content.encode())
            self.assertEqual('0', f.sql('SELECT count(*) FROM pg_hba_file_rules WHERE error IS NOT NULL'))
            self.assertEqual('t', f.sql('SELECT pg_reload_conf()'))
        def query(sql, db=database, tcp=True, supplied=password):
            # docker forwards PGPASSWORD from its environment; never password argv/stdout.
            return f.docker('exec', '-e', 'PGPASSWORD', f.db, 'psql', '-X', '-qAt',
                *(['-h', 'db'] if tcp else []), '-U', role, '-d', db, '-v', 'ON_ERROR_STOP=1',
                '-c', sql, env=dict(os.environ, PGPASSWORD=supplied), check=False)
        try:
            hba(generated['hba'])
            self.assertEqual('host|' + database + '|' + role + '|md5\nhost|all|' + role +
                             '|reject\nlocal|all|' + role + '|reject',
                             f.sql("SELECT type || '|' || array_to_string(database, ',') || '|' || "
                                   "array_to_string(user_name, ',') || '|' || auth_method "
                                   'FROM pg_hba_file_rules ORDER BY line_number LIMIT 3'))
            allowed = query('SELECT id, username FROM users')
            self.assertEqual(0, allowed.returncode, 'real prebuilt DB rejected scoped TCP login')
            self.assertEqual(b'1|invented_reader', allowed.stdout.strip())
            self.assertEqual(b'on', query('SHOW default_transaction_read_only').stdout.strip())
            for sql in ('SELECT email FROM users', 'SELECT * FROM plugin_secrets',
                        "INSERT INTO users VALUES (2, 'forbidden', 'forbidden@example.invalid')",
                        'SET default_transaction_read_only=off; SELECT email FROM users'):
                self.assertNotEqual(0, query(sql).returncode, 'source role exceeded reviewed read columns')
            self.assertNotEqual(0, query('SELECT 1', supplied=secrets.token_hex(24)).returncode,
                                'source role accepted a wrong password')
            self.assertNotEqual(0, query('SELECT 1', tcp=False).returncode, 'local socket bypassed HBA')
            for forbidden in ('postgres', 'discourse', 'invented_pristine', 'template1'):
                self.assertNotEqual(0, query('SELECT 1', db=forbidden).returncode,
                                    'source role connected outside inspection clone')
            self.source_dbhub(f, database, role, password)
        finally:
            hba('')
            f.sql('DROP DATABASE ' + database + ' WITH (FORCE)')
            f.sql('DROP ROLE ' + role)
            f.docker('exec', f.web, 'rm', '-f', '/tmp/source-input.json', '/tmp/source-module.rb',
                     '/tmp/source-build.rb', '/tmp/source-generated.json')
        self.assertTrue(all(password.encode() not in output for output in f.outputs),
                        'source password leaked to captured output')

    def test_real_discourse_read_only_key_and_clean_deliverable(self):
        f = Fixture()
        self.addCleanup(f.close)
        mcp = connector_module()
        class DockerFacade:
            @staticmethod
            def docker(args, timeout=30):
                return f.docker(*args, timeout=timeout, check=False)
        prepared = mcp.connector_ready(ROOT, DockerFacade())
        self.assertIsNotNone(prepared, 'pinned MCP prerequisite missing: set XDG_DATA_HOME to the prepared connector-data')
        install, image, entry = prepared
        f.setup(site=True)
        # Stop only our new web container; retain pristine DB before any inspection identity.
        f.docker('stop', '--time', '30', f.web)
        f.sql('ALTER DATABASE discourse ALLOW_CONNECTIONS false')
        f.sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='discourse'")
        f.sql('ALTER DATABASE discourse RENAME TO invented_pristine')
        f.sql('CREATE DATABASE discourse TEMPLATE invented_pristine')
        f.sql('ALTER DATABASE discourse ALLOW_CONNECTIONS true')
        f.docker('start', f.web)
        f.wait(lambda: f.docker('exec', f.web, 'curl', '-s', '-o', '/dev/null', '-w', '%{http_code}',
            'http://127.0.0.1/srv/status', check=False).stdout == b'200', timeout=120)
        seed = f.private / 'restricted_category.rb'
        seed.write_text('''require "json"
begin
  group = Group.create!(name: "mi_" + ENV.fetch("SILO_FIXTURE_TOKEN")[0, 8])
  category = Category.create!(name: "Inspection Restricted " + ENV.fetch("SILO_FIXTURE_TOKEN"),
    slug: "mi-restricted-" + ENV.fetch("SILO_FIXTURE_TOKEN"), user: Discourse.system_user,
    permissions: { group.name => 1 }, color: "0088CC")
  abort "INVENTED_CATEGORY_NOT_RESTRICTED" unless category.reload.read_restricted &&
    category.category_groups.pluck(:group_id, :permission_type) == [[group.id, 1]]
  puts "SILO_JSON:" + JSON.generate(id: category.id, name: category.name, slug: category.slug, group_id: group.id)
rescue StandardError => error
  # Only exception/validation CODE names: never interpolated messages or model values.
  codes = error.respond_to?(:record) ? error.record.errors.details.flat_map { |field, items|
    items.map { |item| "#{field}:#{item[:error]}" }
  } : []
  warn "SILO_SEED_ERROR:" + ([error.class.name] + codes).join(",")
  exit 1
end
''')
        f.copy(seed, '/tmp/restricted_category.rb')
        seeded = f.runner('/tmp/restricted_category.rb', ['SILO_FIXTURE_TOKEN=' + f.token], check=False)
        diagnostic = re.findall(rb'SILO_SEED_ERROR:([A-Za-z_:,]+)', seeded.stderr)
        self.assertEqual(0, seeded.returncode, 'invented category seed failed: ' +
                         (diagnostic[0].decode() if diagnostic else 'output suppressed'))
        category = json.loads(next(line[10:] for line in seeded.stdout.decode().splitlines() if line.startswith('SILO_JSON:')))
        helper = '/tmp/merge_inspection_access.rb'
        binding_oid = f.sql("SELECT oid FROM pg_database WHERE datname='discourse'")
        binding = ['SILO_INSPECTION_DATABASE=discourse', 'SILO_INSPECTION_DATABASE_OID=' + binding_oid]
        f.copy(ROOT / 'runtime/prebuilt-discourse/merge_inspection_access.rb', helper)
        username = 'silo_inspect_' + secrets.token_hex(4)
        guest_dir = '/tmp/silo-inspection-' + secrets.token_hex(8)
        pristine_oid = f.sql("SELECT oid FROM pg_database WHERE datname='invented_pristine'")
        wrong_binding = f.runner(helper, ['SILO_INSPECTION_ACTION=create', 'SILO_INSPECTION_USERNAME=' + username,
            'SILO_INSPECTION_KEY_DIR=' + guest_dir, 'SILO_INSPECTION_DATABASE=discourse',
            'SILO_INSPECTION_DATABASE_OID=' + pristine_oid], check=False)
        self.assertNotEqual(0, wrong_binding.returncode, 'same database name must not bypass clone OID binding')
        self.assertIn(b'MERGE_INSPECTION_REFUSED: database binding', wrong_binding.stderr)
        self.assertEqual('0', f.sql("SELECT count(*) FROM users WHERE username='" + username + "'", 'discourse'))
        result = f.runner(helper, ['SILO_INSPECTION_ACTION=create', 'SILO_INSPECTION_USERNAME=' + username,
                                   'SILO_INSPECTION_KEY_DIR=' + guest_dir] + binding)
        lines = [line[10:] for line in result.stdout.decode().splitlines() if line.startswith('SILO_JSON:')]
        self.assertEqual(1, len(lines))
        facts = json.loads(lines[0])
        self.assertEqual('discourse', facts['database'])
        self.assertEqual(binding_oid, facts['database_oid'])
        self.assertEqual('read_only', facts['scope_mode'])
        self.assertEqual(['global:read'], facts['scopes'])
        self.assertEqual('700', f.docker('exec', f.web, 'stat', '-c', '%a', guest_dir).stdout.decode().strip())
        self.assertEqual('600', f.docker('exec', f.web, 'stat', '-c', '%a', guest_dir + '/key').stdout.decode().strip())
        before_posts = f.sql('SELECT count(*) FROM posts', 'discourse')
        before_title = f.sql("SELECT value FROM site_settings WHERE name='title'", 'discourse')
        key_path = f.private / 'inspection.key'
        f.docker('cp', f.web + ':' + guest_dir + '/key', str(key_path))
        self.assertEqual(0o600, key_path.stat().st_mode & 0o777)
        key = key_path.read_bytes()
        self.assertTrue(re.fullmatch(b'[0-9a-f]{64}', key) is not None)
        # Key stays in a file: HTTP requests run inside the container, no secret argv/stdout.
        probe = f.private / 'http_probe.rb'
        probe.write_text('''require "net/http"
require "json"
key = File.read(ENV.fetch("SILO_KEY_PATH"))
uri = URI("http://127.0.0.1/admin/users/list/active.json")
request = Net::HTTP::Get.new(uri)
request["Host"] = "merge-fixture.invalid"
request["Api-Key"] = key
request["Api-Username"] = ENV.fetch("SILO_USERNAME")
get = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
request = Net::HTTP::Post.new(URI("http://127.0.0.1/posts.json"))
request["Host"] = "merge-fixture.invalid"
request["Api-Key"] = key
request["Api-Username"] = ENV.fetch("SILO_USERNAME")
request.set_form_data(title: "Must never be written by inspection", raw: "Invented forbidden mutation")
post = Net::HTTP.start(uri.host, uri.port) { |http| http.request(request) }
puts JSON.generate(get: get.code.to_i, post: post.code.to_i)
''')
        f.copy(probe, '/tmp/http_probe.rb')
        def http():
            response = f.docker('exec', '-e', 'SILO_KEY_PATH=' + guest_dir + '/key', '-e', 'SILO_USERNAME=' + username,
                                f.web, 'ruby', '/tmp/http_probe.rb')
            return json.loads(response.stdout)
        self.assertEqual({'get': 200, 'post': 403}, http())
        self.assertEqual(before_posts, f.sql('SELECT count(*) FROM posts', 'discourse'))
        self.assertEqual(before_title, f.sql("SELECT value FROM site_settings WHERE name='title'", 'discourse'))
        profile = f.private / 'mcp-profile.json'
        profile.write_text(json.dumps(mcp.mcp_profile({'username': username}, key.decode())))
        profile.chmod(0o600)
        f.allowed_binds[f.name + '-connector'] = {
            '/opt/discourse-mcp': str(install.resolve()), '/config/profile.json': str(profile.resolve())}
        connector = f.container('connector', image, '-i', '--read-only',
            '--tmpfs', '/tmp:rw,size=64m,mode=1777', '--user', f'{os.getuid()}:{os.getgid()}',
            '--cap-drop', 'ALL', '--security-opt', 'no-new-privileges', '--log-driver', 'none',
            '-e', 'HOME=/tmp', '--mount', f'type=bind,src={install.resolve()},dst=/opt/discourse-mcp,readonly',
            '--mount', f'type=bind,src={profile.resolve()},dst=/config/profile.json,readonly',
            '--entrypoint', 'node', command=('/opt/discourse-mcp/' + entry, '--profile', '/config/profile.json'), start=False)
        def client():
            rpc = JsonRpc(f, connector)
            self.addCleanup(rpc.close)
            rpc.initialize()
            return rpc
        rpc = client()
        f.assert_isolation()
        tools = rpc.request('tools/list', {})['tools']
        self.assertEqual(mcp.EXPECTED_TOOLS, {tool['name'] for tool in tools}, 'pinned read-tool catalog drifted')
        self.assertIn('discourse_list_categories', [tool['name'] for tool in tools])
        # Some pinned legacy read tools omit annotations. Require a closed read-verb
        # catalog, reject explicit write hints, and check the new category tool's hint.
        self.assertTrue(all(re.fullmatch(r'discourse_(?:get_|read_|list_|filter_|search(?:_|$))[a-z_]*',
                                        tool['name']) for tool in tools), 'connector advertised a non-read tool')
        self.assertTrue(all(tool.get('annotations', {}).get('readOnlyHint') is not False for tool in tools),
                        'connector advertised an explicit write tool')
        category_tool = next(tool for tool in tools if tool['name'] == 'discourse_list_categories')
        self.assertIs(category_tool['annotations']['readOnlyHint'], True)
        arguments = {'max_pages': 4, 'max_requests': 6, 'deadline_ms': 20000}
        listed = rpc.request('tools/call', {'name': 'discourse_list_categories', 'arguments': arguments})
        self.assertFalse(listed.get('isError', False), 'real category MCP call failed; response suppressed')
        directory = listed.get('structuredContent')
        if directory is None:
            directory = json.loads(next(item['text'] for item in listed['content'] if item.get('type') == 'text'))
        found = [item for item in directory['categories'] if item['id'] == category['id']]
        self.assertEqual(1, len(found), 'restricted inspection category missing from real MCP result')
        record = found[0]
        self.assertEqual(category['name'], record['name'])
        self.assertEqual(category['slug'], record['slug'])
        self.assertIs(record['read_restricted'], True)
        self.assertIsNone(record['parent_category_id'])
        self.assertIsNone(record['pid'])
        self.assertIsInstance(record['topic_count'], int)
        self.assertIsInstance(record['post_count'], int)
        # GET fallback does not necessarily carry ACLs. Missing perms means unknown,
        # not public/everyone. If provided, compare against the real DB restriction.
        if 'perms' in record:
            self.assertEqual([{'gid': category['group_id'], 'perm': 1}], record['perms'])
        meta = directory['meta']
        self.assertEqual(len(directory['categories']), meta['total'])
        self.assertIs(meta['complete'], False, 'read-only GET fallback must not claim exhaustive discovery')
        self.assertIs(meta['has_more'], True)
        self.assertIsNone(meta['reported_total'])
        self.assertIn(meta['truncated_reason'], ('legacy_site_json', 'no_new_ids', 'page_limit'))
        missing_username = 'silo_inspect_' + secrets.token_hex(4)
        self.assertEqual('0', f.sql("SELECT count(*) FROM users WHERE username='" + missing_username + "'", 'discourse'))
        foreign = f.runner(helper, ['SILO_INSPECTION_ACTION=revoke', 'SILO_INSPECTION_USERNAME=' + missing_username,
                                   'SILO_INSPECTION_KEY_IDS=' + str(facts['api_key_id'])] + binding, check=False)
        self.assertNotEqual(0, foreign.returncode, 'missing identity must not authorize foreign key revocation')
        self.assertIn(b'MERGE_INSPECTION_REFUSED: key ownership', foreign.stderr)
        self.assertEqual('1', f.sql('SELECT count(*) FROM api_keys WHERE id=' + str(facts['api_key_id']) +
                                   ' AND revoked_at IS NULL', 'discourse'))
        self.assertEqual(200, http()['get'])
        revoked = f.runner(helper, ['SILO_INSPECTION_ACTION=revoke', 'SILO_INSPECTION_USERNAME=' + username,
                                   'SILO_INSPECTION_KEY_IDS=' + str(facts['api_key_id']),
                                   'SILO_INSPECTION_MINT_ACKNOWLEDGED=1'] + binding)
        self.assertIn(b'"active_remaining":0', revoked.stdout)
        self.assertNotEqual(200, http()['get'])
        # Change the directory cache key, testing revocation on an existing session too.
        denied = rpc.request('tools/call', {'name': 'discourse_list_categories',
                             'arguments': dict(arguments, term='revoked-' + f.token)})
        self.assertIs(denied.get('isError'), True, 'revoked credential still allowed an uncached MCP read')
        rpc.close()
        f.docker('stop', '--time', '5', connector)
        # Fresh bootstrap validates /about.json and must now refuse the revoked key.
        revoked_rpc = JsonRpc(f, connector)
        self.addCleanup(revoked_rpc.close)
        with self.assertRaisesRegex(AssertionError, 'MCP exited before response'):
            revoked_rpc.initialize()
        revoked_rpc.close()
        self.assertNotEqual(0, f.owned('container', connector)['State']['ExitCode'])
        self.source_role_hba(f)
        f.docker('exec', f.web, 'rm', '-rf', guest_dir, helper, '/tmp/http_probe.rb', '/tmp/restricted_category.rb')
        f.docker('stop', '--time', '30', f.web)
        f.sql('ALTER DATABASE discourse ALLOW_CONNECTIONS false')
        f.sql("SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='discourse'")
        f.sql('DROP DATABASE discourse')
        f.sql('ALTER DATABASE invented_pristine RENAME TO discourse')
        f.sql('ALTER DATABASE discourse ALLOW_CONNECTIONS true')
        self.assertEqual('0', f.sql("SELECT count(*) FROM categories WHERE slug='" + category['slug'] + "'", 'discourse'))
        self.assertEqual('0', f.sql("SELECT count(*) FROM users WHERE username='" + username + "'", 'discourse'))
        self.assertEqual('0', f.sql("SELECT count(*) FROM api_keys WHERE description='SiloMigrate merge inspection (local, read-only)'", 'discourse'))
        # A deliverable logical checkpoint is checked without printing or persisting its contents.
        dump = f.docker('exec', f.db, 'pg_dump', '-U', 'postgres', '-d', 'discourse', timeout=120).stdout
        self.assertFalse(username.encode() in dump, 'inspection identity leaked into clean checkpoint')
        self.assertFalse(key in dump, 'inspection key leaked into clean checkpoint')
        self.assertTrue(all(key not in output for output in f.outputs), 'secret leaked to subprocess output')


if __name__ == '__main__':
    unittest.main()
