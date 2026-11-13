// The Findings tab: what migration-data proposes, and the only way text reaches the coding agents.
// The decisions are those of widgets/findings/server.py: the exact text and its checksum are sent, and a
// release or a rejection also names the proposal this page showed (migration-data can revise one until then).
import { el, safe, ago, toast, api, lists, explain, facts, details, card, back, item } from './ui.js';

const STATUS_LABEL = { proposed: 'to review', released: 'released', rejected: 'rejected', superseded: 'replaced', withdrawn: 'withdrawn' };
// Refusals only a decision on a proposal gets; ui.js explains the rest.
const REFUSED = {
  STANDARD_PROPOSAL_CHANGED: 'migration-data revised this proposal after this page loaded it. Nothing was released or rejected.',
  STANDARD_PROPOSAL_TAMPERED: 'The stored proposal no longer matches its record. Nothing was released or rejected. Ask your node admin to investigate.',
};

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

  async function act(action, record, text, onRevised) {
    const words = {
      release: `Release this exact text (${new TextEncoder().encode(text || '').length} bytes) to the coding agents of ${ctx.project}?`,
      amend: `Release this corrected text for ${ctx.project}? It replaces the current one; the coding agents will see only the new version.`,
      reject: `Reject this finding of ${ctx.project}? Nothing is released.`,
      withdraw: `Withdraw this finding of ${ctx.project}? The coding agents won't be able to read it any more. It doesn't erase what they already read.`,
    };
    if (!confirm(words[action])) return;
    const project = ctx.project;
    const mine = ++ticket;  // an older list refresh must not replace the disabled action controls
    // One decision at a time. Only what was enabled: a refusal re-enables these, never a control that was off already.
    const buttons = [...document.querySelectorAll('#content .actions button')].filter((button) => !button.disabled);
    for (const button of buttons) button.disabled = true;
    try {
      // The proposal this page showed: the server refuses if it has been revised (or decided) since.
      const viewed = action === 'release' || action === 'reject' ? { proposal_sha256: record.proposal_sha256 } : {};
      const outcome = await api(`api/findings/${action}`, { workspace: project, id: record.id, text, ...viewed });
      if (project !== ctx.project || mine !== ticket) return;
      toast(action === 'amend' ? 'Released the correction.' : `Done: ${outcome.status}.`);
      editing = null;
      board = null;
      if (outcome.finding_id && outcome.finding_id !== record.id) ctx.open('finding', outcome.finding_id); else ctx.refresh();
    } catch (error) {
      if (project !== ctx.project || mine !== ticket) return;
      for (const button of buttons) button.disabled = false;
      const code = String(error.message).split(':')[0];
      toast(REFUSED[code] || explain(error), true);  // nothing changed: the page, edits included, stays as it is
      if (code === 'STANDARD_PROPOSAL_CHANGED' && onRevised) onRevised();
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

  const listPath = () => `api/boards?${new URLSearchParams({ workspace: ctx.project })}`;

  async function list() {
    const mine = ++ticket;
    const path = listPath();
    board = lists.peek(path)?.findings || null;
    if (board) paintList(board, 'Refreshing…');
    else ctx.mount([el('p', { class: 'quiet', role: 'status' }, 'Loading findings…')]);
    try {
      const data = (await lists.load(path)).findings;
      if (mine !== ticket) return;
      board = data;
      paintList(data);
    } catch (error) {
      if (mine !== ticket) return;
      if (board) paintList(board, `Couldn't refresh: ${explain(error)} Showing the last loaded list.`);
      else ctx.mount([el('p', { class: 'quiet' }, explain(error))]);
    }
  }

  function paintList(data, status = '') {
    const nodes = [];
    if (data.review.length) nodes.push(el('h2', {}, 'TO REVIEW'), ...data.review.map((entry) => boardCard(entry, false)));
    if (data.progress.length) nodes.push(el('h2', {}, 'IN PROGRESS'), ...data.progress.map((entry) => boardCard(entry, true)));
    if (data.done.length) nodes.push(el('h2', {}, 'DONE'), ...data.done.map((entry) => boardCard(entry, false)));
    if (data.other.length) {
      nodes.push(el('details', { class: 'history' }, el('summary', {}, `Rejected, withdrawn and replaced (${data.other.length})`),
        ...data.other.map((entry) => item(safe(entry.title), `${STATUS_LABEL[entry.status]} · ${ago(entry.decided_at || entry.proposed_at)}`, () => ctx.open('finding', entry.id)))));
    }
    if (!nodes.length) nodes.push(el('p', { class: 'quiet' }, 'No findings yet. migration-data proposes them when converter work needs to know something about the data.'));
    if (status) nodes.push(el('p', { class: 'hint footer', role: 'status' }, status));
    ctx.mount(nodes);
  }

  // keepEdits: reading a revised proposal after a refused decision. The page, and the editor on it, stays
  // until the revision has arrived; the engineer's own text then goes into the new editor.
  async function detail(id, keepEdits = false) {
    const mine = ++ticket;
    const leave = () => { if (!unsaved() || confirm('Discard your edits to this finding?')) { editing = null; ctx.close(); } };
    if (!keepEdits) ctx.mount([back('Findings', leave), el('p', { class: 'quiet' }, 'Loading…')]);
    let record;
    try { record = await api(`api/findings/finding?${new URLSearchParams({ workspace: ctx.project, id })}`); } catch (error) {
      if (mine !== ticket) return;
      if (keepEdits) toast(explain(error), true); else ctx.mount([back('Findings', leave), el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    if (keepEdits && record.status !== 'proposed' && unsaved()) {
      toast('This finding was decided in the meantime. Your text is still here; go back to Findings to see the decision.', true);
      return;
    }
    board = lists.peek(listPath())?.findings || null;
    if (!find(record.id)) {
      try {
        const data = (await lists.load(listPath())).findings;
        if (mine !== ticket) return;
        board = data;
      } catch { /* no track then */ }
    }
    if (mine !== ticket) return;
    const entry = find(record.id);
    const story = entry && record.status !== 'proposed' ? [track(entry), el('p', { class: 'changed' }, `${origin(entry)}. ${nextStep(entry)}.`)] : [];
    const mark = (undo) => el('button', { type: 'button', class: 'btn q', onclick: async () => {
      if (!confirm(undo ? `Reopen this finding of ${ctx.project}? It goes back to In progress.` : `Mark this finding of ${ctx.project} done? Use this when it needed no converter change, or was fixed before fixes named their findings.`)) return;
      try { await api('api/findings/done', { workspace: ctx.project, id: undo && entry.marked_id ? entry.marked_id : record.id, undo }); if (mine !== ticket) return; toast(undo ? 'Reopened.' : 'Marked done.'); board = null; ctx.refresh(); } catch (error) { toast(explain(error), true); }
    } }, undo ? 'Reopen' : 'Mark done');
    const more = details(facts([['Finding', record.id, true], ['Kind', record.kind + (record.run_id ? ` (run ${record.run_id})` : '')], ['Proposed', record.proposed_at],
      ['Proposal revision', record.proposal_revision > 1 ? `${record.proposal_revision}${record.proposal_revised_at ? `, revised ${record.proposal_revised_at}` : ''}` : null],
      ['Decided', record.decided_at ? `${record.decided_at}${record.reviewer ? ` by ${record.reviewer}` : ''}` : null], ['SHA-256', record.sha256, true]]),
    record.versions.length > 1 ? el('ol', {}, record.versions.map((version) => el('li', {}, el('button', { type: 'button', class: version.id === record.id ? 'link current' : 'link', onclick: () => {
      if (!unsaved() || confirm('Discard your edits to this finding?')) { editing = null; ctx.open('finding', version.id); }
    } }, version.id), ` · ${STATUS_LABEL[version.status]} · ${ago(version.updated_at)}`))) : null);
    let parts;
    if (record.status === 'proposed') {
      const kept = keepEdits && unsaved() ? editing.area.value : null;  // text written against the proposal shown before
      const [view, toggle] = textView(record.proposal);
      const edit = editor(record.proposal);
      if (kept !== null) { edit.area.value = kept; edit.area.dispatchEvent(new Event('input')); }
      const revised = el('div', { class: 'block', role: 'alert', hidden: true });
      const onRevised = () => {
        revised.replaceChildren(el('p', { class: 'note' }, 'migration-data revised this proposal after this page loaded it, so nothing was decided. Load the revision to read it'
          + (unsaved() ? '; your text to release is kept.' : '.')),
        el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn q', onclick: () => detail(record.id, true) }, 'Load the revised proposal')));
        revised.hidden = false;
      };
      parts = [card('FOR YOU TO REVIEW', 'What the coding agents would see',
        el('p', { class: 'note' }, 'Nothing reaches the coding agents until you release it. Edit it first: invented examples only, no real names, emails, IPs or messages.'),
        record.proposal_sha256 ? null : el('p', { class: 'note', role: 'alert' }, 'The stored proposal doesn\'t match its record, so it can\'t be released or rejected. Ask your node admin to investigate.'),
        kept !== null ? el('p', { class: 'note', role: 'status' }, 'The proposal below is the revision. Your text to release was written before it and is kept as you left it: compare the two before you release.') : null,
        el('div', { class: 'block' }, el('h3', {}, `Proposal from migration-data${record.proposal_revision > 1 ? ` (revision ${record.proposal_revision})` : ''} `, toggle), view),
        el('div', { class: 'block' }, el('h3', {}, 'Text to release'), edit.node), revised,
        // No digest to name, no decision to offer.
        el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', disabled: !record.proposal_sha256, onclick: () => act('release', record, edit.area.value, onRevised) }, 'Release'),
          el('button', { type: 'button', class: 'btn q', disabled: !record.proposal_sha256, onclick: () => act('reject', record, undefined, onRevised) }, 'Reject')), more)];
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

  return { show: () => (ctx.selected ? detail(ctx.selected.id) : list()), cancel: () => { ++ticket; },
    reset: () => { ++ticket; board = null; editing = null; }, unsaved, discard: () => { editing = null; } };
}
