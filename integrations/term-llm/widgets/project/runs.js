// The Runs tab: plans to approve and start, runs to follow and reset, converter pushes.
// The decisions are those of widgets/runs/server.py, unchanged: same checks, same exact-digest approval.
import { el, safe, short, badge, ago, toast, api, lists, explain, facts, block, table, details, card, back, item } from './ui.js';
import { planSections } from './intake.js';

const baseLabel = (base) => base ? `Base site v${(base.delivery || {}).version}` : 'None: fresh site';
const bytes = (n) => n >= 1e9 ? `${(n / 1e9).toFixed(1)} GB` : `${Math.round(n / 1e6)} MB`;
const runtimeLabel = (runtime) => runtime ? `${runtime.actual_version} · ${runtime.track} · ${runtime.mode === 'latest' ? 'latest supported build' : runtime.mode === 'newer' ? 'compatible newer version' : 'matches the Base site version'}` : null;
const resetNote = (release) => release ? 'The released backup stays in the output folder.' : 'The unreleased backup is kept with the run.';

const RUN_DONE = new Set(['completed', 'failed', 'interrupted']);
const operationLabel = (operation) => (operation === 'standard_review' ? 'Import into a review site' : operation === 'standard_convert' ? 'Convert run' : operation === 'standard_merge' ? 'Merge run'
  : operation === 'standard_master_lists' ? 'Master-list export (preparation)' : operation === PREPARE ? 'Prepare merge environment' : 'Run');
// Preparing a merge environment is not a merge or a convert run: nothing is migrated, backed up or released.
const PREPARE = 'standard_merge_prepare';
const PREPARE_WHAT = 'Preparation only: selects one compatible pinned Discourse runtime, restores the Base site, loads and upgrades a disposable copy of the source site’s database with it, checks compatibility and keeps the source uploads unchanged. It keeps a clean prepared checkpoint, and separate inspection copies for migration-data. Nothing is merged or migrated; there is no output backup to release.';
const PREPARE_ACCESS = 'While it is ready, migration-data can read both sites’ private content through the inspection copies (read-only tools only: DBHub for the source database, Discourse MCP for the local Base site). That access lasts until a merge fences it or you reset the environment. Each copy needs about another full database of disk space.';
const PREPARE_APPROVAL = 'It restores and prepares both sites locally and gives migration-data read-only inspection access. Nothing is merged: the merge needs its own plan and approval.';
const PHASES = { preparing: 'Preparing', ready: 'Ready · inspection copies live', inspection: 'Ready · being inspected', fencing: 'Fencing inspection for a merge', merging: 'A merge is using it',
  consumed: 'Used by a merge', dirty: 'Not clean: prepare it again', reset: 'Reset' };
const phaseLabel = (env) => (env && env.phase ? PHASES[env.phase] || `State: ${safe(env.phase)}` : 'State not reported');
const ENDPOINTS = { dbhub: 'DBHub · prepared source database (inspection copy)', discourse_mcp: 'Discourse MCP · local Base site (inspection copy)' };
// Only the fixed kind, name and readiness the host reports: never a profile, key, host path or URL.
const endpointRows = (env) => ((env && env.endpoints) || []).filter((point) => ENDPOINTS[point.kind])
  .map((point) => [ENDPOINTS[point.kind], `${point.ready ? 'ready' : 'not ready'}${point.name ? ` · ${safe(point.name)}` : ''}`]);
const live = (phase) => phase === 'ready' || phase === 'inspection';  // prepared and clean, not yet used by a merge
// A generation is the host's 64-hex identity (or a small counter): shown short, never edited.
const generationLabel = (bound) => (bound && bound.generation ? `generation ${short(String(bound.generation), 12)}` : 'generation unknown');
const intentLabel = (intent) => (intent === 'stock' ? 'Stock: Discourse’s own merger only' : intent === 'custom' ? 'Custom: the committed merge layer and settings' : null);
const PREPARED_MERGE = (bound) => `This merge runs in the same prepared environment (${generationLabel(bound)} of run ${short(bound.run_id, 12)}). Inspection access is fenced and its copies discarded, then the clean prepared checkpoint is activated, its binding rechecked and the merge run. The backups are not restored anew. If that environment changed, was reset or used, the run refuses: it never switches to a fresh restore.`;
// A preparation job is not a pass: it neither converts nor imports.
const MASTER_WHAT = 'Preparation only: loads a disposable copy of the source and runs the converter’s committed master-list exporter. It rebuilds staging tables in that copy (not a read-only check). Nothing is converted or imported; the exported CSVs are kept as this run’s private artifacts, and using them needs a new plan.';
const isMerge = (group) => group.kind === 'merge';
// A merge pass names the merge layer it ran with (the commit it was read from), or that there was none.
const layerLabel = (layer) => (layer && layer.present ? `merge layer ${short(layer.revision, 7)}` : 'no merge layer');
const MERGE_TOTALS = ['users', 'topics', 'posts', 'categories', 'groups', 'tags', 'uploads'];
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
    const project = ctx.project;
    const mine = ++ticket;  // an older list refresh must not replace the disabled action controls
    // One decision at a time: no second click while this one runs (a push can take minutes).
    const buttons = [...document.querySelectorAll('#content .actions button')];
    for (const button of buttons) button.disabled = true;
    toast(action === 'release' ? 'Releasing… this can take a few minutes.' : action === 'push' ? 'Pushing… this can take a few minutes.' : 'Working…');
    let preparing = null;
    try {
      let outcome = await api(`api/runs/${action}`, { workspace: project, ...body });
      const deadline = Date.now() + 21 * 60 * 1000;
      while (['import', 'again'].includes(action) && outcome.status === 'runtime_preparing') {
        if (project !== ctx.project || mine !== ticket) return null;
        if (!preparing) {
          preparing = el('p', { class: 'note', role: 'status' }, 'Preparing the matching Discourse runtime… This can take several minutes the first time. No customer data is used. The plan will appear when ready.');
          document.querySelector('#content')?.append(preparing);
        }
        if (Date.now() > deadline) throw new Error('STANDARD_REVIEW_RUNTIME_TIMEOUT');
        await new Promise(resolve => setTimeout(resolve, 5000));
        if (project !== ctx.project || mine !== ticket) return null;
        outcome = await api(`api/runs/${action}`, { workspace: project, ...body });
      }
      return project === ctx.project && mine === ticket ? outcome : null;
    } catch (error) {
      if (project !== ctx.project || mine !== ticket) return null;
      for (const button of buttons) button.disabled = false;
      toast(explain(error), true);
      ctx.refresh();
      return null;
    } finally {
      preparing?.remove();
    }
  }

  let board = null;  // the last passes view, for opening one pass

  const stepText = (step, site) => {
    if (!step.run_status) {
      return { waiting: 'Waiting for your approval', proposed: 'Waiting for your approval', approved: 'Approved: start it', stale: 'Out of date' }[step.plan_status] || step.plan_status;
    }
    if (['claimed', 'running'].includes(step.run_status)) return `Running: ${step.stage || 'starting'}`;
    if (step.run_status === 'completed' && step.kind === 'merge') return 'Merged · no automatic count checks: check the site';
    if (step.run_status === 'completed' && step.kind === 'merge_prepare') return 'Prepared · no migration has run';
    if (step.run_status === 'completed') {
      const checks = step.checks ? (step.matched === step.checks ? `All ${step.checks} checks match` : `${step.matched} of ${step.checks} checks match`) : 'No count checks';
      return `${checks}${site ? ' on the site' : ''}`;
    }
    return `${step.run_status.replace('_', ' ')}${step.stage ? ` at ${step.stage}` : ''}`;
  };
  const stepTone = (step) => (!step.run_status ? 'now' : ['claimed', 'running'].includes(step.run_status) ? 'run'
    : step.run_status === 'completed' && (step.kind === 'merge' || step.kind === 'merge_prepare' || (step.checks && step.matched === step.checks)) ? '' : 'warn');
  const stepPill = (step) => (!step.run_status ? (step.plan_status === 'stale' ? 'out of date' : 'for you') : step.run_status === 'completed' ? 'finished' : step.run_status.replace('_', ' '));
  const stepRow = (name, step, site) => el('button', { type: 'button', class: 'step', onclick: () => (step.run_id ? ctx.open('run', step.run_id) : ctx.open('plan', step.plan_id)) },
    el('span', { class: `dot ${stepTone(step)}` }), el('span', {}, name), el('span', { class: 'what' }, stepText(step, site)),
    el('span', { class: `pill ${stepTone(step) === 'warn' ? 'warn' : stepTone(step) === '' ? 'ok' : 'now'}` }, stepPill(step)));
  const passMeta = (group) => [group.delivery || 'Data not labelled', isMerge(group) ? layerLabel(group.layer) : group.converter ? `converter ${short(group.converter, 7)}` : null, ago(group.started_at)].filter(Boolean).join(' · ');
  const tone = (group) => ({ now: 'now', ok: 'ok', warn: 'warn', wait: '' })[group.status[1]];

  function passActions(group, full) {
    const convert = group.convert;
    // A merge pass is one run: the merged site and its backup are on that run.
    const last = isMerge(group) ? (convert.run_id ? convert : undefined) : group.imports[group.imports.length - 1];
    const busy = [convert, ...group.imports].some((step) => !step.run_status || ['claimed', 'running'].includes(step.run_status));
    const actions = [];
    if (last) { const release = releaseButton(last); if (release) actions.push(release); }
    if (last && last.site_up) {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: () => ctx.open('run', last.run_id) }, 'Open the site'));
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('reset', { run_id: last.run_id }, `Reset the ${isMerge(group) ? 'merged' : 'review'} site of pass ${group.number} (${ctx.project})? It holds customer data; evidence and plans stay. ${resetNote(last && last.release)}`)) { toast('Reset.'); ctx.refresh(); }
      } }, 'Reset the site'));
    }
    const convertPassed = convert.run_status === 'completed' && convert.checks && convert.matched === convert.checks;
    if (!isMerge(group) && !busy && convertPassed && (!last || (last.run_status && !last.site_up))) {
      actions.push(el('button', { type: 'button', class: last ? 'btn q' : 'btn', onclick: async () => {
        const outcome = await act('import', { run_id: convert.run_id }, `Propose importing pass ${group.number} of ${ctx.project} into a new review site? You approve it next.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, last ? 'Import again' : 'Import into a review site'));
    }
    if (!busy && convert.run_id) {
      const again = el('button', { type: 'button', class: full ? 'btn q' : 'link', onclick: async () => {
        const outcome = await act('again', { run_id: convert.run_id }, isMerge(group) && group.prepared_from
          ? `Propose a new merge of ${ctx.project} with the same source backup, settings and options as pass ${group.number}, in the same prepared environment (${generationLabel(group.prepared_from)}), with the merge layer as it is committed now? Only while that environment is still ready at that generation: otherwise nothing is proposed and you prepare it again. This only proposes it: you approve it next.`
          : isMerge(group)
          ? `Start a new merge of ${ctx.project} with the same source backup, settings and options as pass ${group.number}, on the current Base site, with the merge layer as it is committed now? This only proposes it: you approve it next.`
          : `Start a new pass of ${ctx.project} with the same data, settings and checks as pass ${group.number}, and the converter as it is now? This only proposes it: you approve it next.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, 'Run again');
      if (!full) again.style.marginLeft = 'auto';
      actions.push(again);
    }
    return actions.length ? el('div', { class: 'actions' }, actions) : null;
  }

  const passed = (step) => step && step.run_status === 'completed' && step.checks && step.matched === step.checks;
  // The engineer's verdict on the last import's site: accepted (on the customer's approval or their own
  // check), needs changes, or still to decide.
  function siteRow(last) {
    const review = last.review;
    const up = last.site_up ? ' · up, holds customer data until reset' : '';
    if (review && review.verdict === 'accepted') {
      const basis = review.replaced ? 'customer approved; a later pass is now the accepted one' : review.basis === 'customer' ? 'customer approved' : 'your own check';
      return el('div', { class: 'step static' }, el('span', { class: 'dot' }), el('span', {}, 'Site'), el('span', { class: 'what' }, `Accepted by ${safe(review.by)} ${ago(review.at)} · ${basis}${up}`),
        el('span', { class: `pill ${review.replaced ? '' : 'ok'}` }, review.replaced ? 'accepted earlier' : review.basis === 'customer' ? 'accepted' : 'checked'));
    }
    if (review && review.verdict === 'needs_changes') {
      return el('div', { class: 'step static' }, el('span', { class: 'dot warn' }), el('span', {}, 'Site'), el('span', { class: 'what' }, `Needs changes: ${safe(review.note || '')}${up}`),
        el('span', { class: 'pill warn' }, 'needs changes'));
    }
    return el('div', { class: 'step static' }, el('span', { class: 'dot run' }), el('span', {}, 'Site'),
      el('span', { class: 'what' }, last.site_up ? 'Up · check it through the tunnel, then decide' : 'Reset · decide from what you saw'), el('span', { class: 'pill now' }, 'for you'));
  }

  function releaseButton(step) {
    if (step.run_status !== 'completed' || !step.backup || step.release) return null;
    const matched = step.checks > 0 && step.matched === step.checks;
    const differs = Math.max(0, step.checks - step.matched);
    const question = matched ? 'Release this backup for review? It copies the backup and a manifest to this project’s output folder. Nothing is sent anywhere.'
      : step.kind === 'merge' ? 'A merge has no automatic count checks: the totals and your own check of the merged site are what there is. Release this backup for review? It copies the backup and a manifest to this project’s output folder. Nothing is sent anywhere.'
      : `${step.checks ? `${differs} of ${step.checks} checks ${differs === 1 ? 'differs' : 'differ'}.` : 'There are no count checks.'} Release this backup for review anyway?`;
    return el('button', { type: 'button', class: matched || step.kind === 'merge' ? 'btn' : 'btn q', onclick: async () => {
      if (await act('release', { run_id: step.run_id, acknowledge: !matched }, question)) { toast('Backup released.'); ctx.refresh(); }
    } }, matched ? 'Release backup' : step.kind === 'merge' ? 'Release backup…' : 'Release anyway…');
  }

  function backupRows(last) {
    if (!last || !last.base_site) return [];
    const base = last.base_site_details || {};
    const backup = last.backup;
    const row = (name, text, state) => el('div', { class: 'step static' }, el('span', { class: 'dot' }), el('span', {}, name),
      el('span', { class: 'what' }, text), state ? el('span', { class: 'pill ok' }, state) : null);
    const ahead = base.ahead || (last.results || {}).base_site_ahead;
    const merge = last.kind === 'merge';
    return [row('Base site', `${last.base_site} · Discourse ${base.discourse_version || 'unknown'}${ahead ? ' · newer schema than this server, as approved' : ''} · restored before the ${merge ? 'merge' : 'import'}`, ''),
      row('Backup', backup ? `${merge ? 'Merged site with the source site’s uploads' : 'Sandbox + imported data, no uploads'} · ${bytes(backup.bytes)} · taken before the review sign-in was added` : 'Not taken yet', last.backup_state)];
  }

  function releasedDetails(last) {
    const release = last && last.release;
    if (!release) return null;
    const manifest = String(release.manifest || '').split('/').pop();
    const version = (last.results || {}).backup_discourse_version || (last.results || {}).discourse_version;
    const schema = (last.results || {}).backup_schema_version;
    return block('Released for review', el('p', {}, 'Copy the backup from the server and restore it on the migration site.'),
      facts([['Output folder', safe(release.outbox), true], ['Backup', safe(release.filename), true], ['Manifest', safe(manifest), true],
        ['Released', `by ${safe(release.released_by)} · ${safe(release.released_at)}`], ['SHA-256', short(release.sha256, 12), true]]),
      el('p', { class: 'hint' }, version ? `Restores on Discourse ${safe(version)} or newer${schema ? ` (schema version ${safe(schema)} or newer)` : ''}. Restore on the hosted migration site is outside this tool.` : 'Restore on the hosted migration site is outside this tool. Use the Discourse version in the manifest or newer.'));
  }

  function steps(group) {
    if (isMerge(group)) {
      const merge = group.convert;
      const site = merge.site_up ? [el('div', { class: 'step static' }, el('span', { class: 'dot run' }), el('span', {}, 'Merged site'), el('span', { class: 'what' }, 'Up · holds customer data until reset'), el('span', { class: 'pill now' }, 'check it'))] : [];
      const prepared = group.prepared_from ? [el('div', { class: 'step static' }, el('span', { class: 'dot' }), el('span', {}, 'Prepared environment'),
        el('span', { class: 'what' }, `${generationLabel(group.prepared_from)} · its clean checkpoint, activated for the merge (not restored anew)`))] : [];
      return [...prepared, stepRow('Merge run', merge, false), ...site, ...backupRows(merge)];
    }
    const rows = [stepRow('Convert run', group.convert, false), ...group.imports.map((step, i) => stepRow(group.imports.length > 1 ? `Import ${i + 1}` : 'Import', step, true))];
    const last = group.imports[group.imports.length - 1];
    if (last && passed(last) && passed(group.convert)) rows.push(siteRow(last));
    else if (last && last.site_up) rows.push(el('div', { class: 'step static' }, el('span', { class: 'dot run' }), el('span', {}, 'Review site'), el('span', { class: 'what' }, 'Up · holds customer data until reset'), el('span', { class: 'pill now' }, 'check it')));
    rows.push(...backupRows(last));
    return rows;
  }

  // Is this site right? Shown on a pass whose last import passed and has no verdict yet, or only the
  // engineer's own check (the customer's approval is what launch repeats).
  function decideBox(group) {
    const last = group.imports[group.imports.length - 1];
    if (!last || !passed(last) || !passed(group.convert) || !/^Development/.test(group.delivery || '')) return null;
    const review = last.review;
    if (review && !(review.verdict === 'accepted' && (review.basis === 'engineer' || review.replaced))) return null;
    return el('div', { class: 'decide' }, el('span', {}, review ? 'Has the customer approved it?' : 'Is this site right?'),
      el('span', { class: 'btns' }, el('button', { type: 'button', class: 'btn', onclick: () => ctx.open('accept', last.run_id) }, 'Accept site\u2026'),
        el('button', { type: 'button', class: 'btn q', onclick: () => ctx.open('changes', last.run_id) }, 'Needs changes\u2026')));
  }

  function passSay(group) {
    if (isMerge(group)) {
      const merge = group.convert;
      if (merge.run_status !== 'completed') return group.status[0];
      if (merge.release) return 'Released for review. Copy the backup from the server and restore it on the migration site.';
      return `Merged into the sandbox with ${layerLabel(group.layer)}. There are no automatic count checks: ${merge.site_up ? 'check the site, then release the backup.' : 'the run shows the totals.'}`;
    }
    const last = group.imports[group.imports.length - 1];
    if (!last || !last.base_site || last.run_status !== 'completed') return group.status[0];
    if (last.release) return 'Released for review. Copy the backup from the server and restore it on the migration site.';
    return passed(last) ? 'Imported on top of the sandbox. Every check matches. Check the site, then release the backup.'
      : `Imported on top of the sandbox. ${last.checks ? `${last.checks - last.matched} of ${last.checks} checks ${last.checks - last.matched === 1 ? 'differs' : 'differ'}.` : 'No count checks.'}`;
  }

  function passCard(group, open) {
    const head = el('button', { type: 'button', class: 'pass-head', onclick: () => ctx.open('pass', group.key) },
      el('div', {}, el('span', { class: 'name' }, `Pass ${group.number}`), el('small', {}, passMeta(group))), el('span', { class: `pill ${tone(group)}` }, group.status[0]));
    return el('div', { class: `pass ${open ? '' : 'closed'}` }, head, open ? el('div', { class: 'pass-body' }, group.base_site ? el('p', { class: 'hint' }, passSay(group)) : null, steps(group), decideBox(group), passActions(group, false), releasedDetails(isMerge(group) ? group.convert : group.imports[group.imports.length - 1])) : null);
  }

  // A prepared merge environment: its own card, never a numbered pass. No backup, release or sign-in.
  function envActions(item, full) {
    const step = item.step;
    const actions = [];
    const done = step.run_id && step.run_status && !['claimed', 'running'].includes(step.run_status);
    const phase = (item.environment || {}).phase;
    if (done && !['reset', 'consumed', 'fencing', 'merging'].includes(phase)) {
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('reset', { run_id: step.run_id }, `Reset the prepared merge environment of ${ctx.project}? Its inspection copies, connectors and clean prepared checkpoint are removed; a merge plan bound to ${generationLabel(item.environment)} can no longer run. Evidence and plans stay.`)) { toast('Reset.'); ctx.refresh(); }
      } }, 'Reset the environment'));
    }
    if (done) {
      const again = el('button', { type: 'button', class: full ? 'btn q' : 'link', onclick: async () => {
        const outcome = await act('again', { run_id: step.run_id }, `Propose preparing a new merge environment of ${ctx.project} with the same source backup, on the current Base site? This only proposes it: you approve it next, then start it. Nothing is merged.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, 'Run again');
      if (!full) again.style.marginLeft = 'auto';
      actions.push(again);
    }
    return actions.length ? el('div', { class: 'actions' }, actions) : null;
  }

  function envSay(item) {
    const step = item.step;
    if (step.run_status !== 'completed') return item.status[0];
    const phase = (item.environment || {}).phase;
    if (live(phase)) return 'Prepared. No migration has run. Inspection stays live until a merge or a reset; ask migration-data to propose the merge when its questions are answered.';
    if (phase === 'consumed') return 'A merge used this environment. Its result and backup are on that merge pass.';
    return item.status[0];
  }

  function envCard(item) {
    const step = item.step;
    const env = item.environment;
    const head = el('button', { type: 'button', class: 'pass-head', onclick: () => (step.run_id ? ctx.open('run', step.run_id) : ctx.open('plan', step.plan_id)) },
      el('div', {}, el('span', { class: 'name' }, 'Prepare merge environment'), el('small', {}, [item.delivery || 'Data not labelled', item.base_site, env && env.generation ? generationLabel(env) : null, ago(item.at)].filter(Boolean).join(' · '))),
      el('span', { class: `pill ${tone(item)}` }, item.status[0]));
    const row = (name, text) => el('div', { class: 'step static' }, el('span', { class: 'dot' }), el('span', {}, name), el('span', { class: 'what' }, text));
    const rows = [stepRow('Prepare', step, false)];
    if (step.run_status === 'completed') {
      rows.push(row('Environment', phaseLabel(env)));
      if (env && live(env.phase)) rows.push(...endpointRows(env).map(([name, text]) => row(name, text)));
      rows.push(row('Output', 'None: no migration has run, nothing to back up or release'));
    }
    if (item.used_by && item.used_by.length) rows.push(row('Merge', `Used by pass ${item.used_by.join(', ')}`));
    else if (item.proposed_merges && item.proposed_merges.length) rows.push(row('Merge', `Proposed as pass ${item.proposed_merges.join(', ')}: approve it there`));
    return el('div', { class: 'pass' }, head, el('div', { class: 'pass-body' }, el('p', { class: 'hint' }, envSay(item)), rows, envActions(item, false)));
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

  const listPath = () => `api/boards?${new URLSearchParams({ workspace: ctx.project })}`;

  async function list() {
    const mine = ++ticket;
    const path = listPath();
    board = lists.peek(path)?.runs || null;
    if (board) paintList(board, 'Refreshing…');
    else ctx.mount([el('p', { class: 'quiet', role: 'status' }, 'Loading runs…')]);
    try {
      const data = (await lists.load(path)).runs;
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
    if (data.error) { ctx.mount([el('p', { class: 'quiet' }, explain(new Error(data.error)))]); return; }
    const nodes = [];
    if (data.banner) {
      const b = data.banner;
      nodes.push(el('div', { class: 'banner' }, b.kind === 'converter'
        ? el('span', {}, el('b', {}, b.merge ? 'Converter checkout updated' : 'Converter updated'), ` since the last pass: ${b.head} “${safe(b.title || '')}”. Nothing has run on it yet.`)
        : el('span', {}, el('b', {}, 'New data'), `: ${safe(b.label)} hasn't been run yet. Ask migration-data to propose a ${b.merge ? 'merge' : 'convert'} run on it.`),
      b.kind === 'converter' ? el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn', onclick: async () => {
        const outcome = await act('again', { run_id: b.run_id }, b.merge
          ? `Start pass ${b.next} of ${ctx.project} with the merge layer as it is committed now (${b.head}) and the same source backup, settings and options as the last pass? This only proposes it: you approve it next.`
          : `Start pass ${b.next} of ${ctx.project} with the newest converter (${b.head}) and the same data, settings and checks as the last pass? This only proposes it: you approve it next.`);
        if (outcome && outcome.plan_id) { toast('Proposed. Check it and approve.'); ctx.open('plan', outcome.plan_id); }
      } }, `Start pass ${b.next}`)) : null));
    }
    const waitingPushes = data.updates.filter((update) => update.status === 'proposed');
    if (waitingPushes.length) {
      nodes.push(el('h2', {}, 'WAITING FOR YOU'), ...waitingPushes.map((update) => item(`Converter update: ${safe(update.title || '')}`, 'Push it to GitHub and open or update the draft PR', () => ctx.open('push', update.digest))));
    }
    const prepared = data.environments || [];
    if (prepared.length) {
      nodes.push(el('h2', {}, 'MERGE ENVIRONMENT'), el('p', { class: 'hint' }, 'Preparing a merge environment is not a pass: nothing is merged, backed up or released in it.'),
        ...prepared.map((item) => envCard(item)));
      if (data.passes.length) nodes.push(el('h2', {}, 'PASSES'));
    }
    if (!data.passes.length) nodes.push(el('p', { class: 'quiet' }, prepared.length ? 'No merge has run yet. When the environment is ready and inspected, migration-data proposes the merge; it appears here as pass 1.' : 'No runs yet. migration-data proposes the first run (a convert run, or a merge run in a Discourse merge project); it appears here as pass 1.'));
    nodes.push(...data.passes.map((group, i) => passCard(group, i === 0)));
    const preparing = data.preparations || [];
    if (preparing.length) {
      nodes.push(el('h2', {}, 'PREPARATION'), el('p', { class: 'hint' }, 'Preparation jobs are not passes: they neither convert nor import.'),
        ...preparing.map((job) => item(`${safe(job.name)}${job.list ? ` · ${safe(job.list)}` : ''}`,
          [job.delivery, job.run_status ? (['claimed', 'running'].includes(job.run_status) ? `Running: ${job.stage || 'starting'}` : job.run_status.replace('_', ' '))
            : ({ proposed: 'Waiting for your approval', approved: 'Approved: start it', stale: 'Out of date' }[job.plan_status] || job.plan_status), ago(job.at)].filter(Boolean).join(' · '),
          () => (job.run_id ? ctx.open('run', job.run_id) : ctx.open('plan', job.plan_id)))));
    }
    nodes.push(...updatesList(data.updates));
    const conv = data.converter || {};
    nodes.push(el('p', { class: 'hint footer' }, el('button', { type: 'button', class: 'link', onclick: () => ctx.open('converter', ctx.project) },
      conv.error ? 'Converter checkout' : `Converter checkout: ${safe(conv.branch || '?')} · ${conv.not_pushed ?? '?'} commit(s) not on GitHub`)));
    if (status) nodes.push(el('p', { class: 'hint footer', role: 'status' }, status));
    ctx.mount(nodes);
  }

  async function passView(key) {
    const mine = ++ticket;
    ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, 'Loading pass…')]);
    try {
      const data = (await lists.load(listPath())).runs;
      if (mine !== ticket) return;
      if (data.error) throw new Error(data.error);
      board = data;
    } catch (error) {
      if (mine === ticket) ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    const group = board.passes.find((candidate) => candidate.key === key);
    if (!group) { ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, 'This pass is no longer there.')]); return; }
    const before = board.passes.find((candidate) => candidate.number === group.number - 1);
    const changes = [];
    if (before) {
      if (before.delivery !== group.delivery) changes.push(`new data (${group.delivery})`);
      if (isMerge(group) && isMerge(before)) {
        if ((before.layer || {}).sha256 !== (group.layer || {}).sha256) changes.push(`merge layer (${layerLabel(before.layer).replace('merge layer ', '')} → ${layerLabel(group.layer).replace('merge layer ', '')})`);
        if (before.base_site !== group.base_site) changes.push(`Base site (${group.base_site})`);
      } else if (before.converter !== group.converter) changes.push(`converter ${short(before.converter, 7)} → ${short(group.converter, 7)}`);
      if ((before.roles || {}).settings !== (group.roles || {}).settings) changes.push('new settings');
      if ((before.roles || {}).reconciliation !== (group.roles || {}).reconciliation) changes.push('new checks');
    }
    const changed = before ? el('p', { class: 'changed' }, `Changed since pass ${before.number}: `, el('b', {}, changes.length ? changes.join(', ') : 'nothing'), '.') : null;
    const layer = group.layer || {};
    const more = details(facts(isMerge(group)
      ? [['Merge run', group.convert.run_id, true], ['Merge plan', group.convert.plan_id, true],
        ['Prepared environment', group.prepared_from ? `${group.prepared_from.run_id} · ${generationLabel(group.prepared_from)}` : null, true],
        ['Merge layer', layer.present ? layer.path : 'None: Discourse’s own merger only', true],
        ['Layer commit', layer.present ? layer.revision : null, true], ['Layer SHA-256', layer.present ? layer.sha256 : null, true], ['Branch', group.branch, true]]
      : [['Convert run', group.convert.run_id, true], ['Convert plan', group.convert.plan_id, true],
        ...group.imports.map((step, i) => [`Import ${i + 1}`, step.run_id || step.plan_id, true]), ['Converter', group.converter, true], ['Branch', group.branch, true]]));
    ctx.mount([back('Runs', ctx.close), card(`PASS ${group.number} · ${safe(group.delivery || 'DATA NOT LABELLED').toUpperCase()}${group.base_site ? ` ON ${group.base_site.toUpperCase()}` : ''}`, passSay(group), changed,
      el('div', { class: 'steps' }, steps(group)), decideBox(group), passActions(group, true), group.backup_state === 'ready' ? el('p', { class: 'hint' }, 'Release copies the backup and a manifest to this project’s output folder on the server. Nothing is sent anywhere.') : null, releasedDetails(isMerge(group) ? group.convert : group.imports[group.imports.length - 1]), more)]);
  }

  function plan(data) {
    const convert = data.operation === 'standard_convert';
    const review = data.operation === 'standard_review';
    const merge = data.operation === 'standard_merge';
    const master = data.operation === 'standard_master_lists';
    const prepare = data.operation === PREPARE;
    const bound = merge ? data.prepared_from : null;  // a prepared merge binds one exact environment generation
    const merging = merge ? (data.merge || {}) : {};
    const layer = merging.layer || {};
    const onBase = review || merge || prepare;
    const converter = data.converter || {};
    const texts = data.texts || {};
    const unseen = ((convert || master) && texts.settings == null) || (merge && (data.roles || {}).settings && texts.settings == null)
      || ((convert || review) && (data.roles || {}).reconciliation && texts.reconciliation == null);
    const say = data.status === 'proposed' ? `Approve this ${convert ? 'convert run' : review ? 'import' : merge ? (bound ? 'merge in the prepared environment' : 'merge') : master ? 'master-list export (preparation)' : prepare ? 'merge environment preparation (no merge)' : 'run'} on ${dataLabel(data)}${onBase ? ` · ${baseLabel(data.base_site)}` : ''}?`
      : data.status === 'approved' ? 'Approved. Start it when you are ready.' : `This plan is ${data.status === 'stale' ? 'out of date' : data.status.replace('_', ' ')}.`;
    const summary = facts([
      ['Data', el('strong', {}, dataLabel(data))],
      ['Source site', merge ? `Its full backup, with uploads · Discourse ${safe((merging.source || {}).discourse_version || 'unknown')}` : prepare ? 'Its full backup, with uploads' : null],
      ['Base site', onBase ? `${baseLabel(data.base_site)}${data.base_site ? ` · Discourse ${data.base_site.discourse_version}` : ''}${merge || prepare ? ' · the site merged into' : ''}` : null],
      ['Review Discourse', onBase ? runtimeLabel(data.review_runtime) : null],
      ['Prepared environment', bound ? `Run ${short(bound.run_id, 12)} · ${generationLabel(bound)} · exactly this one` : null, true],
      ['Merge rules', merge ? intentLabel(data.intent) : null],
      ['What', convert ? `Converts the data with converters/${data.platform} and checks the counts. Nothing is imported yet.` : review ? 'Imports the converted data into a new local review site and checks the counts there.'
        : merge && bound ? 'Fences inspection access, activates the environment’s clean prepared checkpoint (it does not restore the backups anew), rechecks it, merges the source site into it with Discourse’s own merger, and takes a full backup. No automatic count checks.'
        : merge ? 'Restores the Base site in a new local review site, merges the source site into it with Discourse’s own merger, and takes a full backup. No automatic count checks.'
        : prepare ? PREPARE_WHAT : master ? MASTER_WHAT : operationLabel(data.operation)],
      ['Exporter', master && data.master_lists ? `${safe(data.master_lists.script || '')} · list ${safe(data.master_lists.list || 'all')}` : null, true],
      ['Merge layer', merge ? (layer.present ? `${safe(layer.path)} @ ${short(layer.revision, 12)} · ${layer.files} file${layer.files === 1 ? '' : 's'}` : 'None: Discourse’s own merger only') : null, true],
      ['Merge settings', merge ? ((data.roles || {}).settings ? 'A settings file: shown under Details' : 'None') : null],
      ['Options', merge ? ([(merging.options || {}).ignore_global_pins ? 'ignore globally pinned topics' : null, (merging.options || {}).separate_same_named_groups ? 'keep same-named groups separate' : null].filter(Boolean).join(', ') || 'Discourse’s defaults') : null],
      ['Converter', review || merge || prepare ? null : `${converter.branch || ''} @ ${short(data.converter_revision, 12)}`, true],
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
    if (data.review_runtime) {
      const runtime = data.review_runtime;
      more.push(block('Review runtime', facts([['Image', runtime.image_ref, true], ['Image content', runtime.content_id, true],
        ['Stock digest', runtime.stock_digest, true], ['Core revision', runtime.app_revision, true], ['Core schema', runtime.schema_version, true]])));
    }
    if (review) {
      const source = data.from_run || {};
      more.push(block('Review source', facts([['Source run', source.run_id, true], ['Intermediate SHA-256', source.intermediate_sha256, true], ['Loopback port', ((data.instances || {}).review || {}).port]])));
    }
    if (bound || data.merge_environment) {
      const env = data.merge_environment || {};
      more.push(block('Prepared environment', facts([['Preparation run', (bound || {}).run_id || env.preparation_run_id, true],
        ['Generation', String((bound || env).generation || 'unknown'), true], ['State', data.merge_environment ? phaseLabel(env) : null]])));
    }
    if (merge) {
      more.push(block('Merge', facts([['Source site', `Discourse ${safe((merging.source || {}).discourse_version || '')} · schema ${safe((merging.source || {}).schema_version || '')}`],
        ['Merge layer', layer.present ? layer.path : 'none', true], ['Layer commit', layer.present ? layer.revision : null, true], ['Layer size', layer.present ? `${layer.files} file(s), ${layer.bytes} bytes` : null],
        ['Layer SHA-256', layer.present ? layer.sha256 : null, true], ['Checkout branch', converter.branch, true], ['Loopback port', ((data.instances || {}).review || {}).port]])));
      if ((data.roles || {}).settings) more.push(block('Merge settings (customer values the merge layer reads)', texts.settings == null ? el('p', { class: 'quiet' }, '(not readable, or changed since the plan)') : el('pre', {}, safe(texts.settings))));
    }
    if (convert || master) more.push(block('Converter settings (the run fills in ${SILO_DB_*})', texts.settings == null ? el('p', { class: 'quiet' }, '(not readable, or changed since the plan)') : el('pre', {}, safe(texts.settings))));
    if ((convert || review) && (data.roles || {}).reconciliation) {
      more.push(block('Count checks', texts.reconciliation == null ? el('p', { class: 'quiet' }, '(not readable, or changed since the plan)') : checksView(texts.reconciliation)));
    }
    more.push(block('What it does', el('ul', {}, (data.mutations || []).map((m) => el('li', {}, safe(m))))), block('Not included', el('p', {}, (data.not_included || []).join(', '))));
    const prepared = planSections(data.intake);
    const blocked = !!(prepared && !prepared.ready);
    const actions = [];
    const notReady = blocked ? el('p', { class: 'hint', id: 'plan-not-ready' }, 'Not ready: resolve what is listed under “Needs your answer” (in the migration-data chat), then review the new plan.') : null;
    if (data.status === 'proposed') {
      const question = unseen
        ? `Approve this run of ${ctx.project} on ${dataLabel(data)}${onBase ? ` · ${baseLabel(data.base_site)}` : ''}?\nApproval code ${short(data.digest, 16)}…\nThe settings or checks could NOT be shown here: you approve them by their checksum only.`
        : `Approve ${prepare ? 'preparing the merge environment' : 'this run'} of ${ctx.project} on ${dataLabel(data)}${onBase ? ` · ${baseLabel(data.base_site)}` : ''}?\nApproval code ${short(data.digest, 16)}…\n${prepare ? PREPARE_APPROVAL
          : `${bound ? `It merges in the prepared environment, ${generationLabel(bound)} only. ` : ''}${merge && layer.present ? `It runs the merge layer at commit ${short(layer.revision, 12)} next to the customer data.` : 'It runs exactly what this page shows.'}`}`;
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        if (blocked) return;
        if (await act('approve', { plan_id: data.plan_id, digest: data.digest }, question)) { toast('Approved. Start it when you are ready.'); ctx.refresh(); }
      }, disabled: blocked, 'aria-describedby': blocked ? 'plan-not-ready' : undefined }, 'Approve'));
    }
    if (data.status === 'approved') {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        if (blocked) return;
        const outcome = await act('start', { plan_id: data.plan_id }, `Start this run of ${ctx.project} on ${dataLabel(data)} now? It runs in the background on the server.`);
        if (outcome) { toast('Started.'); ctx.open('run', outcome.run_id); }
      }, disabled: blocked, 'aria-describedby': blocked ? 'plan-not-ready' : undefined }, 'Start'));
    }
    if (['proposed', 'approved', 'stale'].includes(data.status)) {
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('discard', { plan_id: data.plan_id }, `Discard this plan of ${ctx.project}? It can never be approved or run.`)) { toast('Discarded.'); ctx.close(); }
      } }, 'Discard'));
    }
    const notes = [];
    if (data.review_runtime) notes.push(el('p', { class: 'hint' }, 'Chosen automatically for this plan. A replacement Base backup is resolved again for the next plan; existing runs keep their original version. Restore the output on the same or a compatible newer Discourse version.'));
    if (data.review_runtime && data.review_runtime.core_comparison_complete === false && data.base_site) notes.push(el('p', { class: 'note' }, 'The selected version is compatible, but comparison with the current build was unavailable. Core/schema coverage is not fully confirmed; the run still verifies its identity and required runtime migrations.'));
    if (data.review_runtime && data.review_runtime.missing_known_core_migrations > 0) notes.push(el('p', { class: 'note' }, `${data.review_runtime.missing_known_core_migrations} known Base-site core migrations are not in this image. This is a compatibility warning, not a claim of an exact match.`));
    if (prepare) notes.push(el('p', { class: 'note' }, PREPARE_ACCESS));
    if (bound) notes.push(el('p', { class: 'note' }, PREPARED_MERGE(bound)));
    if (merge && layer.present) notes.push(el('p', { class: 'note' },
      `The merge layer is code converter-developer wrote. It runs inside the review site, next to the customer data, exactly as committed at ${short(layer.revision, 12)}. Have converter-reviewer check it before you approve.`));
    if (onBase && data.base_site && data.base_site.ahead) notes.push(el('p', { class: 'note' },
      `The sandbox is on a newer schema (${data.base_site.schema_version}) than this server's Discourse (${data.base_site.site_schema_version}). Normal for hosted sandboxes. It will be restored anyway.`));
    if (data.status === 'stale') notes.push(el('p', { class: 'note' }, 'Something this plan uses changed since it was proposed, so it can\'t run. Discard it and ask migration-data to propose it again.'));
    if (unseen) notes.push(el('p', { class: 'note' }, 'The settings or checks couldn\'t be shown here: an approval would cover them by checksum only.'));
    return [card(data.status === 'proposed' || data.status === 'approved' ? 'FOR YOU' : 'PLAN', say, summary, ...(prepared ? prepared.sections : []), ...notes, actions.length ? el('div', { class: 'actions' }, actions) : null, notReady, details(...more))];
  }

  function checksView(text) {
    let spec = null;
    try { spec = JSON.parse(text); } catch { /* shown as text */ }
    if (!spec || !Array.isArray(spec.checks)) return el('pre', {}, safe(text));
    const destination = spec.checks.some((c) => c.destination_sql);
    return table(['Check', 'Source query', 'Converted query', ...(destination ? ['Site query'] : []), 'Note'],
      spec.checks.map((c) => [safe(c.name), el('code', {}, safe(c.source_sql || '')), el('code', {}, safe(c.intermediate_sql || '')), ...(destination ? [el('code', {}, safe(c.destination_sql || ''))] : []), safe(c.note || '')]));
  }

  // A prepare run's own page: the environment's state and fixed inspection endpoints, then Reset and
  // Run again. Never a backup, release, review URL or admin password: nothing has been merged yet.
  function prepareRun(data) {
    const env = data.merge_environment;
    const phase = (env || {}).phase;
    const say = ['claimed', 'running'].includes(data.status) ? `Preparing: ${data.stage || 'starting'}.`
      : data.status === 'completed' && live(phase) ? 'Prepared. No migration has run. Inspection stays live until a merge or a reset.'
      : data.status === 'completed' ? `Prepared · ${phaseLabel(env)}. No migration ran in this job.`
      : data.status === 'failed' ? `Stopped at ${data.stage || 'a stage'}. Nothing was merged.` : `This preparation is ${data.status.replace('_', ' ')}.`;
    const parts = [];
    if ((data.results || {}).review_runtime) parts.push(block('Pinned Discourse', el('p', {}, safe(runtimeLabel(data.results.review_runtime)))));
    if (data.status === 'completed') {
      parts.push(block('Environment', facts([['State', phaseLabel(env)], ['Generation', env && env.generation ? String(env.generation) : 'unknown'],
        ...(live(phase) ? endpointRows(env) : []), ['Output', 'None: nothing to back up or release before a clean merged result']])));
      if (live(phase)) parts.push(el('p', { class: 'note' }, PREPARE_ACCESS),
        el('p', { class: 'hint' }, 'When migration-data’s questions are answered, it proposes one exact merge plan bound to this generation. You approve and start that separately.'));
    }
    if (data.failure && data.failure.recovery) parts.push(el('p', { class: 'note' }, data.failure.recovery));
    if (data.recovery) parts.push(el('p', { class: 'note' }, data.recovery));
    const actions = [];
    if (['abandoned', 'not_started'].includes(data.status)) {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        if (await act('recover', { run_id: data.run_id }, `Mark this preparation of ${ctx.project} as interrupted? Only do this if its process is gone, for example after a restart. Then reset it.`)) { toast('Marked interrupted.'); ctx.refresh(); }
      } }, 'Recover'));
    }
    const item = { step: { run_id: data.run_id, run_status: data.status }, environment: env };
    const more = envActions(item, true);
    if (RUN_DONE.has(data.status) && (phase === 'reset' || (!env && !data.review_site_available))) parts.push(el('p', { class: 'hint' }, 'Nothing of this environment is left to reset. Evidence and plans stay with the run.'));
    if (more) actions.push(...more.childNodes);
    const details_ = details(facts([['Run', data.run_id, true], ['Plan', data.plan_id, true], ['Started', data.started_at], ['Finished', data.finished_at],
      ['Problem', data.failure ? `${data.failure.code} (stage ${data.failure.stage})` : null, true]]),
    el('div', { class: 'stagelist' }, Object.entries(data.stages || {}).map(([name, status]) => el('span', {}, `${name} `, badge(status)))));
    const eyebrow = ['claimed', 'running'].includes(data.status) ? 'IN PROGRESS' : data.status === 'completed' && !['dirty'].includes(phase) ? 'PREPARED' : 'NEEDS A LOOK';
    return [card(eyebrow, say, ...parts, actions.length ? el('div', { class: 'actions' }, actions) : null, details_)];
  }

  function run(data) {
    if (data.operation === PREPARE) return prepareRun(data);
    const results = data.results || {};
    const rows = Array.isArray(data.reconciliation) ? data.reconciliation : [];
    const destination = rows.some((row) => row.destination != null);
    const bad = rows.filter((row) => row.status !== 'matched');
    const merge = data.operation === 'standard_merge';
    const merged = merge && results.merge && typeof results.merge === 'object' ? results.merge : null;
    const master = data.operation === 'standard_master_lists';
    const say = ['claimed', 'running'].includes(data.status) ? `Running: ${data.stage || 'starting'}.`
      : data.status === 'completed' && master ? 'Master lists exported. This was preparation only: nothing was converted or imported. Using the CSVs needs a new plan.'
      : data.status === 'completed' && merge ? 'Merged. There are no automatic count checks: check the site and the totals.'
      : data.status === 'completed' ? (bad.length ? `${bad.map((row) => safe(row.name)).join(', ')} ${bad.length === 1 ? 'doesn\'t' : 'don\'t'} match.` : rows.length ? 'Finished. Every check matches.' : 'Finished.')
        : data.status === 'failed' ? `Stopped at ${data.stage || 'a stage'}.` : `This run is ${data.status.replace('_', ' ')}.`;
    const parts = [];
    if (results.review_runtime) {
      const runtime = results.review_runtime;
      parts.push(block('Review Discourse', el('p', {}, safe(runtimeLabel(runtime))), details(facts([
        ['Image', runtime.image_ref, true], ['Resolved image', runtime.resolved_image_id, true], ['Image content', runtime.content_id, true],
        ['Core revision', runtime.running_revision || runtime.app_revision, true], ['Schema before restore', runtime.schema_before_restore, true],
        ['Schema after restore', runtime.schema_after_restore, true]]))));
    }
    const backupStep = { kind: merge ? 'merge' : undefined, run_id: data.run_id, run_status: data.status, checks: results.reconciliation_checks || 0,
      matched: results.reconciliation_matched || 0, base_site: data.base_site ? baseLabel(data.base_site) : null,
      base_site_details: data.base_site, backup: (data.artifacts || {}).backup, release: data.release, results,
      backup_state: data.release ? 'released' : (data.artifacts || {}).backup ? 'ready' : 'none' };
    parts.push(...backupRows(backupStep), releasedDetails(backupStep));
    if (rows.length) {
      parts.push(table(['Check', 'Source', 'Converted', ...(destination ? ['Site'] : []), ''],
        rows.map((r) => [safe(r.name), r.source, r.intermediate, ...(destination ? [r.destination] : []), badge(r.status === 'matched' ? 'ok' : 'differs', r.status)]),
        destination ? [1, 2, 3] : [1, 2], (i) => (rows[i].status !== 'matched' ? 'bad' : '')));
    } else if (results.reconciliation_checks !== undefined) parts.push(el('p', { class: 'quiet' }, 'No count checks in this run.'));
    if (merged) {
      // Totals only: how many of each the two sites had and the merged site has. Never names or text.
      const count = (side, key) => (merged[side] && Number.isInteger(merged[side][key]) ? merged[side][key] : '');
      if (merged.target_before || merged.source || merged.after) {
        parts.push(block('Totals', table(['', 'Base site before', 'Source site', 'Merged site'], MERGE_TOTALS.map((key) => [key, count('target_before', key), count('source', key), count('after', key)]), [1, 2, 3]),
          el('p', { class: 'hint' }, 'The merged site rarely has the sum: the merger joins users with the same email, categories and tags with the same name, and identical uploads.')));
      }
      if (Number.isInteger(merged.target_only_columns) && merged.target_only_columns > 0) {
        parts.push(el('p', { class: 'note' }, `${merged.target_only_columns} column(s) exist only on the Base site’s tables (a plugin there adds them). The merger stops if a table it copies has one. migration-data can name them from this run.`));
      }
      const own = Object.entries(merged.layer_totals || {}).filter(([name, value]) => /^[a-z][a-z0-9_]{0,40}$/.test(name) && Number.isInteger(value));
      if (own.length) parts.push(block('Totals the merge layer reported', table(['Total', 'Count'], own.map(([name, value]) => [name, value]), [1])));
    }
    if (data.failure && data.failure.recovery) parts.push(el('p', { class: 'note' }, data.failure.recovery));
    if (data.recovery) parts.push(el('p', { class: 'note' }, data.recovery));
    // Accept only the contracted loopback URL before constructing links or tunnel instructions.
    const reviewURL = /^http:\/\/127[.]0[.]0[.]1:([0-9]{1,5})\/?$/.exec(results.review_url || '');
    if ((data.operation === 'standard_review' || merge) && data.status === 'completed' && reviewURL && Number(reviewURL[1]) > 0 && Number(reviewURL[1]) <= 65535 && data.review_site_available) {
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
      parts.push(block(merge ? 'Merged site' : 'Review site', el('p', {}, 'Open an SSH tunnel with the same port on both sides, then ', el('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, url), ':'),
        el('pre', {}, `ssh -N -L ${port}:127.0.0.1:${port} <your server login>`), show, credentials,
        el('p', { class: 'note' }, 'This site holds customer data until it is reset.')));
    }
    const actions = [];
    const release = releaseButton(backupStep); if (release) actions.push(release);
    if (['abandoned', 'not_started'].includes(data.status)) {
      actions.push(el('button', { type: 'button', class: 'btn', onclick: async () => {
        if (await act('recover', { run_id: data.run_id }, `Mark this run of ${ctx.project} as interrupted? Only do this if its process is gone, for example after a restart. Then reset it.`)) { toast('Marked interrupted.'); ctx.refresh(); }
      } }, 'Recover'));
    }
    // Only offered while there's something to remove: a review site still up, or what a run that
    // didn't finish cleanly may have left. A convert run cleans up after itself when it ends.
    const review = data.operation === 'standard_review' || merge;
    const leftovers = review ? data.review_site_available : data.status !== 'completed';
    if (RUN_DONE.has(data.status) && !leftovers) parts.push(el('p', { class: 'hint' }, review ? 'Its site has been reset. Evidence and backups stay with the run; released backups stay in the output folder.' : 'Nothing to clean up: it tidied up after itself.'));
    if (RUN_DONE.has(data.status) && leftovers) {
      actions.push(el('button', { type: 'button', class: 'btn q', onclick: async () => {
        if (await act('reset', { run_id: data.run_id }, `Reset this run of ${ctx.project}? Its review site, containers and leftovers are removed. Evidence and plans stay. ${resetNote(data.release)}`)) { toast('Reset.'); ctx.refresh(); }
      } }, review ? 'Reset the site' : 'Reset'));
    }
    const more = [facts([['Run', data.run_id, true], ['Plan', data.plan_id, true], ['Started', data.started_at], ['Finished', data.finished_at],
      ['Prepared environment', merge && data.prepared_from ? `${data.prepared_from.run_id} · ${generationLabel(data.prepared_from)}` : null, true],
      ['Problem', data.failure ? `${data.failure.code} (stage ${data.failure.stage})` : null, true], ['Import issues', results.import_issues],
      ...(merged ? [['Columns only the Base site has', merged.target_only_columns], ['Source upload files', merged.source_upload_files], ['Upload files in the backup', merged.archive_upload_files], ['Site settings changed by the merge', merged.site_settings_changed],
        ['Restore proof', merged.restore_proof === 'skipped' ? 'Not run in this version' : merged.restore_proof]] : [])]),
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
    const rewrite = data.rewrite && data.rewrite.mode === 'force-with-lease';
    const say = data.status === 'proposed' ? (rewrite ? 'Push the rebased branch and update its draft PR?' : `Push ${commits.length} commit(s) and open or update the draft PR?`) : data.status === 'superseded' ? 'A newer proposal replaced this one.' : `This push is ${data.status}.`;
    const warning = rewrite ? el('p', { class: 'note' }, 'This replaces this migration branch’s history on GitHub, never main. The push is refused if someone else has moved the branch from the exact remote commit shown below.') : null;
    const summary = facts([['Title', safe(data.title)], ['Branch', `${safe(data.branch)} → ${safe(data.base)}`, true], ['Repository', data.repository],
      ...(rewrite ? [['Upstream main', short(data.rewrite.main_head, 12), true], ['Remote before', short(data.rewrite.expected_remote_head, 12), true], ['New head', short(data.head, 12), true]] : []),
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
        const question = rewrite
          ? `Replace the history of ${data.branch} in ${data.repository}, only if GitHub still has ${data.rewrite.expected_remote_head}, with rebased head ${data.head}, and update its draft PR? Main is never pushed. If the branch moved, nothing is pushed.`
          : `Push ${data.branch} (${short(data.head, 12)}) to ${data.repository} and open a draft PR, with the server's GitHub token for ${owner}?`;
        const outcome = await act('push', { digest: data.digest, ...(rewrite ? { rewrite: true } : {}) }, question);
        if (outcome) { toast(outcome.pull_request && outcome.pull_request.url ? `Pushed; draft PR #${outcome.pull_request.number}.` : 'Pushed.'); ctx.refresh(); }
      } }, data.status === 'proposed' ? (rewrite ? 'Push rebased branch…' : 'Push and open draft PR') : 'Open draft PR'));
      if (data.status === 'proposed') actions.push(discard);
    } else if (data.status === 'superseded') actions.push(discard);
    const more = [facts([['Head', data.head, true], ['Proposed', data.proposed_at], ['Pushed', data.pushed_at], ['Approval code', data.digest, true]]),
      block('PR description', el('pre', {}, safe(data.body || '(empty)'))),
      block(`Files (${data.files_total ?? (data.files || []).length})`, el('pre', {}, (data.files || []).map(safe).join('\n')))];
    if (data.stat) more.push(block('Diff stat', el('pre', {}, safe(data.stat))));
    return [card(data.status === 'proposed' ? 'FOR YOU' : 'CONVERTER PUSH', say, warning, summary, block(`Commits (${commits.length})`, commitList), actions.length ? el('div', { class: 'actions' }, actions) : null, details(...more))];
  }

  function converter(log) {
    return [card('CONVERTER', `${safe(log.branch || 'No branch')} · ${log.not_pushed ?? '?'} commit(s) not on GitHub`,
      facts([['Head', log.head, true], ['Ahead of main', log.ahead_of_main == null ? null : `${log.ahead_of_main} commit(s)`],
        ['Uncommitted', log.uncommitted ? `${log.uncommitted} change(s): converter-developer is working, or files were left behind` : 'none']]),
      el('p', { class: 'note' }, 'Commits reach GitHub only when converter-developer proposes a push and you approve it. Runs use the committed head of this checkout.'),
      details(table(['Commit', 'Subject', 'Author', 'Date', 'GitHub'], (log.commits || []).map((c) => [el('span', { class: 'mono' }, short(c.sha, 10)), safe(c.subject), safe(c.author), (c.date || '').slice(0, 16).replace('T', ' '), c.pushed ? 'pushed' : 'not yet']))))];
  }

  // Accepting a site: the server shows exactly what is frozen (the accepted process), and the
  // acceptance names that (process_digest); anything changed in between is refused.
  async function acceptView(runId) {
    const mine = ++ticket;
    ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, 'Loading…')]);
    let shown;
    try { shown = await api(`api/site/process?${new URLSearchParams({ workspace: ctx.project, id: runId })}`); } catch (error) {
      if (mine === ticket) ctx.mount([back('Runs', ctx.close), el('p', { class: 'quiet' }, explain(error))]);
      return;
    }
    if (mine !== ticket) return;
    const process = shown.process;
    const what = facts([['Data', process.delivery.kind === 'development' ? `Development v${process.delivery.version}` : safe(process.delivery.kind)],
      ['Converter', `${short(process.converter.revision, 7)}${process.converter.branch ? ` on ${safe(process.converter.branch)}` : ''}`],
      ['Settings', process.settings ? 'As this pass used them' : 'None'],
      ['Checks', `${process.results.import.checks} on the site, all matched; ${process.results.convert.checks} in the convert run, all matched`],
      ['Discourse', safe(((process.discourse_profile || '').match(/discourse-([0-9][0-9.]*[0-9])/) || [])[1] || process.discourse_profile || '')]]);
    if (!shown.can_accept) {
      ctx.mount([back('Runs', ctx.close), card('CAN\u2019T BE ACCEPTED', `This site can't be accepted: ${shown.reason}.`, what,
        el('div', { class: 'actions' }, el('button', { type: 'button', class: 'btn q', onclick: () => ctx.open('changes', runId) }, 'Needs changes\u2026')))]);
      return;
    }
    let basis = 'customer';
    const option = (value, title, hint) => {
      const input = el('input', { type: 'radio', name: 'basis', value, checked: value === basis });
      const label = el('label', { class: value === basis ? 'on' : '' }, input, el('span', {}, title, el('small', {}, hint)));
      input.addEventListener('change', () => { basis = value; for (const node of document.querySelectorAll('.choice label')) node.className = node.contains(input) ? 'on' : ''; });
      return label;
    };
    const note = el('textarea', { class: 'note', maxlength: '2000', placeholder: 'For example: approved on the call', 'aria-label': 'Note' });
    const accept = el('button', { type: 'button', class: 'btn', onclick: async () => {
      accept.disabled = true;
      try {
        await api('api/site/review', { workspace: ctx.project, run_id: runId, verdict: 'accepted', basis, note: note.value.trim() || undefined, process_digest: shown.process_digest });
      } catch (error) {
        if (mine !== ticket) return;
        accept.disabled = false;
        toast(explain(error), true);
        return;
      }
      if (mine !== ticket) return;
      board = null;
      done(runId, basis);
    } }, 'Accept');
    ctx.mount([back('Runs', ctx.close), card('ACCEPT, FOR YOU', `Accept this site for ${ctx.project}?`,
      el('div', { class: 'label' }, 'WHAT YOU ACCEPT'), what,
      el('div', { class: 'label' }, 'ON WHAT BASIS'),
      el('div', { class: 'choice' }, option('customer', 'The customer approved it', 'They reviewed it and are happy. This is the process launch will repeat.'),
        option('engineer', 'I checked it myself', 'Your own review. The customer hasn\u2019t seen it yet.')),
      el('div', { class: 'label' }, 'NOTE (OPTIONAL)'), note,
      el('p', { class: 'hint' }, 'Recorded with your name and the time. Launch runs will use exactly this process; anything that changes later is shown before you approve them.'),
      el('div', { class: 'actions' }, accept, el('button', { type: 'button', class: 'btn q', onclick: ctx.close }, 'Cancel')),
      details(facts([['Import run', process.run_id, true], ['Convert run', process.convert_run_id, true], ['Converter', process.converter.revision, true],
        ['Settings', process.settings && process.settings.id, true], ['Checks', process.checks.import && process.checks.import.id, true], ['Process code', short(shown.process_digest, 16), true]])))]);
  }

  // After accepting: the site still holds customer data, so Reset is offered straight away.
  async function done(runId, basis) {
    const mine = ++ticket;
    let up = false;
    let last = null;
    try {
      const data = await api(`api/runs/passes?${new URLSearchParams({ workspace: ctx.project })}`);
      if (mine !== ticket) return;
      board = data;
      last = data.passes.flatMap((group) => group.imports).find((step) => step.run_id === runId);
      up = Boolean(last && last.site_up);
    } catch { /* the Runs list shows it */ }
    if (mine !== ticket) return;
    const reset = up ? el('button', { type: 'button', class: 'btn', onclick: async () => {
      if (await act('reset', { run_id: runId }, `Reset this review site of ${ctx.project}? It holds customer data; evidence and plans stay. ${resetNote(last && last.release)}`)) { toast('Reset.'); ctx.close(); }
    } }, 'Reset the site') : null;
    ctx.mount([back('Runs', ctx.close), card('ACCEPTED', basis === 'customer' ? 'Accepted: this is the process launch will repeat.' : 'Recorded as your own check.',
      el('p', { class: 'hint' }, up ? 'The review site still holds customer data. Reset it now unless you still need it.' : 'Its review site is already gone.'),
      el('div', { class: 'actions' }, reset, el('button', { type: 'button', class: reset ? 'btn q' : 'btn', onclick: ctx.close }, 'Back to Runs')))]);
    ctx.refreshCounts && ctx.refreshCounts();
  }

  function changesView(runId) {
    const mine = ++ticket;
    const note = el('textarea', { class: 'note tall', maxlength: '2000', placeholder: 'For example: quoted replies show raw markup; avatars are missing', 'aria-label': 'What needs changing' });
    const save = el('button', { type: 'button', class: 'btn', disabled: true, onclick: async () => {
      save.disabled = true;
      try {
        await api('api/site/review', { workspace: ctx.project, run_id: runId, verdict: 'needs_changes', note: note.value.trim() });
      } catch (error) {
        if (mine !== ticket) return;
        save.disabled = false;
        toast(explain(error), true);
        return;
      }
      if (mine !== ticket) return;
      board = null;
      toast('Saved. Ask migration-data in a chat in this project: "What\u2019s next?"');
      ctx.close();
    } }, 'Save');
    note.addEventListener('input', () => { save.disabled = !note.value.trim(); });
    ctx.mount([back('Runs', ctx.close), card('NEEDS CHANGES', 'What needs changing on this site?', note,
      el('p', { class: 'hint' }, 'Stays on this server. migration-data reads it in a chat in this project and works out the fix with you. The site stays up until you Reset it.'),
      el('div', { class: 'actions' }, save, el('button', { type: 'button', class: 'btn q', onclick: ctx.close }, 'Cancel')))]);
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

  return { cancel: () => { ++ticket; }, reset: () => { ++ticket; board = null; },
    show: () => (!ctx.selected ? list() : ctx.selected.kind === 'pass' ? passView(ctx.selected.id)
    : ctx.selected.kind === 'accept' ? acceptView(ctx.selected.id) : ctx.selected.kind === 'changes' ? changesView(ctx.selected.id)
      : detail(ctx.selected.kind, ctx.selected.id)) };
}
