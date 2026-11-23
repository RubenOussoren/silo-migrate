// Opt-in smoke: verified stock binary, loopback only, no real providers or sessions.
// Run from repository root with TERM_LLM_BINARY, PLAYWRIGHT_CORE, and CHROMIUM.
import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { resolve } from 'node:path';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';

const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const delay = ms => new Promise(done => setTimeout(done, ms));
const extensions = resolve('integrations/term-llm/extensions');
const full = ['varnish', 'silo-theme', 'silo-findings', 'sidebar-agent'];
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
try {
  for (const { prefix, enabled } of [{ prefix: '/ui', enabled: ['sidebar-agent'] },
      { prefix: '/hub/node/invented', enabled: full }]) {
    const home = await mkdtemp(`${tmpdir()}/silo-sidebar-`);
    await mkdir(`${home}/config/term-llm`, { recursive: true });
    await writeFile(`${home}/config/term-llm/config.yaml`, `provider_discovery: config\ndefault_provider: fixture\nproviders:\n  fixture:\n    type: vllm\n    url: http://127.0.0.1:1/v1/chat/completions\n    model: invented\n    api_key: invented-unused\n`);
    const socket = createServer().listen(0, '127.0.0.1');
    await once(socket, 'listening');
    const port = socket.address().port;
    await new Promise((done, fail) => socket.close(err => err ? fail(err) : done()));
    const origin = `http://127.0.0.1:${port}`;
    const base = origin + prefix;
    const processNode = spawn(resolve(process.env.TERM_LLM_BINARY), ['serve', 'web', '--host', '127.0.0.1',
      '--port', String(port), '--base-path', prefix, '--auth', 'none', '--approval', 'prompt',
      '--provider', 'debug', '--no-projects', '--disable-widgets', '--extensions-dir', extensions,
      '--extensions', enabled.join(',')], { cwd: home, stdio: ['ignore', 'ignore', 'pipe'],
      env: { PATH: '/usr/bin:/bin', HOME: home, XDG_CACHE_HOME: `${home}/cache`,
        XDG_CONFIG_HOME: `${home}/config`, XDG_DATA_HOME: `${home}/data` } });
    let log = '';
    processNode.stderr.on('data', chunk => { log = (log + chunk).slice(-4000); });
    const context = await browser.newContext({ serviceWorkers: 'block' });
    try {
      let status;
      for (let attempt = 0; attempt < 60; ++attempt) {
        assert.equal(processNode.exitCode, null, log);
        try {
          const response = await fetch(`${base}/admin/extensions/status`, { signal: AbortSignal.timeout(500) });
          if (response.ok) { status = await response.json(); break; }
        } catch { /* waiting for the disposable process */ }
        await delay(100);
      }
      assert.ok(status, log);
      assert.deepEqual(status.enabled, enabled);
      assert.deepEqual(status.errors, []);
      for (const id of ['sidebar-agent', ...(enabled.includes('varnish') ? ['varnish'] : [])]) {
        for (const file of ['main.js', 'style.css']) {
          const response = await fetch(`${base}/extensions/${status.generation}/${id}/${file}`);
          assert.equal(response.status, 200);
          assert.deepEqual(Buffer.from(await response.arrayBuffer()), await readFile(`${extensions}/${id}/${file}`));
        }
      }
      const seen = [];
      const errors = [];
      const entry = { mode: 'chat', origin: 'web', message_count: 2, archived: false, pinned: false,
        created_at: 1800000000000, last_message_at: 1800000000000 };
      const saved = { ...entry, id: 'invented-recorded', number: 1, short_title: 'Invented recorded', agent: 'migration-data' };
      const plain = { ...entry, id: 'invented-unrecorded', number: 2, short_title: 'Invented unlabeled' };
      await context.route('**/*', route => {
        const request = route.request();
        const url = new URL(request.url());
        if (url.origin !== origin || request.method() !== 'GET') { seen.push(request.method()); return route.abort(); }
        if (url.pathname === `${prefix}/v1/sessions`) return route.fulfill({ json: { sessions: [saved, plain] } });
        return route.continue();
      });
      await context.routeWebSocket('**/*', socket => socket.close());
      const page = await context.newPage();
      page.on('pageerror', error => errors.push(error.message));
      await page.goto(`${base}/`);
      const recorded = page.locator('.session-row[data-session-id="invented-recorded"]').first();
      const unrecorded = page.locator('.session-row[data-session-id="invented-unrecorded"]').first();
      await recorded.locator('.session-meta > .sidebar-agent-prefix:first-child > .sidebar-agent-label').waitFor({ timeout: 7000 });
      await unrecorded.waitFor({ state: 'attached', timeout: 7000 });
      assert.equal(await recorded.getAttribute('data-session-agent'), 'migration-data');
      assert.equal(await recorded.locator('.sidebar-agent-label').textContent(), 'migration-data');
      assert.equal(await unrecorded.getAttribute('data-session-agent'), null);
      assert.equal(await unrecorded.locator('.sidebar-agent-label').count(), 0);
      if (enabled.includes('varnish')) {
        await page.locator('.vn-composer-bar').waitFor({ timeout: 7000 });
        const util = `${base}/extensions/${status.generation}/varnish/util.js`;
        assert.equal(await page.evaluate(async url => (await import(url)).NODE_ID, util), 'invented');
      }
      assert.deepEqual(errors, []);
      assert.deepEqual(seen, [], 'no external requests or non-GET browser actions');
      console.log(`PASS ${prefix}: registry, served bytes, native metadata, recorded and unrecorded labels`);
    } finally {
      await context.close();
      if (processNode.exitCode === null && processNode.signalCode === null) {
        const exited = once(processNode, 'exit');
        const fallback = setTimeout(() => processNode.kill('SIGKILL'), 3000);
        processNode.kill('SIGTERM');
        try { await exited; } finally { clearTimeout(fallback); }
      }
      await rm(home, { recursive: true, force: true });
    }
  }
} finally { await browser.close(); }
