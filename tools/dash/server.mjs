// cel dash server - one per workspace, zero dependencies. Launched by
// lib/dash.sh with CEL_DASH_CONFIG (JSON: name, wsdir, port, host, repos
// [{name, slug}], services [{name, url}]).
//
// Reads live state by shelling out to the same CLIs the roles use (herdr,
// gh, yq) - no daemons, no state of its own. The CLI launcher defaults to the
// tailnet IP when available, otherwise loopback; --host overrides it. This
// private control surface requires trusted Host/Origin and CSRF checks.
import { createServer, request as httpRequest } from 'node:http';
import { connect } from 'node:net';
import { timingSafeEqual } from 'node:crypto';
import { execFile } from 'node:child_process';
import { readdirSync, existsSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

import { controlSecurity, internalError } from '../http-security.mjs';
const cfg = JSON.parse(process.env.CEL_DASH_CONFIG || '{}');
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

const prs = () => cached('prs', 60000, async () => {
  const fields = 'number,title,headRefName,isDraft,reviewDecision,url,statusCheckRollup,author';
  const all = [];
  await Promise.all((cfg.repos || []).map(async (r) => {
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
const ledger = () => cached('ledger', 5000, async () => {
  const f = join(cfg.wsdir, '.cel', 'delegations.json');
  if (!existsSync(f)) return {};
  try {
    const rows = JSON.parse(readFileSync(f, 'utf8'));
    const by = {};
    // herdr lowercases worktree directory names; the ledger keeps the branch
    // as written. Join case-insensitively or nothing ever matches.
    for (const r of rows) if (r && r.branch) by[(r.repo + '/' + r.branch).toLowerCase()] = r;
    return by;
  } catch { return {}; }
});

const worktreeRows = async () => {
  const ag = await agents();
  const labels = await wsLabels();
  const led = await ledger();
  const rows = [];
  for (const r of cfg.repos || []) {
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
const wsAgents = async () => {
  const ag = await agents();
  const labels = await wsLabels();
  return ag
    .filter((a) => a.cwd && (a.cwd === cfg.wsdir || a.cwd.startsWith(cfg.wsdir + '/')))
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
const inbox = () => cached('inbox', 8000, async () => {
  const f = join(INBOX_DIR, `${cfg.name}.jsonl`);
  if (!existsSync(f)) return { items: [], byWho: [], open: [] };
  const items = readFileSync(f, 'utf8').split('\n').filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter(Boolean);
  // unread = after each recipient's cursor, so the dash agrees with cel inbox
  const cursor = (who) => {
    const c = join(INBOX_DIR, `${cfg.name}.${who}.cursor`);
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
const linear = () => cached('linear', 120000, async () => {
  if (!process.env.LINEAR_API_KEY) return null;
  const teams = cfg.linearTeams || [];
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
      trigger: cfg.triggerState || '',
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
const services = () => cached('services', 5000, async () => {
  const out = await run(join(CEL_ROOT, 'bin/cel'), ['services', '--workspace', cfg.name, '--json'], 10000);
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
const proxyPorts = async () => new Set((await services())
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

const backlog = () => cached('backlog', 15000, async () => {
  const f = join(cfg.wsdir, 'backlog.yaml');
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
// --- CEL-43 section 4: box material belongs to ONE dashboard ---------------
//
// The owner, 2026-09-19: "why are there multiple cel broker and gateway
// services?" There is exactly one of each - one broker, one gateway,
// registered once in services.d and printed once by `cel services`. What
// multiplied was the DISPLAY: four per-workspace dashboards run on this box,
// each rendered the box-level rows inside its own services panel, and each
// rendered the whole subscriptions panel, which is box-level in its entirety.
// Flipping between tabs reads as several brokers.
//
// So box material renders on exactly ONE dashboard - the workspace whose
// `dash:` block says `box: true`, defaulting to the registry's first - and
// every other dashboard shows a line pointing at it. This is NOT a box-wide
// dashboard, which the plane deliberately does not have (`cel fleet` and the
// console are the box-wide views); it only stops four surfaces from repeating
// one panel.
const REGISTRY = () => process.env.CEL_REGISTRY || join(homedir(), '.local/share/cel/registry.yaml');
const boxDash = () => cached('boxdash', 60000, async () => {
  let list = [];
  try {
    list = JSON.parse(await run('yq', ['-c',
      '[.workspaces // {} | to_entries[] | {name: .key, path: (.value.path // .value)}]',
      REGISTRY()], 8000) || '[]');
  } catch { list = []; }
  if (!Array.isArray(list) || !list.length) return { owner: cfg.name, mine: true, url: '' };
  let owner = null;
  const ports = {};
  for (const w of list) {
    const row = String(await run('yq', ['-r', '[(.dash.box // false), (.dash.port // 7770)] | @tsv',
      join(String(w.path || ''), 'workspace.yaml')], 8000) || '').trim();
    const [flag, port] = row.split('\t');
    ports[w.name] = Number(port) || 7770;
    if (!owner && String(flag) === 'true') owner = w.name;
  }
  // No declaration anywhere: the registry's first workspace, so the panel has
  // a home on a box nobody has configured rather than appearing everywhere
  // again by default.
  if (!owner) owner = list[0].name;
  return { owner, mine: owner === cfg.name, url: `http://${cfg.host || '127.0.0.1'}:${ports[owner] || 7770}` };
});

const subscriptions = () => cached('subs', 60000, async () => {
  try {
    const doc = JSON.parse(await run(join(CEL_ROOT, 'bin/cel'), ['fleet', '--json'], 20000) || '{}');
    return Array.isArray(doc.subscriptions) ? doc.subscriptions : [];
  } catch { return []; }
});

const state = async () => {
  const [wts, prList, ags, bl, me, mail, lin, pnames, subs, svcs, box] = await Promise.all([worktreeRows(), prs(), wsAgents(), backlog(), viewer(), inbox(), linear(), paneNames(), subscriptions(), services(), boxDash()]);
  // A PARTITION, NOT A NEW QUERY: `cel services --json` has tagged every row
  // with the workspace that owns it since CEL-34, and `box` is the tag for
  // what belongs to nobody. A workspace's panel lists its own rows only.
  const wsServices = svcs.filter((x) => (x.workspace || cfg.name) !== 'box');
  const boxServices = box.mine ? svcs.filter((x) => (x.workspace || '') === 'box') : [];
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
    workspace: cfg.name, updated: new Date().toISOString(), viewer: me,
    attention, inflight, stale: stale.map((w) => `${w.repo}/${w.branch}`),
    agents: ags, services: wsServices, boxServices, box, backlog: bl, inbox: mail.items, inboxBy: mail.byWho, inboxOpen: mail.open || [], linear: lin,
    // One list, two doors: a signed-in subscription and a gateway account are
    // the same thing to whoever is reading the card - `source` says which, and
    // `cel fleet` decided both before this line ran.
    // Subscriptions are box-level in their entirety, so they move with the
    // box panel: four copies of one account list is the same complaint.
    subscriptions: box.mine ? subs : [],
  };
};

const htmlText = (value) => String(value ?? '').replace(/[&<>"]/g,
  (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

const PAGE = `<!doctype html><meta charset="utf-8">
<meta name="cel-csrf-token" content="${security.token}">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${htmlText(cfg.name)} · Celestial AI software factory</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23c8952a' d='M12 1l2.4 8.6L23 12l-8.6 2.4L12 23l-2.4-8.6L1 12l8.6-2.4z'/%3E%3C/svg%3E">
<style>
  /* ONE ramp plus one accent, defined twice. Every colour below is a token:
     the previous palette had eleven hand-picked values that drifted apart in
     light mode, so the ramp (bg -> raise -> line -> dim -> ink) carries all
     the structure and the accent carries all the emphasis. Semantic
     ok/warn/bad exist only to mean state, never to decorate. */
  :root{
    color-scheme:light dark;
    --bg:#f7f5f0; --raise:#ffffff; --line:#e2ddd2; --dim:#6b6659; --ink:#1b1a17;
    --accent:#a8761a; --accent-soft:rgba(168,118,26,.10);
    --ok:#2f7d4f; --warn:#a3690b; --bad:#b23b2c;
    --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace;
    --shadow:0 10px 30px rgba(27,26,23,.10);
    --glow:0;
  }
  :root[data-theme=dark]{
    --bg:#0e1014; --raise:#171a21; --line:#252a33; --dim:#8b93a1; --ink:#eceae4;
    --accent:#e3b34c; --accent-soft:rgba(227,179,76,.12);
    --ok:#54c07f; --warn:#d9a03f; --bad:#e2604e;
    --shadow:0 12px 40px rgba(0,0,0,.55);
    --glow:1;
  }
  @media(prefers-color-scheme:dark){
    :root:not([data-theme=light]){
      --bg:#0e1014; --raise:#171a21; --line:#252a33; --dim:#8b93a1; --ink:#eceae4;
      --accent:#e3b34c; --accent-soft:rgba(227,179,76,.12);
      --ok:#54c07f; --warn:#d9a03f; --bad:#e2604e;
      --shadow:0 12px 40px rgba(0,0,0,.55);
      --glow:1;
    }
  }
  *{box-sizing:border-box}
  /* the canvas sits behind everything and paints the ground; body stays
     transparent so a theme switch needs no repaint of the page */
  /* The GROUND is on html, not body: a background on body paints over a
     canvas behind it, which is why the sky was invisible until this was
     found. Canvases sit at z-index 0 and the content above them at 1 -
     negative z-index would put them behind the root background again. */
  html{background:var(--bg)}
  #sky{position:fixed;inset:0;z-index:0;display:block}
  body{margin:0;color:var(--ink);font:14px/1.5 system-ui,'Segoe UI',sans-serif;
    background:transparent;min-height:100vh;padding:24px 22px 44px;
    position:relative;z-index:1}
  main{max-width:1180px;margin:0 auto;position:relative;z-index:1}
  a{color:var(--accent);text-decoration:none}
  a:hover{text-decoration:underline;text-underline-offset:3px}
  :focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:4px}

  header{display:flex;align-items:center;gap:14px;flex-wrap:wrap;margin-bottom:8px}
  .mark{display:flex;align-items:baseline;gap:10px}
  .mark canvas{width:18px;height:18px}
  .mark h1{font:600 20px/1 system-ui,sans-serif;margin:0;letter-spacing:.01em}
  .mark h1 .ws{color:var(--accent)}
  #updated{color:var(--dim);font:12px var(--mono)}
  .grow{flex:1}
  #build{font:11px var(--mono);color:var(--dim);opacity:.6}
  #upd{font:11px var(--mono);color:var(--accent);border:1px solid var(--line);
    border-radius:999px;padding:2px 8px}
  #fxstate{font:11px var(--mono);color:var(--dim);opacity:.75}
  #fxstate.on{color:var(--accent);opacity:1}
  #themebtn{background:var(--raise);color:var(--dim);border:1px solid var(--line);
    border-radius:8px;padding:5px 10px;font:12px var(--mono);cursor:pointer}
  #themebtn:hover{color:var(--accent);border-color:var(--accent)}

  #strip{display:flex;gap:30px;flex-wrap:wrap;padding:14px 2px 18px;
    border-bottom:1px solid var(--line);margin-bottom:20px}
  .stat{display:flex;flex-direction:column;gap:2px}
  .stat b{font:600 24px/1.15 var(--mono);font-variant-numeric:tabular-nums;color:var(--ink)}
  .stat b.hot{color:var(--accent)}
  .stat b.zero{color:var(--dim);opacity:.55}
  .stat span{font:11px/1.4 var(--mono);letter-spacing:.13em;text-transform:uppercase;color:var(--dim)}
  .stat canvas{width:64px;height:14px;opacity:.85}

  #tabs{display:flex;gap:4px;flex-wrap:wrap;margin:0 0 18px;
    border-bottom:1px solid var(--line);padding-bottom:0}
  .tab{display:inline-flex;align-items:center;gap:8px;background:none;border:0;
    border-bottom:2px solid transparent;color:var(--dim);cursor:pointer;
    font:600 12px var(--mono);letter-spacing:.06em;padding:9px 13px;border-radius:8px 8px 0 0}
  .tab:hover{color:var(--ink);background:var(--accent-soft)}
  .tab[aria-selected=true]{color:var(--ink);border-bottom-color:var(--accent)}
  /* the badge is the reason a tab exists: it must read at a glance, and go
     quiet - not disappear - when there is nothing there */
  .badge{min-width:19px;padding:1px 6px;border-radius:9px;font:600 11px var(--mono);
    background:var(--line);color:var(--dim);font-variant-numeric:tabular-nums}
  .tab[aria-selected=true] .badge{background:var(--accent-soft);color:var(--accent)}
  .badge.hot{background:var(--accent);color:var(--bg)}
  .badge.bad{background:var(--bad);color:#fff}
  .badge.zero{opacity:.45}
  .panel{display:none;animation:rise .22s cubic-bezier(.2,.7,.3,1) both}
  .panel.on{display:block}
  @media(prefers-reduced-motion:reduce){.panel{animation:none}}
  h2{font:600 11px var(--mono);letter-spacing:.15em;text-transform:uppercase;
     color:var(--dim);margin:0 0 12px}
  section{margin-bottom:24px}
  /* glass: a translucent raise over the canvas ground, so the sky shows
     through just enough to feel alive without hurting contrast */
  .card{background:color-mix(in srgb,var(--raise) 88%,transparent);
    border:1px solid var(--line);border-radius:12px;padding:15px 17px;
    backdrop-filter:blur(9px)}

  #attention{display:flex;flex-direction:column;gap:8px}
  .attitem{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;
    background:color-mix(in srgb,var(--raise) 88%,transparent);backdrop-filter:blur(9px);
    border:1px solid var(--line);border-left:3px solid var(--warn);
    border-radius:10px;padding:10px 14px;
    animation:rise .32s cubic-bezier(.2,.7,.3,1) both}
  @keyframes rise{from{opacity:0;transform:translateY(5px)}to{opacity:1;transform:none}}
  @media(prefers-reduced-motion:reduce){.attitem{animation:none}}
  .attitem.merge{border-left-color:var(--ok)}
  .attitem.red,.attitem.blocked{border-left-color:var(--bad)}
  .attitem .why{font-weight:600}
  .attitem.merge .why{color:var(--ok)}
  .attitem.red .why,.attitem.blocked .why{color:var(--bad)}
  .attitem.stall .why{color:var(--warn)}
  .attitem .ttl{color:var(--dim);flex:1 1 220px;min-width:0}
  .attitem .go{font:12.5px var(--mono);white-space:nowrap}
  .allclear{color:var(--ok);font:13px var(--mono)}

  table{border-collapse:collapse;width:100%}
  th{font:600 10.5px var(--mono);letter-spacing:.13em;text-transform:uppercase;color:var(--dim);
     text-align:left;padding:0 14px 8px 0;border-bottom:1px solid var(--line)}
  td{padding:9px 14px 9px 0;vertical-align:top;border-bottom:1px solid var(--line)}
  tr:last-child td{border-bottom:none}
  tbody tr:hover td{background:var(--accent-soft)}
  .branch{font:12.5px var(--mono);color:var(--ink)}
  .branch .repo{color:var(--dim)}
  .ttl a{font:12.5px var(--mono)}
  .ttl .t{color:var(--dim)}
  .owner{font:11.5px var(--mono);color:var(--dim);opacity:.75}
  .owner.other{color:var(--accent);opacity:1}

  .chip{display:inline-flex;align-items:center;gap:6px;font:12px var(--mono);
    color:var(--dim);white-space:nowrap}
  .chip::before{content:'';width:7px;height:7px;border-radius:50%;background:currentColor;opacity:.55}
  .chip.ok{color:var(--ok)}.chip.w{color:var(--warn)}.chip.m{color:var(--ok)}
  .chip.b{color:#fff;background:var(--bad);border-radius:7px;padding:1px 9px 1px 7px}
  .chip.b::before{background:#fff;opacity:1}

  .sechead{display:flex;align-items:baseline;gap:18px;flex-wrap:wrap}
  #filters{display:flex;gap:14px;align-items:center;flex-wrap:wrap;margin:0 0 12px;
    font:12px var(--mono);color:var(--dim)}
  #filters label{display:inline-flex;gap:5px;align-items:center;cursor:pointer;white-space:nowrap}
  #filters input{accent-color:var(--accent)}
  #filters select{font:12px var(--mono);padding:2px 6px}
  #f-count,#inbox-count,#lin-me{color:var(--dim);opacity:.8}
  details{color:var(--dim);font:12.5px var(--mono);margin-top:12px;opacity:.85}
  summary{cursor:pointer}summary:hover{color:var(--ink)}
  details ul{margin:8px 0 0;columns:2}

  .cols{display:grid;gap:16px;grid-template-columns:1fr 1fr}
  @media(max-width:820px){.cols{grid-template-columns:1fr}#strip{gap:20px}}
  .agrow td{padding:6px 14px 6px 0}
  #services a{font:13px var(--mono);margin-right:18px}
  textarea,select,button{background:var(--raise);color:var(--ink);border:1px solid var(--line);
    border-radius:8px;font:13px var(--mono);padding:7px 10px}
  textarea{width:100%;min-height:58px;margin:8px 0;resize:vertical}
  select{max-width:100%}
  button{cursor:pointer;color:var(--accent);border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}
  button:hover{background:var(--accent-soft)}
  #promptmsg{font:12px var(--mono);color:var(--dim);margin-left:10px}
  .empty{color:var(--dim);font:13px var(--mono);opacity:.8}

  /* one grid for the whole list, so time, sender, recipient and read state
     line up down the column instead of ragging with the message length */
  .mailgrid{display:grid;grid-template-columns:auto auto auto auto 1fr auto;
    column-gap:12px;align-items:baseline}
  .mail{display:contents}
  .mail>*{padding:7px 0;border-top:1px solid var(--line)}
  .mailgrid>.mail:first-child>*{border-top:none}
  .mail .when{color:var(--dim);opacity:.75;font:11.5px var(--mono);white-space:nowrap;
    font-variant-numeric:tabular-nums}
  .mail .route{font:11.5px var(--mono);color:var(--dim);white-space:nowrap;
    max-width:16ch;overflow:hidden;text-overflow:ellipsis}
  .mail .arrow{color:var(--dim);opacity:.5;font:11.5px var(--mono)}
  .mail .body{min-width:0;word-break:break-word}
  .mail.unread .body{color:var(--ink)}
  .mail.read .body{color:var(--dim)}
  .mail .rd{font:11px var(--mono);color:var(--accent);white-space:nowrap;
    display:inline-flex;align-items:center;gap:5px}
  .mail .rd .dot{width:6px;height:6px;border-radius:50%;background:var(--accent)}
  .mail .esc{color:var(--bad)}
  #inboxwho{display:flex;gap:20px;flex-wrap:wrap;padding:0 0 12px;margin-bottom:4px;
    border-bottom:1px solid var(--line);font:12px var(--mono)}
  #inboxwho .who{display:flex;gap:7px;align-items:baseline}
  #inboxwho .n{font-weight:600;color:var(--ok)}
  #inboxwho .n.behind{color:var(--accent)}
  #inboxwho .n.stuck{color:var(--bad)}
  #inboxwho .lbl{color:var(--dim)}
  #inboxwho .age{color:var(--dim);opacity:.7}
  .mail:hover>*{background:var(--accent-soft)}
  @media(max-width:760px){
    .mailgrid{grid-template-columns:auto 1fr}
    .mail .arrow,.mail .rd{display:none}
    .mail .body{grid-column:1/-1;padding-top:0;border-top:none}
  }

  /* open decisions: the one thing on the inbox tab that is never "just
     traffic". Left-bordered like an attention item, because it is one. */
  #decisions{display:flex;flex-direction:column;gap:6px;margin-bottom:14px}
  #decisions h2{margin:0 0 4px}
  #decisions h2 .n{color:var(--bad);margin-left:6px}
  .decision{display:flex;align-items:baseline;gap:12px;flex-wrap:wrap;
    background:color-mix(in srgb,var(--raise) 90%,transparent);backdrop-filter:blur(9px);
    border:1px solid var(--line);border-left:3px solid var(--bad);border-radius:10px;padding:9px 13px}
  .decision .kind{font:600 10.5px var(--mono);letter-spacing:.12em;text-transform:uppercase;color:var(--bad)}
  .decision .kind.blocked{color:var(--warn)}
  .decision .route,.decision .age{font:11.5px var(--mono);color:var(--dim);white-space:nowrap}
  .decision .body{flex:1 1 260px;min-width:0;word-break:break-word}
  .decision button.resolve{font:12px var(--mono);padding:3px 10px}
  .lin td{padding:7px 14px 7px 0}
  .lin .id{font:12.5px var(--mono)}
  /* priority reads as a rank: four bars you can compare down the column,
     the label beside them, and an em dash where there is none */
  .pri{display:inline-flex;align-items:center;gap:7px;font:11.5px var(--mono);
    color:var(--dim);white-space:nowrap}
  .pri .bars{display:inline-flex;gap:2px;align-items:flex-end;height:11px}
  .pri .bars i{width:3px;height:4px;background:var(--line);border-radius:1px}
  .pri .bars i:nth-child(2){height:6px}
  .pri .bars i:nth-child(3){height:8.5px}
  .pri .bars i:nth-child(4){height:11px}
  .pri .bars i.on{background:currentColor}
  .pri.p4{color:var(--bad);font-weight:600}
  .pri.p3{color:var(--warn)}
  .pri.p2{color:var(--ink);opacity:.85}
  .pri.p1{color:var(--dim)}
  .pri.none{opacity:.45}

  /* kanban: the columns ARE the team's Linear statuses, in Linear's order.
     Columns SHARE the available width rather than each claiming a fixed 236px:
     five fixed columns overflowed the panel and cut Done off the right-hand
     edge, and a board whose last column is invisible is worse than a narrow
     one - Done is where you look to see the work land. They shrink to --kmin
     and only then does the board scroll, so the squeeze has a floor and the
     text stays readable.

     A collapsed column is the other half: statuses are not equally
     interesting, and on a 7-status team the two or three you never look at
     were spending the width the live ones needed. Collapsing turns one into a
     vertical spine, and flex hands its width to the rest automatically. */
  #kanban{display:flex;gap:12px;overflow-x:auto;padding-bottom:6px;align-items:flex-start;
    --kmin:186px}
  .kcol{flex:1 1 0;min-width:var(--kmin);display:flex;flex-direction:column;gap:8px}
  .kcol h3{margin:0;font:600 11px var(--mono);letter-spacing:.1em;text-transform:uppercase;
    color:var(--dim);display:flex;align-items:center;gap:7px;padding:0 2px 6px;
    border-bottom:2px solid var(--kc,var(--line));cursor:pointer;user-select:none}
  .kcol h3:hover{color:var(--fg)}
  .kcol h3 .nm{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
  .kcol h3 .n{margin-left:auto;font-weight:400;opacity:.7;font-variant-numeric:tabular-nums}
  .kcol.empty h3{opacity:.5}

  /* Collapsed: a spine just wide enough for the count and the rotated name.
     min-width has to be overridden, not just flex-basis, or the column keeps
     the full --kmin it was told to never go below. */
  .kcol.col{flex:0 0 38px;min-width:38px}
  .kcol.col h3{flex-direction:column;gap:6px;padding:0 0 6px;border-bottom-width:3px}
  .kcol.col h3 .nm{writing-mode:vertical-rl;transform:rotate(180deg);max-height:180px}
  .kcol.col h3 .n{margin-left:0}
  .kcol.col .kcard,.kcol.col .none{display:none}
  .kcard{background:color-mix(in srgb,var(--raise) 92%,transparent);backdrop-filter:blur(9px);
    border:1px solid var(--line);border-left:3px solid var(--kc,var(--line));
    border-radius:9px;padding:9px 11px;display:flex;flex-direction:column;gap:6px;
    cursor:context-menu}
  .kcard:hover{border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}
  .kcard .top{display:flex;align-items:center;gap:8px}
  .kcard .top a{font:12.5px var(--mono)}
  .kcard .ttl{font-size:12.5px;line-height:1.4;word-break:break-word}
  .kcard .team{font:10.5px var(--mono);color:var(--dim);opacity:.7;margin-left:auto}
  .kcol .none{color:var(--dim);font:11.5px var(--mono);opacity:.5;padding:4px 2px}

  #ctx{position:fixed;z-index:50;display:none;min-width:210px;
    background:color-mix(in srgb,var(--raise) 96%,transparent);backdrop-filter:blur(12px);
    border:1px solid var(--line);border-radius:10px;padding:5px;box-shadow:var(--shadow)}
  #ctx .hdr{font:11px var(--mono);color:var(--dim);padding:5px 9px 7px;
    border-bottom:1px solid var(--line);margin-bottom:4px;white-space:nowrap;
    overflow:hidden;text-overflow:ellipsis;max-width:280px}
  #ctx button{display:block;width:100%;text-align:left;background:none;border:0;
    color:var(--ink);font:12.5px var(--mono);padding:6px 9px;border-radius:6px;cursor:pointer}
  #ctx button:hover{background:var(--accent-soft);color:var(--accent)}
  #ctx .sep{height:1px;background:var(--line);margin:4px 0}
  #ctx .grp{font:10.5px var(--mono);color:var(--dim);padding:5px 9px 2px;letter-spacing:.1em}
  tr[data-ctx],div[data-ctx]{cursor:context-menu}
</style>
<link rel="stylesheet" href="/factory.css">
<canvas id="sky"></canvas>
<main>
<header>
  <div class="mark"><canvas id="starmark" width="36" height="36" aria-hidden="true"></canvas><div><h1>celestial <span class="ws" id="wsname"></span></h1><p class="factory-brand">AI software factory</p></div></div>
  <div id="updated"></div>
  <span class="grow"></span>
  <span id="fxstate" title=""></span>
  <span id="build" title="the plane build this dashboard is running">${htmlText(cfg.build)}</span><!--UPDATE-CHIP-->
  <button id="themebtn" title="light / dark / follow system">◐ theme</button>
</header>
<div id="strip"></div>
<nav id="tabs" role="tablist"></nav>
<div class="panel on" id="tab-factory" role="tabpanel"><section class="factory-shell" id="factory-floor"><p class="factory-unavailable">Reading factory signals…</p></section></div>

<div class="panel" id="tab-attention" role="tabpanel">
  <div id="attention"></div>
</div>

<div class="panel" id="tab-inflight" role="tabpanel">
  <div class="sechead"><h2>In flight</h2>
    <div id="filters">
      <label><input type="checkbox" id="f-drafts"> hide drafts</label>
      <label><input type="checkbox" id="f-nopr"> hide no-PR</label>
      <label><input type="checkbox" id="f-quiet"> only needs action</label>
      <label><input type="checkbox" id="f-mine"> only my PRs</label>
      <select id="f-repo"><option value="">all repos</option></select>
      <span id="f-count"></span>
    </div></div>
  <div class="card"><div id="inflight"></div>
    <details id="staledetails"><summary id="stalesummary"></summary><ul id="stalelist"></ul></details></div>
</div>

<div class="panel" id="tab-linear" role="tabpanel">
  <div class="sechead"><h2>My Linear</h2><div id="filters"><span id="lin-me"></span></div></div>
  <div class="card"><div id="linear"></div></div>
</div>

<div class="panel" id="tab-inbox" role="tabpanel">
  <div class="sechead"><h2>Inbox</h2>
    <div id="filters"><label><input type="checkbox" id="f-unread"> unread only</label>
    <span id="inbox-count"></span></div></div>
  <div id="decisions"></div>
  <div class="card"><div id="inboxwho"></div><div id="inbox"></div></div>
</div>

<div class="panel" id="tab-agents" role="tabpanel">
  <div class="cols">
    <section><h2>Agents</h2><div class="card"><div id="agents"></div>
      <h2 style="margin:18px 0 8px">Drive an agent</h2>
      <select id="target"></select>
      <textarea id="msg" placeholder="prompt…"></textarea>
      <button onclick="send()">Send</button><span id="promptmsg"></span></div></section>
    <section><h2>Services &amp; backlog</h2><div class="card"><div id="services"></div>
      <div id="backlog" style="margin-top:14px"></div></div></section>
    <section><h2>Box</h2><div class="card"><div id="box"></div>
      <div id="subs" style="margin-top:14px"></div></div></section>
  </div>
</div>
<div id="ctx"></div>
</main>
<script src="/factory.js"></script>
<script>
const $=id=>document.getElementById(id);
const csrf=document.querySelector('meta[name="cel-csrf-token"]').content;

// ---- theme: light / dark / follow the system --------------------------
// Three states, not two: "follow" is the honest default, and the stamped
// attribute is what the CSS media query defers to.
var THEMES=['system','light','dark'];
var theme=localStorage.getItem('cel-theme')||'system';
function applyTheme(){
  if(theme==='system')document.documentElement.removeAttribute('data-theme');
  else document.documentElement.setAttribute('data-theme',theme);
  var t=$('themebtn');
  if(t)t.textContent=(theme==='dark'?'◐ dark':theme==='light'?'◑ light':'◓ system');
  paintMark();
}
function cyc(){theme=THEMES[(THEMES.indexOf(theme)+1)%3];localStorage.setItem('cel-theme',theme);applyTheme()}
function tok(n){return getComputedStyle(document.documentElement).getPropertyValue(n).trim()}

// ---- the sky: a slow particle field behind the page ------------------
// Hand-rolled rather than a component library: the dashboard is a single
// dependency-free surface, and the effect is 40 lines of canvas 2D. It idles
// when the tab is hidden, stops entirely under prefers-reduced-motion, and
// its warmth tracks how much needs the human - the page glows when the
// attention queue does.
var sky=$('sky'), sctx=sky&&sky.getContext('2d'), stars=[], heat=0, raf=null;
var reduce=matchMedia('(prefers-reduced-motion:reduce)').matches;
function sizeSky(){
  if(!sky)return;
  var d=Math.min(devicePixelRatio||1,2);
  sky.width=innerWidth*d;sky.height=innerHeight*d;
  sctx.setTransform(d,0,0,d,0,0);
  stars=[];
  var n=Math.min(90,Math.round(innerWidth*innerHeight/26000));
  for(var i=0;i<n;i++)stars.push({
    x:Math.random()*innerWidth,y:Math.random()*innerHeight,
    r:Math.random()*1.5+.35,vy:(Math.random()*.10+.02),
    a:Math.random()*.5+.15,p:Math.random()*Math.PI*2});
}
function drawSky(t){
  if(!sctx)return;
  var dark=tok('--glow')==='1';
  sctx.clearRect(0,0,innerWidth,innerHeight);
  // a single soft wash, warm when work is waiting
  var g=sctx.createRadialGradient(innerWidth*.82,-90,20,innerWidth*.82,-90,Math.max(innerWidth,innerHeight)*.9);
  var acc=tok('--accent');
  g.addColorStop(0,dark?'rgba(60,74,120,.55)':'rgba(255,255,255,.9)');
  g.addColorStop(.45,dark?'rgba(24,29,49,.35)':'rgba(240,236,226,.55)');
  g.addColorStop(1,'rgba(0,0,0,0)');
  sctx.fillStyle=g;sctx.fillRect(0,0,innerWidth,innerHeight);
  if(heat>0){
    // the accent token may be hex or rgb(); resolve it to numbers once so the
    // wash can carry its own alpha
    if(!drawSky.rgb){
      var probe=document.createElement('canvas').getContext('2d');
      probe.fillStyle=acc;var hx=probe.fillStyle;
      drawSky.rgb=/^#/.test(hx)
        ? [parseInt(hx.slice(1,3),16),parseInt(hx.slice(3,5),16),parseInt(hx.slice(5,7),16)]
        : (hx.match(/\d+/g)||[227,179,76]).slice(0,3).map(Number);
      drawSky.for=acc;
    } else if(drawSky.for!==acc){ drawSky.rgb=null; }
    if(drawSky.rgb){
      var c=drawSky.rgb, a=0.05+Math.min(heat,6)*0.012;
      var hg=sctx.createRadialGradient(innerWidth/2,0,10,innerWidth/2,0,innerWidth*.7);
      hg.addColorStop(0,'rgba('+c[0]+','+c[1]+','+c[2]+','+a+')');
      hg.addColorStop(1,'rgba('+c[0]+','+c[1]+','+c[2]+',0)');
      sctx.fillStyle=hg;sctx.fillRect(0,0,innerWidth,innerHeight);
    }
  }
  for(var i=0;i<stars.length;i++){
    var st=stars[i];
    st.y-=st.vy; if(st.y<-4){st.y=innerHeight+4;st.x=Math.random()*innerWidth}
    var tw=dark?(0.55+0.45*Math.sin(t/900+st.p)):(0.25+0.2*Math.sin(t/900+st.p));
    sctx.globalAlpha=st.a*tw;
    sctx.fillStyle=dark?'#cdd6f5':'#9a917f';
    sctx.beginPath();sctx.arc(st.x,st.y,st.r,0,6.283);sctx.fill();
  }
  sctx.globalAlpha=1;
}
function tick(t){drawSky(t);raf=requestAnimationFrame(tick)}
function startSky(){
  if(!sky)return;
  sizeSky();
  if(reduce){drawSky(0);return}
  if(!raf)raf=requestAnimationFrame(tick);
}
addEventListener('resize',function(){sizeSky();if(reduce)drawSky(0)});
document.addEventListener('visibilitychange',function(){
  if(document.hidden){if(raf){cancelAnimationFrame(raf);raf=null}}
  else if(!reduce&&!raf)raf=requestAnimationFrame(tick);
});

// the wordmark is a drawn star, so it takes the accent from whichever theme
function paintMark(){
  var c=$('starmark');if(!c)return;
  var x=c.getContext('2d');x.setTransform(2,0,0,2,0,0);x.clearRect(0,0,18,18);
  x.fillStyle=tok('--accent');x.beginPath();
  for(var i=0;i<8;i++){
    var a=i*Math.PI/4, r=i%2?2.6:8.2;
    x[i?'lineTo':'moveTo'](9+Math.cos(a)*r,9+Math.sin(a)*r);
  }
  x.closePath();x.fill();
}

// a 14px sparkline per figure: the same number over the last N refreshes,
// so a rising queue reads as rising, not just as a bigger integer
var HIST={};
function spark(key,val){
  HIST[key]=(HIST[key]||[]).concat(val).slice(-24);
  var h=HIST[key];
  if(h.length<3)return '';
  var id='sp-'+key;
  setTimeout(function(){
    var c=document.getElementById(id);if(!c)return;
    var x=c.getContext('2d');x.setTransform(2,0,0,2,0,0);x.clearRect(0,0,32,7);
    var max=Math.max.apply(null,h.concat([1]));
    x.strokeStyle=tok('--accent');x.globalAlpha=.8;x.lineWidth=1;x.beginPath();
    h.forEach(function(v,i){
      var px=i*(32/(h.length-1)), py=7-(v/max)*6.4;
      x[i?'lineTo':'moveTo'](px,py);
    });
    x.stroke();
  },0);
  return '<canvas id="'+id+'" width="64" height="14"></canvas>';
}

const esc=s=>String(s??'').replace(/[&<>"]/g,c=>({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const chip=(t,c)=>'<span class="chip '+(c||'')+'">'+esc(t)+'</span>';
const statusChip=s=>!s?chip('no agent',''):chip(s,s==='working'?'w':(s==='idle'||s==='done')?'ok':s==='blocked'?'b':'');
const reviewChip=p=>{
  if(!p)return chip('no PR','');
  if(p.draft)return chip('draft','');
  const r=p.review;
  return r==='APPROVED'?chip('approved','m'):r==='CHANGES_REQUESTED'?chip('changes requested','w')
    :chip('awaiting review','');
};
const checksChip=p=>!p||p.checks==='none'?'':chip('CI '+p.checks,p.checks==='green'?'ok':p.checks==='failing'?'b':'w');
const stat=(n,label,hot)=>'<div class="stat"><b class="'+(n===0?'zero':hot?'hot':'')+'">'+n+
  '</b><span>'+esc(label)+'</span>'+spark(label.replace(/[^a-z]/gi,''),n)+'</div>';
// Filters are the viewer's own lens, so they live in this browser's
// localStorage, not on the server.
const FKEY='cel-dash-filters';
let F={drafts:false,nopr:false,quiet:false,mine:false,repo:'',unread:false};
try{F=Object.assign(F,JSON.parse(localStorage.getItem(FKEY)||'{}'))}catch(e){}
let LAST=null;
function saveF(){localStorage.setItem(FKEY,JSON.stringify(F))}
// Which kanban columns the viewer has collapsed, by status NAME - a team that
// adds or reorders a status must not silently collapse a different column.
const KCKEY='cel-dash-kanban-collapsed';
let KC={};
try{KC=JSON.parse(localStorage.getItem(KCKEY)||'{}')||{}}catch(e){KC={}}
function needsAction(w){
  return w.status==='blocked'||(w.pr&&!w.pr.draft&&(w.pr.checks==='failing'
    ||w.pr.review==='CHANGES_REQUESTED'||w.pr.review==='APPROVED'));}
// The verdict is what collect recorded: the gate actually run, the commit
// order, CI and review. Two chips - gate and red-then-green - because those
// are the two facts a reviewer cannot see from the PR page. A scout has no
// verdict by design; a ship branch not yet collected shows a dash.
function verdictChips(w){
  if(w.shape==='scout')return '<span class="chip" title="scout: a report, not a change">scout</span>';
  var v=w.verdict;
  if(!v)return '<span class="empty" title="not collected yet">—</span>';
  var g=v.gate_configured===false?chip('no gate',''):(v.gate===true?chip('gate ✓','ok'):(v.gate===false?chip('gate ✗','b'):chip('gate ?','w')));
  var r=v.red_then_green===true?chip('red→green','ok'):(v.red_then_green===false?chip('tests after','w'):chip('no tests','') );
  return g+' '+r;
}
function renderInflight(){
  if(!LAST)return;
  const all=LAST.inflight;
  const rows=all.filter(w=>
    !(F.drafts&&w.pr&&w.pr.draft)&&!(F.nopr&&!w.pr)
    &&!(F.quiet&&!needsAction(w))&&!(F.repo&&w.repo!==F.repo)
    &&!(F.mine&&w.pr&&LAST.viewer&&w.pr.author!==LAST.viewer));
  $('f-count').textContent=rows.length===all.length?'':rows.length+' of '+all.length+' shown';
  $('inflight').innerHTML=rows.length?'<table><thead><tr><th>work</th><th>agent</th><th>verdict</th><th>review</th><th>ci</th></tr></thead><tbody>'+
    rows.map((w,ix)=>'<tr data-ctx="inflight" data-ix="'+ix+'"><td><div class="branch"><span class="repo">'+esc(w.repo)+'/</span>'+esc(w.branch)+'</div>'+
      '<div class="ttl">'+(w.ticket?(w.ticket.url?'<a href="'+esc(w.ticket.url)+'" target="_blank">'+esc(w.ticket.id)+'</a> ':'<span class="t">'+esc(w.ticket.id)+'</span> '):'')+
      (w.pr?'<a href="'+esc(w.pr.url)+'" target="_blank">#'+w.pr.number+'</a> <span class="t">'+
      esc(w.pr.title)+'</span>'+(w.pr.author?' <span class="owner'+(LAST.viewer&&w.pr.author!==LAST.viewer?' other':'')+
      '">@'+esc(w.pr.author)+'</span>':''):'<span class="t">no PR yet</span>')+'</div></td>'+
      '<td>'+statusChip(w.status)+(w.agent?'<div class="empty">'+esc(w.agent)+(w.model?' · '+esc(w.model.split('/').pop()):'')+'</div>':'')+'</td>'+
      '<td>'+verdictChips(w)+'</td>'+
      '<td>'+reviewChip(w.pr)+'</td><td>'+checksChip(w.pr)+'</td></tr>').join('')+'</tbody></table>'
    :'<span class="empty">'+(all.length?'all '+all.length+' filtered out':'nothing in flight')+'</span>';
  Array.prototype.forEach.call($('inflight').querySelectorAll('tr[data-ctx]'),function(tr){
    tr.oncontextmenu=function(e){inflightMenu(e,rows[+tr.dataset.ix])};
  });
}
// ---- tabs ---------------------------------------------------------------
// Stacked sections meant the thing you needed was usually below the fold.
// Tabs put one surface in front of you and let the BADGES carry the rest:
// a count you can read without switching, hot when it wants you.
var TABS=[
  {id:'factory',label:'factory floor',badge:function(s){return s.inflight.length}},
  {id:'attention',label:'needs you',badge:function(s){return s.attention.length},tone:'hot'},
  {id:'inflight', label:'in flight', badge:function(s){return s.inflight.length}},
  {id:'linear',   label:'my linear', badge:function(s){return s.linear&&s.linear.issues?s.linear.issues.length:null}},
  // the badge is UNRESOLVED decisions first: unread mail is a queue length,
  // an open decision is someone waiting on an answer
  {id:'inbox',    label:'inbox',     badge:function(s){return (s.inboxOpen||[]).length+(s.inbox||[]).filter(function(m){return m.unread}).length},tone:'hot'},
  {id:'agents',   label:'agents',    badge:function(s){
      var b=s.agents.filter(function(a){return a.status==='blocked'}).length;
      return b?b:s.agents.length},
    tone:function(s){return s.agents.some(function(a){return a.status==='blocked'})?'bad':''}}
];
var tab=localStorage.getItem('cel-tab')||'factory';
function showTab(id){
  tab=id;localStorage.setItem('cel-tab',id);
  TABS.forEach(function(t){
    var p=$('tab-'+t.id);if(p)p.className='panel'+(t.id===id?' on':'');
    var b=document.getElementById('tabbtn-'+t.id);
    if(b)b.setAttribute('aria-selected',String(t.id===id));
  });
}
function renderTabs(s){
  var host=$('tabs');
  var html=TABS.map(function(t){
    var n=t.badge(s);
    if(n===null)return '';   // no linear here, no tab
    var tone=typeof t.tone==='function'?t.tone(s):(t.tone||'');
    var cls='badge'+(n===0?' zero':(tone?' '+tone:''));
    return '<button class="tab" id="tabbtn-'+t.id+'" role="tab" aria-selected="false" data-tab="'+t.id+'">'+
      esc(t.label)+'<span class="'+cls+'">'+n+'</span></button>';
  }).join('');
  if(host.dataset.sig!==html){host.innerHTML=html;host.dataset.sig=html;
    Array.prototype.forEach.call(host.querySelectorAll('.tab'),function(b){
      b.onclick=function(){showTab(b.dataset.tab)};
    });
  }
  // a tab that vanished (linear removed) must not leave a blank page
  if(!document.getElementById('tabbtn-'+tab))tab='factory';
  showTab(tab);
}

// ---- right-click menus -------------------------------------------------
// Every row is a thing you might want to DO something with; a context menu
// keeps those verbs next to the noun instead of in a toolbar far away.
var CTXCLOSE=function(){$('ctx').style.display='none'};
document.addEventListener('click',CTXCLOSE);
document.addEventListener('keydown',function(e){if(e.key==='Escape')CTXCLOSE()});
window.addEventListener('blur',CTXCLOSE);
function copyText(t){
  if(navigator.clipboard&&window.isSecureContext)
    return navigator.clipboard.writeText(t).then(function(){return true},function(){return false});
  var ta=document.createElement('textarea');ta.value=t;ta.style.position='fixed';ta.style.opacity='0';
  document.body.appendChild(ta);ta.select();var ok=false;
  try{ok=document.execCommand('copy')}catch(e){}
  document.body.removeChild(ta);return Promise.resolve(ok);
}
async function post(path,body){
  var r=await fetch(location.origin+path,{method:'POST',
    headers:{'content-type':'application/json','x-cel-csrf':csrf},body:JSON.stringify(body)});
  return {ok:r.ok,text:await r.text()};
}
function toast(t,ok){
  var el=$('updated');var prev=el.textContent;
  el.textContent=t;el.style.color=ok===false?'var(--bad)':'var(--mint)';
  setTimeout(function(){el.textContent=prev;el.style.color=''},2600);
}
function openMenu(e,title,items){
  e.preventDefault();e.stopPropagation();
  var m=$('ctx');
  // the menu host lives outside the tab panels on purpose: a panel swap must
  // never take the menus with it, as it did once
  if(!m){m=document.createElement('div');m.id='ctx';document.body.appendChild(m)}
  m.innerHTML='<div class="hdr">'+esc(title)+'</div>'+items.map(function(it,i){
    if(it.sep)return '<div class="sep"></div>';
    if(it.group)return '<div class="grp">'+esc(it.group)+'</div>';
    return '<button data-i="'+i+'">'+esc(it.label)+'</button>';
  }).join('');
  Array.prototype.forEach.call(m.querySelectorAll('button'),function(b){
    b.onclick=function(ev){ev.stopPropagation();CTXCLOSE();items[+b.dataset.i].run()};
  });
  m.style.display='block';
  // keep it on screen
  var r=m.getBoundingClientRect();
  m.style.left=Math.min(e.clientX,window.innerWidth-r.width-8)+'px';
  m.style.top=Math.min(e.clientY,window.innerHeight-r.height-8)+'px';
}
// The states THIS team actually has, from Linear. The old hardcoded list
// offered "Ready", which this team does not define - so the menu advertised a
// move that could only ever fail, and named the wrong state as the one that
// starts a build.
function linearStates(){
  return (LAST&&LAST.linear&&LAST.linear.states)?LAST.linear.states.map(function(s){return s.name}):[];
}
function ticketItems(id,url){
  var items=[];
  if(url)items.push({label:'open '+id+' in Linear ↗',run:function(){window.open(url,'_blank')}});
  items.push({label:'copy '+id,run:function(){copyText(id).then(function(ok){toast(ok?'copied '+id:'copy blocked',ok)})}});
  var trig=(LAST&&LAST.linear&&LAST.linear.trigger)||'';
  var sts=linearStates();
  if(!sts.length)return items;
  items.push({group:'move to'+(trig?' — '+trig+' starts a build':'')});
  sts.forEach(function(st){
    items.push({label:st,run:async function(){
      var r=await post('/api/ticket-state',{id:id,state:st});
      toast(r.ok?(id+' → '+st):('could not move '+id+': '+r.text),r.ok);
      if(r.ok)refresh();
    }});
  });
  return items;
}
function inflightMenu(e,w){
  var items=[];
  if(w.pr)items.push({label:'open PR #'+w.pr.number+' ↗',run:function(){window.open(w.pr.url,'_blank')}});
  if(w.ticket)items=items.concat(ticketItems(w.ticket.id,w.ticket.url));
  items.push({sep:true});
  items.push({label:'copy branch',run:function(){copyText(w.branch).then(function(ok){toast(ok?'copied branch':'copy blocked',ok)})}});
  if(w.path)items.push({label:'copy worktree path',run:function(){copyText(w.path).then(function(ok){toast(ok?'copied path':'copy blocked',ok)})}});
  if(w.pane){
    items.push({sep:true});
    items.push({label:'focus its pane',run:async function(){var r=await post('/api/focus',{pane:w.pane});toast(r.ok?'focused '+w.pane:r.text,r.ok)}});
    items.push({label:'prompt this agent…',run:function(){$('target').value=w.pane;$('msg').focus();toast('addressed to '+w.pane)}});
  }
  openMenu(e,w.repo+'/'+w.branch,items);
}
// Priority as its own leading column, not a suffix on the title. Four bars
// filled to the level, so a column of them is scannable without reading a
// word; the label rides alongside because bars alone are ambiguous about
// direction. Linear's scale runs 1=Urgent..4=Low, which is BACKWARDS for
// "how many bars", hence the flip.
function priCell(i){
  if(!i.pri||i.pri>4)return '<span class="pri none">—</span>';
  var filled=5-i.pri, b='', k;
  for(k=1;k<=4;k++)b+='<i'+(k<=filled?' class="on"':'')+'></i>';
  return '<span class="pri p'+filled+'" title="'+esc(i.priority||'')+'">'+
    '<span class="bars">'+b+'</span>'+esc(i.priority||'')+'</span>';
}
function renderLinear(){
  if(!LAST)return;
  var L=LAST.linear;
  if(!L||!L.issues)return;
  $('lin-me').textContent=L.issues.length+' open, assigned to '+L.me+
    ' \u00b7 team'+(L.teams.length>1?'s':'')+' '+L.teams.join(', ');
  // COLUMNS COME FROM LINEAR, never from a list we keep here: the board shows
  // this team's real workflow states, in Linear's own order (type first, then
  // position - "In Review" sits at position 1002, so position alone would file
  // it after Canceled). A terminal state with nothing in it is dropped, since
  // an always-empty Canceled column is just lost width; the working states
  // stay visible even when empty, because an empty Todo is information.
  var states=L.states||[];
  if(!states.length){
    $('linear').innerHTML='<span class="empty">no workflow states returned for '+esc(L.teams.join(', '))+'</span>';
    return;
  }
  var byState={},i,s;
  for(i=0;i<L.issues.length;i++){
    (byState[L.issues[i].state]=byState[L.issues[i].state]||[]).push(L.issues[i]);
  }
  var html='<div id="kanban">',shown=0;
  for(i=0;i<states.length;i++){
    s=states[i];
    var items=byState[s.name]||[];
    var terminal=(s.type==='canceled'||s.type==='duplicate');
    if(terminal&&!items.length)continue;
    shown++;
    html+='<div class="kcol'+(items.length?'':' empty')+(KC[s.name]?' col':'')+
      '" data-col="'+esc(s.name)+'" style="--kc:'+esc(s.color||'')+'">'+
      '<h3 title="click to collapse or expand"><span class="nm">'+esc(s.name)+
      '</span><span class="n">'+items.length+'</span></h3>';
    if(!items.length)html+='<div class="none">—</div>';
    for(var k=0;k<items.length;k++){
      var t=items[k];
      html+='<div class="kcard" data-ctx="lin" data-id="'+esc(t.id)+'" data-url="'+esc(t.url)+'">'+
        '<div class="top"><a href="'+esc(t.url)+'" target="_blank">'+esc(t.id)+'</a>'+
        (L.teams.length>1?'<span class="team">'+esc(t.team)+'</span>':'')+'</div>'+
        '<div class="ttl">'+esc(t.title)+'</div>'+priCell(t)+'</div>';
    }
    html+='</div>';
  }
  html+='</div>';
  $('linear').innerHTML=shown?html
    :'<span class="empty">nothing assigned to you in '+esc(L.teams.join(', '))+'</span>';
  // Collapse toggles live on the header. Kept in localStorage beside the
  // filters and the theme, keyed by STATUS NAME rather than position, so a
  // team that adds or reorders a status does not silently collapse a
  // different column than the one you chose.
  Array.prototype.forEach.call($('linear').querySelectorAll('.kcol h3'),function(h){
    h.addEventListener('click',function(){
      var col=h.parentNode,nm=col.getAttribute('data-col');
      if(KC[nm]){delete KC[nm];col.classList.remove('col')}
      else{KC[nm]=1;col.classList.add('col')}
      try{localStorage.setItem(KCKEY,JSON.stringify(KC))}catch(e){}
    });
  });
  // right-click still works, on the card rather than the row
  Array.prototype.forEach.call($('linear').querySelectorAll('[data-ctx="lin"]'),function(el){
    el.oncontextmenu=function(e){openMenu(e,el.dataset.id,ticketItems(el.dataset.id,el.dataset.url))};
  });
}
function renderInbox(){
  if(!LAST)return;
  // OPEN DECISIONS sit above the mail, not in it. Reading moved the cursor
  // past them; that is exactly why they need their own strip - a question
  // that scrolled off the unread list is still a question.
  var od=LAST.inboxOpen||[];
  $('decisions').innerHTML=od.length?'<h2>open decisions <span class="n">'+od.length+'</span></h2>'+od.map(function(d){
    var mins=Math.round((Date.now()-new Date(d.ts))/60000);
    return '<div class="decision" data-id="'+esc(d.id)+'">'+
      '<span class="kind '+esc(d.kind)+'">'+esc(d.kind)+'</span>'+
      '<span class="route">'+esc(d.from)+' → '+esc(d.to)+'</span>'+
      '<span class="age">'+(mins<60?mins+'m':Math.round(mins/60)+'h')+'</span>'+
      '<span class="body">'+esc(d.message)+'</span>'+
      '<button class="resolve" data-id="'+esc(d.id)+'">resolve</button></div>';
  }).join(''):'';
  Array.prototype.forEach.call($('decisions').querySelectorAll('button.resolve'),function(b){
    b.onclick=async function(){
      var r=await post('/api/inbox-resolve',{id:b.dataset.id});
      toast(r.ok?'resolved':('could not resolve: '+r.text),r.ok);
      if(r.ok)refresh();
    };
  });
  var by=LAST.inboxBy||[];
  $('inboxwho').innerHTML=by.length?by.map(function(w){
    var age='';
    if(w.unread&&w.oldest){
      var mins=Math.round((Date.now()-new Date(w.oldest))/60000);
      age='<span class="age">oldest '+(mins<60?mins+'m':Math.round(mins/60)+'h')+'</span>';
    }
    var cls=w.unread===0?'':(w.unread&&w.oldest&&(Date.now()-new Date(w.oldest))>1800e3?'stuck':'behind');
    return '<span class="who"><span class="n '+cls+'">'+w.unread+'</span>'+
      '<span class="lbl">unread \u00b7 '+esc(w.who)+'</span>'+age+'</span>';
  }).join(''):'';
  var all=LAST.inbox||[];
  var rows=F.unread?all.filter(function(m){return m.unread}):all;
  var un=all.filter(function(m){return m.unread}).length;
  $('inbox-count').textContent=all.length?(un+' unread of '+all.length):'';
  $('inbox').innerHTML=rows.length?'<div class="mailgrid">'+rows.map(function(m,ix){
    return '<div class="mail '+(m.unread?'unread':'read')+'" data-ctx="mail" data-ix="'+ix+'">'+
      '<span class="when">'+new Date(m.ts).toLocaleTimeString()+'</span>'+
      '<span class="route'+(m.kind==='escalation'?' esc':'')+'" title="'+esc(m.from)+'">'+esc(m.fromName||m.from)+'</span>'+
      '<span class="arrow">\u2192</span>'+
      '<span class="route" title="'+esc(m.to)+'">'+esc(m.toName||m.to)+'</span>'+
      '<span class="body">'+(m.kind==='escalation'?'<b class="esc">escalation</b> ':'')+esc(m.message)+'</span>'+
      '<span class="rd">'+(m.unread?'<span class="dot"></span>unread':'')+'</span></div>';
  }).join('')+'</div>':'<span class="empty">'+(all.length?'nothing unread':'no messages')+'</span>';
  Array.prototype.forEach.call($('inbox').querySelectorAll('[data-ctx="mail"]'),function(el){
    el.oncontextmenu=function(e){var m=rows[+el.dataset.ix];openMenu(e,m.from+' → '+m.to,[
      {label:'copy message',run:function(){copyText(m.message).then(function(ok){toast(ok?'copied':'copy blocked',ok)})}},
      {label:'reply to '+m.from+'…',run:function(){$('target').value=m.from;$('msg').focus();toast('addressed to '+m.from)}},
      {sep:true},
      {label:'focus sender pane',run:async function(){var r=await post('/api/focus',{pane:m.from});toast(r.ok?'focused '+m.from:r.text,r.ok)}}
    ])};
  });
}
function initFilters(){
  $('f-drafts').checked=F.drafts;$('f-nopr').checked=F.nopr;$('f-quiet').checked=F.quiet;
  $('f-mine').checked=F.mine;
  $('f-mine').onchange=function(){F.mine=this.checked;saveF();renderInflight()};
  $('f-drafts').onchange=function(){F.drafts=this.checked;saveF();renderInflight()};
  $('f-nopr').onchange=function(){F.nopr=this.checked;saveF();renderInflight()};
  $('f-quiet').onchange=function(){F.quiet=this.checked;saveF();renderInflight()};
  $('f-repo').onchange=function(){F.repo=this.value;saveF();renderInflight()};
  $('f-unread').checked=F.unread;
  $('f-unread').onchange=function(){F.unread=this.checked;saveF();renderInbox()};
}
initFilters();
async function refresh(){
  const response=await fetch('/api/state');
  if(!response.ok)throw new Error('dashboard state unavailable');
  const s=await response.json();
  LAST=s;
  const repos=[...new Set(s.inflight.map(w=>w.repo))].sort();
  const sel=$('f-repo');
  sel.innerHTML='<option value="">all repos</option>'+repos.map(r=>'<option value="'+esc(r)+'">'+esc(r)+'</option>').join('');
  sel.value=repos.includes(F.repo)?F.repo:'';
  $('wsname').textContent=s.workspace;
  $('updated').textContent='updated '+new Date(s.updated).toLocaleTimeString();
  const working=s.agents.filter(a=>a.status==='working').length
    +s.inflight.filter(w=>w.status==='working').length;
  const blocked=s.agents.filter(a=>a.status==='blocked').length
    +s.inflight.filter(w=>w.status==='blocked').length;
  heat=s.attention.length;
  $('strip').innerHTML=stat(s.attention.length,'needs you',true)
    +stat(s.inflight.length,'in flight')+stat(working,'working')
    +stat(blocked,'blocked',true)+stat(s.stale.length,'stale trees')
    +stat((s.inbox||[]).filter(function(m){return m.unread}).length,'unread mail',true)
    +((s.linear&&s.linear.issues)?stat(s.linear.issues.length,'my tickets'):'');
  $('attention').innerHTML=s.attention.length?s.attention.map(a=>
    '<div class="attitem '+esc(a.kind)+'"><span class="why">'+esc(a.text)+'</span>'+
    '<span class="ttl">'+esc(a.title||'')+'</span>'+
    (a.url?'<a class="go" href="'+esc(a.url)+'" target="_blank">open ↗</a>':'')+'</div>').join('')
    :'<div class="card"><span class="allclear">✦ nothing waiting on you</span></div>';
  renderInflight();
  CelFactory.render($('factory-floor'),s,{
    list:function(){showTab('inflight')},
    focus:function(pane){return post('/api/focus',{pane:pane})}
  });
  renderInbox();
  renderLinear();
  renderTabs(s);
  $('staledetails').style.display=s.stale.length?'':'none';
  $('stalesummary').textContent=s.stale.length+' stale worktrees (no agent, no open PR) — cel gc prunes merged ones';
  $('stalelist').innerHTML=s.stale.map(x=>'<li>'+esc(x)+'</li>').join('');
  $('agents').innerHTML=s.agents.length?'<table><tbody>'+s.agents.map(a=>'<tr class="agrow" data-ctx="agent" data-pane="'+esc(a.pane)+'" data-label="'+esc(a.label)+'"><td title="'+esc(a.pane)+'">'+esc(a.label)+
    '</td><td class="empty">'+esc(a.agent)+'</td><td>'+statusChip(a.status)+'</td></tr>').join('')+'</tbody></table>'
    :'<span class="empty">none running</span>';
  Array.prototype.forEach.call($('agents').querySelectorAll('tr[data-ctx]'),function(tr){
    tr.oncontextmenu=function(e){openMenu(e,tr.dataset.label,[
      {label:'focus its pane',run:async function(){var r=await post('/api/focus',{pane:tr.dataset.pane});toast(r.ok?'focused '+tr.dataset.pane:r.text,r.ok)}},
      {label:'prompt this agent…',run:function(){$('target').value=tr.dataset.pane;$('msg').focus();toast('addressed to '+tr.dataset.pane)}},
      {sep:true},
      {label:'copy pane id',run:function(){copyText(tr.dataset.pane).then(function(ok){toast(ok?'copied':'copy blocked',ok)})}}
    ])};
  });
  const cur=$('target').value;
  $('target').innerHTML=s.agents.map(a=>'<option value="'+esc(a.pane)+'">'+esc(a.label)+'</option>').join('')
    +s.inflight.filter(w=>w.pane).map(w=>'<option value="'+esc(w.pane)+'">'+esc(w.repo)+'/'+esc(w.branch)+'</option>').join('');
  if(cur)$('target').value=cur;
  $('services').innerHTML=s.services.length?'<table><tbody>'+s.services.map(function(x){
    // a preview belongs to a ticket, and the thing you want next to a running
    // preview is the PR it is a preview OF
    var pr=x.ticket?s.inflight.find(function(w){return w.ticket&&w.ticket.id===x.ticket&&w.pr}):null;
    var link=x.reach?'<a href="'+esc(x.reach)+(x.reach.indexOf('/svc/')>-1?'?cel_token='+encodeURIComponent(csrf):'')+
      '" target="_blank">'+esc(x.reach)+' \u2197</a>':'<span class="empty">not reachable</span>';
    return '<tr class="agrow"><td style="width:1%">'+chip(x.state,x.state==='healthy'?'ok':x.state==='up'?'w':'b')+
      '</td><td class="branch">'+esc(x.name)+(x.observe_only?' <span class="empty">observe-only</span>':'')+
      '</td><td class="owner">:'+esc(x.port)+'</td><td class="owner">'+esc(x.rss_mb>=1024?(x.rss_mb/1024).toFixed(1)+'G':(x.rss_mb||0)+'M')+'</td><td>'+link+
      '</td><td>'+(pr?'<a href="'+esc(pr.pr.url)+'" target="_blank">#'+esc(pr.pr.number)+'</a>':'')+'</td></tr>';
  }).join('')+'</tbody></table>':'<span class="empty">no services declared and no previews running</span>';
  $('backlog').innerHTML=(s.backlog&&s.backlog.items&&s.backlog.items.length)?
    '<table><tbody>'+s.backlog.items.map(i=>'<tr class="agrow"><td style="width:1%">'+
    chip(i.status||'todo',i.status==='in-progress'?'w':i.status==='done'?'ok':'')+'</td><td>'+esc(i.title)+
    (i.repo?' <span class="empty">'+esc(i.repo)+'</span>':'')+'</td></tr>').join('')+'</tbody></table>'
    :'<span class="empty">no backlog.yaml (items: [{title, repo, status}])</span>';
  renderBox(s);
  renderSubs(s);
}

// THE TWO SUBSCRIPTIONS THE FLEET RUNS ON. Amber at 80, red at 100 - the same
// thresholds the steward and the console use, because three surfaces
// disagreeing about when to worry is three surfaces nobody trusts. A window
// with no percentage is absent, never a zero: "0% used" is a claim, and the
// only honest answer to an unreadable endpoint is that it was unreadable.
// <cel35:sub-cells>
function subReset(iso){
  if(!iso) return '';
  var at=new Date(iso); if(isNaN(at.getTime())) return String(iso);
  var hhmm=String(at.getHours()).padStart(2,'0')+':'+String(at.getMinutes()).padStart(2,'0');
  if(at.getTime()-Date.now()<86400000) return hhmm;
  return ['Sun','Mon','Tue','Wed','Thu','Fri','Sat'][at.getDay()]+' '+hhmm;
}
// THE SAME CELLS THE CONSOLE DRAWS. This is a copy of subCells() in
// tools/console/views.mjs - the dashboard's client script is served as text
// and cannot import it - and tests/console.test.sh runs both over one fixture
// and fails when they differ. They differed once, silently, and the owner saw
// Claude alone in the TUI and everything on this page.
function subCells(s){
  var provider=String((s&&s.provider)||'');
  var label=String((s&&(s.label||s.account))||'');
  var windows=((s&&s.windows)||[]).filter(function(w){return w&&w.used_pct!==null&&w.used_pct!==undefined});
  if(!windows.length){
    var reason=(s&&s.extra&&s.extra.reason)||'not signed in here, or the endpoint is down';
    return [[provider,label,'unreadable: '+reason,'']];
  }
  var rows=windows.map(function(w,i){
    return [i===0?provider:'', i===0?label:'',
      w.name+' '+Math.round(Number(w.used_pct)||0)+'%',
      subReset(w.resets_at)?'resets '+subReset(w.resets_at):''];
  });
  if(s&&s.extra&&s.extra.state==='disabled'){
    rows.push(['','','extra: '+String(s.extra.reason||'disabled').replace(/_/g,' '),'']);
  }
  return rows;
}
// </cel35:sub-cells>
// The Box panel: what this box runs on nobody's behalf in particular, drawn
// on the one dashboard that owns it and replaced by a single pointer line on
// every other. Four dashboards each drawing this is how one broker read as
// several.
function renderBox(s){
  var el=$('box'); if(!el) return;
  var b=s.box||{mine:true,owner:'',url:''};
  if(!b.mine){
    el.innerHTML='<span class="empty">box services and subscriptions: '+
      (b.url?'<a href="'+esc(b.url)+'" target="_blank">'+esc(b.url)+' \u2197</a>':esc(b.owner))+'</span>';
    return;
  }
  var rows=s.boxServices||[];
  var note='<div class="empty" style="margin-bottom:8px">one broker, one gateway, one of each - the same on every dashboard, so it is drawn here only</div>';
  el.innerHTML=note+(rows.length?'<table><tbody>'+rows.map(function(x){
    var link=x.reach?'<a href="'+esc(x.reach)+'" target="_blank">'+esc(x.reach)+' \u2197</a>':'<span class="empty">not reachable</span>';
    return '<tr class="agrow"><td style="width:1%">'+chip(x.state,x.state==='healthy'?'ok':x.state==='up'?'w':'b')+
      '</td><td class="branch">'+esc(x.name)+'</td><td class="owner">:'+esc(x.port)+
      '</td><td class="owner">'+esc(x.rss_mb>=1024?(x.rss_mb/1024).toFixed(1)+'G':(x.rss_mb||0)+'M')+
      '</td><td>'+link+'</td></tr>';
  }).join('')+'</tbody></table>':'<span class="empty">no box services declared - cel gateway install</span>');
}
function renderSubs(s){
  var el=$('subs'); if(!el) return;
  // Box-level in their entirety, so they are drawn where the box panel is.
  if(!(s.box||{mine:true}).mine){el.innerHTML='';return}
  var subs=s.subscriptions||[];
  if(!subs.length){el.innerHTML='<span class="empty">no subscription readings cached yet - cel quota asks the providers</span>';return}
  var html='<table><tbody>';
  var groups=[['direct',subs.filter(function(x){return x&&x.source!=='gateway'})],
              ['via gateway',subs.filter(function(x){return x&&x.source==='gateway'})]];
  for(var g=0;g<groups.length;g++){
    var rows=groups[g][1];
    if(!rows.length) continue;
    html+='<tr class="agrow"><td colspan="4" class="empty">'+esc(groups[g][0])+'</td></tr>';
    for(var i=0;i<rows.length;i++){
      var acc=rows[i], cells=subCells(acc);
      // the chip's colour is the window the cell names, so a spent account is
      // red on this page for the same reason it is red on the status edge
      var ws=(acc.windows||[]).filter(function(w){return w&&w.used_pct!==null&&w.used_pct!==undefined});
      for(var j=0;j<cells.length;j++){
        var c=cells[j], pct=ws[j]?Math.round(Number(ws[j].used_pct)||0):null;
        var cls=pct===null?'':pct>=100?'b':pct>=80?'w':'';
        html+='<tr class="agrow"><td>'+esc(c[0])+'</td><td class="empty">'+esc(c[1])+'</td><td>'+
          (pct===null?'<span class="empty">'+esc(c[2])+'</span>':chip(c[2],cls))+
          '</td><td class="empty">'+esc(c[3])+'</td></tr>';
      }
    }
  }
  el.innerHTML=html+'</tbody></table>';
}
async function send(){
  const r=await post('/api/prompt',{target:$('target').value,message:$('msg').value});
  $('promptmsg').textContent=r.ok?'sent':'failed: '+r.text;
  if(r.ok)$('msg').value='';
}
$('themebtn').onclick=cyc;
applyTheme();startSky();

// ---- Canvas UI effects (box-local, Chrome-only, entirely optional) -------
// These components paint the LIVE DOM through the experimental
// HTML-in-Canvas API, so the page has to be re-parented into a
// <canvas layoutsubtree> for them to see it. Canvas children are normally
// fallback content - invisible in any browser that supports canvas at all -
// so the restructure happens ONLY after the component itself confirms
// support. Unsupported, uninstalled or broken: the DOM is never touched and
// the built-in sky stays. Nothing here may take the dashboard down with it.
function fxlog(event,detail){
  post('/api/client-log',{event:event,detail:String(detail||'')}).catch(function(){});
}
(async function effects(){
  try{
    var man=await (await fetch('/fx/manifest.json')).json();
    var names=(man&&man.effects)||[];
    if(!names.length){fxlog('fx-none-installed','');return}
    var mods={};
    for(var i=0;i<names.length;i++){
      try{mods[names[i]]=await import('/fx/'+names[i]+'.js')}catch(e){}
    }
    var loaded=Object.keys(mods);
    var any=Object.values(mods)[0];
    var probe=document.createElement('canvas');
    var pctx=probe.getContext('2d');
    var detail='loaded='+loaded.join(',')
      +' drawElementImage='+(pctx&&typeof pctx.drawElementImage)
      +' requestPaint='+(typeof probe.requestPaint)
      +' webgl2='+!!document.createElement('canvas').getContext('webgl2')
      +' brands='+(navigator.userAgentData?JSON.stringify(navigator.userAgentData.brands):'n/a')
      +' ua='+navigator.userAgent.slice(0,150);
    if(!any||typeof any.supportsHtmlInCanvas!=='function'||!any.supportsHtmlInCanvas()){
      fxlog('fx-unsupported',detail);
      // DEGRADED MODE: without HTML-in-Canvas the components cannot capture
      // the page, but their shaders can still paint. So try them with a
      // DETACHED source canvas and leave the DOM completely alone - the
      // re-parenting is the only dangerous part, and it is what we skip.
      try{
        var dsrc=document.createElement('canvas');
        dsrc.width=innerWidth;dsrc.height=innerHeight;
        // THE BED. The component's syncCanvasSize() does:
        //     output.style.width  = content.clientWidth + 'px'
        //     output.style.height = content.clientHeight + 'px'
        // i.e. it OVERWRITES whatever size we gave the output canvas with the
        // content element's box, and re-does it on every resize. Passing
        // <main> as content therefore pinned the canvas to main's 1180px
        // column, top-left, leaving the rest of the page uncovered - which is
        // exactly the "canvas isn't covering the background" symptom.
        // So content is a dedicated full-viewport element instead. It is empty
        // and hidden from the pointer, and without HTML-in-Canvas nothing is
        // captured from it anyway - it exists purely to be the right SIZE.
        // It must stay ATTACHED: the component walks content.parentElement up
        // the tree looking for a non-transparent background to tint the clouds
        // with, and a detached node has no ancestors, which would force a
        // white base regardless of theme.
        var dbed=document.createElement('div');
        dbed.id='fx-bed';
        dbed.style.cssText='position:fixed;inset:0;z-index:0;pointer-events:none';
        document.body.appendChild(dbed);
        var dout=document.createElement('canvas');
        dout.id='fx-output';
        dout.style.cssText='position:fixed;left:0;top:0;z-index:0;display:block;pointer-events:none';
        document.body.appendChild(dout);
        var dels={source:dsrc,content:dbed,output:dout};
        var dlive=[];
        if(mods.clouds&&mods.clouds.createClouds){var dc=mods.clouds.createClouds(dels,{});if(dc)dlive.push(dc)}
        if(mods.ripple&&mods.ripple.createRipple){var dr=mods.ripple.createRipple(dels,{});if(dr)dlive.push(dr)}
        if(dlive.length){
          // The built-in sky STAYS. It used to be hidden here, which meant a
          // shader that painted nothing visible left a flat background - worse
          // than no effects at all. Leaving it makes degraded mode strictly
          // additive: clouds composite over the stars, and the floor is the
          // page we already had.
          fxlog('fx-degraded',dlive.length+' of '+loaded.length+' painting without DOM capture');
          var fsd=$('fxstate');
          if(fsd){fsd.className='on';fsd.textContent='effects: degraded';
            fsd.title='Canvas UI shaders are painting, but this browser has no '+
              'HTML-in-Canvas so they cannot refract the page itself. Chrome: enable '+
              'chrome://flags/#canvas-draw-element (Enabled, then relaunch) for the full effect.';}
          return;
        }
        dout.remove();dbed.remove();
        fxlog('fx-degraded-null','shaders returned null without html-in-canvas too');
      }catch(de){fxlog('fx-degraded-threw',(de&&de.message)||String(de))}
      var fs=$('fxstate');
      if(fs){fs.textContent='effects off';
        fs.title='Canvas UI is installed ('+loaded.join(', ')+') but this browser has no '+
          'HTML-in-Canvas (drawElementImage/requestPaint). Chrome: enable '+
          'chrome://flags/#canvas-draw-element (Enabled), relaunch, and reload. '+
          'Safari and Firefox do not implement it at all - the built-in canvas sky runs instead.';}
      console.info('celestial: canvas effects installed but this browser has no HTML-in-Canvas; using the built-in sky');
      return;
    }
    fxlog('fx-supported',detail);
    var main=document.querySelector('main');if(!main)return;
    var source=document.createElement('canvas');
    source.setAttribute('layoutsubtree','');
    source.id='fx-source';
    source.style.cssText='display:block;width:100%;position:relative;z-index:1';
    var output=document.createElement('canvas');
    output.id='fx-output';
    output.style.cssText='position:fixed;left:0;top:0;z-index:0;display:block;pointer-events:none';
    // A bed between the source canvas and <main>, for the same reason as the
    // degraded path: the component sizes the output canvas from
    // content.clientWidth/clientHeight, so handing it main would size the
    // effect to main's 1180px column. The bed spans the viewport and carries
    // main inside it, so captured content and painted output are both
    // full-width. (No backticks in here: this whole script is inside a
    // template literal, and one would end it.)
    var bed=document.createElement('div');
    bed.id='fx-bed';
    bed.style.cssText='width:100%;min-height:100vh';
    main.parentNode.insertBefore(source,main);
    bed.appendChild(main);
    source.appendChild(bed);              // the page now lives in the canvas
    document.body.appendChild(output);
    var els={source:source,content:bed,output:output};
    var live=[];
    // clouds paints the ground, so the hand-rolled sky stands down
    if(mods.clouds&&mods.clouds.createClouds){
      var c=mods.clouds.createClouds(els,{});
      if(c){live.push(c);if(raf){cancelAnimationFrame(raf);raf=null}$('sky').style.display='none'}
    }
    if(mods.glass&&mods.glass.createGlass){var g=mods.glass.createGlass(els,{});if(g)live.push(g)}
    if(mods.ripple&&mods.ripple.createRipple){var r=mods.ripple.createRipple(els,{});if(r)live.push(r)}
    if(!live.length){
      // nothing took: put the page back exactly as it was
      source.parentNode.insertBefore(main,source);source.remove();output.remove();bed.remove();
      fxlog('fx-all-null','every factory returned null (webgl2 or html-in-canvas)');
      return;
    }
    fxlog('fx-active',Object.keys(mods).join(','));
    var fso=$('fxstate');
    if(fso){fso.className='on';fso.textContent='effects: '+Object.keys(mods).join(' ');
      fso.title='Canvas UI components running over the live page';}
    addEventListener('beforeunload',function(){live.forEach(function(x){try{x.destroy&&x.destroy()}catch(e){}})});
    console.info('celestial: canvas effects active -',Object.keys(mods).join(', '));
  }catch(e){fxlog('fx-threw',(e&&e.message)||String(e));console.warn('celestial: effects skipped',e)}
})();
matchMedia('(prefers-color-scheme:dark)').addEventListener('change',applyTheme);
async function refreshDashboard(){
  try { await refresh(); }
  catch {
    // Never leave an animated factory claiming current work after a failed poll.
    var floor=$('factory-floor');
    floor.replaceChildren();
    var unavailable=document.createElement('p');
    unavailable.className='factory-unavailable';
    unavailable.textContent='Factory signals unavailable. Reconnecting on the next refresh.';
    floor.appendChild(unavailable);
    $('updated').textContent='refresh failed — last dashboard data may be stale';
  }
}
refreshDashboard();setInterval(refreshDashboard,8000);
</script>`;


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

const server = createServer(async (req, res) => {
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
    if (req.method === 'GET' && req.url === '/api/session') {
      security.session(req, res);
      return;
    }
    if ((req.method === 'GET' || req.method === 'HEAD') &&
        (req.url === '/factory.js' || req.url === '/factory.css')) {
      const body = readFileSync(new URL('.' + req.url, import.meta.url));
      const type = req.url.endsWith('.js') ? 'text/javascript' : 'text/css';
      res.writeHead(200, { 'content-type': type + '; charset=utf-8', 'cache-control': 'no-cache' })
        .end(req.method === 'HEAD' ? undefined : body);
      return;
    }
    if (req.method === 'HEAD' && req.url === '/api/state') {
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
    if ((req.method === 'GET' || req.method === 'HEAD') && req.url === '/') {
      res.writeHead(200, {
        'content-type': 'text/html; charset=utf-8',
        // no-store, not no-cache: the dashboard changes under you as the
        // plane is developed, and a browser holding yesterday's shell is
        // indistinguishable from a broken deploy
        'cache-control': 'no-store, must-revalidate',
      }).end(req.method === 'HEAD' ? undefined : PAGE.replace('<!--UPDATE-CHIP-->', updateChip()));
    } else if (req.method === 'GET' && req.url === '/api/state') {
      const body = JSON.stringify(await state());
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(body);
    } else if (req.method === 'POST' && req.url === '/api/prompt') {
      const { target, message } = await readBody(req);
      if (!target || !message) { res.writeHead(400).end('target and message required'); return; }
      const out = await run('herdr', ['agent', 'prompt', String(target), String(message)], 20000);
      if (out === null) { res.writeHead(502).end('herdr agent prompt failed'); return; }
      res.writeHead(200).end('ok');
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
      const { id } = await readBody(req, 2000);
      if (!/^\d{10,25}$/.test(String(id || ''))) { res.writeHead(400).end('bad decision id'); return; }
      const out = await run(join(CEL_ROOT, 'bin/cel'),
        ['inbox', 'resolve', String(id), '--by', 'dashboard', '--workspace', cfg.name], 10000);
      if (out === null) { res.writeHead(502).end('could not resolve (already resolved, or not a decision?)'); return; }
      delete cache.inbox;
      res.writeHead(200).end('ok');
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
      delete cache.linear;   // the card must reflect the move immediately
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
  console.log(`cel dash: ${cfg.name} on http://${a.address}:${a.port}`);
});
