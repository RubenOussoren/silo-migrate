// Invented fixtures only: intake-first references and progressive plan view, desktop and 360 px.
// Run with the same PLAYWRIGHT_CORE and CHROMIUM as file_roles_browser.mjs.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const BLOCKED = 'plan-' + 'a'.repeat(32), READY = 'plan-' + 'b'.repeat(32), LEGACY = 'plan-' + 'c'.repeat(32), MASTER = 'plan-' + 'e'.repeat(32), EMPTY = 'plan-' + 'f'.repeat(32);
const ref = { id: 'file-' + '1'.repeat(32), path: 'invented-plan.xlsx', role: 'reference', bytes: 84, sha256: 'e'.repeat(64), support_id: 'support-' + '1'.repeat(32), status: 'available',
  usage_status: 'cited_by_plan', used_by: { plans: [{ plan_id: BLOCKED, status: 'proposed', operation: 'standard_merge' }], runs: [] } };
const unknown = { ...ref, id: 'file-' + '2'.repeat(32), path: 'invented-plan.xlsx', support_id: undefined, sha256: 'a'.repeat(64), usage_status: 'unknown', used_by: null };  // same name, no reader ID
const roles = { revision: 1, active: { development: 'dataset-' + '1'.repeat(32), base_site: null }, snapshots: [
  { dataset_id: 'dataset-' + '1'.repeat(32), kind: 'development', label: 'Development v1', revision: 1, eligible: true, files: [{ id: 'file-' + '9'.repeat(32), path: 'invented-source.tar.gz', role: 'source', bytes: 400, sha256: 'b'.repeat(64) }] }],
  references: [ref, unknown], history: [] };
// Shapes as lib/silo_migrate/services/standard_run_inputs.rb binds them; the server re-checks them (intake.py).
const prep = (questions, extra = {}) => ({ analyst: { label: 'migration-data', text: 'Merge the invented Atlas forum into Base site v1.' }, references: [{ file_id: ref.id, sha256: ref.sha256 }],
  outcomes: [{ id: 'o1', requirement: 'Move Old Help into Support', disposition: 'prepared_input', input: 'settings' }, { id: 'o2', requirement: 'Merge matching-email users', disposition: 'stock' },
    { id: 'o3', requirement: 'Badge styling after launch', disposition: 'excluded', exclusion: 'x1' }, { id: 'o4', requirement: 'Route Sandbox topics', disposition: 'code' }],
  questions, exclusions: [{ id: 'x1', text: 'Badge styling after launch', reason: 'Manual follow-up' }],
  code_readiness: { kind: 'merge_layer', present: true, required: true, path: 'mergers/atlas', revision: 'a1b2c3d4e5f6' }, ...extra });
const input = { input_id: 'input-' + '3'.repeat(32), name: null, sha256: 'd'.repeat(64), origin: 'prepared settings', bytes: 60, state: 'verified', lineage: null,
  preview: { text: 'category_routes:\n  - from: Old Help\n    to: Support\n', truncated: false, bytes: 60 } };
const mapping = { input_id: 'input-' + '4'.repeat(32), name: 'categories.csv', sha256: 'c'.repeat(64), origin: 'converter input', bytes: 40, state: 'verified',
  lineage: { references: [{ file_id: ref.id, sha256: ref.sha256, verified: 'registry_digest' }], preparation: { job: 'job-5555', tool: 'xlsx-reader', preparation_sha256: '8'.repeat(64) } },
  reuse: { dataset_id: 'dataset-' + '6'.repeat(32), source_sha256: '5'.repeat(64) }, preview: { text: 'source,target\nOld Help,Support\n', truncated: false, bytes: 40 } };
const plans = {
  [BLOCKED]: { status: 'proposed', intake: { ready: false, preparation: prep([{ id: 'q1', text: 'Retire Sandbox: exclude topics or keep read-only?', status: null, resolution: null }]),
    run_inputs: null, inputs: [{ ...input, state: 'changed', preview: undefined }],
    blockers: [{ code: 'QUESTION_UNRESOLVED', text: 'Needs your answer: Retire Sandbox: exclude topics or keep read-only?' }, { code: 'INPUT_CHANGED', text: 'A selected input is changed since the plan: prepared settings.' }] } },
  [READY]: { status: 'proposed', intake: { ready: true, blockers: [], preparation: prep([{ id: 'q1', text: 'Retire Sandbox?', status: 'excluded', resolution: 'Exclude Sandbox topics', exclusion: 'x1' }]),
    run_inputs: { consumer: { platform: 'invented', setting: 'mappings.directory' }, writable: true, files: [{ name: mapping.name, input_id: mapping.input_id, sha256: mapping.sha256, bytes: mapping.bytes }],
      absent_defaults: ['groups.csv'], generated: ['trust_level_mapping.yml'] }, inputs: [input, mapping] } },
  [LEGACY]: { status: 'proposed', intake: null },
  [EMPTY]: { status: 'proposed', operation: 'standard_convert', platform: 'invented', converter: { branch: 'invented' }, converter_revision: 'a1b2c3d4e5f6'.padEnd(40, '0'),
    roles: { source: 'input-' + '6'.repeat(32), settings: 'input-' + '7'.repeat(32) }, texts: { settings: 'mappings:\n  directory: ${SILO_RUN_INPUTS_DIR}\n' }, intake: { ready: true, blockers: [], inputs: [],
    preparation: prep([], { outcomes: [{ id: 'o1', requirement: 'Keep the converter defaults', disposition: 'stock' }], exclusions: [], code_readiness: { kind: 'converter', present: true, required: false, path: 'converters/invented/converter.rb', revision: 'a1b2c3d4e5f6' } }),
    run_inputs: { consumer: { platform: 'invented', setting: 'mappings.directory' }, writable: true, files: [], absent_defaults: ['categories.csv'], generated: ['trust_level_mapping.yml'] } } },
  [MASTER]: { status: 'proposed', intake: null, operation: 'standard_master_lists', master_lists: { script: 'converters/invented/scripts/export_master_lists.rb', list: 'all' },
    roles: { source: 'input-' + '6'.repeat(32), settings: 'input-' + '7'.repeat(32) }, texts: { settings: 'mappings:\n  directory: ${SILO_RUN_INPUTS_DIR}\n' }, converter: { branch: 'invented' }, converter_revision: 'f'.repeat(40) },
};
const decisions = [], errors = [], external = [];
let clipboardWorks = false;
const sizes = [{ width: 1280, height: 900 }, { width: 360, height: 780 }];
try {
  for (const viewport of sizes) {
    const context = await browser.newContext({ viewport });
    const page = await context.newPage();
    page.on('pageerror', error => errors.push(error.message));
    page.on('dialog', dialog => dialog.accept());
    await page.addInitScript(() => {
      const interval = window.setInterval;
      window.setInterval = (fn, ms) => interval(fn, ms === 15000 ? 300 : ms);
      window.copied = [];
      Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async text => { if (!window.clipboardWorks) throw new Error('denied'); window.copied.push(text); } } });
    });
    await page.route('**/*', async route => {
      const req = route.request(), url = new URL(req.url());
      if (url.origin !== 'http://widget.test') { external.push(url.href); return route.abort(); }
      const path = url.pathname.replace('/widgets/project/', '');
      const json = value => route.fulfill({ contentType: 'application/json', body: JSON.stringify(value) });
      if (path === 'api/projects') return json({ projects: ['alpha'] });
      if (path === 'api/files') return json({ initialized: true, setup: { complete: true, platform: 'discourse' }, deliveries: [], unlabelled_files: [], not_ready_files: [], unlabelled_data: [], refused_files: [], labelled_files: [], counts: {}, roles });
      if (path === 'api/counts') return json({});
      if (path === 'api/boards') return json({ runs: { passes: [], updates: [], preparations: [{ kind: 'standard_master_lists', name: 'Master-list export', plan_id: MASTER, plan_status: 'proposed', list: 'all', delivery: 'Development v1', at: '2026-11-12T10:00:00Z' }] }, findings: { review: [], progress: [], done: [], other: [] } });
      if (path === 'api/runs/passes') return json({ passes: [], updates: [] });
      if (path === 'api/guide') return json({ project: 'alpha', stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Invented overview' } });
      if (path === 'api/runs/plan') {
        const id = url.searchParams.get('id'), plan = plans[id];
        return json({ plan_id: id, operation: 'standard_merge', mutations: [], not_included: [], digest: id.slice(5).padEnd(64, '0'), delivery: { kind: 'development', version: 1 }, roles: {}, inputs: [], texts: {}, merge: { layer: { present: false } }, created_at: '2026-11-12T10:00:00Z', ...plan });
      }
      if (path.startsWith('api/')) { decisions.push([path, req.postDataJSON()]); return json(path.endsWith('/start') ? { run_id: 'run-' + '7'.repeat(32) } : { status: 'ok' }); }
      if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
      return route.fulfill({ contentType: path.endsWith('.js') ? 'text/javascript' : path.endsWith('.css') ? 'text/css' : 'text/html', body: readFileSync(resolve(root, path || 'index.html')) });
    });
    const shot = async name => { if (process.env.INTAKE_SCREENSHOTS) await page.screenshot({ path: `${process.env.INTAKE_SCREENSHOTS}/${name}-${viewport.width}.png`, fullPage: true }); };
    const overflow = () => page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);

    // Files: explicit roles stay; references show derived use, retained original and Copy request.
    await page.goto('http://widget.test/widgets/project/#project=alpha&tab=files');
    await page.getByText('Cited by a plan', { exact: true }).waitFor();
    await page.getByText('Use unknown', { exact: true }).waitFor();
    assert.equal(await page.getByText('Not cited by any plan yet.').count(), 0, 'unknown use is never shown as unused');
    assert(await page.getByText(/Original retained in private custody/).first().isVisible());
    await page.getByText('Used by (1) — from plan and run records').click();
    assert.match(await page.locator('.usage pre').first().innerText(), new RegExp(BLOCKED));
    assert.equal(await page.getByRole('checkbox').count(), 0, 'no per-file usage toggles');
    const copy = page.getByRole('button', { name: 'Copy request for migration-data' }).first();
    await copy.click();  // clipboard refused: visible, selectable fallback; nothing sent
    const box = page.getByRole('textbox', { name: 'Request text to copy' });
    await box.waitFor();
    const text = await box.inputValue();
    assert.match(text, /^Project: alpha\nAgent: migration-data/);
    // Exact identities, labelled: the private reader ID (not only the Files ID) and the checksum.
    assert(text.includes(`Private reader ID (for data_supporting_read): ${ref.support_id}`));
    assert(text.includes(`Files tab identity: ${ref.id}`));
    assert(text.includes(`Exact SHA-256: ${ref.sha256}`));
    assert(text.includes('Confirm that the reader ID’s SHA-256 equals the one above before reading.'));
    assert.match(text, /Do not start a migration, approve anything/);
    await page.evaluate(() => { window.clipboardWorks = true; });
    await copy.click();
    assert.equal((await page.evaluate(() => window.copied)).length, 1);
    assert.equal((await page.evaluate(() => window.copied))[0], text, 'clipboard and fallback carry the same request');
    // A same-named reference without a reader ID: resolve by exact digest, never by name.
    await page.getByRole('button', { name: 'Copy request for migration-data' }).nth(1).click();
    const second = (await page.evaluate(() => window.copied))[1];
    assert(second.includes(`Files tab identity: ${unknown.id}`) && second.includes(`Exact SHA-256: ${unknown.sha256}`));
    assert(second.includes('Find it with data_supporting_list by the exact SHA-256 below; do not choose by file name alone.'));
    assert(!second.includes('support-'), 'no reader ID is invented');
    assert.equal(decisions.length, 0, 'copying a request performs no action');
    await shot('files');
    assert(await overflow() <= 0, `Files overflow at ${viewport.width}px`);

    // A blocked plan: questions and changed inputs first; Approve disabled and explained.
    await page.goto(`http://widget.test/widgets/project/#project=alpha&tab=runs&kind=plan&id=${BLOCKED}`);
    await page.reload();
    await page.getByRole('region', { name: 'Needs your answer' }).waitFor();
    const approve = page.getByRole('button', { name: 'Approve', exact: true });
    assert(await approve.isDisabled(), 'unresolved material question blocks approval');
    assert.equal(await approve.getAttribute('aria-describedby'), 'plan-not-ready');
    assert(await page.locator('#plan-not-ready').isVisible());
    await page.getByText(/changed since the plan/).first().waitFor();
    assert.equal(await page.getByText('Preview the exact bytes').count(), 0, 'no preview of unverified bytes');
    assert(await page.getByText(/Written by migration-data: an interpretation, not evidence/).first().isVisible());
    await approve.click({ force: true });
    assert.equal(decisions.length, 0);
    await shot('blocked');
    assert(await overflow() <= 0, `blocked plan overflow at ${viewport.width}px`);

    // A ready plan: exact prepared bytes, answers, exclusions, code; existing Approve, then Start.
    await page.goto(`http://widget.test/widgets/project/#project=alpha&tab=runs&kind=plan&id=${READY}`);
    await page.reload();
    await page.getByText('Analyst-recorded answers and scope choices — confirm in this exact plan review').waitFor();
    assert(await page.getByText('Recorded exclusion: Exclude Sandbox topics').isVisible());
    assert(await page.getByText(/not independent proof of your decision\. Approving this plan is your confirmation/).isVisible());
    assert.equal(await page.getByText(/Your answers|by your choice|you answered/i).count(), 0, 'agent-recorded choices are never presented as the engineer’s');
    for (const summary of await page.getByText('Preview the exact bytes').all()) await summary.click();
    const previews = await page.locator('details.more[open] pre').allInnerTexts();
    assert.equal(previews.length, 2);
    assert(previews.every(text => /Old Help/.test(text)));
    assert(await page.getByText(/groups\.csv: deliberately not provided — the converter’s own default applies/).isVisible());
    assert(await page.getByText(/trust_level_mapping\.yml: may be generated/).isVisible());
    // Pinned code identifies what runs; it is never presented as the behavior being implemented.
    assert(await page.getByText(/merge layer mergers\/atlas at a1b2c3d4e5f6/).isVisible());
    assert(await page.getByText(/this page does not show that it implements them/).isVisible());
    assert(await page.getByText('Handled by pinned code, not proven by this page: check the reviewed change.').isVisible());
    assert.equal(await page.getByText(/implemented|fulfilled|done/i).count(), 0, 'no fulfilment claim from code presence');
    assert(await page.getByText(/Derived from reference file-1/).isVisible());
    assert(await page.getByText(/Converter setting mappings.directory points at a fresh run-owned copy/).isVisible());
    // Explicit reuse and what was actually checked are stated; hashes stay collapsed until asked for.
    assert(await page.getByText(/Explicitly reused from an earlier source snapshot, not this plan’s source/).isVisible());
    assert(await page.getByText(/registry checksum matched; bytes not re-read/).isVisible());
    assert(!(await page.getByText('dataset-' + '6'.repeat(32)).isVisible()));
    assert(!(await page.getByText('8'.repeat(64)).isVisible()));
    const identity = page.locator('details.more', { hasText: 'Reused from snapshot' }).first();
    await identity.locator('summary').click();
    assert(await page.getByText('dataset-' + '6'.repeat(32)).isVisible());
    assert(await page.getByText('5'.repeat(64)).isVisible());
    assert(await page.getByText('8'.repeat(64)).isVisible());
    assert(await page.getByText(/provenance only — the original is retained/).isVisible());
    assert.equal(await page.getByRole('region', { name: 'Needs your answer' }).count(), 0);
    // Keyboard only: Approve is reachable by Tab and activated by Enter.
    let reached = false;
    for (let i = 0; i < 80 && !reached; i++) {
      await page.keyboard.press('Tab');
      reached = await page.evaluate(() => document.activeElement?.textContent === 'Approve');
    }
    assert(reached, 'Approve is keyboard reachable');
    await page.keyboard.press('Enter');
    for (let i = 0; i < 50 && !decisions.length; i++) await new Promise(r => setTimeout(r, 20));
    assert.equal(decisions.at(-1)[0], 'api/runs/approve');
    assert.equal(decisions.at(-1)[1].digest, READY.slice(5).padEnd(64, '0'));
    assert.equal(decisions.filter(([path]) => path.endsWith('/start')).length, 0, 'approval never starts');
    await shot('ready');
    assert(await overflow() <= 0, `ready plan overflow at ${viewport.width}px`);

    // A plan without preparation keeps the existing view and makes no readiness claim.
    await page.goto(`http://widget.test/widgets/project/#project=alpha&tab=runs&kind=plan&id=${LEGACY}`);
    await page.reload();
    await page.getByRole('button', { name: 'Approve', exact: true }).waitFor();
    assert(!(await page.getByRole('button', { name: 'Approve', exact: true }).isDisabled()));
    assert.equal(await page.getByText('How wishes are handled').count(), 0);
    // No reviewed maps: an empty manifest binds a fresh empty directory; defaults are visible; one Approve.
    await page.goto(`http://widget.test/widgets/project/#project=alpha&tab=runs&kind=plan&id=${EMPTY}`);
    await page.reload();
    await page.getByText(/No reviewed files are provided\. Converter setting mappings\.directory points at a fresh, empty run-owned directory/).waitFor();
    assert(await page.getByText(/No placeholder or header-only file is added/).isVisible());
    assert(await page.getByText(/categories\.csv: deliberately not provided — the converter’s own default applies/).isVisible());
    assert(await page.getByText(/trust_level_mapping\.yml: may be generated/).isVisible());
    assert.equal(await page.getByText('Preview the exact bytes').count(), 0);
    assert.equal(await page.getByRole('checkbox').count(), 0, 'no mapping toggles or extra approval');
    assert(!(await page.getByRole('button', { name: 'Approve', exact: true }).isDisabled()));
    assert.equal(await page.getByRole('button', { name: /approve/i }).count(), 1, 'one approval covers the plan');
    await shot('empty');
    assert(await overflow() <= 0, `empty-manifest plan overflow at ${viewport.width}px`);

    // A master-list export is a preparation job: listed apart from passes and worded as such.
    await page.goto('http://widget.test/widgets/project/#project=alpha&tab=runs');
    await page.reload();
    await page.getByRole('heading', { name: 'PREPARATION' }).waitFor();
    assert(await page.getByText('Preparation jobs are not passes: they neither convert nor import.').isVisible());
    await page.getByRole('button', { name: /Master-list export · all/ }).click();
    await page.getByText('Approve this master-list export (preparation) on Development v1?').waitFor();
    assert(await page.getByText(/Preparation only: loads a disposable copy of the source/).isVisible());
    assert.equal(await page.getByText(/Converts the data|Imports the converted data/).count(), 0);
    await shot('master');
    assert(await overflow() <= 0, `master-list plan overflow at ${viewport.width}px`);
    decisions.length = 0;
    await context.close();
  }
  assert.deepEqual(errors, []);
  assert.deepEqual(external, []);
  console.log(JSON.stringify({ result: 'INTAKE_PLAN_OK', viewports: sizes.map(s => s.width), errors: errors.length }));
} finally {
  await browser.close();
}
