// CEL-105: THE DATA BEHIND DASHBOARD V2. Every card on the v2 page reads one
// feed here; none of them is a new store. Activity is what the inbox, the
// delegation ledger and gh already say; lanes are the ledger's own history
// with the steward's pane-status samples laid over it; load is the same ring.
// The one write path is /api/v2/act, and it maps a NAME to one existing
// command - the page never sends a command line, and nothing here types into
// a pane: a dashboard that could would be a remote shell behind a cookie.
import { existsSync, readFileSync, writeFileSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { homedir, cpus } from 'node:os';
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
    try {
      const rows = JSON.parse(readFileSync(join(ws.path, '.cel', 'delegations.json'), 'utf8'));
      return Array.isArray(rows) ? rows.filter((r) => r && r.branch) : [];
    } catch { return []; }
  };
  const inboxOf = (ws) => readJsonl(join(INBOX_DIR, `${ws.name}.jsonl`));
  const cursorOf = (ws, who) => {
    try { return readFileSync(join(INBOX_DIR, `${ws.name}.${who}.cursor`), 'utf8').trim(); } catch { return ''; }
  };

  // ---- gh: ONE cached pass per repo, shared by every card that counts merges
  const ghList = (slug, st, fields) => cached(`v2gh:${st}:${slug}`, 600000, async () => {
    const out = await run('gh', ['pr', 'list', '--repo', slug, '--state', st, '--json', fields, '--limit', '200'], 30000);
    try { const v = JSON.parse(out || '[]'); return Array.isArray(v) ? v : []; } catch { return []; }
  });
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
      for (const p of await ghList(r.slug, 'open', 'number,title,url,headRefName,mergeable,reviewDecision,updatedAt')) {
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
  const logAct = (ws, text) => {
    try {
      mkdirSync(dirname(ACTIVITY()), { recursive: true });
      appendFileSync(ACTIVITY(), JSON.stringify({ ts: new Date().toISOString(), ws, kind: 'orchestrator', text }) + '\n');
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
  const PANE_STATE = { working: 'running', blocked: 'waiting', idle: 'idle', done: 'idle' };
  const lanes = async (url, wss) => {
    const range = url.searchParams.get('range') || 'today';
    const now = Date.now();
    let start; let end;
    if (range === 'today') { const d = new Date(); d.setHours(0, 0, 0, 0); start = d.getTime(); end = start + DAY; }
    else { start = now - (range === '3d' ? 3 : 7) * DAY; end = now; }
    const samples = readJsonl(SAMPLES()).map((s) => ({ ...s, t: new Date(s.ts).getTime() })).filter((s) => s.t).sort((a, b) => a.t - b.t);
    let prs = [];
    try { prs = [...await open(wss), ...await merged(wss)]; } catch { prs = []; }
    const clipTo = Math.min(end, now);
    const out = [];
    for (const ws of wss) {
      const lanesOut = [];
      for (const r of ledgerOf(ws)) {
        const hist = (r.history || []).map((h) => ({ state: h.state, t: new Date(h.at).getTime() })).filter((h) => h.t).sort((a, b) => a.t - b.t);
        const segs = [];
        for (let i = 0; i < hist.length; i++) {
          if (TERMINAL.has(hist[i].state)) continue;
          const to = i + 1 < hist.length ? hist[i + 1].t : now;
          segs.push({ from: hist[i].t, to, state: hist[i].state === 'running' ? 'running' : 'waiting' });
        }
        // the samples say what the pane was actually doing; from the first
        // one on, they replace the ledger's coarser "running"
        const mine = r.worktree ? samples.map((s) => {
          const p = (s.panes || []).find((x) => x.cwd === r.worktree);
          return p ? { t: s.t, state: PANE_STATE[p.status] || 'waiting' } : null;
        }).filter(Boolean) : [];
        let final = segs;
        if (mine.length) {
          const cut = mine[0].t;
          const alive = segs.length ? segs[segs.length - 1].to : now;
          final = segs.filter((s) => s.from < cut).map((s) => ({ ...s, to: Math.min(s.to, cut) }));
          mine.forEach((m, i) => final.push({ from: m.t, to: Math.min(i + 1 < mine.length ? mine[i + 1].t : now, Math.max(alive, m.t)), state: m.state }));
        }
        const clipped = [];
        for (const s of final) {
          const from = Math.max(s.from, start); const to = Math.min(s.to, clipTo);
          if (to <= from) continue;
          const prev = clipped[clipped.length - 1];
          if (prev && prev.state === s.state && prev.to >= from) prev.to = Math.max(prev.to, to);
          else clipped.push({ from, to, state: s.state });
        }
        if (!clipped.length) continue;
        const pr = prs.find((p) => p.repo === r.repo && String(p.headRefName).toLowerCase() === String(r.branch).toLowerCase());
        lanesOut.push({ ref: `${r.repo}/${r.branch}`, ...(pr ? { pr: pr.number } : {}), label: r.id || r.branch,
          segments: clipped.map((s) => ({ from: iso(s.from), to: iso(s.to), state: s.state })) });
      }
      out.push({ ws: ws.name, lanes: lanesOut });
    }
    return { start: iso(start), end: iso(end), now: iso(now), workspaces: out };
  };

  // ---- load ---------------------------------------------------------------
  const load = (url) => {
    const hours = Math.min(24 * 14, Math.max(1, Number(url.searchParams.get('hours')) || 24));
    const from = Date.now() - hours * 3600e3;
    const points = readJsonl(SAMPLES()).filter((s) => new Date(s.ts).getTime() >= from)
      .map((s) => ({ ts: iso(s.ts), load: s.load, mem_pct: s.mem_pct, swap_pct: s.swap_pct }));
    return { threads: cpus().length, points };
  };

  // ---- merges / cycle / heat ---------------------------------------------
  const localDay = (t) => { const d = new Date(t); return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`; };
  const merges = async (url, wss) => {
    const days = Math.min(90, Math.max(1, Number(url.searchParams.get('days')) || 14));
    const list = await merged(wss);
    const out = [];
    const today = new Date(); today.setHours(12, 0, 0, 0);
    for (let i = days - 1; i >= 0; i--) out.push({ day: localDay(today.getTime() - i * DAY), repos: {} });
    const byDay = Object.fromEntries(out.map((d) => [d.day, d]));
    for (const p of list) {
      const d = byDay[localDay(p.mergedAt)];
      if (d) d.repos[p.repo] = (d.repos[p.repo] || 0) + 1;
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
      (by[p.repo] || (by[p.repo] = [])).push((m - c) / 3600e3);
    }
    const repos = {};
    for (const [k, v] of Object.entries(by)) repos[k] = { median_hours: Math.round(median(v) * 10) / 10, n: v.length };
    return { days, repos };
  };
  const heat = async (url, wss) => {
    const days = Math.min(365, Math.max(1, Number(url.searchParams.get('days')) || 28));
    const from = Date.now() - days * DAY;
    const grid = Array.from({ length: 7 }, () => Array(24).fill(0));
    for (const p of await merged(wss)) {
      const t = new Date(p.mergedAt);
      if (t.getTime() < from) continue;
      grid[t.getDay()][t.getHours()] += 1;
    }
    return { days, rows: 'day of week, 0 = Sunday (local)', grid };
  };

  // ---- forecast -----------------------------------------------------------
  const WINDOW_MS = { '5h': 5 * 3600e3, '7d': 7 * DAY, monthly: 30 * DAY, daily: DAY, weekly: 7 * DAY };
  const winLen = (name) => {
    if (WINDOW_MS[name]) return WINDOW_MS[name];
    const m = /^(\d+)([hd])$/.exec(String(name || ''));
    return m ? Number(m[1]) * (m[2] === 'h' ? 3600e3 : DAY) : null;
  };
  const forecast = () => cached('v2forecast', 60000, async () => {
    let q = {};
    try { q = JSON.parse(await run(CEL(), ['quota', '--json'], 45000) || '{}'); } catch { q = {}; }
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
    return { items };
  });

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
    if (action === 'message') {
      const text = String(args.text || '').trim();
      if (!NAME.test(String(target || '')) || !text || text.length > 4000) return [400, 'message needs a target and text'];
      if (await cel(['inbox', 'send', String(target), text, '--from', 'dashboard', '--workspace', wsName]) === null) return [502, 'inbox send failed'];
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
    const url = new URL(req.url, 'http://localhost');
    const feed = url.pathname.slice('/api/v2/'.length);
    if (req.method === 'POST') {
      if (feed === 'seen') { const at = markSeen(req, res); json(res, 200, { at }); return true; }
      if (feed === 'act') {
        let body;
        try { body = await readBody(req, 8000); } catch { res.writeHead(400).end('invalid request body'); return true; }
        const [code, text] = await act(req, res, body);
        delete cache.v2forecast;
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
      default: res.writeHead(404).end('not found'); return true;
    }
  };
  return { handle };
};
