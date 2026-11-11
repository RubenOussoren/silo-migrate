// Invented-data Project page runtime/preparation regression. All requests intercepted.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const runId = 'run-' + 'a'.repeat(32), planId = 'plan-' + 'b'.repeat(32);
const runtime = { mode: 'version_match', track: 'stable', requested_version: '2026.7.5', actual_version: '2026.7.5',
  image_ref: 'silo-migrate/review-runtime:' + 'c'.repeat(64), content_id: 'sha256:' + 'd'.repeat(64),
  stock_digest: 'sha256:' + 'e'.repeat(64), app_revision: 'f'.repeat(40), schema_version: '20260701000000' };
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
  await page.clock.install();
  const errors = [], posts = [];
  let imports = 0;
  page.on('pageerror', error => errors.push(error.message));
  page.on('dialog', dialog => dialog.accept());
  await page.route('**/*', route => {
    const request = route.request(), url = new URL(request.url());
    assert.equal(url.origin, 'http://runtime.test', 'no outside requests');
    const path = url.pathname.replace('/widgets/project/', '');
    const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
    if (request.method() === 'POST') {
      posts.push(path);
      assert.equal(request.postDataJSON().workspace, 'invented');
      assert.equal(path, 'api/runs/import', 'no automatic approve or start');
      imports++;
      return json(imports < 3 ? { status: 'runtime_preparing' } : { status: 'proposed', plan_id: planId });
    }
    if (path === 'api/projects') return json({ projects: ['invented'] });
    if (path === 'api/counts') return json({ findings: 0, runs: 0 });
    if (path === 'api/guide') return json({ project: 'invented', stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Invented fixture' } });
    if (path === 'api/files') return json({ deliveries: [], counts: {}, unlabelled_files: [], not_ready_files: [], unlabelled_data: [] });
    if (path === 'api/boards') return json({ runs: { passes: [{ key: 'invented-pass', number: 1, status: ['Converted', 'ok'], delivery: 'Development v1',
      convert: { kind: 'convert', run_id: runId, run_status: 'completed', checks: 1, matched: 1 }, imports: [] }], updates: [] }, findings: { review: [], progress: [], done: [], other: [] } });
    if (path === 'api/runs/plan') return json({ plan_id: planId, status: 'proposed', digest: 'a'.repeat(64), operation: 'standard_review', delivery: { kind: 'development', version: 1 },
      base_site: { delivery: { kind: 'base_site', version: 3 }, discourse_version: '2026.7.5' }, review_runtime: runtime, from_run: { run_id: runId },
      inputs: [], roles: {}, mutations: [], not_included: [] });
    if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
    const name = path || 'index.html';
    return route.fulfill({ contentType: name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html', body: readFileSync(resolve(root, name)) });
  });
  await page.goto('http://runtime.test/widgets/project/');
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Runs', exact: false }).click();
  await page.getByRole('button', { name: 'Import into a review site', exact: true }).click();
  await page.getByRole('status').filter({ hasText: 'Preparing the matching Discourse runtime' }).waitFor();
  assert.equal(imports, 1);
  assert.equal(await page.getByRole('button', { name: 'Import into a review site', exact: true }).isDisabled(), true);
  await page.clock.fastForward(5000);
  await page.waitForFunction(() => document.querySelector('[role="status"]')?.textContent.includes('Preparing'));
  // Let the intercepted second response settle before advancing the next poll.
  for (let i = 0; i < 50 && imports < 2; i++) await new Promise(resolve => setTimeout(resolve, 20));
  assert.equal(imports, 2);
  await new Promise(resolve => setTimeout(resolve, 100));
  await page.clock.fastForward(5000);
  await page.getByText('2026.7.5 · stable · matches the Base site version', { exact: true }).waitFor();
  assert.match(await page.locator('#content').innerText(), /Base site v3/);
  assert.equal(await page.locator('#content [role="status"]').count(), 0);
  assert.equal(imports, 3);
  assert.deepEqual(posts, ['api/runs/import', 'api/runs/import', 'api/runs/import']);
  await page.locator('#content summary').click();
  assert.match(await page.locator('#content').innerText(), /silo-migrate\/review-runtime/);
  assert.match(await page.locator('#content').innerText(), /Core revision/);
  assert.equal(await page.getByRole('button', { name: 'Approve', exact: true }).count(), 1);
  if (process.env.REVIEW_RUNTIME_SCREENSHOT) await page.screenshot({ path: process.env.REVIEW_RUNTIME_SCREENSHOT, fullPage: true });
  assert.deepEqual(errors, []);
  console.log('review-runtime browser: preparation polling, same-track plan/provenance, no automatic approval/start, no outside requests: passed');
} finally {
  await browser.close();
}
