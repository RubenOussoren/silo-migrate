// The Findings tab: what migration-data proposes, and the only way text reaches the coding agents.
// The decisions are the Findings widget's, unchanged: the exact text and its checksum are sent.
import { el, safe, ago, toast, api, explain, facts, details, card, back, item } from './ui.js';

const STATUS_LABEL = { proposed: 'to review', released: 'released', rejected: 'rejected', superseded: 'replaced', withdrawn: 'withdrawn' };
const FILTERS = [['proposed', 'To review'], ['released', 'Released'], ['history', 'Everything else']];

// A small Markdown subset rendered as DOM nodes (never as HTML): headings (also ALL-CAPS section
// lines), bullet and numbered lists, pipe tables, fenced code, `code` and **bold**. Links stay text.
const CAPS_HEADING = /^(?:[A-Z][A-Z0-9&/'’-]+\s+[A-Z][A-Z0-9&/'’-]+\b(?![a-z]).*|[A-Z][A-Z0-9&/'’-]{3,}(?:\s*\([^)]*\))?:?)$/;
const FENCE = /^```[\w+-]*$/;
const TABLE_RULE = /^\s*\|?(\s*:?-{2,}:?\s*\|)*\s*:?-{2,}:?\s*\|?\s*$/;
const isCapsHeading = (line) => line.length <= 120 && !line.endsWith('.') && CAPS_HEADING.test(line);

function inline(text) {
  const nodes = [];
  const pattern = /`([^`]+)`|\*\*([^*]+)\*\*/g;
  let last = 0;
  for (const match of text.matchAll(pattern)) {
    if (match.index > last) nodes.push(safe(text.slice(last, match.index)));
    nodes.push(match[1] !== undefined ? el('code', {}, safe(match[1])) : el('strong', {}, safe(match[2])));
    last = match.index + match[0].length;
  }
  if (last < text.length) nodes.push(safe(text.slice(last)));
  return nodes;
}

export function markdown(text) {
  const root = el('div', { class: 'md' });
  const lines = (text || '').replace(/\r\n?/g, '\n').split('\n');
  let list = null;
  let paragraph = null;
  const close = () => { list = null; paragraph = null; };
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    const trimmed = line.trim();
    // Only a bare fence opens or closes a block; any other text on a fence line stays visible.
    if (FENCE.test(trimmed)) {
      close();
      const code = [];
      for (i++; i < lines.length && lines[i].trim() !== '```'; i++) code.push(lines[i]);
      root.append(el('pre', {}, safe(code.join('\n'))));
      continue;
    }
    if (!trimmed) { close(); continue; }
    const heading = trimmed.match(/^(#{1,4})\s+(.*)$/);
    if (heading || isCapsHeading(trimmed)) {
      close();
      root.append(el(heading ? `h${Math.min(6, heading[1].length + 2)}` : 'h4', {}, inline(heading ? heading[2] : trimmed)));
      continue;
    }
    if (trimmed.startsWith('|') && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1])) {
      close();
      const cells = (row) => row.trim().replace(/^\||\|$/g, '').split('|').map((cell) => cell.trim());
      const table = el('table', {}, el('thead', {}, el('tr', {}, cells(line).map((cell) => el('th', {}, inline(cell))))));
      const body = el('tbody');
      for (i += 2; i < lines.length && lines[i].trim().startsWith('|'); i++) body.append(el('tr', {}, cells(lines[i]).map((cell) => el('td', {}, inline(cell)))));
      i--;
      table.append(body);
      root.append(el('div', { class: 'grid-wrap' }, table));
      continue;
    }
    const entry = trimmed.match(/^([-*]|\d+[.)])\s+(.*)$/);
    if (entry) {
      paragraph = null;
      const ordered = /\d/.test(entry[1]);
      if (!list || (list.tagName === 'OL') !== ordered) {
        list = el(ordered ? 'ol' : 'ul');
        root.append(list);
      }
      list.append(el('li', {}, inline(entry[2])));
      continue;
    }
    if (list && /^\s{2,}/.test(line) && list.lastChild) { list.lastChild.append(' ', ...inline(trimmed)); continue; }
    list = null;
    if (!paragraph) { paragraph = el('p'); root.append(paragraph); } else paragraph.append(el('br'));
    paragraph.append(...inline(trimmed));
  }
  return root;
}

export function findingsView(ctx) {
  // ctx: { project, open(kind, id), close(), refresh(), selected, mount(nodes), state: { filter, q } }
  let ticket = 0;
  let editing = null;  // the open editor and the text it started with
  const unsaved = () => editing && editing.area.value !== editing.original;
  window.addEventListener('beforeunload', (event) => { if (unsaved()) event.preventDefault(); });

  function textView(text) {
    let formatted = true;
    const body = el('div', { class: 'view' });
    const toggle = el('button', { type: 'button', class: 'link', onclick: () => { formatted = !formatted; show(); } });
    const show = () => {
      body.replaceChildren(text == null ? el('p', { class: 'quiet' }, '(none)') : formatted ? markdown(text) : el('pre', {}, safe(text)));
      toggle.textContent = formatted ? 'Plain text' : 'Formatted';
    };
    show();
    return [body, toggle];
  }

  function editor(text) {
    const area = el('textarea', { spellcheck: 'false', rows: 16, 'aria-label': 'Text to release' });
    area.value = text ?? '';
    const counter = el('span', { class: 'hint' });
    const count = () => { counter.textContent = `${new TextEncoder().encode(area.value).length} bytes`; };
    area.addEventListener('input', count);
    count();
    editing = { area, original: area.value };
    return { area, node: el('div', { class: 'editor' }, area, counter) };
  }

  async function act(action, record, text) {
    const words = {
      release: `Release this exact text (${new TextEncoder().encode(text || '').length} bytes) to the coding agents?`,
      amend: 'Release this corrected text? It replaces the current one; the coding agents will see only the new version.',
      reject: 'Reject this finding? Nothing is released.',
      withdraw: 'Withdraw this finding? The coding agents won\'t be able to read it any more. It doesn\'t erase what they already read.',
    };
    if (!confirm(words[action])) return;
    try {
      const outcome = await api(`api/findings/${action}`, { workspace: ctx.project, id: record.id, text });
      toast(action === 'amend' ? 'Released the correction.' : `Done: ${outcome.status}.`);
      editing = null;
      if (outcome.finding_id && outcome.finding_id !== record.id) ctx.open('finding', outcome.finding_id); else ctx.refresh();
    } catch (error) {
      toast(explain(error), true);  // nothing changed: the page, edits included, stays as it is
    }
  }

  async function list() {
    const mine = ++ticket;
    editing = null;
    const filter = ctx.state.filter || 'proposed';
    const chips = el('div', { class: 'chips' }, FILTERS.map(([id, label]) => el('button', { type: 'button', class: id === filter ? 'chip on' : 'chip', onclick: () => { ctx.state.filter = id; list(); } }, label)));
    ctx.mount([chips, el('p', { class: 'quiet' }, 'Loading…')]);
    let data;
    try { data = await api(`api/findings/list?${new URLSearchParams({ workspace: ctx.project, status: filter, q: ctx.state.q || '' })}`); } catch (error) {
      if (mine === ticket) ctx.mount([chips, el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    const items = data.items.map((record) => item(safe(record.title || record.id), `${record.kind} · ${STATUS_LABEL[record.status]} · ${ago(record.updated_at)}${record.supersedes ? ' · correction' : ''}`,
      () => ctx.open('finding', record.id)));
    const empty = filter === 'proposed' ? 'Nothing to review. migration-data proposes findings when converter work needs to know something.' : 'Nothing here.';
    ctx.mount([chips, ...(items.length ? items : [el('p', { class: 'quiet' }, empty)]), data.total > items.length ? el('p', { class: 'hint' }, `Showing the newest ${items.length} of ${data.total}.`) : null]);
  }

  async function detail(id) {
    const mine = ++ticket;
    const leave = () => { if (!unsaved() || confirm('Discard your edits to this finding?')) { editing = null; ctx.close(); } };
    ctx.mount([back('Findings', leave), el('p', { class: 'quiet' }, 'Loading…')]);
    let record;
    try { record = await api(`api/findings/finding?${new URLSearchParams({ workspace: ctx.project, id })}`); } catch (error) {
      if (mine === ticket) ctx.mount([back('Findings', leave), el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    const more = details(facts([['Finding', record.id, true], ['Kind', record.kind + (record.run_id ? ` (run ${record.run_id})` : '')], ['Proposed', record.proposed_at],
      ['Decided', record.decided_at ? `${record.decided_at}${record.reviewer ? ` by ${record.reviewer}` : ''}` : null], ['SHA-256', record.sha256, true]]),
    record.versions.length > 1 ? el('ol', {}, record.versions.map((version) => el('li', {}, el('button', { type: 'button', class: version.id === record.id ? 'link current' : 'link', onclick: () => ctx.open('finding', version.id) }, version.id), ` · ${STATUS_LABEL[version.status]} · ${ago(version.updated_at)}`))) : null);
    let parts;
    if (record.status === 'proposed') {
      const [view, toggle] = textView(record.proposal);
      const edit = editor(record.proposal);
      parts = [card('FOR YOU TO REVIEW', 'What the coding agents would see',
        el('p', { class: 'note' }, 'Nothing reaches the coding agents until you release it. Edit it first: invented examples only, no real names, emails, IPs or messages.'),
        el('div', { class: 'block' }, el('h3', {}, 'Proposal from migration-data ', toggle), view),
        el('div', { class: 'block' }, el('h3', {}, 'Text to release'), edit.node),
        el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: () => act('release', record, edit.area.value) }, 'Release'),
          el('button', { type: 'button', class: 'btn q', onclick: () => act('reject', record) }, 'Reject')), more)];
    } else if (record.status === 'released') {
      const [view, toggle] = textView(record.released);
      const edit = editor(record.released);
      edit.node.hidden = true;
      editing = null;
      const amend = el('button', { type: 'button', class: 'btn', hidden: true, onclick: () => act('amend', record, edit.area.value) }, 'Release correction');
      parts = [card('RELEASED', 'What the coding agents see', el('div', { class: 'block' }, el('h3', {}, 'Released text ', toggle), view), edit.node,
        el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn q', onclick: (event) => {
          edit.node.hidden = false; amend.hidden = false; event.currentTarget.hidden = true; editing = { area: edit.area, original: edit.area.value }; edit.area.focus();
        } }, 'Amend…'), amend, el('button', { type: 'button', class: 'btn q', onclick: () => act('withdraw', record) }, 'Withdraw')), more)];
    } else {
      const shown = record.released != null ? textView(record.released) : textView(record.proposal);
      parts = [card(STATUS_LABEL[record.status].toUpperCase(), record.released != null ? 'Released text' : 'Proposal from migration-data', el('div', { class: 'block' }, el('h3', {}, shown[1]), shown[0]), more)];
    }
    ctx.mount([back('Findings', leave), ...parts]);
  }

  return { show: () => (ctx.selected ? detail(ctx.selected.id) : list()), unsaved };
}
