// Invented fixtures only: reproduce idle Files polling/decision lock collisions.
// Run with the same cached PLAYWRIGHT_CORE and CHROMIUM as file_roles_browser.mjs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const sourceId = 'dataset-' + '1'.repeat(32), wrongId = 'dataset-' + '2'.repeat(32);
const sheet = { id: 'file-' + '2'.repeat(32), path: 'invented-map.xlsx', role: 'source', bytes: 80, sha256: 'a'.repeat(64), dataset_id: wrongId };
const source = { id: 'file-' + '1'.repeat(32), path: 'invented-source.sql', role: 'source', bytes: 400, sha256: 'b'.repeat(64), dataset_id: sourceId };
const roles = { revision: 1, active: { development: wrongId }, snapshots: [
  { dataset_id: sourceId, kind: 'development', label: 'Development v1', revision: 1, eligible: true, files: [source] },
  { dataset_id: wrongId, kind: 'development', label: 'Development v2', revision: 1, eligible: true, files: [sheet] },
], references: [], history: [] };
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const until = async predicate => {
  for (let i = 0; i < 200 && !predicate(); i++) await sleep(10);
  assert(predicate(), 'fixture request did not reach its expected boundary');
};
let holdRead = false, releaseRead, holdPreview = false, releasePreview, holdCommit = false, releaseCommit;
let activeRead = false, activeDecision = false, refusePreview = false, fileReads = 0, previews = 0, commits = 0, collisions = 0;
const errors = [];
try {
  const page = await browser.newPage();
  page.on('pageerror', error => errors.push(error.message));
  // Invoke the real polling callback at exact request boundaries, without timing races.
  await page.addInitScript(() => {
    const interval = window.setInterval;
    window.setInterval = (fn, ms) => {
      if (ms === 15000) { window.pollProject = fn; return 0; }
      return interval(fn, ms);
    };
  });
  await page.route('**/*', async route => {
    const req = route.request(), url = new URL(req.url());
    assert.equal(url.origin, 'http://widget.test');
    const path = url.pathname.replace('/widgets/project/', '');
    const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
    const busy = () => { collisions++; return route.fulfill({ status: 409, contentType: 'application/json', body: '{"error":"STANDARD_BUSY"}' }); };
    if (path === 'api/projects') return json({ projects: ['alpha', 'beta'] });
    if (path === 'api/files') {
      fileReads++;
      if (activeDecision) return busy();
      activeRead = true;
      if (holdRead) await new Promise(resolve => releaseRead = resolve);
      activeRead = false;
      return json({ initialized: true, setup: { complete: true, platform: 'phpbb' }, deliveries: [], unlabelled_files: [], counts: {}, roles });
    }
    if (path === 'api/counts') return json({});
    if (path === 'api/boards') return json({ runs: { passes: [], updates: [] }, findings: { review: [], progress: [], done: [], other: [] } });
    if (path === 'api/guide') return json({ project: 'alpha', stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Invented overview' } });
    if (path === 'api/files/preview' || path === 'api/files/commit') {
      const body = req.postDataJSON();
      assert.equal(body.workspace, 'alpha');
      assert.equal(body.change.action, 'correct');
      assert.equal(body.change.role, 'reference');
      assert.equal(body.change.restore_dataset_id, sourceId);
      if (path.endsWith('/preview')) previews++; else commits++;
      if (activeRead) return busy();
      if (refusePreview && path.endsWith('/preview')) return route.fulfill({ status: 409, contentType: 'application/json', body: '{"error":"STANDARD_BUSY"}' });
      activeDecision = true;
      if (path.endsWith('/preview') && holdPreview) await new Promise(resolve => releasePreview = resolve);
      if (path.endsWith('/commit') && holdCommit) await new Promise(resolve => releaseCommit = resolve);
      activeDecision = false;
      if (path.endsWith('/preview')) return json({ digest: 'c'.repeat(64), revision: roles.revision, change: body.change, files: [sheet], before_active: roles.active,
        after_active: { development: sourceId }, impacts: { pending: [], active: [], completed: [], releases: [] }, warnings: [], blocked: [] });
      assert.equal(body.digest, 'c'.repeat(64));
      roles.active.development = sourceId;
      roles.revision++;
      return json({ status: 'ok' });
    }
    if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
    return route.fulfill({ contentType: path.endsWith('.js') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html', body: readFileSync(resolve(root, path || 'index.html')) });
  });
  const btn = name => page.getByRole('button', { name, exact: true });
  const ack = () => page.getByRole('checkbox', { name: 'Confirm I reviewed this exact preview' });
  const poll = () => page.evaluate(() => window.pollProject());
  const beginRead = async () => {
    holdRead = true; releaseRead = null;
    await page.evaluate(() => { window.pollProject(); });
    await until(() => !!releaseRead);
  };
  const finishRead = () => { holdRead = false; releaseRead(); };
  await page.goto('http://widget.test/widgets/project/#project=alpha&tab=files');
  await page.getByText('Manage invented-map.xlsx', { exact: true }).click();
  await btn('Correct assignment…').click();
  await page.getByRole('combobox', { name: 'Restore current source snapshot (optional)', exact: true }).selectOption(sourceId);
  await page.getByRole('textbox', { name: 'Reason for this change (required)' }).fill('Invented workbook was labelled as source');

  // A long preview must not be interrupted by the page's own polling read.
  holdPreview = true;
  await btn('Preview assignment').click();
  await until(() => !!releasePreview);
  let reads = fileReads;
  await poll();
  assert.equal(fileReads, reads, 'polling must not read Files during a preview');
  assert.equal(collisions, 0, 'an idle page must not create its own busy notification');
  holdPreview = false; releasePreview(); await ack().waitFor();

  // A preview must drain an already-sent read, not merely stop future polling.
  await beginRead();
  let count = previews;
  await btn('Preview assignment').click();
  await page.getByText('Checking / saving assignment…', { exact: true }).waitFor();
  await sleep(100);
  assert.equal(previews, count, 'preview waits for an in-flight Files read');
  await page.getByRole('combobox', { name: 'Change project' }).selectOption('beta');
  assert.equal(await page.getByRole('combobox', { name: 'Change project' }).inputValue(), 'alpha', 'waiting decision cannot change project');
  finishRead(); await ack().waitFor();
  assert.equal(previews, count + 1);

  // Real decision refusals stay visible, never silently replayed; polling resumes.
  refusePreview = true;
  await btn('Preview assignment').click();
  await page.getByRole('alert').waitFor();
  assert.match(await page.getByRole('alert').innerText(), /busy|lock/);
  assert.equal(await ack().count(), 0);
  count = previews; reads = fileReads;
  await poll();
  assert.equal(fileReads, reads + 1, 'polling resumes after a refused decision');
  assert.equal(previews, count, 'refused preview is not retried automatically');
  refusePreview = false;
  await btn('Preview assignment').click(); await ack().waitFor();

  // The final confirmation must also drain reads, without changing its digest/intent.
  await ack().check();
  await beginRead();
  holdCommit = true;
  await btn('Confirm assignment').click();
  await page.getByText('Checking / saving assignment…', { exact: true }).waitFor();
  await sleep(100);
  assert.equal(commits, 0, 'confirmation waits for an in-flight Files read');
  finishRead(); await until(() => !!releaseCommit);
  reads = fileReads;
  await poll();
  assert.equal(fileReads, reads, 'polling must not read Files during confirmation');
  assert.equal(commits, 1);
  holdCommit = false; releaseCommit();
  await page.getByRole('heading', { name: 'Migration data', exact: true }).waitFor();
  assert.equal(await ack().count(), 0, 'successful confirmation closes the editor');
  assert.equal(roles.active.development, sourceId);
  await until(() => fileReads > reads);
  reads = fileReads;
  await poll();
  assert.equal(fileReads, reads + 1, 'polling resumes after successful confirmation');
  assert.equal(commits, 1, 'confirmation is sent exactly once');
  assert.equal(collisions, 0);
  assert.equal(await page.locator('#toast.bad.show').count(), 0, 'no false busy toast');
  assert.deepEqual(errors, []);
  console.log(JSON.stringify({ result: 'FILE_DECISION_POLLING_OK', previews, commits, fileReads, collisions, errors: errors.length }));
} finally { await browser.close(); }
