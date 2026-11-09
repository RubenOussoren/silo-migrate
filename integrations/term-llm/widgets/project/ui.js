// Shared pieces of the Project page. Everything from the server goes in as text, never as markup.
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
  const response = await fetch(path, options);
  let data = {};
  try { data = await response.json(); } catch { /* not JSON */ }
  if (!response.ok) throw new Error(data.error || `HTTP ${response.status}`);
  return data;
}

const ERRORS = {
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
  STANDARD_PUSH_REJECTED: 'GitHub rejected the push (the branch moved on GitHub). Nothing was changed there.',
  STANDARD_PUSH_TOKEN_MISSING: 'No GitHub token for this repository owner on the server.',
  STANDARD_REQUEST_REFUSED: 'The request was refused. Reload the page.',
  STANDARD_OPERATION_TIMEOUT: 'No answer in time. It may still have happened: refresh before trying again.',
  STANDARD_TEXT_TOO_LARGE: 'The text is over 256 KiB.',
  STANDARD_DELIVERY_FILES_CHANGED: 'The files changed since this page loaded. Check them and choose again.',
  STANDARD_DELIVERY_CONFIRM_LAUNCH: 'Type LAUNCH to confirm.',
  STANDARD_DELIVERY_LAUNCH_EXISTS: 'Launch data already exists. Confirm that this replaces it.',
  STANDARD_DELIVERY_LABEL_EXISTING_FIRST: 'Label the data already in this project first.',
  STANDARD_NOT_INITIALIZED: 'This project has no workspace yet. Ask migration-data to create it.',
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
