"""Page-memory navigation snapshots; no browser, network or customer data required."""
import json
from pathlib import Path
import shutil
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'integrations/term-llm/widgets/project/lists.js'


@unittest.skipUnless(shutil.which('node'), 'Node is needed for the widget navigation tests')
class ProjectNavigationTest(unittest.TestCase):
    def check_js(self, body):
        source = SOURCE.read_text()
        script = "import assert from 'node:assert/strict';\n"
        script += 'const {createListCache} = await import("data:text/javascript;base64," + Buffer.from(' + json.dumps(source) + ').toString("base64"));\n'
        script += body
        result = subprocess.run(['node', '--input-type=module', '-e', script], capture_output=True, text=True, timeout=10)
        self.assertEqual(0, result.returncode, result.stderr)

    def test_snapshots_are_immediate_and_project_scoped(self):
        self.check_js('''
const cache = createListCache(async path => ({path}));
assert.equal(cache.peek('alpha'), null);
await cache.load('alpha');
assert.deepEqual(cache.peek('alpha'), {path:'alpha'});
assert.equal(cache.peek('beta'), null);
await cache.load('beta');
assert.deepEqual(cache.peek('beta'), {path:'beta'});
''')

    def test_reads_coalesce_and_recent_data_is_reused(self):
        self.check_js('''
let finish, calls = 0;
const cache = createListCache(() => { calls++; return new Promise(resolve => finish = resolve); });
const a = cache.load('alpha'), b = cache.load('alpha');
assert.equal(a,b);
await Promise.resolve();
assert.equal(calls,1);
finish({value:1});
await a;
assert.deepEqual(await cache.load('alpha'), {value:1});
assert.equal(calls,1);
''')

    def test_invalidation_cannot_be_undone_by_an_old_inflight_read(self):
        self.check_js('''
const pending = [];
const cache = createListCache(() => new Promise(resolve => pending.push(resolve)));
const before = cache.load('alpha');
await Promise.resolve();
cache.clear();
const after = cache.load('alpha');
await Promise.resolve();
pending[1]({value:'new'}); await after;
pending[0]({value:'old'}); await before;
assert.deepEqual(cache.peek('alpha'), {value:'new'});
''')

    def test_failed_refresh_keeps_last_snapshot_and_can_retry(self):
        self.check_js('''
let calls = 0;
const cache = createListCache(async () => { if (++calls === 2) throw Error('offline'); return {calls}; },8,0);
await cache.load('alpha');
await assert.rejects(cache.load('alpha'), /offline/);
assert.deepEqual(cache.peek('alpha'), {calls:1});
assert.deepEqual(await cache.load('alpha'), {calls:3});
''')

    def test_page_memory_is_bounded(self):
        self.check_js('''
const cache = createListCache(async path => ({path}),2);
await cache.load('alpha'); await cache.load('beta'); await cache.load('gamma');
assert.equal(cache.peek('alpha'), null);
assert.deepEqual(cache.peek('gamma'), {path:'gamma'});
''')


if __name__ == '__main__':
    unittest.main()
