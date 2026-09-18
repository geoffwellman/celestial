// THE BOARD, THE PULL REQUESTS, AND WHAT CHANGED SINCE YOU LAST LOOKED.
//
// state.mjs gathers what the fleet knows about ITSELF. This file gathers the
// two things the fleet exists to move - the tickets and the pull requests -
// and the cursor that turns "everything that ever happened" into "what
// happened while you were away".
//
// CACHED, WHICH NOTHING ELSE IN THIS CONSOLE IS. The panels refresh after
// every command and on a ten-second loop, and unlike `cel fleet` these two
// reads cross a network to somebody else's rate limit: an operator who leaves
// the console open would otherwise be a request to Linear and one to GitHub
// per repo every ten seconds, all day. Sixty seconds is short enough that a
// ticket someone just moved shows up on the next refresh and long enough that
// a busy minute costs one call. `refresh()` drops it after a command, because
// the command the operator just ran is the one change they want to see.
import { execFile } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

import { ago, clock, digestLine } from './views.mjs';

export const LINEAR_BIN = () => process.env.CEL_LINEAR_BIN || 'cel-linear';
export const GH_BIN = () => process.env.CEL_GH_BIN || 'gh';
export const TTL = Number(process.env.CEL_CONSOLE_CACHE_TTL || 60000);
export const STATE_DIR = () => process.env.CEL_CONSOLE_STATE_DIR
  || join(homedir(), '.local/share/cel/console');

const sh = (cmd, args, timeout = 20000) =>
  new Promise((resolve) => {
    execFile(cmd, args, { timeout, maxBuffer: 8 * 1024 * 1024 }, (err, out) =>
      resolve({ ok: !err, out: String(out || '') }));
  });

// One cache, keyed by the call. A Map rather than a file: the console is one
// process per operator and a cache that outlived it would be a cache that is
// wrong the moment the box changes underneath a closed terminal.
const CACHE = new Map();
export const refresh = () => CACHE.clear();
const cached = async (key, fn, now = Date.now()) => {
  const hit = CACHE.get(key);
  if (hit && now - hit.at < TTL) return hit.value;
  const value = await fn();
  CACHE.set(key, { at: now, value });
  return value;
};
// What is already known, without going and asking. The digest wants to say "2
// PRs merged" and must not pay for a round trip to do it: a header line that
// costs two HTTP requests is a header line that makes the console feel slow.
export const peek = (key) => (CACHE.has(key) ? CACHE.get(key).value : null);

// --- the board -------------------------------------------------------------

export const boardFor = async (ws) => cached(`board:${ws}`, async () => {
  const r = await sh(LINEAR_BIN(), ['board', '--json', '--workspace', ws]);
  if (!r.ok) return null;          // no Linear on this box, or no team: no panel
  const rows = [];
  for (const line of r.out.split('\n')) {
    if (!line.trim()) continue;
    try { rows.push(JSON.parse(line)); } catch { /* a half-written line is not a ticket */ }
  }
  return rows;
});

// --- the pull requests -----------------------------------------------------

// OWNER/NAME, or nothing at all. `gh pr list --repo widget` is a request for
// a repository that does not exist under whatever owner gh happens to guess,
// and the console must not make it: a slug it cannot resolve is a panel it
// does not draw. The workspace knows the URL, so the same one-line derivation
// lib/steward.sh and cel-fanout use is read out of it here.
export const repoSlugs = async (ws) => cached(`slugs:${ws}`, async () => {
  const fromEnv = process.env.CEL_CONSOLE_REPO_SLUGS;
  if (fromEnv) {
    try { return JSON.parse(fromEnv); } catch { /* a bad map is no map */ }
  }
  const r = await sh('bash', ['-c', `
    set -euo pipefail
    . "$CEL_ROOT/lib/registry.sh"; . "$CEL_ROOT/lib/workspace.sh"
    d="$(registry_path "$1")" || exit 0
    for r in $(ws_repo_names "$d"); do
      printf '%s\\t%s\\n' "$r" "$(ws_repo_get "$d" "$r" url | sed -E 's#^git@[^:]+:##; s#^https?://[^/]+/##; s#\\.git$##')"
    done`, '_', ws], 10000);
  const map = {};
  if (r.ok) {
    for (const line of r.out.split('\n')) {
      const [name, slug] = line.split('\t');
      if (name && slug && slug.includes('/')) map[name] = slug;
    }
  }
  return map;
});

const PR_FIELDS = 'number,title,headRefName,isDraft,reviewDecision,statusCheckRollup,updatedAt';

// ONE CALL PER REPO, never one per row. The first sketch asked for the checks
// of each PR separately, which on a product with six open PRs was seven
// requests every refresh - `statusCheckRollup` is in the list form and the
// list form is the whole panel.
export const prsFor = async (ws, repos) => cached(`prs:${ws}:${(repos || []).join(',')}`, async () => {
  const slugs = await repoSlugs(ws);
  const out = [];
  let asked = false;
  for (const repo of repos || []) {
    const slug = slugs[repo];
    if (!slug) continue;
    asked = true;
    // eslint-disable-next-line no-await-in-loop
    const r = await sh(GH_BIN(), ['pr', 'list', '--repo', slug, '--json', PR_FIELDS]);
    if (!r.ok) continue;
    try {
      for (const pr of JSON.parse(r.out || '[]')) out.push({ repo, slug, ...pr });
    } catch { /* gh printed something that is not a list */ }
  }
  if (!asked) return null;        // nothing resolvable: no panel rather than an empty one
  return out.sort((a, b) => String(b.updatedAt).localeCompare(String(a.updatedAt)));
});

// What LEFT since yesterday, for the timeline and the digest. Merged PRs are
// a separate query because the open list cannot carry them: a PR stops being
// open at the moment it becomes the most interesting thing that happened.
export const mergedFor = async (ws, repos) => cached(`merged:${ws}:${(repos || []).join(',')}`, async () => {
  const slugs = await repoSlugs(ws);
  const out = [];
  for (const repo of repos || []) {
    const slug = slugs[repo];
    if (!slug) continue;
    // eslint-disable-next-line no-await-in-loop
    const r = await sh(GH_BIN(), ['pr', 'list', '--repo', slug, '--state', 'merged', '--limit', '20',
      '--json', 'number,title,headRefName,mergedAt,updatedAt']);
    if (!r.ok) continue;
    try {
      for (const pr of JSON.parse(r.out || '[]')) out.push({ repo, slug, ...pr });
    } catch { /* likewise */ }
  }
  return out;
});

// --- the cursor ------------------------------------------------------------
//
// THE CONSOLE'S OWN CURSOR, not the mailbox's read marker. `cel inbox` tracks
// what has been READ, which the steward and the agent console also move; this
// one tracks when this operator last LOOKED at this workspace, and moving it
// must not mark anybody's mail as read.
export const cursorPath = (ws) => join(STATE_DIR(), `${ws}.root.console.cursor`);

export const readCursor = (ws) => {
  try { return readFileSync(cursorPath(ws), 'utf8').trim() || ''; } catch { return ''; }
};

export const writeCursor = (ws, iso = new Date().toISOString()) => {
  try {
    mkdirSync(STATE_DIR(), { recursive: true });
    writeFileSync(cursorPath(ws), iso);
  } catch { /* a console that cannot write its cursor still draws every panel */ }
};

// A day, when there is no cursor yet. Not "the beginning of time": the first
// digest an operator ever sees would otherwise be a count of every message the
// box has ever sent, which says nothing about what they missed.
export const since = (ws, now = Date.now()) => readCursor(ws)
  || new Date(now - 24 * 3600 * 1000).toISOString();

// --- the mailbox, read raw -------------------------------------------------

const INBOX_DIR = () => process.env.CEL_INBOX_DIR || join(homedir(), '.local/share/cel/inbox');

export const mailSince = (ws, iso) => {
  let text;
  try { text = readFileSync(join(INBOX_DIR(), `${ws}.jsonl`), 'utf8'); } catch { return []; }
  const floor = Date.parse(iso) || 0;
  const out = [];
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue;
    try {
      const m = JSON.parse(raw);
      if ((Date.parse(m.ts) || 0) < floor) continue;
      out.push({ ws, ts: m.ts || '', kind: m.kind || 'status', from: m.from || '-', to: m.to || '', message: String(m.message || '').replace(/\n/g, ' ') });
    } catch { /* a half-written line is not a message */ }
  }
  return out.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));
};

// --- the digest ------------------------------------------------------------

export const digestFor = (ws, { items = [], repos = [], now = Date.now() } = {}) => {
  const from = since(ws, now);
  const mail = mailSince(ws, from).filter((m) => m.to === 'root' || m.to === 'all');
  // Merged PRs come from the cache if the timeline has already filled it, and
  // are left out otherwise. A header line that costs a round trip per repo is
  // a header line that makes opening a unit feel slow, which is the exact
  // complaint the panel refresh budget exists to avoid.
  const seen = peek(`merged:${ws}:${(repos || []).join(',')}`) || [];
  const floor = Date.parse(from) || 0;
  const merged = seen.filter((p) => (Date.parse(p.mergedAt) || 0) >= floor).length;
  return digestLine({ since: from, mail, merged, waiting: items.length });
};

// The same numbers, without the prose, for the fleet screen's workspace rows.
export const digestCounts = (ws, { items = [], now = Date.now() } = {}) => {
  const from = since(ws, now);
  const mail = mailSince(ws, from).filter((m) => m.to === 'root' || m.to === 'all');
  return { since: clock(from), mail: mail.length, waiting: items.length };
};

// --- the timeline ----------------------------------------------------------
//
// THE BOX'S OWN HISTORY, in one column. Three sources that were three screens:
// the mailboxes say what was said, the fleet document says what was delegated,
// and the PR lists say what landed. An operator reconstructing the last two
// hours had to read all three and put them in order by hand.
export const timelineFor = async (doc, { now = Date.now() } = {}) => {
  const events = [];
  for (const ws of (doc && doc.workspaces) || []) {
    const from = new Date(now - 24 * 3600 * 1000).toISOString();
    for (const m of mailSince(ws.name, from)) {
      if (!['status', 'decision', 'blocked', 'resolution'].includes(m.kind)) continue;
      events.push({ ts: m.ts, ws: ws.name, kind: m.kind, what: `${m.from}: ${m.message}`, item: m });
    }
    const repos = [];
    for (const u of ws.units || []) {
      for (const r of u.repos || [u.name]) if (!repos.includes(r)) repos.push(r);
      for (const w of u.workers_list || []) {
        if (w.created) events.push({ ts: w.created, ws: ws.name, kind: 'created', what: `${w.ticket || w.id} ${w.id}`, worker: w });
        if (w.tried) events.push({ ts: w.tried, ws: ws.name, kind: 'try', what: `${w.ticket || w.id} preview`, worker: w });
      }
    }
    // eslint-disable-next-line no-await-in-loop
    for (const pr of await mergedFor(ws.name, repos)) {
      events.push({ ts: pr.mergedAt || pr.updatedAt, ws: ws.name, kind: 'merged', what: `#${pr.number} ${pr.headRefName}`, pr });
    }
  }
  return events;
};

export { ago };
