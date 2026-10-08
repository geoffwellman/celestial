// CEL-106: drive dashboard v2 in a real headless browser against fixture feeds.
//
//   node dash-v2-browser.mjs <base-url> <fixture-dir> <scenario> [shot-dir]
//
// The page is served by the real dash server; every /api/ request it makes is
// answered here from <fixture-dir>/<name>.json over Chrome's DevTools Fetch
// domain, and recorded. Nothing reaches a real inbox, decision or orchestrator:
// a POST is logged and answered 200, never forwarded. Prints one JSON object
// per scenario with what the page did and what it sent.
import { readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { findChrome, launchChrome } from './dash-browser.mjs';

const [base, fixDir, scenario, shotDir] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const connect = async (port) => {
  const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
  const page = targets.find((t) => t.type === 'page');
  const ws = new WebSocket(page.webSocketDebuggerUrl);
  await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
  let seq = 0; const waiting = new Map(); const handlers = [];
  ws.onmessage = (m) => {
    const d = JSON.parse(m.data);
    if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); }
    else if (d.method) handlers.forEach((h) => h(d));
  };
  const send = (method, params = {}) => new Promise((r) => { const id = ++seq; waiting.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
  return { ws, send, on: (h) => handlers.push(h) };
};

const main = async () => {
  const bin = findChrome();
  if (!bin) { console.log(JSON.stringify({ skip: 'no headless chrome on this box' })); return; }
  const { chrome, prof, port } = await launchChrome(bin, ['--window-size=1400,1000']);
  const sent = [];
  try {
    const { ws, send, on } = await connect(port);
    const missing = (process.env.V2_MISSING || '').split(',');
    const fixture = (name) => { if (missing.includes(name)) return null; try { return readFileSync(join(fixDir, name + '.json'), 'utf8'); } catch { return null; } };
    on(async (ev) => {
      if (ev.method !== 'Fetch.requestPaused') return;
      const { requestId, request } = ev.params;
      const u = new URL(request.url);
      let body = '{}', code = 200;
      if (request.method === 'POST') {
        let pb = null; try { pb = JSON.parse(request.postData || 'null'); } catch { /* raw */ }
        sent.push({ path: u.pathname, body: pb, csrf: !!(request.headers['x-cel-csrf'] || request.headers['X-Cel-Csrf']) });
        body = u.pathname === '/api/decide' ? 'ok' : '{"ok":true}';
      } else {
        sent.push({ path: u.pathname, query: u.search });
        const name = u.pathname === '/api/state' ? 'state' : u.pathname.replace(/^\/api\/v2\//, '');
        const f = fixture(name);
        if (f === null) code = 404; else body = f;
      }
      await send('Fetch.fulfillRequest', { requestId, responseCode: code,
        responseHeaders: [{ name: 'content-type', value: 'application/json' }],
        body: Buffer.from(body).toString('base64') });
    });
    await send('Fetch.enable', { patterns: [{ urlPattern: '*/api/*', requestStage: 'Request' }] });
    await send('Page.enable');
    await send('Runtime.enable');
    const evaluate = async (expr) => {
      const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
      if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 600));
      return r.result.result.value;
    };
    const until = async (expr, ms = 15000) => {
      const t0 = Date.now();
      while (Date.now() - t0 < ms) { if (await evaluate(`!!(${expr})`)) return true; await sleep(100); }
      return false;
    };
    const load = async () => {
      await send('Page.navigate', { url: base + '/' });
      await sleep(300);
      return until(`window.V2READY && document.querySelector('#needsyou .nycard')`);
    };
    const key = async (k, mods = 0) => {
      const code = k.length === 1 ? 'Key' + k.toUpperCase() : k;
      const kc = { Enter: 13, Escape: 27 }[k] || k.toUpperCase().charCodeAt(0);
      for (const type of ['keyDown', 'keyUp']) {
        await send('Input.dispatchKeyEvent', { type, key: k, code, modifiers: mods, windowsVirtualKeyCode: kc,
          ...(type === 'keyDown' && k.length === 1 && !mods ? { text: k } : {}) });
      }
    };
    const shot = async (name, width) => {
      if (!shotDir) return;
      await send('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: width < 600 });
      await sleep(600);
      const h = await evaluate('document.documentElement.scrollHeight');
      await send('Emulation.setDeviceMetricsOverride', { width, height: Math.min(h, 6000), deviceScaleFactor: 1, mobile: width < 600 });
      await sleep(400);
      const r = await send('Page.captureScreenshot', { format: 'png' });
      writeFileSync(join(shotDir, name), Buffer.from(r.result.data, 'base64'));
      await send('Emulation.clearDeviceMetricsOverride');
    };
    const out = { loaded: await load() };
    const posts = (p) => sent.filter((s) => s.body !== undefined && s.path === p);

    if (scenario === 'filter') {
      // every card's body, and the ws tags it shows, before and after "bundle"
      const snap = `(function(){var o={};document.querySelectorAll('#grid .w').forEach(function(c){
        o[c.dataset.id]={html:c.innerHTML,ws:[].slice.call(c.querySelectorAll('[data-ws]')).map(function(e){return e.dataset.ws})}});
        o._composer=[].slice.call(document.querySelectorAll('#to .chip[data-ws]')).map(function(e){return e.dataset.ws});return o})()`;
      const before = await evaluate(snap);
      await evaluate(`(function(){var s=document.getElementById('wsf');s.value='bundle';s.dispatchEvent(new Event('change',{bubbles:true}));return 1})()`);
      await sleep(1500);
      const after = await evaluate(snap);
      out.cards = Object.keys(before).filter((k) => k !== '_composer').length;
      out.unchanged = Object.keys(before).filter((k) => k !== '_composer' && before[k].html === (after[k] || {}).html);
      out.alphaAfter = Object.keys(after).filter((k) => (after[k].ws || after[k]).some((w) => w === 'alpha'));
      out.alphaBefore = Object.keys(before).filter((k) => k !== '_composer' && before[k].ws.includes('alpha')).length;
      out.feedsAskedForBundle = sent.filter((s) => /^\/api\/v2\//.test(s.path) && /ws=bundle/.test(s.query || '')).length;
      // the palette respects the filter too
      await key('k', 2);
      await evaluate(`(function(){var q=document.getElementById('pq');q.value='widget';q.dispatchEvent(new Event('input'));return 1})()`);
      out.paletteAlpha = await evaluate(`[].slice.call(document.querySelectorAll('#pres .pr[data-ws]')).filter(function(e){return e.dataset.ws==='alpha'}).length`);
    }

    if (scenario === 'layout') {
      const order = () => evaluate(`[].slice.call(document.querySelectorAll('#grid .w')).map(function(e){return e.dataset.id}).join(',')`);
      out.orderBefore = await order();
      // drag "activity" onto "since" the way a mouse does: the same events
      await evaluate(`(function(){
        var a=document.querySelector('#grid .w[data-id=activity] .grip'),b=document.querySelector('#grid .w[data-id=since] h3');
        var dt=new DataTransfer();
        a.dispatchEvent(new DragEvent('dragstart',{bubbles:true,dataTransfer:dt}));
        b.dispatchEvent(new DragEvent('dragover',{bubbles:true,cancelable:true,dataTransfer:dt}));
        b.dispatchEvent(new DragEvent('drop',{bubbles:true,cancelable:true,dataTransfer:dt}));
        a.dispatchEvent(new DragEvent('dragend',{bubbles:true,dataTransfer:dt}));
        return 1})()`);
      out.orderDragged = await order();
      // Customize: make "prs" full width and "box" tall, hide "heat"
      await evaluate(`(function(){
        document.getElementById('cust').click();
        function size(id,v){var s=document.querySelector('#grid .w[data-id='+id+'] select.size');s.value=v;s.dispatchEvent(new Event('change',{bubbles:true}))}
        size('prs','full');size('box','tall');
        document.querySelector('#grid .w[data-id=heat] .x').click();
        document.getElementById('cust').click();return 1})()`);
      await load();
      out.orderAfterReload = await order();
      out.prsClass = await evaluate(`document.querySelector('#grid .w[data-id=prs]').className`);
      out.boxClass = await evaluate(`document.querySelector('#grid .w[data-id=box]').className`);
      out.heatShown = await evaluate(`!!document.querySelector('#grid .w[data-id=heat]')`);
      await evaluate(`document.getElementById('cust').click()`);
      out.heatInCustomize = await evaluate(`!!document.querySelector('#grid .w[data-id=heat]')`);
    }

    if (scenario === 'decide') {
      const id = '1759800000000000002';
      const card = `document.querySelector('#needsyou .nycard[data-id="${id}"]')`;
      await evaluate(`${card}.querySelector('.nyhead').click()`);
      out.opened = await evaluate(`${card}.classList.contains('open')`);
      await evaluate(`${card}.querySelector('button.opt[data-n="1"]').click()`);
      out.afterOne = posts('/api/decide').length;
      out.armed = await evaluate(`!!${card}.querySelector('button.opt.armed')`);
      await evaluate(`${card}.querySelector('button.opt[data-n="1"]').click()`);
      await until(`!${card}`, 5000);
      out.decides = posts('/api/decide').map((s) => s.body);
      out.csrf = posts('/api/decide').every((s) => s.csrf);
      out.gone = await evaluate(`!${card}`);
    }

    if (scenario === 'composer') {
      await evaluate(`document.querySelector('#to .chip[data-o="bundle-orch"]').click()`);
      await evaluate(`(function(){var t=document.getElementById('task');t.value='add a gadget beta toggle';t.dispatchEvent(new Event('input'));return 1})()`);
      await evaluate(`document.getElementById('go').click()`);
      await until(`document.querySelector('#thread .sentmsg')`, 5000);
      await evaluate(`document.querySelector('#to .chip[data-o="celestial-orch"]').click()`);
      await evaluate(`(function(){var t=document.getElementById('task');t.value='where is the widget release?';t.dispatchEvent(new Event('input'));
        document.querySelector('.ctabs [data-k=ask]').click();return 1})()`);
      await evaluate(`document.getElementById('go').click()`);
      await sleep(800);
      out.acts = posts('/api/v2/act').map((s) => s.body);
      out.anyLabel = await evaluate(`document.querySelector('#to .chip[data-o="celestial-orch"]').textContent`);
      out.thread = await evaluate(`document.getElementById('thread').textContent`);
    }

    if (scenario === 'refresh') {
      // what an owner leaves half-done: typed composer text, an open drawer
      // with a typed message, an open decision with typed free text, an armed
      // button - then two refreshes
      await evaluate(`(function(){
        var t=document.getElementById('task');t.focus();t.value='half a thought';t.setSelectionRange(4,4);
        var c=document.querySelector('#needsyou .nycard[data-id="1759800000000000003"]');
        c.querySelector('.nyhead').click();
        c=document.querySelector('#needsyou .nycard[data-id="1759800000000000003"]');
        c.querySelector('details.other').open=true;
        var f=c.querySelector('.free');f.value='keep it as is';
        c.querySelector('button.accept').click();
        document.querySelector('#grid .w[data-id=working] [data-agent]').click();
        document.getElementById('dmsg').value='status please';
        t.focus();t.setSelectionRange(4,4);return 1})()`);
      const u0 = await evaluate(`document.getElementById('updated').textContent`);
      await evaluate(`window.v2refresh(true)`);
      await evaluate(`window.v2refresh(true)`);
      out.refreshed = (await evaluate(`document.getElementById('updated').textContent`)) !== u0 || (await evaluate('window.V2REFRESHES')) >= 3;
      out.state = await evaluate(`(function(){
        var c=document.querySelector('#needsyou .nycard[data-id="1759800000000000003"]'),t=document.getElementById('task');
        return {task:t.value,focused:document.activeElement===t,caret:t.selectionStart,
          open:!!(c&&c.classList.contains('open')),other:!!(c&&c.querySelector('details.other').open),
          free:c?c.querySelector('.free').value:null,armed:!!(c&&c.querySelector('button.accept.armed')),
          drawer:document.getElementById('drawer').classList.contains('open'),dmsg:document.getElementById('dmsg').value}})()`);
    }

    if (scenario === 'palette') {
      await key('k', 2);
      out.paletteOpen = await evaluate(`document.getElementById('pal').classList.contains('open')`);
      await evaluate(`(function(){var q=document.getElementById('pq');q.value='gadget beta now';q.dispatchEvent(new Event('input'));return 1})()`);
      out.first = await evaluate(`(document.querySelector('#pres .pr.on')||{}).textContent||''`);
      await key('Enter');
      await sleep(400);
      out.paletteClosed = !(await evaluate(`document.getElementById('pal').classList.contains('open')`));
      out.decisionOpen = await evaluate(`!!document.querySelector('#needsyou .nycard.open[data-id="1759800000000000002"]')`);
      out.optionsShown = await evaluate(`(function(){var o=document.querySelector('#needsyou .nycard[data-id="1759800000000000002"] .nyopts');return !!o&&o.offsetParent!==null})()`);
      // an action asks twice before it runs
      await key('k', 2);
      await evaluate(`(function(){var q=document.getElementById('pq');q.value='go away';q.dispatchEvent(new Event('input'));return 1})()`);
      await key('Enter');
      out.actsAfterOneEnter = posts('/api/v2/act').length;
      await key('Enter');
      await sleep(400);
      out.actsAfterTwo = posts('/api/v2/act').map((s) => s.body.action);
    }

    if (scenario === 'expand') {
      await evaluate(`document.querySelector('#grid .w[data-id=activity] .ex').click()`);
      await sleep(300);
      out.open = await evaluate(`document.getElementById('ov').classList.contains('open')`);
      out.title = await evaluate(`document.getElementById('ovt').textContent`);
      out.search = await evaluate(`!!document.querySelector('#ovb input.actq')`);
      await evaluate(`(function(){var q=document.querySelector('#ovb input.actq');q.value='widget';q.dispatchEvent(new Event('input'));return 1})()`);
      out.matches = await evaluate(`document.querySelectorAll('#ovb .feed .row').length`);
      await key('Escape');
      await sleep(200);
      out.closed = !(await evaluate(`document.getElementById('ov').classList.contains('open')`));
      await evaluate(`document.querySelector('#grid .w[data-id=needs] .ex').click()`);
      await sleep(300);
      out.needsInOverlay = await evaluate(`!!document.querySelector('#ovb #needsyou .nycard')`);
      out.bulk = await evaluate(`!!document.querySelector('#ovb #needsyou button.bulk')`);
      await key('Escape');
      await sleep(200);
      out.needsBack = await evaluate(`!!document.querySelector('#grid .w[data-id=needs] #needsyou .nycard')`);
      await evaluate(`document.querySelector('#grid .w[data-id=lanes] .ex').click()`);
      await sleep(300);
      out.lanesRange = await evaluate(`!!document.querySelector('#ovb select.range')`);
      await key('Escape');
    }

    if (scenario === 'working') {
      // Working now is for panes that need watching: working or blocked
      out.working = await evaluate(`[].slice.call(document.querySelectorAll('#grid .w[data-id=working] [data-agent]')).map(function(e){return e.dataset.agent}).join(',')`);
    }

    if (scenario === 'missing') {
      // one feed answers 404: its card says so and the others still draw
      const body = (id) => evaluate(`(document.querySelector('#grid .w[data-id=${id}] .body')||{}).textContent||''`);
      out.heat = await body('heat');
      out.cycle = await body('cycle');
      out.activity = await body('activity');
    }

    if (scenario === 'shots') {
      await shot('v2-1400.png', 1400);
      await shot('v2-390.png', 390);
      out.shots = true;
    }
    out.errors = await evaluate('window.V2ERRORS||[]');
    console.log(JSON.stringify(out));
    ws.close();
  } finally {
    chrome.kill('SIGKILL');
    const { rmSync } = await import('node:fs');
    rmSync(prof, { recursive: true, force: true });
  }
};

main().catch((e) => { console.error(e.stack || String(e)); process.exit(1); });
