// CEL-105: THE DATA BEHIND DASHBOARD V2. Every card on the v2 page reads one
// feed here; none of them is a new store. Activity is what the inbox, the
// delegation ledger and gh already say; lanes are the ledger's own history
// with the steward's pane-status samples laid over it; load is the same ring.
// The one write path is /api/v2/act, and it maps a NAME to one existing
// command - the page never sends a command line, and nothing here types into
// a pane: a dashboard that could would be a remote shell behind a cookie.
import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir, cpus, loadavg, totalmem, freemem, networkInterfaces } from 'node:os';
import { connect } from 'node:net';
import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { store } from './store.mjs';

const DAY = 86400e3;
const iso = (v) => { if (v === null || v === undefined || v === "") return null; const d = new Date(v); return Number.isNaN(d.getTime()) ? null : d.toISOString(); };
// CEL-116: parsed once and kept (store.mjs); the rows are shared, never mutate them
const readJsonl = (f) => { try { return store.jsonl(f); } catch { return []; } };
const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
const TERMINAL = new Set(['landed', 'released', 'abandoned', 'failed', 'cancelled']);
// The fixes a stuck row can offer. Each one only MAILS the owning
// orchestrator: the dashboard notices, the orchestrator decides.
const STUCK = {
  approved_not_landed: 'approved but not landed - land it or say why not',
  merge_conflict: 'has merge conflicts - rebase it',
  changes_no_worker: 'changes requested and no worker on it - restart one',
  idle_with_mail: 'worker idle with unread mail - wake it',
  review_incomplete: 'finished with no review verdict - review it',
  no_activity: 'no activity in 14 days - finish or abandon it',
};

export const createV2 = ({ cfg, run, cached, cache, CEL_ROOT, INBOX_DIR, REGISTRY, agents: agentsCold }) => {
  const STATE_DIR = process.env.CEL_DASH_STATE_DIR || join(homedir(), '.local/share/cel');
  const SAMPLES = () => process.env.CEL_SAMPLES_FILE || join(homedir(), '.local/share/cel/samples.jsonl');
  const ACTIVITY = () => join(STATE_DIR, 'dash-activity.jsonl');
  const SEEN = () => join(STATE_DIR, 'dash-seen.json');
  const CEL = () => process.env.CEL_DASH_CEL || join(CEL_ROOT, 'bin/cel');

  // ---- where to look ------------------------------------------------------
  const BOOT = new Date().toISOString();
  const slugExpr = '[(.repos // [])[] | {name: .name, slug: ((.url // "") | sub("^git@[^:]+:"; "") | sub("^https?://[^/]+/"; "") | sub("\\\\.git$"; ""))}]';
  // CEL-116: served warm like `slow` - a plain TTL cache made every request
  // in the 30th second wait on five yq spawns, and every 8th on herdr
  const workspaces = () => slow('v2ws', 30000, async () => {
    let list = [];
    try {
      list = JSON.parse(await run('yq', ['-c',
        '[.workspaces // {} | to_entries[] | {name: .key, path: (.value.path // .value)}]', REGISTRY()], 8000) || '[]');
    } catch { list = []; }
    if (!Array.isArray(list)) list = [];
    const out = [];
    for (const w of list) {
      const path = String(w.path || '').replace(/^~(?=\/|$)/, homedir());
      let repos = [];
      if (w.name === cfg.name) repos = cfg.repos || [];
      else {
        try { repos = JSON.parse(await run('yq', ['-c', slugExpr, join(path, 'workspace.yaml')], 8000) || '[]'); } catch { repos = []; }
      }
      out.push({ name: w.name, path: w.name === cfg.name ? cfg.wsdir : path, repos: Array.isArray(repos) ? repos : [] });
    }
    if (!out.some((w) => w.name === cfg.name)) out.unshift({ name: cfg.name, path: cfg.wsdir, repos: cfg.repos || [] });
    return out;
  });
  // ?ws=<name>|all; unknown is an error, not an empty card that reads as calm
  const scope = async (url) => {
    const want = url.searchParams.get('ws') || cfg.name;
    const all = await workspaces();
    if (want === 'all') return all;
    const one = all.filter((w) => w.name === want);
    return one.length ? one : null;
  };

  const ledgerOf = (ws) => {
    const rows = store.json(join(ws.path, '.cel', 'delegations.json'));
    return Array.isArray(rows) ? rows.filter((r) => r && r.branch) : [];
  };
  const inboxOf = (ws) => readJsonl(join(INBOX_DIR, `${ws.name}.jsonl`));
  const cursorOf = (ws, who) => {
    try { return readFileSync(join(INBOX_DIR, `${ws.name}.${who}.cursor`), 'utf8').trim(); } catch { return ''; }
  };

  // ---- slow upstreams: gh and `cel quota` -------------------------------
  // Review on #131, three rules. ONE FETCH IN FLIGHT: the page asks merges,
  // cycle and heat at the same moment, and a plain TTL cache let all three
  // miss together and run gh three times. NEVER CACHE A FAILURE: a rate-limit
  // or a network blip cached for ten minutes is ten minutes of a card that
  // says "no merges" with full confidence. NEVER BLOCK ON A WARM VALUE: past
  // its TTL a value is still served while a refresh runs behind it, and a
  // timer keeps the passes warm so a request only waits on a cold box.
  const flights = {};
  const slow = (key, ttlMs, fn) => {
    const f = flights[key] || (flights[key] = { v: undefined, t: 0, p: null });
    const refresh = () => {
      if (!f.p) {
        f.p = Promise.resolve().then(fn).then((v) => {
          if (v !== null && v !== undefined) { f.v = v; f.t = Date.now(); }
          return v;
        }, () => null).finally(() => { f.p = null; });
      }
      return f.p;
    };
    if (f.v !== undefined) {
      if (Date.now() - f.t >= ttlMs) refresh();
      return Promise.resolve(f.v);
    }
    return refresh();
  };
  // ---- computed feeds, kept warm (CEL-116) --------------------------------
  // The same three rules as `slow`, one level up: a feed's computed answer is
  // kept per (feed, query) and served at once; past CEL_DASH_FEED_TTL_MS a
  // refresh runs behind it, and a timer refreshes every feed a page asked for
  // in the last ten minutes, so a refresh only waits on a cold server. A
  // computation that throws is not kept. Each answer carries when it was
  // computed, so a card can say how old it is.
  const feeds = new Map();
  // Review on #141: a feed computed while gh failed is served but never kept
  // as fresh (t=0) - yet a repo gh cannot resolve fails EVERY time (two did on
  // the live box), and retrying it on every ask and every warm pass was a gh
  // spawn every few seconds forever. So a degraded feed is retried at most
  // once per CEL_DASH_DEGRADED_RETRY_MS (default 60 s); in between its last
  // answer is served, and it says how old it is.
  let upstreamFailures = 0;
  const compute = (f) => {
    const before = upstreamFailures;
    f.tried = Date.now();
    return Promise.resolve().then(f.fn).then((v) => { f.v = v; f.t = upstreamFailures === before ? Date.now() : 0; f.at = Date.now(); return f; });
  };
  const DEGRADED_RETRY = () => Number(process.env.CEL_DASH_DEGRADED_RETRY_MS) || 60000;
  // the cheap feeds follow the page; the ones that spawn (services: `cel
  // services` per workspace, usage: `cel quota`) or chew the sample ring
  // (lanes) are kept longer
  const SLOW_FEEDS = /^(services|usage|lanes):/;
  const FEED_TTL = (key) => (key && SLOW_FEEDS.test(key) ? Number(process.env.CEL_DASH_SLOW_FEED_TTL_MS) || 30000 : Number(process.env.CEL_DASH_FEED_TTL_MS) || 5000);
  const due = (k, f) => (f.t ? Date.now() - f.t >= FEED_TTL(k) : Date.now() - (f.tried || 0) >= DEGRADED_RETRY());
  // peek: any last value at once, however degraded (the snapshot's contract)
  const feed = (key, fn, peek = false) => {
    let f = feeds.get(key);
    if (!f) { f = { v: undefined, t: 0, p: null, fn }; feeds.set(key, f); }
    f.fn = fn; f.asked = Date.now();
    const refresh = () => {
      if (!f.p) f.p = compute(f).finally(() => { f.p = null; });
      return f.p;
    };
    if (f.v === undefined) return refresh();
    if (due(key, f)) {
      const p = refresh();
      // a degraded feed past its back-off waits at most
      // CEL_DASH_DEGRADED_WAIT_MS (default 0) for the retry
      if (!f.t && !peek) {
        const wait = Number(process.env.CEL_DASH_DEGRADED_WAIT_MS) || 0;
        return Promise.race([p, new Promise((r) => setTimeout(() => r(f), wait))]);
      }
      p.catch(() => {});
    }
    return Promise.resolve(f);
  };
  // one feed at a time, so a warm pass never holds the event loop for all of
  // them at once; only feeds a page asked for in the last minute are kept warm
  // (review on #141), and one nobody asked for in ten minutes is forgotten
  let feedWarming = false;
  const feedWarm = async () => {
    if (feedWarming) return;
    feedWarming = true;
    try {
      for (const [k, f] of [...feeds]) {
        const idle = Date.now() - f.asked;
        if (idle > 600000) { feeds.delete(k); continue; }
        if (idle > (Number(process.env.CEL_DASH_FEED_KEEP_WARM_MS) || 60000) || f.p || !due(k, f)) continue;
        f.p = compute(f).catch(() => {}).finally(() => { f.p = null; });
        await f.p;
        await new Promise((r) => setImmediate(r));
      }
    } finally { feedWarming = false; }
  };
  // something changed by our own hand (an act): the next ask recomputes
  const feedDrop = () => feeds.clear();
  const wsKey = (wss) => wss.map((w) => w.name).join(',');

  const agents = async () => (await slow('agents', 8000, agentsCold)) || [];
  const ghParse = (out) => { try { const j = JSON.parse(out); return Array.isArray(j) ? j : null; } catch { return null; } };
  const ghList = async (slug, st, fields) => {
    const v = await slow(`gh:${st}:${slug}`, 600000, async () => {
      const out = await run('gh', ['pr', 'list', '--repo', slug, '--state', st, '--json', fields, '--limit', '200'], 30000);
      return out === null ? null : ghParse(out);
    });
    if (!v) upstreamFailures++;
    return v;
  };
  // CEL-117: merged PRs are fetched BY DATE, not by count. `--limit 200` was
  // the newest 200 merges whatever their date, so a repo with 220 merges in a
  // fortnight showed 200 and its oldest days quietly emptied. Every card the
  // page shows asks 90 days or less, so they share ONE 90-day fetch per repo;
  // a longer ask (heat?days=365) fetches its own window on demand and never
  // widens the shared one (review on #142). GitHub's search answers at most
  // 1000 per query: a full page is followed by another ending at the oldest
  // day seen, and PRs are de-duplicated by number.
  const SHARED_WINDOW = 90;
  const MERGE_PAGE = 1000;
  const ymdUtc = (t) => new Date(t).toISOString().slice(0, 10);
  // gh with its stderr, so a refusal can be told from a blip
  const ghTry = (args, timeout) => new Promise((resolve) => {
    execFile('gh', args, { timeout, maxBuffer: 64 * 1024 * 1024 }, (err, out, errOut) =>
      resolve(err ? { ok: false, err: String(errOut || err.message || '') } : { ok: true, out }));
  });
  // Only GitHub saying the repo does not exist or is not ours to read is "no
  // access"; a rate limit, a timeout or a network blip is not (review on #142)
  // - that is a failure, never cached, and the last good answer stands.
  const DENIED = /Could not resolve to a Repository|cannot be searched|Resource not accessible|HTTP 404|Not Found/i;
  const mergedList = async (slug, days) => {
    const v = await slow(`gh:merged:${slug}:${days}`, 600000, async () => {
      const start = ymdUtc(Date.now() - days * DAY);
      const seen = new Map();
      let end = null;
      for (let page = 0; page < 50; page++) {
        const q = end ? `merged:${start}..${end}` : `merged:>=${start}`;
        const r = await ghTry(['pr', 'list', '--repo', slug, '--state', 'merged', '--search', q,
          '--json', 'number,title,url,headRefName,createdAt,mergedAt', '--limit', String(MERGE_PAGE)], 60000);
        if (!r.ok) return DENIED.test(r.err) ? { denied: true } : null;
        const rows = ghParse(r.out);
        if (!rows) return null;
        const before = seen.size;
        for (const p of rows) seen.set(p.number, p);
        if (rows.length < MERGE_PAGE || seen.size === before) break;
        const oldest = rows.reduce((m, p) => (p.mergedAt && p.mergedAt < m ? p.mergedAt : m), rows[0].mergedAt || '');
        if (!oldest) break;
        end = ymdUtc(oldest);
      }
      // GitHub's search answers a repo we cannot read with an empty list and
      // exit 0 - the live box showed two such repos as a calm 0. An empty
      // answer is checked against the repo itself.
      if (!seen.size) {
        const r = await ghTry(['repo', 'view', slug, '--json', 'name'], 30000);
        if (!r.ok) return DENIED.test(r.err) ? { denied: true } : null;
      }
      return { rows: [...seen.values()] };
    });
    if (!v) upstreamFailures++;
    return v;
  };
  // per repo: merges, "no access" (GitHub refused), or "unavailable" (gh
  // failed and there is no earlier answer to stand on)
  const mergedInfo = async (wss, days = 0) => {
    const window = days > SHARED_WINDOW ? Math.min(365, days) : SHARED_WINDOW;
    const list = []; const noAccess = []; const unavailable = [];
    for (const ws of wss) for (const r of ws.repos) {
      if (!r.slug) continue;
      const v = await mergedList(r.slug, window);
      if (!v) { unavailable.push(r.name); continue; }
      if (v.denied) { noAccess.push(r.name); continue; }
      for (const p of v.rows) if (p.mergedAt) list.push({ ...p, ws: ws.name, repo: r.name });
    }
    return { list, noAccess, unavailable };
  };
  const merged = async (wss, days) => (await mergedInfo(wss, days)).list;
  const open = async (wss) => {
    const out = [];
    for (const ws of wss) for (const r of ws.repos) {
      if (!r.slug) continue;
      for (const p of (await ghList(r.slug, 'open', 'number,title,url,headRefName,mergeable,reviewDecision,updatedAt,isDraft')) || []) {
        out.push({ ...p, ws: ws.name, repo: r.name });
      }
    }
    return out;
  };

  // ---- activity -----------------------------------------------------------
  const activity = async (wss) => {
    const names = new Set(wss.map((w) => w.name));
    const items = [];
    for (const p of await merged(wss)) {
      items.push({ ts: iso(p.mergedAt), ws: p.ws, kind: 'merge', text: `${p.repo}#${p.number} merged: ${p.title}`, url: p.url });
    }
    for (const ws of wss) items.push(...wsActivity(ws));
    for (const a of readJsonl(ACTIVITY())) if (names.has(a.ws) && iso(a.ts)) items.push({ ...a, ts: iso(a.ts) });
    items.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
    return items;
  };
  // CEL-116: one workspace's inbox and ledger items, rebuilt only when the
  // store hands back a new parse (a grown inbox, a rewritten ledger) - the
  // largest inbox is tens of thousands of lines, and every row was re-dated
  // on every request. The items are shared: never mutate them.
  const actMemo = new Map();
  const wsActivity = (ws) => {
    const mail = inboxOf(ws);
    const led = store.json(join(ws.path, '.cel', 'delegations.json'));
    const m0 = actMemo.get(ws.name);
    if (m0 && m0.mail === mail && m0.led === led) return m0.items;
    const items = [];
    {
      const decisions = new Map(mail.filter((m) => m.kind === 'decision' || m.kind === 'blocked').map((m) => [m.id, m]));
      for (const m of mail) {
        const ts = iso(m.ts);
        if (!ts) continue;
        const msg = String(m.message || '').slice(0, 200);
        if (m.kind === 'decision') items.push({ ts, ws: ws.name, kind: 'decision', sub: 'new', text: `decision asked: ${msg}` });
        else if (m.kind === 'resolution' && decisions.has(m.ref)) {
          const d = decisions.get(m.ref);
          items.push({ ts, ws: ws.name, kind: d.kind === 'decision' ? 'decision' : 'incident', sub: 'closed',
            text: `closed: ${String(d.message || '').slice(0, 160)}` });
        } else if (m.kind === 'blocked' || m.kind === 'escalation') items.push({ ts, ws: ws.name, kind: 'incident', sub: 'new', text: msg });
      }
      for (const r of ledgerOf(ws)) {
        for (const h of r.history || []) {
          const ts = iso(h.at);
          if (ts) items.push({ ts, ws: ws.name, kind: 'worker', text: `${r.id || r.branch} ${h.state}${h.by ? ` (${h.by})` : ''}` });
        }
        if (r.review && iso(r.review.at)) {
          items.push({ ts: iso(r.review.at), ws: ws.name, kind: 'review',
            text: `${r.id || r.branch} review ${r.review.verdict}${r.review.by ? ` by ${r.review.by}` : ''}` });
        }
      }
    }
    actMemo.set(ws.name, { mail, led, items });
    return items;
  };
  // a ring, newest CEL_DASH_ACTIVITY_KEEP lines (review on #131): the feed
  // only ever shows the recent past, and a log nobody trims is a disk leak
  const logAct = (ws, text) => {
    try {
      const keep = Math.max(1, Number(process.env.CEL_DASH_ACTIVITY_KEEP) || 1000);
      mkdirSync(dirname(ACTIVITY()), { recursive: true });
      appendFileSync(ACTIVITY(), JSON.stringify({ ts: new Date().toISOString(), ws, kind: 'orchestrator', text }) + '\n');
      const lines = readFileSync(ACTIVITY(), 'utf8').split('\n').filter(Boolean);
      if (lines.length > keep) writeFileSync(ACTIVITY(), lines.slice(-keep).join('\n') + '\n');
    } catch { /* the act happened; a lost log line must not undo it */ }
  };

  // ---- stuck --------------------------------------------------------------
  const stuck = async (wss) => {
    const now = Date.now();
    const approvedDays = Number(process.env.CEL_DASH_STUCK_APPROVED_DAYS) || 2;
    const ag = await agents();
    const agentAt = (wt) => ag.find((a) => wt && a.cwd === wt) || null;
    const items = [];
    const add = (ws, ref, reason, since) => items.push({ ws, ref, reason, since: iso(since) || null,
      fix: { label: `tell ${ref.split('/')[0]}-orch`, action: `stuck.${reason}` }, text: STUCK[reason] });
    const pulls = await open(wss);
    for (const ws of wss) {
      const rows = ledgerOf(ws);
      const mail = inboxOf(ws).filter((m) => m.kind !== 'resolution');
      for (const r of rows) {
        const ref = `${r.repo}/${r.branch}`;
        if (TERMINAL.has(r.state)) continue;
        const hist = (r.history || []).map((h) => ({ ...h, t: new Date(h.at).getTime() })).filter((h) => h.t);
        const last = hist.length ? Math.max(...hist.map((h) => h.t)) : 0;
        const rv = r.review || {};
        if (rv.verdict === 'approved' && now - new Date(rv.at).getTime() > approvedDays * DAY) add(ws.name, ref, 'approved_not_landed', rv.at);
        if (r.state === 'finished' && !rv.verdict) {
          const fin = hist.filter((h) => h.state === 'finished').pop();
          if (fin && now - fin.t > DAY) add(ws.name, ref, 'review_incomplete', fin.at);
        }
        const a = agentAt(r.worktree);
        if (r.state === 'running' && a && a.agent_status === 'idle' && r.alias) {
          const cur = cursorOf(ws, r.alias);
          const unread = mail.filter((m) => m.to === r.alias && (!cur || m.id > cur));
          if (unread.length) add(ws.name, ref, 'idle_with_mail', unread[0].ts);
        }
        if (r.state === 'running' && last && now - last > 14 * DAY) add(ws.name, ref, 'no_activity', new Date(last).toISOString());
      }
      for (const p of pulls.filter((x) => x.ws === ws.name)) {
        const ref = `${p.repo}/${p.headRefName}`;
        if (p.mergeable === 'CONFLICTING') add(ws.name, ref, 'merge_conflict', p.updatedAt);
        if (p.reviewDecision === 'CHANGES_REQUESTED') {
          const row = rows.find((r) => r.repo === p.repo && String(r.branch).toLowerCase() === String(p.headRefName).toLowerCase());
          if (!row || TERMINAL.has(row.state) || !agentAt(row.worktree)) add(ws.name, ref, 'changes_no_worker', p.updatedAt);
        }
      }
    }
    return items;
  };

  // ---- "since you last looked", per browser -------------------------------
  const COOKIE = 'cel_v2_seen';
  const cookieToken = (req) => {
    const m = new RegExp(`(?:^|;\\s*)${COOKIE}=([A-Za-z0-9_-]{16,64})`).exec(req.headers.cookie || '');
    return m ? m[1] : null;
  };
  const seenStore = () => { try { return JSON.parse(readFileSync(SEEN(), 'utf8')) || {}; } catch { return {}; } };
  const markSeen = (req, res) => {
    let tok = cookieToken(req);
    if (!tok) {
      tok = randomBytes(18).toString('base64url');
      res.setHeader('set-cookie', `${COOKIE}=${tok}; Path=/; SameSite=Strict; HttpOnly; Max-Age=31536000`);
    }
    const s = seenStore();
    s[tok] = new Date().toISOString();
    // a token per browser ever used; keep the newest few hundred
    const keep = Object.entries(s).sort((a, b) => (a[1] < b[1] ? 1 : -1)).slice(0, 200);
    mkdirSync(dirname(SEEN()), { recursive: true });
    writeFileSync(SEEN(), JSON.stringify(Object.fromEntries(keep)));
    return s[tok];
  };
  const since = async (req, url, wss) => {
    const tok = cookieToken(req);
    const at = iso(url.searchParams.get('at')) || (tok && iso(seenStore()[tok])) || new Date(Date.now() - DAY).toISOString();
    const items = (await feed(`activity:${wsKey(wss)}`, () => activity(wss))).v.filter((i) => i.ts > at);
    const st = (await feed(`stuck:${wsKey(wss)}`, () => stuck(wss))).v;
    return {
      at,
      counts: {
        merged: items.filter((i) => i.kind === 'merge').length,
        decisions_closed: items.filter((i) => i.kind === 'decision' && i.sub === 'closed').length,
        decisions_new: items.filter((i) => i.kind === 'decision' && i.sub === 'new').length,
        incidents: items.filter((i) => i.kind === 'incident' && i.sub === 'new').length,
        stuck: st.length,
      },
      items: items.slice(0, 100),
    };
  };

  // ---- lanes --------------------------------------------------------------
  // Review of #132 on real data: every lane was amber all day. Stale rows
  // (a "running" nobody touched in weeks, finished or orphaned work) each drew
  // one segment across the whole window, and every state that was not
  // "running" read as "waiting". Now: the ledger contributes only its running
  // spans; an open-ended "running" counts up to now only while a pane is live
  // in that worktree (and takes the pane's state); waiting means a pane that
  // said "blocked" - a person is needed - and nothing else.
  const PANE_STATE = { working: 'running', blocked: 'waiting', idle: 'idle', done: 'idle' };
  // CEL-116: the sample ring indexed once per change, worktree -> what its
  // pane said, oldest first. Every ledger row used to scan the whole ring
  // (hundreds of rows x thousands of samples) on every request.
  let paneMemo = { rows: null, idx: new Map() };
  const paneIndex = () => {
    const rows = readJsonl(SAMPLES());
    if (paneMemo.rows === rows) return paneMemo.idx;
    const samples = rows.map((s) => ({ panes: s.panes, t: new Date(s.ts).getTime() })).filter((s) => s.t).sort((a, b) => a.t - b.t);
    const idx = new Map();
    for (const s of samples) {
      const seen = new Set();
      for (const p of s.panes || []) {
        // the first pane in a sample for a cwd is the one that counts, as before
        if (!p || !p.cwd || seen.has(p.cwd)) continue;
        seen.add(p.cwd);
        let l = idx.get(p.cwd); if (!l) { l = []; idx.set(p.cwd, l); }
        l.push({ t: s.t, state: PANE_STATE[p.status] || 'idle' });
      }
    }
    paneMemo = { rows, idx };
    return idx;
  };
  const lanes = async (url, wss) => {
    const range = url.searchParams.get('range') || 'today';
    const now = Date.now();
    let start; let end;
    if (range === 'today') { const d = new Date(); d.setHours(0, 0, 0, 0); start = d.getTime(); end = start + DAY; }
    else { start = now - (range === '3d' ? 3 : 7) * DAY; end = now; }
    const byCwd = paneIndex();
    const ag = await agents();
    let prs = [];
    try { prs = [...await open(wss), ...await merged(wss)]; } catch { prs = []; }
    const clipTo = Math.min(end, now);
    const out = [];
    for (const ws of wss) {
      const lanesOut = [];
      for (const r of ledgerOf(ws)) {
        const hist = (r.history || []).map((h) => ({ state: h.state, t: new Date(h.at).getTime() })).filter((h) => h.t).sort((a, b) => a.t - b.t);
        const live = r.worktree ? ag.find((a) => a.cwd === r.worktree) : null;
        const segs = [];
        for (let i = 0; i < hist.length; i++) {
          if (hist[i].state !== 'running') continue;
          if (i + 1 < hist.length) segs.push({ from: hist[i].t, to: hist[i + 1].t, state: 'running' });
          else if (live) segs.push({ from: hist[i].t, to: now, state: PANE_STATE[live.agent_status] || 'idle', open: true });
        }
        // the samples say what the pane was actually doing, inside the
        // ledger's running spans only
        const mine = (r.worktree && byCwd.get(r.worktree)) || [];
        let final = [];
        for (const sg of segs) {
          const inside = mine.filter((m) => m.t >= sg.from && m.t < sg.to);
          if (!inside.length) { final.push({ from: sg.from, to: sg.to, state: sg.open ? sg.state : 'running' }); continue; }
          if (inside[0].t > sg.from) final.push({ from: sg.from, to: inside[0].t, state: 'running' });
          inside.forEach((m, i) => final.push({ from: m.t, to: i + 1 < inside.length ? inside[i + 1].t : sg.to,
            // the live pane has the last word on the open span
            state: (sg.open && i === inside.length - 1) ? sg.state : m.state }));
        }
        const clipped = [];
        for (const s2 of final) {
          const from = Math.max(s2.from, start); const to = Math.min(s2.to, clipTo);
          if (to <= from) continue;
          const prev = clipped[clipped.length - 1];
          if (prev && prev.state === s2.state && prev.to >= from) prev.to = Math.max(prev.to, to);
          else clipped.push({ from, to, state: s2.state });
        }
        if (!clipped.length) continue;
        const pr = prs.find((p) => p.repo === r.repo && String(p.headRefName).toLowerCase() === String(r.branch).toLowerCase());
        lanesOut.push({ ref: `${r.repo}/${r.branch}`, ...(pr ? { pr: pr.number } : {}), label: r.id || r.branch,
          segments: clipped.map((x) => ({ from: iso(x.from), to: iso(x.to), state: x.state })) });
      }
      out.push({ ws: ws.name, lanes: lanesOut });
    }
    return { start: iso(start), end: iso(end), now: iso(now), workspaces: out };
  };

  // ---- fleet: who is running and what is open, across workspaces ----------
  const WORKTREES = () => join(homedir(), '.herdr', 'worktrees');
  const under = (cwd, dir) => !!cwd && !!dir && (cwd === dir || cwd.startsWith(dir + '/'));
  const fleet = async (wss) => {
    const ag = await agents();
    const pulls = await open(wss);
    const orchestrators = []; const workers = [];
    for (const a of ag) {
      const cwd = a.cwd || '';
      let ws = null; let row = null;
      for (const w of wss) {
        row = ledgerOf(w).find((r) => r.worktree && r.worktree === cwd) || null;
        if (row || w.repos.some((r) => under(cwd, join(WORKTREES(), r.name)))) { ws = w; break; }
      }
      if (ws) {
        const pr = row ? pulls.find((p) => p.repo === row.repo && String(p.headRefName).toLowerCase() === String(row.branch).toLowerCase()) : null;
        workers.push({ name: a.name || (row && row.alias) || a.pane_id, ws: ws.name, status: a.agent_status || 'unknown', pane: a.pane_id || null,
          repo: row ? row.repo : cwd.split('/').slice(-2)[0], branch: row ? row.branch : cwd.split('/').pop(),
          id: row ? row.id || row.branch : '', model: row ? row.model || '' : '', ...(pr ? { pr: pr.number } : {}) });
        continue;
      }
      const home = wss.find((w) => under(cwd, w.path));
      if (home && /-orch$/.test(String(a.name || ''))) {
        orchestrators.push({ name: a.name, ws: home.name, status: a.agent_status || 'unknown', pane: a.pane_id || null });
      }
    }
    const prs = pulls.map((p) => ({ ws: p.ws, repo: p.repo, number: p.number, title: p.title, url: p.url, branch: p.headRefName,
      review: p.reviewDecision || 'REVIEW_REQUIRED', mergeable: p.mergeable || '', draft: !!p.isDraft }));
    return { orchestrators, workers, prs };
  };

  // ---- services: the box's own and each workspace's ---------------------
  // the box's servers bind the tailnet address, not loopback: try both
  // Each server is probed on the host IT binds - a dashboard's dash.host,
  // the pages server's CEL_PAGES_HOST - then on this box's own addresses
  // (the default bind is the tailnet IP, not loopback: probing 127.0.0.1
  // alone called every one of them down).
  const localAddrs = () => Object.values(networkInterfaces()).flat().filter((a) => a && a.family === 'IPv4').map((a) => a.address);
  const answersOn = (port, host) => new Promise((resolve) => {
    const sock = connect(Number(port), host);
    const done = (v) => { sock.destroy(); resolve(v); };
    sock.setTimeout(1000, () => done(false));
    sock.on('connect', () => done(true)); sock.on('error', () => done(false));
  });
  // all candidate hosts at once, first connect wins, never past ~1 s
  const answers = (port, host) => {
    const hosts = [...new Set([host, cfg.host, '127.0.0.1', ...localAddrs()].filter(Boolean))];
    return new Promise((resolve) => {
      let left = hosts.length;
      if (!port || !left) { resolve(false); return; }
      const timer = setTimeout(() => resolve(false), 1000);
      for (const h of hosts) answersOn(port, h).then((ok) => {
        if (ok) { clearTimeout(timer); resolve(true); }
        else if (--left === 0) { clearTimeout(timer); resolve(false); }
      });
    });
  };
  // Review on #132: every tab polls this every 8 s, and it spawns `cel
  // services` per workspace and probes ports. One run in flight, shared by
  // every request (the promise is cached, not just the value), ~8 s fresh;
  // workspaces and probes run side by side.
  // the promise is cached per workspace (and for pages), so a scope of "all"
  // and a scope of one share the same runs
  const svcFlights = {};
  const once = (key, fn) => {
    const f = svcFlights[key];
    if (f && Date.now() - f.t < 8000) return f.p;
    const p = Promise.resolve().then(fn).catch(() => []);
    svcFlights[key] = { t: Date.now(), p };
    return p;
  };
  const pagesRow = () => once('pages', async () => {
    const pagesPort = Number(process.env.CEL_PAGES_PORT) || 7780;
    return [{ name: 'pages', ws: 'box', port: pagesPort, state: (await answers(pagesPort, process.env.CEL_PAGES_HOST)) ? 'up' : 'down', url: '' }];
  });
  const wsRows = (ws) => once(`ws:${ws.name}`, async () => {
    const out = await run(CEL(), ['services', '--workspace', ws.name, '--json'], 15000);
    const rows = [];
    let list = [];
    try { list = JSON.parse(out || '[]'); } catch { list = []; }
    for (const r of Array.isArray(list) ? list : []) {
      const st = String(r.state || '');
      rows.push({ name: r.name, ws: r.workspace === 'box' ? 'box' : ws.name, port: r.port || null,
        state: /healthy|up|running/.test(st) ? 'up' : st || 'unknown', url: r.reach || '' });
    }
    return rows;
  });
  const services = async (wss) => {
    // CEL-107: one dashboard for the box, and it is the server answering this
    // request - up by construction, so it is a row and not a probe
    const dash = [{ name: 'dashboard', ws: 'box', port: cfg.port || null, state: 'up', url: '' }];
    const parts = await Promise.all([dash, pagesRow(), ...wss.map(wsRows)]);
    const seen = new Set(); const items = [];
    for (const it of parts.flat()) { const k = `${it.ws}/${it.name}`; if (!seen.has(k)) { seen.add(k); items.push(it); } }
    return { items };
  };


  // ---- load ---------------------------------------------------------------
  const load = (url) => {
    const hours = Math.min(24 * 14, Math.max(1, Number(url.searchParams.get('hours')) || 24));
    const from = Date.now() - hours * 3600e3;
    const points = readJsonl(SAMPLES()).filter((s) => new Date(s.ts).getTime() >= from)
      .map((s) => ({ ts: iso(s.ts), load: s.load, mem_pct: s.mem_pct, swap_pct: s.swap_pct }));
    // what the box is doing right now, without the ring: the steward may not
    // have sampled yet, and the Box card should not wait for it
    let swap = 0; let avail = freemem();
    try {
      const mi = Object.fromEntries(readFileSync('/proc/meminfo', 'utf8').split('\n').map((l) => /^(\w+):\s+(\d+)/.exec(l)).filter(Boolean).map((m) => [m[1], Number(m[2]) * 1024]));
      if (mi.MemAvailable) avail = mi.MemAvailable;
      if (mi.SwapTotal) swap = Math.round((1 - (mi.SwapFree || 0) / mi.SwapTotal) * 1000) / 10;
    } catch { /* not linux: no swap figure */ }
    const current = { load: Math.round(loadavg()[0] * 100) / 100, mem_pct: Math.round((1 - avail / totalmem()) * 1000) / 10, swap_pct: swap };
    const first = readJsonl(SAMPLES())[0];
    return { threads: cpus().length, points, current, collecting_since: iso(first && first.ts) || BOOT };
  };

  // ---- merges / cycle / heat ---------------------------------------------
  const TZ_NAME = Intl.DateTimeFormat().resolvedOptions().timeZone || 'local';
  const localDay = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const merges = async (url, wss) => {
    const days = Math.min(90, Math.max(1, Number(url.searchParams.get('days')) || 14));
    const { list, noAccess, unavailable } = await mergedInfo(wss, days);
    const out = [];
    const today = new Date(); today.setHours(12, 0, 0, 0);
    for (let i = days - 1; i >= 0; i--) out.push({ day: localDay(today.getTime() - i * DAY), counts: {} });
    const byDay = Object.fromEntries(out.map((d) => [d.day, d]));
    for (const p of list) {
      const d = byDay[localDay(p.mergedAt)];
      if (d) d.counts[p.repo] = (d.counts[p.repo] || 0) + 1;
    }
    // CEL-117: days are the box's local calendar days (the owner reads the
    // chart in local time); GitHub's own search buckets by UTC, so a merge
    // near midnight can sit one day apart from github.com - by design
    return { days: out, timezone: TZ_NAME, no_access: noAccess, unavailable };
  };
  const cycle = async (url, wss) => {
    const days = Math.min(365, Math.max(1, Number(url.searchParams.get('days')) || 30));
    const from = Date.now() - days * DAY;
    const by = {};
    for (const p of await merged(wss, days)) {
      const m = new Date(p.mergedAt).getTime(); const c = new Date(p.createdAt).getTime();
      if (!m || !c || m < from) continue;
      const k = `${p.ws}\t${p.repo}`;
      (by[k] || (by[k] = [])).push((m - c) / 3600e3);
    }
    const repos = Object.entries(by).map(([k, v]) => {
      const [ws, repo] = k.split('\t');
      return { repo, ws, prs: v.length, median_hours: Math.round(median(v) * 10) / 10 };
    });
    return { days, repos };
  };
  const heat = async (url, wss) => {
    const days = Math.min(365, Math.max(1, Number(url.searchParams.get('days')) || 28));
    const from = Date.now() - days * DAY;
    const grid = Array.from({ length: 7 }, () => Array(24).fill(0));
    for (const p of await merged(wss, days)) {
      const t = new Date(p.mergedAt);
      if (t.getTime() < from) continue;
      grid[(t.getDay() + 6) % 7][t.getHours()] += 1;
    }
    // CEL-106's page: Monday first, local time
    return { days, cells: grid };
  };

  // ---- forecast -----------------------------------------------------------
  const WINDOW_MS = { '5h': 5 * 3600e3, '7d': 7 * DAY, monthly: 30 * DAY, daily: DAY, weekly: 7 * DAY };
  const winLen = (name) => {
    if (WINDOW_MS[name]) return WINDOW_MS[name];
    const m = /^(\d+)([hd])$/.exec(String(name || ''));
    return m ? Number(m[1]) * (m[2] === 'h' ? 3600e3 : DAY) : null;
  };
  const quota = () => slow('quota', 60000, async () => {
    const out = await run(CEL(), ['quota', '--json'], 45000);
    if (out === null) return null;
    let q; try { q = JSON.parse(out); } catch { return null; }
    if (!Array.isArray(q.subscriptions)) return null;
    recordUsage(q);
    return q;
  });
  // ---- usage (CEL-108) ----------------------------------------------------
  // THE ONE USAGE CARD. "Usage forecast" and "Claude accounts" were the same
  // windows drawn twice as flat rows, and neither said the things the owner
  // asks: which account runs out before it resets, which ones the
  // orchestrators are on, and which paid balances have vetoed their workers.
  // Everything here is read, not decided: windows from `cel quota --json`,
  // the orchestrators' pool from omp (the CEL-98 source, via the same JSON),
  // the floor veto from quota_vetoed, and who used an account from the
  // delegation ledgers.
  //
  // History: no sampler records quota, so the dashboard keeps its own short
  // ring of each `cel quota` read it makes (at most one a minute, a week
  // kept) - the expanded card's per-window lines come from there and say so
  // when there is nothing yet.
  const USAGE_RING = () => join(STATE_DIR, 'dash-usage.jsonl');
  const winKey = (s, w) => `${s.provider}|${String(s.label || s.account || '').toLowerCase()}|${w.name}|${w.scope || ''}`;
  let lastRecord = 0;
  const recordUsage = (q) => {
    const now = Date.now();
    if (now - lastRecord < 55000) return;
    lastRecord = now;
    const u = {};
    for (const s of q.subscriptions) for (const w of s.windows || []) u[winKey(s, w)] = Math.round((Number(w.used_pct) || 0) * 10) / 10;
    try {
      mkdirSync(STATE_DIR, { recursive: true });
      appendFileSync(USAGE_RING(), JSON.stringify({ ts: new Date(now).toISOString(), u }) + '\n');
      const rows = readJsonl(USAGE_RING());
      if (rows.length > 2400) writeFileSync(USAGE_RING(), rows.slice(-2000).map((r) => JSON.stringify(r)).join('\n') + '\n');
    } catch { /* history is a nicety; the card still draws without it */ }
  };
  const PROVIDER_TITLE = { claude: 'Claude', codex: 'ChatGPT (codex)', opencode: 'OpenCode' };
  const PROVIDER_ORDER = ['claude', 'codex', 'opencode'];
  // a ledger model to the subscription it spends; anything else is an API key
  const modelProvider = (m) => {
    const x = String(m || '').toLowerCase();
    if (/claude|anthropic|opus|sonnet|haiku/.test(x)) return 'claude';
    if (/gpt|codex|openai/.test(x)) return 'codex';
    if (/opencode/.test(x)) return 'opencode';
    return null;
  };
  const winLabel = (w) => {
    const len = winLen(w.name);
    const base = len === 5 * 3600e3 ? '5 hours' : len === DAY ? 'Day' : len === 7 * DAY ? 'Week' : len === 30 * DAY ? 'Month' : String(w.name || 'window');
    return w.scope ? `${w.scope} ${base === 'Week' ? 'week' : base.toLowerCase()}` : base;
  };
  // used / fraction of the window gone; quota_at_risk in lib/quota.sh is the
  // steward's copy of this rule and the two must agree
  const project = (used, len, resets, now) => {
    if (!len || !resets) return used;
    const frac = (len - (resets - now)) / len;
    return frac > 0.05 && frac <= 1 ? Math.min(999, Math.round(used / frac)) : Math.round(used);
  };
  const level = (pct) => (pct >= 95 ? 'bad' : pct >= 75 ? 'warn' : 'ok');
  const usage = async (wss) => {
    const q = (await quota()) || {};
    const now = Date.now();
    const pool = q.orch_pool || {};
    const live = new Set((pool.live || []).map((x) => String(x).toLowerCase()));
    const dead = new Set((pool.disabled || []).map((x) => String(x).toLowerCase()));
    const gw = new Set((q.gateway || []).map((x) => String(x).toLowerCase()));
    // who used each subscription this week, by workspace and profile - from
    // every ledger on the box, since a subscription is the box's
    const weekAgo = now - 7 * DAY;
    const usedBy = {};
    for (const ws of await workspaces()) {
      for (const r of ledgerOf(ws)) {
        const p = modelProvider(r.model || r.profile);
        const at = new Date(((r.history || [])[0] || {}).at || 0).getTime();
        if (!p || !(at >= weekAgo)) continue;
        const k = `${ws.name}\t${r.profile || r.model || '?'}`;
        (usedBy[p] = usedBy[p] || {})[k] = ((usedBy[p] || {})[k] || 0) + 1;
      }
    }
    const usedList = (p) => Object.entries(usedBy[p] || {}).map(([k, n]) => { const [ws, profile] = k.split('\t'); return { ws, profile, n }; })
      .sort((a, b) => b.n - a.n || a.ws.localeCompare(b.ws));
    const ring = readJsonl(USAGE_RING()).filter((r) => new Date(r.ts).getTime() >= weekAgo);
    const atRisk = [];
    const groups = {};
    for (const s of Array.isArray(q.subscriptions) ? q.subscriptions : []) {
      const who = String(s.label || s.account || s.provider);
      const lw = who.toLowerCase();
      const tags = [];
      if (s.provider === 'claude') {
        if (live.has(lw) && !dead.has(lw)) tags.push('orch');
        if (gw.has(`claude|${lw}`)) tags.push('workers');
        if (dead.has(lw)) tags.push('not orch');
      } else if (gw.has(`${s.provider}|${lw}`)) tags.push('workers');
      const windows = (s.windows || []).map((w) => {
        const used = Math.round(Number(w.used_pct) || 0);
        const len = winLen(w.name);
        const resets = new Date(w.resets_at).getTime() || null;
        const projected = project(used, len, resets, now);
        const key = winKey(s, w);
        const history = ring.filter((r) => r.u && r.u[key] !== undefined).map((r) => [r.ts, r.u[key]]);
        return { label: winLabel(w), name: w.name, scope: w.scope || null, used_pct: used, resets: iso(w.resets_at),
          projected_pct: projected, level: level(Math.max(used, projected >= 100 ? 75 : 0)),
          at_risk: projected >= 100 || used >= 95, len: len || 0, history: history.length > 1 ? history.slice(-200) : [] };
      }).sort((a, b) => (a.len - b.len) || String(a.scope || '').localeCompare(String(b.scope || '')));
      for (const w of windows) {
        if (w.at_risk) atRisk.push({ who, provider: s.provider, window: w.label, used_pct: w.used_pct, projected_pct: w.projected_pct, resets: w.resets });
      }
      const g = groups[s.provider] || (groups[s.provider] = { provider: s.provider, title: PROVIDER_TITLE[s.provider] || s.provider, accounts: [] });
      g.accounts.push({ who, account: s.account || who, tags, state: (s.extra || {}).state || '', reason: (s.extra || {}).reason || '',
        at_risk: windows.some((w) => w.at_risk), windows: windows.map(({ len, ...w }) => w), used_by: null });
    }
    const glist = Object.values(groups).sort((a, b) => {
      const ia = PROVIDER_ORDER.indexOf(a.provider); const ib = PROVIDER_ORDER.indexOf(b.provider);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.provider.localeCompare(b.provider);
    });
    for (const g of glist) {
      g.used_by = usedList(g.provider);
      g.who = { orch: g.accounts.some((a) => a.tags.includes('orch')), workers: g.accounts.some((a) => a.tags.includes('workers')),
        profiles: [...new Set(g.used_by.map((u) => u.profile))] };
      // A gateway round-robins one provider's accounts and the ledger does not
      // record which one served a worker, so the split is only knowable when
      // there is one account; otherwise the row does not pretend.
      if (g.accounts.length === 1 && g.used_by.length) g.accounts[0].used_by = g.used_by;
    }
    // pay-as-you-go: one row per account (key fingerprint), workspaces merged
    const names = new Set(wss.map((w) => w.name));
    const bal = {};
    for (const b of Array.isArray(q.balances) ? q.balances : []) {
      const k = `${b.provider}|${b.account || `ws:${b.workspace}`}`;
      const r = bal[k] || (bal[k] = { provider: b.provider, workspaces: [], remaining: b.remaining, floor: b.floor, unit: b.unit,
        state: b.state, vetoed: !!b.vetoed });
      if (b.workspace && !r.workspaces.includes(b.workspace)) r.workspaces.push(b.workspace);
    }
    const balances = Object.values(bal)
      .filter((b) => !b.workspaces.length || b.workspaces.some((w) => names.has(w)))
      .map((b) => ({ ...b, workspaces: b.workspaces.sort(), remaining: Number.isFinite(Number(b.remaining)) && b.remaining !== '' ? Number(b.remaining) : null }))
      .sort((a, b) => a.provider.localeCompare(b.provider) || a.workspaces.join().localeCompare(b.workspaces.join()));
    const claude = (groups.claude || { accounts: [] }).accounts;
    const funded = balances.filter((b) => b.remaining !== null && b.remaining > 0 && !b.vetoed);
    return {
      at: new Date(now).toISOString(),
      summary: {
        at_risk: atRisk,
        orch: { serving: claude.filter((a) => a.tags.includes('orch')).length, of: claude.length },
        below_floor: balances.filter((b) => b.vetoed).length,
        funded: Math.round(funded.reduce((n, b) => n + b.remaining, 0) * 100) / 100,
        funded_by: funded.map((b) => `${b.provider} · ${b.workspaces.join(', ')}`),
      },
      groups: glist,
      balances,
      history: ring.length > 1,
    };
  };
  const forecast = async () => {
    const q = (await quota()) || {};
    const items = [];
    const now = Date.now();
    for (const s of Array.isArray(q.subscriptions) ? q.subscriptions : []) {
      for (const w of s.windows || []) {
        const len = winLen(w.name); const resets = new Date(w.resets_at).getTime();
        const used = Number(w.used_pct) || 0;
        let projected = used;
        if (len && resets) {
          const frac = (len - (resets - now)) / len;
          // too early in a window to extrapolate: say what is used, not a guess
          if (frac > 0.05 && frac <= 1) projected = Math.min(999, Math.round(used / frac));
        }
        items.push({ who: s.label || s.account || s.provider, pool: s.provider + (w.scope ? `/${w.scope}` : ''),
          window: w.name, used_pct: used, resets: iso(w.resets_at), projected_pct: projected });
      }
    }
    return { accounts: items };
  };

  // ---- act ----------------------------------------------------------------
  const NAME = /^[A-Za-z0-9._:-]{1,80}$/;
  const REF = /^[A-Za-z0-9._-]{1,80}\/[A-Za-z0-9._\/-]{1,160}$/;
  const act = async (req, res, body) => {
    const { action, target } = body || {};
    const args = (body && typeof body.args === 'object' && body.args) || {};
    const all = await workspaces();
    const wsName = String(args.ws || cfg.name);
    if (!all.some((w) => w.name === wsName)) return [400, 'unknown workspace'];
    const cel = (argv) => run(CEL(), argv, 30000);
    // Review on #131: a mailbox is only one somebody reads. `cel inbox send`
    // will write to any name, so the dashboard checks first: a ledger alias,
    // the workspace's own orchestrator or a repo orchestrator it declares,
    // or root. A typo here would otherwise be a message nobody ever sees.
    const ws = all.find((w) => w.name === wsName);
    const repos = new Set(ws.repos.map((r) => r.name));
    const known = new Set(['root', `${ws.name}-orch`, ...[...repos].map((r) => `${r}-orch`),
      ...ledgerOf(ws).map((r) => r.alias).filter(Boolean)]);
    if (action === 'message') {
      const text = String(args.text || '').trim();
      if (!NAME.test(String(target || '')) || !text || text.length > 4000) return [400, 'message needs a target and text'];
      if (!known.has(String(target))) return [400, 'unknown recipient'];
      // urgent goes as an escalation so it notifies; an ask is labelled so
      // the recipient knows a reply is wanted
      const kind = args.urgent ? 'escalation' : 'status';
      const body = args.kind === 'ask' ? `[ask] ${text}` : text;
      if (await cel(['inbox', 'send', String(target), body, '--from', 'dashboard', '--workspace', wsName, '--kind', kind]) === null) return [502, 'inbox send failed'];
      logAct(wsName, `dashboard: message to ${target}`);
      return [200, 'ok'];
    }
    if (action === 'orch.restart') {
      const argv = ['run', 'orchestrator', '--workspace', wsName, '--restart'];
      if (args.repo) { if (!NAME.test(String(args.repo))) return [400, 'bad repo']; argv.push('--repo', String(args.repo)); }
      if (await run(CEL(), argv, 120000) === null) return [502, 'restart failed'];
      logAct(wsName, `dashboard: restarted the orchestrator${args.repo ? ` for ${args.repo}` : ''}`);
      return [200, 'ok'];
    }
    if (action === 'afk.on' || action === 'afk.off') {
      const argv = ['afk', action === 'afk.on' ? 'on' : 'off'];
      if (action === 'afk.on' && args.until) {
        if (!/^[A-Za-z0-9:+.\- TZ]{1,40}$/.test(String(args.until))) return [400, 'bad until'];
        argv.push('--until', String(args.until));
      }
      if (await cel(argv) === null) return [502, 'afk failed'];
      logAct(wsName, `dashboard: AFK ${action === 'afk.on' ? 'on' : 'off'}`);
      return [200, 'ok'];
    }
    if (action === 'seen') { markSeen(req, res); return [200, 'ok']; }
    const sm = /^stuck\.([a-z_]+)$/.exec(String(action || ''));
    if (sm && STUCK[sm[1]]) {
      if (!REF.test(String(target || ''))) return [400, 'stuck fix needs a repo/branch target'];
      const repo = String(target).split('/')[0];
      if (!repos.has(repo)) return [400, 'unknown repo'];
      const msg = `stuck: ${target} ${STUCK[sm[1]]} (from the dashboard)`;
      if (await cel(['inbox', 'send', `${repo}-orch`, msg, '--from', 'dashboard', '--workspace', wsName, '--kind', 'status']) === null) return [502, 'inbox send failed'];
      logAct(wsName, `dashboard: ${sm[1]} on ${target} sent to ${repo}-orch`);
      return [200, 'ok'];
    }
    return [400, 'unknown action'];
  };

  // one feed's answer as { v, t }: `since` is per browser (its cookie and
  // ?at), so it is built fresh from the cached activity and stuck lists; every
  // other feed is cached whole per (feed, query)
  const FEED_NAMES = new Set(['since', 'activity', 'stuck', 'lanes', 'load', 'merges', 'cycle', 'heat', 'forecast', 'usage', 'fleet', 'services']);
  const answer = async (name, req, url, wss, peek = false) => {
    if (name === 'since') return { v: await since(req, url, wss), at: Date.now() };
    // Review on #141: the cache key is built only from the parameters the
    // feed reads, each clamped as the feed clamps it, and the feed computes
    // from that same normalised query - so the map is bounded by workspaces
    // x a handful of values, whatever a client sends
    const n = (k, d, lo, hi) => Math.min(hi, Math.max(lo, Math.floor(Number(url.searchParams.get(k)) || d)));
    const q = new URLSearchParams();
    if (name === 'lanes') { const r = url.searchParams.get('range'); q.set('range', !r || r === 'today' ? 'today' : r === '3d' ? '3d' : '7d'); }
    if (name === 'load') q.set('hours', n('hours', 24, 1, 24 * 14));
    if (name === 'merges') q.set('days', n('days', 14, 1, 90));
    if (name === 'cycle') q.set('days', n('days', 30, 1, 365));
    if (name === 'heat') q.set('days', n('days', 28, 1, 365));
    const key = `${name}:${wsKey(wss)}?${q}`;
    const raw = url;
    url = new URL(`http://localhost/?${q}`);
    switch (name) {
      case 'activity': {
        const limit = Math.min(500, Math.max(1, Number(raw.searchParams.get('limit')) || 50));
        const before = iso(raw.searchParams.get('before'));
        const a = await feed(`activity:${wsKey(wss)}`, () => activity(wss), peek);
        let items = a.v;
        if (before) items = items.filter((i) => i.ts < before);
        return { v: { items: items.slice(0, limit).map(({ sub, ...i }) => i) }, at: a.at };
      }
      case 'stuck': { const st = await feed(`stuck:${wsKey(wss)}`, () => stuck(wss), peek); return { v: { items: st.v }, at: st.at }; }
      case 'lanes': return feed(key, () => lanes(url, wss), peek);
      case 'load': return feed(key, () => load(url), peek);
      case 'merges': return feed(key, () => merges(url, wss), peek);
      case 'cycle': return feed(key, () => cycle(url, wss), peek);
      case 'heat': return feed(key, () => heat(url, wss), peek);
      case 'forecast': return feed(key, () => forecast(), peek);
      case 'usage': return feed(key, () => usage(wss), peek);
      case 'fleet': return feed(key, () => fleet(wss), peek);
      default: return feed(key, () => services(wss), peek);
    }
  };
  // FIRST PAINT WITHOUT WAITING: every card's feed, with the query the page
  // asks it with, in one answer - warm values as they are, so a reload draws
  // at once and the live refresh updates it
  const PAGE_QUERY = { activity: 'limit=30', merges: 'days=14', load: 'hours=24', lanes: 'range=today' };
  const snapshot = async (req, url, wss) => {
    const names = ['fleet', 'services', 'since', 'activity', 'stuck', 'lanes', 'load', 'merges', 'cycle', 'heat', 'usage'];
    const out = {};
    await Promise.all(names.map(async (n) => {
      const u = new URL(`http://localhost/api/v2/${n}?${PAGE_QUERY[n] || ''}`);
      if (url.searchParams.get('ws')) u.searchParams.set('ws', url.searchParams.get('ws'));
      try { const r = await answer(n, req, u, wss, true); out[n] = { v: r.v, at: new Date(r.at).toISOString() }; } catch { /* the live refresh reports it */ }
    }));
    return { at: new Date().toISOString(), feeds: out };
  };

  const json = (res, code, v) => res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(v));

  // true when the request was ours
  const handle = async (req, res, readBody) => {
    if (!String(req.url || '').startsWith('/api/v2/')) return false;
    startWarm();
    const url = new URL(req.url, 'http://localhost');
    const name = url.pathname.slice('/api/v2/'.length);
    if (req.method === 'POST') {
      if (name === 'seen') { const at = markSeen(req, res); json(res, 200, { at }); return true; }
      if (name === 'act') {
        let body;
        try { body = await readBody(req, 8000); } catch { res.writeHead(400).end('invalid request body'); return true; }
        const [code, text] = await act(req, res, body);
        if (code === 200) feedDrop();
        res.writeHead(code, { 'content-type': 'text/plain' }).end(text);
        return true;
      }
      res.writeHead(404).end('not found');
      return true;
    }
    if (req.method !== 'GET') { res.writeHead(404).end('not found'); return true; }
    const wss = await scope(url);
    if (!wss) { res.writeHead(400).end('unknown workspace'); return true; }
    if (name === 'snapshot') { json(res, 200, await snapshot(req, url, wss)); return true; }
    if (!FEED_NAMES.has(name)) { res.writeHead(404).end('not found'); return true; }
    const r = await answer(name, req, url, wss);
    res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store', 'x-cel-computed-at': new Date(r.at).toISOString() })
      .end(JSON.stringify(r.v));
    return true;
  };
  // keep the slow passes warm so a request never waits on gh or quota
  const warm = async () => {
    try {
      const wss = await workspaces();
      await Promise.all([merged(wss), open(wss), quota(), services(wss)]);
    } catch { /* a failed warm-up is retried next interval */ }
  };
  // Started by the first v2 request, not at boot: a dashboard nobody opens
  // the v2 page on has no reason to spend gh rate limit or run `cel quota`
  // (and the v1 suite's fixtures were torn down under a boot-time quota run).
  let warming = false;
  const startWarm = () => {
    if (warming) return;
    warming = true;
    setTimeout(warm, 0).unref();
    setInterval(warm, Number(process.env.CEL_DASH_WARM_MS) || 300000).unref();
    setInterval(feedWarm, Number(process.env.CEL_DASH_FEED_WARM_MS) || 5000).unref();
  };
  // test seam: drop the slow caches so a test can watch a cold start
  if (process.env.CEL_TESTING) process.on('SIGUSR2', () => { for (const k of Object.keys(flights)) delete flights[k]; feedDrop(); });
  return { handle };
};
