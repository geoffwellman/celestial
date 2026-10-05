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
// Opens both cards' "other…", types into each, arms <keep-id>'s accept button,
// opens the bulk preview, runs <mutate-cmd> (which files a new decision and
// answers <gone-id> elsewhere), waits <wait-ms>, and prints what survived as
// JSON. Screenshots before.png / after.png land in <shot-dir>.
import { spawn, execSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir, homedir } from 'node:os';
import { join } from 'node:path';

const [url, keepId, goneId, mutate, waitMs, shotDir] = process.argv.slice(2);

export const findChrome = () => {
  const c = [process.env.CEL_TEST_CHROME];
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

const main = async () => {
  const bin = findChrome();
  if (!bin) { console.log(JSON.stringify({ skip: 'no headless chrome on this box' })); return; }
  const prof = mkdtempSync(join(tmpdir(), 'cel-chrome-'));
  const chrome = spawn(bin, ['--headless', '--no-sandbox', '--disable-gpu', '--remote-debugging-port=0',
    `--user-data-dir=${prof}`, '--window-size=1200,1400', 'about:blank'], { stdio: 'ignore' });
  try {
    let port = '';
    for (let i = 0; i < 100 && !port; i++) {
      await sleep(100);
      try { port = readFileSync(join(prof, 'DevToolsActivePort'), 'utf8').split('\n')[0]; } catch { /* not yet */ }
    }
    if (!port) throw new Error('chrome never opened its debugging port');
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
      k.querySelector('button.accept').click();
      var ki=k.querySelector('.free');ki.focus();ki.value='half a thought';ki.dispatchEvent(new Event('input',{bubbles:true}));
      ki.setSelectionRange(4,4);
      return true})()`);
    await shot('before.png');
    execSync(mutate, { stdio: 'ignore', shell: '/bin/bash' });
    await sleep(Number(waitMs));
    await shot('after.png');
    const out = await evaluate(`(function(){
      var k=${sel(keepId)},g=${sel(goneId)},a=document.activeElement;
      return {
        keepOpen: !!(k && k.querySelector('details.other').open),
        keepText: k ? k.querySelector('.free').value : null,
        focused: !!(k && a === k.querySelector('.free')),
        caret: a && a.selectionStart,
        armed: !!(k && k.querySelector('button.accept.armed')),
        bulkOpen: !!document.querySelector('.nybulk'),
        cards: document.querySelectorAll('.nycard').length,
        goneShown: !!g,
        goneText: g ? g.querySelector('.free').value : null,
        goneClosed: !!(g && /closed elsewhere/.test(g.textContent))
      }})()`);
    console.log(JSON.stringify(out));
    ws.close();
  } finally {
    chrome.kill('SIGKILL');
    rmSync(prof, { recursive: true, force: true });
  }
};

if (url) main().catch((e) => { console.error(e.stack || String(e)); process.exit(1); });
