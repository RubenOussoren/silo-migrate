// Invented fixtures only. Same local Playwright environment as project_navigation_browser.mjs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const hash = 'a'.repeat(64);
const source = { id: 'file-11111111111111111111111111111111', path: 'invented-source.tar.gz', role: 'source', bytes: 400, sha256: hash, input_id: 'input-11111111111111111111111111111111' };
const sheet = { id: 'file-22222222222222222222222222222222', path: 'invented-map.xlsx', role: 'source', bytes: 80, sha256: hash };
const incoming = [{ path: 'new-map.xlsx', bytes: 82, mtime_ns: '1700000000000000000', ctime_ns: '1700000000000000001', ino: '123' }, { path: 'assets-a.zip', bytes: 200, mtime_ns: '1700000000000000000', ctime_ns: '1700000000000000001', ino: '123' }, { path: 'assets-b.zip', bytes: 201, mtime_ns: '1700000000000000000', ctime_ns: '1700000000000000001', ino: '123' }];
const roles = { revision: 1, active: { development: 'dataset-11111111111111111111111111111111', launch: null, base_site: 'dataset-44444444444444444444444444444444' }, snapshots: [
  { dataset_id: 'dataset-22222222222222222222222222222222', kind: 'development', label: 'Development v2', revision: 1, eligible: false, files: [sheet] },
  { dataset_id: 'dataset-11111111111111111111111111111111', kind: 'development', label: 'Development v1', revision: 1, eligible: true, files: [source] },
  { dataset_id: 'dataset-33333333333333333333333333333333', kind: 'development', label: 'Development v0', revision: 1, eligible: true, files: [{ ...source, id: 'file-33333333333333333333333333333333', path: 'invented-earlier.tar.gz' }] },
  { dataset_id: 'dataset-55555555555555555555555555555555', kind: 'launch', label: 'Launch v1', revision: 1, eligible: true, files: [{ ...source, id: 'file-66666666666666666666666666666666', path: 'invented-launch.tar.gz' }] },
  { dataset_id: 'dataset-44444444444444444444444444444444', kind: 'base_site', label: 'Base site v1', files: [{ id: 'file-44444444444444444444444444444444', path: 'invented-base.sql.gz', role: 'base_site', bytes: 90 }] },
], references: [{ id: 'file-55555555555555555555555555555555', path: 'instructions.txt', bytes: 33, role: 'reference', support_id: 'support-11111111111111111111111111111111', status: 'available' }], history: [{ action: 'correct', text: 'Original mistaken classification retained', completed_run: 'run-original' }] };
let blocked = false, stale = false, holdPreview = false, releasePreview, previews = [], commits = [], revision = 1, legacy = false;
const errors = [];
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  const page = await browser.newPage();
  page.on('pageerror', error => errors.push(error.message));
  // Deterministically exercise normal polling without waiting 15 seconds each time.
  await page.addInitScript(() => { const interval = window.setInterval; window.setInterval = (fn, ms) => interval(fn, ms === 15000 ? 200 : ms); });
  await page.route('**/*', async route => {
    const req = route.request(), url = new URL(req.url());
    assert.equal(url.origin, 'http://widget.test');
    const path = url.pathname.replace('/widgets/project/', '');
    const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
    if (path === 'api/projects') return json({ projects: ['alpha', 'beta'] });
    if (path === 'api/files') return json({ initialized: true, setup: { complete: true, platform: 'discourse' }, deliveries: [
      { kind: 'development', dataset_id: 'dataset-22222222222222222222222222222222', version: 2, files: [sheet] }, { kind: 'development', dataset_id: 'dataset-11111111111111111111111111111111', version: 1, files: [source] },
    ], unlabelled_files: incoming, not_ready_files: [], unlabelled_data: [], refused_files: [], labelled_files: [], counts: {}, ...(legacy ? {} : { roles }) });
    if (path === 'api/counts') return json({});
    if (path === 'api/boards') return json({ runs: { passes: [], updates: [] }, findings: { review: [], progress: [], done: [], other: [] } });
    if (path === 'api/guide') return json({ project: 'alpha', stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Invented overview' } });
    if (path === 'api/files/preview') {
      const body = req.postDataJSON(); previews.push(body);
      assert.equal(body.workspace, 'alpha'); assert(!('actor' in body)); assert(!('actor' in body.change));
      const change = body.change;
      for (const key of ['dataset_id', 'restore_dataset_id']) if (key in change) assert.match(change[key], /^dataset-[0-9a-f]{32}$/);
      if (change.files) for (const f of change.files) {
        assert.equal(typeof f.bytes, 'number');
        for (const key of ['mtime_ns', 'ctime_ns', 'ino']) assert.match(f[key], /^[0-9]{1,24}$/);
        assert.deepEqual(Object.keys(f).sort(), ['path', 'bytes', 'mtime_ns', 'ctime_ns', 'ino'].sort());
      }
      if (change.file_ids) for (const id of change.file_ids) assert.match(id, /^file-[0-9a-f]{16,64}$/);
      if (change.action === 'correct') assert(['reference', 'uploads', 'unassigned'].includes(change.role));
      const after = { ...roles.active };
      if (change.action === 'activate') after.development = change.dataset_id;
      if (change.restore_dataset_id) after.development = change.restore_dataset_id;
      const response = { digest: (revision++).toString(16).padStart(64, '0'), revision, change, files: change.files || [sheet], before_active: { ...roles.active }, after_active: after,
        impacts: { pending: [{ plan_id: 'plan-dependent', action: 'invalidate approval' }], active: blocked ? [{ run_id: 'run-active' }] : [], completed: [{ run_id: 'run-original', unchanged: true }], releases: [{ release_id: 'release-original', unchanged: true }] }, blocked: blocked ? ['Active run is still bound to this file'] : [], warnings: ['Output is not retroactively corrected'] };
      if (holdPreview) await new Promise(resolve => releasePreview = resolve);
      return json(response);
    }
    if (path === 'api/files/commit') {
      const body = req.postDataJSON(); commits.push(body);
      assert.equal(body.workspace, 'alpha'); assert(!('actor' in body));
      assert.deepEqual(body.change, previews.at(-1).change); assert.match(body.digest, /^[0-9a-f]{64}$/);
      if (stale) return route.fulfill({ status: 409, contentType: 'application/json', body: '{"error":"STANDARD_FILE_ROLES_STALE_PREVIEW"}' });
      if (body.change.action === 'activate') roles.active.development = body.change.dataset_id;
      return json({ status: 'committed' });
    }
    assert.notEqual(path, 'api/label', 'normal intake must never call legacy label');
    if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
    return route.fulfill({ contentType: path.endsWith('.js') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html', body: readFileSync(resolve(root, path || 'index.html')) });
  });
  const btn = name => page.getByRole('button', { name, exact: true });
  const role = () => page.getByRole('combobox', { name: 'File role', exact: true });
  const preview = () => btn('Preview assignment');
  const reason = () => page.getByRole('textbox', { name: 'Reason for this change (required)', exact: true });
  const ack = () => page.getByRole('checkbox', { name: 'Confirm I reviewed this exact preview' });
  const cancel = () => btn('Cancel').click();
  const manage = async path => { await page.getByText(`Manage ${path}`, { exact: true }).click(); await btn('Correct assignment…').click(); };
  await page.goto('http://widget.test/widgets/project/#project=alpha&tab=files');
  await page.getByRole('heading', { name: 'Migration data', exact: true }).waitFor();
  assert.match(await page.locator('#data').innerText(), /DEVELOPMENT V1/);
  assert(!/DEVELOPMENT V2/.test(await page.locator('#data').innerText()), 'explicit older pointer beats newest delivery');
  assert.match(await page.locator('#content').innerText(), /Private reference registered/);
  assert.match(await page.locator('#content').innerText(), /embedded uploads/);
  if (process.env.FILE_ROLES_SCREENSHOT) await page.screenshot({ path: process.env.FILE_ROLES_SCREENSHOT, fullPage: true });
  await btn('Classify new files…').click();
  assert.equal(await page.getByRole('checkbox', { checked: true }).count(), 0);
  assert(await preview().isDisabled());
  assert.equal(await page.getByRole('combobox', { name: 'Snapshot purpose' }).count(), 0);
  await role().selectOption('source');
  await page.getByRole('combobox', { name: 'Snapshot purpose' }).selectOption('launch');
  await page.getByRole('checkbox', { name: 'Select new-map.xlsx' }).check();
  assert(await preview().isDisabled(), 'launch requires typed LAUNCH');
  await page.getByRole('textbox', { name: 'Type LAUNCH to confirm' }).fill('LAUNCH');
  assert(!(await preview().isDisabled()));
  await role().selectOption('reference');
  assert.equal(await page.getByRole('combobox', { name: 'Snapshot purpose' }).count(), 0);
  assert.equal(await page.getByRole('combobox', { name: 'Associate uploads with snapshot' }).count(), 0);
  await preview().click(); await ack().waitFor();
  assert.equal(previews.at(-1).change.role, 'reference');
  assert.equal(previews.at(-1).change.files.length, 1);
  assert(!('kind' in previews.at(-1).change)); assert(!('confirm' in previews.at(-1).change));
  assert.match(await page.locator('.file-preview').innerText(), /Previous current[\s\S]*dataset-11111111111111111111111111111111[\s\S]*New current[\s\S]*dataset-11111111111111111111111111111111/);
  assert.match(await page.locator('.file-preview').innerText(), /plan-dependent/);
  assert.match(await page.locator('.file-preview').innerText(), /run-original/);
  assert(await btn('Confirm assignment').isDisabled());
  await ack().check(); await btn('Confirm assignment').click();
  await btn('Classify new files…').waitFor();
  assert.equal(roles.active.development, 'dataset-11111111111111111111111111111111'); assert.equal(commits.length, 1);
  // Snapshot-specific assets attach multiple files to the chosen immutable source, not a new source version.
  await btn('Add files to this snapshot…').click();
  assert.equal(await role().inputValue(), 'uploads');
  assert.equal(await page.getByRole('combobox', { name: 'Associate uploads with snapshot' }).inputValue(), 'dataset-11111111111111111111111111111111');
  await page.getByRole('checkbox', { name: 'Select assets-a.zip' }).check();
  await page.getByRole('checkbox', { name: 'Select assets-b.zip' }).check();
  await preview().click(); await ack().waitFor();
  assert.equal(previews.at(-1).change.dataset_id, 'dataset-11111111111111111111111111111111');
  assert.equal(previews.at(-1).change.files.length, 2); assert(!('kind' in previews.at(-1).change));
  await cancel();
  // Associating assets with Launch also needs explicit LAUNCH confirmation, even when it is not current.
  await btn('Classify new files…').click();
  await role().selectOption('uploads');
  await page.getByRole('checkbox', { name: 'Select assets-a.zip' }).check();
  await page.getByRole('combobox', { name: 'Associate uploads with snapshot' }).selectOption('dataset-55555555555555555555555555555555');
  assert(await preview().isDisabled());
  await page.getByRole('textbox', { name: 'Type LAUNCH to confirm' }).fill('LAUNCH');
  await preview().click(); await ack().waitFor();
  assert.equal(previews.at(-1).change.confirm, 'LAUNCH');
  assert.equal(previews.at(-1).change.dataset_id, 'dataset-55555555555555555555555555555555');
  await cancel();
  // Correction requires reason, may restore exact earlier pointer, and preserves input/checksum identities.
  await page.getByText('History — earlier snapshots, additions and corrections', { exact: true }).click();
  assert.match(await page.locator('#content').innerText(), /Original mistaken classification retained/);
  await manage('invented-map.xlsx');
  assert(await preview().isDisabled());
  await page.getByRole('combobox', { name: 'Restore current source snapshot (optional)', exact: true }).selectOption('dataset-11111111111111111111111111111111');
  await reason().fill('Correct workbook mistakenly assigned as source');
  // Polling must preserve the same focused form and draft, never replay the decision.
  await reason().focus();
  await sleep(500);
  assert.equal(await reason().evaluate(node => node === document.activeElement), true, 'polling preserves focus');
  assert.equal(await reason().inputValue(), 'Correct workbook mistakenly assigned as source');
  assert.equal(commits.length, 1);
  blocked = true;
  await preview().click(); await ack().waitFor();
  assert.match(await page.locator('.file-preview').innerText(), /Blocked: Active run/);
  assert(await ack().isDisabled()); assert(await btn('Confirm assignment').isDisabled());
  assert.deepEqual(previews.at(-1).change.file_ids, ['file-22222222222222222222222222222222']);
  assert.equal(previews.at(-1).change.restore_dataset_id, 'dataset-11111111111111111111111111111111');
  blocked = false;
  await preview().click(); await ack().waitFor();
  stale = true;
  await ack().check(); await btn('Confirm assignment').click();
  await page.getByRole('alert').waitFor();
  assert.match(await page.getByRole('alert').innerText(), /Nothing was retried/);
  assert.equal(await ack().count(), 0);
  const afterStale = previews.length; await sleep(500);
  assert.equal(previews.length, afterStale, 'no automatic stale retry');
  assert.equal(commits.length, 2);
  stale = false;
  await preview().click(); await ack().waitFor();
  // Editing the reason removes the digest-bound preview and requires another deliberate preview.
  await reason().fill('Different justified correction');
  assert.equal(await ack().count(), 0);
  await preview().click(); await ack().waitFor();
  await ack().check(); await btn('Confirm assignment').click();
  await btn('Classify new files…').waitFor();
  assert.equal(commits.length, 3);
  // Earlier eligible source activation is explicit and audited, not a new copy.
  await page.getByText('History — earlier snapshots, additions and corrections', { exact: true }).click();
  await btn('Make this source snapshot current…').first().click();
  await reason().fill('Use the earlier validated source snapshot');
  await preview().click(); await ack().waitFor();
  assert.equal(previews.at(-1).change.action, 'activate'); assert.equal(previews.at(-1).change.dataset_id, 'dataset-33333333333333333333333333333333');
  await ack().check(); await btn('Confirm assignment').click();
  await btn('Classify new files…').waitFor();
  assert.match(await page.locator('#data').innerText(), /DEVELOPMENT V0/);
  // Project switching never displays or commits another project's preview, including a late response.
  await btn('Classify new files…').click();
  await page.getByRole('checkbox', { name: 'Select new-map.xlsx' }).check();
  holdPreview = true;
  await preview().click();
  for (let i = 0; !releasePreview && i < 100; i++) await sleep(10);
  assert(releasePreview);
  await page.getByRole('combobox', { name: 'Change project' }).selectOption('beta');
  assert.equal(await page.getByRole('combobox', { name: 'Change project' }).inputValue(), 'alpha', 'in-flight preview cannot be abandoned');
  releasePreview(); holdPreview = false; await ack().waitFor();
  page.once('dialog', d => d.dismiss());
  await page.getByRole('combobox', { name: 'Change project' }).selectOption('beta');
  assert.equal(await ack().count(), 1, 'declined project switch preserves preview');
  page.once('dialog', d => d.accept());
  await page.getByRole('combobox', { name: 'Change project' }).selectOption('beta');
  await btn('Classify new files…').waitFor(); assert.equal(await ack().count(), 0);
  roles.active.development = null; await sleep(500);
  assert(!/DEVELOPMENT V[012]/.test(await page.locator('#data').innerText()), 'explicit null pointer never falls back to newest');
  delete roles.active.base_site; await sleep(500);
  assert(!/Base site v1/.test(await page.locator('#data').innerText()), 'an absent explicit Base pointer must not promote a recovered snapshot');
  assert.match(await page.locator('#content').innerText(), /Base site v1 · Earlier/);
  assert.match(await page.locator('#content').innerText(), /No current Base backup/);
  // Legacy payloads stay usable, but all normal intake still uses role endpoints.
  legacy = true; await sleep(500);
  await btn('Classify new files…').click();
  assert.equal(await page.getByRole('checkbox', { checked: true }).count(), 0);
  await cancel();
  assert.equal(errors.length, 0, errors.join('\n'));
  console.log(JSON.stringify({ result: 'FILE_ROLES_OK', previews: previews.length, commits: commits.length, errors: errors.length }));
} finally { await browser.close(); }
