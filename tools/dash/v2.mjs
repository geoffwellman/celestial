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
import { randomBytes } from 'node:crypto';

const DAY = 86400e3;
const iso = (v) => { if (v === null || v === undefined || v === "") return null; const d = new Date(v); return Number.isNaN(d.getTime()) ? null : d.toISOString(); };
const readJsonl = (f) => {
  try {
    return readFileSync(f, 'utf8').split('\n').filter(Boolean)
      .map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter(Boolean);
  } catch { return []; }
};
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

export const createV2 = ({ cfg, run, cached, cache, CEL_ROOT, INBOX_DIR, REGISTRY, agents }) => {
  const STATE_DIR = process.env.CEL_DASH_STATE_DIR || join(homedir(), '.local/share/cel');
  const SAMPLES = () => process.env.CEL_SAMPLES_FILE || join(homedir(), '.local/share/cel/samples.jsonl');
  const ACTIVITY = () => join(STATE_DIR, 'dash-activity.jsonl');
  const SEEN = () => join(STATE_DIR, 'dash-seen.json');
  const CEL = () => process.env.CEL_DASH_CEL || join(CEL_ROOT, 'bin/cel');

  // ---- where to look ------------------------------------------------------
  const BOOT = new Date().toISOString();
  const slugExpr = '[(.repos // [])[] | {name: .name, slug: ((.url // "") | sub("^git@[^:]+:"; "") | sub("^https?://[^/]+/"; "") | sub("\\\\.git$"; ""))}]';
  const workspaces = () => cached('v2ws', 30000, async () => {
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
      let dashPort = null; let dashHost = null;
      if (w.name === cfg.name) { dashPort = cfg.port || null; dashHost = cfg.host || null; }
      else {
        const [p, h] = String(await run('yq', ['-r', '((.dash.port // "") | tostring) + " " + (.dash.host // "")', join(path, 'workspace.yaml')], 8000) || '').trim().split(/\s+/);
        dashPort = Number(p) > 0 ? Number(p) : null; dashHost = h || null;
      }
      out.push({ name: w.name, path: w.name === cfg.name ? cfg.wsdir : path, repos: Array.isArray(repos) ? repos : [], dashPort, dashHost });
    }
    if (!out.some((w) => w.name === cfg.name)) out.unshift({ name: cfg.name, path: cfg.wsdir, repos: cfg.repos || [], dashPort: cfg.port || null, dashHost: cfg.host || null });
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
    try {
      const rows = JSON.parse(readFileSync(join(ws.path, '.cel', 'delegations.json'), 'utf8'));
      return Array.isArray(rows) ? rows.filter((r) => r && r.branch) : [];
    } catch { return []; }
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
  const ghList = async (slug, st, fields) => {
    const v = await slow(`gh:${st}:${slug}`, 600000, async () => {
      const out = await run('gh', ['pr', 'list', '--repo', slug, '--state', st, '--json', fields, '--limit', '200'], 30000);
      if (out === null) return null;
      try { const j = JSON.parse(out); return Array.isArray(j) ? j : null; } catch { return null; }
    });
    return v || [];
  };
  const merged = async (wss) => {
    const out = [];
    for (const ws of wss) for (const r of ws.repos) {
      if (!r.slug) continue;
      for (const p of await ghList(r.slug, 'merged', 'number,title,url,headRefName,createdAt,mergedAt')) {
        if (p.mergedAt) out.push({ ...p, ws: ws.name, repo: r.name });
      }
    }
    return out;
  };
  const open = async (wss) => {
    const out = [];
    for (const ws of wss) for (const r of ws.repos) {
      if (!r.slug) continue;
      for (const p of await ghList(r.slug, 'open', 'number,title,url,headRefName,mergeable,reviewDecision,updatedAt,isDraft')) {
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
    for (const ws of wss) {
      const mail = inboxOf(ws);
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
    for (const a of readJsonl(ACTIVITY())) if (names.has(a.ws) && iso(a.ts)) items.push({ ...a, ts: iso(a.ts) });
    items.sort((a, b) => (a.ts < b.ts ? 1 : a.ts > b.ts ? -1 : 0));
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
    const items = (await activity(wss)).filter((i) => i.ts > at);
    const st = await stuck(wss);
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
  const lanes = async (url, wss) => {
    const range = url.searchParams.get('range') || 'today';
    const now = Date.now();
    let start; let end;
    if (range === 'today') { const d = new Date(); d.setHours(0, 0, 0, 0); start = d.getTime(); end = start + DAY; }
    else { start = now - (range === '3d' ? 3 : 7) * DAY; end = now; }
    const samples = readJsonl(SAMPLES()).map((s) => ({ ...s, t: new Date(s.ts).getTime() })).filter((s) => s.t).sort((a, b) => a.t - b.t);
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
        const mine = r.worktree ? samples.map((s) => {
          const p = (s.panes || []).find((x) => x.cwd === r.worktree);
          return p ? { t: s.t, state: PANE_STATE[p.status] || 'idle' } : null;
        }).filter(Boolean) : [];
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
  const answers = async (port, host) => {
    const hosts = [...new Set([host, cfg.host, '127.0.0.1', ...localAddrs()].filter(Boolean))];
    for (const h of hosts) if (await answersOn(port, h)) return true;
    return false;
  };
  const answersOn = (port, host) => new Promise((resolve) => {
    if (!port) { resolve(false); return; }
    const s = connect(Number(port), host);
    const done = (v) => { s.destroy(); resolve(v); };
    s.setTimeout(800, () => done(false));
    s.on('connect', () => done(true)); s.on('error', () => done(false));
  });
  const services = async (wss) => {
    const items = [];
    const seen = new Set();
    const add = (it) => { const k = `${it.ws}/${it.name}`; if (!seen.has(k)) { seen.add(k); items.push(it); } };
    const pagesPort = Number(process.env.CEL_PAGES_PORT) || 7780;
    add({ name: 'pages', ws: 'box', port: pagesPort, state: (await answers(pagesPort, process.env.CEL_PAGES_HOST)) ? 'up' : 'down', url: '' });
    for (const ws of wss) {
      if (ws.dashPort) add({ name: `dashboard ${ws.name}`, ws: ws.name, port: ws.dashPort, state: (await answers(ws.dashPort, ws.dashHost)) ? 'up' : 'down', url: '' });
      let rows = [];
      try { rows = JSON.parse(await run(CEL(), ['services', '--workspace', ws.name, '--json'], 15000) || '[]'); } catch { rows = []; }
      for (const r of Array.isArray(rows) ? rows : []) {
        const owner = r.workspace === 'box' ? 'box' : ws.name;
        const st = String(r.state || '');
        add({ name: r.name, ws: owner, port: r.port || null, state: /healthy|up|running/.test(st) ? 'up' : st || 'unknown', url: r.reach || '' });
      }
    }
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
  const localDay = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const merges = async (url, wss) => {
    const days = Math.min(90, Math.max(1, Number(url.searchParams.get('days')) || 14));
    const list = await merged(wss);
    const out = [];
    const today = new Date(); today.setHours(12, 0, 0, 0);
    for (let i = days - 1; i >= 0; i--) out.push({ day: localDay(today.getTime() - i * DAY), counts: {} });
    const byDay = Object.fromEntries(out.map((d) => [d.day, d]));
    for (const p of list) {
      const d = byDay[localDay(p.mergedAt)];
      if (d) d.counts[p.repo] = (d.counts[p.repo] || 0) + 1;
    }
    return { days: out };
  };
  const cycle = async (url, wss) => {
    const days = Math.min(365, Math.max(1, Number(url.searchParams.get('days')) || 30));
    const from = Date.now() - days * DAY;
    const by = {};
    for (const p of await merged(wss)) {
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
    for (const p of await merged(wss)) {
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
    try { const q = JSON.parse(out); return Array.isArray(q.subscriptions) ? q : null; } catch { return null; }
  });
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

  const json = (res, code, v) => res.writeHead(code, { 'content-type': 'application/json', 'cache-control': 'no-store' }).end(JSON.stringify(v));

  // true when the request was ours
  const handle = async (req, res, readBody) => {
    if (!String(req.url || '').startsWith('/api/v2/')) return false;
    startWarm();
    const url = new URL(req.url, 'http://localhost');
    const feed = url.pathname.slice('/api/v2/'.length);
    if (req.method === 'POST') {
      if (feed === 'seen') { const at = markSeen(req, res); json(res, 200, { at }); return true; }
      if (feed === 'act') {
        let body;
        try { body = await readBody(req, 8000); } catch { res.writeHead(400).end('invalid request body'); return true; }
        const [code, text] = await act(req, res, body);
        res.writeHead(code, { 'content-type': 'text/plain' }).end(text);
        return true;
      }
      res.writeHead(404).end('not found');
      return true;
    }
    if (req.method !== 'GET') { res.writeHead(404).end('not found'); return true; }
    const wss = await scope(url);
    if (!wss) { res.writeHead(400).end('unknown workspace'); return true; }
    switch (feed) {
      case 'since': json(res, 200, await since(req, url, wss)); return true;
      case 'activity': {
        const limit = Math.min(500, Math.max(1, Number(url.searchParams.get('limit')) || 50));
        const before = iso(url.searchParams.get('before'));
        let items = await activity(wss);
        if (before) items = items.filter((i) => i.ts < before);
        json(res, 200, { items: items.slice(0, limit).map(({ sub, ...i }) => i) });
        return true;
      }
      case 'stuck': json(res, 200, { items: await stuck(wss) }); return true;
      case 'lanes': json(res, 200, await lanes(url, wss)); return true;
      case 'load': json(res, 200, load(url)); return true;
      case 'merges': json(res, 200, await merges(url, wss)); return true;
      case 'cycle': json(res, 200, await cycle(url, wss)); return true;
      case 'heat': json(res, 200, await heat(url, wss)); return true;
      case 'forecast': json(res, 200, await forecast()); return true;
      case 'fleet': json(res, 200, await fleet(wss)); return true;
      case 'services': json(res, 200, await services(wss)); return true;
      default: res.writeHead(404).end('not found'); return true;
    }
  };
  // keep the slow passes warm so a request never waits on gh or quota
  const warm = async () => {
    try {
      const wss = await workspaces();
      await Promise.all([merged(wss), open(wss), quota()]);
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
  };
  // test seam: drop the slow caches so a test can watch a cold start
  if (process.env.CEL_TESTING) process.on('SIGUSR2', () => { for (const k of Object.keys(flights)) delete flights[k]; });
  return { handle };
};
