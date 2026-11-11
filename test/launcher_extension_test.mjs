// Invented fixtures only. No running app, customer paths, cookies or config.
// Run from repository root: node test/launcher_extension_test.mjs
// Optional: TERM_LLM_SOURCE, PLAYWRIGHT_CORE, CHROMIUM executable paths.
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const source = resolve(process.env.TERM_LLM_SOURCE || '../../../term-llm-mcp-agent-scope');
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE || `${source}/frontend/node_modules/playwright-core/index.mjs`)));
const cache = `${process.env.HOME}/.cache/ms-playwright`;
const executablePath = process.env.CHROMIUM || `${cache}/${readdirSync(cache).find((name) => name === 'chromium-1243')}/chrome-linux64/chrome`;
const pinned = (path) => execFileSync('git', ['-C', source, 'show', `v0.9.99:frontend/src/${path}`], { encoding: 'utf8' });
const baseCSS = ['base/tokens.css', 'layout/header.css', 'layout/mobile-shell.css', 'integration/preact-overrides.css']
  .map((name) => pinned(`styles/${name}`)).join('\n');
const directory = 'integrations/term-llm/extensions/silo-findings';
const js = readFileSync(`${directory}/main.js`, 'utf8');
const css = readFileSync(`${directory}/style.css`, 'utf8');
const varnish = readFileSync('integrations/term-llm/extensions/varnish/style.css', 'utf8');
const header = `<header class="main-header"><div class="header-title-row">
  <div class="header-left"><button class="icon-btn mobile-menu" aria-label="Sidebar">☰</button><h1 class="header-title">Invented project / Review preparation</h1></div>
  <div class="header-controls-row"><div class="header-stats"><button class="chip-trigger">migration-data ▾</button></div>
  <button class="header-action" aria-label="Activity">12s</button><button class="header-action context-meter" aria-label="Context">42%</button>
  <div class="header-context-actions"><button class="header-action" aria-label="Shell">Shell</button><button class="header-action plan-toggle">Plan 2/5</button></div>
  <button class="header-action diff-toggle">+12 −3</button><button class="vn-theme-btn" aria-label="Appearance">◐</button></div>
  </div></header>`;
const fixture = { waiting: 2, latest: [{ workspace: 'example-forum', files: 1 }, { workspace: '<invented & community>', files: 2 }], finding_text: 'MUST NOT RENDER' };
const browser = await chromium.launch({ executablePath, headless: true });
try {
  for (const theme of ['stock', 'varnish']) {
    const page = await browser.newPage({ viewport: { width: 1180, height: 760 } });
    const errors = [];
    const requests = [];
    page.on('pageerror', (error) => errors.push(error.message));
    await page.route('**/*', async (route) => {
      const url = new URL(route.request().url());
      requests.push(url.pathname);
      if (url.pathname === '/launcher.js') return route.fulfill({ contentType: 'text/javascript', body: js });
      assert.equal(url.origin, 'http://launcher.test');
      if (url.pathname.startsWith('/fonts/')) return route.fulfill({ status: 204, body: '' });
      return route.fulfill({ contentType: 'text/html', body: `<html><head><style>
      *{box-sizing:border-box} body{margin:0} :root{--safe-top:0px;--safe-left:0px;--safe-right:0px;--header-action-height:34px;--header-cluster-gap:6px;--surface:#fff;--surface-2:#eee;--text:#222;--border:#bbb;--accent:#6465ce}
      button{font:13px system-ui} .header-action,.chip-trigger{min-height:34px;white-space:nowrap}.header-context-actions{display:flex;gap:4px}
      ${baseCSS}\n${theme === 'varnish' ? varnish : ''}\n${css}</style></head>
      <body><div id="root">${header}<main style="height:1500px"><button id="outside">Outside</button><div class="messages"></div></main></div><div id="extension-mount"></div></body></html>` });
    });
    await page.goto('http://launcher.test/');
    await page.evaluate(async ({ fixture }) => {
      window.calls = [];
      window.pending = [];
      window.summaryFixture = fixture;
      window.fetch = (url, options) => {
        window.calls.push({ url, credentials: options.credentials });
        return new Promise((resolve) => window.pending.push(() => resolve({ ok: !window.fail, status: window.fail ? (window.failStatus || 503) : 200, json: async () => window.summaryFixture })));
      };
      window.flush = () => window.pending.splice(0).forEach((finish) => finish());
      window.prefix = '/hub/nodes/invented';
      window.subscriptions = 0;
      window.host = {
        root: document.querySelector('#root'), mount: document.querySelector('#extension-mount'),
        getContext: () => ({ prefix: window.prefix, version: '0.9.99', sessionId: 'invented' }),
        onSessionChanged(callback) { window.sessionChanged = callback; window.subscriptions++; callback(); return () => window.subscriptions--; },
      };
      window.activate = (await import('/launcher.js')).activate;
      window.dispose = window.activate(window.host);
    }, { fixture });
    assert.equal(await page.evaluate(() => calls.length), 1, 'initial/session refresh deduplicated');
    await page.evaluate(() => flush());
    const button = page.locator('.silo-project-button');
    const panel = page.locator('.silo-project-panel');
    await button.waitFor({ state: 'visible' });
    assert.equal(await button.locator('..').getAttribute('class'), 'header-controls-row');
    assert.equal(await page.locator('.header-controls-row > *').count(), 7, 'only one own child appended');
    await button.click();
    assert.equal(await button.getAttribute('aria-expanded'), 'true');
    assert.equal(await page.locator(':focus').getAttribute('aria-label'), 'Close migration projects');
    await page.evaluate(() => { sessionChanged(); sessionChanged(); document.dispatchEvent(new Event('visibilitychange')); });
    assert.equal(await page.evaluate(() => calls.length), 2, 'open/session/visibility in flight deduplicated');
    await page.evaluate(() => flush());
    assert.ok(!(await panel.innerText()).includes('MUST NOT RENDER'));
    assert.equal(await panel.locator('li a').nth(1).textContent(), '<invented & community> · 2 waiting');
    assert.equal(await panel.locator('li a').first().getAttribute('href'), '/hub/nodes/invented/widgets/project/#project=example-forum');
    assert.ok(await page.evaluate(() => calls.every((call) => call.credentials === 'same-origin')));
    await panel.locator('li a').first().focus();
    await page.evaluate(() => { sessionChanged(); flush(); });
    assert.equal(await page.locator(':focus').textContent(), 'example-forum · 1 waiting', 'refresh preserves link focus');
    await page.keyboard.press('Escape');
    assert.equal(await button.getAttribute('aria-expanded'), 'false');
    assert.ok(await button.evaluate((node) => node === document.activeElement));

    for (const width of [1180, 760, 390, 320]) {
      await page.setViewportSize({ width, height: 844 });
      await button.click();
      await page.waitForTimeout(60);
      const b = await button.boundingBox();
      const p = await panel.boundingBox();
      assert.ok(b.x >= 0 && b.x + b.width <= width, `${theme}/${width}: button within viewport`);
      assert.ok(p.x >= 7 && p.x + p.width <= width - 7 && p.y >= 7 && p.y + p.height <= 837, `${theme}/${width}: panel clamped`);
      assert.ok(Math.abs(p.y - (b.y + b.height + 8)) < 2, 'anchored below button');
      assert.equal(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), true, 'no horizontal overflow');
      const collision = await button.evaluate((node) => {
        const a = node.getBoundingClientRect();
        return [...node.parentElement.children].filter((other) => other !== node).some((other) => {
          const b = other.getBoundingClientRect();
          return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
        });
      });
      assert.equal(collision, false, 'no toolbar control collision');
      await page.locator('#outside').click({ position: { x: 2, y: 2 }, force: true });
      assert.equal(await button.getAttribute('aria-expanded'), 'false');
    }
    await page.setViewportSize({ width: 1180, height: 760 });
    await button.click();
    await page.setViewportSize({ width: 390, height: 320 });
    await page.waitForTimeout(60);
    const resized = await panel.boundingBox();
    assert.ok(resized.x >= 7 && resized.x + resized.width <= 383 && resized.y + resized.height <= 313, 'open panel follows viewport resize');
    await page.keyboard.press('Escape');
    await page.setViewportSize({ width: 1180, height: 760 });
    await button.click();
    await page.evaluate(() => window.scrollTo(0, 20));
    await page.waitForTimeout(60);
    const moved = await panel.boundingBox();
    const anchor = await button.boundingBox();
    assert.ok(Math.abs(moved.y - anchor.y - anchor.height - 8) < 2, 'scroll tracking');
    // Replace the entire header, as a Preact shell remount can do.
    await page.evaluate((html) => { document.querySelector('.main-header').outerHTML = html; }, header);
    await button.waitFor({ state: 'visible' });
    assert.equal(await page.locator('.silo-project-button').count(), 1, 'one button after remount');
    await page.evaluate(() => { window.fail = true; flush(); sessionChanged(); flush(); });
    await button.waitFor({ state: 'visible' });
    await button.click();
    await page.getByText('Project status unavailable', { exact: true }).waitFor();
    assert.equal(await panel.locator('li').count(), 0, 'transient error clears stale project names/counts');
    assert.equal(await panel.getByRole('link').count(), 1, 'Project page navigation survives a transient error');
    await page.evaluate(() => { window.failStatus = 403; flush(); sessionChanged(); flush(); });
    await button.waitFor({ state: 'hidden' });
    assert.notEqual(await page.locator(':focus').getAttribute('class'), 'silo-project-button', 'auth failure does not leave focus on a hidden button');
    await page.evaluate(() => { window.fail = false; window.summaryFixture = { waiting: 0, latest: [] }; sessionChanged(); flush(); });
    await button.waitFor({ state: 'visible' });
    assert.equal(await button.innerText(), 'Project');
    // Context-prefix changes must abort/ignore an older response and use the new route.
    await page.evaluate(() => {
      sessionChanged();
      prefix = '';
      sessionChanged();
      summaryFixture = { waiting: 1, latest: [{ workspace: 'direct-example', files: 1 }] };
      flush();
    });
    await button.click();
    assert.equal(await panel.locator('li a').first().getAttribute('href'), '/widgets/project/#project=direct-example');
    await page.locator('#outside').focus();
    assert.equal(await button.getAttribute('aria-expanded'), 'false', 'Tab/focus outside dismisses without stealing focus');
    assert.equal(await page.locator(':focus').getAttribute('id'), 'outside');
    await page.evaluate(() => { window.dispose = activate(host); });
    assert.equal(await page.locator('.silo-project-panel').count(), 1, 'reactivation disposes old instance');
    assert.equal(await page.evaluate(() => subscriptions), 1);
    await page.evaluate(() => { dispose(); flush(); });
    assert.equal(await page.locator('.silo-project-button, .silo-project-panel').count(), 0);
    assert.equal(await page.evaluate(() => subscriptions), 0);
    const total = await page.evaluate(() => calls.length);
    await page.evaluate(() => document.dispatchEvent(new Event('visibilitychange')));
    assert.equal(await page.evaluate(() => calls.length), total, 'listeners removed');
    assert.deepEqual(errors, []);
    assert.deepEqual(requests.filter((path) => !path.startsWith('/fonts/')).sort(), ['/', '/launcher.js']);
    await page.close();
    console.log(`PASS ${theme}: responsive anchor, safe summary, dismissal/focus, dedup, remount, disposal`);
  }
} finally {
  await browser.close();
}
