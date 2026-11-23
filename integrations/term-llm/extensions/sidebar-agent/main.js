const ROW = ".session-row";
const META = ":scope > .session-btn > .session-meta";
const LABEL_HOST = ".session-row[data-session-id][data-session-agent]:not(.session-row-draft)";
const colors = new Map([["developer", "violet"], ["work", "amber"], ["codebase", "teal"]]);

function colorFor(agent) {
  if (colors.has(agent)) return colors.get(agent);
  const palette = ["violet", "amber", "teal", "blue", "rose"];
  let hash = 0;
  for (const letter of agent) hash = (Math.imul(hash, 31) + letter.codePointAt(0)) >>> 0;
  return palette[hash % palette.length];
}

export function activate(ui) {
  const originalRoot = ui?.root;
  if (!(originalRoot instanceof HTMLElement)) return;
  const doc = originalRoot.ownerDocument;
  const owned = new Map();
  let disposed = false;
  let frame = 0;
  const root = () => ui.root?.isConnected ? ui.root
    : originalRoot.id ? doc.getElementById(originalRoot.id) : null;

  function observe() {
    observer.observe(doc.documentElement, {
      childList: true, subtree: true, attributes: true,
      attributeFilter: ["data-session-id", "data-session-agent"],
    });
  }

  function reconcile() {
    frame = 0;
    if (disposed) return;
    observer.disconnect(); // Our own insertions should never trigger a new scan.
    try {
      const rows = new Set();
      for (const row of root()?.querySelectorAll(LABEL_HOST) ?? []) {
        const agent = row.getAttribute("data-session-agent").trim();
        const id = row.getAttribute("data-session-id").trim();
        const meta = row.querySelector(META);
        if (!id || !agent || !meta) continue;
        rows.add(row);
        let entry = owned.get(row);
        if (!entry) {
          const prefix = doc.createElement("span");
          prefix.className = "sidebar-agent-prefix";
          const label = doc.createElement("bdi");
          label.className = "sidebar-agent-label";
          const separator = doc.createElement("span");
          separator.setAttribute("aria-hidden", "true");
          separator.textContent = " · ";
          prefix.append(label, separator);
          entry = { prefix, label };
          owned.set(row, entry);
        }
        if (entry.label.textContent !== agent) {
          entry.label.textContent = agent;
          entry.label.title = agent;
          entry.label.dataset.color = colorFor(agent);
        }
        if (meta.firstChild !== entry.prefix) meta.prepend(entry.prefix);
      }
      for (const [row, { prefix }] of owned) {
        if (rows.has(row)) continue;
        prefix.remove();
        owned.delete(row);
      }
    } finally {
      if (!disposed) observe();
    }
  }

  const observer = new MutationObserver((records) => {
    if (disposed || frame) return;
    // Ignore unrelated UI churn (notably streaming messages). A moved/replaced
    // row or sidebar still appears in a child-list mutation somewhere above it.
    const containsRow = (node) => node.nodeType === 1 && (node.matches(ROW) || node.querySelector(ROW));
    if (records.some((m) => m.type === "attributes" || m.target.closest?.(ROW)
      || Array.from(m.addedNodes).some(containsRow) || Array.from(m.removedNodes).some(containsRow))) {
      frame = requestAnimationFrame(reconcile);
    }
  });
  reconcile();
  return () => {
    if (disposed) return;
    disposed = true;
    observer.disconnect();
    cancelAnimationFrame(frame);
    for (const { prefix } of owned.values()) prefix.remove();
    owned.clear();
  };
}
