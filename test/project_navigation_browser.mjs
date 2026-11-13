// Synthetic browser regressions. Run from the repository root with PLAYWRIGHT_CORE and CHROMIUM.
// No service, model, customer data, or network outside the intercepted fixture origin.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const findingId = 'finding-' + 'a'.repeat(32);
const runId = 'run-' + 'b'.repeat(32);
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  const errors = [], requests = [], held = [];
  let hold = true, fail = false, revision = 1, released = false, releasedText = '', accepting = false, finishReset = null, refused = false;
  page.on('pageerror', error => errors.push(error.message));
  const fixture = project => {
    const entry = { id: findingId, title: `${project} finding ${revision}`, status: released ? 'released' : 'proposed', kind: 'schema', proposed_at: '2026-11-10T12:00:00Z' };
    const step = { run_id: runId, run_status: 'completed', checks: 1, matched: 1, site_up: true };
    const passes = accepting ? [{ key: 'fixture-pass', number: 1, status: ['Finished', 'ok'], delivery: 'Development v1', convert: step, imports: [step] }] : [];
    return { runs: { passes, ...(refused ? { error: 'STANDARD_BUSY' } : {}), updates: [], converter: { branch: project, not_pushed: 0 } },
      findings: { review: released ? [] : [entry], progress: released ? [entry] : [], done: [], other: [] } };
  };
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    assert.equal(url.origin, 'http://widget.test');
    requests.push({ path: url.pathname, project: url.searchParams.get('workspace'), method: request.method() });
    const path = url.pathname.replace('/widgets/project/', '');
    const project = url.searchParams.get('workspace') || 'alpha';
    const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
    if (path === 'api/projects') return json({ projects: ['alpha', 'beta'] });
    if (path === 'api/files') return json({ deliveries: [], counts: {}, unlabelled_files: [], not_ready_files: [], unlabelled_data: [] });
    if (path === 'api/counts') return json({ findings: 1, runs: 0 });
    if (path === 'api/guide') return json({ project, stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Fixture overview' } });
    if (path === 'api/boards') {
      const data = fixture(project);
      if (hold) await new Promise(resolve => held.push({ project, resolve })); else await sleep(80);
      if (fail) return route.fulfill({ status: 503, contentType: 'application/json', body: '{"error":"offline"}' });
      return json(data);
    }
    if (path === 'api/runs/reset') {
      await new Promise(resolve => finishReset = resolve);
      return json({ status: 'reset' });
    }
    if (path === 'api/runs/passes') return json(fixture(project).runs);
    if (path === 'api/site/process') return json({ can_accept: true, process_digest: 'a'.repeat(64), process: {
      delivery: { kind: 'development', version: 1 }, converter: { revision: 'b'.repeat(40) },
      results: { import: { checks: 1 }, convert: { checks: 1 } }, checks: {}, run_id: runId, convert_run_id: runId,
    } });
    if (path === 'api/site/review') {
      const body = request.postDataJSON(); assert.equal(body.process_digest, 'a'.repeat(64));
      assert.equal(body.run_id, runId); assert.equal(body.verdict, 'accepted');
      return json({ verdict: 'accepted' });
    }
    if (path === 'api/findings/finding') return json({ id: findingId, kind: 'schema', status: released ? 'released' : 'proposed', versions: [], proposal: `${project} original proposal`, proposal_revision: 1, proposal_sha256: 'a'.repeat(64), released: released ? releasedText : null });
    if (path === 'api/findings/release') {
      const body = request.postDataJSON();
      assert.equal(body.workspace, 'alpha'); assert.equal(body.id, findingId); assert.equal(body.proposal_sha256, 'a'.repeat(64));
      assert.equal(request.headers()['x-silo-project'], '1');
      releasedText = body.text; released = true; revision++;
      return json({ status: 'released', finding_id: findingId });
    }
    if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
    const name = path || 'index.html';
    const mime = name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html';
    return route.fulfill({ contentType: mime, body: readFileSync(resolve(root, name)) });
  });
  const tab = name => page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name, exact: false });
  const flush = project => { for (let i = held.length - 1; i >= 0; i--) if (!project || held[i].project === project) held.splice(i, 1)[0].resolve(); };
  const waitHeld = async project => { for (let i = 0; i < 100 && !held.some(x => x.project === project); i++) await sleep(20); assert(held.some(x => x.project === project)); };
  const boardCalls = () => requests.filter(r => r.path.endsWith('/api/boards')).length;
  await page.goto('http://widget.test/widgets/project/');
  await waitHeld('alpha');
  await tab('Findings').click();
  await page.getByText('Loading findings…', { exact: true }).waitFor();
  await tab('Runs').click();
  await page.getByText('Loading runs…', { exact: true }).waitFor();
  assert.equal(boardCalls(), 1, 'tabs share one in-flight read');
  await tab('Overview').click();
  hold = false; flush(); await sleep(150);
  assert.match(await page.locator('#content').innerText(), /Fixture overview/);
  const warmMs = [];
  for (const name of ['Findings', 'Runs', 'Findings', 'Runs']) {
    const timing = await page.evaluate(name => {
      const start = performance.now();
      [...document.querySelectorAll('#tabs button')].find(b => b.textContent.startsWith(name)).click();
      return { ms: performance.now() - start, content: document.querySelector('#content').textContent };
    }, name);
    assert.match(timing.content, name === 'Findings' ? /alpha finding/ : /Converter checkout: alpha/);
    assert(timing.ms < 100, `warm ${name} took ${timing.ms}ms`);
    warmMs.push(Math.round(timing.ms * 10) / 10);
  }
  await sleep(1100); hold = true;
  await tab('Findings').click(); await waitHeld('alpha');
  await page.getByRole('button', { name: /alpha finding/ }).click();
  const editor = page.getByRole('textbox', { name: 'Text to release' });
  await editor.waitFor(); await editor.fill('Edited invented text');
  flush('alpha'); await sleep(100);
  assert.equal(await editor.inputValue(), 'Edited invented text', 'late list must not replace an editor');
  page.once('dialog', dialog => dialog.dismiss());
  await tab('Runs').click();
  assert.equal(await editor.inputValue(), 'Edited invented text', 'declining navigation preserves edits');
  page.once('dialog', dialog => dialog.accept());
  await tab('Runs').click();
  await tab('Findings').click();
  await page.getByRole('button', { name: /alpha finding/ }).click();
  await editor.waitFor();
  assert.equal(await editor.inputValue(), 'alpha original proposal', 'detail is read fresh, not cached');
  const detailCalls = requests.filter(r => r.path.endsWith('/api/findings/finding')).length;
  assert.equal(detailCalls, 2);
  await editor.fill('Exact invented release text');
  const before = boardCalls();
  hold = false;
  page.once('dialog', dialog => dialog.accept());
  await page.getByRole('button', { name: 'Release', exact: true }).click();
  await page.getByText('Released text (what the coding agents see)', { exact: false }).waitFor();
  assert.equal(releasedText, 'Exact invented release text');
  assert(boardCalls() > before, 'decision invalidated the navigation snapshot');
  await sleep(1100); hold = true;
  await tab('Findings').click(); await waitHeld('alpha');
  await page.getByRole('combobox', { name: 'Change project' }).selectOption('beta');
  await waitHeld('beta');
  assert(!/alpha finding/.test(await page.locator('#content').innerText()), 'project switch clears old content');
  flush('alpha'); await sleep(100);
  assert(!/alpha finding/.test(await page.locator('#content').innerText()), 'old project response must not mount');
  hold = false; flush('beta');
  await page.getByRole('button', { name: /beta finding/ }).waitFor();
  await sleep(1100); fail = true;
  await tab('Runs').click();
  await page.getByText(/Couldn't refresh:/).waitFor();
  assert.match(await page.locator('#content').innerText(), /Converter checkout: beta/);
  assert.match(await page.locator('#content').innerText(), /Showing the last loaded list/);
  // A list refresh cannot replace disabled controls while an action is still in flight.
  accepting = true; fail = false; hold = false;
  await page.goto('about:blank');
  await page.goto('http://widget.test/widgets/project/#project=alpha&tab=runs');
  await page.getByRole('button', { name: 'Reset the site', exact: true }).waitFor();
  await sleep(1100); hold = true;
  await tab('Runs').click(); await waitHeld('alpha');
  page.once('dialog', dialog => dialog.accept());
  const reset = page.getByRole('button', { name: 'Reset the site', exact: true });
  await reset.click();
  for (let i = 0; i < 100 && !finishReset; i++) await sleep(20);
  assert(finishReset);
  const oldRead = page.waitForResponse(response => response.url().includes('/api/boards?workspace=alpha'));
  flush('alpha');
  await (await oldRead).finished();
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  assert(await reset.isDisabled(), 'late revalidation must not replace in-flight action controls');
  hold = false; finishReset();
  await page.getByText('Reset.', { exact: true }).waitFor();
  // Acceptance must still read fresh process details and show Reset for a recorded live site.
  await page.goto('about:blank');
  await page.goto(`http://widget.test/widgets/project/#project=alpha&tab=runs&kind=accept&id=${runId}`);
  await page.getByRole('button', { name: 'Accept', exact: true }).click();
  await page.getByRole('button', { name: 'Reset the site', exact: true }).waitFor();
  assert(requests.some(r => r.path.endsWith('/api/site/process')));
  assert(requests.some(r => r.path.endsWith('/api/runs/passes')), 'post-accept site state is freshly read');
  refused = true;
  await page.goto('about:blank');
  await page.goto('http://widget.test/widgets/project/#project=alpha&tab=runs&kind=pass&id=fixture-pass');
  await page.getByText('The project is busy (a run or another decision). Try again in a moment.', { exact: true }).waitFor();
  assert(!/This pass is no longer there/.test(await page.locator('#content').innerText()), 'a read refusal must not look like a removed pass');
  assert.equal(errors.length, 0, errors.join('\n'));
  console.log(JSON.stringify({ result: 'PROJECT_NAVIGATION_OK', warmClickMs: warmMs, boardRequests: boardCalls(), freshDetailReads: detailCalls, errors: errors.length }));
} finally { await browser.close(); }
