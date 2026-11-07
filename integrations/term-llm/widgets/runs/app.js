// Runs widget page. All text from the server is inserted with textContent, never as HTML.
const ERRORS = {
  STANDARD_BUSY: 'The project is busy (a run or another decision). Try again in a moment.',
  STANDARD_STALE_PLAN: 'This plan is stale: something it binds changed (inputs, converter commit, code or runtime). Discard it and ask migration-data to propose again.',
  STANDARD_APPROVAL_MISMATCH: 'The plan differs from what this page showed. Nothing was approved.',
  STANDARD_TRANSITION_INVALID: 'That was already decided. The page has been refreshed.',
  STANDARD_NOT_APPROVED: 'Approve the plan first.',
  STANDARD_PLAN_CONSUMED: 'This plan was already used (or discarded).',
  STANDARD_CAPACITY: 'Not enough memory or disk on the server right now: reset finished runs that still hold instances, or free disk.',
  STANDARD_DIRTY_INSTANCE: 'An earlier run left an instance dirty: reset that run first.',
  STANDARD_PUSH_STALE: 'The branch changed since this push was proposed. Ask converter-developer to propose again.',
  STANDARD_PUSH_REJECTED: 'GitHub rejected the push (the branch moved on GitHub). Nothing was changed there.',
  STANDARD_PUSH_TOKEN_MISSING: 'No GitHub token for this repository owner on the server.',
  STANDARD_REQUEST_REFUSED: 'The request was refused. Reload the page.',
  STANDARD_OPERATION_TIMEOUT: 'No answer in time. It may still have happened: press Refresh before trying again.',
};
const RUN_DONE = new Set(['completed', 'failed', 'interrupted']);
const state = { workspace: '', selected: null, overview: null };
const $ = (id) => document.getElementById(id);
let pollTimer = null;
// Each list or detail load gets a ticket; only the latest one may draw. Answers take seconds
// (each is a control call), so switching projects quickly would otherwise let an older,
// slower answer overwrite the newer one.
const tickets = { list: 0, detail: 0 };

function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat()) {
    if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

const badge = (status) => el('span', { class: `badge ${status || ''}` }, (status || '').replace('_', ' '));
const short = (value, n = 12) => (value ? String(value).slice(0, n) : '');

function ago(iso) {
  if (!iso) return '';
  const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (seconds < 90) return 'just now';
  if (seconds < 5400) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 129600) return `${Math.round(seconds / 3600)} h ago`;
  return new Date(iso).toLocaleDateString();
}

function toast(message, bad = false) {
  const box = $('toast');
  box.textContent = message;
  box.className = bad ? 'show bad' : 'show';
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.className = ''; }, bad ? 10000 : 4500);
}

async function api(path, body) {
  const options = body
    ? { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Silo-Runs': '1' }, body: JSON.stringify(body) }
    : { credentials: 'same-origin', headers: { Accept: 'application/json' } };
  const response = await fetch(path, options);
  let data = {};
  try { data = await response.json(); } catch { /* not JSON */ }
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

const explain = (error) => ERRORS[String(error.message).split(':')[0]] || `Refused: ${error.message}`;

function readHash() {
  const params = new URLSearchParams(location.hash.slice(1));
  if (params.get('ws')) state.workspace = params.get('ws');
  const kind = params.get('kind');
  state.selected = ['plan', 'run', 'push', 'converter'].includes(kind) && params.get('id') ? { kind, id: params.get('id') } : null;
}

function writeHash() {
  const params = new URLSearchParams();
  if (state.workspace) params.set('ws', state.workspace);
  if (state.selected) { params.set('kind', state.selected.kind); params.set('id', state.selected.id); }
  history.replaceState(null, '', `#${params}`);
}

async function chooseWorkspace() {
  let names = [];
  try {
    const [summary, listed] = await Promise.all([api('api/summary'), api('api/workspaces')]);
    names = listed.workspaces;
    if (!state.workspace || !names.includes(state.workspace)) {
      state.workspace = (summary.workspaces[0] && summary.workspaces[0].workspace) || names[0] || '';
    }
  } catch (error) { toast(`Couldn't load projects: ${error.message}`, true); }
  const select = $('workspace');
  select.replaceChildren(...names.map((name) => el('option', { value: name }, name)));
  if (!names.length) select.append(el('option', { value: '' }, 'No projects yet'));
  select.value = state.workspace;
}

function entry(kind, id, title, meta) {
  const selected = state.selected && state.selected.kind === kind && state.selected.id === id;
  return el('li', {}, el('button', { type: 'button', class: selected ? 'item selected' : 'item', 'data-kind': kind, 'data-id': id, onclick: () => open({ kind, id }) },
    el('span', { class: 'title' }, title), el('span', { class: 'meta' }, meta)));
}

async function loadList() {
  const list = $('items');
  const ticket = ++tickets.list;
  const workspace = state.workspace;
  if (!workspace) { list.replaceChildren(el('li', { class: 'none' }, 'No projects yet.')); return; }
  // A different project: say so at once instead of leaving the previous project's list up.
  if (!state.overview || state.overview.workspace !== workspace) list.replaceChildren(el('li', { class: 'none' }, `Loading ${workspace}…`));
  let data;
  try { data = await api(`api/overview?${new URLSearchParams({ workspace })}`); } catch (error) {
    if (ticket !== tickets.list) return;
    list.replaceChildren(el('li', { class: 'none' }, `Couldn't load: ${explain(error)}`));
    return;
  }
  if (ticket !== tickets.list || workspace !== state.workspace) return;  // a newer load is under way
  state.overview = data;
  const plans = data.plans.slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
  const runs = data.runs.slice().sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
  const planItem = (plan) => entry('plan', plan.plan_id, `${plan.operation === 'standard_convert' ? 'Convert run' : 'Full run'}${plan.platform ? ` · ${plan.platform}` : ''}`,
    [badge(plan.status), ` ${short(plan.plan_id, 13)} · ${ago(plan.created_at)}${plan.approved_by ? ` · approved by ${plan.approved_by}` : ''}`]);
  const runItem = (run) => entry('run', run.run_id, `Run ${short(run.run_id, 12)}`,
    [badge(run.status), ` ${run.stage ? `${run.stage} · ` : ''}${ago(run.started_at)}`]);
  const pushItem = (push) => entry('push', push.digest, push.title || 'Converter push', [badge(push.status), ` ${push.branch || ''} · ${ago(push.proposed_at)}`]);
  const conv = data.converter || {};
  const converterItem = entry('converter', data.workspace, conv.error ? 'Converter' : `Converter · ${conv.branch || '?'}`,
    conv.error ? [badge('error'), ` ${conv.error}`]
      : [`${short(conv.head, 8)} · ${conv.not_pushed ?? '?'} not on GitHub`, conv.uncommitted ? ` · ${conv.uncommitted} uncommitted` : '']);
  const sections = [
    ['Converter', [converterItem]],
    ['Waiting for you', [...plans.filter((p) => p.status === 'proposed' || p.status === 'approved').map(planItem),
      ...data.pushes.filter((p) => p.status === 'proposed').map(pushItem)]],
    ['Running', runs.filter((r) => ['claimed', 'running'].includes(r.status)).map(runItem)],
    ['Runs', runs.filter((r) => !['claimed', 'running'].includes(r.status)).slice(0, 25).map(runItem)],
    ['Pushed', data.pushes.filter((p) => p.status !== 'proposed').slice(0, 10).map(pushItem)],
    ['Other plans', plans.filter((p) => !['proposed', 'approved'].includes(p.status)).slice(0, 25).map(planItem)],
  ];
  const nodes = [];
  for (const [title, items] of sections) {
    if (!items.length && title !== 'Waiting for you') continue;
    nodes.push(el('li', { class: 'section-title' }, title));
    nodes.push(...(items.length ? items : [el('li', { class: 'none' },
      'Nothing waits for you here. Plans appear when migration-data proposes a run (data_plan_propose); pushes when converter-developer proposes one (dev_push_propose).')]));
  }
  list.replaceChildren(...nodes);
}

function facts(pairs) {
  return el('dl', { class: 'facts' }, pairs.filter(([, value]) => value !== undefined && value !== null && value !== '')
    .flatMap(([label, value, mono]) => [el('dt', {}, label), el('dd', { class: mono ? 'mono' : '' }, value)]));
}

const block = (title, ...content) => el('div', { class: 'block' }, el('h3', {}, title), ...content);

function table(headers, rows, numeric = []) {
  return el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, headers.map((h) => el('th', {}, h)))),
    el('tbody', {}, rows.map((row) => el('tr', {}, row.map((cell, i) => el('td', { class: numeric.includes(i) ? 'num' : '' }, cell ?? ''))))));
}

async function act(action, body, question) {
  if (!confirm(question)) return null;
  // One decision at a time: no second click while this one runs (a push can take minutes).
  const buttons = [...document.querySelectorAll('#detail-pane .actions button')];
  for (const button of buttons) button.disabled = true;
  toast(action === 'push' ? 'Pushing… this can take a few minutes.' : 'Working…');
  let outcome;
  try {
    outcome = await api(`api/${action}`, { workspace: state.workspace, ...body });
  } catch (error) {
    for (const button of buttons) button.disabled = false;
    toast(explain(error), true);
    await loadList();
    await loadDetail();
    return null;
  }
  return outcome;
}

function checksView(text) {
  let spec = null;
  try { spec = JSON.parse(text); } catch { /* shown as text */ }
  if (!spec || !Array.isArray(spec.checks)) return el('pre', {}, text);
  return table(['Check', 'Expect', 'Source query', 'Intermediate query', 'Note'],
    spec.checks.map((c) => [c.name, c.expect || 'equal', el('code', {}, c.source_sql || ''), el('code', {}, c.intermediate_sql || ''), c.note || '']));
}

function renderPlan(plan) {
  const convert = plan.operation === 'standard_convert';
  const converter = plan.converter || {};
  const inputs = (plan.inputs || []).map((input) => {
    const role = Object.entries(plan.roles || {}).find(([, id]) => id === input.id);
    return [role ? role[0] : input.type, el('span', { class: 'mono' }, (plan.input_paths || {})[input.id] || input.id), input.type,
      String(input.bytes), el('span', { class: 'mono', title: input.sha256 }, short(input.sha256, 16))];
  });
  const parts = [el('h2', { class: 'mono' }, plan.plan_id), facts([
    ['Status', badge(plan.status)],
    ['What', convert ? `Convert run: load the dump, run converters/${plan.platform}, count (no import)` : 'Full synthetic run'],
    ['Converter', `${converter.branch || ''} @ ${short(plan.converter_revision, 12)}${converter.repo ? ` (${converter.repo})` : ''}`],
    ['Proposed', plan.created_at],
    ['Approved by', plan.approved_by],
    ['Discarded', plan.discarded ? `${plan.discarded.discarded_at} by ${plan.discarded.reviewer}` : null],
    ['Run', plan.run_id],
    ['Runtime', plan.discourse_profile],
    ['Charset', plan.source_charset],
    ['Digest', plan.digest, true],
  ])];
  if (plan.status === 'stale') parts.push(el('p', { class: 'note' }, 'Stale: something this plan binds has changed since it was proposed. It can\'t be approved or started; discard it and ask migration-data to propose again.'));
  parts.push(block('Inputs (by content hash)', table(['Role', 'File', 'Type', 'Bytes', 'SHA-256'], inputs, [3])));
  if (convert) {
    const limits = plan.limits || {};
    parts.push(block('Limits', facts([['Database', limits.db ? `${limits.db.cpus} CPUs, ${limits.db.memory_mib} MiB` : ''],
      ['Converter', limits.converter ? `${limits.converter.cpus} CPUs, ${limits.converter.memory_mib} MiB` : '']])));
    const texts = plan.texts || {};
    parts.push(block('Converter settings (the run fills in ${SILO_DB_*})', texts.settings == null ? el('p', { class: 'empty' }, '(not readable, or changed since the plan)') : el('pre', {}, texts.settings)));
    if ((plan.roles || {}).reconciliation) {
      parts.push(block('Reconciliation checks (reported, not enforced)', texts.reconciliation == null ? el('p', { class: 'empty' }, '(not readable, or changed since the plan)') : checksView(texts.reconciliation)));
    }
  }
  parts.push(block('What it does', el('ul', {}, (plan.mutations || []).map((m) => el('li', {}, m)))),
    block('Not included', el('p', {}, (plan.not_included || []).join(', '))));
  const actions = [];
  const unseen = convert && ((plan.texts || {}).settings == null || ((plan.roles || {}).reconciliation && (plan.texts || {}).reconciliation == null));
  if (plan.status === 'proposed') {
    const question = unseen
      ? `Approve plan ${plan.plan_id}?\nDigest ${plan.digest}\nThe settings or checks could NOT be shown here: you approve them by hash only.`
      : `Approve plan ${plan.plan_id}?\nDigest ${plan.digest}\nIt runs exactly what this page shows.`;
    actions.push(el('button', { type: 'button', class: 'primary', onclick: async () => {
      if (await act('approve', { plan_id: plan.plan_id, digest: plan.digest }, question)) {
        toast('Approved. Start it when you are ready.');
        await refreshAll();
      }
    } }, 'Approve'));
  }
  if (plan.status === 'approved') {
    actions.push(el('button', { type: 'button', class: 'primary', onclick: async () => {
      const outcome = await act('start', { plan_id: plan.plan_id }, `Start the approved plan ${plan.plan_id} now? It runs in the background on the server.`);
      if (outcome) {
        toast(`Started ${outcome.run_id}.`);
        state.selected = { kind: 'run', id: outcome.run_id };
        writeHash();
        await refreshAll();
      }
    } }, 'Start run'));
  }
  if (['proposed', 'approved', 'stale'].includes(plan.status)) {
    actions.push(el('button', { type: 'button', class: 'danger', onclick: async () => {
      if (await act('discard', { plan_id: plan.plan_id }, `Discard plan ${plan.plan_id}? It can never be approved or run.`)) { toast('Discarded.'); await refreshAll(); }
    } }, 'Discard'));
  }
  if (actions.length) parts.push(el('div', { class: 'actions' }, actions));
  return parts;
}

function renderRun(run) {
  const results = run.results || {};
  const parts = [el('h2', { class: 'mono' }, run.run_id), facts([
    ['Status', badge(run.status)], ['Stage', run.stage], ['Plan', run.plan_id, true],
    ['Started', run.started_at], ['Finished', run.finished_at],
    ['Failure', run.failure ? `${run.failure.code} (stage ${run.failure.stage})` : null],
  ])];
  parts.push(el('div', { class: 'stages' }, Object.entries(run.stages || {}).map(([name, status]) => el('span', {}, `${name} `, badge(status)))));
  if (run.failure && run.failure.recovery) parts.push(el('p', { class: 'note' }, run.failure.recovery));
  if (run.recovery) parts.push(el('p', { class: 'note' }, run.recovery));
  if (results.reconciliation_checks !== undefined) {
    parts.push(block(`Reconciliation: ${results.reconciliation_checks} checks, ${results.reconciliation_matched} matched, ${results.reconciliation_differs} differ, ${results.reconciliation_errors} errors`,
      Array.isArray(run.reconciliation) && run.reconciliation.length
        ? table(['Check', 'Source', 'Intermediate', 'Difference', 'Status', 'Note'],
          run.reconciliation.map((r) => [r.name, r.source, r.intermediate, r.difference, badge(r.status), r.error || r.note || '']), [1, 2, 3])
        : el('p', { class: 'empty' }, 'No checks in this run.')));
  }
  if (run.artifacts && run.artifacts.intermediate) {
    parts.push(block('Intermediate database', facts([['Bytes', String(run.artifacts.intermediate.bytes)], ['SHA-256', run.artifacts.intermediate.sha256, true]])));
  }
  if (run.conversion_summary) parts.push(block('Converter summary', el('pre', {}, run.conversion_summary)));
  const actions = [];
  if (['abandoned', 'not_started'].includes(run.status)) {
    actions.push(el('button', { type: 'button', onclick: async () => {
      if (await act('recover', { run_id: run.run_id }, `Mark ${run.run_id} as interrupted? Do this only if the run's process is gone (for example after a restart). Then reset it.`)) { toast('Marked interrupted.'); await refreshAll(); }
    } }, 'Recover'));
  }
  if (RUN_DONE.has(run.status)) {
    actions.push(el('button', { type: 'button', class: 'danger', onclick: async () => {
      if (await act('reset', { run_id: run.run_id }, `Reset ${run.run_id}? Its containers, networks, volumes and leftovers are removed. Evidence, plans and backups stay.`)) { toast('Reset.'); await refreshAll(); }
    } }, 'Reset'));
  }
  if (actions.length) parts.push(el('div', { class: 'actions' }, actions));
  return parts;
}

function renderConverter(log) {
  const parts = [el('h2', {}, `Converter checkout · ${log.workspace}`), facts([
    ['Branch', log.branch, true], ['Head', log.head, true],
    ['Not on GitHub', `${log.not_pushed} commit(s)`],
    ['Ahead of main', log.ahead_of_main == null ? null : `${log.ahead_of_main} commit(s)`],
    ['Uncommitted', log.uncommitted ? `${log.uncommitted} change(s): converter-developer is working, or files were left behind` : 'none'],
  ])];
  parts.push(el('p', { class: 'note' }, 'Commits reach GitHub only when converter-developer proposes a push (dev_push_propose) and you approve it here. Runs use the committed head of this checkout, not GitHub.'));
  parts.push(block('Recent commits', table(['Commit', 'Subject', 'Author', 'Date', 'GitHub'],
    (log.commits || []).map((c) => [el('span', { class: 'mono', title: c.sha }, short(c.sha, 10)), c.subject, c.author, (c.date || '').slice(0, 16).replace('T', ' '),
      badge(c.pushed ? 'pushed' : 'not_pushed')]))));
  if ((log.branches || []).length) {
    parts.push(block('Migration branches', table(['Branch', 'Head', 'Not on GitHub', 'On GitHub'],
      log.branches.map((b) => [el('span', { class: `mono${b.name === log.branch ? ' current' : ''}` }, b.name + (b.name === log.branch ? ' (current)' : '')),
        el('span', { class: 'mono' }, short(b.head, 10)), b.not_pushed == null ? '' : String(b.not_pushed), b.on_github ? 'yes' : 'no']), [2])));
  }
  return parts;
}

function renderPush(push) {
  const pull = push.pull_request;
  const parts = [el('h2', {}, push.title || 'Converter push'), facts([
    ['Status', badge(push.status)], ['Repository', push.repository], ['Branch', `${push.branch} → ${push.base}`],
    ['Head', push.head, true], ['Proposed', push.proposed_at], ['Pushed', push.pushed_at],
    ['Pull request', pull && pull.url ? el('a', { href: pull.url, target: '_blank', rel: 'noopener noreferrer' }, `#${pull.number} (draft)`) : null],
    ['Digest', push.digest, true],
  ])];
  parts.push(block('PR description', el('pre', {}, push.body || '(empty)')));
  parts.push(block(`Commits (${(push.commits || []).length})`, el('ul', {}, (push.commits || []).map((c) => el('li', { class: 'mono' }, typeof c === 'string' ? c : JSON.stringify(c))))));
  parts.push(block(`Files (${push.files_total ?? (push.files || []).length})`, el('pre', {}, (push.files || []).join('\n'))));
  if (push.stat) parts.push(block('Diff stat', el('pre', {}, push.stat)));
  if (push.status === 'proposed' || (push.status === 'pushed' && !(pull && pull.url))) {
    parts.push(el('div', { class: 'actions' }, el('button', { type: 'button', class: 'primary', onclick: async () => {
      const owner = String(push.repository || '').split('/')[0];
      const outcome = await act('push', { digest: push.digest }, `Push ${push.branch} (${short(push.head, 12)}) to ${push.repository} and open a draft PR, with the server's GitHub token for ${owner}?`);
      if (outcome) { toast(outcome.pull_request && outcome.pull_request.url ? `Pushed; draft PR #${outcome.pull_request.number}.` : 'Pushed.'); await refreshAll(); }
    } }, push.status === 'proposed' ? 'Push and open draft PR' : 'Open draft PR')));
  }
  return parts;
}

async function loadDetail() {
  clearTimeout(pollTimer);
  const pane = $('detail-pane');
  const ticket = ++tickets.detail;
  if (!state.selected || !state.workspace) { pane.replaceChildren(el('p', { class: 'empty' }, 'Select a plan, run or push.')); return; }
  const { kind, id } = state.selected;
  const workspace = state.workspace;
  let data;
  try {
    data = await api(`api/${kind}?${new URLSearchParams({ workspace, id })}`);
  } catch (error) {
    if (ticket !== tickets.detail) return;
    pane.replaceChildren(el('p', { class: 'empty' }, `Couldn't load it: ${explain(error)}`));
    return;
  }
  if (ticket !== tickets.detail || workspace !== state.workspace || !state.selected || state.selected.id !== id) return;  // something newer was opened
  const render = { plan: renderPlan, run: renderRun, push: renderPush, converter: renderConverter }[kind];
  pane.replaceChildren(...render(data).filter(Boolean));
  if (kind === 'run' && ['claimed', 'running'].includes(data.status)) {
    pollTimer = setTimeout(() => { if (!document.hidden) refreshAll(); }, 10000);
  }
}

function open(next) {
  state.selected = next;
  writeHash();
  for (const button of document.querySelectorAll('#items .item')) {
    button.classList.toggle('selected', button.dataset.kind === next.kind && button.dataset.id === next.id);
  }
  loadDetail();
}

async function refreshAll() {
  await loadList();
  await loadDetail();
}

$('workspace').addEventListener('change', (event) => { state.workspace = event.target.value; state.selected = null; state.overview = null; writeHash(); refreshAll(); });
$('refresh').addEventListener('click', () => refreshAll());
window.addEventListener('hashchange', () => { readHash(); refreshAll(); });
readHash();
await chooseWorkspace();
writeHash();
refreshAll();
