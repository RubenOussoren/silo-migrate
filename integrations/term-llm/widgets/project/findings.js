// The Findings tab: what migration-data proposes, and the only way text reaches the coding agents.
// The decisions are those of widgets/findings/server.py, unchanged: the exact text and its checksum are sent.
import { el, safe, ago, toast, api, explain, facts, details, card, back, item } from './ui.js';

const STATUS_LABEL = { proposed: 'to review', released: 'released', rejected: 'rejected', superseded: 'replaced', withdrawn: 'withdrawn' };

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
      release: `Release this exact text (${new TextEncoder().encode(text || '').length} bytes) to the coding agents of ${ctx.project}?`,
      amend: `Release this corrected text for ${ctx.project}? It replaces the current one; the coding agents will see only the new version.`,
      reject: `Reject this finding of ${ctx.project}? Nothing is released.`,
      withdraw: `Withdraw this finding of ${ctx.project}? The coding agents won't be able to read it any more. It doesn't erase what they already read.`,
    };
    if (!confirm(words[action])) return;
    // One decision at a time.
    const buttons = [...document.querySelectorAll('#content .actions button')];
    for (const button of buttons) button.disabled = true;
    try {
      const outcome = await api(`api/findings/${action}`, { workspace: ctx.project, id: record.id, text });
      toast(action === 'amend' ? 'Released the correction.' : `Done: ${outcome.status}.`);
      editing = null;
      board = null;
      if (outcome.finding_id && outcome.finding_id !== record.id) ctx.open('finding', outcome.finding_id); else ctx.refresh();
    } catch (error) {
      for (const button of buttons) button.disabled = false;
      toast(explain(error), true);  // nothing changed: the page, edits included, stays as it is
    }
  }

  let board = null;  // grouped findings with their tracks
  const find = (id) => board && Object.values(board).flat().find((entry) => entry.id === id);

  // Released, fixed, run, checked: where a finding is, in four dots.
  function track(entry) {
    const steps = [
      ['done', entry.status === 'proposed' ? 'Proposed' : `Released ${ago(entry.decided_at)}`],
      entry.marked ? ['done', 'Marked done'] : entry.fix && entry.fix.head ? ['done', `Fix ${entry.fix.head}`] : entry.fix ? ['now', 'Fix proposed'] : ['now', 'Waiting for a fix'],
      entry.marked ? null : entry.ran ? ['done', 'Run'] : entry.fix && entry.fix.head ? ['now', 'Not run yet'] : ['', 'Run'],
      entry.marked ? null : entry.checked_in ? ['done', `Checked in pass ${entry.checked_in}`] : ['', 'Checked'],
    ].filter(Boolean);
    if (entry.status === 'proposed') steps.splice(1);
    return el('div', { class: 'track' }, steps.map(([state, label]) => el('span', { class: `tstep ${state}` }, el('i'), label)));
  }

  const origin = (entry) => (entry.origin ? `Found in pass ${entry.origin.pass}'s ${entry.origin.step === 'import' ? 'import' : 'convert run'}` : entry.kind === 'schema' ? 'Schema' : entry.kind || 'Finding');
  const nextStep = (entry) => (entry.marked ? `Marked done by ${safe(entry.marked.by)}` : entry.checked_in ? `Checked in pass ${entry.checked_in}`
    : entry.fix && entry.fix.head ? (entry.ran ? 'A pass ran on the fix but its checks didn\'t all match' : 'Next: start a new pass to check the fix')
      : entry.fix ? 'Next: approve the converter update in Runs' : 'Next: converter-developer works from it, or mark it done if no change is needed');

  function boardCard(entry, open) {
    const head = el('button', { type: 'button', class: 'pass-head', onclick: () => ctx.open('finding', entry.id) },
      el('div', {}, el('span', { class: 'name' }, safe(entry.title)), el('small', {}, entry.status === 'proposed' ? `${origin(entry)} · proposed ${ago(entry.proposed_at)}` : origin(entry))),
      entry.status === 'proposed' ? el('span', { class: 'btn' }, 'Review') : el('span', { class: `pill ${entry.checked_in || entry.marked ? 'ok' : 'now'}` },
        entry.checked_in ? 'checks match' : entry.marked ? 'done' : entry.fix && entry.fix.head ? 'fix pushed' : entry.fix ? 'fix proposed' : 'needs a fix'));
    return el('div', { class: `pass ${open ? '' : 'closed'}` }, head, open ? el('div', { class: 'pass-body' }, track(entry), el('p', { class: 'changed' }, nextStep(entry))) : null);
  }

  async function list() {
    const mine = ++ticket;
    if (!board) ctx.mount([el('p', { class: 'quiet' }, 'Loading…')]);
    let data;
    try { data = await api(`api/findings/board?${new URLSearchParams({ workspace: ctx.project })}`); } catch (error) {
      if (mine === ticket) ctx.mount([el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    board = data;
    const nodes = [];
    if (data.review.length) nodes.push(el('h2', {}, 'TO REVIEW'), ...data.review.map((entry) => boardCard(entry, false)));
    if (data.progress.length) nodes.push(el('h2', {}, 'IN PROGRESS'), ...data.progress.map((entry) => boardCard(entry, true)));
    if (data.done.length) nodes.push(el('h2', {}, 'DONE'), ...data.done.map((entry) => boardCard(entry, false)));
    if (data.other.length) {
      nodes.push(el('details', { class: 'history' }, el('summary', {}, `Rejected, withdrawn and replaced (${data.other.length})`),
        ...data.other.map((entry) => item(safe(entry.title), `${STATUS_LABEL[entry.status]} · ${ago(entry.decided_at || entry.proposed_at)}`, () => ctx.open('finding', entry.id)))));
    }
    if (!nodes.length) nodes.push(el('p', { class: 'quiet' }, 'No findings yet. migration-data proposes them when converter work needs to know something about the data.'));
    ctx.mount(nodes);
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
    if (!find(record.id)) { try { board = await api(`api/findings/board?${new URLSearchParams({ workspace: ctx.project })}`); } catch { /* no track then */ } }
    if (mine !== ticket) return;
    const entry = find(record.id);
    const story = entry && record.status !== 'proposed' ? [track(entry), el('p', { class: 'changed' }, `${origin(entry)}. ${nextStep(entry)}.`)] : [];
    const mark = (undo) => el('button', { type: 'button', class: 'btn q', onclick: async () => {
      if (!confirm(undo ? `Reopen this finding of ${ctx.project}? It goes back to In progress.` : `Mark this finding of ${ctx.project} done? Use this when it needed no converter change, or was fixed before fixes named their findings.`)) return;
      try { await api('api/findings/done', { workspace: ctx.project, id: undo && entry.marked_id ? entry.marked_id : record.id, undo }); toast(undo ? 'Reopened.' : 'Marked done.'); board = null; ctx.refresh(); } catch (error) { toast(explain(error), true); }
    } }, undo ? 'Reopen' : 'Mark done');
    const more = details(facts([['Finding', record.id, true], ['Kind', record.kind + (record.run_id ? ` (run ${record.run_id})` : '')], ['Proposed', record.proposed_at],
      ['Decided', record.decided_at ? `${record.decided_at}${record.reviewer ? ` by ${record.reviewer}` : ''}` : null], ['SHA-256', record.sha256, true]]),
    record.versions.length > 1 ? el('ol', {}, record.versions.map((version) => el('li', {}, el('button', { type: 'button', class: version.id === record.id ? 'link current' : 'link', onclick: () => {
      if (!unsaved() || confirm('Discard your edits to this finding?')) { editing = null; ctx.open('finding', version.id); }
    } }, version.id), ` · ${STATUS_LABEL[version.status]} · ${ago(version.updated_at)}`))) : null);
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
      parts = [card(entry && (entry.checked_in || entry.marked) ? 'FINDING · DONE' : 'FINDING · IN PROGRESS', safe((entry && entry.title) || 'Released finding'), ...story,
        el('div', { class: 'block' }, el('h3', {}, 'Released text (what the coding agents see) ', toggle), view), edit.node,
        el('div', { class: 'actions' }, entry && entry.marked ? mark(true) : entry && !entry.checked_in ? mark(false) : null, el('button', { type: 'button', class: 'btn q', onclick: (event) => {
          edit.node.hidden = false; amend.hidden = false; event.currentTarget.hidden = true; editing = { area: edit.area, original: edit.area.value }; edit.area.focus();
        } }, 'Amend…'), amend, el('button', { type: 'button', class: 'btn q', onclick: () => act('withdraw', record) }, 'Withdraw')), more)];
    } else {
      const shown = record.released != null ? textView(record.released) : textView(record.proposal);
      parts = [card(STATUS_LABEL[record.status].toUpperCase(), record.released != null ? 'Released text' : 'Proposal from migration-data', el('div', { class: 'block' }, el('h3', {}, shown[1]), shown[0]), more)];
    }
    ctx.mount([back('Findings', leave), ...parts]);
  }

  return { show: () => (ctx.selected ? detail(ctx.selected.id) : list()), unsaved, discard: () => { editing = null; } };
}
