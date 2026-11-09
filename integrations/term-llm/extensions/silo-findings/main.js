// One tab on the right edge, with a small panel of links into the Project page:
//   Project · N   projects with files to label, findings to review, or plans and pushes waiting
// It only reads (GET api/summary, signed in by the web UI's own cookie); every decision happens on
// the Project page. No finding text, file names, settings or counts are shown here.
// (The extension keeps its old name, so the web service's --extensions list stays as installed.)
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
    tooltip: (_data, n) => (n ? `${n} project(s) with something waiting for you` : 'Open the Project page'),
    heading: (_data, n) => (n ? 'Waiting for you' : 'Nothing waiting'),
    items: (data) => ((data && data.latest) || []).map((item) => ({ text: `${item.workspace} · ${item.files} waiting`, hash: `#project=${encodeURIComponent(item.workspace)}`, at: '' })),
    more: () => 'Open the Project page…',
  });
}
