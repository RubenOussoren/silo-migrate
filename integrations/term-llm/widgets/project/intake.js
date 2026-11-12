// Intake-first pieces: a reference's derived "Used by", the Copy request fallback, and the
// progressive preparation sections of a plan. Everything shown comes from the server's
// projection of the plan body and run records (intake.py); nothing here invents state.
import { el, safe, short, toast, facts, block } from './ui.js';

export const USAGE = {
  reference_only: ['Reference only', 'Not cited by any plan yet.'],
  cited_by_plan: ['Cited by a plan', 'A plan waiting for review or Start cites this reference.'],
  in_use: ['Cited by a running run', 'A run in progress was planned with these exact bytes.'],
  run_not_completed: ['Cited by a run that did not complete', 'A run planned with these bytes stopped before completing; see its status under Used by.'],
  cited_earlier: ['Cited by an earlier plan, not run', 'Only plans that were never run cited it; see their status under Used by.'],
  used_by_completed_run: ['Used by a completed run', 'A completed run’s plan cited these exact bytes.'],
  unknown: ['Use unknown', 'Plans could not be read just now, so its use is not shown. It is not assumed unused.'],
};
// The backend's dispositions and question statuses (standard_run_inputs.rb), in words.
const DISPOSITION = {
  stock: 'Built-in behavior', setting: 'Supported setting / option', prepared_input: 'Prepared input file', code: 'Depends on code',
  manual: 'Manual follow-up', excluded: 'Not included',
};
// Recorded by the analyst in the plan: the engineer confirms them by reviewing this exact plan, not elsewhere.
const QUESTION = { resolved: 'Recorded answer', excluded: 'Recorded exclusion', scope_narrowed: 'Recorded scope narrowing' };
const STATE = { verified: 'Exact bytes verified', not_verified_here: 'Bound by checksum; too large to re-check on this page (the run checks it before use)', not_bound: 'Not bound to this plan', missing: 'Missing', changed: 'Changed since the plan', unreadable: 'Unreadable' };
const refText = r => `${r.file_id || r.input_id} (${short(r.sha256, 12)}…)`;
// What the backend checked when the plan was proposed: re-read custody bytes, or only matched the registry's recorded digest.
const VERIFIED = { custody_bytes: 'bytes re-checked when proposed', registry_digest: 'registry checksum matched; bytes not re-read' };
const refCheck = r => (r.verified ? ` · ${VERIFIED[r.verified]}` : '');

// Plain text the engineer pastes themselves into this project's migration-data chat. It names the
// project and agent explicitly; it is never sent, inserted into another chat, or run. It carries
// the exact identities so nothing is matched by file name alone (names can repeat).
const SUPPORT_ID = /^support-[0-9a-f]{16,64}$/, SHA256 = /^[0-9a-f]{64}$/;
export function requestText(project, ref) {
  const support = SUPPORT_ID.test(ref.support_id || '') ? ref.support_id : null;
  const digest = SHA256.test(ref.sha256 || '') ? ref.sha256 : null;
  return [`Project: ${project}`, 'Agent: migration-data (this project’s private chat)', '',
    `Use the registered supporting reference ${safe(ref.path || 'reference')} as the requirements for a plan on the explicitly selected source and Base.`,
    support ? `Private reader ID (for data_supporting_read): ${support}` : 'Private reader ID: not shown on the Files tab. Find it with data_supporting_list by the exact SHA-256 below; do not choose by file name alone.',
    `Files tab identity: ${ref.id}`,
    digest ? `Exact SHA-256: ${digest}` : 'Exact SHA-256: not recorded on the Files tab. Ask me before using any file with this name.',
    support && digest ? 'Confirm that the reader ID’s SHA-256 equals the one above before reading.' : null,
    'Explain what each wish needs (stock behavior, setting, prepared input, code, manual follow-up), ask me about material choices, and propose one plan with the exact prepared inputs.',
    'Do not start a migration, approve anything, change source/Base selections or alter the original file.'].filter(line => line !== null).join('\n');
}

export function copyRequest(project, ref) {
  const text = requestText(project, ref);
  const area = el('div', { class: 'copy-request' });
  const fallback = () => {
    const box = el('textarea', { readonly: true, rows: 7, 'aria-label': 'Request text to copy' }, text);
    area.replaceChildren(el('p', { class: 'hint' }, 'Copy this text and paste it into a migration-data chat in this project. Nothing was sent.'), box);
    box.focus(); box.select();
  };
  const button = el('button', { type: 'button', class: 'btn q', onclick: async () => {
    try { await navigator.clipboard.writeText(text); toast('Request copied. Paste it into a migration-data chat in this project; nothing was sent.'); area.replaceChildren(); }
    catch { fallback(); }
  } }, 'Copy request for migration-data');
  return [button, area];
}

export function usageBlock(ref) {
  const [label, explain] = USAGE[ref.usage_status] || USAGE.unknown;
  const used = ref.used_by || null;
  const lines = used ? [...(used.plans || []).map(plan => `Plan ${plan.plan_id} · ${safe(plan.operation || 'run')} · ${safe(plan.status || 'unknown')}`),
    ...(used.runs || []).map(run => `Run ${run.run_id} · ${safe(run.status || 'unknown')} (plan ${run.plan_id})`)] : [];
  return el('div', { class: 'usage' }, el('span', { class: `pill ${ref.usage_status === 'used_by_completed_run' ? 'ok' : ref.usage_status === 'cited_by_plan' ? 'now' : ref.usage_status === 'unknown' ? 'warn' : ''}` }, label),
    el('span', { class: 'hint' }, explain),
    lines.length ? el('details', { class: 'more' }, el('summary', {}, `Used by (${lines.length}) — from plan and run records`), el('pre', {}, lines.join('\n'))) : null);
}

const list = (items, render) => el('ul', { class: 'intake-list' }, items.map(item => el('li', {}, render(item))));

// The plan's preparation, outcome first; technical detail collapsed. Returns { sections, ready, blockers }.
export function planSections(intake) {
  if (!intake) return null;
  const prep = intake.preparation, manifest = intake.run_inputs, sections = [];
  const analyst = () => el('p', { class: 'hint label-analyst' }, `Written by ${prep ? safe(prep.analyst.label) : 'migration-data'}: an interpretation, not evidence. Compare it with the exact inputs and pinned code below.`);
  if (prep) sections.push(block('What will happen', el('p', { class: 'analyst-text' }, safe(prep.analyst.text)), analyst()));
  if (intake.blockers.length) {
    sections.push(el('div', { class: 'card-inner needs', role: 'region', 'aria-label': 'Needs your answer' },
      el('h3', {}, intake.blockers.some(b => b.code === 'QUESTION_UNRESOLVED') ? 'Needs your answer' : 'Not ready to approve'),
      list(intake.blockers, b => safe(b.text)),
      el('p', { class: 'hint' }, 'Answer in this project’s migration-data chat, or explicitly narrow the scope there. A new plan is proposed with your choices; unclear wishes are never silently defaulted or omitted.')));
  }
  if (prep && prep.outcomes.length) {
    sections.push(block('How wishes are handled', list(prep.outcomes, o => [el('strong', {}, safe(o.requirement)), ' ',
      el('span', { class: `pill ${o.disposition === 'code' ? 'warn' : ''}` }, DISPOSITION[o.disposition] || o.disposition),
      o.disposition === 'code' ? el('small', {}, 'Handled by pinned code, not proven by this page: check the reviewed change.') : null,
      o.input ? el('small', {}, o.input === 'settings' ? 'Prepared settings bound to this plan' : `Prepared file: ${safe(o.input)}`) : null]), analyst()));
  }
  const answered = prep ? prep.questions.filter(q => q.status) : [];
  if (answered.length) sections.push(block('Analyst-recorded answers and scope choices — confirm in this exact plan review',
    list(answered, q => [el('strong', {}, safe(q.text)), el('small', {}, `${QUESTION[q.status]}: ${safe(q.resolution)}`)]),
    el('p', { class: 'hint label-analyst' }, `Recorded by ${prep ? safe(prep.analyst.label) : 'migration-data'}, not independent proof of your decision. Approving this plan is your confirmation; correct anything wrong in the migration-data chat for a new plan.`)));
  const files = [];
  for (const input of intake.inputs) {
    const lineage = input.lineage || {};
    const refs = lineage.references || [];
    files.push(el('div', { class: 'role-file' }, el('div', {},
      el('strong', {}, safe(input.name || input.origin)), el('small', {}, `${STATE[input.state] || input.state}${input.bytes != null ? ` · ${input.bytes} bytes` : ''} · ${input.origin}`),
      refs.length ? el('small', {}, `Derived from reference ${(lineage.references || []).map(r => refText(r) + refCheck(r)).join(', ')}`) : null,
      lineage.preparation ? el('small', {}, `Prepared by ${safe(lineage.preparation.job)}${lineage.preparation.tool ? ` (${safe(lineage.preparation.tool)})` : ''}`) : null,
      input.reuse ? el('small', { class: 'reuse' }, 'Explicitly reused from an earlier source snapshot, not this plan’s source. Its exact bytes and that source version are bound below.') : null,
      input.preview ? el('details', { class: 'more' }, el('summary', {}, `Preview the exact bytes${input.preview.truncated ? ' (first 64 KiB)' : ''}`), el('pre', {}, safe(input.preview.text)))
        : input.state === 'verified' ? el('small', {}, 'No text preview for this format; bound by its checksum.') : null,
      el('details', { class: 'more' }, el('summary', {}, 'Identity'), facts([['Input', input.input_id, true], ['SHA-256', input.sha256, true],
        ['Reused from snapshot', input.reuse ? input.reuse.dataset_id : null, true], ['That source’s SHA-256', input.reuse ? input.reuse.source_sha256 : null, true],
        ['Preparation job', lineage.preparation ? lineage.preparation.job : null, true], ['Preparation spec SHA-256', lineage.preparation ? lineage.preparation.preparation_sha256 : null, true],
        ['Preparer script SHA-256', lineage.preparation ? lineage.preparation.script_sha256 : null, true]])))));
  }
  if (manifest) {
    files.unshift(manifest.files.length
      ? el('p', { class: 'hint' }, `Converter setting ${safe(manifest.consumer.setting)} points at a fresh run-owned copy of these files${manifest.writable ? '; only the declared generated files may be written' : ', read-only'}.`)
      : el('p', { class: 'empty-manifest' }, `No reviewed files are provided. Converter setting ${safe(manifest.consumer.setting)} points at a fresh, empty run-owned directory, so the converter’s own defaults apply${manifest.writable ? '; only the declared generated files may be written there' : ''}. No placeholder or header-only file is added.`));
    for (const name of manifest.absent_defaults) files.push(el('p', { class: 'hint' }, `${safe(name)}: deliberately not provided — the converter’s own default applies.`));
    for (const name of manifest.generated) files.push(el('p', { class: 'hint' }, `${safe(name)}: may be generated by the converter in this run’s own copy; captured as evidence, never reused automatically.`));
  }
  const code = prep && prep.code_readiness;
  if (code) {
    const what = code.kind === 'merge_layer' ? 'merge layer' : 'converter';
    // Presence identifies the code that will run. It is not proof the requested behavior is implemented or reviewed.
    files.push(facts([['Code that will run', code.present ? `${what}${code.path ? ` ${safe(code.path)}` : ''}${code.revision ? ` at ${short(code.revision, 12)}` : ''}` : `No ${what} in this plan`, !!code.path]]),
      code.required ? el('p', { class: 'hint code-caveat' }, code.present
        ? `Some wishes need code. The pinned ${what} is what will run; this page does not show that it implements them. Check the reviewed change before approving.`
        : `Some wishes need code, and no ${what} is pinned.`) : null);
  }
  if (prep) for (const r of prep.references) files.push(el('p', { class: 'hint' }, `Reference ${refText(r)}${refCheck(r)}: provenance only — the original is retained and is not executed or mounted.`));
  if (files.length) sections.push(block('Files and code this run will actually use', ...files));
  if (prep && prep.exclusions.length) sections.push(block('Not included', list(prep.exclusions, x => [el('strong', {}, safe(x.text)), x.reason ? el('small', {}, safe(x.reason)) : null]), analyst()));
  return { sections, ready: intake.ready, blockers: intake.blockers };
}
