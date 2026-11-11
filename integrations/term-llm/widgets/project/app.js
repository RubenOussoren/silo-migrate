// The Project page: one project at a glance, its files, findings and runs.
import { $, el, safe, short, toast, api, lists, explain, card, details, back, facts } from './ui.js';
import { runsView } from './runs.js';
import { findingsView } from './findings.js';

const POLL_MS = 15000;
const TABS = [['overview', 'Overview'], ['files', 'Files'], ['findings', 'Findings'], ['runs', 'Runs']];
const STAGE_NAMES = { files: 'Files', workspace: 'Workspace', source_db: 'Source DB', finding: 'Finding', converter: 'Converter', convert: 'Convert', review: 'Import', site: 'Check site', release: 'Release backup' };
const state = { projects: [], project: null, tab: 'overview', selected: null, files: null, guide: null, counts: {}, details: false, typing: false, generation: 0, findings: { filter: 'proposed', q: '' }, removal: null, labelResult: null, selectedFiles: null, setup: null };

const count = (n, word) => `${n} ${word}${n === 1 ? '' : 's'}`;
const size = (bytes) => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : bytes >= 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.round(bytes / 1e3)} KB`);
const day = (iso) => (iso ? new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '');
// IDs and hashes belong in Details, not in the sentence.
const plain = (text) => text.replace(/\s*\b(?:plan|run|finding)-[0-9a-f]{32}\b/g, '').replace(/\s*\b[0-9a-f]{64}\b/g, '')
  .replace(/ (?:on the Project page|in the (?:Runs|Findings) (?:tab|widget))/g, '').replace(/\s+([.,])/g, '$1');
const deliveryLabel = (record) => (record.kind === 'base_site' ? `Base site v${record.version}` : record.kind === 'launch' ? 'Launch' : `Development v${record.version}`);
const fileText = (record) => {
  const first = (record.files || [])[0];
  const more = (record.file_count || 0) - 1;
  return first ? `${safe(first.path)}${more > 0 ? ` and ${more} more` : ''} · ` : '';
};

function applyScheme() {
  let scheme = 'system';
  try { scheme = JSON.parse(localStorage.getItem('term-llm:varnish:scheme')) || 'system'; } catch { /* the default */ }
  const light = scheme === 'light' || (scheme === 'system' && matchMedia('(prefers-color-scheme: light)').matches);
  document.documentElement.dataset.scheme = light ? 'light' : 'dark';
}

function readHash() {
  const params = new URLSearchParams(location.hash.slice(1));
  const tab = params.get('tab');
  const kind = params.get('kind');
  const kinds = { runs: ['plan', 'run', 'push', 'converter', 'pass', 'accept', 'changes'], findings: ['finding'] }[tab] || [];
  return { project: params.get('project') || params.get('ws'), tab: TABS.some(([id]) => id === tab) ? tab : null,
    selected: kinds.includes(kind) && params.get('id') ? { kind, id: params.get('id') } : null };
}

function writeHash() {
  const params = new URLSearchParams({ project: state.project || '', tab: state.tab });
  if (state.selected) { params.set('kind', state.selected.kind); params.set('id', state.selected.id); }
  history.replaceState(null, '', `#${params}`);
}

// What stops leaving a tab: an open finding with unsaved edits.
function leaving() {
  if (!(views.findings && views.findings.unsaved())) return true;
  if (!confirm('Discard your edits to this finding?')) return false;
  views.findings.discard();
  return true;
}

function go(tab, selected = null) {
  if (!leaving()) return;
  if (state.removal) {
    if (state.removal.working) return;  // it finishes on this page
    // After a removal, the same way out as Done: a removed project leaves the list.
    if (state.removal.result) { closeRemoval().then(() => go(tab, selected)).catch((error) => toast(explain(error), true)); return; }
    state.removal = null;
  }
  cancelViews();
  state.tab = tab;
  state.selected = selected;
  writeHash();
  render();
}

const mount = (nodes) => $('content').replaceChildren(...nodes.filter(Boolean));
const context = (tab) => ({
  get project() { return state.project; },
  get selected() { return state.selected; },
  state: state.findings,
  mount: (nodes) => { if (state.tab === tab) mount(nodes); },
  open: (kind, id) => { cancelViews(); state.selected = { kind, id }; writeHash(); views[tab].show(); },
  close: () => { cancelViews(); state.selected = null; writeHash(); views[tab].show(); refreshCounts(); },
  refresh: () => { cancelViews(); views[tab].show(); refreshCounts(); },
});
const views = { runs: runsView(context('runs')), findings: findingsView(context('findings')) };
const cancelViews = () => { for (const view of Object.values(views)) view.cancel(); };

function warmLists(project) {
  // Read-only lists, in page memory only. Never prefetch approval details or private input texts.
  return lists.load(`api/boards?${new URLSearchParams({ workspace: project })}`).catch(() => {});
}

function newest(kind) {
  return ((state.files && state.files.deliveries) || []).find((record) => record.kind === kind && !record.replaced_by) || null;
}

function renderData() {
  const development = newest('development');
  const launch = newest('launch');
  const parts = [];
  // A merge project's source file is a Discourse backup: its name starts with the customer's site name.
  // This strip is on every tab (and in every screenshot), so it says what the file is. The Files tab has the names.
  const siteBackup = ((state.files && state.files.setup) || {}).platform === 'discourse';
  if (development) parts.push(el('span', { class: 'badge' }, deliveryLabel(development).toUpperCase()), `${siteBackup ? 'source site backup · ' : fileText(development)}labelled ${day(development.labelled_at)}`);
  if (launch) parts.push(el('span', { class: 'badge launch' }, 'LAUNCH RECEIVED'));
  if (!parts.length) parts.push(el('span', { class: 'badge none' }, 'NO DATA LABELLED'));
  const base = newest('base_site');
  if (base) parts.push(el('span', { class: 'badge' }, deliveryLabel(base)), `sandbox backup · labelled ${day(base.labelled_at)}`);
  $('data').replaceChildren(...parts);
}

function renderStages() {
  const stages = (state.guide && state.guide.stages) || [];
  $('stages').replaceChildren(...stages.map((stage) => el('li', { class: stage.state }, stage.id === 'review' && stage.label.startsWith('Import on Base site') ? stage.label : STAGE_NAMES[stage.id] || stage.label)));
}

function filesWaiting() {
  const files = state.files;
  if (!files) return 0;
  const counts = files.counts || {};
  return (counts.unlabelled ?? files.unlabelled_files.length) + (counts.refused || 0) + (counts.not_ready ?? files.not_ready_files.length) + files.unlabelled_data.length;
}

function renderTabs() {
  const count = { files: filesWaiting(), findings: state.counts.findings || 0, runs: state.counts.runs || 0 };
  $('tabs').replaceChildren(...TABS.map(([id, label]) => el('button', { type: 'button', class: state.tab === id ? 'on' : '', onclick: () => go(id) },
    label, count[id] ? el('span', { class: 'c' }, String(count[id])) : null)));
}

function nextAction(next) {
  const tab = { 'Runs tab': 'runs', 'Runs widget': 'runs', 'Findings tab': 'findings', 'Findings widget': 'findings', 'Project page': 'files' }[next.where];
  const label = { runs: 'Go to Runs', findings: 'Go to Findings', files: 'Go to Files' }[tab];
  return tab ? el('button', { type: 'button', class: 'btn', onclick: () => go(tab) }, label) : null;
}

function renderOverview() {
  const guide = state.guide;
  if (!guide) return [el('p', { class: 'quiet' }, 'Working out where this project stands…')];
  const { next } = guide;
  const eyebrow = next.who === 'engineer' ? 'NEXT, FOR YOU' : next.who === 'agent' ? 'NEXT, FOR THE AGENT' : 'NOTHING NEEDED FROM YOU';
  const left = nextAction(next) || (next.who === 'agent' ? el('p', { class: 'hint' }, 'Ask migration-data in a chat in this project: "What\'s next?"') : el('span'));
  const lines = [`Project    ${guide.project}`, `Stage      ${guide.stage}`, `Next       ${next.action}`,
    ...guide.plans.slice(0, 5).map((plan) => `Plan       ${plan.plan_id} · ${plan.kind || '-'} · ${plan.status}`),
    ...guide.runs.slice(0, 5).map((run) => `Run        ${run.run_id} · ${run.kind || '-'} · ${run.status} · ${run.matched}/${run.checks} checks`)];
  const others = guide.waiting_on_engineer.slice(1).map((entry) => el('p', { class: 'note' }, plain(entry.what)));
  const also = guide.also.map((line) => el('p', { class: 'note' }, plain(line)));
  // The page redraws every few seconds: an open Details stays open.
  const more = details(el('pre', { class: 'mono' }, lines.join('\n')));
  more.open = state.details;
  more.addEventListener('toggle', () => { state.details = more.open; });
  const site = guide.site_acceptance || {};
  const accepted = site.accepted ? acceptedCard(site) : null;
  // Once accepted with nothing for anyone to do, the acceptance is the main card.
  const main = accepted && next.who === 'nobody' ? null : card(eyebrow, plain(next.action), el('div', { class: 'row' }, left), more);
  const changed = site.accepted && (site.changed_since_acceptance || []).length
    ? el('div', { class: 'banner warn' }, el('span', {}, el('b', {}, 'Changed since acceptance: '), `${site.changed_since_acceptance.join(', ')}. Launch would use the accepted process unless you accept a newer pass.`),
      el('button', { type: 'button', class: 'btn q', onclick: () => go('runs') }, 'See Runs'))
    : null;
  return [changed, main, accepted, ...others, ...also, manageLine()];
}

// The accepted process: what launch repeats. Withdrawing it is recorded too (nothing is deleted).
function acceptedCard(site) {
  const entry = site.accepted;
  const withdraw = el('button', { type: 'button', class: 'btn q', onclick: async () => {
    if (!confirm(`Withdraw the acceptance of ${state.project}'s process? Launch can't repeat it until you accept a site again. It stays in the record.`)) return;
    withdraw.disabled = true;
    try {
      await api('api/site/review', { workspace: state.project, verdict: 'withdrawn', review_id: entry.id });
      toast('Withdrawn.');
    } catch (error) {
      withdraw.disabled = false;
      toast(explain(error), true);
    }
    refresh();
  } }, 'Withdraw acceptance\u2026');
  return card('ACCEPTED', 'The process is accepted: the customer approved it.',
    facts([['Data', safe(entry.data || '')], ['Converter', short(entry.converter, 7)], ['Accepted', `by ${safe(entry.by)} ${day(entry.at)}`], ['Note', entry.note ? safe(entry.note) : '']]),
    el('p', { class: 'hint' }, 'Next: when the launch dump arrives, label it Launch on the Files tab.'),
    el('div', { class: 'actions' }, withdraw));
}

// Start over and Remove: rare and can't be undone, so they sit quietly at the foot of Overview, and the
// server lists what goes and what stays before anything happens (bin/project_remove.py).
function manageLine() {
  return el('div', { class: 'manage' }, el('span', {}, 'Project'), el('span', { class: 'acts' },
    el('button', { type: 'button', class: 'link', onclick: () => openRemoval(true) }, 'Start over\u2026'),
    el('button', { type: 'button', class: 'link danger', onclick: () => openRemoval(false) }, 'Remove project\u2026')));
}

async function openRemoval(keep) {
  const project = state.project;
  const removal = { keep, project, plan: null, typed: '', working: false, result: null, error: null };
  state.removal = removal;
  render();
  try {
    removal.plan = await api(`api/project/removal?${new URLSearchParams({ workspace: project, keep: keep ? '1' : '0' })}`);
  } catch (error) {
    removal.error = explain(error);
  }
  if (state.removal === removal) render();
}

async function closeRemoval() {
  const removal = state.removal;
  state.removal = null;
  if (removal && removal.result && !removal.keep) {
    await loadProjects();  // the project is gone: show another, or none
    const next = state.projects[0] || null;
    if (next) { choose(next); return; }
    state.project = null;
    state.files = state.guide = null;
  }
  render();
  refresh(false);
}

async function submitRemoval() {
  const removal = state.removal;
  if (!removal || removal.working || removal.result || removal.typed !== removal.project) return;
  removal.working = true;
  $('project').disabled = true;  // no switching project until it has finished
  removal.error = null;
  render();
  try {
    removal.result = await api('api/project/remove', { workspace: removal.project, confirm: removal.typed, keep_received: removal.keep });
    // What the header showed (its label, its stages) is gone with the work.
    state.files = state.guide = null;
    state.counts = {};
  } catch (error) {
    removal.error = explain(error);
  }
  removal.working = false;
  $('project').disabled = false;
  if (state.removal === removal) render();
}

const itemList = (items) => el('ul', { class: 'list' }, items.map((entry) => el('li', { class: entry.warn ? 'warn' : '' },
  el('span', {}, safe(entry.text)), el('span', {}, entry.bytes === null || entry.bytes === undefined ? '' : size(entry.bytes)))));
const dangerCard = (eyebrow, say, ...content) => el('div', { class: 'card danger' }, el('div', { class: 'eyebrow' }, eyebrow), say ? el('p', { class: 'say' }, say) : null, ...content);

function renderRemoval() {
  const removal = state.removal;
  const { project, keep } = removal;
  const title = keep ? 'START OVER' : 'REMOVE PROJECT';
  const backButton = back('Overview', () => { if (!removal.working) closeRemoval(); });
  const button = (label, onclick, cls = 'btn q') => el('button', { type: 'button', class: cls, onclick }, label);
  if (removal.result) {
    const result = removal.result;
    const done = result.removed || {};
    const lines = (result.returned || []).map((entry) => ({ text: `${entry.to} is back in the drop folder`, bytes: entry.bytes }));
    lines.push({ text: keep ? 'Work, released backups, review sites and the source database removed' : 'Work, files, released backups, review sites and the source database removed' });
    if (done.chats) lines.push({ text: `${count(done.chats, 'chat')}${done.attachments ? ` and ${count(done.attachments, 'attachment')}` : ''} removed` });
    return [card(null, null, el('div', { class: 'eyebrow ok' }, keep ? 'STARTED OVER' : 'REMOVED'),
      el('p', { class: 'say' }, keep ? `${project} is ready to start again.` : `${project} has been removed from this server.`),
      itemList(lines), ...(result.notes || []).map((note) => el('p', { class: 'note' }, safe(note))),
      el('p', { class: 'hint' }, safe(result.next || '')), el('div', { class: 'actions' }, button('Done', closeRemoval, 'btn')))];
  }
  if (!removal.plan) {
    return [backButton, dangerCard(title, removal.error || 'Checking what this would remove\u2026', removal.error ? el('div', { class: 'actions' }, button('Back', closeRemoval)) : null)];
  }
  const plan = removal.plan;
  if (!plan.exists) return [backButton, dangerCard(title, `There is nothing of ${project} on this server.`, el('div', { class: 'actions' }, button('Back', closeRemoval)))];
  if (plan.blocked.length) {
    return [backButton, dangerCard(title, 'Not now.', ...plan.blocked.map((entry) => el('p', { class: 'hint' }, safe(entry.text))),
      el('p', { class: 'hint' }, 'Nothing was changed.'), el('div', { class: 'actions' }, button('Back', closeRemoval)))];
  }
  const box = el('input', { class: 'confirm remove-confirm', autocomplete: 'off', spellcheck: 'false', value: removal.typed, 'aria-label': `Type ${project} to confirm`, disabled: removal.working });
  const confirmButton = el('button', { type: 'button', class: 'btn red', disabled: removal.working || removal.typed !== project, onclick: submitRemoval },
    removal.working ? 'Working\u2026' : keep ? 'Start over' : 'Remove project');
  box.addEventListener('input', () => { removal.typed = box.value; confirmButton.disabled = box.value !== project; });
  return [backButton, dangerCard(title, keep ? `Start ${project} again from the beginning?` : `Remove ${project} from this server?`,
    plan.removed.length ? [el('h2', {}, 'REMOVED'), itemList(plan.removed)] : null,
    plan.kept.length ? [el('h2', {}, 'KEPT'), itemList(plan.kept)] : null,
    el('p', { class: 'hint' }, 'This can\u2019t be undone. Released backups in the output folder are deleted too. A short record of who did it and when is kept.'),
    el('label', { class: 'typed' }, 'Type ', el('b', {}, project), ' to confirm', box),
    el('div', { class: 'actions' }, confirmButton, removal.working ? null : button('Cancel', closeRemoval)),
    removal.working ? el('p', { class: 'hint' }, 'This can take a few minutes. Keep this page open.') : null,
    removal.error ? el('p', { class: 'error' }, removal.error) : null)];
}

async function submitLabel(kind, extra) {
  try {
    const result = await api('api/label', { workspace: state.project, kind, ...extra });
    toast(`Labelled as ${result.delivery}.${result.checks ? ` Original SQL-only name and gzip checked.${result.checks.discourse_version ? ` Discourse ${result.checks.discourse_version}.` : ''}${result.input ? ' Registered read-only as base_site.' : ' Ready to take as base_site.'}` : ''}`);
    state.labelResult = result;
    state.selectedFiles = null;
    state.typing = false;
  } catch (error) {
    toast(explain(error), true);
  }
  refresh();
}

function fileRows(items, right) {
  return el('div', { class: 'files' }, items.map((entry) => el('div', { class: 'file' }, el('span', {}, safe(entry.path)), el('span', {}, right(entry)))));
}

function newFilesCard(files) {
  const selected = state.selectedFiles || new Set(files.unlabelled_files.map((entry) => entry.path));
  state.selectedFiles = selected;
  const list = el('div', { class: 'files' }, files.unlabelled_files.map((entry) => {
    const box = el('input', { type: 'checkbox', checked: selected.has(entry.path), 'aria-label': `Select ${safe(entry.path)}` });
    box.addEventListener('change', () => { if (box.checked) selected.add(entry.path); else selected.delete(entry.path); });
    return el('label', { class: 'file' }, el('span', {}, box, ' ', safe(entry.path)), el('span', {}, `${size(entry.bytes)} · ${day(new Date(entry.mtime_ns / 1e6).toISOString())}`));
  }));
  const hidden = ((files.counts || {}).unlabelled || 0) - files.unlabelled_files.length;
  const body = () => ({ files: files.unlabelled_files.filter((entry) => selected.has(entry.path)) });
  const replacing = files.deliveries.some((record) => record.kind === 'launch' && !record.replaced_by);
  let actions;
  if (state.typing) {
    const box = el('input', { class: 'confirm', placeholder: 'Type LAUNCH', autocomplete: 'off', 'aria-label': 'Type LAUNCH to confirm' });
    const confirmButton = el('button', { type: 'button', class: 'btn launch', disabled: true, onclick: () => submitLabel('launch', { ...body(), confirm: 'LAUNCH', replaces_launch: replacing }) },
      replacing ? 'Replace the launch data' : 'These are the launch files');
    box.addEventListener('input', () => { confirmButton.disabled = box.value !== 'LAUNCH'; });
    actions = el('div', { class: 'actions' }, box, confirmButton, el('button', { type: 'button', class: 'btn q', onclick: () => { state.typing = false; render(); } }, 'Cancel'));
  } else {
    actions = el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: () => submitLabel('development', body()) }, 'Development'),
      el('button', { type: 'button', class: 'btn q', onclick: () => { state.typing = true; render(); } }, 'Launch'),
      el('button', { type: 'button', class: 'btn q', onclick: () => submitLabel('base_site', body()) }, 'Base site'));
  }
  return card('NEW FILES, FOR YOU', 'What are these files for?', list, hidden > 0 ? el('p', { class: 'hint' }, `and ${hidden} more. Label these first, then the rest.`) : null, actions, el('p', { class: 'hint' }, 'Base site · a backup of the customer’s sandbox, without uploads. Review sites are built on top of it.'));
}

const PLATFORM = /^[a-z][a-z0-9_.-]{0,31}$/;

async function submitSetup(platform) {
  const setup = state.setup;
  if (!setup || setup.working || !PLATFORM.test(platform)) return;
  const project = state.project;
  setup.working = true;
  render();
  try {
    await api('api/workspace/create', { workspace: project, platform });
    toast('Workspace created. Now say what the files are for.');
  } catch (error) {
    toast(explain(error), true);
  }
  setup.working = false;
  if (state.project === project) { state.setup = null; refresh(); }
}

// The workspace is created here, with the one thing only the engineer knows: the source platform.
// The same card finishes a setup that stopped half way (a failed clone, say); the platform is then fixed.
function setupCard(files, known) {
  const setup = state.setup || (state.setup = { platform: '', working: false });
  const say = files.initialized ? 'Workspace setup isn\u2019t finished.' : 'Files have arrived. Create the workspace.';
  const rows = files.initialized ? null : fileRows(files.unlabelled_files, (entry) => size(entry.bytes));
  if (setup.working) {
    return card('NEXT, FOR YOU', say, rows, el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', disabled: true }, 'Creating\u2026')),
      el('p', { class: 'hint' }, 'This copies discourse-converters from GitHub and can take a few minutes. Keep this page open.'));
  }
  if (known) {
    return card('NEXT, FOR YOU', say, rows, el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: () => submitSetup(known) }, 'Finish setup')),
      el('p', { class: 'hint' }, `Source platform: ${safe(known)}. What was already done is kept. If it stops again, check the server\u2019s GitHub token for discourse-converters (silo use-github, as root), then ask for help.`));
  }
  const box = el('input', { class: 'confirm', placeholder: 'e.g. mybb', autocomplete: 'off', spellcheck: 'false', value: setup.platform, 'aria-label': 'Source platform' });
  const create = el('button', { type: 'button', class: 'btn', disabled: !PLATFORM.test(setup.platform), onclick: () => submitSetup(setup.platform) }, 'Create workspace');
  box.addEventListener('input', () => { setup.platform = box.value.trim(); create.disabled = !PLATFORM.test(setup.platform); });
  box.addEventListener('keydown', (event) => { if (event.key === 'Enter') submitSetup(setup.platform); });
  return card('NEXT, FOR YOU', say, rows, el('label', { class: 'typed' }, 'Source platform'), el('div', { class: 'actions' }, box, create),
    el('p', { class: 'hint' }, 'Lowercase, and the same as the converter\u2019s folder in discourse-converters (converters/PLATFORM). To merge another Discourse site into this one, type discourse. It can\u2019t be changed later without starting over. After this you say what the files are for.'));
}

function renderFiles() {
  const files = state.files;
  if (!files) return [el('p', { class: 'quiet' }, 'Loading…')];
  const setup = files.setup || { complete: files.initialized, platform: null };
  if (!files.initialized && !files.not_ready_files.length && !files.unlabelled_files.length) {
    return [el('p', { class: 'quiet' }, 'No files yet. Copy them to the drop folder with scp, then run silo intake as root.')];
  }
  const out = [];
  // Labels come after the workspace: Development and Launch data belong to its source.
  if (!setup.complete && (files.initialized || files.unlabelled_files.length)) out.push(setupCard(files, setup.platform));
  const labels = files.initialized && (setup.complete || setup.platform);
  const labelled = state.labelResult;
  if (labelled && labelled.checks) out.push(card(labelled.delivery, 'SQL-only backup checked.',
    facts([['File checks', 'Original SQL-only backup name · gzip · regular file'], ['Discourse', labelled.checks.discourse_version || 'Version will be checked in the plan'],
      ['Input', labelled.input ? 'Registered read-only as base_site' : 'Label recorded; take as base_site after workspace setup']])));
  for (const dataset of files.unlabelled_data) {
    out.push(card('EXISTING DATA, FOR YOU', 'This project has data from before labels existed.',
      el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: () => submitLabel('development', { dataset_id: dataset }) }, 'Label it Development'))));
  }
  if (files.refused_files.length) {
    out.push(card('NEEDS YOU', "These labelled files can't be taken: each is identical to data of the other kind. Remove them from the drop folder.", fileRows(files.refused_files, (entry) => entry.delivery)));
  }
  if (files.not_ready_files.length) {
    out.push(card('NEEDS YOU', `Not handed over yet: run silo intake ${state.project} as root. Rename any file whose name shows �.`, fileRows(files.not_ready_files, (entry) => size(entry.bytes))));
  }
  if (labels && files.unlabelled_files.length) out.push(newFilesCard(files));
  if (files.labelled_files.length) out.push(el('p', { class: 'quiet' }, `${files.labelled_files.length} labelled file(s) are waiting for migration-data to take them.`));
  const current = [newest('development'), newest('launch'), newest('base_site')].filter(Boolean);
  const row = (record, old) => el('div', { class: `item static ${old ? 'old' : ''}` }, el('div', {},
    old ? el('span', {}, `${deliveryLabel(record)} · replaced`) : el('span', { class: `badge ${record.kind === 'launch' ? 'launch' : ''}` }, deliveryLabel(record).toUpperCase()),
    el('small', {}, `${fileText(record)}labelled ${day(record.labelled_at)} by ${safe(record.labelled_by)}`)));
  const earlier = files.deliveries.filter((record) => !current.includes(record));
  if (current.length) out.push(el('h2', {}, 'CURRENT'), ...current.map((record) => row(record, false)));
  if (earlier.length) out.push(el('details', { class: 'history' }, el('summary', {}, `Earlier (${earlier.length})`), ...earlier.map((record) => row(record, true))));
  if (!out.length) out.push(el('p', { class: 'quiet' }, 'No files yet. Copy them to the drop folder with scp.'));
  return out;
}

function render() {
  const typing = document.activeElement && document.activeElement.classList.contains('confirm');
  if ((state.typing || state.removal || state.setup) && typing) return;  // don't wipe what's being typed
  $('project-name').textContent = state.project || 'No projects yet';
  renderData();
  renderStages();
  renderTabs();
  if (state.tab === 'runs' || state.tab === 'findings') { views[state.tab].show(); return; }
  mount(state.tab === 'files' ? renderFiles() : state.removal ? renderRemoval() : renderOverview());
}

async function refreshCounts() {
  const project = state.project;
  try {
    const counts = await api(`api/counts?workspace=${encodeURIComponent(project)}`);
    if (project === state.project) { state.counts = counts; renderTabs(); }
  } catch { /* the tabs keep their last counts */ }
}

async function refresh(full = true) {
  if (state.removal) return;
  if (!state.project) { render(); return; }
  const generation = ++state.generation;
  const project = state.project;
  const stale = () => generation !== state.generation || project !== state.project;
  const repaint = () => { if (state.tab === 'overview' || state.tab === 'files') render(); else { renderData(); renderStages(); renderTabs(); } };
  // Independent reads: a slow guide must not hold up files, counts, or navigation.
  await Promise.all([
    (async () => {
      try {
        const files = await api(`api/files?workspace=${encodeURIComponent(project)}`);
        if (!stale()) { state.files = files; repaint(); }
      } catch (error) { if (!stale()) toast(explain(error), true); }
    })(),
    (async () => {
      try {
        const counts = await api(`api/counts?workspace=${encodeURIComponent(project)}`);
        if (!stale()) { state.counts = counts; renderTabs(); }
      } catch { /* the tabs keep their last counts */ }
    })(),
    (async () => {
      try {
        const guide = await api(`api/guide?workspace=${encodeURIComponent(project)}`);
        if (!stale()) { state.guide = guide; repaint(); }
      } catch (error) { if (!stale()) toast(explain(error), true); }
    })(),
  ]);
  if (!stale()) {
    if (full && (state.tab === 'runs' || state.tab === 'findings') && !state.selected) views[state.tab].show();
    warmLists(project);
  }
}

function choose(project) {
  if (!leaving() || (state.removal && state.removal.working)) { $('project').value = state.project; return; }
  if (state.removal && state.removal.result) {  // the same way out as Done, then the chosen project
    closeRemoval().then(() => { if (state.projects.includes(project) && project !== state.project) choose(project); })
      .catch((error) => toast(explain(error), true));
    return;
  }
  cancelViews();
  for (const view of Object.values(views)) view.reset();
  lists.clear();
  ++state.generation;
  state.project = project;
  state.selectedFiles = null; state.labelResult = null; state.setup = null;
  state.files = state.guide = null;
  state.counts = {};
  state.selected = null;
  state.typing = false;
  state.removal = null;
  state.findings.page = 0;  // another project's page or search would show an empty list
  state.findings.q = '';
  $('project').value = project;
  try { localStorage.setItem('silo-project', project); } catch { /* the default */ }
  writeHash();
  render();
  warmLists(project);
  refresh(false);
}

async function loadProjects() {
  state.projects = (await api('api/projects')).projects;
  $('project').replaceChildren(...state.projects.map((name) => el('option', { value: name }, name)));
}

async function start() {
  applyScheme();
  const wanted = readHash();
  if (wanted.tab) state.tab = wanted.tab;
  state.selected = wanted.selected;
  try {
    await loadProjects();
  } catch (error) {
    toast(explain(error), true);
    return;
  }
  $('project').addEventListener('change', (event) => choose(event.target.value));
  let last = null;
  try { last = localStorage.getItem('silo-project'); } catch { /* the default */ }
  const project = [wanted.project, last, state.projects[0]].find((name) => name && state.projects.includes(name));
  if (project) {
    const selected = state.selected;
    choose(project);
    if (selected) { state.selected = selected; writeHash(); render(); }
  } else render();
  // Only the overview and files refresh by themselves: a detail being read or edited stays put.
  // One refresh at a time: the guide can take a while, and a slow server shouldn't get a queue.
  let busy = false;
  setInterval(async () => {
    if (document.hidden || busy) return;
    busy = true;
    try { await refresh(false); } finally { busy = false; }
  }, POLL_MS);
}

start();
