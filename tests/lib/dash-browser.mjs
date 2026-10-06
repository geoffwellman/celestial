// CEL-101: drive the dashboard's decisions panel in a real headless browser.
//
// The owner opened "other…", started typing, and lost the text a few seconds
// later when the 8 s refresh rebuilt the panel. Only a browser shows that: a
// curl of the page cannot type, focus or wait for a timer. No test dependency
// is installed for this - Chrome is driven over its DevTools protocol with
// node's own fetch and WebSocket.
//
//   node dash-browser.mjs <url> <keep-id> <gone-id> <mutate-cmd> <wait-ms> <shot-dir>
//
// Opens both cards' "other…", types into each, opens the bulk preview, arms
// <keep-id>'s accept button, runs <mutate-cmd> (which files a new decision and
// answers <gone-id> elsewhere), waits for the repaint and two more refreshes
// plus <wait-ms>, and prints what survived as JSON. Screenshots before.png /
// after.png land in <shot-dir>.
import { spawn, exec, execSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';

const [url, keepId, goneId, mutate, waitMs, shotDir] = process.argv.slice(2);

export const findChrome = () => {
  const c = [process.env.CEL_TEST_CHROME];
  // puppeteer's own download (omp keeps one), newest first
  const pp = join(homedir(), '.omp/puppeteer/chrome');
  if (existsSync(pp)) for (const d of readdirSync(pp).sort().reverse()) c.push(join(pp, d, 'chrome-linux64/chrome'));
  const pw = join(homedir(), '.cache/ms-playwright');
  if (existsSync(pw)) {
    for (const d of readdirSync(pw).sort().reverse()) {
      c.push(join(pw, d, 'chrome-linux/headless_shell'), join(pw, d, 'chrome-headless-shell-linux64/chrome-headless-shell'),
        join(pw, d, 'chrome-linux64/chrome'), join(pw, d, 'chrome-linux/chrome'));
    }
  }
  for (const n of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser']) {
    try { c.push(execSync(`command -v ${n}`, { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim()); } catch { /* absent */ }
  }
  return c.find((p) => p && existsSync(p)) || '';
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

// CEL-102: under the parallel runner Chrome can take well over 10 s to write
// DevToolsActivePort. Wait a generous, bounded time (CEL_TEST_CHROME_WAIT_MS,
// default 60 s), retry the launch once, and on failure show Chrome's stderr.
export const chromeWaitMs = () => Number(process.env.CEL_TEST_CHROME_WAIT_MS) || 60000;

export const launchChrome = async (bin, extra = [], { waitMs = chromeWaitMs(), tries = 2 } = {}) => {
  const tails = [];
  for (let attempt = 1; attempt <= tries; attempt++) {
    const prof = mkdtempSync(join(tmpdir(), 'cel-chrome-'));
    const chrome = spawn(bin, ['--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0',
      `--user-data-dir=${prof}`, ...extra, 'about:blank'], { stdio: ['ignore', 'ignore', 'pipe'] });
    let err = '';
    chrome.stderr.on('data', (d) => { err = (err + d).slice(-4000); });
    let exited = false;
    chrome.on('exit', () => { exited = true; });
    chrome.on('error', (e) => { err += String(e); exited = true; });
    let port = '';
    const t0 = Date.now();
    while (!port && !exited && Date.now() - t0 < waitMs) {
      await sleep(100);
      try { port = readFileSync(join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch { /* not yet */ }
    }
    if (port) return { chrome, prof, port };
    chrome.kill('SIGKILL');
    rmSync(prof, { recursive: true, force: true });
    tails.push(`attempt ${attempt} (${Date.now() - t0} ms):\n${err.split('\n').slice(-20).join('\n')}`);
  }
  throw new Error(`chrome never opened its debugging port (waited ${waitMs} ms x${tries})\n--- chrome stderr tail ---\n${tails.join('\n')}`);
};

const main = async () => {
  const bin = findChrome();
  if (!bin) { console.log(JSON.stringify({ skip: 'no headless chrome on this box' })); return; }
  const { chrome, prof, port } = await launchChrome(bin, ['--window-size=1200,1400']);
  try {
    const targets = await (await fetch(`http://127.0.0.1:${port}/json/list`)).json();
    const page = targets.find((t) => t.type === 'page');
    const ws = new WebSocket(page.webSocketDebuggerUrl);
    await new Promise((r, j) => { ws.onopen = r; ws.onerror = j; });
    let seq = 0; const waiting = new Map();
    ws.onmessage = (m) => { const d = JSON.parse(m.data); if (d.id && waiting.has(d.id)) { waiting.get(d.id)(d); waiting.delete(d.id); } };
    const send = (method, params = {}) => new Promise((r) => { const id = ++seq; waiting.set(id, r); ws.send(JSON.stringify({ id, method, params })); });
    const evaluate = async (expr) => {
      const r = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
      if (r.result.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
      return r.result.result.value;
    };
    const shot = async (name) => {
      const r = await send('Page.captureScreenshot', { format: 'png' });
      writeFileSync(join(shotDir, name), Buffer.from(r.result.data, 'base64'));
    };
    await send('Page.enable');
    await send('Page.navigate', { url });
    const sel = (id) => `document.querySelector('.nycard[data-id="${id}"]')`;
    for (let i = 0; i < 100; i++) {
      if (await evaluate(`!!(${sel(keepId)} && ${sel(goneId)})`)) break;
      await sleep(100);
    }
    // what an owner does: open both "other…", type, leave the caret mid-word,
    // arm a button, open the bulk preview
    await evaluate(`(function(){
      var k=${sel(keepId)},g=${sel(goneId)};
      g.querySelector('details.other').open=true;
      var gi=g.querySelector('.free');gi.focus();gi.value='typing on two';gi.dispatchEvent(new Event('input',{bubbles:true}));
      document.querySelector('button.bulk').click();
      k=${sel(keepId)};
      k.querySelector('details.other').open=true;
      var ki=k.querySelector('.free');ki.focus();ki.value='half a thought';ki.dispatchEvent(new Event('input',{bubbles:true}));
      ki.setSelectionRange(4,4);
      return true})()`);
    await shot('before.png');
    // armed just before the data changes: it lasts 4 s by design
    await evaluate(`(function(){var a=document.activeElement;${sel(keepId)}.querySelector('button.accept').click();a.focus();a.setSelectionRange(4,4);return 1})()`);
    const sig0 = await evaluate(`document.getElementById('needsyou').dataset.sig`);
    const upd = () => evaluate(`document.getElementById('updated').textContent`);
    const done = new Promise((r) => exec(mutate, { shell: '/bin/bash' }, r));
    // the repaint the bug lived in: the panel's data changed and it redrew
    let armedAfterRepaint = false, repaintMs = -1;
    const armedAt = Date.now();
    const isArmed = () => evaluate(`!!document.querySelector('.nycard[data-id="${keepId}"] button.accept.armed')`);
    const t0 = Date.now();
    while (Date.now() - t0 < 20000) {
      if (await evaluate(`document.getElementById('needsyou').dataset.sig`) !== sig0) {
        repaintMs = Date.now() - t0;
        armedAfterRepaint = await isArmed();
        break;
      }
      await sleep(50);
    }
    // then past two more refreshes, however slow this box makes them. The
    // armed button is checked at each one while its 4 s window is still open:
    // a later refresh that disarmed it must fail, not hide behind the first.
    let refreshes = 0, armedChecks = 0;
    for (let last = await upd(); refreshes < 2 && Date.now() - t0 < 40000;) {
      await sleep(50);
      const u = await upd();
      if (u !== last) {
        refreshes++; last = u;
        if (Date.now() - armedAt < 3500) { armedChecks++; if (!(await isArmed())) armedAfterRepaint = false; }
      }
    }
    await done;
    await sleep(Number(waitMs));
    await shot('after.png');
    const out = await evaluate(`(function(){
      var k=${sel(keepId)},g=${sel(goneId)},a=document.activeElement;
      return {
        keepOpen: !!(k && k.querySelector('details.other').open),
        keepText: k ? k.querySelector('.free').value : null,
        focused: !!(k && a === k.querySelector('.free')),
        caret: a && a.selectionStart,
        armed: ${armedAfterRepaint}, repaintMs: ${repaintMs}, refreshes: ${refreshes}, armedChecks: ${armedChecks},
        bulkOpen: !!document.querySelector('.nybulk'),
        cards: document.querySelectorAll('.nycard').length,
        goneShown: !!g,
        goneText: g ? g.querySelector('.free').value : null,
        goneClosed: !!(g && /closed elsewhere/.test(g.textContent)),
        updated: document.getElementById('updated').textContent
      }})()`);
    // and the quick close is wired: two clicks on "already done" send it
    out.closeClicked = await evaluate(`(async function(){
      var c=${sel(keepId)};c.querySelector('details.other').open=true;
      var b=c.querySelector('button.close[data-why="already done"]');b.click();
      b=${sel(keepId)}.querySelector('button.close[data-why="already done"]');b.click();
      for(var i=0;i<100&&${sel(keepId)};i++)await new Promise(function(r){setTimeout(r,100)});
      return !${sel(keepId)}})()`);
    console.log(JSON.stringify(out));
    ws.close();
  } finally {
    chrome.kill('SIGKILL');
    rmSync(prof, { recursive: true, force: true });
  }
};

if (url) main().catch((e) => { console.error(e.stack || String(e)); process.exit(1); });
