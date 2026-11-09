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

  async function list() {
    const mine = ++ticket;
    ctx.mount([el('p', { class: 'quiet' }, 'Loading…')]);
    let data;
    try { data = await api(`api/runs/overview?${new URLSearchParams({ workspace: ctx.project })}`); } catch (error) {
      if (mine === ticket) ctx.mount([el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    const plans = data.plans.slice().sort((a, b) => String(b.created_at).localeCompare(String(a.created_at)));
    // A run is known by its plan: what kind it is and which data it used.
    const planOf = Object.fromEntries(data.plans.map((plan) => [plan.plan_id, plan]));
    const runs = data.runs.map((r) => ({ ...r, operation: (planOf[r.plan_id] || {}).operation, delivery: (planOf[r.plan_id] || {}).delivery }))
      .sort((a, b) => String(b.started_at).localeCompare(String(a.started_at)));
    const planItem = (plan) => item(`${operationLabel(plan.operation)} on ${dataLabel(plan)}`,
      `${plan.status === 'approved' ? 'Approved, ready to start' : plan.status === 'proposed' ? 'Waiting for your approval' : plan.status.replace('_', ' ')} · ${ago(plan.created_at)}`,
      () => ctx.open('plan', plan.plan_id));
    const runItem = (run) => item(`${operationLabel(run.operation)}${run.delivery ? ` on ${dataLabel(run)}` : ''} · ${run.status === 'completed' ? 'finished' : run.status.replace('_', ' ')}`,
      `${run.stage ? `${run.stage} · ` : ''}${ago(run.started_at)}`, () => ctx.open('run', run.run_id));
    const pushItem = (push) => item(safe(push.title || 'Converter update'), `${push.status === 'proposed' ? 'Waiting for your approval' : push.status} · ${ago(push.proposed_at)}`,
      () => ctx.open('push', push.digest));
    const waiting = [...plans.filter((p) => ['proposed', 'approved'].includes(p.status)).map(planItem), ...data.pushes.filter((p) => p.status === 'proposed').map(pushItem)];
    const running = runs.filter((r) => ['claimed', 'running'].includes(r.status)).map(runItem);
    const finished = runs.filter((r) => !['claimed', 'running'].includes(r.status));
    const nodes = [el('h2', {}, 'WAITING FOR YOU'), ...(waiting.length ? waiting : [el('p', { class: 'quiet' }, 'Nothing. Plans appear when migration-data proposes a run, pushes when converter-developer proposes one.')])];
    if (running.length) nodes.push(el('h2', {}, 'RUNNING'), ...running);
    if (finished.length) nodes.push(el('h2', {}, 'LATEST'), runItem(finished[0]));
    const conv = data.converter || {};
    const earlier = [
      ...finished.slice(1, 25).map(runItem),
      ...data.pushes.filter((p) => p.status !== 'proposed').slice(0, 10).map(pushItem),
      ...plans.filter((p) => !['proposed', 'approved'].includes(p.status)).slice(0, 25).map(planItem),
    ];
    nodes.push(el('details', { class: 'history' }, el('summary', {}, `Converter and earlier items (${earlier.length})`),
      item(conv.error ? 'Converter' : `Converter · ${safe(conv.branch || '?')}`, conv.error ? conv.error : `${conv.not_pushed ?? '?'} commit(s) not on GitHub${conv.uncommitted ? ` · ${conv.uncommitted} uncommitted` : ''}`,
        () => ctx.open('converter', ctx.project)), ...earlier));
    ctx.mount(nodes);
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

  return { show: () => (ctx.selected ? detail(ctx.selected.kind, ctx.selected.id) : list()) };
}
