"""The bundled Varnish theme: unmodified, credited, updatable. Run: python3 -I -B test/varnish_bundle_test.py."""
import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
EXTENSIONS = ROOT / 'integrations/term-llm/extensions'
VARNISH = EXTENSIONS / 'varnish'
THEME = EXTENSIONS / 'silo-theme'
SCRIPT = ROOT / 'script/update-varnish'


def load():
    loader = importlib.machinery.SourceFileLoader('update_varnish', str(SCRIPT))
    spec = importlib.util.spec_from_loader('update_varnish', loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class ShippedVarnishTest(unittest.TestCase):
    def test_the_folder_is_exactly_what_was_recorded_from_upstream(self):
        record = json.loads((THEME / 'varnish-upstream.json').read_text())
        self.assertRegex(record['commit'], r'\A[0-9a-f]{40}\Z')
        found = {str(path.relative_to(VARNISH)): hashlib.sha256(path.read_bytes()).hexdigest() for path in VARNISH.rglob('*') if path.is_file()}
        found.pop('local.json', None)  # upstream's own customisation file, kept across updates
        self.assertEqual(record['files'], found)
        self.assertEqual([], [str(path) for path in VARNISH.rglob('*') if path.is_symlink()])

    def test_licenses_and_credit_ship_with_it(self):
        self.assertIn('Keegan George', (VARNISH / 'LICENSE').read_text())
        self.assertIn('SIL OPEN FONT LICENSE', (VARNISH / 'fonts/OFL.txt').read_text().upper())
        notice = (THEME / 'NOTICE.md').read_text()
        self.assertIn('Based on Varnish by Keegan George'.split(' by ')[1], notice)
        self.assertIn('https://github.com/keegangeorge/term-llm-varnish', notice)
        self.assertIn('Based on Varnish by Keegan George', (THEME / 'extension.yaml').read_text())

    def test_nothing_reaches_an_outside_address(self):
        outside, network = load().scan(VARNISH)
        self.assertEqual([], outside)
        self.assertEqual(['util.js:35', 'util.js:112'], network)
        self.assertEqual([], load().scan(THEME)[0])

    def test_no_personal_settings_ship(self):
        self.assertFalse((VARNISH / 'local.json').exists())

    def test_starters_only_fill_the_chat_box(self):
        source = (THEME / 'main.js').read_text()
        self.assertIn('insertComposerText', source)
        for word in ('fetch(', 'innerHTML', '/shell'):
            self.assertNotIn(word, source)


class UpdateTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        top = Path(self.temp.name)
        self.upstream = top / 'upstream'
        self.repo = top / 'repo'
        (self.repo / 'integrations/term-llm/extensions/silo-theme').mkdir(parents=True)
        self.target = self.repo / 'integrations/term-llm/extensions/varnish'
        self.record = self.repo / 'integrations/term-llm/extensions/silo-theme/varnish-upstream.json'
        self.git('init', '-q', str(self.upstream), cwd=top)
        self.write('extension.yaml', 'title: V\n')
        self.write('LICENSE', 'MIT\n')
        self.write('fonts/OFL.txt', 'OFL\n')
        self.write('main.js', 'export function activate() {}\n')
        self.write('tools/check.mjs', 'dev only\n')
        self.write('install.sh', 'dev only\n')
        self.first = self.commit()

    def git(self, *args, cwd=None):
        return subprocess.run(['git', '-c', 'user.name=T', '-c', 'user.email=t@example.invalid', *args], cwd=cwd or self.upstream,
                              check=True, capture_output=True, text=True).stdout.strip()

    def write(self, name, text):
        path = self.upstream / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text)

    def commit(self):
        self.git('add', '-A')
        self.git('commit', '-qm', 'x')
        return self.git('rev-parse', 'HEAD')

    def update(self, commit):
        env = dict(os.environ, VARNISH_UPSTREAM=str(self.upstream), VARNISH_REPO_ROOT=str(self.repo), PYTHONDONTWRITEBYTECODE='1')
        return subprocess.run([sys.executable, '-I', '-B', str(SCRIPT), commit], env=env, capture_output=True, text=True)

    def test_installs_only_the_extension_and_records_the_commit(self):
        result = self.update(self.first)
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertTrue((self.target / 'main.js').is_file())
        self.assertFalse((self.target / 'tools').exists())
        self.assertFalse((self.target / 'install.sh').exists())
        self.assertEqual(self.first, json.loads(self.record.read_text())['commit'])

    def test_replaces_the_folder_keeps_local_json_and_says_what_changed(self):
        self.update(self.first)
        (self.target / 'local.json').write_text('{"nodeAccents": {}}')
        (self.target / 'stray.js').write_text('hand edit')
        self.write('main.js', 'export function activate() { return 1; }\n')
        self.write('new.js', 'export const a = 1;\n')
        result = self.update(self.commit())
        self.assertEqual(0, result.returncode, result.stderr)
        self.assertIn('added: new.js', result.stdout)
        self.assertIn('changed: main.js', result.stdout)
        self.assertFalse((self.target / 'stray.js').exists())
        self.assertEqual('{"nodeAccents": {}}', (self.target / 'local.json').read_text())

    def test_an_outside_address_stops_the_update_and_changes_nothing(self):
        self.update(self.first)
        for text in ("fetch('https://example.com/a');\n", 'const a = `<img src="//evil.example/x">`;\n'):
            with self.subTest(text=text):
                self.write('main.js', text)
                result = self.update(self.commit())
                self.assertNotEqual(0, result.returncode)
                self.assertIn('outside addresses', result.stderr)
                self.assertEqual(self.first, json.loads(self.record.read_text())['commit'])
                self.assertEqual('export function activate() {}\n', (self.target / 'main.js').read_text())

    def test_an_svg_namespace_is_fine(self):
        self.write('main.js', 'const n = "http://www.w3.org/2000/svg";\n')
        self.assertEqual(0, self.update(self.commit()).returncode)

    def test_every_way_of_reaching_outside_is_caught(self):
        scan = load().scan
        cases = ('* { background: url(https://x.example/a) }', '/* x */ fetch("https://x.example/a")', 'import x from "//x.example/x.js"',
                 'el.setAttribute("src","//x.example/a")', 'a = `<img srcset="//x.example/a">`', '<form action="//x.example/a">', 'fetch("//x.example/a")',
                 'new WebSocket("wss://x.example/a")', 'fetch("HTTPS://x.example/a")', 'a = "https:\\/\\/x.example/a"', '@import "//x.example/a.css";',
                 'b { background: url( //x.example/a) }', '// see https://x.example/a',
                 'fetch("https://simpleicons.org.x.example/a")', 'fetch("https://simpleicons.org@x.example/a")')
        for index, text in enumerate(cases):
            with self.subTest(text=text), tempfile.TemporaryDirectory() as folder:
                (Path(folder) / 'a.js').write_text(text + '\n')
                self.assertEqual(['a.js:1'], scan(Path(folder))[0])

    def test_an_unknown_file_type_or_an_unchecked_entry_stops_the_update(self):
        self.update(self.first)
        self.write('picture.svg', '<svg><image href="https://x.example/a"/></svg>')
        result = self.update(self.commit())
        self.assertNotEqual(0, result.returncode)
        self.assertIn("file type this doesn't check", result.stderr)
        (self.upstream / 'picture.svg').unlink()
        self.write('extension.yaml', 'title: V\njs: notes.md\n')
        self.write('notes.md', 'x')
        result = self.update(self.commit())
        self.assertNotEqual(0, result.returncode)
        self.assertIn("can't check", result.stderr)
        for line in ('js: notes.md # c', '"js": notes.md', '  js: notes.md'):
            with self.subTest(line=line):
                self.write('extension.yaml', 'title: V\n' + line + '\n')
                self.assertIn("can't check", self.update(self.commit()).stderr)
        self.assertEqual(self.first, json.loads(self.record.read_text())['commit'])
        self.assertFalse(self.target.with_name('.varnish.new').exists())

    def test_a_short_hash_is_refused_even_when_a_tag_shares_it(self):
        self.write('main.js', 'export const other = 1;\n')
        other = self.commit()
        self.git('tag', self.first[:7], other)
        self.assertNotEqual(0, self.update(self.first[:7]).returncode)
        self.assertFalse(self.target.exists())

    def test_a_symlink_is_refused(self):
        os.symlink('/etc/passwd', self.upstream / 'link.js')
        result = self.update(self.commit())
        self.assertNotEqual(0, result.returncode)
        self.assertIn("isn't a regular file", result.stderr)
        self.assertFalse(self.target.exists())

    def test_a_bad_commit_argument_runs_nothing(self):
        for bad in ('main', '--help', 'abc;id', 'a' * 39):
            self.assertNotEqual(0, self.update(bad).returncode)
        self.assertFalse(self.target.exists())


if __name__ == '__main__':
    unittest.main()
