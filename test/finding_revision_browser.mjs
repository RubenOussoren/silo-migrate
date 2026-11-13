// Invented fixtures only. Same local Playwright environment as project_navigation_browser.mjs
// (PLAYWRIGHT_CORE and CHROMIUM; nothing is installed, no service, model or network).
// A release or a rejection names the proposal the page showed; when migration-data has revised it
// since, nothing is decided and the engineer's unsaved text survives reading the revision.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';
const { chromium } = await import(pathToFileURL(resolve(process.env.PLAYWRIGHT_CORE)));
const browser = await chromium.launch({ executablePath: process.env.CHROMIUM });
const root = resolve('integrations/term-llm/widgets/project');
const findingId = 'finding-' + 'a'.repeat(32);
const digests = { 1: '1'.repeat(64), 2: '2'.repeat(64) };
const proposals = { 1: 'First invented proposal', 2: 'Second invented proposal' };
try {
  const page = await browser.newPage({ viewport: { width: 1100, height: 800 } });
  const errors = [], decisions = [];
  let revision = 1, status = 'proposed', releasedText = null, matches = true;
  page.on('pageerror', error => errors.push(error.message));
  await page.route('**/*', async route => {
    const request = route.request(), url = new URL(request.url());
    assert.equal(url.origin, 'http://widget.test');
    const path = url.pathname.replace('/widgets/project/', '');
    const json = (value, code = 200) => route.fulfill({ status: code, contentType: 'application/json', body: JSON.stringify(value) });
    const entry = { id: findingId, title: 'invented finding', status, kind: 'schema', proposed_at: '2026-11-10T12:00:00Z' };
    if (path === 'api/projects') return json({ projects: ['alpha'] });
    if (path === 'api/files') return json({ deliveries: [], counts: {}, unlabelled_files: [], not_ready_files: [], unlabelled_data: [] });
    if (path === 'api/counts') return json({ findings: 1, runs: 0 });
    if (path === 'api/guide') return json({ project: 'alpha', stages: [], plans: [], runs: [], waiting_on_engineer: [], also: [], next: { who: 'nobody', action: 'Fixture overview' } });
    if (path === 'api/boards') return json({ runs: { passes: [], updates: [], converter: { branch: 'alpha', not_pushed: 0 } },
      findings: { review: status === 'proposed' ? [entry] : [], progress: status === 'released' ? [entry] : [], done: [], other: status === 'rejected' ? [entry] : [] } });
    if (path === 'api/findings/finding') return json({ id: findingId, kind: 'schema', status, versions: [], proposal: proposals[revision],
      proposal_revision: matches ? revision : null, proposal_sha256: matches ? digests[revision] : null,
      proposal_revised_at: revision > 1 ? '2026-11-11T12:00:00Z' : null, released: releasedText });
    if (path === 'api/findings/release' || path === 'api/findings/reject') {
      const body = request.postDataJSON();
      assert.equal(request.headers()['x-silo-project'], '1');
      assert.equal(body.workspace, 'alpha'); assert.equal(body.id, findingId);
      decisions.push({ action: path.split('/').pop(), text: body.text, proposal_sha256: body.proposal_sha256 });
      if (body.proposal_sha256 !== digests[revision]) return json({ error: 'STANDARD_PROPOSAL_CHANGED' }, 409);
      status = path.endsWith('release') ? 'released' : 'rejected';
      if (status === 'released') releasedText = body.text;
      return json({ status, finding_id: findingId });
    }
    if (path.startsWith('fonts/')) return route.fulfill({ status: 204, body: '' });
    const name = path || 'index.html';
    const mime = name.endsWith('.js') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html';
    return route.fulfill({ contentType: mime, body: readFileSync(resolve(root, name)) });
  });
  const content = () => page.locator('#content').innerText();
  const editor = page.getByRole('textbox', { name: 'Text to release' });
  const load = page.getByRole('button', { name: 'Load the revised proposal', exact: true });
  const open = async () => {
    await page.goto('about:blank');
    await page.goto(`http://widget.test/widgets/project/#project=alpha&tab=findings&kind=finding&id=${findingId}`);
    await editor.waitFor();
  };
  const decide = async (name) => {
    const before = decisions.length;
    page.once('dialog', dialog => dialog.accept());
    await page.getByRole('button', { name, exact: true }).click();
    for (let i = 0; i < 100 && decisions.length === before; i++) await new Promise(done => setTimeout(done, 20));
    assert.equal(decisions.length, before + 1, `${name} reached the server once`);
    return decisions[before];
  };

  // The first proposal is shown as it always was: no revision is named until there is a second one.
  await open();
  assert.equal(await editor.inputValue(), proposals[1]);
  assert(!/revision/i.test(await content()), 'an unrevised proposal has no revision wording');
  await editor.fill('Engineer edited invented text');

  // migration-data revises it while the page is open: neither decision goes through, the text stays.
  revision = 2;
  assert.deepEqual(await decide('Reject'), { action: 'reject', text: undefined, proposal_sha256: digests[1] });
  await load.waitFor();
  assert.equal(status, 'proposed');
  assert.equal(await editor.inputValue(), 'Engineer edited invented text', 'a refused rejection keeps the unsaved text');
  assert.deepEqual(await decide('Release'), { action: 'release', text: 'Engineer edited invented text', proposal_sha256: digests[1] });
  await page.getByText('your text to release is kept', { exact: false }).waitFor();
  assert.equal(status, 'proposed');
  assert.equal(releasedText, null);
  assert.equal(await editor.inputValue(), 'Engineer edited invented text', 'a refused release keeps the unsaved text');
  assert.match(await content(), /First invented proposal/, 'the page still shows what was read');
  assert(await page.getByRole('button', { name: 'Release', exact: true }).isEnabled(), 'the decision can be retried after reading');

  // Reading the revision replaces the proposal, never the engineer's text; the next decision names the revision.
  await load.click();
  await page.getByText('Second invented proposal', { exact: false }).first().waitFor();
  assert.equal(await editor.inputValue(), 'Engineer edited invented text', 'the revision does not replace unsaved text');
  const shown = await content();
  assert.match(shown, /\(revision 2\)/i);
  assert.match(shown, /compare the two before you release/);
  assert(!/First invented proposal/.test(shown), 'the earlier revision is no longer offered');
  assert.deepEqual(await decide('Release'), { action: 'release', text: 'Engineer edited invented text', proposal_sha256: digests[2] });
  await page.getByText('Released text (what the coding agents see)', { exact: false }).waitFor();
  assert.equal(releasedText, 'Engineer edited invented text');

  // With nothing edited, reading the revision simply shows it, and a rejection names it.
  status = 'proposed'; releasedText = null; revision = 1;
  await open();
  revision = 2;
  await decide('Reject');
  await page.getByText('Load the revision to read it.', { exact: false }).waitFor();
  await load.click();
  await page.getByText('(revision 2)', { exact: false }).waitFor();
  assert.equal(await editor.inputValue(), proposals[2], 'an untouched editor follows the revision');
  assert.equal((await decide('Reject')).proposal_sha256, digests[2]);
  for (let i = 0; i < 100 && status !== 'rejected'; i++) await new Promise(done => setTimeout(done, 20));
  assert.equal(status, 'rejected');

  // Decided elsewhere while the engineer was writing: the text is not thrown away by the read.
  status = 'proposed'; revision = 1;
  await open();
  await editor.fill('Text written before someone else decided');
  revision = 2;
  await decide('Release');
  await load.waitFor();
  status = 'rejected';
  await load.click();
  await page.getByText('This finding was decided in the meantime.', { exact: false }).waitFor();
  assert.equal(await editor.inputValue(), 'Text written before someone else decided');

  // A stored proposal that is not its record has no digest to name: the page says so before any decision.
  status = 'proposed'; revision = 1; matches = false;
  page.once('dialog', dialog => dialog.accept());  // leaving the unsaved text above
  await open();
  await page.getByText("The stored proposal doesn't match its record", { exact: false }).waitFor();
  for (const name of ['Release', 'Reject']) assert.equal(await page.getByRole('button', { name, exact: true }).isDisabled(), true, name);
  const before = decisions.length;
  await page.getByRole('button', { name: 'Release', exact: true }).click({ force: true });
  assert.equal(decisions.length, before);

  assert.equal(errors.length, 0, errors.join('\n'));
  console.log(JSON.stringify({ result: 'FINDING_REVISION_OK', decisions: decisions.length, errors: errors.length }));
} finally { await browser.close(); }
