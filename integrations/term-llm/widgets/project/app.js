// The Project page. Built with DOM calls only: file names are data, never markup.
const $ = (id) => document.getElementById(id);
const el = (tag, props = {}, ...children) => {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (key.includes('-')) node.setAttribute(key, value); else node[key] = value;
  }
  node.append(...children.filter((child) => child !== null && child !== undefined));
  return node;
};

const POLL_MS = 15000;
const ERRORS = {
  STANDARD_DELIVERY_FILES_CHANGED: 'The files changed since this page loaded. Check them and choose again.',
  STANDARD_DELIVERY_CONFIRM_LAUNCH: 'Type LAUNCH to confirm.',
  STANDARD_DELIVERY_LAUNCH_EXISTS: 'Launch data already exists. Confirm that this replaces it.',
  STANDARD_DELIVERY_LABEL_EXISTING_FIRST: 'Label the data already in this project first.',
  STANDARD_NOT_INITIALIZED: 'This project has no workspace yet. Ask migration-data to create it.',
};

const state = { projects: [], project: null, tab: 'overview', files: null, guide: null, details: false, typing: false, generation: 0 };

function toast(text, bad = false) {
  const box = $('toast');
  box.textContent = text;
  box.className = bad ? 'show bad' : 'show';
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.className = ''; }, bad ? 9000 : 3500);
}

async function api(path, body) {
  const options = body
    ? { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Silo-Project': '1' }, body: JSON.stringify(body) }
    : { credentials: 'same-origin', headers: { Accept: 'application/json' } };
  const response = await fetch(path, options);
  let data = {};
  try { data = await response.json(); } catch { /* not JSON */ }
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

const explain = (error) => ERRORS[String(error.message).split(':')[0]] || `That didn't work: ${error.message}`;
const size = (bytes) => (bytes >= 1e9 ? `${(bytes / 1e9).toFixed(1)} GB` : bytes >= 1e6 ? `${Math.round(bytes / 1e6)} MB` : `${Math.round(bytes / 1e3)} KB`);
const day = (iso) => (iso ? new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : '');
const widget = (name) => `../${name}/#ws=${encodeURIComponent(state.project)}`;
// File names are data from outside: control and direction characters could disguise them.
const safe = (text) => String(text).replace(/[\u0000-\u001f\u007f-\u009f\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g, '\ufffd');
const fileText = (record) => {
  const first = (record.files || [])[0];
  const more = (record.file_count || 0) - 1;
  return first ? `${safe(first.path)}${more > 0 ? ` and ${more} more` : ''} · ` : '';
};
// IDs and hashes belong in Details, not in the sentence.
const plain = (text) => text.replace(/\s*\b(?:plan|run|finding)-[0-9a-f]{32}\b/g, '').replace(/\s*\b[0-9a-f]{64}\b/g, '').replace(/ on the Project page/g, '').replace(/\s+([.,])/g, '$1');
const STAGE_NAMES = { files: 'Files', workspace: 'Workspace', source_db: 'Source DB', finding: 'Finding', converter: 'Converter', convert: 'Convert', review: 'Import', site: 'Check site' };

const applyScheme = () => {
  let scheme = 'system';
  try { scheme = JSON.parse(localStorage.getItem('term-llm:varnish:scheme')) || 'system'; } catch { /* the default */ }
  const light = scheme === 'light' || (scheme === 'system' && matchMedia('(prefers-color-scheme: light)').matches);
  document.documentElement.dataset.scheme = light ? 'light' : 'dark';
};

function readHash() {
  const params = new URLSearchParams(location.hash.slice(1));
  return { project: params.get('project') || params.get('workspace'), tab: params.get('tab') };
}

function writeHash() {
  history.replaceState(null, '', `#project=${encodeURIComponent(state.project || '')}&tab=${state.tab}`);
}

function deliveryLabel(record) {
  return record.kind === 'launch' ? 'Launch' : `Development v${record.version}`;
}

// The newest delivery of a kind, unless it was replaced. Runs use development data until launch
// runs exist, so that's what the page leads with; launch data shows beside it once it arrives.
function newest(kind) {
  return ((state.files && state.files.deliveries) || []).find((record) => record.kind === kind && !record.replaced_by) || null;
}

function renderData() {
  const development = newest('development');
  const launch = newest('launch');
  const parts = [];
  if (development) parts.push(el('span', { className: 'badge', textContent: deliveryLabel(development).toUpperCase() }), `${fileText(development)}labelled ${day(development.labelled_at)}`);
  if (launch) parts.push(el('span', { className: 'badge launch', textContent: 'LAUNCH RECEIVED' }));
  if (!parts.length) parts.push(el('span', { className: 'badge none', textContent: 'NO DATA LABELLED' }));
  $('data').replaceChildren(...parts);
}

function renderStages() {
  const stages = (state.guide && state.guide.stages) || [];
  $('stages').replaceChildren(...stages.map((stage) => el('li', { className: stage.state === 'not_recorded' ? 'current-todo' : stage.state, textContent: STAGE_NAMES[stage.id] || stage.label })));
}

function waitingFiles() {
  const files = state.files;
  if (!files) return 0;
  const counts = files.counts || {};
  return (counts.unlabelled ?? files.unlabelled_files.length) + (counts.refused || 0) + (counts.not_ready ?? files.not_ready_files.length) + files.unlabelled_data.length;
}

function renderTabs() {
  const tab = (id, label, count) => el('button', { type: 'button', className: state.tab === id ? 'on' : '', onclick: () => { state.tab = id; writeHash(); render(); } },
    label, count ? el('span', { className: 'c', textContent: String(count) }) : null);
  const open = (name, label) => el('a', { href: widget(name), target: '_blank', rel: 'noopener', textContent: label });
  $('tabs').replaceChildren(tab('overview', 'Overview'), tab('files', 'Files', waitingFiles()), open('findings', 'Findings'), open('runs', 'Runs'));
}

function nextAction(next) {
  if (next.where === 'Runs widget') return el('a', { className: 'btn', href: widget('runs'), target: '_blank', rel: 'noopener', textContent: 'Open Runs' });
  if (next.where === 'Findings widget') return el('a', { className: 'btn', href: widget('findings'), target: '_blank', rel: 'noopener', textContent: 'Open Findings' });
  if (next.where === 'Project page') return el('button', { type: 'button', className: 'btn', textContent: 'Go to Files', onclick: () => { state.tab = 'files'; writeHash(); render(); } });
  return null;
}

function renderOverview() {
  const guide = state.guide;
  if (!guide) return [el('p', { className: 'quiet', textContent: 'Working out where this project stands…' })];
  const { next } = guide;
  const eyebrow = next.who === 'engineer' ? 'NEXT, FOR YOU' : next.who === 'agent' ? 'NEXT, FOR THE AGENT' : 'NOTHING NEEDED FROM YOU';
  const details = el('button', { type: 'button', className: 'link', textContent: state.details ? 'Hide details' : 'Details', onclick: () => { state.details = !state.details; render(); } });
  const left = nextAction(next) || (next.who === 'agent' ? el('p', { className: 'hint', textContent: 'Ask migration-data in a chat in this project: "What\'s next?"' }) : el('span'));
  const card = el('div', { className: 'card' }, el('div', { className: 'eyebrow', textContent: eyebrow }), el('p', { className: 'say', textContent: plain(next.action) }), el('div', { className: 'row' }, left, details));
  if (state.details) {
    const lines = [`Project    ${guide.project}`, `Stage      ${guide.stage}`, `Next       ${next.action}`,
      ...guide.plans.slice(0, 5).map((plan) => `Plan       ${plan.plan_id} · ${plan.kind || '-'} · ${plan.status}`),
      ...guide.runs.slice(0, 5).map((run) => `Run        ${run.run_id} · ${run.kind || '-'} · ${run.status} · ${run.matched}/${run.checks} checks`)];
    card.append(el('div', { className: 'mono', textContent: lines.join('\n') }));
  }
  const others = guide.waiting_on_engineer.slice(1).map((item) => el('p', { className: 'note', textContent: plain(item.what) }));
  const also = guide.also.map((line) => el('p', { className: 'note', textContent: plain(line) }));
  return [card, ...others, ...also];
}

async function submitLabel(kind, extra) {
  try {
    const result = await api('api/label', { workspace: state.project, kind, ...extra });
    toast(`Labelled as ${result.delivery}.`);
    state.typing = false;
    await refresh();
  } catch (error) {
    toast(explain(error), true);
    await refresh();
  }
}

function newFilesCard(files) {
  const list = el('div', { className: 'files' }, ...files.unlabelled_files.map((item) => el('div', { className: 'file' }, el('span', { textContent: safe(item.path) }), el('span', { textContent: `${size(item.bytes)} · ${day(new Date(item.mtime_ns / 1e6).toISOString())}` }))));
  const hidden = ((files.counts || {}).unlabelled || 0) - files.unlabelled_files.length;
  if (hidden > 0) list.append(el('p', { className: 'hint', textContent: `and ${hidden} more. Label these first, then the rest.` }));
  const body = { files: files.unlabelled_files };
  const replacing = files.deliveries.some((record) => record.kind === 'launch' && !record.replaced_by);
  let actions;
  if (state.typing) {
    const box = el('input', { className: 'confirm', placeholder: 'Type LAUNCH', autocomplete: 'off', 'aria-label': 'Type LAUNCH to confirm' });
    const confirm = el('button', { type: 'button', className: 'btn launch', disabled: true, textContent: replacing ? 'Replace the launch data' : 'These are the launch files', onclick: () => submitLabel('launch', { ...body, confirm: 'LAUNCH', replaces_launch: replacing }) });
    box.addEventListener('input', () => { confirm.disabled = box.value !== 'LAUNCH'; });
    actions = el('div', { className: 'btns' }, box, confirm, el('button', { type: 'button', className: 'btn q', textContent: 'Cancel', onclick: () => { state.typing = false; render(); } }));
  } else {
    actions = el('div', { className: 'btns' },
      el('button', { type: 'button', className: 'btn', textContent: 'Development', onclick: () => submitLabel('development', body) }),
      el('button', { type: 'button', className: 'btn q', textContent: 'Launch', onclick: () => { state.typing = true; render(); } }));
  }
  return el('div', { className: 'card' }, el('div', { className: 'eyebrow', textContent: 'NEW FILES, FOR YOU' }), el('p', { className: 'say', textContent: 'What are these files for?' }), list, actions);
}

function renderFiles() {
  const files = state.files;
  if (!files) return [el('p', { className: 'quiet', textContent: 'Loading…' })];
  if (!files.initialized) {
    return [el('p', { className: 'quiet', textContent: 'This project has no workspace yet. Copy the files to the drop folder, then ask migration-data in a chat in this project to create it.' })];
  }
  const out = [];
  for (const dataset of files.unlabelled_data) {
    out.push(el('div', { className: 'card' }, el('div', { className: 'eyebrow', textContent: 'EXISTING DATA, FOR YOU' }), el('p', { className: 'say', textContent: 'This project has data from before labels existed.' }),
      el('button', { type: 'button', className: 'btn', textContent: 'Label it Development', onclick: () => submitLabel('development', { dataset_id: dataset }) })));
  }
  const problem = (title, items, why) => el('div', { className: 'card' }, el('div', { className: 'eyebrow', textContent: 'NEEDS YOU' }), el('p', { className: 'say', textContent: title }),
    el('div', { className: 'files' }, ...items.map((item) => el('div', { className: 'file' }, el('span', { textContent: safe(item.path) }), el('span', { textContent: why(item) })))));
  if (files.refused_files.length) {
    out.push(problem("These labelled files can't be taken: each is identical to data of the other kind. Remove them from the drop folder.", files.refused_files, (item) => item.delivery));
  }
  if (files.not_ready_files.length) {
    out.push(problem(`Not handed over yet: run silo intake ${state.project} as root. Rename any file whose name shows a \ufffd.`, files.not_ready_files, (item) => size(item.bytes)));
  }
  if (files.unlabelled_files.length) out.push(newFilesCard(files));
  if (files.labelled_files.length) out.push(el('p', { className: 'quiet', textContent: `${files.labelled_files.length} labelled file(s) are waiting for migration-data to take them.` }));
  const isCurrent = (record) => [newest('development'), newest('launch')].some((pick) => pick && pick.dataset_id === record.dataset_id);
  const row = (record, old) => {
    const label = old ? el('span', { textContent: `${deliveryLabel(record)} · replaced` }) : el('span', { className: `badge ${record.kind === 'launch' ? 'launch' : ''}`, textContent: deliveryLabel(record).toUpperCase() });
    return el('div', { className: `item ${old ? 'old' : ''}` }, el('div', {}, label, el('small', { textContent: `${fileText(record)}labelled ${day(record.labelled_at)} by ${safe(record.labelled_by)}` })));
  };
  const current = files.deliveries.filter(isCurrent);
  const earlier = files.deliveries.filter((record) => !isCurrent(record));
  if (current.length) out.push(el('h2', { textContent: 'CURRENT' }), ...current.map((record) => row(record, false)));
  if (earlier.length) out.push(el('h2', { textContent: 'EARLIER' }), ...earlier.map((record) => row(record, true)));
  if (!out.length) out.push(el('p', { className: 'quiet', textContent: 'No files yet. Copy them to the drop folder with scp.' }));
  return out;
}

function render() {
  if (state.typing && document.activeElement && document.activeElement.classList.contains('confirm')) return; // don't wipe what's being typed
  $('project-name').textContent = state.project || 'No projects yet';
  renderData();
  renderStages();
  renderTabs();
  $('content').replaceChildren(...(state.tab === 'files' ? renderFiles() : renderOverview()));
}

async function refresh() {
  if (!state.project) { render(); return; }
  const generation = ++state.generation;
  const project = state.project;
  const stale = () => generation !== state.generation || project !== state.project;
  // The quick answer first, so the page has something to show while the slower one runs.
  try {
    const files = await api(`api/files?workspace=${encodeURIComponent(project)}`);
    if (stale()) return;
    state.files = files;
    render();
  } catch (error) {
    if (!stale()) toast(explain(error), true);
  }
  try {
    const guide = await api(`api/guide?workspace=${encodeURIComponent(project)}`);
    if (stale()) return;
    state.guide = guide;
    render();
  } catch (error) {
    if (!stale()) toast(explain(error), true);
  }
}

function choose(project) {
  state.project = project;
  state.files = state.guide = null;
  state.details = state.typing = false;
  $('project').value = project;
  try { localStorage.setItem('silo-project', project); } catch { /* the default */ }
  writeHash();
  render();
  refresh();
}

async function start() {
  applyScheme();
  const wanted = readHash();
  if (wanted.tab === 'files') state.tab = 'files';
  try {
    state.projects = (await api('api/projects')).projects;
  } catch (error) {
    toast(explain(error), true);
    return;
  }
  $('project').replaceChildren(...state.projects.map((name) => el('option', { value: name, textContent: name })));
  $('project').addEventListener('change', (event) => choose(event.target.value));
  let last = null;
  try { last = localStorage.getItem('silo-project'); } catch { /* the default */ }
  const project = [wanted.project, last, state.projects[0]].find((name) => name && state.projects.includes(name));
  if (project) choose(project); else render();
  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
}

start();
