// A tab on the right edge: how many findings wait for review, and links into the Findings
// widget. It only reads (GET api/summary, signed in by the web UI's own cookie); every
// decision happens in the widget. No finding text is shown here.
const POLL_MS = 60_000;

export function activate(ui) {
  const widget = () => `${(ui.getContext().prefix || '').replace(/\/+$/, '')}/widgets/findings/`;
  const tab = document.createElement('button');
  tab.type = 'button';
  tab.className = 'silo-findings-tab';
  tab.hidden = true;
  const panel = document.createElement('aside');
  panel.className = 'silo-findings-panel';
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

  const age = (iso) => {
    const minutes = Math.max(0, (Date.now() - Date.parse(iso)) / 60000);
    return minutes < 90 ? `${Math.round(minutes)} min ago` : minutes < 2160 ? `${Math.round(minutes / 60)} h ago` : new Date(iso).toLocaleDateString();
  };

  const render = () => {
    const pending = last ? last.pending : 0;
    tab.textContent = pending ? `Findings · ${pending}` : 'Findings';
    tab.classList.toggle('has-pending', pending > 0);
    tab.title = pending ? `${pending} finding(s) waiting for your review` : 'No findings waiting; open the history';
    const heading = document.createElement('h2');
    heading.textContent = pending ? 'Findings to review' : 'No findings to review';
    const list = document.createElement('ul');
    for (const item of (last && last.latest) || []) {
      const entry = document.createElement('li');
      entry.append(link(`${item.workspace} · ${item.kind}`, `#ws=${encodeURIComponent(item.workspace)}&id=${encodeURIComponent(item.id)}`));
      const when = document.createElement('span');
      when.textContent = item.proposed_at ? age(item.proposed_at) : '';
      entry.append(when);
      list.append(entry);
    }
    const more = document.createElement('p');
    more.append(link(pending > ((last && last.latest.length) || 0) ? 'All findings to review…' : 'Open findings and history…', ''));
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
