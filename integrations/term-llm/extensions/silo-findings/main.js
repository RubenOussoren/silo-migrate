// Summary-only navigation: names and waiting counts, never findings or file contents.
// Keep the installed extension ID; all decisions still happen on the Project page.
const POLL_MS = 60_000;
const destination = { mount: 'project' };
const instances = new WeakMap();
let nextPanelID = 0;

export function activate(ui) {
  instances.get(ui.mount)?.();
  const root = ui.root;
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'silo-project-button';
  button.hidden = true;
  button.setAttribute('aria-haspopup', 'dialog');
  button.setAttribute('aria-expanded', 'false');
  const panel = document.createElement('section');
  panel.className = 'silo-project-panel';
  panel.id = `silo-project-panel-${++nextPanelID}`;
  panel.hidden = true;
  panel.tabIndex = -1;
  panel.setAttribute('role', 'dialog');
  panel.setAttribute('aria-label', 'Migration projects');
  button.setAttribute('aria-controls', panel.id);
  const heading = document.createElement('h2');
  const closeButton = document.createElement('button');
  closeButton.type = 'button';
  closeButton.className = 'silo-project-close';
  closeButton.textContent = '×';
  closeButton.setAttribute('aria-label', 'Close migration projects');
  const list = document.createElement('ul');
  const footer = document.createElement('p');
  panel.append(closeButton, heading, list, footer);
  ui.mount.append(panel);

  let disposed = false;
  let inFlight = null;
  let controller = null;
  let frame = 0;
  let summary = null;
  let summaryURL = '';
  let attachedRow = null;
  const listeners = [];
  const listen = (target, event, callback, options) => {
    target.addEventListener(event, callback, options);
    listeners.push(() => target.removeEventListener(event, callback, options));
  };
  const widget = () => `${(ui.getContext().prefix || '').replace(/\/+$/, '')}/widgets/${destination.mount}/`;
  const close = (restoreFocus = false) => {
    const wasOpen = !panel.hidden;
    panel.hidden = true;
    button.setAttribute('aria-expanded', 'false');
    if (wasOpen && restoreFocus && button.isConnected && !button.hidden) button.focus({ preventScroll: true });
  };
  const position = () => {
    if (panel.hidden) return;
    if (!button.isConnected || button.hidden) { close(); return; }
    const viewport = window.visualViewport;
    const x = viewport?.offsetLeft || 0;
    const y = viewport?.offsetTop || 0;
    const width = viewport?.width || window.innerWidth;
    const height = viewport?.height || window.innerHeight;
    const rect = button.getBoundingClientRect();
    const inset = 8;
    const gap = 8;
    panel.style.width = `${Math.max(0, Math.min(340, width - inset * 2))}px`;
    const below = Math.max(0, y + height - inset - rect.bottom - gap);
    const above = Math.max(0, rect.top - gap - y - inset);
    const upwards = below < 180 && above > below;
    panel.style.maxHeight = `${Math.min(height - inset * 2, upwards ? above : below)}px`;
    const size = panel.getBoundingClientRect();
    panel.style.left = `${Math.max(x + inset, Math.min(rect.right - size.width, x + width - inset - size.width))}px`;
    panel.style.top = `${Math.max(y + inset, Math.min(upwards ? rect.top - gap - size.height : rect.bottom + gap, y + height - inset - size.height))}px`;
  };
  const schedulePosition = () => { if (!frame && !disposed) frame = requestAnimationFrame(() => { frame = 0; position(); }); };
  const resizeObserver = new ResizeObserver(schedulePosition);
  const ensureButton = () => {
    const row = root.querySelector('.main-header .header-controls-row');
    const restoreFocus = row !== attachedRow && panel.contains(document.activeElement);
    if (row !== attachedRow) {
      close();
      resizeObserver.disconnect();
      attachedRow = row;
      if (row) {
        resizeObserver.observe(row);
        resizeObserver.observe(button);
      }
    }
    // Append our own element only. Never move or rebuild Preact-owned children.
    if (row && button.parentElement !== row) row.append(button);
    if (restoreFocus && row && !button.hidden) button.focus({ preventScroll: true });
    if (!row) { button.remove(); close(); }
    schedulePosition();
  };
  const link = (text, hash = '') => {
    const anchor = document.createElement('a');
    anchor.href = widget() + hash;
    anchor.target = '_blank';
    anchor.rel = 'noopener';
    anchor.textContent = text;
    return anchor;
  };
  const render = () => {
    const waiting = Number.isSafeInteger(summary?.waiting) && summary.waiting > 0 ? summary.waiting : 0;
    button.textContent = 'Project';
    if (waiting) {
      const badge = document.createElement('span');
      badge.className = 'silo-project-count';
      badge.textContent = String(waiting);
      badge.setAttribute('aria-hidden', 'true');
      button.append(badge);
    }
    button.classList.toggle('has-pending', waiting > 0);
    button.title = waiting ? `${waiting} project(s) with something waiting for you` : 'Open the Project page';
    button.setAttribute('aria-label', `Migration projects${waiting ? `, ${waiting} waiting` : ''}`);
    heading.textContent = waiting ? 'Waiting for you' : 'Nothing waiting';
    // Reconcile links so an in-flight refresh cannot discard keyboard focus.
    const entries = Array.isArray(summary?.latest) ? summary.latest : [];
    const old = new Map([...list.children].map((entry) => [entry.dataset.workspace, entry]));
    let index = 0;
    for (const item of entries) {
      if (typeof item.workspace !== 'string') continue;
      let entry = old.get(item.workspace);
      old.delete(item.workspace);
      if (!entry) {
        entry = document.createElement('li');
        entry.dataset.workspace = item.workspace;
        entry.append(link(''));
      }
      const anchor = entry.firstElementChild;
      const count = Number.isSafeInteger(item.files) && item.files >= 0 ? item.files : 0;
      anchor.textContent = `${item.workspace} · ${count} waiting`;
      anchor.href = widget() + `#project=${encodeURIComponent(item.workspace)}`;
      if (list.children[index] !== entry) list.insertBefore(entry, list.children[index] || null);
      index++;
    }
    for (const entry of old.values()) {
      if (entry.contains(document.activeElement)) closeButton.focus({ preventScroll: true });
      entry.remove();
    }
    if (!footer.firstChild) footer.append(link('Open the Project page ↗'));
    footer.firstChild.href = widget();
    button.hidden = false;
    schedulePosition();
  };
  const refresh = () => {
    if (disposed) return Promise.resolve();
    const url = `${widget()}api/summary`;
    if (inFlight && summaryURL === url) return inFlight;
    controller?.abort();
    controller = new AbortController();
    const request = controller;
    summaryURL = url;
    inFlight = (async () => {
      try {
        const response = await fetch(url, { credentials: 'same-origin', headers: { Accept: 'application/json' }, signal: request.signal });
        if (!response.ok) throw new Error(String(response.status));
        const data = await response.json();
        if (disposed || request.signal.aborted || url !== `${widget()}api/summary`) return;
        summary = data;
        render();
      } catch {
        if (disposed || request.signal.aborted) return;
        close(panel.contains(document.activeElement));
        button.hidden = true; // unavailable or signed out: do not show stale summary
        summary = null;
      } finally {
        if (controller === request) inFlight = null;
      }
    })();
    return inFlight;
  };
  listen(button, 'click', () => {
    if (!panel.hidden) { close(true); return; }
    panel.hidden = false;
    button.setAttribute('aria-expanded', 'true');
    position();
    closeButton.focus({ preventScroll: true });
    refresh();
  });
  listen(closeButton, 'click', () => close(true));
  listen(document, 'keydown', (event) => {
    if (event.key === 'Escape' && !panel.hidden) { event.preventDefault(); close(true); }
  });
  listen(document, 'pointerdown', (event) => {
    if (!panel.hidden && !panel.contains(event.target) && !button.contains(event.target)) close(panel.contains(document.activeElement));
  });
  listen(document, 'focusin', (event) => {
    if (!panel.hidden && !panel.contains(event.target) && event.target !== button) close();
  });
  listen(document, 'visibilitychange', () => { if (!document.hidden) refresh(); });
  listen(window, 'resize', schedulePosition);
  listen(window, 'scroll', schedulePosition, true);
  if (window.visualViewport) {
    listen(window.visualViewport, 'resize', schedulePosition);
    listen(window.visualViewport, 'scroll', schedulePosition);
  }
  // Observe structural changes only, and ignore transcript streaming / our own rendering.
  const observer = new MutationObserver((records) => {
    if (records.some(({ target, addedNodes, removedNodes }) =>
      !panel.contains(target) && !button.contains(target) &&
      !(target instanceof Element && target.closest('.messages')) &&
      (target === root || (target instanceof Element && target.closest('.main-header')) ||
       [...addedNodes, ...removedNodes].some((node) => node instanceof Element &&
         (node.matches('.main-header, .header-controls-row') || node.querySelector('.main-header, .header-controls-row')))))) ensureButton();
  });
  observer.observe(root, { childList: true, subtree: true });
  const interval = setInterval(() => { if (!document.hidden) refresh(); }, POLL_MS);
  const unsubscribe = ui.onSessionChanged(() => refresh()); // 0.9.99 invokes immediately
  ensureButton();
  refresh();
  const dispose = () => {
    if (disposed) return;
    disposed = true;
    controller?.abort();
    clearInterval(interval);
    cancelAnimationFrame(frame);
    unsubscribe?.();
    observer.disconnect();
    resizeObserver.disconnect();
    for (const remove of listeners) remove();
    button.remove();
    panel.remove();
    instances.delete(ui.mount);
  };
  // 0.9.99 reloads the document on extension changes (no host cleanup hook).
  // Also return a disposer for harnesses/future hosts and release it on page teardown.
  listen(window, 'pagehide', (event) => { if (!event.persisted) dispose(); });
  instances.set(ui.mount, dispose);
  return dispose;
}
