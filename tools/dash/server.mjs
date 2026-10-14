// cel dash server - ONE for the box, zero dependencies (CEL-107). Launched by
// lib/dash.sh with CEL_DASH_CONFIG (JSON: port, host, and
// workspaces [{name, wsdir, repos [{name, slug}], services, linearTeams,
// triggerState}]; name/wsdir/repos at the top level are the first workspace,
// the default for every page that still shows one at a time).
//
// Reads live state by shelling out to the same CLIs the roles use (herdr,
// gh, yq) - no daemons, no state of its own. The CLI launcher defaults to the
// tailnet IP when available, otherwise loopback; --host overrides it. This
// private control surface requires trusted Host/Origin and CSRF checks.
import { createServer, request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { readdirSync, existsSync, readFileSync, statSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

import { controlSecurity, internalError } from '../http-security.mjs';
import { createV2 } from './v2.mjs';
import { store } from './store.mjs';
const cfg = JSON.parse(process.env.CEL_DASH_CONFIG || '{}');
// CEL-107: there used to be one server per workspace, each polling the same
// herdr and gh as the others, and the per-workspace restart race took one of
// them down. Now one server carries every workspace; a config without the
// list (an old launcher, a test fixture) is a list of one.
const WORKSPACES = Array.isArray(cfg.workspaces) && cfg.workspaces.length ? cfg.workspaces
  : [{ name: cfg.name, wsdir: cfg.wsdir, repos: cfg.repos, services: cfg.services, linearTeams: cfg.linearTeams, triggerState: cfg.triggerState }];
if (!cfg.name) Object.assign(cfg, { name: WORKSPACES[0].name, wsdir: WORKSPACES[0].wsdir, repos: WORKSPACES[0].repos || [] });
// ?ws=<name> picks the workspace an /api/state read covers; absent means the
// first. Unknown is null, so the caller can say so rather than show another.
const wsOf = (name) => (name ? WORKSPACES.find((w) => w.name === name) || null : WORKSPACES[0]);
const wsParam = (req) => new URL(req.url || '/', 'http://x').searchParams.get('ws') || '';
// The plane's own directory name is the reader's choice, so resolve it from
// this file (tools/dash/server.mjs -> two levels up) the way bin/cel does.
// A hardcoded fallback meant anyone who cloned under a different name got a
// dashboard reading role files out of a directory that did not exist.
const CEL_ROOT = process.env.CEL_ROOT || join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const FX_DIR = process.env.CEL_EFFECTS_DIR || join(homedir(), '.local/share/cel/vendor/canvasui');
const WORKTREES = join(homedir(), '.herdr', 'worktrees');
const security = controlSecurity({
  host: cfg.host || '127.0.0.1', port: cfg.port || 7770,
  trustedOrigins: process.env.CEL_DASH_TRUSTED_ORIGINS,
  csrfToken: process.env.CEL_DASH_CSRF_TOKEN,
});
// files the pages load by name; anything else under / is not served
const STATIC_FILES = new Set(['/factory.js', '/factory.css', '/decisions.js', '/decisions.css', '/v2.js', '/v2.css']);
const UPDATE_DIR = process.env.CEL_UPDATE_DIR || join(homedir(), '.local/share/cel/update');

// The steward writes this file hours after the dashboard booted, so it is read
// PER REQUEST and spliced into the shell below - a chip captured at startup
// would never appear at all. It holds either a release version (`0.3.0`) or,
// on the main channel, a distance and the sha the build came from
// (`main+7 d43910c`): on main the tag never moves, so a version is not a thing
// the chip can show.
const updateChip = () => {
  try {
    const v = readFileSync(join(UPDATE_DIR, 'available'), 'utf8').trim();
    const main = /^main\+([0-9]+)\b/.exec(v);
    if (main) return '<span id="upd" title="the steward saw new commits on main">main +' + main[1] + ' \u2192 cel update</span>';
    if (!/^[0-9][0-9a-zA-Z.\-]*$/.test(v)) return '';
    return '<span id="upd" title="the steward saw a newer release">update available v' + v + ' \u2192 cel update</span>';
  } catch { return ''; }
};

const run = (cmd, args, timeout = 15000) =>
  new Promise((resolve) =>
    execFile(cmd, args, { timeout, maxBuffer: 4 * 1024 * 1024 }, (err, out) =>
      resolve(err ? null : out)));

// Each upstream has its own staleness budget: pane state is cheap and local,
// gh burns rate limit.
const cache = {};
const cached = async (key, ttlMs, fn) => {
  const c = cache[key];
  if (c && Date.now() - c.t < ttlMs) return c.v;
  const v = await fn();
  cache[key] = { t: Date.now(), v };
  return v;
};

const agents = () => cached('agents', 8000, async () => {
  const out = await run('herdr', ['agent', 'list']);
  if (!out) return [];
  try { return JSON.parse(out).result.agents || []; } catch { return []; }
});

const wsLabels = () => cached('wslabels', 30000, async () => {
  const out = await run('herdr', ['workspace', 'list']);
  const m = {};
  try {
    for (const w of JSON.parse(out).result.workspaces || []) m[w.workspace_id] = w.label;
  } catch { /* no herdr, no labels */ }
  return m;
});

const prs = (w) => cached(`prs:${w.name}`, 60000, async () => {
  const fields = 'number,title,headRefName,isDraft,reviewDecision,url,statusCheckRollup,author';
  const all = [];
  await Promise.all((w.repos || []).map(async (r) => {
    if (!r.slug) return;
    const out = await run('gh', ['pr', 'list', '--repo', r.slug, '--json', fields, '--limit', '30'], 20000);
    let list = [];
    try { list = JSON.parse(out || '[]'); } catch { /* gh error page */ }
    for (const p of list) {
      const checks = p.statusCheckRollup || [];
      const bad = checks.filter((c) => ['FAILURE', 'ERROR'].includes(c.conclusion || c.state)).length;
      const pending = checks.filter((c) => !c.conclusion && (c.status || c.state) !== 'COMPLETED' && c.state !== 'SUCCESS').length;
      all.push({
        repo: r.name, number: p.number, title: p.title, branch: p.headRefName,
        url: p.url, draft: p.isDraft, review: p.reviewDecision || 'NONE',
        author: p.author?.login || '',
        checks: checks.length === 0 ? 'none' : bad ? 'failing' : pending ? 'pending' : 'green',
      });
    }
  }));
  return all;
});

// The delegation ledger, joined onto worktree rows by branch: which model
// built it, what shape it is, and the VERDICT collect recorded - gate result,
// red-then-green, CI, review. The table used to show only what herdr and gh
// knew; this is what the plane itself knows.
const ledger = (w) => cached(`ledger:${w.name}`, 5000, async () => {
  const f = join(w.wsdir, '.cel', 'delegations.json');
  if (!existsSync(f)) return {};
  try {
    // CEL-116: parsed once per change, shared with the v2 feeds
    const rows = store.json(f);
    if (!Array.isArray(rows)) return {};
    const by = {};
    // herdr lowercases worktree directory names; the ledger keeps the branch
    // as written. Join case-insensitively or nothing ever matches.
    for (const r of rows) if (r && r.branch) by[(r.repo + '/' + r.branch).toLowerCase()] = r;
    return by;
  } catch { return {}; }
});

const worktreeRows = async (w) => {
  const ag = await agents();
  const labels = await wsLabels();
  const led = await ledger(w);
  const rows = [];
  for (const r of w.repos || []) {
    const dir = join(WORKTREES, r.name);
    if (!existsSync(dir)) continue;
    for (const branch of readdirSync(dir)) {
      const path = join(dir, branch);
      const a = ag.find((x) => x.cwd === path);
      const l = led[(r.name + '/' + branch).toLowerCase()] || null;
      rows.push({
        repo: r.name, branch, path,
        agent: a ? a.agent : null,
        pane: a ? a.pane_id : null,
        status: a ? a.agent_status : null,
        label: a ? labels[a.workspace_id] || branch : branch,
        model: l ? l.model || null : null,
        shape: l ? l.shape || 'ship' : null,
        why: l ? l.profile_reason || null : null,
        verdict: l ? l.verdict || null : null,
      });
    }
  }
  return rows;
};

// Orchestrator-ish agents in this workspace's own dirs (root pane, repo
// orchestrators, reviewers) - anything promptable that is not a worktree.
const wsAgents = async (w) => {
  const ag = await agents();
  const labels = await wsLabels();
  return ag
    .filter((a) => a.cwd && (a.cwd === w.wsdir || a.cwd.startsWith(w.wsdir + '/')))
    .map((a) => ({
      agent: a.agent, status: a.agent_status, cwd: a.cwd, pane: a.pane_id,
      label: labels[a.workspace_id] || a.pane_id,
    }));
};

// Whose PRs count as "mine": the login behind the gh token the whole plane
// publishes and reviews with.
const viewer = () => cached('viewer', 3600000, async () => {
  const out = await run('gh', ['api', 'user', '-q', '.login'], 20000);
  return (out || '').trim();
});

// The workspace inbox: agent-to-agent mail that deliberately never types
// into a pane, so the dashboard is where a human watches it move. Read
// straight off the JSONL - no cursor is touched here, looking is not reading.
const INBOX_DIR = process.env.CEL_INBOX_DIR || join(homedir(), '.local', 'share', 'cel', 'inbox');
const TRIAGE_CACHE = () => process.env.CEL_TRIAGE_CACHE || join(INBOX_DIR, 'triage.cache');
const triageRanks = () => {
  const out = new Map();
  let text;
  try { text = readFileSync(TRIAGE_CACHE(), 'utf8'); } catch { return out; }
  for (const line of text.split('\n')) {
    const [id, rank] = line.split('\t');
    const n = Number(rank);
    if (id && Number.isFinite(n)) out.set(id, n);
  }
  return out;
};
const inbox = (w) => cached(`inbox:${w.name}`, 8000, async () => {
  const f = join(INBOX_DIR, `${w.name}.jsonl`);
  if (!existsSync(f)) return { items: [], byWho: [], open: [] };
  // CEL-116: the shared, append-aware parse; never mutated below
  const items = store.jsonl(f);
  // unread = after each recipient's cursor, so the dash agrees with cel inbox
  const cursor = (who) => {
    const c = join(INBOX_DIR, `${w.name}.${who}.cursor`);
    try { return readFileSync(c, 'utf8').trim(); } catch { return ''; }
  };
  const cursors = {};
  for (const it of items) if (!(it.to in cursors)) cursors[it.to] = cursor(it.to);
  // Decisions are a LEDGER, not a queue: a `decision`/`blocked` item stays
  // open until a `resolution` record names its id, however many reads moved
  // the cursor past it. Resolution records themselves are bookkeeping and
  // never render as mail.
  const resolved = new Set(items.filter((it) => it.kind === 'resolution').map((it) => it.ref));
  const mail = items.filter((it) => it.kind !== 'resolution');
  const open = mail
    .filter((it) => (it.kind === 'decision' || it.kind === 'blocked') && !resolved.has(it.id))
    .map((it) => ({ id: it.id, ts: it.ts, to: it.to, from: it.from, kind: it.kind, message: it.message }));
  const marked = mail.map((it) => ({ ...it, unread: !cursors[it.to] || it.id > cursors[it.to] }));
  // CEL-43: THE SAME ORDER THE CONSOLE DRAWS. A level per message comes from a
  // decision model through lib/triage.sh, which scores each id once and writes
  // `<id>\t<rank>` to a cache; this card reads the cache and does the ordering
  // itself - the model supplies the level and nothing else. No cache (or no
  // model) is today's ordering, by the kind's own default, not a loss.
  const ranks = triageRanks();
  const KIND_RANK = { blocked: 3, decision: 2, escalation: 2, update: 1, status: 0 };
  for (const it of marked) it.rank = ranks.has(it.id) ? ranks.get(it.id) : (KIND_RANK[it.kind] ?? 0);
  // "Are the inboxes backed up?" should be answerable without counting rows:
  // per recipient, how many unread and how long the OLDEST has waited.
  const byWho = {};
  for (const it of marked) {
    const w = byWho[it.to] || (byWho[it.to] = { who: it.to, total: 0, unread: 0, oldest: null });
    w.total += 1;
    if (it.unread) { w.unread += 1; if (!w.oldest) w.oldest = it.ts; }
  }
  // Unread first, most urgent first inside that, newest first inside a level:
  // the top of this card is what a person should answer next, and read mail
  // keeps its old newest-first shape underneath.
  const shown = marked.slice(-40).reverse().sort((a, b) =>
    (Number(b.unread) - Number(a.unread)) || (b.rank - a.rank));
  return { items: shown, byWho: Object.values(byWho).sort((a, b) => b.unread - a.unread), open };
});

// My Linear queue, SCOPED TO THIS WORKSPACE's teams (repos' linear_team
// keys). A workspace dashboard that showed every ticket in the account would
// mix a client's board into your side project - the whole point of a
// workspace is that it bounds what you are looking at. No teams declared =
// no scoping possible = no card, rather than a misleading everything-list.
// Only when the key is in the environment; no key, no card, never an error.
const linear = (w) => cached(`linear:${w.name}`, 120000, async () => {
  if (!process.env.LINEAR_API_KEY) return null;
  const teams = w.linearTeams || [];
  if (!teams.length) return null;
  // TWO issue sets, deliberately. Active work is fetched unfiltered by state
  // so a busy board can never starve it, and finished work is fetched
  // SEPARATELY and capped - otherwise the most-recent-N would eventually be
  // all Done tickets and the columns that matter would empty out.
  //
  // `states` comes from the team itself: the kanban must show the statuses
  // this Linear team actually has, not a set we invented. Ordering needs the
  // TYPE as well as the position, because Linear positions are per-type and
  // "In Review" sits at 1002 here - sorting on position alone would file it
  // after Canceled.
  const ISSUE_FIELDS = `identifier title url priority priorityLabel updatedAt
              state { name type } team { key }`;
  const query = `query { organization { urlKey }
    teams(filter: { key: { in: ${JSON.stringify(teams)} } }) {
      nodes { key states(first: 40) { nodes { name type position color } } } }
    viewer { name
      active: assignedIssues(first: 60,
        filter: { state: { type: { nin: ["completed", "canceled", "duplicate"] } } },
        orderBy: updatedAt) { nodes { ${ISSUE_FIELDS} } }
      finished: assignedIssues(first: 15,
        filter: { state: { type: { in: ["completed", "canceled", "duplicate"] } } },
        orderBy: updatedAt) { nodes { ${ISSUE_FIELDS} } } } }`;
  try {
    const r = await fetch('https://api.linear.app/graphql', {
      method: 'POST',
      headers: { authorization: process.env.LINEAR_API_KEY, 'content-type': 'application/json' },
      body: JSON.stringify({ query }),
      signal: AbortSignal.timeout(15000),
    });
    if (!r.ok) return null;
    const j = await r.json();
    const v = j?.data?.viewer;
    const nodes = v && [...(v.active?.nodes || []), ...(v.finished?.nodes || [])];
    if (!nodes) return null;

    // One ordered column list across every team the workspace declares.
    // De-duplicated by name: two teams sharing "In Progress" is one column.
    const TYPE_RANK = { backlog: 0, unstarted: 1, started: 2, completed: 3, canceled: 4, duplicate: 5 };
    const seen = new Map();
    for (const t of j?.data?.teams?.nodes || []) {
      for (const s of t.states?.nodes || []) {
        if (!seen.has(s.name)) seen.set(s.name, s);
      }
    }
    const states = [...seen.values()].sort((a, b) =>
      (TYPE_RANK[a.type] ?? 9) - (TYPE_RANK[b.type] ?? 9) || a.position - b.position);

    return {
      me: v.name,
      urlKey: j.data.organization?.urlKey || '',
      teams,
      trigger: w.triggerState || '',
      states: states.map((s) => ({ name: s.name, type: s.type, color: s.color })),
      issues: nodes.filter((i) => teams.includes(i.team?.key)).map((i) => ({
        id: i.identifier, title: i.title, url: i.url, team: i.team?.key || '',
        state: i.state?.name || '', type: i.state?.type || '',
        // Linear's numeric priority is 0=none, 1=Urgent .. 4=Low, so "no
        // priority" sorts as if it were the MOST urgent thing you own. Remap
        // it to 5 so the column reads strictly most-urgent-first and unset
        // work falls to the bottom where it belongs.
        pri: i.priority === 0 || i.priority == null ? 5 : i.priority,
        priority: i.priorityLabel || '', updated: i.updatedAt,
      })).sort((a, b) => a.pri - b.pri || (a.updated < b.updated ? 1 : -1)),
    };
  } catch { return null; }
});

// WHAT IS RUNNING ON A PORT, asked of the plane rather than re-derived here.
// `cel services --json` already joins the declared services to the previews
// `try` started and answers state, health, memory and reach; a second
// implementation in JavaScript would be a second answer to one question.
const services = (w) => cached(`services:${w.name}`, 5000, async () => {
  const out = await run(join(CEL_ROOT, 'bin/cel'), ['services', '--workspace', w.name, '--json'], 10000);
  // ALWAYS A LIST. A `cel` that answers something else - an old build, a
  // wrapper, an error document - used to flow straight into the card; since
  // CEL-43 partitions these rows, a non-array reached `.filter` and took the
  // whole /api/state read down with it, on every request, until a restart.
  try { const doc = JSON.parse(out || '[]'); return Array.isArray(doc) ? doc : []; } catch { return []; }
});

// THE PROXY ONLY CARRIES PORTS THIS WORKSPACE KNOWS. A tailnet neighbour who
// can reach the dashboard must not be able to browse this box's loopback by
// walking port numbers - so the allowed set is exactly the ports of the
// services and previews above, and everything else is 404.
const proxyPorts = async () => new Set((await Promise.all(WORKSPACES.map(services))).flat()
  .map((s) => Number(s.port)).filter((p) => Number.isInteger(p) && p > 0 && p < 65536));

// ...and only with the dash's own control token, the one its control
// endpoints require. A browser cannot set a header on a plain navigation, so
// the token may also arrive as `?cel_token=` (which is then parked in a
// cookie scoped to /svc/, because a dev server's own assets are fetched
// without the query string that got you there).
const COOKIE = 'cel_svc_token';
const tokenOk = (value) => {
  const supplied = String(value || '');
  if (supplied.length !== security.token.length) return false;
  try { return timingSafeEqual(Buffer.from(supplied), Buffer.from(security.token)); } catch { return false; }
};
const proxyToken = (req, url) => {
  if (tokenOk(req.headers['x-cel-csrf'])) return { ok: true, fromQuery: false };
  const q = url.searchParams.get('cel_token');
  if (tokenOk(q)) return { ok: true, fromQuery: true };
  const jar = String(req.headers.cookie || '').split(';')
    .map((c) => c.trim().split('='));
  const c = jar.find((p) => p[0] === COOKIE);
  if (c && tokenOk(decodeURIComponent(c[1] || ''))) return { ok: true, fromQuery: false };
  return { ok: false, fromQuery: false };
};

const SVC_RE = /^\/svc\/(\d{1,5})(\/[^?]*)?(\?.*)?$/;

const backlog = (w) => cached(`backlog:${w.name}`, 15000, async () => {
  const f = join(w.wsdir, 'backlog.yaml');
  if (!existsSync(f)) return null;
  const out = await run('yq', ['.', f]);
  try { return JSON.parse(out); } catch { return null; }
});

// The joined view the page actually renders. A worktree and a PR on the same
// branch are one piece of work; a worktree with no agent AND no open PR is
// stale noise (cel gc food), collapsed to a count.
// A branch named for its ticket (ABC-3-slug) is the join between the fleet
// and the board, so the in-flight row can link straight to Linear.
const TICKET_RE = /^([A-Z][A-Z0-9]*-\d+)/;
const ticketOf = (branch, teams, urlKey) => {
  const m = TICKET_RE.exec(String(branch || '').toUpperCase());
  if (!m) return null;
  const id = m[1];
  if (teams.length && !teams.some((t) => id.startsWith(t + '-'))) return null;
  return { id, url: urlKey ? `https://linear.app/${urlKey}/issue/${id}` : null };
};

// Pane ids are herdr's coordinates, not names a human knows. Everything the
// dashboard SHOWS resolves to the label from the sidebar, with the id kept
// only as a tooltip and as the address the prompt/focus endpoints need.
const paneNames = async () => {
  const ag = await agents();
  const labels = await wsLabels();
  const m = {};
  for (const a of ag) m[a.pane_id] = a.name || labels[a.workspace_id] || a.pane_id;
  return m;
};

// THE SUBSCRIPTIONS, from the same 60 s cache `cel fleet` reads.
//
// THE SUBSCRIPTIONS, from `cel fleet --json` and from nowhere else.
//
// This card used to merge `cel quota --json` with `cel gateway status --json`
// itself while the console read the fleet document, so the two surfaces
// answered "which subscriptions does this box have" differently: the owner,
// 2026-09-19, "The TUI is not showing any usage other than claude; the
// dashboard is showing all usage". CEL-35 makes the fleet document the one
// list - direct logins and gateway accounts, already folded - and the card
// draws it without a merge of its own.
//
// Cached a minute, like the windows it reports: they move in hours, and the
// fleet read walks /proc once for the whole box.
// Box material - box services, subscriptions, the gateway panel - used to be
// drawn by whichever of four per-workspace dashboards the `dash.box` flag
// named (CEL-43), because four copies of one broker read as four brokers.
// With one dashboard for the box (CEL-107) there is nothing to choose: it is
// drawn here, once.
const REGISTRY = () => process.env.CEL_REGISTRY || join(homedir(), '.local/share/cel/registry.yaml');

// CEL-80: THE CARD IS `cel quota --json`, the rows `cel quota` prints. The
// fleet document is the cached copy of the same list and is only as fresh as
// the last live read, so on a box where nobody had run `cel quota` lately the
// card showed nothing or yesterday's accounts. Asked only by the one
// dashboard that draws the card, a minute apart; the fleet cache is the
// fallback when the live read fails.
const subscriptions = () => cached('subs', 60000, async () => {
  try {
    const q = JSON.parse(await run(join(CEL_ROOT, 'bin/cel'), ['quota', '--json'], 45000) || '{}');
    if (Array.isArray(q.subscriptions)) return q.subscriptions;
  } catch { /* fall through to the cached copy */ }
  try {
    const doc = JSON.parse(await run(join(CEL_ROOT, 'bin/cel'), ['fleet', '--json'], 20000) || '{}');
    return Array.isArray(doc.subscriptions) ? doc.subscriptions : [];
  } catch { return []; }
});

// The gateway's own web panel (CEL-80). It listens on loopback only, so the
// card links it only when this page is itself being viewed on loopback - over
// the ssh tunnel, or on the box - and shows the tunnel line otherwise. A link
// that works only on the box, shown on the tailnet, is an invitation to
// expose the panel to make it work.
const gatewayPanel = () => cached('gwpanel', 600000, async () => {
  try {
    const d = JSON.parse(await run(join(CEL_ROOT, 'bin/cel'), ['gateway', 'panel', '--json'], 8000) || 'null');
    return d && d.url ? { url: String(d.url), ssh: String(d.ssh || '') } : null;
  } catch { return null; }
});
const isLoopback = (addr) => /^(127\.|::1$|::ffff:127\.)/.test(String(addr || ''));

// NEEDS YOU (CEL-93): the owner's decisions across every workspace, read from
// `cel decide list --json` so the board and the CLI cannot disagree about
// what is open. Answering goes back through `cel decide answer|drop` - one
// writer path, so the asker is told through its inbox exactly as from a shell.
// How often the page polls; a test sets it short so "two refreshes" is seconds.
const REFRESH_MS = Math.min(8000, Math.max(500, Number(cfg.refreshMs) || 8000));
const decisions = () => cached('decisions', REFRESH_MS, async () => {
  const out = await run(join(CEL_ROOT, 'bin/cel'), ['decide', 'list', '--json'], 10000);
  if (!out) return [];
  return out.split('\n').filter(Boolean).flatMap((l) => { try { return [JSON.parse(l)]; } catch { return []; } });
});

// CEL-99: 53 decisions in one flat list, in whatever order the CLI read the
// mailboxes, was a list nobody could work through. Grouped by workspace (the
// owner thinks per project), and inside a group: urgent first, then what
// blocks something, then oldest - the order an owner should answer in.
const decisionRank = (d) => (d.urgent ? 0 : 2) + ((d.blocks || '') ? 0 : 1);
const orderDecisions = (list) => [...list].sort((a, b) =>
  decisionRank(a) - decisionRank(b) || (b.age_secs || 0) - (a.age_secs || 0));
const groupDecisions = (list) => {
  const by = new Map();
  for (const d of orderDecisions(list)) {
    const ws = d.workspace || '?';
    if (!by.has(ws)) by.set(ws, []);
    by.get(ws).push(d);
  }
  return [...by.entries()].map(([workspace, items]) => ({
    workspace, count: items.length,
    urgent: items.filter((d) => d.urgent).length,
    recommended: items.filter((d) => d.recommended).length,
    items,
  })).sort((a, b) => b.urgent - a.urgent || a.workspace.localeCompare(b.workspace));
};

// One answer, one `cel decide` call: the single and the bulk endpoint share
// it so "accept all" cannot take a path the guarded single answer does not.
const decideOne = async ({ id, action, value, option }) => {
  const v = String(value || '').trim();
  if (!/^\d{10,25}$/.test(String(id || ''))) return { code: 400, error: 'bad decision id' };
  if (!['answer', 'drop'].includes(action)) return { code: 400, error: 'action must be answer or drop' };
  const byIndex = action === 'answer' && option !== undefined && option !== null;
  if (byIndex && !(Number.isInteger(option) && option >= 1 && option <= 99)) return { code: 400, error: 'bad option' };
  if (!byIndex && (!v || v.length > 2000)) return { code: 400, error: action === 'drop' ? 'a reason is required' : 'an answer is required' };
  const args = action === 'drop'
    ? ['decide', 'drop', String(id), '--why', v, '--by', 'dashboard']
    : byIndex ? ['decide', 'answer', String(id), '--option', String(option), '--by', 'dashboard']
      : ['decide', 'answer', String(id), '--text', v, '--by', 'dashboard'];
  const out = await run(join(CEL_ROOT, 'bin/cel'), args, 15000);
  delete cache.decisions;
  if (out === null) return { code: 409, error: 'not recorded: already answered, or no such option' };
  return { code: 200 };
};

const state = async (req, w) => {
  const needsYou = orderDecisions(await decisions());
  const needsYouGroups = groupDecisions(needsYou);
  const [wts, prList, ags, bl, me, mail, lin, pnames, subs, svcs, gwp] = await Promise.all([worktreeRows(w), prs(w), wsAgents(w), backlog(w), viewer(), inbox(w), linear(w), paneNames(), subscriptions(), services(w), gatewayPanel()]);
  // A PARTITION, NOT A NEW QUERY: `cel services --json` has tagged every row
  // with the workspace that owns it since CEL-34, and `box` is the tag for
  // what belongs to nobody. A workspace's panel lists its own rows only.
  const wsServices = svcs.filter((x) => (x.workspace || w.name) !== 'box');
  const boxServices = svcs.filter((x) => (x.workspace || '') === 'box');
  // an inbox line addressed to or from a pane shows that pane's name
  for (const m2 of mail.items) {
    m2.fromName = /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(m2.from) ? (pnames[m2.from] || m2.from) : m2.from;
    m2.toName = /^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(m2.to) ? (pnames[m2.to] || m2.to) : m2.to;
  }
  const byBranch = Object.fromEntries(prList.map((p) => [`${p.repo}/${p.branch}`, p]));
  const claimed = new Set();
  const inflight = [];
  const stale = [];
  for (const w of wts) {
    const pr = byBranch[`${w.repo}/${w.branch}`] || null;
    if (pr) claimed.add(pr);
    if (!pr && !w.agent) { stale.push(w); continue; }
    inflight.push({ ...w, pr });
  }
  for (const p of prList) if (!claimed.has(p)) inflight.push({ repo: p.repo, branch: p.branch, agent: null, pane: null, status: null, pr: p });
  // attach the ticket each branch names, if any
  for (const it of inflight) it.ticket = ticketOf(it.branch, lin?.teams || [], lin?.urlKey || '');

  const attention = [];
  for (const it of inflight) {
    const p = it.pr;
    if (p && !p.draft && p.review === 'APPROVED' && p.checks !== 'failing')
      attention.push({ kind: 'merge', text: `${p.repo}#${p.number} approved${p.checks === 'green' ? ', checks green' : ''} - ready for YOUR merge`, title: p.title, url: p.url });
    else if (p && p.checks === 'failing')
      attention.push({ kind: 'red', text: `${p.repo}#${p.number} checks FAILING${it.agent ? ` (${it.status} ${it.agent} on it)` : ' - nobody on it'}`, title: p.title, url: p.url });
    else if (p && p.review === 'CHANGES_REQUESTED' && (!it.agent || it.status !== 'working'))
      attention.push({ kind: 'stall', text: `${p.repo}#${p.number} changes requested, ${it.agent ? `worker ${it.status}` : 'no worker on the branch'}`, title: p.title, url: p.url });
    if (it.status === 'blocked')
      attention.push({ kind: 'blocked', text: `${it.repo}/${it.branch}: agent BLOCKED, waiting on input`, title: it.label, url: null });
  }
  for (const a of ags) if (a.status === 'blocked')
    attention.push({ kind: 'blocked', text: `${a.label}: agent BLOCKED, waiting on input`, title: a.cwd, url: null });
  // Fresh mail is delivered by a monitor or the prompt hook; mail still
  // unread after 30 minutes means neither is running.
  const stuck = mail.items.filter((m) => m.unread && Date.now() - new Date(m.ts).getTime() > 1800e3);
  if (stuck.length)
    attention.push({ kind: 'stall',
      text: `${stuck.length} inbox item(s) unread 30m+ (to ${[...new Set(stuck.map((m) => m.to))].join(', ')}) - is the recipient's monitor running?`,
      title: stuck[0].message.slice(0, 90), url: null });

  return {
    workspace: w.name, workspaces: WORKSPACES.map((x) => x.name), updated: new Date().toISOString(), viewer: me,
    attention, inflight, stale: stale.map((w) => `${w.repo}/${w.branch}`),
    agents: ags, services: wsServices, boxServices, backlog: bl, inbox: mail.items, inboxBy: mail.byWho, inboxOpen: mail.open || [], needsYou, needsYouGroups, linear: lin,
    // One list, two doors: a signed-in subscription and a gateway account are
    // the same thing to whoever is reading the card - `source` says which, and
    // `cel fleet` decided both before this line ran.
    subscriptions: subs,
    // the socket, never X-Forwarded-For: a header is whatever the client says
    gatewayPanel: gwp ? { ...gwp, loopback: isLoopback(req && req.socket && req.socket.remoteAddress) } : null,
  };
};

const htmlText = (value) => String(value ?? '').replace(/[&<>"]/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));


const readBody = async (req, max = 20000) => {
  let body = '';
  for await (const c of req) { body += c; if (body.length > max) throw new Error('body too large'); }
  return JSON.parse(body || '{}');
};

// One line per request on stderr (so it lands in the dash log). Without it,
// "I refreshed and nothing changed" is unanswerable: you cannot tell a stale
// browser from a request that never arrived.
// A LOG LINE IS A PLACE A SECRET CAN END UP. The proxy accepts its control
// token as a query parameter, because a browser cannot set a header on a
// plain navigation - and the first cut of this printed `req.url` verbatim, so
// clicking a service link wrote the dash's control token, in cleartext, into
// a log that outlives the process. Redaction lives in the ONE function that
// writes a request line rather than at each call site, where the next one
// would be forgotten.
const SECRET_PARAMS = /\b(cel_token|token|access_token|authorization|api_key|key)=[^&\s]*/gi;
const safeUrl = (url) => String(url || '').replace(SECRET_PARAMS, (m) => `${m.split('=')[0]}=REDACTED`);

const logReq = (req, code) => {
  const ua = String(req.headers['user-agent'] || '-').slice(0, 40);
  console.error(`${new Date().toISOString()} ${req.method} ${safeUrl(req.url)} ${code} ${req.headers.host || '-'} "${ua}"`);
};

// CEL-105: the v2 page's feeds and its one named-action door, in their own
// module so this file does not grow another thousand lines.
const v2 = createV2({ cfg, run, cached, cache, CEL_ROOT, INBOX_DIR, REGISTRY, agents });

// CEL-116 (live check of #141): /api/state is what the Needs-you card and
// the header count are drawn from, and it was the one thing a refresh still
// waited 3-4 s for - the feeds painted, Needs-you said 0, then jumped to 14.
// It is served warm now, like the v2 feeds: the last answer at once, a
// refresh behind it past CEL_DASH_STATE_TTL_MS (default the page refresh, at most 5 s), kept warm for a
// minute after a page last asked. A failed read is never kept: cold, it
// answers 500 as before; warm, the last good answer stands. Any POST may have
// changed it (a resolve, a decision), so a POST forgets every answer.
// A warm answer is only served while the files it was read from are as they
// were: a new inbox line (a decision asked, a resolution) or a ledger write
// is the very thing the owner is waiting to see, so it drops the warm answer
// and the upstream caches that would hide it, and the ask computes fresh.
const states = new Map();
const fileSig = (f) => { try { const st = statSync(f); return `${st.size}:${st.mtimeMs}`; } catch { return '-'; } };
const stateSig = () => WORKSPACES.map((x) => `${fileSig(join(INBOX_DIR, `${x.name}.jsonl`))}/${fileSig(join(x.wsdir, '.cel', 'delegations.json'))}`).join('|');
const warmState = (w, warmer = false) => {
  let f = states.get(w.name);
  if (!f) { f = { v: undefined, at: 0, p: null, gen: 0, have: 0 }; states.set(w.name, f); }
  if (!warmer) f.asked = Date.now();
  const sig = stateSig();
  // Every computation resolves to ITS OWN answer, and is kept only if no
  // later-started one has landed first. Review on #141: a request waiting on
  // a computation that a newer file change superseded used to wake to an
  // emptied entry and answer 500 - the classic page's refresh failed right
  // after every mutation, which is exactly when the owner is mid-thought.
  const refresh = () => {
    if (f.p && f.psig === sig) return f.p;
    const gen = ++f.gen;
    const p = state(null, w).then((v) => {
      const r = { v, at: Date.now() };
      if (gen > f.have) { f.have = gen; f.v = v; f.at = r.at; f.sig = sig; }
      return r;
    }).finally(() => { if (f.p === p) f.p = null; });
    f.p = p; f.psig = sig;
    return p;
  };
  if (f.v !== undefined && f.sig !== sig) {
    // the files moved: this ask waits for an answer read after the change,
    // as it always did, and the caches that would hide the change go first
    delete cache.decisions;
    for (const x of WORKSPACES) { delete cache[`inbox:${x.name}`]; delete cache[`ledger:${x.name}`]; }
    return refresh();
  }
  if (f.v === undefined || warmer) return refresh();
  if (Date.now() - f.at >= STATE_TTL()) refresh().catch(() => {});
  return Promise.resolve({ v: f.v, at: f.at });
};
// The warm read runs AHEAD of the page's poll, once per state TTL: the
// classic page prints the answer's own `updated` time, and polls every
// REFRESH_MS - served from a value refreshed only when an ask found it stale,
// every other poll repeated the last answer and the page fell a refresh
// behind (review on #141). Ahead of the poll, each poll gets a read at most
// one TTL old, as fresh as the per-request read it replaces, and every open
// tab shares it.
const STATE_TTL = () => Number(process.env.CEL_DASH_STATE_TTL_MS) || Math.min(5000, REFRESH_MS);
setInterval(() => {
  for (const [k, f] of states) {
    if (Date.now() - f.asked > 60000) { states.delete(k); continue; }
    if (!f.p && Date.now() - f.at >= STATE_TTL() / 2) {
      const w = wsOf(k);
      if (w) warmState(w, true).catch(() => {});
    }
  }
}, STATE_TTL()).unref();

const server = createServer(async (req, res) => {
  if (req.method === 'POST') states.clear();
  res.on('finish', () => logReq(req, res.statusCode));
  try {
    if (!security.allow(req, res)) return;
    // THE REVERSE PROXY. Every dev server and every preview on this box binds
    // 127.0.0.1, which from the owner's laptop is the laptop. The dashboard
    // already listens on the tailnet IP, so it carries them: /svc/<port>/… is
    // forwarded to loopback, for known ports only, with the control token.
    const svc = SVC_RE.exec(req.url || '');
    if (svc) {
      const url = new URL(req.url, 'http://localhost');
      const port = Number(svc[1]);
      const auth = proxyToken(req, url);
      if (!auth.ok) { res.writeHead(403, { 'content-type': 'text/plain' }).end('proxy requires the dash control token'); return; }
      if (!(await proxyPorts()).has(port)) { res.writeHead(404).end('no service or preview on that port'); return; }
      // ...AND IT NEVER TRAVELS FURTHER THAN THE FIRST REQUEST. A token in a
      // query string survives in browser history, in a Referer handed to the
      // dev server, and in anything downstream that logs a URL. So the
      // query-param form is exchanged for the scoped cookie and bounced once
      // to the SAME path without it: every request after the bounce - and
      // every asset the page then fetches - carries no credential at all.
      // GET and HEAD only; bouncing a bodied method would drop its body.
      if (auth.fromQuery && (req.method === 'GET' || req.method === 'HEAD')) {
        url.searchParams.delete('cel_token');
        const clean = (svc[2] || '/') + (url.search && url.search !== '?' ? url.search : '');
        res.writeHead(302, {
          location: `/svc/${port}${clean}`,
          'set-cookie': `${COOKIE}=${encodeURIComponent(security.token)}; Path=/svc/; SameSite=Strict`,
        }).end();
        return;
      }
      url.searchParams.delete('cel_token');
      const path = (svc[2] || '/') + (url.search && url.search !== '?' ? url.search : '');
      const headers = { ...req.headers, host: `127.0.0.1:${port}` };
      delete headers['x-cel-csrf'];
      delete headers.cookie;
      const upstream = httpRequest({ hostname: '127.0.0.1', port, path, method: req.method, headers },
        (up) => {
          // the bounce above already handed back the cookie; a proxied
          // response never adds a Set-Cookie of the plane's own
          res.writeHead(up.statusCode || 502, { ...up.headers });
          up.pipe(res);
        });
      upstream.on('error', () => { if (!res.headersSent) res.writeHead(502).end('service did not answer'); else res.destroy(); });
      req.pipe(upstream);
      return;
    }
    if (await v2.handle(req, res, readBody)) return;
    if (req.method === 'GET' && req.url === '/api/session') {
      security.session(req, res);
      return;
    }
    if ((req.method === 'GET' || req.method === 'HEAD') && STATIC_FILES.has(req.url)) {
      const body = readFileSync(new URL('.' + req.url, import.meta.url));
      const type = req.url.endsWith('.js') ? 'text/javascript' : 'text/css';
      res.writeHead(200, { 'content-type': type + '; charset=utf-8', 'cache-control': 'no-cache' })
        .end(req.method === 'HEAD' ? undefined : body);
      return;
    }
    if (req.method === 'HEAD' && (req.url === '/api/state' || req.url.startsWith('/api/state?'))) {
      res.writeHead(200, { 'content-type': 'application/json' }).end();
      return;
    }
    if (req.method === 'GET' && req.url === '/fx/manifest.json') {
      // what this box has installed; empty is the normal case and the page
      // simply keeps its built-in sky
      let names = [];
      try {
        names = readdirSync(FX_DIR).filter((f) => f.endsWith('.js')).map((f) => f.slice(0, -3));
      } catch { /* nothing installed */ }
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ effects: names }));
      return;
    }
    if (req.method === 'GET' && req.url.startsWith('/fx/')) {
      const name = req.url.slice(4).replace(/\?.*$/, '');
      if (!/^[a-z0-9-]+\.js$/.test(name)) { res.writeHead(400).end('bad effect'); return; }
      const f = join(FX_DIR, name);
      if (!existsSync(f)) { res.writeHead(404).end('not installed'); return; }
      const body = readFileSync(f);
      res.writeHead(200, { 'content-type': 'text/javascript', 'cache-control': 'no-store' }).end(body);
      return;
    }
    if ((req.method === 'GET' || req.method === 'HEAD') && (req.url === '/' || req.url.startsWith('/?'))) {
      // v2 (CEL-106) is the front door. The shell is read per request, and
      // no-store, so a deploy shows up on the next reload.
      const body = readFileSync(new URL('./v2.html', import.meta.url), 'utf8')
        .replace('__CEL_CSRF__', security.token).replace('__CEL_BUILD__', htmlText(cfg.build)).replace('<!--UPDATE-CHIP-->', updateChip());
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store, must-revalidate' })
        .end(req.method === 'HEAD' ? undefined : body);
    } else if ((req.method === 'GET' || req.method === 'HEAD') && (req.url === '/classic' || req.url.startsWith('/classic?'))) {
      // CEL-123: the classic page is retired (no browser had opened it since
      // v2); a bookmark lands on the one dashboard instead of a 404.
      res.writeHead(302, { location: '/', 'cache-control': 'no-store' }).end();
    } else if (req.method === 'GET' && (req.url === '/api/state' || req.url.startsWith('/api/state?'))) {
      const w = wsOf(wsParam(req));
      if (!w) { res.writeHead(404).end('no such workspace'); return; }
      const r = await warmState(w);
      // the one per-request field: whether THIS caller is on loopback
      const v = r.v.gatewayPanel ? { ...r.v, gatewayPanel: { ...r.v.gatewayPanel, loopback: isLoopback(req.socket && req.socket.remoteAddress) } } : r.v;
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-cel-computed-at': new Date(r.at).toISOString() })
        .end(JSON.stringify(v));
    } else if (req.method === 'POST' && req.url === '/api/client-log') {
      // The effect boot happens in a browser I cannot see. Rather than guess
      // why nothing renders, the page reports which branch it took and that
      // lands in the dash log next to the request that fetched it.
      const { event, detail } = await readBody(req, 4000);
      console.error(`${new Date().toISOString()} CLIENT ${String(event || '?').slice(0, 40)} ${String(detail || '').slice(0, 300)}`);
      res.writeHead(204).end();
    } else if (req.method === 'POST' && req.url === '/api/focus') {
      // right-click -> "focus pane": the dashboard says where to look, herdr
      // does the looking
      const { pane } = await readBody(req, 500);
      if (!/^[A-Za-z0-9]+:[A-Za-z0-9]+$/.test(String(pane || ''))) { res.writeHead(400).end('bad pane id'); return; }
      const out = await run('herdr', ['pane', 'focus', String(pane)], 10000);
      res.writeHead(out === null ? 502 : 200).end(out === null ? 'focus failed' : 'ok');
    } else if (req.method === 'POST' && req.url === '/api/inbox-resolve') {
      // Closing a decision from the board. Appends a resolution record via
      // the same command an agent would use, so the ledger has one writer
      // path and the dash never invents its own format.
      const { id, ws } = await readBody(req, 2000);
      if (!/^\d{10,25}$/.test(String(id || ''))) { res.writeHead(400).end('bad decision id'); return; }
      const w = wsOf(String(ws || ''));
      if (!w) { res.writeHead(400).end('no such workspace'); return; }
      const out = await run(join(CEL_ROOT, 'bin/cel'),
        ['inbox', 'resolve', String(id), '--by', 'dashboard', '--workspace', w.name], 10000);
      if (out === null) { res.writeHead(502).end('could not resolve (already resolved, or not a decision?)'); return; }
      delete cache[`inbox:${w.name}`];
      res.writeHead(200).end('ok');
    } else if (req.method === 'POST' && req.url === '/api/decide') {
      // POST only, behind the same Host and CSRF guard as every other control
      // (security.allow above). The page confirms the exact text first.
      // An option is sent by its 1-based INDEX, never its label: a label of
      // "2" would otherwise read as option 2. Typed text goes as --text, so
      // digits in the box are the answer itself. A second submission (double
      // click, another tab) is refused by `cel decide`, which re-checks the
      // record is still open under the mailbox lock.
      let parsed;
      try { parsed = await readBody(req, 6000); } catch { res.writeHead(400).end('invalid request body'); return; }
      const r = await decideOne(parsed || {});
      res.writeHead(r.code).end(r.error || 'ok');
    } else if (req.method === 'POST' && req.url === '/api/decide-bulk') {
      // "accept all recommended": the page shows the exact list first, then
      // sends ids WITH the option it showed - never "whatever is recommended
      // now", which a re-ask could have changed in between. Each goes through
      // decideOne in turn; a refused one stays open and is reported.
      let parsed;
      try { parsed = await readBody(req, 20000); } catch { res.writeHead(400).end('invalid request body'); return; }
      const items = parsed && Array.isArray(parsed.items) ? parsed.items : null;
      if (!items || !items.length || items.length > 100) { res.writeHead(400).end('items: 1..100 required'); return; }
      const results = [];
      for (const it of items) {
        const r = await decideOne({ id: it && it.id, action: 'answer', option: it && it.option });
        results.push({ id: String((it && it.id) || ''), ok: r.code === 200, ...(r.error ? { error: r.error } : {}) });
      }
      res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ results }));
    } else if (req.method === 'POST' && req.url === '/api/ticket-state') {
      // Moving a ticket is how work is STARTED from the board: the trigger
      // state is what the steward watches for, so this endpoint is the
      // dashboard's half of "kick off a build".
      const { id, state: st } = await readBody(req, 2000);
      if (!/^[A-Z][A-Z0-9]*-\d+$/.test(String(id || ''))) { res.writeHead(400).end('bad ticket id'); return; }
      if (!String(st || '').match(/^[A-Za-z0-9 ._-]{1,40}$/)) { res.writeHead(400).end('bad state'); return; }
      const out = await run(join(CEL_ROOT, 'core/skills/linear/bin/cel-linear'),
        ['state', String(id), String(st)], 20000);
      if (out === null) { res.writeHead(502).end('cel-linear could not move it (key? state name?)'); return; }
      // the card must reflect the move immediately, whichever workspace shows it
      for (const k of Object.keys(cache)) if (k.startsWith('linear:')) delete cache[k];
      res.writeHead(200).end(out.trim() || 'ok');
    } else {
      res.writeHead(404).end('not found');
    }
  } catch (e) {
    internalError(res);
  }
});

// WEBSOCKET UPGRADES GO THROUGH TOO. A dev server that cannot upgrade is a
// page that never hot-reloads, which is most of what a preview is for. Raw
// sockets, no library: the request line and headers are rewritten once and
// everything after the 101 is bytes in both directions.
server.on('upgrade', async (req, socket, head) => {
  const svc = SVC_RE.exec(req.url || '');
  const refuse = (line) => { socket.write(`HTTP/1.1 ${line}\r\n\r\n`); socket.destroy(); };
  if (!svc) return refuse('404 Not Found');
  const url = new URL(req.url, 'http://localhost');
  const port = Number(svc[1]);
  if (!proxyToken(req, url).ok) return refuse('403 Forbidden');
  if (!(await proxyPorts()).has(port)) return refuse('404 Not Found');
  url.searchParams.delete('cel_token');
  const path = (svc[2] || '/') + (url.search && url.search !== '?' ? url.search : '');
  const up = connect(port, '127.0.0.1', () => {
    const lines = [`${req.method} ${path} HTTP/1.1`, `host: 127.0.0.1:${port}`];
    for (const [k, v] of Object.entries(req.headers)) {
      if (['host', 'cookie', 'x-cel-csrf'].includes(k)) continue;
      for (const one of [].concat(v)) lines.push(`${k}: ${one}`);
    }
    up.write(`${lines.join('\r\n')}\r\n\r\n`);
    if (head && head.length) up.write(head);
    up.pipe(socket);
    socket.pipe(up);
  });
  up.on('error', () => refuse('502 Bad Gateway'));
  socket.on('error', () => up.destroy());
});

server.listen(cfg.port || 7770, cfg.host || '127.0.0.1', () => {
  const a = server.address();
  console.log(`cel dash: ${WORKSPACES.map((w) => w.name).join(', ')} on http://${a.address}:${a.port}`);
});
