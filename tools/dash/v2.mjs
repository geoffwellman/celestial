// THE DATA BEHIND DASHBOARD V2. Every card on the v2 page reads one
// feed here; none of them is a new store. Activity is what the inbox and gh
// already say; lanes are each live solo agent's own pane-status samples from
// the steward's ring; load is the same ring.
// The one write path is /api/v2/act, and it maps a NAME to one existing
// command - the page never sends a command line, and nothing here types into
// a pane: a dashboard that could would be a remote shell behind a cookie.
import { existsSync, readFileSync, readdirSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { homedir, cpus, loadavg, totalmem, freemem, networkInterfaces } from 'node:os';
import { connect } from 'node:net';
import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { store } from './store.mjs';

const DAY = 86400e3;
const iso = (v) => { if (v === null || v === undefined || v === "") return null; const d = new Date(v); return Number.isNaN(d.getTime()) ? null : d.toISOString(); };
// parsed once and kept (store.mjs); the rows are shared, never mutate them
const readJsonl = (f) => { try { return store.jsonl(f); } catch { return []; } };
const median = (xs) => {
  if (!xs.length) return null;
  const s = [...xs].sort((a, b) => a - b);
  const m = s.length >> 1;
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
};
// The fixes a stuck row can offer. Each one only MAILS the owning
// orchestrator: the dashboard notices, the orchestrator decides.
const STUCK = {
  merge_conflict: 'has merge conflicts - rebase it',
};

export const createV2 = ({ cfg, run, cached, cache, CEL_ROOT, INBOX_DIR, REGISTRY, agents: agentsCold }) => {
  const STATE_DIR = process.env.CEL_DASH_STATE_DIR || join(process.env.XDG_DATA_HOME || join(homedir(), '.local/share'), 'cel');
  const SAMPLES = () => process.env.CEL_SAMPLES_FILE || join(process.env.XDG_DATA_HOME || join(homedir(), '.local/share'), 'cel/samples.jsonl');
  const ACTIVITY = () => join(STATE_DIR, 'dash-activity.jsonl');
  const SEEN = () => join(STATE_DIR, 'dash-seen.json');
  const CEL = () => process.env.CEL_DASH_CEL || join(CEL_ROOT, 'bin/cel');

  // ---- where to look ------------------------------------------------------
  const BOOT = new Date().toISOString();
  const slugExpr = '[(.repos // [])[] | {name: .name, slug: ((.url // "") | sub("^git@[^:]+:"; "") | sub("^https?://[^/]+/"; "") | sub("\\\\.git$"; ""))}]';
  // every product the workspace builds (lib/workspace.sh ws_product_names):
  // the declared ones in file order, then each repo no product claims - each
  // with its build mode (ws_build_mode: absent is solo)
  const productExpr = '(.products // []) as $ps | ([$ps[].repos // []] | flatten) as $used'
    + ' | [($ps[] | {name: .name, mode: (.mode // "solo")}),'
    + ' ((.repos // [])[] | select(.name as $n | $used | any(. == $n) | not) | {name: .name, mode: (.mode // "solo")})]';
  // Agent and mailbox names are lib/common.sh's cel_alias_norm, asked of that
  // one rule and never re-derived here: raw name -> canonical alias, and no
  // entry when the shell cannot answer, so nothing is matched or mailed by
  // a guess.
  const canonical = async (names) => {
    const uniq = [...new Set(names)];
    if (!uniq.length) return new Map();
    const out = await run('bash', ['-c', '. "$0" && for n; do cel_alias_norm "$n"; echo; done',
      join(CEL_ROOT, 'lib', 'common.sh'), ...uniq], 8000);
    if (out === null) return new Map();
    const lines = out.split('\n');
    return new Map(uniq.map((n, i) => [n, lines[i]]));
  };
  // served through `slow`, so once warm a request never waits on the yq
  // spawns behind it
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
      // the products it builds and how: a solo product's `-orch` agent is the
      // one that builds and ships, and its lanes are further solo agents
      let products = [];
      try { products = JSON.parse(await run('yq', ['-c', productExpr, join(w.name === cfg.name ? cfg.wsdir : path, 'workspace.yaml')], 8000) || '[]'); } catch { products = []; }
      out.push({ name: w.name, path: w.name === cfg.name ? cfg.wsdir : path, repos: Array.isArray(repos) ? repos : [],
        products: Array.isArray(products) ? products.filter((p) => p && p.name) : [] });
    }
    if (!out.some((w) => w.name === cfg.name)) out.unshift({ name: cfg.name, path: cfg.wsdir, repos: cfg.repos || [], products: [] });
    // each workspace's main agents by the names their panes and mailboxes
    // carry, each with how `cel run orchestrator` names it for a restart: one
    // per product (--product), one per declared repo (--repo) and the
    // workspace's own (no selector); a product's name wins a clash
    const orch = (n) => `${n}-orch`;
    const canon = await canonical(out.flatMap((w) => [w.name, ...w.repos.map((r) => r && r.name), ...w.products.map((p) => p.name)]
      .filter(Boolean).map(orch)));
    for (const w of out) {
      const mains = new Map();
      const put = (n, v) => { const a = canon.get(orch(n)); if (a) mains.set(a, v); };
      put(w.name, { product: null, mode: 'fleet' });
      for (const r of w.repos) if (r && r.name) put(r.name, { product: null, repo: r.name, mode: 'fleet' });
      for (const p of w.products) put(p.name, { product: p.name, mode: p.mode === 'solo' ? 'solo' : 'fleet' });
      w.mains = mains;
    }
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

  const inboxOf = (ws) => readJsonl(join(INBOX_DIR, `${ws.name}.jsonl`));

  // ---- slow upstreams: gh and `cel quota` -------------------------------
  // Per key: one computation in flight at a time; a failed computation
  // (throws, null or undefined) is never cached; and a warm value is served
  // at once while a refresh past its TTL runs behind it.
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
  // ---- computed feeds, kept warm -------------------------------------------
  // The same three invariants as `slow`, per (feed, query); each answer
  // carries when it was computed, so a card can say how old it is.
  const feeds = new Map();
  // A feed computed while an upstream failed is served but never fresh (t=0),
  // and is retried at most once per CEL_DASH_DEGRADED_RETRY_MS (default 60 s)
  // so a repo gh can never resolve does not spawn gh on every ask.
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
  // them at once; only feeds a page asked for in the last minute are kept
  // warm, and one nobody asked for in ten minutes is forgotten
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
  // Merged PRs are fetched BY DATE, not by count, so a busy repo's oldest
  // days never quietly empty. Every card the page shows asks 90 days or less,
  // so they share ONE 90-day fetch per repo; a longer ask (heat?days=365)
  // fetches its own window on demand and never widens the shared one.
  // GitHub's search answers at most 1000 per query: a full page is followed
  // by another ending at the oldest day seen, and PRs are de-duplicated by number.
  const SHARED_WINDOW = 90;
  const MERGE_PAGE = 1000;
  const ymdUtc = (t) => new Date(t).toISOString().slice(0, 10);
  // gh with its stderr, so a refusal can be told from a blip
  const ghTry = (args, timeout) => new Promise((resolve) => {
    execFile('gh', args, { timeout, maxBuffer: 64 * 1024 * 1024 }, (err, out, errOut) =>
      resolve(err ? { ok: false, err: String(errOut || err.message || '') } : { ok: true, out }));
  });
  // Only GitHub saying the repo does not exist or is not ours to read is "no
  // access"; a rate limit, a timeout or a network blip is not - that is a
  // failure, never cached, and the last good answer stands.
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
      // exit 0, so an empty answer is checked against the repo itself.
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
  // one workspace's inbox items, rebuilt only when the store hands back a new
  // parse (a grown inbox) rather than re-dated on every request. The items
  // are shared: never mutate them.
  const actMemo = new Map();
  const wsActivity = (ws) => {
    const mail = inboxOf(ws);
    const m0 = actMemo.get(ws.name);
    if (m0 && m0.mail === mail) return m0.items;
    const items = [];
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
    actMemo.set(ws.name, { mail, items });
    return items;
  };
  // a ring, newest CEL_DASH_ACTIVITY_KEEP lines: the feed
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
  // an open PR GitHub cannot merge: its agent should rebase it
  const stuck = async (wss) => (await open(wss)).filter((p) => p.mergeable === 'CONFLICTING').map((p) => {
    const ref = `${p.repo}/${p.headRefName}`;
    return { ws: p.ws, ref, reason: 'merge_conflict', since: iso(p.updatedAt) || null,
      fix: { label: `tell ${p.repo}-orch`, action: 'stuck.merge_conflict' }, text: STUCK.merge_conflict };
  });

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

  // ---- who each live agent is ---------------------------------------------
  // By the identity cel gave it - a directory and a cel_alias_norm name -
  // never by a name's shape alone:
  //  - a solo LANE (cel run solo --lane) stands in
  //    <ws>/.cel/solo/<product>/lane-<lane> and is named <product>-<lane>;
  //  - a reviewer (cel run reviewer) stands in its review checkout of
  //    <repo>#<n> and is named <repo>-pr-<n>-review (an extra one,
  //    --focus, <repo>-pr-<n>-review-<focus>; a QA agent, --qa,
  //    <repo>-pr-<n>-qa-<focus>), for a repo the workspace declares;
  //  - a main agent carries one of the workspace's `-orch` names (w.mains)
  //    and stands in that workspace.
  const under = (cwd, dir) => !!cwd && !!dir && (cwd === dir || cwd.startsWith(dir + '/'));
  const LANE = /^[a-z0-9]+(-[a-z0-9]+)*$/;
  const REVIEWER = /-pr-(\d+)-(?:review(?:-[a-z0-9_-]*)?|qa(?:-[a-z0-9_-]*)?)$/;
  // where `cel run reviewer` checks a PR out and stands its reviewer
  // (lib/run.sh _run_review_dir, reviewer_checkout_path): <dir>/<repo>-pr-<n>,
  // or a later round's <dir>/<repo>-pr-<n>.round.<k>; an extra agent's
  // <dir>/<repo>-pr-<n>-<kind>-<focus>[.round.<k>] (kind review for --focus,
  // qa for --qa). Answers null for the plain reviewer, {kind, focus} for an
  // extra one, or undefined when cwd is neither.
  const REVIEWS = () => process.env.CEL_REVIEW_DIR
    || join(process.env.XDG_STATE_HOME || join(homedir(), '.local', 'state'), 'cel', 'reviews');
  const inReview = (cwd, repo, pr) => {
    const c = cwd.replace(/ \(deleted\)$/, '');
    const at = join(REVIEWS(), `${repo}-pr-${pr}`);
    if (under(c, at) || c.startsWith(`${at}.round.`)) return null;
    for (const kind of ['review', 'qa']) {
      if (!c.startsWith(`${at}-${kind}-`)) continue;
      const focus = c.slice(`${at}-${kind}-`.length).split('/')[0].split('.round.')[0];
      return LANE.test(focus) ? { kind, focus } : undefined;
    }
    return undefined;
  };
  const laneBase = (w, product) => join(w.path, '.cel', 'solo', product, 'lane-');
  const soloProducts = (w) => w.products.filter((p) => p.mode === 'solo').map((p) => p.name);
  const identities = async (wss) => {
    const ag = await agents();
    const mains = []; const lanes = []; const reviewers = []; const rest = []; const keys = [];
    for (const a of ag) {
      const cwd = a.cwd || '';
      const me = { name: String(a.name || ''), status: a.agent_status || 'unknown', pane: a.pane_id || null, cwd };
      if (!me.name) continue;
      // a pane whose directory was deleted is no live lane (lib/mode.sh)
      const lane = [];
      if (!cwd.endsWith(' (deleted)')) {
        for (const w of wss) for (const product of soloProducts(w)) {
          const b = laneBase(w, product);
          const l = cwd.startsWith(b) ? cwd.slice(b.length).split('/')[0] : '';
          if (LANE.test(l) && l !== 'orch') lane.push({ w, product, lane: l, key: `${product}/${l}` });
        }
      }
      const review = [];
      const m = REVIEWER.exec(me.name);
      // a reviewer is its canonical name AND its own review checkout
      if (m) for (const w of wss) for (const r of w.repos) {
        const x = r && r.name ? inReview(cwd, r.name, m[1]) : undefined;
        if (x !== undefined) review.push({ w, repo: r.name, pr: Number(m[1]), ...(x || {}), key: `${r.name}/pr-${m[1]}-${x ? `${x.kind}-${x.focus}` : 'review'}` });
      }
      for (const c of [...lane, ...review]) keys.push(c.key);
      rest.push({ me, lane, review });
    }
    const canon = keys.length ? await canonical(keys) : new Map();
    for (const { me, lane, review } of rest) {
      const l = lane.find((c) => canon.get(c.key) === me.name);
      if (l) { lanes.push({ ...me, ws: l.w.name, mode: 'solo', product: l.product, lane: l.lane }); continue; }
      const rv = review.find((c) => canon.get(c.key) === me.name);
      if (rv) { reviewers.push({ ...me, ws: rv.w.name, repo: rv.repo, pr: rv.pr, ...(rv.focus ? { focus: rv.focus } : {}), ...(rv.kind === 'qa' ? { kind: 'qa' } : {}) }); continue; }
      const home = wss.find((w) => under(me.cwd, w.path) && w.mains.has(me.name));
      if (home) mains.push({ ...me, ws: home.name, ...home.mains.get(me.name) });
    }
    return { mains, lanes, reviewers };
  };
  // A workspace's solo lanes as cel made them - every lane-<name> directory
  // of a solo product, live or not - each by its canonical name. This, not a
  // live pane, is what a lane's mailbox and restart bind to.
  const laneDirs = async (w) => {
    const found = [];
    for (const product of soloProducts(w)) {
      let names = [];
      try { names = readdirSync(join(w.path, '.cel', 'solo', product)); } catch { names = []; }
      for (const d of names) {
        const l = d.startsWith('lane-') ? d.slice(5) : '';
        if (LANE.test(l) && l !== 'orch') found.push({ product, lane: l, key: `${product}/${l}` });
      }
    }
    const canon = found.length ? await canonical(found.map((x) => x.key)) : new Map();
    return found.filter((x) => canon.get(x.key)).map((x) => ({ ...x, name: canon.get(x.key) }));
  };
  // The branch a checkout stands on, read from its own .git (a worktree's is
  // a file naming its gitdir); '' for a directory that is no checkout, or a
  // detached head. This is the one place a solo agent's current branch is
  // written down.
  const branchAt = (dir) => {
    let head;
    try {
      const g = /^gitdir:\s*(.+)$/m.exec(readFileSync(join(dir, '.git'), 'utf8'));
      if (!g) return '';
      head = join(resolve(dir, g[1].trim()), 'HEAD');
    } catch (e) {
      if (!e || e.code !== 'EISDIR') return '';
      head = join(dir, '.git', 'HEAD');
    }
    try { const m = /^ref: refs\/heads\/(.+)$/m.exec(readFileSync(head, 'utf8')); return m ? m[1].trim() : ''; } catch { return ''; }
  };
  // a solo agent's branch, where its pane stands in a checkout, and the PR
  // from that branch in its workspace
  const soloWork = (x, prs) => {
    const branch = branchAt(x.cwd);
    if (!branch) return {};
    const pr = prs.find((p) => p.ws === x.ws && String(p.headRefName).toLowerCase() === branch.toLowerCase());
    return { branch, ...(pr ? { repo: pr.repo, pr: pr.number } : {}) };
  };

  // ---- lanes --------------------------------------------------------------
  // waiting means a pane that said "blocked" - a person is needed - and
  // nothing else.
  const PANE_STATE = { working: 'running', blocked: 'waiting', idle: 'idle', done: 'idle' };
  // the sample ring indexed once per change, cwd -> what its pane said,
  // oldest first, so a request never rescans the ring per agent
  let paneMemo = { rows: null, idx: new Map() };
  const paneIndex = () => {
    const rows = readJsonl(SAMPLES());
    if (paneMemo.rows === rows) return paneMemo.idx;
    const samples = rows.map((s) => ({ panes: s.panes, t: new Date(s.ts).getTime() })).filter((s) => s.t).sort((a, b) => a.t - b.t);
    const idx = new Map();
    for (const s of samples) {
      const seen = new Set();
      for (const p of s.panes || []) {
        // the first pane in a sample for a cwd is the one that counts
        if (!p || !p.cwd || seen.has(p.cwd)) continue;
        seen.add(p.cwd);
        let l = idx.get(p.cwd); if (!l) { l = []; idx.set(p.cwd, l); }
        l.push({ t: s.t, state: PANE_STATE[p.status] || 'idle' });
      }
    }
    paneMemo = { rows, idx };
    return idx;
  };
  // spans clipped to the window, touching same-state spans merged
  const clipSpans = (spans, start, clipTo) => {
    const clipped = [];
    for (const s2 of spans) {
      const from = Math.max(s2.from, start); const to = Math.min(s2.to, clipTo);
      if (to <= from) continue;
      const prev = clipped[clipped.length - 1];
      if (prev && prev.state === s2.state && prev.to >= from) prev.to = Math.max(prev.to, to);
      else clipped.push({ from, to, state: s2.state });
    }
    return clipped.map((x) => ({ from: iso(x.from), to: iso(x.to), state: x.state }));
  };
  // A solo agent's own pane's samples are its spans. A
  // sample stands for at most SAMPLE_SPAN - the strip's half-hour slot - so a
  // steward that stopped sampling is not drawn as work, and the live pane has
  // the last word from its last sample on (or, with none that recent, for the
  // minute it was just seen live).
  const SAMPLE_SPAN = 1800e3;
  const soloSpans = (x, byCwd, now) => {
    const mine = (byCwd.get(x.cwd) || []).filter((m) => m.t <= now);
    const spans = mine.map((m, i) => ({ from: m.t, to: Math.min(i + 1 < mine.length ? mine[i + 1].t : now, m.t + SAMPLE_SPAN), state: m.state }));
    const live = PANE_STATE[x.status] || 'idle';
    const last = spans[spans.length - 1];
    if (last && now - last.from <= SAMPLE_SPAN) { last.to = now; last.state = live; }
    else spans.push({ from: now - 60e3, to: now, state: live });
    return spans;
  };
  const lanes = async (url, wss) => {
    const range = url.searchParams.get('range') || 'today';
    const now = Date.now();
    let start; let end;
    if (range === 'today') { const d = new Date(); d.setHours(0, 0, 0, 0); start = d.getTime(); end = start + DAY; }
    else { start = now - (range === '3d' ? 3 : 7) * DAY; end = now; }
    const byCwd = paneIndex();
    const id = await identities(wss);
    let prs = [];
    try { prs = [...await open(wss), ...await merged(wss)]; } catch { prs = []; }
    const clipTo = Math.min(end, now);
    const out = [];
    for (const ws of wss) {
      const lanesOut = [];
      // a solo product's agents - its main one and each live lane - each a
      // row of its own
      for (const x of [...id.mains.filter((m) => m.mode === 'solo'), ...id.lanes]) {
        if (x.ws !== ws.name) continue;
        const segments = clipSpans(soloSpans(x, byCwd, now), start, clipTo);
        if (!segments.length) continue;
        lanesOut.push({ ref: x.name, kind: x.lane ? 'lane' : 'solo', agent: x.name, product: x.product,
          ...(x.lane ? { lane: x.lane } : {}), ...soloWork(x, prs), label: x.name, segments });
      }
      out.push({ ws: ws.name, lanes: lanesOut });
    }
    return { start: iso(start), end: iso(end), now: iso(now), workspaces: out };
  };

  // ---- fleet: who is running and what is open, across workspaces ----------
  // A solo product's PR is approved by `cel solo land`'s rule, asked of
  // `cel solo approvals` (lib/solo.sh) and never re-derived here: the plain
  // reviewer and every extra one the review policy requires, each at the
  // current head. A PR that is not a solo product's (`n/a`) keeps the forge's
  // review decision, and so does every PR of a workspace `cel solo approvals`
  // could not answer for at all; a solo PR whose reviews cannot be read
  // (`unknown`) is not approved. `waiting` names the required reviewers that
  // have not approved the current head.
  const approvals = async (wss, pulls) => {
    const out = new Map();
    for (const ws of wss) {
      const refs = pulls.filter((p) => p.ws === ws.name).map((p) => `${p.repo}#${p.number}`);
      if (!refs.length) continue;
      const v = await slow(`approvals:${ws.name}`, 60000, async () => {
        const raw = await run(CEL(), ['solo', 'approvals', '--workspace', ws.name, '--json', ...refs], 120000);
        try { const j = JSON.parse(raw || ''); return Array.isArray(j) ? j : null; } catch { return null; }
      });
      for (const a of v || []) if (a && a.ref) out.set(`${ws.name}:${a.ref}`, a);
    }
    return out;
  };
  const REVIEW_OF = { approved: 'APPROVED', changes: 'CHANGES_REQUESTED' };
  const fleet = async (wss) => {
    const id = await identities(wss);
    const pulls = await open(wss);
    const appr = await approvals(wss, pulls);
    // main agents and solo lanes: each restartable and mailable by its name;
    // a solo one says which branch and PR it is on where its pane shows it
    const orchestrators = [...id.mains, ...id.lanes].map(({ cwd, ...x }) => ({ ...x, ...(x.mode === 'solo' ? soloWork({ ...x, cwd }, pulls) : {}) }));
    const reviewers = id.reviewers.map(({ cwd, ...x }) => {
      const pr = pulls.find((p) => p.ws === x.ws && p.repo === x.repo && p.number === x.pr);
      return { ...x, ...(pr ? { branch: pr.headRefName, title: pr.title } : {}) };
    });
    const prs = pulls.map((p) => {
      const a = appr.get(`${p.ws}:${p.repo}#${p.number}`);
      const solo = !!a && a.state !== 'n/a';
      const waiting = solo ? (a.reviewers || []).filter((r) => r.required && r.state !== 'approved').map((r) => r.alias) : [];
      return { ws: p.ws, repo: p.repo, number: p.number, title: p.title, url: p.url, branch: p.headRefName,
        // approved only by land's rule; a change request the forge holds is still one
        review: solo ? REVIEW_OF[a.state] || (p.reviewDecision === 'CHANGES_REQUESTED' ? 'CHANGES_REQUESTED' : 'REVIEW_REQUIRED')
          : p.reviewDecision || 'REVIEW_REQUIRED',
        ...(solo ? { waiting } : {}), mergeable: p.mergeable || '', draft: !!p.isDraft };
    });
    return { orchestrators, reviewers, prs };
  };

  // ---- feature teams --------------------------------------------------------
  // Each workspace's .cel/teams/<feature>/ exactly as `cel team` writes it:
  // team.json (the roster), events.jsonl (what happened) and verdicts.json
  // (the specialists' word on a head). Nothing else - no ledger, and no branch
  // read off a checkout: a repo's candidate head is its latest
  // candidate.updated event, and a member is live only when an agent of
  // exactly its alias is on the roster. A team whose files do not read is a
  // row that says so, never a team that silently is not there.
  const TEAM_RESERVED_MS = () => (Number(process.env.CEL_TEAM_RESERVED_SECS) || 600) * 1000;
  const isObj = (v) => !!v && typeof v === 'object' && !Array.isArray(v);
  const isStr = (v) => typeof v === 'string' && v !== '';
  const readTeamJson = (f) => JSON.parse(readFileSync(f, 'utf8'));
  // the steward's rules (lib/steward.sh _steward_team_read), word for word
  const teamProblem = (t, feature, vs) => {
    if (!isObj(t)) return 'team.json is not an object';
    if (t.feature !== feature) return `team.json names feature ${JSON.stringify(t.feature ?? null)}, not its directory`;
    if (!isStr(t.product)) return 'team.json has no product';
    if (!Array.isArray(t.members)) return 'team.json has no members list';
    if (t.members.some((m) => !isObj(m) || !isStr(m.alias) || typeof m.state !== 'string')) return 'a team.json member has no alias or state';
    if (vs.some((v) => !isObj(v) || typeof v.repo !== 'string' || typeof v.head !== 'string')) return 'a verdicts.json entry has no repo or head';
    return '';
  };
  const roleOf = (v) => `${v.role || '?'}${isStr(v.focus) ? `/${v.focus}` : ''}`;
  const short = (h) => String(h || '').slice(0, 12);
  const teamRow = (w, feature, dir, live, now) => {
    const row = { ws: w.name, feature };
    let t;
    try { t = readTeamJson(join(dir, 'team.json')); } catch { return { ...row, error: 'team.json does not parse' }; }
    let vs = [];
    if (existsSync(join(dir, 'verdicts.json'))) {
      let v;
      try { v = readTeamJson(join(dir, 'verdicts.json')); } catch { v = null; }
      vs = Array.isArray(v) ? v : isObj(v) ? Object.values(v) : null;
      if (!vs) return { ...row, error: 'verdicts.json does not parse' };
    }
    const problem = teamProblem(t, feature, vs);
    if (problem) return { ...row, error: problem };
    const lead = isStr(t.lead) ? t.lead : `${t.product}-orch`;
    const state = t.state || 'open';
    let ev = [];
    try { ev = readJsonl(join(dir, 'events.jsonl')).filter(isObj); } catch { ev = []; }
    const cand = new Map(); const reservedAt = new Map();
    for (const e of ev) {
      const d = isObj(e.data) ? e.data : {};
      if (e.type === 'candidate.updated' && typeof d.repo === 'string' && typeof d.head === 'string') cand.set(d.repo, { repo: d.repo, head: d.head, at: iso(e.ts) });
      if (e.type === 'member.reserved' && isStr(d.alias)) reservedAt.set(d.alias, iso(e.ts));
    }
    const members = t.members.map((m) => ({ alias: m.alias, role: m.role || '?', focus: isStr(m.focus) ? m.focus : null,
      repo: isStr(m.repo) ? m.repo : null, state: m.state, live: live.get(m.alias) || 'not running',
      since: m.state === 'reserved' ? (reservedAt.get(m.alias) || iso(m.created)) : null }));
    // each role/focus's latest word per repo; an older one it replaced is history
    const latest = new Map();
    for (const v of vs) {
      const k = JSON.stringify([v.repo, v.role || '', v.focus || '']);
      const p = latest.get(k);
      if (!p || (Date.parse(v.at) || 0) >= (Date.parse(p.at) || 0)) latest.set(k, v);
    }
    const verdicts = [...latest.values()].map((v) => {
      const c = cand.get(v.repo);
      return { role: v.role || '?', focus: isStr(v.focus) ? v.focus : null, repo: v.repo, head: v.head, verdict: v.verdict || '?',
        by: v.by || null, at: iso(v.at), fresh: !c ? 'no candidate' : c.head === v.head ? 'fresh' : 'stale' };
    });
    const candidates = [...cand.values()];
    // WHO OWES NEXT, from these files alone: an unconfirmed launch is the
    // lead's, a candidate nobody has judged is qa's (the lead's when the team
    // has none), a finding at the candidate is the lead's to route, and a
    // candidate every verdict passes is the lead's to land.
    const owes = [];
    if (state !== 'closed') {
      for (const m of members.filter((x) => x.state === 'reserved')) {
        const at = Date.parse(m.since || '');
        if (Number.isNaN(at) || now - at >= TEAM_RESERVED_MS()) owes.push({ who: lead, what: `${m.alias} reserved ${Number.isNaN(at) ? 'at no recorded time' : `${Math.round((now - at) / 60000)}m ago`} - launch unconfirmed: look, then retire it or add it again` });
        else owes.push({ who: m.alias, what: 'its acknowledgement (cel team ack)' });
      }
      const qa = members.filter((m) => m.role === 'qa' && m.state !== 'retired' && m.state !== 'done').map((m) => m.alias);
      for (const c of candidates) {
        const at = verdicts.filter((v) => v.repo === c.repo && v.fresh === 'fresh');
        const bad = at.filter((v) => v.verdict === 'changes' || v.verdict === 'blocked');
        if (bad.length) owes.push({ who: lead, what: `${c.repo}@${short(c.head)}: ${bad.map((v) => `${roleOf(v)} says ${v.verdict}`).join(', ')}` });
        else if (!at.length) owes.push({ who: qa.length ? qa.join(', ') : lead, what: `a verdict on ${c.repo}@${short(c.head)}${qa.length ? '' : ' (no qa member)'}` });
        else owes.push({ who: lead, what: `${c.repo}@${short(c.head)} passed - integrate and land it` });
      }
      if (!candidates.length) {
        const b = members.filter((m) => m.role === 'builder' && (m.state === 'ready' || m.state === 'working')).map((m) => m.alias);
        owes.push(b.length ? { who: b.join(', '), what: 'a contribution (task.ready) for the lead to make a candidate' } : { who: lead, what: 'members, or a candidate' });
      }
    }
    return { ...row, product: t.product, lead, state, repos: Array.isArray(t.repos) ? t.repos : [], created: iso(t.created), members, candidates, verdicts, owes };
  };
  const teams = async (wss) => {
    const live = new Map((await agents()).map((a) => [String(a.name || ''), a.agent_status || 'unknown']));
    const now = Date.now();
    const items = [];
    for (const w of wss) {
      const root = join(w.path, '.cel', 'teams');
      let dirs = [];
      try { dirs = readdirSync(root, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name).sort(); } catch { continue; }
      // a directory without a team.json is not a team (yet)
      for (const feature of dirs) if (existsSync(join(root, feature, 'team.json'))) items.push(teamRow(w, feature, join(root, feature), live, now));
    }
    return { items };
  };

  // ---- services: the box's own and each workspace's ---------------------
  // Each server is probed on the host IT binds - a dashboard's dash.host,
  // the pages server's CEL_PAGES_HOST - then on this box's own addresses:
  // the default bind is the tailnet IP, so probing loopback alone reads as down.
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
  // Every tab polls this, and it spawns `cel services` per workspace and
  // probes ports. One run in flight per workspace (and for pages), shared by
  // every request - the promise is cached, not just the value - and ~8 s
  // fresh, so a scope of "all" and a scope of one share the same runs.
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
  const dash = [{ name: 'dashboard', ws: 'box', port: cfg.port || 7770, state: 'up', url: '' }];

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
    // one dashboard for the box, and it is the server answering this
    // request - up by construction, so it is a row and not a probe
    const served = await run(CEL(), ['serve', 'list', '--json'], 15000).then((x) => JSON.parse(x || '[]')).catch(() => []);
    const unknown = await run(CEL(), ['serve', 'adopt', '--json'], 15000).then((x) => JSON.parse(x || '[]')).catch(() => []);
    const serverItems = [
      ...served.map((x) => ({ name: x.name, ws: 'box', port: x.port || null, state: 'up', url: '', kind: 'preview', memory_mb: x.memory_mb, age_seconds: x.age_seconds, owner: x.owner, permanent: x.permanent === true })),
      ...unknown.map((x) => ({ name: x.unit || `pid:${x.pid}`, ws: 'box', port: x.port || null, state: 'unledgered', url: '', kind: 'unledgered', memory_mb: x.memory_mb, age_seconds: x.age_seconds }))
    ];
    const parts = await Promise.all([dash, pagesRow(), serverItems, ...wss.map(wsRows)]);
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
    // days are the box's local calendar days (the owner reads the
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
    // Monday first, local time
    return { days, cells: grid };
  };

  // ---- quota ----------------------------------------------------------------
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
  // ---- usage ----------------------------------------------------------------
  // One card per provider answering: which account runs out before it resets,
  // which ones the orchestrators are on, and which paid balances are below
  // their floor. Everything is read, not decided: windows, the orchestrators'
  // pool and the floor veto from `cel quota --json`.
  //
  // History: nothing else records quota, so the dashboard keeps its own short
  // ring of each `cel quota` read it makes (at most one a minute, a week kept)
  // for the expanded card's per-window lines.
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
  const winLabel = (w) => {
    const len = winLen(w.name);
    const base = len === 5 * 3600e3 ? '5 hours' : len === DAY ? 'Day' : len === 7 * DAY ? 'Week' : len === 30 * DAY ? 'Month' : String(w.name || 'window');
    return w.scope ? `${w.scope} ${base === 'Week' ? 'week' : base.toLowerCase()}` : base;
  };
  // used / fraction of the window gone; quota_at_risk in lib/quota.sh is the
  // steward's copy of this rule and the two must agree - including that a
  // window whose reset has already passed is a stale reading, never at risk
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
    const weekAgo = now - 7 * DAY;
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
          at_risk: !(resets && resets <= now) && (projected >= 100 || used >= 95), len: len || 0, history: history.length > 1 ? history.slice(-200) : [] };
      }).sort((a, b) => (a.len - b.len) || String(a.scope || '').localeCompare(String(b.scope || '')));
      for (const w of windows) {
        if (w.at_risk) atRisk.push({ who, provider: s.provider, window: w.label, used_pct: w.used_pct, projected_pct: w.projected_pct, resets: w.resets });
      }
      const g = groups[s.provider] || (groups[s.provider] = { provider: s.provider, title: PROVIDER_TITLE[s.provider] || s.provider, accounts: [] });
      g.accounts.push({ who, account: s.account || who, tags, state: (s.extra || {}).state || '', reason: (s.extra || {}).reason || '',
        at_risk: windows.some((w) => w.at_risk), windows: windows.map(({ len, ...w }) => w) });
    }
    const glist = Object.values(groups).sort((a, b) => {
      const ia = PROVIDER_ORDER.indexOf(a.provider); const ib = PROVIDER_ORDER.indexOf(b.provider);
      return (ia < 0 ? 99 : ia) - (ib < 0 ? 99 : ib) || a.provider.localeCompare(b.provider);
    });
    for (const g of glist) {
      g.who = { orch: g.accounts.some((a) => a.tags.includes('orch')), workers: g.accounts.some((a) => a.tags.includes('workers')) };
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

  // ---- drive: an orchestrator's room ---------------------------------------
  // The room reads the conversation itself, through the drive core: who is
  // running from `cel drive list` (herdr, never `cel fleet`, whose cold read
  // is slow under load), the transcript from a per-file offset tailer kept
  // in this process. A poll reads only the bytes written since the last one;
  // a large session is never reparsed. A room nobody has looked at for ten
  // minutes is forgotten, so this costs nothing while nobody watches.
  const driveList = () => slow('drive:list', 4000, async () => {
    const out = await run(CEL(), ['drive', 'list', '--json'], 10000);
    if (out === null) return null;
    try { const j = JSON.parse(out); return Array.isArray(j) ? j : null; } catch { return null; }
  });
  // loaded on the first room asked for: the dashboard runs without the drive
  // core beside it (tests copy tools/dash alone), and a page nobody opens a
  // room on never needs it
  let core = null;
  const rooms = new Map();
  // a room nobody asked for in ten minutes is dropped by a timer too, so an
  // abandoned tab's tailer and events do not wait for the next ask
  let sweeping = false;
  const roomSweep = (now) => { for (const [k, r] of rooms) if (now - r.asked > ROOM_IDLE_MS) rooms.delete(k); };
  const ROOM_KEEP = 2000;
  const ROOM_IDLE_MS = 600000;
  const MODEL = /"model"\s*:\s*"([^"]{1,120})"/g;
  const roomPush = (r, lines, events) => {
    for (const l of lines) for (const m of l.matchAll(MODEL)) r.model = m[1];
    r.events.push(...events);
    if (r.events.length > ROOM_KEEP) r.events.splice(0, r.events.length - ROOM_KEEP);
  };
  const roomOpen = (o) => {
    const { Tailer, Normaliser, parseLines } = core;
    const r = { session: o.session, runtime: o.runtime || 'omp', tailer: new Tailer(o.session), events: [], model: null, asked: Date.now() };
    const lines = r.tailer.poll();
    const first = parseLines(lines, r.runtime);
    r.norm = new Normaliser(r.runtime);
    for (const e of first) if (e.kind === 'tool') r.norm.calls.set(e.id, e);
    roomPush(r, lines, first);
    return r;
  };
  const driveTail = async (name, since) => {
    const now = Date.now();
    roomSweep(now);
    if (!sweeping) { sweeping = true; setInterval(() => roomSweep(Date.now()), 60000).unref(); }
    const o = ((await driveList()) || []).find((x) => x.name === name);
    if (!o) return null;
    if (!core) core = await import('../drive/transcript.mjs');
    let r = rooms.get(name);
    let reset = false;
    if (!o.session) return { orch: name, status: o.status, runtime: o.runtime, workspace: o.workspace, model: null, events: [], last: null, reset: true };
    if (!r || r.session !== o.session) { r = roomOpen(o); rooms.set(name, r); reset = true; }
    else {
      const lines = r.tailer.poll();
      if (r.tailer.reset) { r = roomOpen(o); rooms.set(name, r); reset = true; }
      else roomPush(r, lines, r.norm.push(lines));
    }
    r.asked = now;
    let start = Math.max(0, r.events.length - 400);
    if (since && !reset) {
      let i = -1;
      for (let k = r.events.length - 1; k >= 0; k--) if (r.events[k].id === since) { i = k; break; }
      if (i >= 0) start = i + 1; else reset = true;
    } else if (since) reset = true;
    if (!since) reset = true;
    const last = r.events.length ? r.events[r.events.length - 1].id : null;
    return { orch: name, status: o.status, runtime: o.runtime, workspace: o.workspace, model: r.model,
      events: r.events.slice(start), last, reset };
  };
  const driveReceipt = async (id) => {
    const out = await run(CEL(), ['drive', 'receipt', id, '--json'], 15000);
    if (out === null) return null;
    try { return JSON.parse(out); } catch { return null; }
  };

  // ---- act ----------------------------------------------------------------
  const NAME = /^[A-Za-z0-9._:-]{1,80}$/;
  const REF = /^[A-Za-z0-9._-]{1,80}\/[A-Za-z0-9._\/-]{1,160}$/;
  const act = async (req, res, body) => {
    const { action, target } = body || {};
    const args = (body && typeof body.args === 'object' && body.args) || {};
    // mail to a live orchestrator through `cel drive send` - kind
    // owner, from owner, delivered by its inbox hook when the turn ends.
    // Never typed into its pane.
    if (action === 'drive.send') {
      const text = String(args.text || '').trim();
      if (!NAME.test(String(target || '')) || !text || text.length > 4000) return [400, 'drive.send needs an orchestrator and text'];
      const live = ((await driveList()) || []).some((o) => o.name === target);
      if (!live) return [400, 'not a running orchestrator'];
      const out = await run(CEL(), ['drive', 'send', String(target), text, '--json'], 30000);
      if (out === null) return [502, 'send failed'];
      // log under a workspace we know, never a name the request made up
      let sent = {}; try { sent = JSON.parse(out); } catch { /* plain id */ }
      const known = (await workspaces()).map((w) => w.name);
      const logWs = [args.ws, sent.workspace].map(String).find((w) => known.includes(w)) || cfg.name;
      logAct(logWs, `dashboard: message to ${target} (drive)`);
      return [200, out.trim()];
    }
    const all = await workspaces();
    const wsName = String(args.ws || cfg.name);
    if (!all.some((w) => w.name === wsName)) return [400, 'unknown workspace'];
    const cel = (argv) => run(CEL(), argv, 30000);
    // A mailbox is only one somebody reads. `cel inbox send`
    // will write to any name, so the dashboard checks first: one of the
    // workspace's main agents, a solo lane it has made, a live
    // reviewer of one of its repos - each by its canonical alias, the name the
    // page shows - or root. A typo here would otherwise be a message nobody sees.
    const ws = all.find((w) => w.name === wsName);
    const repos = new Set(ws.repos.map((r) => r.name));
    if (action === 'message') {
      const text = String(args.text || '').trim();
      if (!NAME.test(String(target || '')) || !text || text.length > 4000) return [400, 'message needs a target and text'];
      const known = new Set(['root', ...ws.mains.keys(),
        ...(await laneDirs(ws)).map((l) => l.name), ...(await identities([ws])).reviewers.map((r) => r.name)]);
      if (!known.has(String(target))) return [400, 'unknown recipient'];
      // urgent goes as an escalation so it notifies; an ask is labelled so
      // the recipient knows a reply is wanted
      const kind = args.urgent ? 'escalation' : 'status';
      const body = args.kind === 'ask' ? `[ask] ${text}` : text;
      if (await cel(['inbox', 'send', String(target), body, '--from', 'dashboard', '--workspace', wsName, '--kind', kind]) === null) return [502, 'inbox send failed'];
      logAct(wsName, `dashboard: message to ${target}`);
      return [200, 'ok'];
    }
    // Restart exactly the agent the page named, with the selector
    // `cel run` knows it by: a product's main agent by --product, a declared
    // repo's by --repo, the workspace's own by the workspace alone, and a solo
    // lane by its product and --lane. Any other name is refused.
    if (action === 'orch.restart') {
      const name = String(target || '');
      if (!NAME.test(name)) return [400, 'restart needs a target'];
      const main = ws.mains.get(name);
      const lane = main ? null : (await laneDirs(ws)).find((l) => l.name === name);
      let argv;
      if (main) {
        argv = ['run', 'orchestrator', '--workspace', wsName];
        if (main.product) argv.push('--product', main.product);
        else if (main.repo) argv.push('--repo', main.repo);
        argv.push('--restart');
      } else if (lane) argv = ['run', 'solo', '--workspace', wsName, '--product', lane.product, '--lane', lane.lane, '--restart'];
      else return [400, 'not a main agent or solo lane of this workspace'];
      if (await run(CEL(), argv, 120000) === null) return [502, 'restart failed'];
      logAct(wsName, `dashboard: restarted ${name}`);
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
  const FEED_NAMES = new Set(['since', 'activity', 'stuck', 'lanes', 'load', 'merges', 'cycle', 'heat', 'usage', 'fleet', 'services', 'teams']);
  const answer = async (name, req, url, wss, peek = false) => {
    if (name === 'since') return { v: await since(req, url, wss), at: Date.now() };
    // The cache key is built only from the parameters the feed reads, each
    // clamped as the feed clamps it, and the feed computes from that same
    // normalised query - so the map stays bounded whatever a client sends.
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
      case 'usage': return feed(key, () => usage(wss), peek);
      case 'fleet': return feed(key, () => fleet(wss), peek);
      case 'teams': return feed(key, () => teams(wss), peek);
      default: return feed(key, () => services(wss), peek);
    }
  };
  // FIRST PAINT WITHOUT WAITING: every card's feed, with the query the page
  // asks it with, in one answer - warm values as they are, so a reload draws
  // at once and the live refresh updates it
  const PAGE_QUERY = { activity: 'limit=30', merges: 'days=14', load: 'hours=24', lanes: 'range=today' };
  const snapshot = async (req, url, wss) => {
    const names = ['fleet', 'services', 'since', 'activity', 'stuck', 'lanes', 'load', 'merges', 'cycle', 'heat', 'usage', 'teams'];
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
    if (name === 'drive/list') { const l = await driveList(); if (!l) { res.writeHead(502).end('herdr did not answer'); return true; } json(res, 200, l); return true; }
    if (name === 'drive/tail') {
      const orch = url.searchParams.get('orch') || '';
      if (!NAME.test(orch)) { res.writeHead(400).end('bad orch'); return true; }
      const since = url.searchParams.get('since');
      const t = await driveTail(orch, since && since.length <= 200 ? since : null);
      if (!t) { res.writeHead(404, { 'cache-control': 'no-store' }).end('no such orchestrator'); return true; }
      json(res, 200, t); return true;
    }
    if (name === 'drive/receipt') {
      const id = url.searchParams.get('id') || '';
      if (!/^\d{1,30}$/.test(id)) { res.writeHead(400).end('bad id'); return true; }
      const r = await driveReceipt(id);
      if (!r) { res.writeHead(404, { 'cache-control': 'no-store' }).end('no such message'); return true; }
      json(res, 200, r); return true;
    }
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
  // the v2 page on has no reason to spend gh rate limit or run `cel quota`.
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
