// Findings widget page. All text from the server is inserted with textContent, never as HTML.
const STATUS_LABEL = { proposed: 'to review', released: 'released', rejected: 'rejected', superseded: 'replaced', withdrawn: 'withdrawn' };
const ERRORS = {
  STANDARD_BUSY: 'The project is busy (a run or another decision). Try again in a moment.',
  STANDARD_TRANSITION_INVALID: 'This finding was already decided. The list has been refreshed.',
  STANDARD_APPROVAL_MISMATCH: 'The text changed while it was being sent. Nothing was released.',
  STANDARD_TEXT_TOO_LARGE: 'The text is over 256 KiB.',
  STANDARD_ARGUMENTS_INVALID: 'The request was refused (empty or invalid text?).',
  STANDARD_REQUEST_REFUSED: 'The request was refused. Reload the page.',
};
const state = { workspace: '', status: 'proposed', q: '', page: 0, selected: null };
const $ = (id) => document.getElementById(id);

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

// A small Markdown subset rendered as DOM nodes (never as HTML): headings (also ALL-CAPS section
// lines), bullet and numbered lists, pipe tables, fenced code, `code` and **bold**. Links stay text.
// Section lines as migration-data writes them: two or more ALL-CAPS words first ("OPEN QUESTIONS for
// converter work"), or one ALL-CAPS word with an optional note ("UPLOADS (open)").
const CAPS_HEADING = /^(?:[A-Z][A-Z0-9&/'’-]+\s+[A-Z][A-Z0-9&/'’-]+\b(?![a-z]).*|[A-Z][A-Z0-9&/'’-]{3,}(?:\s*\([^)]*\))?:?)$/;
const isCapsHeading = (line) => line.length <= 120 && !line.endsWith('.') && CAPS_HEADING.test(line);

function inline(text) {
  const nodes = [];
  const pattern = /`([^`]+)`|\*\*([^*]+)\*\*/g;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) nodes.push(text.slice(last, match.index));
    nodes.push(match[1] !== undefined ? el('code', {}, match[1]) : el('strong', {}, match[2]));
    last = match.index + match[0].length;
  }
  if (last < text.length) nodes.push(text.slice(last));
  return nodes;
}

function markdown(text) {
  const root = el('div', { class: 'md' });
  const lines = (text || '').replace(/\r\n?/g, '\n').split('\n');
  let list = null;
  let paragraph = null;
  const close = () => { list = null; paragraph = null; };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    if (trimmed.startsWith('```')) {
      close();
      const code = [];
      for (i++; i < lines.length && !lines[i].trim().startsWith('```'); i++) code.push(lines[i]);
      root.append(el('pre', {}, code.join('\n')));
      continue;
    }
    if (!trimmed) { close(); continue; }
    const heading = trimmed.match(/^(#{1,4})\s+(.*)$/);
    if (heading || isCapsHeading(trimmed)) {
      close();
      root.append(el(heading ? `h${Math.min(6, heading[1].length + 2)}` : 'h4', {}, inline(heading ? heading[2] : trimmed)));
      continue;
    }
    if (trimmed.startsWith('|') && i + 1 < lines.length && /^\s*\|?\s*:?-{2,}/.test(lines[i + 1])) {
      close();
      const cells = (row) => row.trim().replace(/^\||\|$/g, '').split('|').map((cell) => cell.trim());
      const table = el('table', {}, el('thead', {}, el('tr', {}, cells(line).map((cell) => el('th', {}, inline(cell))))));
      const body = el('tbody');
      for (i += 2; i < lines.length && lines[i].trim().startsWith('|'); i++) body.append(el('tr', {}, cells(lines[i]).map((cell) => el('td', {}, inline(cell)))));
      i--;
      table.append(body);
      root.append(el('div', { class: 'table' }, table));
      continue;
    }
    const item = trimmed.match(/^([-*]|\d+[.)])\s+(.*)$/);
    if (item) {
      paragraph = null;
      const ordered = /\d/.test(item[1]);
      if (!list || (list.tagName === 'OL') !== ordered) {
        list = el(ordered ? 'ol' : 'ul');
        root.append(list);
      }
      list.append(el('li', {}, inline(item[2])));
      continue;
    }
    if (list && /^\s{2,}/.test(line) && list.lastChild) { list.lastChild.append(' ', ...inline(trimmed)); continue; }
    list = null;
    if (!paragraph) { paragraph = el('p'); root.append(paragraph); } else paragraph.append(el('br'));
    paragraph.append(...inline(trimmed));
  }
  return root;
}

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
  toast.timer = setTimeout(() => { box.className = ''; }, bad ? 9000 : 4000);
}

async function api(path, body) {
  const options = body
    ? { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Silo-Findings': '1' }, body: JSON.stringify(body) }
    : { credentials: 'same-origin', headers: { Accept: 'application/json' } };
  const response = await fetch(path, options);
  let data = {};
  try { data = await response.json(); } catch { /* not JSON */ }
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

function readHash() {
  const params = new URLSearchParams(location.hash.slice(1));
  if (params.get('ws')) state.workspace = params.get('ws');
  if (params.get('status')) state.status = params.get('status');
  state.selected = params.get('id') ? { workspace: params.get('ws') || '', id: params.get('id') } : null;
}

function writeHash() {
  const params = new URLSearchParams();
  if (state.workspace) params.set('ws', state.workspace);
  if (state.status !== 'proposed') params.set('status', state.status);
  if (state.selected) { params.set('ws', state.selected.workspace); params.set('id', state.selected.id); }
  history.replaceState(null, '', `#${params}`);
}

async function loadList() {
  const query = new URLSearchParams({ status: state.status, page: state.page, q: state.q, workspace: state.workspace });
  let data;
  try { data = await api(`api/findings?${query}`); } catch (error) { toast(`Couldn't load findings: ${error.message}`, true); return; }
  const select = $('workspace');
  const known = new Set([...select.options].map((option) => option.value));
  for (const name of data.workspaces) if (!known.has(name)) select.append(el('option', { value: name }, name));
  select.value = state.workspace;
  for (const tab of document.querySelectorAll('[data-status]')) tab.setAttribute('aria-selected', tab.dataset.status === state.status);
  const list = $('items');
  list.replaceChildren();
  if (!data.items.length) list.append(el('li', { class: 'none' }, state.q ? 'Nothing matches.' : 'Nothing here.'));
  for (const item of data.items) {
    const selected = state.selected && state.selected.id === item.id;
    list.append(el('li', {}, el('button', {
      type: 'button', class: selected ? 'item selected' : 'item',
      onclick: () => { state.selected = { workspace: item.workspace, id: item.id }; writeHash(); loadList(); loadDetail(); },
    },
    el('span', { class: 'title' }, item.title || item.id),
    el('span', { class: 'meta' }, `${item.workspace} · ${item.kind} · `, el('span', { class: `badge ${item.status}` }, STATUS_LABEL[item.status]),
      ` · ${ago(item.updated_at)}`, item.supersedes ? ' · correction' : ''))));
  }
  $('pageinfo').textContent = `${data.total} · page ${data.page + 1} of ${data.pages}`;
  $('prev').disabled = data.page === 0;
  $('next').disabled = data.page + 1 >= data.pages;
}

let formatted = localStorage.getItem('silo-findings-plain') !== '1';
const views = new Set();  // text blocks on screen; the toggle re-renders them without touching the editor

function textBlock(label, text) {
  const body = el('div', { class: 'view' });
  const toggle = el('button', { type: 'button', class: 'toggle', onclick: () => {
    formatted = !formatted;
    localStorage.setItem('silo-findings-plain', formatted ? '0' : '1');
    for (const view of views) view();
  } });
  const show = () => {
    body.replaceChildren(text == null ? el('p', { class: 'empty' }, '(none)') : formatted ? markdown(text) : el('pre', {}, text));
    toggle.textContent = formatted ? 'Plain text' : 'Formatted';
  };
  views.add(show);
  show();
  return el('div', { class: 'block' }, el('h3', {}, label, ' ', toggle), body);
}

function editor(label, text) {
  const area = el('textarea', { spellcheck: 'false', rows: 18 });
  area.value = text ?? '';
  const counter = el('span', { class: 'hint' });
  const count = () => { counter.textContent = `${new TextEncoder().encode(area.value).length} bytes`; };
  area.addEventListener('input', count);
  count();
  const preview = el('div', { class: 'view preview', hidden: true });
  const toggle = el('button', { type: 'button', class: 'toggle', onclick: () => {
    const showing = preview.hidden;
    if (showing) preview.replaceChildren(markdown(area.value));
    preview.hidden = !showing;
    area.hidden = showing;
    toggle.textContent = showing ? 'Edit' : 'Preview';
  } }, 'Preview');
  return { area, node: el('div', { class: 'block' }, el('h3', {}, label, ' ', toggle), area, preview, counter) };
}

async function act(action, record, text) {
  const words = {
    release: `Release this exact text (${new TextEncoder().encode(text || '').length} bytes) to the coding agents of ${record.workspace}?`,
    amend: `Release this corrected text for ${record.workspace}? It replaces ${record.id}; the coding agents will see only the new version.`,
    reject: `Reject ${record.id}? Nothing is released.`,
    withdraw: `Withdraw ${record.id}? The coding agents won't be able to read it any more. It doesn't erase what they already read (earlier chats, code they wrote).`,
  };
  if (!confirm(words[action])) return;
  try {
    const outcome = await api(`api/${action}`, { workspace: record.workspace, id: record.id, text });
    toast(action === 'amend' ? `Released the correction as ${outcome.finding_id}.` : `Done: ${outcome.status}.`);
    if (outcome.finding_id && outcome.finding_id !== record.id) state.selected = { workspace: record.workspace, id: outcome.finding_id };
    writeHash();
  } catch (error) {
    toast(ERRORS[error.message] || `Refused: ${error.message}`, true);
  }
  await loadList();
  await loadDetail();
}

async function loadDetail() {
  const pane = $('detail-pane');
  views.clear();
  if (!state.selected) { pane.replaceChildren(el('p', { class: 'empty' }, 'Select a finding.')); return; }
  let record;
  try {
    record = await api(`api/finding?${new URLSearchParams({ workspace: state.selected.workspace, id: state.selected.id })}`);
  } catch (error) {
    pane.replaceChildren(el('p', { class: 'empty' }, `Couldn't load it: ${error.message}`));
    return;
  }
  const facts = el('dl', { class: 'facts' },
    el('dt', {}, 'Project'), el('dd', {}, record.workspace),
    el('dt', {}, 'Kind'), el('dd', {}, record.kind + (record.run_id ? ` (run ${record.run_id})` : '')),
    el('dt', {}, 'Status'), el('dd', {}, el('span', { class: `badge ${record.status}` }, STATUS_LABEL[record.status])),
    el('dt', {}, 'Proposed'), el('dd', {}, record.proposed_at || ''),
    record.decided_at ? [el('dt', {}, 'Decided'), el('dd', {}, `${record.decided_at}${record.reviewer ? ` by ${record.reviewer}` : ''}`)] : null,
    record.sha256 ? [el('dt', {}, 'SHA-256'), el('dd', { class: 'mono' }, record.sha256)] : null);
  const versions = record.versions.length > 1
    ? el('div', { class: 'versions' }, el('h3', {}, 'Versions'), el('ol', {}, record.versions.map((version) => el('li', {},
      el('a', { href: `#ws=${encodeURIComponent(record.workspace)}&id=${version.id}`, class: version.id === record.id ? 'current' : '',
        onclick: (event) => { event.preventDefault(); state.selected = { workspace: record.workspace, id: version.id }; writeHash(); loadDetail(); } },
      version.id), ` · ${STATUS_LABEL[version.status]} · ${ago(version.updated_at)}`))))
    : null;
  const parts = [el('h2', { class: 'mono' }, record.id), facts, versions];
  if (record.status === 'proposed') {
    const edit = editor('Text to release (edit it first: only invented examples, no real names, emails, IPs or messages)', record.proposal);
    parts.push(textBlock('Proposal from migration-data (read-only)', record.proposal), edit.node,
      el('div', { class: 'actions' },
        el('button', { type: 'button', class: 'primary', onclick: () => act('release', record, edit.area.value) }, 'Release'),
        el('button', { type: 'button', class: 'danger', onclick: () => act('reject', record) }, 'Reject')));
  } else if (record.status === 'released') {
    const edit = editor('Corrected text (released as a new version that replaces this one)', record.released);
    edit.node.hidden = true;
    const amendButton = el('button', { type: 'button', class: 'primary', hidden: true, onclick: () => act('amend', record, edit.area.value) }, 'Release correction');
    parts.push(textBlock('Released text (what the coding agents see)', record.released), edit.node,
      el('div', { class: 'actions' },
        el('button', { type: 'button', onclick: (event) => { edit.node.hidden = false; amendButton.hidden = false; event.target.hidden = true; edit.area.focus(); } }, 'Amend…'),
        amendButton,
        el('button', { type: 'button', class: 'danger', onclick: () => act('withdraw', record) }, 'Withdraw')));
  } else {
    if (record.released) parts.push(textBlock('Released text', record.released));
    if (record.proposal) parts.push(textBlock('Proposal from migration-data', record.proposal));
  }
  pane.replaceChildren(...parts.filter(Boolean));
}

for (const tab of document.querySelectorAll('[data-status]')) {
  tab.addEventListener('click', () => { state.status = tab.dataset.status; state.page = 0; writeHash(); loadList(); });
}
$('workspace').addEventListener('change', (event) => { state.workspace = event.target.value; state.page = 0; writeHash(); loadList(); });
let searchTimer;
$('search').addEventListener('input', (event) => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => { state.q = event.target.value; state.page = 0; loadList(); }, 300);
});
$('prev').addEventListener('click', () => { state.page = Math.max(0, state.page - 1); loadList(); });
$('next').addEventListener('click', () => { state.page += 1; loadList(); });
window.addEventListener('hashchange', () => { readHash(); loadList(); loadDetail(); });
readHash();
loadList();
loadDetail();
