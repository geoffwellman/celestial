// The command line, as pure functions.
//
// Everything here is the part of the console the operator's fingers know: a
// cursor, the shell chords (Ctrl+W, Ctrl+K, Ctrl+U) and a history walk that
// filters by what is already typed. It lives outside ui.mjs so it can be
// asserted without a terminal, a React renderer or node_modules - the first
// version of this was inline in the ink component and the only way to prove
// "Ctrl+W at the start of the line" was to sit in front of it.
//
// Every function takes and returns a plain {value, cursor} pair. No state, no
// clamping surprises: the cursor is always 0..value.length.

const clamp = (n, lo, hi) => Math.max(lo, Math.min(hi, n));

export const at = (value, cursor) => ({ value, cursor: clamp(cursor, 0, value.length) });

export const insert = (value, cursor, text) => {
  const c = clamp(cursor, 0, value.length);
  return { value: value.slice(0, c) + text + value.slice(c), cursor: c + text.length };
};

// Backspace deletes BEFORE the cursor, Delete deletes UNDER it. The first cut
// had both doing `slice(0, -1)`, which meant the cursor was decoration.
export const backspace = (value, cursor) => {
  const c = clamp(cursor, 0, value.length);
  if (!c) return { value, cursor: c };
  return { value: value.slice(0, c - 1) + value.slice(c), cursor: c - 1 };
};

export const del = (value, cursor) => {
  const c = clamp(cursor, 0, value.length);
  if (c >= value.length) return { value, cursor: c };
  return { value: value.slice(0, c) + value.slice(c + 1), cursor: c };
};

export const left = (value, cursor) => at(value, cursor - 1);
export const right = (value, cursor) => at(value, cursor + 1);
export const home = (value) => ({ value, cursor: 0 });
export const end = (value) => ({ value, cursor: value.length });

// Ctrl+W: the word before the cursor, plus the whitespace that led to it, in
// one stroke - readline's behaviour, because that is the one in the fingers.
export const killWord = (value, cursor) => {
  const c = clamp(cursor, 0, value.length);
  const before = value.slice(0, c);
  const kept = before.replace(/\S+\s*$/, '');
  return { value: kept + value.slice(c), cursor: kept.length };
};

export const killToEnd = (value, cursor) => {
  const c = clamp(cursor, 0, value.length);
  return { value: value.slice(0, c), cursor: c };
};

export const killLine = () => ({ value: '', cursor: 0 });

// The history walk, fish/zsh style: with something already typed, ↑ walks only
// the entries that START with it. An operator who typed `cel inbox` and wanted
// the long one from this morning should not have to page through every `cel
// fleet` in between.
//
// `index` is -1 for "on the live line"; 0 is the newest match. `typed` is what
// the operator had on the line when the walk began, and is what ↓ returns to.
export const historyWalk = (history, index, dir, typed = '') => {
  const all = (history || []).filter(Boolean);
  const matches = [];
  for (let i = all.length - 1; i >= 0; i -= 1) {
    if (!typed || all[i].startsWith(typed)) matches.push(all[i]);
  }
  if (!matches.length) return { index: -1, value: typed };
  const next = dir === 'up'
    ? Math.min(matches.length - 1, index + 1)
    : Math.max(-1, index - 1);
  return { index: next, value: next < 0 ? typed : matches[next] };
};

// Ctrl+R's picker: substring, newest first, de-duplicated. Duplicates are the
// reason the picker exists at all - a history of forty identical `cel fleet`
// lines is a history with nothing in it.
export const historyFilter = (history, query) => {
  const q = String(query || '').toLowerCase();
  const seen = new Set();
  const out = [];
  const all = (history || []).filter(Boolean);
  for (let i = all.length - 1; i >= 0; i -= 1) {
    const line = all[i];
    if (q && !line.toLowerCase().includes(q)) continue;
    if (seen.has(line)) continue;
    seen.add(line);
    out.push(line);
  }
  return out;
};
