"""Removing a project, or starting it over (bin/project_remove.py). Run: python3 -I -B test/project_remove_test.py.

Files, folders, locks, the MCP settings file and term-llm's chat database (SQLite, with its foreign
keys) are real. Docker is faked and records what it was asked; `term-llm` is a small stand-in that
deletes a chat the way the real CLI does, so deleting a parent before its child fails.
"""
import base64
import fcntl
import http.server
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import sys
import tempfile
import threading
import types
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
RUN_A, RUN_B = 'run-' + 'a' * 32, 'run-' + 'b' * 32
OTHER_RUN = 'run-' + 'f' * 32
REF = 'upl_' + 'Q' * 43
OTHER_REF = 'upl_' + 'Z' * 43


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


FAKE_TERM_LLM = r'''#!/usr/bin/env python3
import os, sqlite3, sys
args = sys.argv[1:]
log = os.environ.get("FAKE_TERM_LLM_LOG")
if log:
    with open(log, "a") as handle:
        handle.write(" ".join(args) + "\n")
if args[:3] == ["service", "token", "web"]:
    print("tok_" + "x" * 30)
    sys.exit(0)
if args[:2] == ["sessions", "delete"] and len(args) == 4 and args[2] == "--":
    db = os.path.join(os.environ["HOME"], ".local/share/term-llm/sessions.db")
    con = sqlite3.connect(db)
    con.execute("PRAGMA foreign_keys = ON")
    try:
        deleted = con.execute("DELETE FROM sessions WHERE id = ?", (args[3],)).rowcount
        con.commit()
    except sqlite3.IntegrityError as error:
        print("failed to delete session: " + str(error), file=sys.stderr)
        sys.exit(1)
    sys.exit(0 if deleted else 1)
sys.exit(2)
'''


class FakeDocker:
    """Containers, networks and volumes with labels; renders the --format templates the code uses."""

    def __init__(self):
        self.calls = []
        self.objects = {'container': {}, 'network': {}, 'volume': {}}
        self.stuck = set()
        self.down = False

    def add(self, kind, identity, labels=None, state='running', name=None):
        self.objects[kind][identity] = {'labels': labels or {}, 'state': state, 'name': name or identity}

    def render(self, template, identity, record):
        def field(match):
            if match[1]:
                return record['labels'].get(match[1], '')
            return {'.ID': identity, '.Id': identity, '.Name': record['name'], '.State': record['state']}[match[2]]
        return re.sub(r'\{\{(?:\.Label "([^"]+)"|(\.[A-Za-z]+))\}\}', field, template)

    def __call__(self, argv, timeout=120, input=None):
        self.calls.append(list(argv))
        if self.down:
            return subprocess.CompletedProcess(argv, 1, b'', b'Cannot connect to the Docker daemon')
        kind = {'ps': 'container', 'rm': 'container', 'container': 'container', 'network': 'network', 'volume': 'volume'}.get(argv[0])
        verb = argv[0] if argv[0] in ('ps', 'rm') else argv[1]
        out, code = b'', 0
        if verb in ('ps', 'ls'):
            template = argv[argv.index('--format') + 1]
            out = ''.join(self.render(template, i, r) + '\n' for i, r in self.objects[kind].items()).encode()
        elif verb in ('rm',):
            identity = argv[-1]
            if identity in self.stuck or identity not in self.objects[kind]:
                code = 1
            else:
                del self.objects[kind][identity]
        elif verb == 'inspect':
            identity = argv[-1]
            record = self.objects[kind].get(identity)
            if record is None:
                return subprocess.CompletedProcess(argv, 1, b'', b'Error: No such object')
            template = argv[argv.index('--format') + 1]
            out = (self.render(template.split('\t')[0], identity, record) + '\t' + json.dumps(record['labels'])).encode()
        return subprocess.CompletedProcess(argv, code, out, b'')

    def removed(self):
        return [argv[-1] for argv in self.calls if argv[0] == 'rm' or (len(argv) > 1 and argv[1] == 'rm')]


class Archive(http.server.BaseHTTPRequestHandler):
    seen = []

    def do_PATCH(self):
        body = self.rfile.read(int(self.headers['Content-Length']))
        Archive.seen.append((self.path, self.headers.get('authorization'), json.loads(body)))
        payload = b'{}'
        self.send_response(200)
        self.send_header('Content-Length', str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


class RemoveTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.top = Path(self.temp.name)
        self.base = self.top / 'workspaces'
        self.home = self.top / 'home'
        self.data = self.home / '.local/share/term-llm'
        self.dt = load('data_tools', 'bin/data_tools.py')
        self.pr = load('project_remove', 'bin/project_remove.py')
        self.docker = FakeDocker()
        patcher = mock.patch.object(self.dt, 'docker', side_effect=self.docker)
        patcher.start()
        self.addCleanup(patcher.stop)
        bin_dir = self.top / 'bin'  # where `silo` keeps term-llm: <prefix>/bin/term-llm
        bin_dir.mkdir()
        (bin_dir / 'term-llm').write_text(FAKE_TERM_LLM.replace('/usr/bin/env python3', sys.executable))
        (bin_dir / 'term-llm').chmod(0o755)
        self.log = self.top / 'term-llm.log'
        env = mock.patch.dict(os.environ, {'HOME': str(self.home), 'FAKE_TERM_LLM_LOG': str(self.log)})
        env.start()
        self.addCleanup(env.stop)
        for name in ('XDG_DATA_HOME', 'XDG_CONFIG_HOME'):
            os.environ.pop(name, None)
        self.make_project('arc')

    # -- a project with everything a project can leave -----------------------------------------

    def make_project(self, name):
        root = self.base / name
        named = root / '.silo-migrate/named'
        (named / 'standard').mkdir(parents=True)
        (root / '.silo-migrate/data/pending').mkdir(parents=True)
        for area in ('inputs/derived', 'work/job-1', 'converter/fixtures'):
            (root / area).mkdir(parents=True)
        dump = root / 'inputs/dump.sql.gz'
        dump.write_bytes(b'customer bytes')
        dump.chmod(0o400)
        (root / 'inputs/settings.yml').write_text('x: 1\n')
        (root / 'inputs/derived/job-1-out.sql').write_text('derived')
        (root / 'work/job-1/out.sql').write_text('derived')
        (root / 'converter/fixtures/a.json').write_text('{}')
        (root / 'converter/fixtures').chmod(0o500)  # a read-only folder must not stop the removal
        state = {'inputs': {'input-1': {'id': 'input-1', 'path': base64.b64encode(b'inputs/dump.sql.gz').decode(), 'bytes': 14},
                            'input-2': {'id': 'input-2', 'path': base64.b64encode(b'inputs/derived/job-1-out.sql').decode(), 'bytes': 7}},
                 'datasets': {}}
        (named / 'state.json').write_text(json.dumps(state))
        standard = {'config': {}, 'plans': {'plan-1': {}, 'plan-2': {}}, 'findings': {'finding-1': {}},
                    'runs': {RUN_A: {'status': 'completed', 'instances': {'review': 'site-a'}}, RUN_B: {'status': 'failed', 'instances': {}}},
                    'instances': {'site-a': {'name': 'site-a', 'state': 'running', 'role': 'review', 'run_id': RUN_A,
                                             'containers': {'web': 'c-web-a'}, 'networks': ['site-a-int'], 'volumes': ['site-a-pg']},
                                  'site-old': {'name': 'site-old', 'state': 'running', 'role': 'review', 'run_id': 'run-' + 'c' * 32,
                                               'containers': {'web': 'c-legacy'}, 'networks': [], 'volumes': []}}}
        (named / 'standard/state.json').write_text(json.dumps(standard))
        (root / '.silo-migrate/data/provenance.jsonl').write_text(
            json.dumps({'event': 'take', 'from': 'intake/sub/dump.sql.gz', 'path': 'inputs/dump.sql.gz', 'input_id': 'input-1'}) + '\n'
            + json.dumps({'event': 'derived', 'from': 'work/job-1/out.sql', 'path': 'inputs/derived/job-1-out.sql'}) + '\nnot json\n')
        drop = self.top / 'intake' / name
        drop.mkdir(parents=True)
        (drop / 'later.csv').write_text('not taken yet')
        chats = self.home / 'projects' / name
        chats.mkdir(parents=True)
        (chats / 'scratch.txt').write_text('left by a chat')
        # Docker: this project's objects, by label and by name; another project's, untouched.
        d = self.docker
        d.add('container', 'c-src', {'silo.workspace': name, 'silo.role': 'source-db'})
        d.add('container', 'c-dbhub', {'silo.workspace': name, 'silo.role': 'dbhub'})
        d.add('container', 'c-job', {'silo.workspace': name, 'silo.role': 'data-job'}, state='exited')
        d.add('container', 'c-web-a', {'silo-migrate.run': RUN_A, 'silo-migrate.role': 'review', 'silo-migrate.instance': 'site-a'})
        d.add('container', 'c-conv-b', {'silo-migrate.run': RUN_B, 'silo-migrate.instance': 'b-conversion'}, state='exited')
        d.add('container', 'c-legacy', {'silo-migrate.instance': 'site-old'})  # a site record names it, but no label of this project's
        d.add('container', 'c-other', {'silo.workspace': 'other', 'silo.role': 'source-db'})
        d.add('container', 'c-other-run', {'silo-migrate.run': OTHER_RUN, 'silo-migrate.role': 'review'})
        d.add('network', 'n-src', {'silo.workspace': name}, name='silo-src-' + name)
        d.add('network', 'site-a-int', {'silo-migrate.run': RUN_A})
        d.add('network', 'n-other', {'silo.workspace': 'other'})
        d.add('volume', 'silo-src-%s-data' % name)  # made by docker run --mount: no labels
        d.add('volume', 'site-a-pg', {'silo-migrate.run': RUN_A})
        d.add('volume', 'silo-src-other-data')
        # term-llm: MCP settings, chats, attachments, handover files.
        config = self.home / '.config/term-llm'
        config.mkdir(parents=True)
        (config / 'mcp.json').write_text(json.dumps({'servers': {
            'db-' + name: {'command': '/x/silo-migrate-control', 'args': ['dbhub', name], 'agents': ['migration-data']},
            'db-other': {'command': '/x/silo-migrate-control', 'args': ['dbhub', 'other']}, 'github': {'command': 'gh'}}}))
        self.make_chats(name)

    def make_chats(self, name):
        self.data.mkdir(parents=True, exist_ok=True)
        (self.data / 'uploads').mkdir(exist_ok=True)
        (self.data / 'upload-refs').mkdir(exist_ok=True)
        folder = str(self.home / 'projects' / name)
        con = sqlite3.connect(self.data / 'sessions.db')
        con.executescript('''
            CREATE TABLE IF NOT EXISTS sessions (id TEXT PRIMARY KEY, project_id TEXT, cwd TEXT, parent_id TEXT REFERENCES sessions(id), root_id TEXT REFERENCES sessions(id));
            CREATE TABLE IF NOT EXISTS messages (id INTEGER PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE, parts TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS projects (id TEXT PRIMARY KEY, name TEXT, canonical_dir TEXT NOT NULL UNIQUE, archived_at DATETIME);
            CREATE TABLE IF NOT EXISTS serve_response_lifecycle (response_id TEXT PRIMARY KEY, session_id TEXT, state TEXT);''')
        con.execute('INSERT INTO projects VALUES (?, ?, ?, NULL)', ('prj_' + 'a' * 16, name, folder))
        con.execute('INSERT INTO projects VALUES (?, ?, ?, NULL)', ('prj_' + 'f' * 16, 'other', str(self.home / 'projects/other')))
        rows = [('s-main', 'prj_' + 'a' * 16, folder, None, None),
                ('s-old', None, folder + '/sub', None, None),           # from before projects: found by its folder
                ('s-child', None, '/elsewhere', 's-main', None),        # an agent's chat: found through its parent
                ('s-grandchild', None, '/elsewhere', 's-child', None),
                ('s-side', None, folder, None, 's-main'),
                ('s-other', 'prj_' + 'f' * 16, str(self.home / 'projects/other'), None, None)]
        con.executemany('INSERT INTO sessions VALUES (?, ?, ?, ?, ?)', rows)
        uploads = str(self.data / 'uploads')
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-main', json.dumps([{'type': 'image', 'image_path': uploads + '/shot_1.png'}])))
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-grandchild', json.dumps([{'type': 'text', 'text': 'see ' + REF + ' and ' + uploads + '/notes_2.txt.'}])))
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-other', json.dumps([{'type': 'input_file', 'upload_id': OTHER_REF, 'path': uploads + '/theirs_3.png'}])))
        con.commit()
        con.close()
        for upload in ('shot_1.png', 'notes_2.txt', 'theirs_3.png', REF, OTHER_REF):
            (self.data / 'uploads' / upload).write_text('attachment')
        for ref in (REF, OTHER_REF):
            (self.data / 'upload-refs' / (ref + '.json')).write_text('{}')
        for owner in (folder, str(self.home / 'projects/other')):
            handover = self.data / 'handover' / self.pr.handover_name(owner)
            handover.mkdir(parents=True)
            (handover / 'plan.md').write_text('handover')

    def removal(self, name='arc', keep=False):
        host = types.SimpleNamespace()
        ws = self.dt.Workspace(self.base, name, ROOT, host, {}, None)
        ws.prefix = self.top  # as an installed release finds it; the test's repo isn't under releases/
        ws.intake = self.top / 'intake' / name
        removal = self.pr.Removal(self.dt, ws, keep)
        removal.record_file = self.top / 'state/removed-projects.jsonl'
        return removal

    def sessions(self):
        con = sqlite3.connect(self.data / 'sessions.db')
        try:
            return sorted(row[0] for row in con.execute('SELECT id FROM sessions'))
        finally:
            con.close()

    def mcp(self):
        return sorted(json.loads((self.home / '.config/term-llm/mcp.json').read_text())['servers'])

    def everything_on_disk(self):
        return sorted(str(p.relative_to(self.top)) for p in self.top.rglob('*'))

    # -- the plan ------------------------------------------------------------------------------

    def test_the_plan_lists_what_goes_and_what_stays_and_changes_nothing(self):
        before = self.everything_on_disk()
        plan = self.removal(keep=True).plan()
        self.assertEqual(before, self.everything_on_disk())
        self.assertEqual([], self.docker.removed())
        self.assertTrue(plan['exists'])
        self.assertEqual([], plan['blocked'])
        self.assertEqual('start_over', plan['mode'])
        removed = [item['text'] for item in plan['removed']]
        kept = [item['text'] for item in plan['kept']]
        self.assertEqual('Work: 2 plans, 2 runs, 1 finding, labels, notes and decisions', removed[0])
        self.assertIn('Converter checkout on this server', removed)
        self.assertEqual(9, len(self.mine()))
        self.assertIn('1 review site and the source database (9 Docker objects)', removed)
        self.assertIn('2 chats in the web UI, with 3 attachments', removed)  # s-main and s-old; the rest are agents' and side chats
        self.assertIn('1 file in the chats\' folder', removed)
        self.assertIn('Received files: dump.sql.gz, back in the drop folder to label again', kept)
        self.assertIn('1 other file in the drop folder', kept)
        self.assertIn('The web UI project, with no chats', kept)
        received = next(item for item in plan['kept'] if item['text'].startswith('Received'))
        self.assertEqual(14, received['bytes'])

    def mine(self):
        return [i for k in self.docker.objects.values() for i, r in k.items()
                if r['labels'].get('silo.workspace') == 'arc' or r['labels'].get('silo-migrate.run') in (RUN_A, RUN_B)
                or i == 'silo-src-arc-data']

    def test_a_full_removal_plan_lists_the_received_files_and_drop_folder_as_going(self):
        plan = self.removal().plan()
        removed = [item['text'] for item in plan['removed']]
        self.assertIn('Received files: dump.sql.gz', removed)
        self.assertIn('The drop folder, with 1 file not taken yet', removed)
        self.assertIn('The web UI project (archived: term-llm can\'t delete projects)', removed)
        self.assertEqual(['The converter\'s branch and pull requests on GitHub'], [item['text'] for item in plan['kept']])

    def test_unpushed_converter_work_is_called_out(self):
        (self.base / 'arc/converter/.git').mkdir()
        removal = self.removal()
        calls = []
        removal.ws.host = types.SimpleNamespace(converter_config_safe=lambda checkout: calls.append('safe'),
                                                converter_git=lambda checkout: ['git'],
                                                capture=lambda argv: '2' if 'rev-list' in argv else ' M x.rb')
        item = next(item for item in removal.plan()['removed'] if item['text'].startswith('Converter'))
        self.assertEqual('Converter checkout on this server, with 2 commits and changes not committed that aren\'t on GitHub', item['text'])
        self.assertTrue(item['warn'])
        self.assertEqual(['safe'], calls)  # its .git/config is checked before any git command
        def unsafe(checkout):
            raise ValueError('STANDARD_CONVERTER_CONFIG')
        removal.ws.host.converter_config_safe = unsafe
        item = next(item for item in removal.plan()['removed'] if item['text'].startswith('Converter'))
        self.assertIn("couldn't check it", item['text'])

    # -- start over ------------------------------------------------------------------------------

    def test_start_over_returns_the_received_files_and_removes_everything_else(self):
        result = self.removal(keep=True).run('arc', 'Ruben')
        self.assertEqual('done', result['status'])
        # The received file is back where it came from, the account's to label again.
        back = self.top / 'intake/arc/sub/dump.sql.gz'
        self.assertEqual(b'customer bytes', back.read_bytes())
        self.assertEqual(0o600, stat.S_IMODE(back.stat().st_mode))
        self.assertEqual([{'name': 'dump.sql.gz', 'bytes': 14, 'to': 'sub/dump.sql.gz'}], result['returned'])
        self.assertTrue((self.top / 'intake/arc/later.csv').exists())
        self.assertFalse((self.base / 'arc').exists())
        # The chats' folder stays (it is the web UI project's folder), empty.
        self.assertEqual([], list((self.home / 'projects/arc').iterdir()))
        # Chats: this project's and its agents', children first; another project's stay.
        self.assertEqual(['s-other'], self.sessions())
        order = [line.split()[-1] for line in self.log.read_text().splitlines() if line.startswith('sessions delete')]
        self.assertLess(order.index('s-grandchild'), order.index('s-child'))
        self.assertLess(order.index('s-child'), order.index('s-main'))
        self.assertLess(order.index('s-side'), order.index('s-main'))
        # Attachments its chats named go; another project's stay. So do its handover files.
        uploads = sorted(p.name for p in (self.data / 'uploads').iterdir())
        self.assertEqual(sorted([OTHER_REF, 'theirs_3.png']), uploads)
        self.assertEqual([OTHER_REF + '.json'], [p.name for p in (self.data / 'upload-refs').iterdir()])
        self.assertEqual([self.pr.handover_name(str(self.home / 'projects/other'))], [p.name for p in (self.data / 'handover').iterdir()])
        # Docker: its objects went, by label, by name and by recorded ID; another project's didn't.
        left = sorted(i for kind in self.docker.objects.values() for i in kind)
        # Only exact labels count: an object a site record names without one of them stays.
        self.assertEqual(['c-legacy', 'c-other', 'c-other-run', 'n-other', 'silo-src-other-data'], left)
        self.assertEqual(['db-other', 'github'], self.mcp())
        self.assertEqual('kept', result['removed']['web_project'])
        self.assertNotIn('service token', self.log.read_text())  # nothing is archived on Start over
        # One record, no file names.
        lines = [json.loads(line) for line in (self.top / 'state/removed-projects.jsonl').read_text().splitlines()]
        self.assertEqual(['started', 'finished'], [line['event'] for line in lines])
        self.assertEqual(('arc', 'start_over', 'Ruben'), (lines[1]['project'], lines[1]['mode'], lines[1]['by']))
        self.assertEqual((5, 3, 1), (lines[1]['chats'], lines[1]['attachments'], lines[1]['returned']))
        self.assertNotIn('dump.sql.gz', (self.top / 'state/removed-projects.jsonl').read_text())
        self.assertEqual("Next: start a new chat with migration-data in project arc and ask what's next. It sets up the workspace; "
                         'then label the returned files on the Files tab.', result['next'])

    def test_a_file_in_the_way_puts_the_returned_file_beside_it_or_stops(self):
        provenance = self.base / 'arc/.silo-migrate/data/provenance.jsonl'
        provenance.write_text(json.dumps({'event': 'take', 'from': 'intake/sub/export.sql.gz', 'path': 'inputs/dump.sql.gz'}) + '\n')
        (self.top / 'intake/arc/sub').mkdir()
        (self.top / 'intake/arc/sub/export.sql.gz').write_text('a newer delivery')
        plan = self.removal(keep=True).plan()
        self.assertEqual([], plan['blocked'])  # the name it had in inputs/ is free beside it
        result = self.removal(keep=True).run('arc', None)
        self.assertEqual('a newer delivery', (self.top / 'intake/arc/sub/export.sql.gz').read_text())
        self.assertEqual(b'customer bytes', (self.top / 'intake/arc/sub/dump.sql.gz').read_bytes())
        self.assertEqual('sub/dump.sql.gz', result['returned'][0]['to'])

    def test_both_places_taken_stops_before_anything_changes(self):
        provenance = self.base / 'arc/.silo-migrate/data/provenance.jsonl'
        provenance.write_text(json.dumps({'event': 'take', 'from': 'intake/dump.sql.gz', 'path': 'inputs/dump.sql.gz'}) + '\n')
        (self.top / 'intake/arc/dump.sql.gz').write_text('in the way')
        before = self.everything_on_disk()
        plan = self.removal(keep=True).plan()
        self.assertEqual(['STANDARD_REMOVE_DROP_TAKEN'], [b['code'] for b in plan['blocked']])
        with self.assertRaisesRegex(ValueError, 'STANDARD_REMOVE_DROP_TAKEN'):
            self.removal(keep=True).run('arc', None)
        self.assertEqual([], self.docker.removed())
        self.assertEqual(before, [p for p in self.everything_on_disk() if p != 'state' and not p.startswith('state/')])

    def test_a_take_stopped_after_its_move_still_goes_back(self):
        pending = self.base / 'arc/.silo-migrate/data/pending/abc.json'
        stray = self.base / 'arc/inputs/second.sql'
        stray.write_text('moved, not registered')
        info = stray.stat()
        pending.write_text(json.dumps({'dev': info.st_dev, 'ino': info.st_ino, 'provenance': {'event': 'take', 'from': 'intake/second.sql'}}))
        result = self.removal(keep=True).run('arc', None)
        self.assertEqual(['dump.sql.gz', 'second.sql'], sorted(item['name'] for item in result['returned']))
        self.assertEqual('moved, not registered', (self.top / 'intake/arc/second.sql').read_text())

    # -- remove ----------------------------------------------------------------------------------

    def test_remove_takes_everything_and_archives_the_web_ui_project(self):
        server = http.server.HTTPServer(('127.0.0.1', 0), Archive)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        service = self.home / '.config/term-llm/services/web'
        service.mkdir(parents=True)
        (service / 'service.json').write_text(json.dumps({'url': 'http://127.0.0.1:%d/' % server.server_port, 'args': ['--projects']}))
        Archive.seen = []
        result = self.removal().run('arc', 'Ruben')
        self.assertFalse((self.base / 'arc').exists())
        self.assertFalse((self.top / 'intake/arc').exists())
        self.assertFalse((self.home / 'projects/arc').exists())
        self.assertTrue((self.home / 'projects').exists())
        self.assertEqual(['s-other'], self.sessions())
        self.assertEqual([('/v1/projects/prj_' + 'a' * 16, 'Bearer tok_' + 'x' * 30, {'archived': True})], Archive.seen)
        self.assertEqual('archived', result['removed']['web_project'])
        self.assertEqual([], result['returned'])
        self.assertEqual([], result['notes'])
        self.assertIn('Nothing of arc is left', result['next'])

    def test_remove_without_the_web_service_says_how_to_archive_by_hand(self):
        result = self.removal().run('arc', None)
        self.assertEqual(['The web UI project is still listed: archive it in the web UI (Projects, arc, Archive).'], result['notes'])

    # -- refusals --------------------------------------------------------------------------------

    def test_the_typed_name_must_match(self):
        before = self.everything_on_disk()
        for typed in ('', 'Arc', 'arc ', 'other'):
            with self.assertRaisesRegex(ValueError, 'STANDARD_CONFIRMATION_REQUIRED'):
                self.removal().run(typed, None)
        self.assertEqual(before, self.everything_on_disk())
        self.assertEqual([], self.docker.calls)

    def test_busy_projects_are_refused_with_a_plain_reason(self):
        standard = self.base / 'arc/.silo-migrate/named/standard/state.json'
        state = json.loads(standard.read_text())
        state['runs'][RUN_B]['status'] = 'running'
        standard.write_text(json.dumps(state))
        self.check_refused('STANDARD_BUSY_RUN', 'A run is still running')
        state['runs'][RUN_B]['status'] = 'failed'
        standard.write_text(json.dumps(state))
        self.docker.objects['container']['c-job']['state'] = 'running'
        self.check_refused('STANDARD_BUSY_JOB', 'A data job is still running')
        self.docker.objects['container']['c-job']['state'] = 'exited'
        con = sqlite3.connect(self.data / 'sessions.db')
        con.execute("INSERT INTO serve_response_lifecycle VALUES ('r1', 's-grandchild', 'running')")
        con.commit()
        self.check_refused('STANDARD_BUSY_CHAT', 'still answering')
        con.execute("UPDATE serve_response_lifecycle SET state = 'completed'")
        con.commit()
        con.close()
        lock = os.open(self.base / 'arc/.silo-migrate/data/lock', os.O_RDWR | os.O_CREAT, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            self.check_refused('STANDARD_BUSY', 'busy right now')
        finally:
            os.close(lock)
        self.removal(keep=True).run('arc', None)  # and once nothing is busy, it goes ahead

    def check_refused(self, code, text):
        before = self.everything_on_disk()
        plan = self.removal(keep=True).plan()
        self.assertEqual([code], [b['code'] for b in plan['blocked']])
        self.assertIn(text, plan['blocked'][0]['text'])
        with self.assertRaisesRegex(ValueError, code):
            self.removal(keep=True).run('arc', None)
        self.assertEqual([], self.docker.removed())
        self.assertEqual(before, [p for p in self.everything_on_disk() if p != 'state' and not p.startswith('state/')])

    def test_links_and_unreadable_state_stop_it(self):
        (self.base / 'linked').symlink_to(self.base / 'arc')
        with self.assertRaisesRegex(ValueError, 'STANDARD_PATH_INVALID'):
            self.removal('linked').plan()
        (self.base / 'arc/.silo-migrate/named/standard/state.json').write_text('{broken')
        with self.assertRaisesRegex(ValueError, 'STANDARD_STATE_INVALID'):
            self.removal().plan()

    def test_nothing_there_is_said_plainly(self):
        plan = self.removal('ghost').plan()
        self.assertFalse(plan['exists'])
        with self.assertRaisesRegex(ValueError, 'STANDARD_REFERENCE_INVALID'):
            self.removal('ghost').run('ghost', None)

    def test_docker_down_stops_the_plan(self):
        self.docker.down = True
        with self.assertRaisesRegex(ValueError, 'STANDARD_DOCKER_UNAVAILABLE'):
            self.removal().plan()

    # -- stopped part-way, then run again ---------------------------------------------------------

    def test_a_stuck_container_stops_before_the_work_goes_and_a_second_run_finishes(self):
        self.docker.stuck.add('c-web-a')
        with mock.patch.object(self.pr.time, 'sleep'):
            with self.assertRaisesRegex(ValueError, r'STANDARD_REMOVE_INCOMPLETE: .*run it again \(the received files are already back in the drop folder\)'):
                self.removal(keep=True).run('arc', None)
        # The customer's file went back first; the work, the chats and the drop folder are all still there.
        self.assertEqual(b'customer bytes', (self.top / 'intake/arc/sub/dump.sql.gz').read_bytes())
        self.assertTrue((self.base / 'arc/.silo-migrate/named/standard/state.json').exists())
        self.assertEqual(6, len(self.sessions()))
        record = [json.loads(line) for line in (self.top / 'state/removed-projects.jsonl').read_text().splitlines()]
        self.assertEqual(('stopped', 'STANDARD_REMOVE_INCOMPLETE'), (record[-1]['event'], record[-1]['code']))
        self.docker.stuck.clear()
        self.removal(keep=True).run('arc', None)
        self.assertFalse((self.base / 'arc').exists())
        self.assertTrue((self.top / 'intake/arc/sub/dump.sql.gz').exists())
        self.assertEqual(['s-other'], self.sessions())

    def test_a_chat_that_cant_be_deleted_stops_before_the_files_go(self):
        con = sqlite3.connect(self.data / 'sessions.db')
        # Another project's chat that points at one of this project's: the real CLI refuses to delete
        # a chat something still points at, and so does the stand-in.
        con.execute("INSERT INTO sessions VALUES ('s-pinned', 'prj_x', '/x', NULL, NULL)")
        con.execute('CREATE TABLE side_refs (id TEXT REFERENCES sessions(id))')
        con.execute("INSERT INTO side_refs VALUES ('s-main')")
        con.commit()
        con.close()
        with self.assertRaisesRegex(ValueError, 'STANDARD_REMOVE_INCOMPLETE: 1 chat'):
            self.removal(keep=True).run('arc', None)
        self.assertTrue((self.base / 'arc/.silo-migrate/named/standard/state.json').exists())
        self.assertTrue((self.top / 'intake/arc/sub/dump.sql.gz').exists())

    # -- from the independent review ------------------------------------------------------------

    def test_an_attachment_another_chat_also_names_stays(self):
        con = sqlite3.connect(self.data / 'sessions.db')
        uploads = str(self.data / 'uploads')
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-other', json.dumps([{'type': 'text', 'text': 'same file: ' + uploads + '/shot_1.png and ' + REF}])))
        # A chat of this project quoting another chat's file doesn't make it this project's either.
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-main', json.dumps([{'type': 'text', 'text': 'look at ' + uploads + '/theirs_3.png'}])))
        con.commit()
        con.close()
        plan = self.removal(keep=True).plan()
        self.assertIn('2 chats in the web UI, with 1 attachment', [item['text'] for item in plan['removed']])
        self.removal(keep=True).run('arc', None)
        self.assertEqual(sorted([OTHER_REF, REF, 'shot_1.png', 'theirs_3.png']), sorted(p.name for p in (self.data / 'uploads').iterdir()))

    def test_busy_after_the_plan_was_shown_stops_before_anything_is_touched(self):
        removal = self.removal(keep=True)
        plan = removal.plan()
        self.assertEqual([], plan['blocked'])
        with mock.patch.object(self.pr.Removal, 'plan', return_value=plan):  # it was free when the engineer read it
            con = sqlite3.connect(self.data / 'sessions.db')
            con.execute("INSERT INTO serve_response_lifecycle VALUES ('r1', 's-child', 'running')")
            con.commit()
            con.close()
            before = self.everything_on_disk()
            with self.assertRaisesRegex(ValueError, 'STANDARD_BUSY_CHAT'):
                self.removal(keep=True).run('arc', None)
            unlocked = lambda paths: [p for p in paths if not p.startswith('state') and not p.endswith('lock')]  # it held the locks, then let go
            self.assertEqual(unlocked(before), unlocked(self.everything_on_disk()))
            self.assertEqual([], self.docker.removed())
            self.assertIn('db-arc', self.mcp())
            con = sqlite3.connect(self.data / 'sessions.db')
            con.execute("DELETE FROM serve_response_lifecycle")
            con.commit()
            con.close()
            self.docker.objects['container']['c-job']['state'] = 'running'
            with self.assertRaisesRegex(ValueError, 'STANDARD_BUSY_JOB'):
                self.removal(keep=True).run('arc', None)
            self.assertEqual([], self.docker.removed())

    def test_a_folder_in_projects_alone_is_not_a_project(self):
        (self.home / 'projects/tools').mkdir()
        (self.home / 'projects/tools/clone.txt').write_text('not a project')
        con = sqlite3.connect(self.data / 'sessions.db')
        con.execute("INSERT INTO sessions VALUES ('s-tools', NULL, ?, NULL, NULL)", (str(self.home / 'projects/tools'),))
        con.commit()
        con.close()
        self.assertFalse(self.removal('tools').plan()['exists'])
        with self.assertRaisesRegex(ValueError, 'STANDARD_REFERENCE_INVALID'):
            self.removal('tools').run('tools', None)
        self.assertTrue((self.home / 'projects/tools/clone.txt').exists())
        self.assertIn('s-tools', self.sessions())

    def test_another_projects_chat_started_from_this_one_is_not_taken(self):
        con = sqlite3.connect(self.data / 'sessions.db')
        con.execute("INSERT INTO sessions VALUES ('s-theirs', ?, ?, 's-main', NULL)", ('prj_' + 'f' * 16, str(self.home / 'projects/other')))
        con.execute("INSERT INTO sessions VALUES ('s-there', NULL, ?, 's-main', NULL)", (str(self.home / 'projects/other/sub'),))
        con.commit()
        con.close()
        ids = self.removal().chats()['ids']
        self.assertNotIn('s-theirs', ids)
        self.assertNotIn('s-there', ids)
        # Its parent can't go while they point at it: it says so before anything is touched.
        self.check_refused('STANDARD_REMOVE_LINKED_CHAT', 'A chat of another project was started from one of this project')
        self.assertTrue({'s-other', 's-theirs', 's-there'} <= set(self.sessions()))

    def test_agent_chats_that_ran_in_another_projects_folders_are_theirs(self):
        con = sqlite3.connect(self.data / 'sessions.db')
        con.execute("INSERT INTO sessions VALUES ('s-ws', NULL, ?, 's-main', NULL)", (str(self.base / 'other/work'),))
        con.execute("INSERT INTO sessions VALUES ('s-drop', NULL, ?, 's-main', NULL)", (str(self.top / 'intake/other'),))
        con.execute("INSERT INTO sessions VALUES ('s-mine', NULL, ?, 's-main', NULL)", (str(self.base / 'arc/work'),))
        con.commit()
        con.close()
        chats = self.removal().chats()
        self.assertIn('s-mine', chats['ids'])
        self.assertEqual(2, chats['linked'])
        self.assertNotIn('s-ws', chats['ids'])

    def test_a_shared_attachment_is_found_however_it_was_escaped(self):
        name = 'a&b<c>_9.png'
        (self.data / 'uploads' / name).write_text('shared')
        uploads = str(self.data / 'uploads')
        con = sqlite3.connect(self.data / 'sessions.db')
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-main', json.dumps([{'image_path': uploads + '/' + name}])))
        # As Go stores it in another chat: <, > and & escaped.
        go = json.dumps([{'image_path': uploads + '/' + name}]).replace('&', '\\u0026').replace('<', '\\u003c').replace('>', '\\u003e')
        con.execute('INSERT INTO messages (session_id, parts) VALUES (?, ?)', ('s-other', go))
        con.commit()
        con.close()
        self.assertNotIn(name, self.removal().chats()['uploads'])
        self.removal(keep=True).run('arc', None)
        self.assertTrue((self.data / 'uploads' / name).exists())

    def test_folders_of_another_user_block_it(self):
        real = self.pr.tree_facts
        workspace = self.base / 'arc'
        with mock.patch.object(self.pr, 'tree_facts', side_effect=lambda path: (0, 0, 1) if Path(path) == workspace else real(path)):
            self.check_refused('STANDARD_REMOVE_NOT_OWNED', 'belong to another user')

    def test_odd_records_are_skipped_and_an_unwritable_record_is_reported(self):
        provenance = self.base / 'arc/.silo-migrate/data/provenance.jsonl'
        provenance.write_text('[1]\n"x"\n' + provenance.read_text())
        (self.base / 'arc/.silo-migrate/data/pending/odd.json').write_text('{"provenance": "x"}')
        (self.top / 'state').write_text('a file where the folder should be')
        result = self.removal(keep=True).run('arc', None)
        self.assertEqual(1, len(result['returned']))
        self.assertEqual(["The record of this removal couldn't be written to " + str(self.top / 'state/removed-projects.jsonl') + '.'], result['notes'])

    def test_a_full_removal_stopped_before_its_last_step_is_found_and_finished(self):
        removal = self.removal()
        with mock.patch.object(self.pr.Removal, 'archive_web_project', side_effect=OSError('stopped')):
            with self.assertRaises(OSError):
                removal.run('arc', None)
        self.assertFalse((self.base / 'arc').exists())
        plan = self.removal().plan()
        self.assertTrue(plan['exists'])  # its web UI project is still there
        self.removal().run('arc', None)

    # -- entry point -----------------------------------------------------------------------------

    def test_arguments_and_list(self):
        (self.top / 'intake/newproj').mkdir()
        out = io.StringIO()
        with mock.patch('sys.stdout', out):
            self.pr.main(['remove-project', '--list'], {}, self.base, self.top / 'releases' / ('a' * 40), None, self.dt)
        self.assertEqual(['arc', 'newproj'], json.loads(out.getvalue())['projects'])
        for args in (['remove-project', 'arc'], ['remove-project', 'arc', '--confirm'], ['remove-project', 'arc', '--plan', '--force'],
                     ['remove-project', 'arc', '--confirm', 'arc', '--as', 'x'], ['remove-project', '../x', '--plan']):
            with self.assertRaisesRegex(ValueError, 'STANDARD_ARGUMENTS_INVALID'):
                self.pr.main(args, {}, self.base, ROOT, None, self.dt)
        with self.assertRaisesRegex(ValueError, 'STANDARD_ARGUMENTS_INVALID: by'):
            self.removal().run('arc', 'bad\nname')

    def test_no_agent_tool_can_reach_it(self):
        for path in (ROOT / 'integrations/term-llm').rglob('*'):
            if path.is_file() and path.suffix in ('.py', '.yaml', '.js') and 'widgets/project' not in str(path):
                self.assertNotIn('remove-project', path.read_text(errors='replace'), path)
        self.assertNotIn('remove', ' '.join(self.dt.OPS))


if __name__ == '__main__':
    unittest.main()
