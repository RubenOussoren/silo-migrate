// The Runs tab: plans to approve and start, runs to follow and reset, converter pushes.
// The decisions are those of widgets/runs/server.py, unchanged: same checks, same exact-digest approval.
import { el, safe, short, badge, ago, toast, api, explain, facts, block, table, details, card, back, item } from './ui.js';

const RUN_DONE = new Set(['completed', 'failed', 'interrupted']);
const operationLabel = (operation) => (operation === 'standard_review' ? 'Import into a review site' : operation === 'standard_convert' ? 'Convert run' : 'Run');
// Which data a plan runs on, in words: part of what an approval covers.
export const dataLabel = (plan) => {
  const delivery = plan.delivery;
  if (!delivery) return 'Not labelled';
  return delivery.kind === 'launch' ? 'LAUNCH data' : `Development v${delivery.version}`;
};

export function runsView(ctx) {
  // ctx: { project, open(kind, id), close(), refresh(), selected: {kind, id} | null, mount(nodes) }
  let ticket = 0;

  async function act(action, body, question) {
    if (!confirm(question)) return null;
    // One decision at a time: no second click while this one runs (a push can take minutes).
    const buttons = [...document.querySelectorAll('#content .actions button')];
    for (const button of buttons) button.disabled = true;
    toast(action === 'push' ? 'Pushing… this can take a few minutes.' : 'Working…');
    try {
      return await api(`api/runs/${action}`, { workspace: ctx.project, ...body });
    } catch (error) {
      for (const button of buttons) button.disabled = false;
      toast(explain(error), true);
      ctx.refresh();
      return null;
    }
  }

  let board = null;  // the last passes view, for opening one pass

  const stepText = (step, site) => {
    if (!step.run_status) {
      return { waiting: 'Waiting for your approval', proposed: 'Waiting for your approval', approved: 'Approved: start it', stale: 'Out of date' }[step.plan_status] || step.plan_status;
    }
    if (['claimed', 'running'].includes(step.run_status)) return `Running: ${step.stage || 'starting'}`;
    if (step.run_status === 'completed') {
      const checks = step.checks ? (step.matched === step.checks ? `All ${step.checks} checks match` : `${step.matched} of ${step.checks} checks match`) : 'No count checks';
      return `${checks}${site ? ' on the site' : ''}`;
    }
    return `${step.run_status.replace('_', ' ')}${step.stage ? ` at ${step.stage}` : ''}`;
  };
  const stepTone = (step) => (!step.run_status ? 'now' : ['claimed', 'running'].includes(step.run_status) ? 'run'
    : step.run_status === 'completed' && step.checks && step.matched === step.checks ? '' : 'warn');
  const stepPill = (step) => (!step.run_status ? (step.plan_status === 'stale' ? 'out of date' : 'for you') : step.run_status === 'completed' ? 'finished' : step.run_status.replace('_', ' '));
  const stepRow = (name, step, site) => el('button', { type: 'button', class: 'step', onclick: () => (step.run_id ? ctx.open('run', step.run_id) : ctx.open('plan', step.plan_id)) },
    el('span', { class: `dot ${stepTone(step)}` }), el('span', {}, name), el('span', { class: 'what' }, stepText(step, site)),
    el('span', { class: `pill ${stepTone(step) === 'warn' ? 'warn' : stepTone(step) === '' ? 'ok' : 'now'}` }, stepPill(step)));
  const passMeta = (group) => [group.delivery || 'Data not labelled', group.converter ? `converter ${short(group.converter, 7)}` : null, ago(group.started_at)].filter(Boolean).join(' · ');
  const tone = (group) => ({ now: 'now', ok: 'ok', warn: 'warn', wait: '' })[group.status[1]];

  function passActions(group, full) {
    const convert = group.convert;
    const last = group.imports[group.imports.length - 1];
    const busy = [convert, ...group.imports].some((step) => !step.run_status || ['claimed', 'running'].includes(step.run_status));
    const actions = [];
    if (last && last.site_up) {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: () => ctx.open('run', last.run_id) }, 'Open the site'));
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('reset', { run_id: last.run_id }, `Reset the review site of pass ${group.number} (${ctx.project})? It holds customer data; evidence and plans stay.`)) { toast('Reset.'); ctx.refresh(); }
      } }, 'Reset the site'));
    }
    const convertPassed = convert.run_status === 'completed' && convert.checks && convert.matched === convert.checks;
    if (!busy && convertPassed && (!last || (last.run_status && !last.site_up))) {
      actions.push(el('button', { type: 'button', class: last ? 'btn q' : 'btn', onclick: async () => {
        const outcome = await act('import', { run_id: convert.run_id }, `Propose importing pass ${group.number} of ${ctx.project} into a new review site? You approve it next.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, last ? 'Import again' : 'Import into a review site'));
    }
    if (!busy && convert.run_id) {
      const again = el('button', { type: 'button', class: full ? 'btn q' : 'link', onclick: async () => {
        const outcome = await act('again', { run_id: convert.run_id }, `Start a new pass of ${ctx.project} with the same data, settings and checks as pass ${group.number}, and the converter as it is now? This only proposes it: you approve it next.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, 'Run again');
      if (!full) again.style.marginLeft = 'auto';
      actions.push(again);
    }
    return actions.length ? el('div', { class: 'actions' }, actions) : null;
  }

  function steps(group) {
    const rows = [stepRow('Convert run', group.convert, false), ...group.imports.map((step, i) => stepRow(group.imports.length > 1 ? `Import ${i + 1}` : 'Import', step, true))];
    const last = group.imports[group.imports.length - 1];
    if (last && last.site_up) rows.push(el('div', { class: 'step static' }, el('span', { class: 'dot run' }), el('span', {}, 'Review site'), el('span', { class: 'what' }, 'Up · holds customer data until reset'), el('span', { class: 'pill now' }, 'check it')));
    return rows;
  }

  function passCard(group, open) {
    const head = el('button', { type: 'button', class: 'pass-head', onclick: () => ctx.open('pass', group.key) },
      el('div', {}, el('span', { class: 'name' }, `Pass ${group.number}`), el('small', {}, passMeta(group))), el('span', { class: `pill ${tone(group)}` }, group.status[0]));
    return el('div', { class: `pass ${open ? '' : 'closed'}` }, head, open ? el('div', { class: 'pass-body' }, steps(group), passActions(group, false)) : null);
  }

  function updatesList(all) {
    // Replaced or discarded proposals never ran: their story is in the push itself.
    const updates = all.filter((update) => ['proposed', 'pushed'].includes(update.status));
    if (!updates.length) return [];
    return [el('h2', {}, 'CONVERTER UPDATES'), el('div', { class: 'updates' }, updates.slice(0, 15).map((update) => el('button', { type: 'button', class: 'upd', onclick: () => ctx.open('push', update.digest) },
      el('span', { class: 'mono' }, update.head || ''), el('span', {}, safe(update.title || 'Converter update')),
      el('span', { class: `pill ${update.status === 'proposed' ? 'now' : !update.used_by.length && update.status === 'pushed' ? 'now' : ''}` },
        update.status === 'proposed' ? 'waiting for your approval' : update.status !== 'pushed' ? update.status : update.used_by.length ? `${update.used_by.length > 1 ? 'passes' : 'pass'} ${update.used_by.join(', ')}` : 'not used yet'))))];
  }

  async function list() {
    const mine = ++ticket;
    if (!board) ctx.mount([el('p', { class: 'quiet' }, 'Loading…')]);
    let data;
    try { data = await api(`api/runs/passes?${new URLSearchParams({ workspace: ctx.project })}`); } catch (error) {
      if (mine === ticket) ctx.mount([el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    board = data;
    const nodes = [];
    if (data.banner) {
      const b = data.banner;
      nodes.push(el('div', { class: 'banner' }, b.kind === 'converter'
        ? el('span', {}, el('b', {}, 'Converter updated'), ` since the last pass: ${b.head} “${safe(b.title || '')}”. Nothing has run on it yet.`)
        : el('span', {}, el('b', {}, 'New data'), `: ${safe(b.label)} hasn't been run yet. Ask migration-data to propose a convert run on it.`),
      b.kind === 'converter' ? el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: async () => {
        const outcome = await act('again', { run_id: b.run_id }, `Start pass ${b.next} of ${ctx.project} with the newest converter (${b.head}) and the same data, settings and checks as the last pass? This only proposes it: you approve it next.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, `Start pass ${b.next}`)) : null));
    }
    const waitingPushes = data.updates.filter((update) => update.status === 'proposed');
    if (waitingPushes.length) {
      nodes.push(el('h2', {}, 'WAITING FOR YOU'), ...waitingPushes.map((update) => item(`Converter update: ${safe(update.title || '')}`, 'Push it to GitHub and open or update the draft PR', () => ctx.open('push', update.digest))));
    }
    if (!data.passes.length) nodes.push(el('p', { class: 'quiet' }, 'No runs yet. migration-data proposes the first convert run; it appears here as pass 1.'));
    nodes.push(...data.passes.map((group, i) => passCard(group, i === 0)));
    nodes.push(...updatesList(data.updates));
    const conv = data.converter || {};
    nodes.push(el('p', { class: 'hint footer' }, el('button', { type: 'button', class: 'link', onclick: () => ctx.open('converter', ctx.project) },
      conv.error ? 'Converter checkout' : `Converter checkout: ${safe(conv.branch || '?')} · ${conv.not_pushed ?? '?'} commit(s) not on GitHub`)));
    ctx.mount(nodes);
  }

  async function passView(key) {
    const mine = ++ticket;
    if (!board) {
      try { board = await api(`api/runs/passes?${new URLSearchParams({ workspace: ctx.project })}`); } catch (error) { ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, explain(error))]); return; }
    }
    if (mine !== ticket) return;
    const group = board.passes.find((candidate) => candidate.key === key);
    if (!group) { ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, 'This pass is no longer there.')]); return; }
    const before = board.passes.find((candidate) => candidate.number === group.number - 1);
    const changes = [];
    if (before) {
      if (before.delivery !== group.delivery) changes.push(`new data (${group.delivery})`);
      if (before.converter !== group.converter) changes.push(`converter ${short(before.converter, 7)} → ${short(group.converter, 7)}`);
      if ((before.roles || {}).settings !== (group.roles || {}).settings) changes.push('new settings');
      if ((before.roles || {}).reconciliation !== (group.roles || {}).reconciliation) changes.push('new checks');
    }
    const changed = before ? el('p', { class: 'changed' }, `Changed since pass ${before.number}: `, el('b', {}, changes.length ? changes.join(', ') : 'nothing'), '.') : null;
    const more = details(facts([['Convert run', group.convert.run_id, true], ['Convert plan', group.convert.plan_id, true],
      ...group.imports.map((step, i) => [`Import ${i + 1}`, step.run_id || step.plan_id, true]), ['Converter', group.converter, true], ['Branch', group.branch, true]]));
    ctx.mount([back('Runs', ctx.close), card(`PASS ${group.number} · ${safe(group.delivery || 'DATA NOT LABELLED').toUpperCase()}`, group.status[0], changed,
      el('div', { class: 'steps' }, steps(group)), passActions(group, true), more)]);
  }

  function plan(data) {
    const convert = data.operation === 'standard_convert';
    const review = data.operation === 'standard_review';
    const converter = data.converter || {};
    const texts = data.texts || {};
    const unseen = (convert && texts.settings == null) || ((convert || review) && (data.roles || {}).reconciliation && texts.reconciliation == null);
    const say = data.status === 'proposed' ? `Approve this ${convert ? 'convert run' : review ? 'import' : 'run'} on ${dataLabel(data)}?`
      : data.status === 'approved' ? 'Approved. Start it when you are ready.' : `This plan is ${data.status === 'stale' ? 'out of date' : data.status.replace('_', ' ')}.`;
    const summary = facts([
      ['Data', el('strong', {}, dataLabel(data))],
      ['What', convert ? `Converts the data with converters/${data.platform} and checks the counts. Nothing is imported yet.` : review ? 'Imports the converted data into a new local review site and checks the counts there.' : operationLabel(data.operation)],
      ['Converter', review ? null : `${converter.branch || ''} @ ${short(data.converter_revision, 12)}`, true],
      ['Proposed', ago(data.created_at)],
      ['Approved by', data.approved_by],
    ]);
    const inputs = (data.inputs || []).map((input) => {
      const role = Object.entries(data.roles || {}).find(([, id]) => id === input.id);
      return [role ? role[0] : input.type, el('span', { class: 'mono' }, safe((data.input_paths || {})[input.id] || input.id)), input.type, String(input.bytes), el('span', { class: 'mono', title: input.sha256 }, short(input.sha256, 16))];
    });
    const more = [facts([['Plan', data.plan_id, true], ['Approval code', data.digest, true], ['Run', data.run_id, true], ['Discourse', data.discourse_profile], ['Charset', data.source_charset],
      ['Discarded', data.discarded ? `${data.discarded.discarded_at} by ${data.discarded.reviewer}` : null]]),
    block('Inputs (by content hash)', table(['Role', 'File', 'Type', 'Bytes', 'SHA-256'], inputs, [3]))];
    if (review) {
      const source = data.from_run || {};
      more.push(block('Review source', facts([['Source run', source.run_id, true], ['Intermediate SHA-256', source.intermediate_sha256, true], ['Loopback port', ((data.instances || {}).review || {}).port]])));
    }
    if (convert) more.push(block('Converter settings (the run fills in ${SILO_DB_*})', texts.settings == null ? el('p', { class: 'quiet' }, '(not readable, or changed since the plan)') : el('pre', {}, safe(texts.settings))));
    if ((convert || review) && (data.roles || {}).reconciliation) {
      more.push(block('Count checks', texts.reconciliation == null ? el('p', { class: 'quiet' }, '(not readable, or changed since the plan)') : checksView(texts.reconciliation)));
    }
    more.push(block('What it does', el('ul', {}, (data.mutations || []).map((m) => el('li', {}, safe(m))))), block('Not included', el('p', {}, (data.not_included || []).join(', '))));
    const actions = [];
    if (data.status === 'proposed') {
      const question = unseen
        ? `Approve this run of ${ctx.project} on ${dataLabel(data)}?\nApproval code ${short(data.digest, 16)}…\nThe settings or checks could NOT be shown here: you approve them by their checksum only.`
        : `Approve this run of ${ctx.project} on ${dataLabel(data)}?\nApproval code ${short(data.digest, 16)}…\nIt runs exactly what this page shows.`;
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        if (await act('approve', { plan_id: data.plan_id, digest: data.digest }, question)) { toast('Approved. Start it when you are ready.'); ctx.refresh(); }
      } }, 'Approve'));
    }
    if (data.status === 'approved') {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        const outcome = await act('start', { plan_id: data.plan_id }, `Start this run of ${ctx.project} on ${dataLabel(data)} now? It runs in the background on the server.`);
        if (outcome) { toast('Started.'); ctx.open('run', outcome.run_id); }
      } }, 'Start'));
    }
    if (['proposed', 'approved', 'stale'].includes(data.status)) {
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('discard', { plan_id: data.plan_id }, `Discard this plan of ${ctx.project}? It can never be approved or run.`)) { toast('Discarded.'); ctx.close(); }
      } }, 'Discard'));
    }
    const notes = [];
    if (data.status === 'stale') notes.push(el('p', { class: 'note' }, 'Something this plan uses changed since it was proposed, so it can\'t run. Discard it and ask migration-data to propose it again.'));
    if (unseen) notes.push(el('p', { class: 'note' }, 'The settings or checks couldn\'t be shown here: an approval would cover them by checksum only.'));
    return [card(data.status === 'proposed' || data.status === 'approved' ? 'FOR YOU' : 'PLAN', say, summary, ...notes, actions.length ? el('div', { class: 'actions' }, actions) : null, details(...more))];
  }

  function checksView(text) {
    let spec = null;
    try { spec = JSON.parse(text); } catch { /* shown as text */ }
    if (!spec || !Array.isArray(spec.checks)) return el('pre', {}, safe(text));
    const destination = spec.checks.some((c) => c.destination_sql);
    return table(['Check', 'Source query', 'Converted query', ...(destination ? ['Site query'] : []), 'Note'],
      spec.checks.map((c) => [safe(c.name), el('code', {}, safe(c.source_sql || '')), el('code', {}, safe(c.intermediate_sql || '')), ...(destination ? [el('code', {}, safe(c.destination_sql || ''))] : []), safe(c.note || '')]));
  }

  function run(data) {
    const results = data.results || {};
    const rows = Array.isArray(data.reconciliation) ? data.reconciliation : [];
    const destination = rows.some((row) => row.destination != null);
    const bad = rows.filter((row) => row.status !== 'matched');
    const say = ['claimed', 'running'].includes(data.status) ? `Running: ${data.stage || 'starting'}.`
      : data.status === 'completed' ? (bad.length ? `${bad.map((row) => safe(row.name)).join(', ')} ${bad.length === 1 ? 'doesn\'t' : 'don\'t'} match.` : rows.length ? 'Finished. Every check matches.' : 'Finished.')
        : data.status === 'failed' ? `Stopped at ${data.stage || 'a stage'}.` : `This run is ${data.status.replace('_', ' ')}.`;
    const parts = [];
    if (rows.length) {
      parts.push(table(['Check', 'Source', 'Converted', ...(destination ? ['Site'] : []), ''],
        rows.map((r) => [safe(r.name), r.source, r.intermediate, ...(destination ? [r.destination] : []), badge(r.status === 'matched' ? 'ok' : 'differs', r.status)]),
        destination ? [1, 2, 3] : [1, 2], (i) => (rows[i].status !== 'matched' ? 'bad' : '')));
    } else if (results.reconciliation_checks !== undefined) parts.push(el('p', { class: 'quiet' }, 'No count checks in this run.'));
    if (data.failure && data.failure.recovery) parts.push(el('p', { class: 'note' }, data.failure.recovery));
    if (data.recovery) parts.push(el('p', { class: 'note' }, data.recovery));
    // Accept only the contracted loopback URL before constructing links or tunnel instructions.
    const reviewURL = /^http:\/\/127[.]0[.]0[.]1:([0-9]{1,5})\/?$/.exec(results.review_url || '');
    if (data.operation === 'standard_review' && data.status === 'completed' && reviewURL && Number(reviewURL[1]) > 0 && Number(reviewURL[1]) <= 65535 && data.review_site_available) {
      const port = reviewURL[1];
      const url = `http://127.0.0.1:${port}/`;
      const credentials = el('div');
      const show = el('button', { type: 'button', class: 'btn q', onclick: async () => {
        show.disabled = true;
        try {
          let secret = await api('api/runs/admin-password', { workspace: ctx.project, run_id: data.run_id });
          if (!credentials.isConnected) return;
          credentials.replaceChildren(facts([['Username', secret.username, true], ['Password', secret.password, true]]),
            el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn q', onclick: async () => {
              try { await navigator.clipboard.writeText(secret.password); toast('Password copied.'); } catch { toast('Copy unavailable; select the password instead.', true); }
            } }, 'Copy password'), el('button', { type: 'button', class: 'btn q', onclick: () => { credentials.replaceChildren(); secret = null; show.hidden = false; } }, 'Hide')));
          show.hidden = true;
        } catch (error) { toast(explain(error), true); } finally { show.disabled = false; }
      } }, 'Show admin password');
      parts.push(block('Review site', el('p', {}, 'Open an SSH tunnel with the same port on both sides, then ', el('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, url), ':'),
        el('pre', {}, `ssh -N -L ${port}:127.0.0.1:${port} <your server login>`), show, credentials,
        el('p', { class: 'note' }, 'This site holds customer data until it is reset.')));
    }
    const actions = [];
    if (['abandoned', 'not_started'].includes(data.status)) {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        if (await act('recover', { run_id: data.run_id }, `Mark this run of ${ctx.project} as interrupted? Only do this if its process is gone, for example after a restart. Then reset it.`)) { toast('Marked interrupted.'); ctx.refresh(); }
      } }, 'Recover'));
    }
    // Only offered while there's something to remove: a review site still up, or what a run that
    // didn't finish cleanly may have left. A convert run cleans up after itself when it ends.
    const review = data.operation === 'standard_review';
    const leftovers = review ? data.review_site_available : data.status !== 'completed';
    if (RUN_DONE.has(data.status) && !leftovers) parts.push(el('p', { class: 'hint' }, review ? 'Its site has been reset: nothing is left to remove.' : 'Nothing to clean up: it tidied up after itself.'));
    if (RUN_DONE.has(data.status) && leftovers) {
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('reset', { run_id: data.run_id }, `Reset this run of ${ctx.project}? Its review site, containers and leftovers are removed. Evidence, plans and backups stay.`)) { toast('Reset.'); ctx.refresh(); }
      } }, data.operation === 'standard_review' ? 'Reset the site' : 'Reset'));
    }
    const more = [facts([['Run', data.run_id, true], ['Plan', data.plan_id, true], ['Started', data.started_at], ['Finished', data.finished_at],
      ['Problem', data.failure ? `${data.failure.code} (stage ${data.failure.stage})` : null, true], ['Import issues', results.import_issues]]),
    el('div', { class: 'stagelist' }, Object.entries(data.stages || {}).map(([name, status]) => el('span', {}, `${name} `, badge(status))))];
    if (rows.length) {
      more.push(block('All check columns', table(['Check', 'Source', 'Converted', 'Difference', ...(destination ? ['Site', 'Site difference'] : []), 'Status', 'Note'],
        rows.map((r) => [safe(r.name), r.source, r.intermediate, r.difference, ...(destination ? [r.destination, r.destination_difference] : []), r.status, safe(r.error || r.note || '')]), [1, 2, 3])));
    }
    if (data.artifacts && data.artifacts.intermediate) more.push(block('Converted database', facts([['Bytes', String(data.artifacts.intermediate.bytes)], ['SHA-256', data.artifacts.intermediate.sha256, true]])));
    if (data.conversion_summary) more.push(block('Converter summary', el('pre', {}, safe(data.conversion_summary))));
    const eyebrow = data.status === 'completed' && !bad.length ? 'FINISHED' : ['claimed', 'running'].includes(data.status) ? 'IN PROGRESS' : 'NEEDS A LOOK';
    return [card(eyebrow, say, ...parts, actions.length ? el('div', { class: 'actions' }, actions) : null, details(...more))];
  }

  function push(data) {
    const pull = data.pull_request;
    const commits = data.commits || [];
    const say = data.status === 'proposed' ? `Push ${commits.length} commit(s) and open or update the draft PR?` : data.status === 'superseded' ? 'A newer proposal replaced this one.' : `This push is ${data.status}.`;
    const summary = facts([['Title', safe(data.title)], ['Branch', `${safe(data.branch)} → ${safe(data.base)}`, true], ['Repository', data.repository],
      ['Addresses', (data.findings || []).length ? `${data.findings.length} finding(s): ${data.findings.join(', ')}` : 'no finding named'],
      ['Pull request', pull && pull.url ? el('a', { href: pull.url, target: '_blank', rel: 'noopener noreferrer' }, `#${pull.number} (draft)`) : null]]);
    const commitLine = (c) => (typeof c === 'string' ? safe(c) : `${short(c.sha, 10)}  ${safe(c.subject || '')}${c.author ? ` (${safe(String(c.author).replace(/\s*<[^>]*>$/, ''))})` : ''}`);
    const commitList = el('ul', { class: 'commits' }, commits.map((c) => el('li', { class: 'mono' }, commitLine(c))));
    const actions = [];
    const discard = el('button', { type: 'button', class: 'btn q', onclick: async () => {
      if (await act('discard-push', { digest: data.digest }, `Discard this push proposal of ${ctx.project}? It will never be pushed.`)) { toast('Discarded.'); ctx.close(); }
    } }, 'Discard');
    if (data.status === 'proposed' || (data.status === 'pushed' && !(pull && pull.url))) {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        const owner = String(data.repository || '').split('/')[0];
        const outcome = await act('push', { digest: data.digest }, `Push ${data.branch} (${short(data.head, 12)}) to ${data.repository} and open a draft PR, with the server's GitHub token for ${owner}?`);
        if (outcome) { toast(outcome.pull_request && outcome.pull_request.url ? `Pushed; draft PR #${outcome.pull_request.number}.` : 'Pushed.'); ctx.refresh(); }
      } }, data.status === 'proposed' ? 'Push and open draft PR' : 'Open draft PR'));
      if (data.status === 'proposed') actions.push(discard);
    } else if (data.status === 'superseded') actions.push(discard);
    const more = [facts([['Head', data.head, true], ['Proposed', data.proposed_at], ['Pushed', data.pushed_at], ['Approval code', data.digest, true]]),
      block('PR description', el('pre', {}, safe(data.body || '(empty)'))),
      block(`Files (${data.files_total ?? (data.files || []).length})`, el('pre', {}, (data.files || []).map(safe).join('\n')))];
    if (data.stat) more.push(block('Diff stat', el('pre', {}, safe(data.stat))));
    return [card(data.status === 'proposed' ? 'FOR YOU' : 'CONVERTER PUSH', say, summary, block(`Commits (${commits.length})`, commitList), actions.length ? el('div', { class: 'actions' }, actions) : null, details(...more))];
  }

  function converter(log) {
    return [card('CONVERTER', `${safe(log.branch || 'No branch')} · ${log.not_pushed ?? '?'} commit(s) not on GitHub`,
      facts([['Head', log.head, true], ['Ahead of main', log.ahead_of_main == null ? null : `${log.ahead_of_main} commit(s)`],
        ['Uncommitted', log.uncommitted ? `${log.uncommitted} change(s): converter-developer is working, or files were left behind` : 'none']]),
      el('p', { class: 'note' }, 'Commits reach GitHub only when converter-developer proposes a push and you approve it. Runs use the committed head of this checkout.'),
      details(table(['Commit', 'Subject', 'Author', 'Date', 'GitHub'], (log.commits || []).map((c) => [el('span', { class: 'mono' }, short(c.sha, 10)), safe(c.subject), safe(c.author), (c.date || '').slice(0, 16).replace('T', ' '), c.pushed ? 'pushed' : 'not yet']))))];
  }

  async function detail(kind, id, quiet = false) {
    const mine = ++ticket;
    board = null;  // a decision may change the passes: the list asks again
    if (!quiet) ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, 'Loading…')]);  // a refresh keeps what's shown
    let data;
    try { data = await api(`api/runs/${kind}?${new URLSearchParams({ workspace: ctx.project, id })}`); } catch (error) {
      if (mine !== ticket) return;
      if (quiet) {  // a passing error during a refresh: keep what's shown and try again
        setTimeout(() => { if (ctx.selected && ctx.selected.id === id && mine === ticket) detail(kind, id, true); }, 5000);
        return;
      }
      ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    const render = { plan, run, push, converter }[kind];
    const open = [...document.querySelectorAll('#content details[open]')].length > 0;
    ctx.mount([back('Runs', ctx.close), ...render(data)]);
    if (quiet && open) for (const node of document.querySelectorAll('#content details.more')) node.open = true;
    // A run in progress refreshes itself while it's the one on screen (waiting while the tab is hidden).
    if (kind === 'run' && ['claimed', 'running'].includes(data.status)) {
      const again = () => {
        if (!(ctx.selected && ctx.selected.kind === 'run' && ctx.selected.id === id && mine === ticket)) return;
        if (document.hidden) setTimeout(again, 5000); else detail(kind, id, true);
      };
      setTimeout(again, 5000);
    }
  }

  return { show: () => (!ctx.selected ? list() : ctx.selected.kind === 'pass' ? passView(ctx.selected.id) : detail(ctx.selected.kind, ctx.selected.id)) };
}
