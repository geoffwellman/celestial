// cel pages server - serves the box's published HTML documents. Zero
// dependencies. Launched by lib/pages.sh with CEL_PAGES_ROOT, CEL_PAGES_PORT,
// CEL_PAGES_HOST, and on the private tier CEL_PAGES_FEEDBACK plus the public
// root/URL so its nav bar can promote documents.
//
// On the private tier an HTML document is served inside a CHROME SHELL: a nav
// bar plus a same-origin iframe holding the document itself (`?raw=1`).
// Chrome rather than injection because a published page owns its own CSS -
// injecting a bar into `body` fought fixed headers and full-height layouts -
// and same-origin keeps select-to-comment working from the parent frame.
// The public tier serves documents raw: the internet gets no controls.
import { createServer } from 'node:http';
import { readFileSync, readdirSync, statSync, existsSync, appendFileSync, mkdirSync, copyFileSync, unlinkSync, rmSync, writeFileSync } from 'node:fs';
import { join, normalize, extname } from 'node:path';
import { execFile } from 'node:child_process';
import { randomBytes } from 'node:crypto';
import { controlSecurity, internalError } from '../http-security.mjs';

const ROOT = process.env.CEL_PAGES_ROOT;
const PORT = Number(process.env.CEL_PAGES_PORT || 7780);
const HOST = process.env.CEL_PAGES_HOST || '127.0.0.1';
// Feedback, chrome and promote exist only on the private tier.
const FEEDBACK = process.env.CEL_PAGES_FEEDBACK === '1';
const PUBROOT = process.env.CEL_PAGES_PUBLIC_ROOT || '';
const PUBURL = (process.env.CEL_PAGES_PUBLIC_URL || '').replace(/\/$/, '');
const security = FEEDBACK ? controlSecurity({
  host: HOST, port: PORT,
  trustedOrigins: process.env.CEL_PAGES_TRUSTED_ORIGINS,
  csrfToken: process.env.CEL_PAGES_CSRF_TOKEN,
}) : null;

const MIME = {
  '.html': 'text/html; charset=utf-8', '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css', '.js': 'text/javascript', '.json': 'application/json',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg',
  '.gif': 'image/gif', '.svg': 'image/svg+xml', '.webp': 'image/webp',
  '.txt': 'text/plain; charset=utf-8', '.md': 'text/plain; charset=utf-8',
  '.csv': 'text/csv', '.pdf': 'application/pdf', '.ico': 'image/x-icon',
};

// A public share is a TOKEN DIRECTORY under the public root:
//   <pubroot>/<24-hex>/<doc>   + .share.json {doc, created, expires}
// Unguessable, because the public tier is reachable by anyone with the link
// and flat document names are trivially enumerable. Expiry is enforced by the
// public server on every request and swept by the steward.
const TOKEN_RE = /^[a-f0-9]{16,48}$/;
const SHARE_TTL_DEFAULT_H = 168;   // 7 days

const shareDirs = (root) => {
  if (!root || !existsSync(root)) return [];
  return readdirSync(root).filter((d) => TOKEN_RE.test(d))
    .map((token) => {
      try {
        const m = JSON.parse(readFileSync(join(root, token, '.share.json'), 'utf8'));
        return { token, ...m };
      } catch { return null; }
    }).filter(Boolean);
};
const shareExpired = (sh) => !!(sh.expires && Date.now() > new Date(sh.expires).getTime());
const shareFor = (root, doc) => shareDirs(root).filter((sh) => sh.doc === doc && !shareExpired(sh))[0] || null;

const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// Which workspace published a document, from the sidecar `cel publish` wrote.
// Absent for anything published before attribution existed - rendered as
// "unfiled" rather than hidden, because a document with no origin is exactly
// the one worth noticing.
const docWorkspace = (f) => {
  try {
    return JSON.parse(readFileSync(join(ROOT, '.meta', f + '.json'), 'utf8')).workspace || '';
  } catch { return ''; }
};

// Same visual identity as cel dash: night ground, starlight ink, gold accent.
const index = () => {
  const rows = readdirSync(ROOT)
    .filter((f) => !f.startsWith('.'))
    .map((f) => ({ f, st: statSync(join(ROOT, f)) }))
    .filter((x) => x.st.isFile())
    .sort((a, b) => b.st.mtimeMs - a.st.mtimeMs)
    .map((x) => ({ ...x, ws: docWorkspace(x.f) }));
  // Workspaces in the order the documents put them, so the busiest is first.
  const spaces = [];
  for (const r of rows) { const w = r.ws || 'unfiled'; if (!spaces.includes(w)) spaces.push(w); }
  const counts = (w) => rows.filter((r) => (r.ws || 'unfiled') === w).length;
  // The badge IS the public link: "which of these are shared, and what URL do
  // I send?" should be answerable from the index without opening anything.
  const pubTag = (f) => {
    if (!(FEEDBACK && PUBROOT)) return '';
    const sh = shareFor(PUBROOT, f);
    if (!sh) return '';
    const badge = 'color:#e3b34c;font:11px ui-monospace,monospace;border:1px solid #9a7f45;border-radius:8px;padding:0 7px';
    const until = sh.expires ? ` title="expires ${new Date(sh.expires).toLocaleString()}"` : ' title="no expiry"';
    return PUBURL
      ? ` <a href="${esc(PUBURL)}/${sh.token}/${encodeURIComponent(f)}" target="_blank" style="${badge}"${until}>PUBLIC ↗</a>`
      : ` <span style="${badge}"${until}>PUBLIC</span>`;
  };
  return `<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>celestial pages</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23e3b34c' d='M12 1l2.4 8.6L23 12l-8.6 2.4L12 23l-2.4-8.6L1 12l8.6-2.4z'/%3E%3C/svg%3E">
<style>
  body{margin:0;min-height:100vh;color:#e9e5da;font:14px/1.5 system-ui,sans-serif;padding:30px 22px;
    background:radial-gradient(1100px 500px at 85% -120px,#1c2340 0%,rgba(28,35,64,0) 65%),#0d0f14}
  main{max-width:820px;margin:0 auto}
  h1{font:600 20px/1 system-ui;margin:0 0 22px}
  h1 .star{color:#e3b34c;margin-right:10px;font-size:15px}
  table{border-collapse:collapse;width:100%;background:#151823;border:1px solid #232838;border-radius:12px}
  td{padding:10px 16px;border-bottom:1px solid rgba(35,40,56,.55)}
  tr:last-child td{border-bottom:none}
  a{color:#e3b34c;text-decoration:none;font:13.5px ui-monospace,Menlo,Consolas,monospace}
  a:hover{text-decoration:underline;text-underline-offset:3px}
  .meta{color:#565d6e;font:12px ui-monospace,Menlo,Consolas,monospace;text-align:right;white-space:nowrap}
  .empty{color:#565d6e;font:13px ui-monospace,monospace}
  #bar{display:flex;gap:10px;align-items:center;margin:0 0 14px;flex-wrap:wrap}
  #q,#ws{background:#151823;color:#e9e5da;border:1px solid #232838;border-radius:9px;
    padding:8px 11px;font:13px ui-monospace,Menlo,Consolas,monospace;outline:none}
  #q{flex:1;min-width:190px}
  #q:focus,#ws:focus{border-color:#9a7f45}
  .wsTag{color:#8d94a6;font:11px ui-monospace,monospace;border:1px solid #2b3145;
    border-radius:8px;padding:0 7px;margin-left:8px;cursor:pointer}
  .wsTag:hover{color:#e3b34c;border-color:#9a7f45}
  #pager{display:flex;gap:10px;align-items:center;justify-content:flex-end;
    margin-top:14px;color:#565d6e;font:12px ui-monospace,monospace}
  #pager button{background:#151823;color:#e9e5da;border:1px solid #232838;border-radius:8px;
    padding:5px 12px;font:12px ui-monospace,monospace;cursor:pointer}
  #pager button:disabled{opacity:.35;cursor:default}
  #pager button:not(:disabled):hover{border-color:#9a7f45;color:#e3b34c}
  tr.hide{display:none}
</style>
<main><h1><span class="star">✦</span>celestial pages</h1>
${rows.length ? `<div id="bar">
  <input id="q" type="search" placeholder="filter by name…" autocomplete="off">
  <select id="ws">
    <option value="">all workspaces (${rows.length})</option>
    ${spaces.map((w) => `<option value="${esc(w)}">${esc(w)} (${counts(w)})</option>`).join('')}
  </select>
</div>
<table>${rows.map(({ f, st, ws }) =>
      `<tr data-n="${esc(f.toLowerCase())}" data-w="${esc(ws || 'unfiled')}"><td><a href="/${encodeURIComponent(f)}">${esc(f)}</a>${pubTag(f)}<span class="wsTag">${esc(ws || 'unfiled')}</span></td><td class="meta">${(st.size / 1024).toFixed(1)} kB · ${new Date(st.mtimeMs).toLocaleString()}</td></tr>`).join('')}</table>
<div id="pager"><span id="count"></span>
  <button id="prev" type="button">prev</button><button id="next" type="button">next</button></div>
<script>
  var PER = 25, page = 0;
  var rows = [].slice.call(document.querySelectorAll('tbody tr, table tr'));
  var q = document.getElementById('q'), ws = document.getElementById('ws');
  function matching(){
    var t = q.value.trim().toLowerCase(), w = ws.value;
    return rows.filter(function(r){
      if (w && r.getAttribute('data-w') !== w) return false;
      return !t || r.getAttribute('data-n').indexOf(t) >= 0;
    });
  }
  function draw(){
    var m = matching();
    var pages = Math.max(1, Math.ceil(m.length / PER));
    if (page >= pages) page = pages - 1;
    if (page < 0) page = 0;
    rows.forEach(function(r){ r.classList.add('hide'); });
    var from = page * PER;
    m.slice(from, from + PER).forEach(function(r){ r.classList.remove('hide'); });
    document.getElementById('count').textContent = m.length
      ? (from + 1) + '–' + Math.min(from + PER, m.length) + ' of ' + m.length
      : 'nothing matches';
    document.getElementById('prev').disabled = page === 0;
    document.getElementById('next').disabled = page >= pages - 1;
  }
  q.addEventListener('input', function(){ page = 0; draw(); });
  ws.addEventListener('change', function(){ page = 0; draw(); });
  document.getElementById('prev').addEventListener('click', function(){ page--; draw(); });
  document.getElementById('next').addEventListener('click', function(){ page++; draw(); });
  // The tag beside a name is the fastest way to ask "what else came from here?"
  document.addEventListener('click', function(e){
    if (!e.target.classList.contains('wsTag')) return;
    ws.value = e.target.textContent; page = 0; draw();
  });
  draw();
</script>`
    : '<p class="empty">nothing published yet — cel publish &lt;file&gt; [name]</p>'}
</main>`;
};

// The chrome shell: nav bar + the document in a same-origin iframe. Client JS
// is written with concatenation, never template literals - this whole string
// is itself a template literal on the server.
const NAV_H = 46;
const chrome = (name) => `<!doctype html><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="cel-csrf-token" content="${security.token}">
<title>${esc(name)} · celestial</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 24 24'%3E%3Cpath fill='%23e3b34c' d='M12 1l2.4 8.6L23 12l-8.6 2.4L12 23l-2.4-8.6L1 12l8.6-2.4z'/%3E%3C/svg%3E">
<style>
  :root{--bar:#151823;--line:#232838;--ink:#e9e5da;--dim:#7d8494;--faint:#565d6e;
        --gold:#e3b34c;--gold-dim:#9a7f45;--mint:#82dca6;--bad:#e2604e;
        --mono:ui-monospace,'SF Mono',Menlo,Consolas,monospace}
  *{box-sizing:border-box}
  html,body{margin:0;height:100%;overflow:hidden;background:#0d0f14}
  #cel-nav{position:fixed;top:0;left:0;right:0;height:${NAV_H}px;z-index:2;
    display:flex;align-items:center;gap:14px;padding:0 14px;
    background:var(--bar);border-bottom:1px solid var(--line);
    color:var(--ink);font:13px system-ui,sans-serif}
  #cel-nav a{color:var(--gold);text-decoration:none}
  #cel-nav a:hover{text-decoration:underline;text-underline-offset:3px}
  .home{display:inline-flex;align-items:center;gap:8px;white-space:nowrap}
  .home .star{color:var(--gold);font-size:13px}
  .home span.t{color:var(--dim);font:12px var(--mono)}
  .docname{font:12.5px var(--mono);color:var(--ink);overflow:hidden;
    text-overflow:ellipsis;white-space:nowrap;max-width:38vw}
  .spacer{flex:1}
  .vis{display:inline-flex;align-items:center;gap:6px;font:12px var(--mono);
    color:var(--dim);white-space:nowrap}
  .vis::before{content:'';width:7px;height:7px;border-radius:50%;background:var(--faint)}
  .vis.pub{color:var(--gold)}.vis.pub::before{background:var(--gold)}
  .vis a{color:var(--gold);text-decoration:none}
  .vis a:hover{text-decoration:underline;text-underline-offset:3px}
  #puburl{font:11.5px var(--mono);color:var(--faint);max-width:24vw;overflow:hidden;
    text-overflow:ellipsis;white-space:nowrap}
  #puburl a{color:var(--faint)}
  @media(max-width:900px){#puburl{display:none}}
  button{background:#1a1e2c;color:var(--gold);border:1px solid var(--gold-dim);
    border-radius:8px;padding:5px 11px;font:12px var(--mono);cursor:pointer;white-space:nowrap}
  button:hover{background:rgba(227,179,76,.10)}
  select{background:#1a1e2c;color:var(--dim);border:1px solid var(--line);border-radius:8px;
    padding:4px 6px;font:12px var(--mono)}
  #exp{font:11.5px var(--mono);color:var(--faint);white-space:nowrap}
  button.quiet{color:var(--dim);border-color:var(--line)}
  button.quiet:hover{color:var(--ink)}
  #msg{font:12px var(--mono);color:var(--mint);white-space:nowrap}
  #doc{position:fixed;top:${NAV_H}px;left:0;width:100%;height:calc(100% - ${NAV_H}px);
    border:0;background:#fff}
  #panel{position:fixed;top:${NAV_H + 8}px;right:12px;z-index:3;display:none;width:330px;
    background:var(--bar);border:1px solid var(--line);border-radius:12px;padding:12px;
    box-shadow:0 10px 34px rgba(0,0,0,.55);font:13px system-ui,sans-serif;color:var(--ink)}
  #quote{display:none;background:#1a1e2c;border-left:3px solid var(--gold);border-radius:6px;
    padding:6px 10px;margin-bottom:8px;color:#a9afbc;font-size:12px;max-height:74px;overflow:auto}
  #quote a{color:var(--dim);float:right;text-decoration:none;margin-left:8px}
  textarea{width:100%;box-sizing:border-box;min-height:84px;background:#1a1e2c;color:var(--ink);
    border:1px solid var(--line);border-radius:8px;font:13px system-ui;padding:8px;resize:vertical}
  #bubble{position:fixed;z-index:4;display:none}
  #bubble button{border-radius:14px;box-shadow:0 4px 16px rgba(0,0,0,.5)}
  #share{display:none;margin-top:9px;padding-top:9px;border-top:1px solid var(--line);
    font:12px var(--mono);color:var(--dim);word-break:break-all}
  #share a{color:var(--gold)}
  #fbhist{display:none;margin-top:9px;padding-top:9px;border-top:1px solid var(--line);
    font:11.5px var(--mono);color:var(--faint);max-height:130px;overflow:auto}
  #fbhist .it{padding:3px 0}
  #fbhist .ok{color:var(--mint)}#fbhist .no{color:var(--bad)}
  #histpanel{position:fixed;top:${NAV_H + 8}px;right:12px;z-index:3;display:none;width:390px;
    max-height:70vh;overflow:auto;background:var(--bar);border:1px solid var(--line);
    border-radius:12px;padding:12px;box-shadow:0 10px 34px rgba(0,0,0,.55);color:var(--ink)}
  #histpanel .hh{font:600 11px var(--mono);letter-spacing:.14em;text-transform:uppercase;
    color:var(--dim);margin-bottom:10px}
  .ev{display:flex;gap:10px;padding:7px 0;border-top:1px solid rgba(35,40,56,.6);
    font:12px var(--mono);align-items:baseline}
  .ev:first-of-type{border-top:none}
  .ev .when{color:var(--faint);white-space:nowrap}
  .ev .what{flex:1;color:var(--dim);word-break:break-word}
  .ev.pubv .what{color:var(--ink)}
  .ev.fb .what{color:#a9afbc}
  .ev .tag{color:var(--gold)}
  .ev a{color:var(--gold);text-decoration:none;white-space:nowrap}
  @media(max-width:640px){.docname{max-width:26vw}.home span.t{display:none}}
</style>
<nav id="cel-nav">
  <a class="home" href="/"><span class="star">✦</span><span class="t">celestial pages</span></a>
  <span class="docname" id="docname"></span>
  <span class="spacer"></span>
  <span id="msg"></span>
  <span class="vis" id="vis">…</span>
  <span id="exp"></span>
  <span id="puburl"></span>
  <select id="ttl" title="how long the public link lives">
    <option value="24">24 h</option><option value="168" selected>7 days</option>
    <option value="720">30 days</option><option value="0">no expiry</option>
  </select>
  <button id="visbtn">…</button>
  <button class="quiet" id="copybtn">copy link</button>
  <button class="quiet" id="histbtn">history</button>
  <button class="quiet" id="fbbtn">✦ feedback</button>
</nav>
<div id="panel">
  <div id="quote"><span id="quotetext"></span><a href="#" id="quotex">✕</a></div>
  <textarea id="fbmsg" placeholder="Tell the publishing agent…"></textarea>
  <div style="display:flex;gap:8px;align-items:center;margin-top:8px">
    <button id="fbsend">Send</button><span id="fbstatus" style="color:var(--dim);font:12px var(--mono)"></span>
  </div>
  <div id="fbhist"></div>
</div>
<div id="histpanel">
  <div class="hh">activity</div>
  <div id="timeline"></div>
</div>
<div id="bubble"><button id="bubblebtn">✦ feedback on this</button></div>
<iframe id="doc" src="/${encodeURIComponent(name)}?raw=1"></iframe>
<script>(function(){
  var $=function(i){return document.getElementById(i)};
  var doc=${JSON.stringify(name).replace(/</g, '\\u003c')}, pub=null, expires=null, quote='', navH=${NAV_H};
  var csrf=document.querySelector('meta[name="cel-csrf-token"]').content;
  var esc=function(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){
    return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})};
  $('docname').textContent=doc;

  function flash(t,ok){var m=$('msg');m.style.color=ok===false?'var(--bad)':'var(--mint)';
    m.textContent=t;setTimeout(function(){if(m.textContent===t)m.textContent=''},2600)}
  function human(iso){
    if(!iso)return 'no expiry';
    var ms=new Date(iso)-Date.now();
    if(ms<=0)return 'expired';
    var h=Math.round(ms/3600e3);
    return h<48?('expires in '+h+' h'):('expires in '+Math.round(h/24)+' d');
  }
  function setVis(p,exp){
    pub=p||null;expires=exp||null;
    $('vis').className='vis'+(pub?' pub':'');
    // when public, the chip and the bar both carry the URL - the link you
    // send should never be hidden behind a panel
    $('vis').innerHTML=pub
      ? '<a href="'+esc(pub)+'" target="_blank">public \u2197</a>'
      : 'private \u00b7 tailnet';
    $('puburl').innerHTML=pub?'<a href="'+esc(pub)+'" target="_blank">'+esc(pub)+'</a>':'';
    $('visbtn').textContent=pub?'make private':'share publicly';
    $('copybtn').textContent=pub?'copy public link':'copy link';
    $('exp').textContent=pub?human(expires):'';
    $('ttl').style.display=pub?'none':'';
  }
  function setHist(items){
    var h=$('fbhist');
    if(!items||!items.length){h.style.display='none';h.innerHTML='';return}
    h.style.display='';
    h.innerHTML='your feedback on this page:'+items.map(function(i){
      var t=new Date(i.ts).toLocaleString();
      return '<div class="it"><span class="'+(i.delivered?'ok':'no')+'">'+
        esc(i.delivered?'delivered to '+i.pane:'queued (publisher gone)')+'</span> · '+esc(t)+'</div>';
    }).join('');
  }
  function tl(when,cls,tag,what,link){
    return '<div class="ev '+esc(cls)+'"><span class="when">'+esc(when)+'</span>'+
      '<span class="what"><span class="tag">'+esc(tag)+'</span> '+esc(what)+'</span>'+
      (link?'<a href="'+esc(link)+'" target="_blank">view ↗</a>':'')+'</div>';
  }
  function setTimeline(revs,fb){
    var evs=[];
    (revs||[]).forEach(function(r){
      evs.push({ts:r.ts,html:tl(new Date(r.ts).toLocaleString(),'pubv',
        r.rev?'revised':'published',
        (r.bytes?Math.round(r.bytes/1024*10)/10+' kB':'')+(r.pane?' · by '+r.pane:''),
        r.rev?'/'+encodeURIComponent(doc)+'?rev='+encodeURIComponent(r.rev):null)});
    });
    (fb||[]).forEach(function(f){
      var body=(f.quote?'\u201c'+f.quote.slice(0,80)+'\u201d - ':'')+f.message;
      evs.push({ts:f.ts,html:tl(new Date(f.ts).toLocaleString(),'fb','feedback',
        body+(f.delivered?' · delivered to '+f.pane:' · queued'),null)});
    });
    evs.sort(function(a,b){return new Date(b.ts)-new Date(a.ts)});
    $('timeline').innerHTML=evs.length?evs.map(function(e){return e.html}).join('')
      :'<div class="ev"><span class="what">nothing recorded yet</span></div>';
  }
  function load(){fetch(location.origin+'/api/doc?name='+encodeURIComponent(doc))
    .then(function(r){return r.json()}).then(function(j){
      setVis(j.public,j.expires);setHist(j.feedback);setTimeline(j.revisions,j.feedback)})
    .catch(function(){$('vis').textContent='state unknown'})}
  load();

  $('visbtn').onclick=async function(){
    var was=pub, ttl=Number($('ttl').value);
    if(!was&&!confirm('Publish "'+doc+'" to the open internet?\\n\\n'+
      'Anyone with the link can read it'+(ttl?' for the next '+(ttl<48?ttl+' hours':Math.round(ttl/24)+' days'):', with no expiry')+
      '.\\nThe link is unguessable and stops working when you revoke it.'))return;
    var r=await fetch(location.origin+(was?'/api/revoke':'/api/promote'),{method:'POST',
      headers:{'content-type':'application/json','x-cel-csrf':csrf},body:JSON.stringify({doc:doc,ttlHours:ttl})});
    if(r.ok){var j=await r.json();setVis(j.public,j.expires);
      if(j.public){
        // the link is in the bar; publishing is not an invitation to comment,
        // so no panel - just put the URL on the clipboard and say so
        copy(j.public).then(function(ok){flash(ok?'public link copied':'public link ready - see the bar')});
      } else flash('made private - old link dead')}
    else flash(await r.text(),false);
  };
  function copy(text){
    if(navigator.clipboard&&window.isSecureContext)
      return navigator.clipboard.writeText(text).then(function(){return true},function(){return false});
    // http origins (a tailnet IP) have no clipboard API - fall back to a
    // throwaway textarea, and if even that is blocked the panel shows the URL
    var ta=document.createElement('textarea');ta.value=text;ta.style.position='fixed';
    ta.style.opacity='0';document.body.appendChild(ta);ta.select();
    var ok=false;try{ok=document.execCommand('copy')}catch(e){}
    document.body.removeChild(ta);return Promise.resolve(ok);
  }
  $('copybtn').onclick=function(){
    var url=pub||location.origin+'/'+encodeURIComponent(doc);
    copy(url).then(function(ok){
      flash(ok?(pub?'public link copied':'link copied'):'copy blocked - the link is in the bar',ok);
    });
  };
  $('fbbtn').onclick=function(){
    var open=$('panel').style.display==='block';
    $('histpanel').style.display='none';
    $('panel').style.display=open?'none':'block';
    if(!open)$('fbmsg').focus();
  };
  $('histbtn').onclick=function(){
    var open=$('histpanel').style.display==='block';
    $('panel').style.display='none';
    $('histpanel').style.display=open?'none':'block';
    if(!open)load();
  };
  function setQuote(q){quote=(q||'').trim().slice(0,600);
    $('quote').style.display=quote?'':'none';
    $('quotetext').textContent=quote?'\\u201c'+quote+'\\u201d':''}
  $('quotex').onclick=function(e){e.preventDefault();setQuote('')};
  $('bubblebtn').onclick=function(){setQuote($('bubble').dataset.sel);
    $('bubble').style.display='none';$('panel').style.display='block';$('fbmsg').focus()};
  $('fbsend').onclick=async function(){
    $('fbstatus').textContent='sending…';
    var r=await fetch(location.origin+'/api/feedback',{method:'POST',
      headers:{'content-type':'application/json','x-cel-csrf':csrf},
      body:JSON.stringify({doc:doc,message:$('fbmsg').value,quote:quote})});
    $('fbstatus').textContent=await r.text();
    if(r.ok){$('fbmsg').value='';setQuote('');load();
      setTimeout(function(){$('fbstatus').textContent=''},2600)}
  };

  // The document is same-origin, so the shell can watch selections inside it
  // (select-to-comment) and keep the bar in charge of in-document navigation.
  $('doc').addEventListener('load',function(){
    var w=$('doc').contentWindow,d;
    try{d=w.document}catch(e){return}
    var p=w.location.pathname.replace(/^\\//,'');
    if(p){var n=decodeURIComponent(p);if(n!==doc){doc=n;$('docname').textContent=doc;load()}}
    // keep links to other published pages inside the shell, not nested in it
    Array.prototype.forEach.call(d.querySelectorAll('a[href]'),function(a){
      try{var u=new URL(a.href,w.location.href);
        if(u.origin===location.origin&&/\\.html?$/i.test(u.pathname)&&!u.searchParams.has('raw')){
          u.searchParams.set('raw','1');a.href=u.toString()}}catch(e){}
    });
    d.addEventListener('mouseup',function(){
      setTimeout(function(){
        var s=w.getSelection(),t=s&&String(s).trim();
        if(!t||t.length<3){$('bubble').style.display='none';return}
        var r=s.getRangeAt(0).getBoundingClientRect();
        $('bubble').style.left=Math.max(8,r.left+r.width/2-60)+'px';
        $('bubble').style.top=(navH+r.bottom+8)+'px';
        $('bubble').dataset.sel=t;$('bubble').style.display='block';
      },0)});
  });
})()</script>`;


const feedback = async (req, res) => {
  let body = '';
  for await (const c of req) { body += c; if (body.length > 20000) { res.writeHead(413).end('too long'); return; } }
  const { doc, message, quote } = JSON.parse(body || '{}');
  const name = String(doc || '').split('/').pop();
  const msg = String(message || '').trim().slice(0, 4000);
  const q = String(quote || '').trim().slice(0, 600);
  if (!name || !msg) { res.writeHead(400).end('doc and message required'); return; }
  let meta = null;
  try { meta = JSON.parse(readFileSync(join(ROOT, '.meta', `${name}.json`), 'utf8')); } catch { /* unpublished or pre-meta doc */ }
  // The prompt has to say what to DO with the feedback, or the agent reads a
  // remark and moves on - the reader then sees nothing change and reasonably
  // concludes the loop is broken.
  const text = (q
    ? `Feedback from the reader on your published page "${name}", about this passage: "${q}" - ${msg}`
    : `Feedback from the reader on your published page "${name}": ${msg}`)
    + `. Act on it now: revise the document and republish it under the SAME name`
    + ` (cel publish <file> ${name}) so the reader's page updates, then say what you changed.`
    + ` If you disagree or need more from them, say so in your reply instead of silently dropping it.`;
  const routed = meta?.pane && await new Promise((ok) =>
    execFile('herdr', ['agent', 'prompt', meta.pane, text], { timeout: 15000 }, (err) => ok(!err)));
  // EVERY item is logged, delivered or not: "did my feedback get through?"
  // must have an answer on disk, and the reader's panel reads this back.
  mkdirSync(join(ROOT, '.meta'), { recursive: true });
  appendFileSync(join(ROOT, '.meta', 'feedback.log'),
    JSON.stringify({ ts: new Date().toISOString(), doc: name, pane: meta?.pane || null,
                     delivered: !!routed, quote: q || null, message: msg }) + '\n');
  if (routed) { res.writeHead(200).end(`sent to ${meta.pane}`); return; }
  res.writeHead(200).end(meta?.pane
    ? `publisher pane ${meta.pane} is gone - queued for the steward`
    : 'no publishing agent recorded - queued for the steward');
};

// Archived revisions of a document, newest first: the .versions snapshots
// cel publish took before each overwrite, plus what revisions.log recorded
// about who published and when.
const revisionHistory = (name) => {
  const logf = join(ROOT, '.meta', 'revisions.log');
  const logged = existsSync(logf)
    ? readFileSync(logf, 'utf8').split('\n').filter(Boolean)
        .map((l) => { try { return JSON.parse(l); } catch { return null; } })
        .filter((x) => x && x.doc === name)
    : [];
  const dir = join(ROOT, '.versions', name);
  const snaps = existsSync(dir)
    ? readdirSync(dir).map((f) => ({ rev: f, ts: new Date(Number(f.split('.')[0]) * 1000).toISOString() }))
    : [];
  // Each snapshot is a SUPERSEDED revision; the newest publish is the live
  // document and has no snapshot of its own.
  const items = snaps.map((sn) => {
    const near = logged.filter((l) => Math.abs(new Date(l.ts) - new Date(sn.ts)) < 120000)[0];
    return { ts: sn.ts, rev: sn.rev, pane: near?.pane || null, bytes: near?.bytes ?? null };
  });
  const live = logged[logged.length - 1];
  if (live) items.push({ ts: live.ts, rev: null, pane: live.pane || null, bytes: live.bytes ?? null });
  return items.sort((a, b) => new Date(b.ts) - new Date(a.ts)).slice(0, 20);
};

// What the reader sent for this document, newest first - the receipt half of
// the loop, so the panel can show "delivered to w14:pE at 09:12".
const feedbackHistory = (name) => {
  const f = join(ROOT, '.meta', 'feedback.log');
  if (!existsSync(f)) return [];
  return readFileSync(f, 'utf8').split('\n').filter(Boolean)
    .map((l) => { try { return JSON.parse(l); } catch { return null; } })
    .filter((x) => x && x.doc === name)
    .slice(-20).reverse();
};

// Promotion copies the file across roots and leaves a line in the audit log
// either way, so "what was ever public, and when" has one answer.
const cleanName = (v) => String(v || '').split('/').pop();
const audit = (entry) => {
  mkdirSync(join(ROOT, '.meta'), { recursive: true });
  appendFileSync(join(ROOT, '.meta', 'promotions.log'),
    JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n');
};
const promote = async (req, res, makePublic) => {
  let body = '';
  for await (const c of req) { body += c; if (body.length > 4000) { res.writeHead(413).end(); return; } }
  const parsed = JSON.parse(body || '{}');
  const name = cleanName(parsed.doc);
  if (!name || name.startsWith('.')) { res.writeHead(404).end('no such document'); return; }
  if (!PUBROOT) { res.writeHead(503).end('no public tier configured'); return; }

  // every existing share of this doc goes, whether we are revoking or
  // re-sharing: a re-share must not leave the old link alive
  const dropped = shareDirs(PUBROOT).filter((sh) => sh.doc === name);
  const drop = () => dropped.forEach((sh) => {
    try { rmSync(join(PUBROOT, sh.token), { recursive: true, force: true }); } catch { /* already gone */ }
  });

  if (!makePublic) {
    drop();
    try { audit({ doc: name, action: 'private', revoked: dropped.map((s2) => s2.token) }); } catch (e) {
      res.writeHead(500).end('revoked, but the audit log failed'); return;
    }
    res.writeHead(200, { 'content-type': 'application/json' }).end(JSON.stringify({ public: null, expires: null }));
    return;
  }

  // promotion needs the private source; revocation deliberately does not,
  // so a doc deleted privately can still be pulled off the internet
  if (!existsSync(join(ROOT, name))) { res.writeHead(404).end('no such document'); return; }
  const ttlH = parsed.ttlHours === 0 ? 0 : Number(parsed.ttlHours || SHARE_TTL_DEFAULT_H);
  if (!Number.isFinite(ttlH) || ttlH < 0 || ttlH > 24 * 365) { res.writeHead(400).end('bad ttlHours'); return; }
  const token = randomBytes(12).toString('hex');
  const expires = ttlH === 0 ? null : new Date(Date.now() + ttlH * 3600e3).toISOString();
  const dir = join(PUBROOT, token);
  mkdirSync(dir, { recursive: true });
  copyFileSync(join(ROOT, name), join(dir, name));
  writeFileSync(join(dir, '.share.json'),
    JSON.stringify({ doc: name, created: new Date().toISOString(), expires }));
  try { audit({ doc: name, action: 'public', token, expires, replaced: dropped.map((s2) => s2.token) }); }
  catch (e) {
    // unaudited public exposure is worse than a failed click
    try { rmSync(dir, { recursive: true, force: true }); } catch { /* already gone */ }
    res.writeHead(500).end('audit log failed - publication rolled back'); return;
  }
  drop();
  res.writeHead(200, { 'content-type': 'application/json' })
    .end(JSON.stringify({ public: `${PUBURL}/${token}/${encodeURIComponent(name)}`, expires }));
};

const server = createServer(async (req, res) => {
  try {
    if (security && !security.allow(req, res)) return;
    if (security && req.method === 'GET' && req.url === '/api/session') {
      security.session(req, res);
      return;
    }
    if (FEEDBACK && req.method === 'POST' && req.url === '/api/feedback') {
      await feedback(req, res);
      return;
    }
    if (FEEDBACK && req.method === 'POST' && (req.url === '/api/promote' || req.url === '/api/revoke')) {
      await promote(req, res, req.url === '/api/promote');
      return;
    }
    if (FEEDBACK && req.method === 'GET' && req.url.startsWith('/api/doc?')) {
      const name = cleanName(new URL(req.url, 'http://x').searchParams.get('name'));
      const sh = (PUBROOT && name && !name.startsWith('.')) ? shareFor(PUBROOT, name) : null;
      const body = JSON.stringify({ public: sh ? `${PUBURL}/${sh.token}/${encodeURIComponent(name)}` : null,
        expires: sh ? sh.expires : null,
        feedback: name ? feedbackHistory(name) : [],
        revisions: name ? revisionHistory(name) : [] });
      res.writeHead(200, { 'content-type': 'application/json' }).end(body);
      return;
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') { res.writeHead(405).end(); return; }
    const url = new URL(req.url, 'http://x');
    const path = decodeURIComponent(url.pathname);
    if (path === '/') {
      if (!FEEDBACK) {
        // no directory listing on the internet-facing tier
        res.writeHead(200, { 'content-type': 'text/plain; charset=utf-8' }).end('celestial pages\n');
        return;
      }
      const body = req.method === 'HEAD' ? undefined : index();
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }).end(body);
      return;
    }
    // PUBLIC TIER: the only readable shape is /<token>/<doc>, and only while
    // the share is live. Flat names are refused outright - a guessable name
    // on an internet-reachable host is the hole tokens exist to close.
    if (!FEEDBACK) {
      const parts = normalize(path).replace(/^[/\\]+/, '').split('/');
      if (parts.length !== 2 || !TOKEN_RE.test(parts[0])) { res.writeHead(404).end('not found'); return; }
      const [token, doc] = parts;
      if (!doc || doc.startsWith('.')) { res.writeHead(404).end('not found'); return; }
      let manifest = null;
      try { manifest = JSON.parse(readFileSync(join(ROOT, token, '.share.json'), 'utf8')); } catch { /* no manifest */ }
      if (!manifest || manifest.doc !== doc) { res.writeHead(404).end('not found'); return; }
      if (shareExpired(manifest)) {
        res.writeHead(410, { 'content-type': 'text/plain; charset=utf-8' })
          .end('this share link has expired');
        return;
      }
      const pf = join(ROOT, token, doc);
      if (!existsSync(pf)) { res.writeHead(404).end('not found'); return; }
      const body = req.method === 'HEAD' ? undefined : readFileSync(pf);
      res.writeHead(200, {
        'content-type': MIME[extname(doc).toLowerCase()] || 'application/octet-stream',
        'cache-control': 'no-store', 'x-robots-tag': 'noindex, nofollow',
      }).end(body);
      return;
    }
    // one flat directory: strip to the basename so traversal cannot escape
    const name = normalize(path).replace(/^[/\\]+/, '');
    const file = join(ROOT, name);
    if (name.includes('/') || name.includes('\\') || name.startsWith('.') || !existsSync(file)) {
      res.writeHead(404, { 'content-type': 'text/plain' }).end('not found');
      return;
    }
    const type = MIME[extname(name).toLowerCase()] || 'application/octet-stream';
    // An archived revision, read-only: ids are the snapshot filenames cel
    // publish wrote (<epoch>.<ext>), validated so nothing escapes .versions.
    const rev = FEEDBACK ? url.searchParams.get('rev') : null;
    if (rev) {
      if (!/^[0-9]+\.[A-Za-z0-9]+$/.test(rev)) { res.writeHead(400).end('bad revision id'); return; }
      const rf = join(ROOT, '.versions', name, rev);
      if (!existsSync(rf)) { res.writeHead(404).end('no such revision'); return; }
      const body = req.method === 'HEAD' ? undefined : readFileSync(rf);
      res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' }).end(body);
      return;
    }
    // HTML on the private tier arrives wrapped in the chrome shell unless the
    // caller asked for the document itself (the shell's own iframe does).
    if (FEEDBACK && type.startsWith('text/html') && !url.searchParams.has('raw')) {
      const body = req.method === 'HEAD' ? undefined : chrome(name);
      res.writeHead(200, { 'content-type': 'text/html; charset=utf-8', 'cache-control': 'no-store' }).end(body);
      return;
    }
    const body = req.method === 'HEAD' ? undefined : readFileSync(file);
    res.writeHead(200, { 'content-type': type, 'cache-control': 'no-store' }).end(body);
  } catch (e) {
    internalError(res);
  }
});

server.listen(PORT, HOST, () => console.log(`cel pages: ${ROOT} on http://${HOST}:${PORT}`));
