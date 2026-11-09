// The Project page: one project at a glance, its files, findings and runs.
import { $, el, safe, toast, api, explain, card, details } from './ui.js';
import { runsView } from './runs.js';
import { findingsView } from './findings.js';

const POLL_MS = 15000;
const TABS = [['overview', 'Overview'], ['files', 'Files'], ['findings', 'Findings'], ['runs', 'Runs']];
const STAGE_NAMES = { files: 'Files', workspace: 'Workspace', source_db: 'Source DB', finding: 'Finding', converter: 'Converter', convert: 'Convert', review: 'Import', site: 'Check site' };
const state = { projects: [], project: null, tab: 'overview', selected: null, files: null, guide: null, counts: {}, details: false, typing: false, generation: 0, findings: { filter: 'proposed', q: '' } };

const size = (bytes) => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : bytes >= 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.round(bytes / 1e3)} KB`);
const day = (iso) => (iso ? new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '');
// IDs and hashes belong in Details, not in the sentence.
const plain = (text) => text.replace(/\s*\b(?:plan|run|finding)-[0-9a-f]{32}\b/g, '').replace(/\s*\b[0-9a-f]{64}\b/g, '')
  .replace(/ (?:on the Project page|in the (?:Runs|Findings) (?:tab|widget))/g, '').replace(/\s+([.,])/g, '$1');
const deliveryLabel = (record) => (record.kind === 'launch' ? 'Launch' : `Development v${record.version}`);
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
  return { project: params.get('project') || params.get('ws'), tab: TABS.some(([id]) => id === tab) ? tab : null,
    selected: kind && params.get('id') ? { kind, id: params.get('id') } : null };
}

function writeHash() {
  const params = new URLSearchParams({ project: state.project || '', tab: state.tab });
  if (state.selected) { params.set('kind', state.selected.kind); params.set('id', state.selected.id); }
  history.replaceState(null, '', `#${params}`);
}

// What stops leaving a tab: an open finding with unsaved edits.
const leaving = () => !(views.findings && views.findings.unsaved()) || confirm('Discard your edits to this finding?');

function go(tab, selected = null) {
  if (!leaving()) return;
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
  mount,
  open: (kind, id) => { state.selected = { kind, id }; writeHash(); views[tab].show(); },
  close: () => { state.selected = null; writeHash(); views[tab].show(); refreshCounts(); },
  refresh: () => { views[tab].show(); refreshCounts(); },
});
const views = { runs: runsView(context('runs')), findings: findingsView(context('findings')) };

function newest(kind) {
  return ((state.files && state.files.deliveries) || []).find((record) => record.kind === kind && !record.replaced_by) || null;
}

function renderData() {
  const development = newest('development');
  const launch = newest('launch');
  const parts = [];
  if (development) parts.push(el('span', { class: 'badge' }, deliveryLabel(development).toUpperCase()), `${fileText(development)}labelled ${day(development.labelled_at)}`);
  if (launch) parts.push(el('span', { class: 'badge launch' }, 'LAUNCH RECEIVED'));
  if (!parts.length) parts.push(el('span', { class: 'badge none' }, 'NO DATA LABELLED'));
  $('data').replaceChildren(...parts);
}

function renderStages() {
  const stages = (state.guide && state.guide.stages) || [];
  $('stages').replaceChildren(...stages.map((stage) => el('li', { class: stage.state }, STAGE_NAMES[stage.id] || stage.label)));
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
  return [card(eyebrow, plain(next.action), el('div', { class: 'row' }, left), details(el('pre', { class: 'mono' }, lines.join('\n')))), ...others, ...also];
}

async function submitLabel(kind, extra) {
  try {
    const result = await api('api/label', { workspace: state.project, kind, ...extra });
    toast(`Labelled as ${result.delivery}.`);
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
  const list = fileRows(files.unlabelled_files, (entry) => `${size(entry.bytes)} · ${day(new Date(entry.mtime_ns / 1e6).toISOString())}`);
  const hidden = ((files.counts || {}).unlabelled || 0) - files.unlabelled_files.length;
  const body = { files: files.unlabelled_files };
  const replacing = files.deliveries.some((record) => record.kind === 'launch' && !record.replaced_by);
  let actions;
  if (state.typing) {
    const box = el('input', { class: 'confirm', placeholder: 'Type LAUNCH', autocomplete: 'off', 'aria-label': 'Type LAUNCH to confirm' });
    const confirmButton = el('button', { type: 'button', class: 'btn launch', disabled: true, onclick: () => submitLabel('launch', { ...body, confirm: 'LAUNCH', replaces_launch: replacing }) },
      replacing ? 'Replace the launch data' : 'These are the launch files');
    box.addEventListener('input', () => { confirmButton.disabled = box.value !== 'LAUNCH'; });
    actions = el('div', { class: 'actions' }, box, confirmButton, el('button', { type: 'button', class: 'btn q', onclick: () => { state.typing = false; render(); } }, 'Cancel'));
  } else {
    actions = el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: () => submitLabel('development', body) }, 'Development'),
      el('button', { type: 'button', class: 'btn q', onclick: () => { state.typing = true; render(); } }, 'Launch'));
  }
  return card('NEW FILES, FOR YOU', 'What are these files for?', list, hidden > 0 ? el('p', { class: 'hint' }, `and ${hidden} more. Label these first, then the rest.`) : null, actions);
}

function renderFiles() {
  const files = state.files;
  if (!files) return [el('p', { class: 'quiet' }, 'Loading…')];
  if (!files.initialized && !files.not_ready_files.length) {
    return [el('p', { class: 'quiet' }, files.unlabelled_files.length ? 'Files have arrived. Ask migration-data in a chat in this project to create the workspace; then label them here.'
      : 'No files yet. Copy them to the drop folder with scp, then run silo intake as root.')];
  }
  const out = [];
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
  if (files.initialized && files.unlabelled_files.length) out.push(newFilesCard(files));
  if (files.labelled_files.length) out.push(el('p', { class: 'quiet' }, `${files.labelled_files.length} labelled file(s) are waiting for migration-data to take them.`));
  const current = [newest('development'), newest('launch')].filter(Boolean);
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
  if (state.typing && document.activeElement && document.activeElement.classList.contains('confirm')) return;  // don't wipe what's being typed
  $('project-name').textContent = state.project || 'No projects yet';
  renderData();
  renderStages();
  renderTabs();
  if (state.tab === 'runs' || state.tab === 'findings') { views[state.tab].show(); return; }
  mount(state.tab === 'files' ? renderFiles() : renderOverview());
}

async function refreshCounts() {
  try { state.counts = await api(`api/counts?${new URLSearchParams({ workspace: state.project })}`); renderTabs(); } catch { /* the tabs keep their last counts */ }
}

async function refresh(full = true) {
  if (!state.project) { render(); return; }
  const generation = ++state.generation;
  const project = state.project;
  const stale = () => generation !== state.generation || project !== state.project;
  const repaint = () => { if (state.tab === 'overview' || state.tab === 'files') render(); else { renderData(); renderStages(); renderTabs(); } };
  // The quick answers first, so the page has something to show while the slower one runs.
  try {
    const [files, counts] = await Promise.all([api(`api/files?workspace=${encodeURIComponent(project)}`), api(`api/counts?workspace=${encodeURIComponent(project)}`)]);
    if (stale()) return;
    state.files = files;
    state.counts = counts;
    repaint();
  } catch (error) { if (!stale()) toast(explain(error), true); }
  if (full && (state.tab === 'runs' || state.tab === 'findings') && !state.selected) views[state.tab].show();
  try {
    const guide = await api(`api/guide?workspace=${encodeURIComponent(project)}`);
    if (stale()) return;
    state.guide = guide;
    repaint();
  } catch (error) { if (!stale()) toast(explain(error), true); }
}

function choose(project) {
  if (!leaving()) { $('project').value = state.project; return; }
  state.project = project;
  state.files = state.guide = null;
  state.counts = {};
  state.selected = null;
  state.typing = false;
  $('project').value = project;
  try { localStorage.setItem('silo-project', project); } catch { /* the default */ }
  writeHash();
  render();
  refresh(false);
}

async function start() {
  applyScheme();
  const wanted = readHash();
  if (wanted.tab) state.tab = wanted.tab;
  state.selected = wanted.selected;
  try {
    state.projects = (await api('api/projects')).projects;
  } catch (error) {
    toast(explain(error), true);
    return;
  }
  $('project').replaceChildren(...state.projects.map((name) => el('option', { value: name }, name)));
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
  setInterval(() => { if (!document.hidden) refresh(false); }, POLL_MS);
}

start();
