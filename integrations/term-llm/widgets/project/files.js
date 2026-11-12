// Role-aware Files decisions. Server previews are the authority; commits never retry themselves.
import { el, safe, api, explain, card, facts, details } from './ui.js';
import { usageBlock, copyRequest } from './intake.js';

const ROLES = [['source', 'Source export / backup'], ['uploads', 'Uploads / assets'], ['reference', 'Supporting reference'], ['base_site', 'Base-site backup']];
const label = snapshot => safe(snapshot.label || `${snapshot.kind === 'launch' ? 'Launch' : snapshot.kind === 'base_site' ? 'Base site' : 'Development'} v${snapshot.version ?? snapshot.revision ?? '?'}`);
const describe = value => safe(typeof value === 'string' ? value : JSON.stringify(value));
const button = (text, onclick, attrs = {}) => el('button', { type: 'button', class: 'btn q', onclick, ...attrs }, text);
const snapshots = files => files.roles?.snapshots || [];
export function currentSnapshot(files, kind) {
  if (files?.roles) {
    const id = files.roles.active?.[kind];
    return snapshots(files).find(s => s.dataset_id === id) || null;
  }
  return (files?.deliveries || []).find(s => s.kind === kind && !s.replaced_by) || null;
}

export function filesView(ctx) {
  let editor = null, nodes = null, listing = null, listingKey = null;
  const reset = () => { editor = null; nodes = null; listing = null; listingKey = null; };
  function leaving() {
    if (!editor) return true;
    if (editor.working) return false;
    if (!confirm('Discard this file assignment form and preview?')) return false;
    reset(); return true;
  }
  function redraw() { nodes = null; ctx.render(); }
  function open(action, selected = [], defaults = {}) {
    editor = { action, selected, role: 'reference', kind: 'development', dataset_id: '', restore: '', reason: '', launch: '', preview: null, error: null, working: false, ...defaults };
    redraw();
  }
  function renderEditor(files) {
    if (nodes) return nodes;
    const e = editor, project = ctx.project;
    const alive = () => editor === e && ctx.project === project;
    const set = (key, value) => { e[key] = value; e.preview = null; e.error = null; redraw(); };
    const select = (name, value, choices, change) => {
      const control = el('select', { 'aria-label': name, disabled: e.working }, choices.map(([id, text]) => el('option', { value: id }, text)));
      control.value = value;
      control.addEventListener('change', () => change(control.value));
      return el('label', { class: 'file-field' }, name, control);
    };
    const available = snapshots(files).filter(s => ['development', 'launch'].includes(s.kind) && s.eligible !== false);
    const snapshotChoices = [['', 'Choose a source snapshot…'], ...available.map(s => [s.dataset_id, `${label(s)} · ${s.dataset_id}`])];
    const form = [];
    if (e.action === 'classify') {
      form.push(el('p', { class: 'hint' }, 'Select only files with the same role. No incoming files are selected by default.'));
      const hidden = (files.counts?.unlabelled || 0) - (files.unlabelled_files || []).length;
      if (hidden > 0) form.push(el('p', { class: 'hint' }, `${hidden} more incoming files are not shown. Assign this batch first, then review the remaining files.`));
      form.push(el('div', { class: 'files' }, (files.unlabelled_files || []).map(file => {
        const box = el('input', { type: 'checkbox', checked: e.selected.some(f => f.path === file.path), disabled: e.working, 'aria-label': `Select ${safe(file.path)}` });
        box.addEventListener('change', () => { e.selected = box.checked ? [...e.selected, file] : e.selected.filter(f => f.path !== file.path); e.preview = null; redraw(); });
        return el('label', { class: 'file' }, el('span', {}, box, ' ', safe(file.path)), `${file.bytes ?? '?'} bytes`);
      })));
    } else if (e.action === 'correct') {
      form.push(el('h3', {}, 'Selected immutable files'), ...e.selected.map(file => facts([['File', safe(file.path)], ['Identity', file.id, true], ['Current role', file.role], ['Checksum', file.sha256, true]])));
    }
    if (e.action !== 'activate') {
      form.push(select('File role', e.role, e.action === 'correct' ? [...ROLES.filter(([role]) => ['reference', 'uploads'].includes(role)), ['unassigned', 'Unassigned']] : ROLES, v => set('role', v)));
      if (e.role === 'source') form.push(select('Snapshot purpose', e.kind, [['development', 'Development — new source snapshot'], ['launch', 'Launch — new source snapshot']], v => set('kind', v)));
      if (e.role === 'uploads') form.push(select('Associate uploads with snapshot', e.dataset_id, snapshotChoices, v => set('dataset_id', v)));
      if (e.role === 'reference') form.push(el('p', { class: 'hint' }, 'Private project reference. Does not replace source data or silently enter run inputs/settings. Existing references are not replaced.'));
      if (e.role === 'uploads') form.push(el('p', { class: 'hint' }, 'Stored—not included by this workflow. Adding assets does not create a new source snapshot.'));
      if (e.role === 'base_site') form.push(el('p', { class: 'hint' }, 'Independent target baseline: original SQL-only Base-site backup. Preview any replacement before confirming.'));
      if (e.action === 'correct') {
        const baseCorrection = e.selected.some(file => file.role === 'base_site');
        const selectedSnapshots = new Set(snapshots(files).filter(snapshot => (snapshot.files || []).some(file => e.selected.some(selected => selected.id === file.id))).map(snapshot => snapshot.dataset_id));
        const restoreChoices = snapshots(files).filter(snapshot => snapshot.eligible !== false && !selectedSnapshots.has(snapshot.dataset_id) && (baseCorrection ? snapshot.kind === 'base_site' : ['development', 'launch'].includes(snapshot.kind)));
        form.push(select(baseCorrection ? 'Restore current Base snapshot (optional)' : 'Restore current source snapshot (optional)', e.restore,
          [['', 'Do not restore another snapshot'], ...restoreChoices.map(snapshot => [snapshot.dataset_id, label(snapshot)])], v => set('restore', v)));
        form.push(el('p', { class: 'hint' }, 'If this removes the last primary file from the current snapshot without restoring another, the preview will show the cleared selection. Original bytes and history are retained.'));
      }
    } else form.push(el('p', {}, `Make ${label(e.snapshot)} (${e.dataset_id}) current. Its immutable files and completed-run history remain unchanged.`));
    const associated = snapshots(files).find(s => s.dataset_id === e.dataset_id);
    const restored = snapshots(files).find(s => s.dataset_id === e.restore);
    const correctingLaunch = e.action === 'correct' && snapshots(files).some(s => s.kind === 'launch' && (s.files || []).some(f => e.selected.some(selected => selected.id === f.id)));
    const launchRequired = (e.role === 'source' && e.kind === 'launch') || (e.action === 'activate' && e.snapshot.kind === 'launch') || (e.role === 'uploads' && associated?.kind === 'launch') || restored?.kind === 'launch' || correctingLaunch;
    const textField = (name, key, tag = 'input') => {
      const control = el(tag, { 'aria-label': name, value: e[key], disabled: e.working, autocomplete: 'off' });
      control.addEventListener('input', () => { e[key] = control.value; e.preview = null; e.error = null; previewArea.replaceChildren(); previewButton.disabled = !valid(); });
      return el('label', { class: 'file-field' }, name, control);
    };
    if (e.action !== 'classify') form.push(textField('Reason for this change (required)', 'reason', 'textarea'));
    if (launchRequired) form.push(textField('Type LAUNCH to confirm', 'launch'));
    const valid = () => !e.working && (e.action === 'activate' || e.selected.length > 0) && (e.action === 'classify' || e.reason.trim()) && (e.role !== 'uploads' || e.dataset_id) && (!launchRequired || e.launch === 'LAUNCH');
    const previewArea = el('div', { class: 'file-preview', 'aria-live': 'polite' });
    const previewButton = button('Preview assignment', async () => {
      if (!valid()) return;
      const change = { action: e.action };
      if (e.action === 'classify') change.files = e.selected.map(file => Object.fromEntries(['path', 'bytes', 'mtime_ns', 'ctime_ns', 'ino'].map(key => [key, file[key]])));
      if (e.action === 'correct') change.file_ids = e.selected.map(f => f.id);
      if (e.action !== 'activate') change.role = e.role;
      if (e.action !== 'activate' && e.role === 'source') change.kind = e.kind;
      if (e.action === 'activate' || e.role === 'uploads') change.dataset_id = e.dataset_id;
      if (e.action === 'correct' && e.restore) change.restore_dataset_id = e.restore;
      if (e.action !== 'classify') change.reason = e.reason.trim();
      if (launchRequired) change.confirm = 'LAUNCH';
      e.working = true; e.preview = null; e.error = null; redraw();
      try {
        await ctx.settleReads();
        const preview = await api('api/files/preview', { workspace: project, change });
        if (alive()) e.preview = preview;
      } catch (error) { if (alive()) e.error = explain(error); }
      finally { if (alive()) { e.working = false; redraw(); } }
    }, { disabled: !valid() });
    const p = e.preview;
    if (p) {
      const activeText = active => ['development', 'launch', 'base_site'].map(kind => {
        const id = active?.[kind];
        const s = snapshots(files).find(s => s.dataset_id === id);
        return `${kind}: ${id ? `${s ? label(s) + ' · ' : ''}${id}` : 'none'}`;
      }).join('\n');
      previewArea.append(el('h3', {}, 'Assignment preview'), facts([['Previous current', activeText(p.before_active)], ['New current', activeText(p.after_active)], ['Proposed assignment', describe(p.change)], ['Revision', p.revision], ['Preview digest', p.digest, true]]),
        el('p', {}, 'File identities, bytes and checksums remain unchanged. Completed-run history and releases are not rewritten.'),
        ...((p.files || []).map(f => facts([['File', safe(f.path)], ['Identity', f.id, true], ['Bytes', f.bytes], ['Checksum', f.sha256, true], ['Current assignment', describe(f)]]))));
      for (const [key, title] of [['pending', 'Pending approvals to invalidate'], ['active', 'Active dependencies'], ['completed', 'Completed runs — historical bindings retained'], ['releases', 'Releases — historical bindings retained']]) {
        previewArea.append(el('h4', {}, title), ...((p.impacts?.[key] || []).length ? p.impacts[key].map(x => el('pre', {}, describe(x))) : [el('p', { class: 'hint' }, 'None reported.')]));
      }
      for (const warning of p.warnings || []) previewArea.append(el('p', { class: 'hint' }, describe(warning)));
      for (const blocker of p.blocked || []) previewArea.append(el('p', { class: 'error' }, `Blocked: ${describe(blocker)}`));
      let acknowledged = false;
      const commit = button('Confirm assignment', async () => {
        if (!acknowledged || e.working || e.preview !== p || p.blocked?.length || !p.digest) return;
        e.working = true; redraw();
        try {
          await ctx.settleReads();
          await api('api/files/commit', { workspace: project, change: p.change, digest: p.digest });
          if (alive()) { reset(); ctx.refresh(); }
        } catch (error) {
          // A stale/failed commit requires a fresh deliberate preview. Never automatically replay it.
          if (alive()) { e.preview = null; e.error = `${explain(error)} Nothing was retried. Request a fresh preview before confirming again.`; }
        } finally { if (alive()) { e.working = false; redraw(); } }
      }, { disabled: true, class: 'btn' });
      const ack = el('input', { type: 'checkbox', disabled: e.working || !!p.blocked?.length, 'aria-label': 'Confirm I reviewed this exact preview' });
      ack.addEventListener('change', () => { acknowledged = ack.checked; commit.disabled = !acknowledged || e.working || !!p.blocked?.length || !p.digest; });
      previewArea.append(el('label', { class: 'file-field' }, el('span', {}, ack, ' I reviewed this exact preview and its dependency impacts.')), commit);
    }
    nodes = [card('FILES', e.action === 'correct' ? 'Correct assignment' : e.action === 'activate' ? 'Activate earlier snapshot' : 'Classify new files', ...form,
      el('div', { class: 'actions' }, previewButton, button('Cancel', () => { reset(); ctx.render(); }, { disabled: e.working })),
      e.working ? el('p', { role: 'status' }, 'Checking / saving assignment…') : null,
      e.error ? el('p', { class: 'error', role: 'alert' }, e.error) : null, previewArea)];
    return nodes;
  }
  function fileRow(file, snapshot) {
    const role = file.role || 'source';
    const embedded = role === 'source' && !file.derived && ctx.files.setup?.platform === 'discourse';
    return el('div', { class: 'role-file' }, el('div', {}, el('strong', {}, safe(file.path)), el('small', {},
      `${file.derived ? 'Registered prepared input' : ROLES.find(([r]) => r === role)?.[1] || role}${snapshot ? ` · ${label(snapshot)}` : ''} · ${file.bytes ?? '?'} bytes`),
    role === 'uploads' ? el('p', { class: 'hint' }, 'Stored—not included by this workflow') : null,
    embedded ? el('p', { class: 'hint' }, 'Discourse full source backup: embedded uploads are consumed by native merge; external S3 assets are not fetched.') : null,
    role === 'reference' ? el('p', { class: 'hint' }, file.support_id ? `Private reference registered · ${safe(file.availability || file.status || 'availability checked by migration-data')}` : 'Private reference · availability not yet confirmed') : null,
    role === 'reference' && file.sha256 ? el('p', { class: 'hint' }, 'Original retained in private custody · checksum recorded. Not executed; a plan says how it is used.') : null,
    role === 'reference' && file.usage_status ? usageBlock(file) : null,
    role === 'reference' && file.id && ctx.project ? el('div', { class: 'actions' }, ...copyRequest(ctx.project, file)) : null,
    details(facts([['Identity', file.id, true], ['Input', file.input_id, true], ['Support', file.support_id, true], ['Checksum', file.sha256, true]]))),
    file.id ? el('details', { class: 'file-manage' }, el('summary', {}, `Manage ${safe(file.path)}`), button('Correct assignment…', () => open('correct', [file]))) : null);
  }
  function snapshotCard(s, current) {
    const prepared = (s.files || []).filter(file => file.derived);
    return card(s.kind === 'base_site' ? 'BASE SITE' : 'SOURCE SNAPSHOT', `${label(s)} · ${current ? 'Current' : 'Earlier'}`,
      ...(s.files || []).filter(file => !file.derived).map(f => fileRow(f, s)),
      prepared.length ? el('details', {}, el('summary', {}, `Registered prepared inputs (${prepared.length})`), ...prepared.map(f => fileRow(f, s))) : null,
      el('details', { class: 'more' }, el('summary', {}, 'Snapshot identity and input set'), facts([['Snapshot', s.dataset_id, true], ['Input-set revision', s.revision]])),
      s.incomplete ? el('p', { class: 'banner warn' }, safe(s.recovery_note || 'An interrupted assignment was retained as an earlier snapshot. Inspect its identities and preview Make current to recover; nothing was automatically resumed.')) : null,
      s.kind !== 'base_site' ? el('div', { class: 'actions' },
        button('Add files to this snapshot…', () => open('classify', [], { role: 'uploads', dataset_id: s.dataset_id }), { disabled: s.eligible === false }),
        !current && s.eligible !== false ? button('Make this source snapshot current…', () => open('activate', [], { dataset_id: s.dataset_id, snapshot: s })) : null)
        : !current && s.eligible !== false ? el('div', { class: 'actions' }, button('Make this Base backup current…', () => open('activate', [], { dataset_id: s.dataset_id, snapshot: s }))) : null,
      s.eligible === false ? el('p', { class: 'hint' }, 'Not eligible as a current source snapshot.') : null);
  }
  function historyEntry(entry) {
    const change = entry.change || {};
    const action = change.action || entry.action;
    const heading = action === 'correct' ? 'Assignment corrected' : action === 'activate' ? 'Current source changed' : 'Files assigned';
    const role = ROLES.find(([value]) => value === change.role)?.[1] || change.role;
    return el('div', { class: 'role-file' }, el('div', {},
      el('strong', {}, `${heading}${role ? ` · ${role}` : ''}`),
      el('small', {}, [entry.at, entry.by].filter(Boolean).map(safe).join(' · ')),
      change.reason || entry.text ? el('p', { class: 'hint' }, safe(change.reason || entry.text)) : null,
      details(el('pre', {}, describe(entry)))));
  }
  function render(files, allowClassify) {
    if (editor) return renderEditor(files);
    const key = JSON.stringify([ctx.project, allowClassify, files]);
    if (listing && listingKey === key) return listing;
    listingKey = key;
    const out = [];
    listing = out;
    if (allowClassify && files.unlabelled_files?.length) out.push(card('NEW FILES', `${files.unlabelled_files.length} incoming files — none selected`, button('Classify new files…', () => open('classify'))));
    if (!files.roles) return out;
    const all = snapshots(files), current = new Set(Object.values(files.roles.active || {}).filter(Boolean));
    out.push(el('div', { class: 'role-heading' }, el('h2', {}, 'Migration data'), allowClassify ? button('New source snapshot…', () => open('classify', [], { role: 'source' })) : null));
    for (const kind of ['development', 'launch']) {
      const s = currentSnapshot(files, kind);
      out.push(s ? snapshotCard(s, true) : card(kind.toUpperCase(), 'No current source snapshot'));
    }
    const base = all.filter(s => s.kind === 'base_site');
    out.push(el('div', { class: 'role-heading' }, el('h2', {}, 'Base site'), allowClassify ? button('New Base-site backup…', () => open('classify', [], { role: 'base_site' })) : null));
    if (base.length && !currentSnapshot(files, 'base_site')) out.push(el('p', { class: 'hint' }, 'No current Base backup. Earlier backups are retained, not implicitly selected.'));
    if (base.length) out.push(...base.map(s => snapshotCard(s, s.dataset_id === files.roles.active?.base_site)));
    else out.push(el('p', { class: 'hint' }, 'No Base-site backup recorded.'));
    out.push(el('h2', {}, 'Supporting references'), el('p', { class: 'hint' }, 'Private project references. Arrival route does not determine role; references never silently replace migration data.'));
    out.push(...(files.roles.references || []).map(f => fileRow(f)));
    if (!files.roles.references?.length) out.push(el('p', { class: 'hint' }, 'No supporting references.'));
    if (files.roles.unassigned?.length) out.push(el('details', { class: 'history' }, el('summary', {}, `Unassigned files — originals retained (${files.roles.unassigned.length})`),
      el('p', { class: 'hint' }, 'These assignments were removed, not deleted. Files still in intake can be explicitly classified again. Manage a retained reference to make it available again; chat-only files cannot silently become migration source data.'),
      ...files.roles.unassigned.map(file => fileRow(file))));
    const earlier = all.filter(s => s.kind !== 'base_site' && !current.has(s.dataset_id));
    out.push(el('details', { class: 'history' }, el('summary', {}, 'History — earlier snapshots, additions and corrections'),
      ...earlier.map(s => snapshotCard(s, false)), ...(files.roles.history || []).map(historyEntry),
      files.roles.history_more ? el('p', { class: 'hint' }, 'Only the latest 20 assignment events are shown here. Older audit events remain in the private project history; they were not deleted.') : null,
      el('p', { class: 'hint' }, 'Completed runs and releases retain their original snapshots, inputs and checksums. Corrections do not retroactively fix output.')));
    return out;
  }
  return { render, reset, leaving, get editing() { return !!editor; }, get working() { return !!editor?.working; } };
}
