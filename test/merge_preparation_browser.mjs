// Invented-data Project page regression for the prepared merge environment. All requests intercepted.
// PLAYWRIGHT_CORE=/path/to/playwright-core/index.mjs CHROMIUM=/path/to/chrome node test/merge_preparation_browser.mjs
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const prepRun = 'run-' + 'a'.repeat(32), prepPlan = 'plan-' + 'a'.repeat(32), newPrep = 'plan-' + 'e'.repeat(32);
const mergePlan = 'plan-' + 'b'.repeat(32), directRun = 'run-' + 'c'.repeat(32), directPlan = 'plan-' + 'c'.repeat(32);
const generation = '1'.repeat(64);
const environment = { preparation_run_id: prepRun, generation, phase: 'ready',
  endpoints: [{ kind: 'dbhub', name: 'silo-invented-source', ready: true }, { kind: 'discourse_mcp', name: 'silo-invented-base', ready: false }] };
const base = { delivery: { kind: 'base_site', version: 3 }, discourse_version: '2026.9.0' };
const step = (extra) => ({ checks: 0, matched: 0, backup: null, release: null, backup_state: 'none', results: {}, base_site: 'Base site v3', ...extra });
const board = {
  passes: [
    { key: mergePlan, number: 2, kind: 'merge', status: ['Waiting for your approval', 'now'], delivery: 'Development v2', layer: { present: false }, imports: [],
      prepared_from: { run_id: prepRun, generation }, base_site: 'Base site v3', backup_state: 'none', roles: {},
      convert: step({ kind: 'merge', plan_id: mergePlan, plan_status: 'proposed', run_id: null, run_status: null, prepared_from: { run_id: prepRun, generation } }) },
    { key: directPlan, number: 1, kind: 'merge', status: ['Merged', 'ok'], delivery: 'Development v1', layer: { present: false }, imports: [], prepared_from: null,
      base_site: 'Base site v3', backup_state: 'ready', roles: {},
      convert: step({ kind: 'merge', plan_id: directPlan, plan_status: 'consumed', run_id: directRun, run_status: 'completed', backup: { bytes: 5e8 }, backup_state: 'ready', site_up: false }) }],
  updates: [], banner: null, preparations: [],
  environments: [{ key: prepPlan, kind: 'merge_prepare', name: 'Prepare merge environment', status: ['Ready: inspect, then propose the merge', 'now'], live: true,
    environment, used_by: [], proposed_merges: [2], delivery: 'Development v2', base_site: 'Base site v3', at: '2026-11-01T01:00:00Z',
    step: step({ kind: 'merge_prepare', plan_id: prepPlan, plan_status: 'consumed', run_id: prepRun, run_status: 'completed' }) }] };
const plans = {
  [newPrep]: { plan_id: newPrep, status: 'proposed', digest: 'd'.repeat(64), operation: 'standard_merge_prepare', delivery: { kind: 'development', version: 2 },
    base_site: base, roles: {}, inputs: [], limits: { db: { cpus: 4, memory_mib: 16384, restore_timeout_seconds: 7200 }, web: { cpus: 2, memory_mib: 8192 } },
    mutations: ['Restores the Base site locally'], not_included: ['merge'] },
  [mergePlan]: { plan_id: mergePlan, status: 'proposed', digest: 'f'.repeat(64), operation: 'standard_merge', delivery: { kind: 'development', version: 2 },
    base_site: base, roles: {}, inputs: [], merge: { layer: { present: false }, options: {} }, prepared_from: { run_id: prepRun, generation }, intent: 'stock',
    merge_environment: environment, mutations: [], not_included: [] } };
const prepDetail = { run_id: prepRun, plan_id: prepPlan, status: 'completed', operation: 'standard_merge_prepare', stages: { prepare: 'completed' },
  results: { step_timings_ms: { 'base.restore': 1826000, 'source.load': 12000, 'PRIVATE_TIMING_CANARY': 1, 'base.hash': 'PRIVATE_VALUE_CANARY' },
    review_runtime: { actual_version: '2026.9.0', track: 'stable', mode: 'version_match' } }, merge_environment: environment, review_site_available: true, base_site: base };
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 900 } });
  const errors = [], posts = [];
  page.on('pageerror', error => errors.push(error.message));
  page.on('dialog', dialog => dialog.accept());
  await page.route('**/*', route => {
    const request = route.request(), url = new URL(request.url());
    assert.equal(url.origin, 'http://prepare.test', 'no outside requests');
    const path = url.pathname.replace('/widgets/project/', '');
    const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
    if (request.method() === 'POST') {
      const body = request.postDataJSON();
      posts.push([path, body]);
      assert.equal(body.workspace, 'invented');
      if (path === 'api/runs/again') return json({ status: 'proposed', plan_id: newPrep });
      if (path === 'api/runs/approve') return json({ status: 'approved' });
      throw new Error(`unexpected POST ${path}`);
    }
    if (path === 'api/projects') return json({ projects: ['invented'] });
    if (path === 'api/counts') return json({ findings: 0, runs: 0 });
    if (path === 'api/guide') return json({ project: 'invented', stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Invented fixture' } });
    if (path === 'api/files') return json({ deliveries: [], counts: {}, unlabelled_files: [], not_ready_files: [], unlabelled_data: [] });
    if (path === 'api/boards') return json({ runs: board, findings: { review: [], progress: [], done: [], other: [] } });
    if (path === 'api/runs/run') return json(prepDetail);
    if (path === 'api/runs/plan') return json(plans[url.searchParams.get('id')]);
    if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
    const name = path || 'index.html';
    return route.fulfill({ contentType: name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html', body: readFileSync(resolve(root, name)) });
  });
  await page.goto('http://prepare.test/widgets/project/');
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Runs', exact: false }).click();
  await page.getByText('MERGE ENVIRONMENT', { exact: true }).waitFor();
  const list = await page.locator('#content').innerText();
  assert.match(list, /Prepare merge environment/);
  assert.match(list, /Prepared · no migration has run/);
  assert.match(list, /DBHub · prepared source database \(inspection copy\)\s+ready · silo-invented-source/);
  assert.match(list, /Discourse MCP · local Base site \(inspection copy\)\s+not ready · silo-invented-base/);
  assert.match(list, /None: no migration has run, nothing to back up or release/);
  assert.match(list, /Proposed as pass 2/);
  assert.match(list, /Pass 2/);
  assert.match(list, /generation 111111111111 · its clean checkpoint, activated for the merge \(not restored anew\)/);
  // The environment card offers no release or sign-in: only the legacy direct merge's backup can be released.
  const envCard = page.locator('.pass').filter({ hasText: 'Prepare merge environment' });
  assert.equal(await envCard.getByRole('button', { name: /Release|admin password/ }).count(), 0);

  await envCard.locator('.pass-head').click();
  await page.getByText('PREPARED', { exact: true }).waitFor();
  const run = await page.locator('#content').innerText();
  assert.match(run, /Prepared\. No migration has run\. Inspection stays live until a merge or a reset\./);
  assert.match(run, /None: nothing to back up or release before a clean merged result/);
  assert.match(run, /read-only tools only/);
  assert.match(run, /Step timings/i);
  assert.match(run, /Restore Base\s+30 min 26 s/);
  assert.match(run, /Load source SQL\s+12.0 s/);
  assert.doesNotMatch(run, /PRIVATE_TIMING_CANARY|PRIVATE_VALUE_CANARY/);
  assert.doesNotMatch(run, /ssh -N|Show admin password|Release backup|127\.0\.0\.1/);
  assert.equal(await page.getByRole('button', { name: 'Reset the environment' }).count(), 1);

  await page.getByRole('button', { name: 'Run again', exact: true }).click();
  await page.getByText('Approve this merge environment preparation (no merge) on Development v2 · Base site v3?').waitFor();
  assert.deepEqual(posts[0], ['api/runs/again', { workspace: 'invented', run_id: prepRun }]);
  const plan = await page.locator('#content').innerText();
  assert.match(plan, /Nothing is merged or migrated; there is no output backup to release\./);
  assert.match(plan, /migration-data can read both sites’ private content/);
  assert.doesNotMatch(plan, /Converter/);
  assert.match(plan, /Database: 4 CPU · 16 GiB RAM; App: 2 CPU · 8 GiB RAM/);
  assert.match(plan, /120 min · not an estimate/);
  await page.getByRole('button', { name: 'Approve', exact: true }).click();
  await page.waitForFunction(() => true);
  for (let i = 0; i < 50 && posts.length < 2; i++) await new Promise(r => setTimeout(r, 20));
  assert.deepEqual(posts[1], ['api/runs/approve', { workspace: 'invented', plan_id: newPrep, digest: 'd'.repeat(64) }]);

  // The prepared merge's own plan binds the exact generation and says it is not a fresh restore.
  await page.getByRole('navigation', { name: 'Sections' }).getByRole('button', { name: 'Runs', exact: false }).click();
  await page.getByRole('button', { name: /^Pass 2 / }).click();
  await page.locator('.step').filter({ hasText: 'Merge run' }).click();
  await page.getByText('Approve this merge in the prepared environment on Development v2 · Base site v3?').waitFor();
  const merge = await page.locator('#content').innerText();
  assert.match(merge, /Run run-aaaaaaaa · generation 111111111111 · exactly this one/);
  assert.match(merge, /Stock: Discourse’s own merger only/);
  assert.match(merge, /activates the environment’s clean prepared checkpoint \(it does not restore the backups anew\)/);
  assert.match(merge, /it never switches to a fresh restore/);
  if (process.env.MERGE_PREPARATION_SCREENSHOT) await page.screenshot({ path: process.env.MERGE_PREPARATION_SCREENSHOT, fullPage: true });
  assert.equal(posts.length, 2, 'nothing starts automatically');
  assert.deepEqual(errors, []);
  console.log('merge-preparation browser: distinct environment card/run/plan, no release or sign-in, run again re-proposes, prepared merge binds its generation: passed');
} finally {
  await browser.close();
}
