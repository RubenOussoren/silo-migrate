// Shared pieces of the Project page. Everything from the server goes in as text, never as markup.
import { createListCache } from './lists.js';

export const lists = createListCache((path) => api(path));
export const $ = (id) => document.getElementById(id);

export function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs || {})) {
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) { if (typeof value === 'function') node.addEventListener(key.slice(2), value); }
    else if (key === 'value') node.value = value;
    else if (value !== undefined && value !== null && value !== false) node.setAttribute(key, value === true ? '' : value);
  }
  for (const child of children.flat(Infinity)) {
    if (child !== null && child !== undefined && child !== false) node.append(child instanceof Node ? child : document.createTextNode(String(child)));
  }
  return node;
}

// File names and agent text come from outside: control and direction characters could disguise them.
export const safe = (text) => String(text ?? '').replace(/[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u061c\u180e\u200b-\u200f\u2028-\u202e\u2060-\u2069\ufeff]/g, '\ufffd');
export const short = (value, n = 12) => (value ? String(value).slice(0, n) : '');
export const badge = (status, text) => el('span', { class: `status ${status || ''}` }, text || String(status || '').replace(/_/g, ' '));

export function ago(iso) {
  if (!iso) return '';
  const seconds = Math.max(0, (Date.now() - Date.parse(iso)) / 1000);
  if (seconds < 90) return 'just now';
  if (seconds < 5400) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 129600) return `${Math.round(seconds / 3600)} h ago`;
  return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' });
}

export function toast(message, bad = false) {
  const box = $('toast');
  box.textContent = message;
  box.className = bad ? 'show bad' : 'show';
  clearTimeout(toast.timer);
  toast.timer = setTimeout(() => { box.className = ''; }, bad ? 10000 : 4500);
}

export async function api(path, body) {
  const options = body
    ? { method: 'POST', credentials: 'same-origin', headers: { 'Content-Type': 'application/json', 'X-Silo-Project': '1' }, body: JSON.stringify(body) }
    : { credentials: 'same-origin', headers: { Accept: 'application/json' } };
  // Invalidate both before and after a decision: a read started during it must not survive it.
  if (body) lists.clear();
  let response;
  try { response = await fetch(path, options); } finally { if (body) lists.clear(); }
  let data = {};
  try { data = await response.json(); } catch { /* not JSON */ }
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

const ERRORS = {
  STANDARD_FILE_ROLES_STALE_PREVIEW: 'This file preview is out of date. Nothing was applied. Review a fresh preview before confirming again.',
  STANDARD_FILE_ROLES_ACTIVE_DEPENDENCY: 'Affected work is active. Settle the active run or job before changing this assignment.',
  STANDARD_FILE_ROLES_FILES_CHANGED: 'The incoming file identity changed. Reload the files and select them again.',
  STANDARD_FILE_ROLES_RESTORE_REQUIRED: 'Select an eligible earlier source snapshot to restore before correcting the current source assignment.',
  STANDARD_FILE_ROLES_SOURCE_INVALID: 'This is not a valid source backup for this platform. Keep the original full Discourse backup name and format.',
  STANDARD_FILE_ROLES_SOURCE_PLATFORM_INVALID: 'These files cannot be used as source data for this project’s platform.',
  STANDARD_FILE_ROLES_SNAPSHOT_INVALID: 'That snapshot is no longer eligible. Reload the Files view and choose another.',
  STANDARD_FILE_ROLES_CONFIRM_LAUNCH: 'This change affects Launch. Type LAUNCH, then request a fresh preview.',
  STANDARD_FILE_ROLES_REASON_REQUIRED: 'Explain why this assignment is being corrected or this snapshot is being activated.',
  STANDARD_FILE_ROLES_ALREADY_ASSIGNED: 'These files have already been assigned. Use Manage → Correct assignment instead.',
  STANDARD_BASE_SITE_NEWER: 'The backup needs a newer Discourse application than the selected runtime. Check the Base backup and public-image availability; resetting the same plan alone will not fix this.',
  STANDARD_REVIEW_RUNTIME_CHANGED: 'The running review instance differs from the approved version. Reset this run and propose again to resolve the current Base site runtime.',
  STANDARD_REVIEW_RUNTIME_UNRESOLVED: 'A compatible review runtime could not be selected from the backup version. Check that this is an original versioned backup; an unsupported release needs node-admin help.',
  STANDARD_REVIEW_RUNTIME_VERSION_INVALID: 'The backup version is not a supported Discourse version identifier.',
  STANDARD_REVIEW_RUNTIME_VERSION_UNAVAILABLE: 'No matching or compatible newer public Discourse build is available on this release track. The tooling did not switch tracks or use an older version.',
  STANDARD_REVIEW_RUNTIME_PREPARATION_FAILED: 'Preparing the Discourse runtime failed. No import started. Wait briefly, then try the proposal again; ask your node admin if it repeats.',
  STANDARD_REVIEW_RUNTIME_TIMEOUT: 'Discourse runtime preparation exceeded its time limit. No import started. Wait briefly and retry the proposal; ask your node admin if it repeats.',
  STANDARD_REVIEW_RUNTIME_CACHE_INVALID: 'The prepared runtime cache changed or is unsafe. Nothing ran; ask your node admin to investigate.',
  STANDARD_REVIEW_RUNTIME_METADATA_INVALID: 'The public Discourse image could not prove its expected identity. Nothing ran; ask your node admin to investigate.',
  STANDARD_REVIEW_RUNTIME_POSTGRES_INCOMPATIBLE: 'This Discourse build requires a newer database runtime. Nothing ran; node-admin preparation is needed.',
  STANDARD_REVIEW_RUNTIME_RECIPE_INVALID: 'The fixed runtime preparation recipe is invalid. Nothing ran; ask your node admin to investigate.',
  STANDARD_REVIEW_RUNTIME_SCHEMA_INVALID: 'The backup schema identifier is invalid.',
  STANDARD_REVIEW_RUNTIME_RECOVERY_REQUIRED: 'Runtime preparation was interrupted and its Docker outcome is uncertain. No customer run started. Preparation is paused for node-admin inspection; do not keep retrying or clear the lease without checking its resources.',
  STANDARD_REVIEW_RUNTIME_CLEANUP_FAILED: 'The preparation sandbox could not be confirmed removed. No customer run started; node-admin inspection is required.',
  STANDARD_REVIEW_RUNTIME_CAPACITY: 'There is not enough disk headroom to prepare another Discourse runtime. No import started; ask your node admin to free space without removing active images.',
  STANDARD_REVIEW_RUNTIME_OUTPUT_LIMIT: 'Runtime preparation exceeded its output limit. No import started; ask your node admin to investigate.',
  STANDARD_BASE_SITE_INVALID: 'Choose one original Discourse SQL-only backup, with its original name. Take it without uploads: discourse backup --sql-only.',
  STANDARD_BASE_SITE_TYPE: 'Only an original backup labelled Base site can be taken as base_site. It cannot be registered as a derived output.',
  STANDARD_BASE_SITE_ROLE: 'A Base site is not source data, settings or count checks.',
  STANDARD_BASE_SITE_NOT_TAKEN: 'Ask migration-data to take the labelled backup as base_site, then propose again.',
  STANDARD_MERGE_NOT_DISCOURSE: 'A merge run needs a project whose source platform is discourse.',
  STANDARD_MERGE_SOURCE_INVALID: 'The source site must be one original full Discourse backup (.tar.gz, with uploads), with its original name, in a project whose platform is discourse.',
  STANDARD_MERGE_SOURCE_NOT_TAKEN: 'Ask migration-data to take the source site\u2019s backup (labelled Development or Launch) first, then propose again.',
  STANDARD_MERGE_SOURCE_NEWER: 'The source backup needs a newer application than the Base-selected runtime. Supply a compatible current Base backup or align the hosted target version/track. Resetting alone will not fix this; the tooling will not silently switch tracks.',
  STANDARD_MERGE_BASE_SITE_MISSING: 'A merge needs a Base site: the backup of the site merged into. Label it on the Files tab, then propose again.',
  STANDARD_MERGE_SETTINGS_INVALID: 'The merge settings must be one small YAML mapping. Ask migration-data to write it again.',
  STANDARD_MERGE_LAYER_INVALID: 'The merge layer can\u2019t be used as committed: only Ruby files under mergers/<project>/, with one merger.rb that defines one merger. Ask converter-developer to fix and commit it, then propose again.',
  STANDARD_MERGE_SCHEMA: 'The merger met a column it doesn\u2019t know: the two sites\u2019 schemas differ. Ask migration-data to look at the run; it may need a newer server or a merge layer change.',
  STANDARD_MERGE_FAILED: 'The merge stopped. Its log stays private on the server: ask migration-data to look at the run, then reset it.',
  STANDARD_RELEASE_NOT_READY: 'Only a completed Base site import with a backup can be released.',
  STANDARD_RELEASE_CHECKS: 'Not every check matched, or there are no checks. Review them and choose Release anyway… to acknowledge this.',
  STANDARD_ARTIFACT_CHANGED: 'The backup changed since it was recorded. Nothing was released. Ask your node admin to investigate.',
  STANDARD_BUSY: 'The project is busy (a run or another decision). Try again in a moment.',
  STANDARD_REVIEW_SOURCE_INVALID: 'Review needs a completed convert run with an unchanged intermediate database. Ask migration-data to check the source run.',
  STANDARD_STALE_PLAN: 'This plan is out of date: something it uses changed. Discard it and ask migration-data to propose it again.',
  STANDARD_APPROVAL_MISMATCH: 'This differs from what the page showed. Nothing was approved or released.',
  STANDARD_TRANSITION_INVALID: 'That was already decided. The page has been refreshed.',
  STANDARD_NOT_APPROVED: 'Approve the plan first.',
  STANDARD_PLAN_CONSUMED: 'This plan was already used (or discarded).',
  STANDARD_CAPACITY: 'Not enough memory or disk on the server right now: reset finished review sites, or free disk.',
  STANDARD_DIRTY_INSTANCE: 'An earlier run left a site behind: reset that run first.',
  STANDARD_PUSH_STALE: 'The branch changed since this push was proposed. Ask converter-developer to propose again.',
  STANDARD_PUSH_REWRITE_APPROVAL_REQUIRED: 'This rebased branch needs explicit history-replacement approval. Review it and choose Push rebased branch…',
  STANDARD_REBASE_CHECKPOINT_REQUIRED: 'Checkpoint the developer’s own uncommitted edits first. Hidden tracked changes need the engineer; nothing was rebased.',
  STANDARD_REBASE_REMOTE_DIVERGED: 'The remote migration branch moved or its pinned rebase changed. Stop and inspect the teammate’s work; no remote history was overwritten.',
  STANDARD_REBASE_COLLISION: 'An incoming code path would replace an existing untracked file or link. Nothing was rebased; ask the engineer to resolve the collision.',
  STANDARD_REBASE_IN_PROGRESS: 'A Git operation is already in progress. Finish or recover it before rebasing; the tool left it untouched.',
  STANDARD_REBASE_FETCH_FAILED: 'Could not fetch upstream main. Nothing was rebased; retry after checking GitHub access.',
  STANDARD_REBASE_MAIN_MISSING: 'The origin has no main branch. Nothing was rebased; ask the engineer to check the converter origin.',
  STANDARD_REBASE_ORIGIN_REFUSED: 'Rebasing is limited to the configured GitHub origin. Nothing was rebased.',
  STANDARD_REBASE_MERGES_UNSUPPORTED: 'The local branch has merge commits. This tool will not flatten them; agree a history-preserving approach with the engineer.',
  STANDARD_REBASE_UNSUPPORTED_TREE: 'The code tree contains unsupported Git paths or link changes. Nothing was rebased.',
  STANDARD_REBASE_LIMIT: 'The code tree or replay exceeds the bounded rebase limits. Nothing was rebased; ask the engineer for a narrower approach.',
  STANDARD_REBASE_TIMEOUT: 'The rebase step timed out. Check dev_status before retrying; scratch replay never changes the live checkout.',
  STANDARD_REBASE_FAILED: 'The local rebase could not complete. Inspect dev_status and the recorded backup ref with the engineer before retrying.',
  STANDARD_PUSH_REJECTED: 'GitHub rejected the push (the branch moved on GitHub). Nothing was changed there.',
  STANDARD_PUSH_FINDING_CHANGED: 'A finding this push names was corrected or withdrawn since. Ask converter-developer to propose the push again.',
  STANDARD_PUSH_TOKEN_MISSING: 'No GitHub token for this repository owner on the server.',
  STANDARD_REQUEST_REFUSED: 'The request was refused. Reload the page.',
  STANDARD_OPERATION_TIMEOUT: 'No answer in time. It may still have happened: refresh before trying again.',
  STANDARD_TEXT_TOO_LARGE: 'The text is over 256 KiB.',
  STANDARD_DELIVERY_FILES_CHANGED: 'The files changed since this page loaded. Check them and choose again.',
  STANDARD_DELIVERY_CONFIRM_LAUNCH: 'Type LAUNCH to confirm.',
  STANDARD_DELIVERY_LAUNCH_EXISTS: 'Launch data already exists. Confirm that this replaces it.',
  STANDARD_DELIVERY_LABEL_EXISTING_FIRST: 'Label the data already in this project first.',
  STANDARD_NOT_INITIALIZED: 'This project has no workspace yet. Create it on the Files tab.',
  STANDARD_PLATFORM_MISMATCH: 'This project already has a different source platform. It can only change by starting over.',
  STANDARD_SITE_NOT_PASSED: 'Only a site whose convert and import runs both matched every check, on development data, can be accepted.',
  STANDARD_SITE_NOT_REVIEW: 'Only an import into a review site can be accepted.',
  STANDARD_SITE_NOT_FINISHED: 'The import hasn\u2019t finished yet.',
  STANDARD_SITE_ACCEPTED: 'This site\u2019s acceptance stands. Withdraw it first, on the Overview.',
  STANDARD_CONFIRMATION_REQUIRED: "Type the project's name exactly to confirm.",
  STANDARD_BUSY_RUN: 'A run is still running. Wait for it to finish, or stop it from the Runs tab.',
  STANDARD_BUSY_JOB: 'A data job is still running. Wait for it, or ask migration-data to stop it.',
  STANDARD_BUSY_CHAT: 'A chat in this project is still answering. Stop it or let it finish, then try again.',
  STANDARD_REMOVE_DROP_TAKEN: 'The drop folder already has files with the received files\' names. Move them away, then try again.',
  STANDARD_REMOVE_INCOMPLETE: 'Not everything could be removed yet. What was done stays done (received files already back in the drop folder stay there): try again to finish.',
  STANDARD_REMOVE_LINKED_CHAT: "A chat of another project was started from one of this project's chats. Delete that chat first, or ask for help.",
  STANDARD_REMOVE_NOT_OWNED: "Some of its folders belong to another user (root, say), so they can't be removed. Ask for help; nothing was changed.",
  STANDARD_DOCKER_UNAVAILABLE: "Docker didn't answer. Try again, or ask for help (silo doctor).",
  STANDARD_CHATS_UNREADABLE: "term-llm's chat list couldn't be read. Try again in a moment.",
  STANDARD_STATE_INVALID: "This project's workbench state can't be read, so its review sites can't be found. Ask for help.",
  STANDARD_PLAN_NOT_READY: 'This plan is not ready: a material question, required code or an exact prepared input is unresolved. Nothing was approved or started.',
  STANDARD_REFERENCE_INVALID: "That isn't on the server any more. The page has been refreshed.",
};
export const explain = (error) => ERRORS[String(error.message).split(':')[0]] || `That didn't work: ${error.message}`;

export function facts(pairs) {
  return el('dl', { class: 'facts' }, pairs.filter(([, value]) => value !== undefined && value !== null && value !== '')
    .map(([label, value, mono]) => [el('dt', {}, label), el('dd', { class: mono ? 'mono' : '' }, value)]));
}

export const block = (title, ...content) => el('div', { class: 'block' }, el('h3', {}, title), ...content);

export function table(headers, rows, numeric = [], rowClass = () => '') {
  return el('div', { class: 'grid-wrap' }, el('table', { class: 'grid' }, el('thead', {}, el('tr', {}, headers.map((h, i) => el('th', { class: numeric.includes(i) ? 'num' : '' }, h)))),
    el('tbody', {}, rows.map((row, r) => el('tr', { class: rowClass(r) }, row.map((cell, i) => el('td', { class: numeric.includes(i) ? 'num' : '' }, cell ?? '')))))));
}

// Technical detail, one click away.
export const details = (...content) => el('details', { class: 'more' }, el('summary', {}, 'Details'), ...content);

export const card = (eyebrow, say, ...content) => el('div', { class: 'card' }, eyebrow ? el('div', { class: 'eyebrow' }, eyebrow) : null, say ? el('p', { class: 'say' }, say) : null, ...content);

export const back = (label, onclick) => el('button', { type: 'button', class: 'back', onclick }, `\u2039 ${label}`);

export function item(title, meta, onclick, extra) {
  return el('button', { type: 'button', class: 'item', onclick }, el('div', {}, el('span', { class: 'title' }, title), el('small', {}, meta)), extra || el('span', { class: 'go' }, '\u203a'));
}
