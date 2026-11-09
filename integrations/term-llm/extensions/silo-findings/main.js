// Two tabs on the right edge, each with a small panel of links into its widget:
//   Findings · N   findings waiting for review (widgets/findings)
//   Runs · N       plans to approve or start and converter pushes waiting (widgets/runs)
// They only read (GET api/summary, signed in by the web UI's own cookie); every decision
// happens in the widgets. No finding text, settings or counts are shown here.
// (One extension for both, so the web service's --extensions list stays as installed.)
const POLL_MS = 60_000;

function age(iso) {
  const minutes = Math.max(0, (Date.now() - Date.parse(iso)) / 60000);
  return minutes < 90 ? `${Math.round(minutes)} min ago` : minutes < 2160 ? `${Math.round(minutes / 60)} h ago` : new Date(iso).toLocaleDateString();
}

function edgeTab(ui, spec) {
  const widget = () => `${(ui.getContext().prefix || '').replace(/\/+$/, '')}/widgets/${spec.mount}/`;
  const tab = document.createElement('button');
  tab.type = 'button';
  tab.className = `${spec.className}-tab`;
  tab.hidden = true;
  const panel = document.createElement('aside');
  panel.className = `${spec.className}-panel`;
  panel.hidden = true;
  ui.mount.append(tab, panel);
  let last = null;

  const link = (text, hash) => {
    const anchor = document.createElement('a');
    anchor.href = widget() + hash;
    anchor.target = '_blank';
    anchor.rel = 'noopener';
    anchor.textContent = text;
    return anchor;
  };

  const render = () => {
    const pending = spec.count(last);
    tab.textContent = pending ? `${spec.label} · ${pending}` : spec.label;
    tab.classList.toggle('has-pending', pending > 0);
    tab.title = spec.tooltip(last, pending);
    const heading = document.createElement('h2');
    heading.textContent = spec.heading(last, pending);
    const list = document.createElement('ul');
    for (const item of spec.items(last)) {
      const entry = document.createElement('li');
      entry.append(link(item.text, item.hash));
      const when = document.createElement('span');
      when.textContent = item.at ? age(item.at) : '';
      entry.append(when);
      list.append(entry);
    }
    const more = document.createElement('p');
    more.append(link(spec.more(last, pending), ''));
    panel.replaceChildren(heading, list, more);
  };

  const refresh = async () => {
    try {
      const response = await fetch(`${widget()}api/summary`, { credentials: 'same-origin', headers: { Accept: 'application/json' } });
      if (!response.ok) throw new Error(String(response.status));
      last = await response.json();
      tab.hidden = false;
      render();
    } catch {
      tab.hidden = true;   // widget unavailable (or not signed in yet): stay out of the way
      panel.hidden = true;
    }
  };

  tab.addEventListener('click', () => {
    panel.hidden = !panel.hidden;
    if (!panel.hidden) refresh();
  });
  document.addEventListener('keydown', (event) => { if (event.key === 'Escape') panel.hidden = true; });
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh(); });
  ui.onSessionChanged(() => refresh());
  setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  refresh();
}

const hashFor = (workspace, extra) => `#ws=${encodeURIComponent(workspace)}${extra}`;

export function activate(ui) {
  edgeTab(ui, {
    mount: 'project', className: 'silo-project', label: 'Project',
    count: (data) => (data ? data.waiting : 0),
    tooltip: (_data, n) => (n ? `${n} project(s) with new files to label` : 'Open a project'),
    heading: (_data, n) => (n ? 'New files to label' : 'Projects'),
    items: (data) => ((data && data.latest) || []).map((item) => ({ text: `${item.workspace} · ${item.files} new file(s)`, hash: `#project=${encodeURIComponent(item.workspace)}&tab=files`, at: '' })),
    more: () => 'Open the Project page…',
  });
  edgeTab(ui, {
    mount: 'findings', className: 'silo-findings', label: 'Findings',
    count: (data) => (data ? data.pending : 0),
    tooltip: (_data, n) => (n ? `${n} finding(s) waiting for your review` : 'No findings waiting; open the history'),
    heading: (_data, n) => (n ? 'Findings to review' : 'No findings to review'),
    items: (data) => ((data && data.latest) || []).map((item) => ({
      text: `${item.workspace} · ${item.kind}`, hash: hashFor(item.workspace, `&id=${encodeURIComponent(item.id)}`), at: item.proposed_at })),
    more: (data, n) => (n > ((data && data.latest.length) || 0) ? 'All findings to review…' : 'Open findings and history…'),
  });
  const WHAT = { plan: { proposed: 'plan to approve (or discard)', approved: 'approved: start it' }, push: { proposed: 'push to approve' } };
  edgeTab(ui, {
    mount: 'runs', className: 'silo-runs', label: 'Runs',
    count: (data) => (data ? data.waiting : 0),
    tooltip: (data, n) => (n ? `${n} plan(s) or push(es) waiting for you` : data && data.running ? `${data.running} run(s) in progress` : 'Nothing waiting; open runs'),
    heading: (data, n) => (n ? 'Waiting for you' : data && data.running ? 'Runs in progress' : 'Nothing waiting'),
    items: (data) => [
      ...((data && data.latest) || []).map((item) => ({
        text: `${item.workspace} · ${(WHAT[item.kind] || {})[item.status] || item.kind}`,
        hash: hashFor(item.workspace, `&kind=${item.kind}&id=${encodeURIComponent(item.id)}`), at: item.at })),
      ...((data && data.active) || []).map((item) => ({
        text: `${item.workspace} · running${item.stage ? ` (${item.stage})` : ''}`,
        hash: hashFor(item.workspace, `&kind=run&id=${encodeURIComponent(item.id)}`), at: item.at })),
    ],
    more: () => 'Open runs…',
  });
}
