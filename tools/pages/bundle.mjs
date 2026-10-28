// A public share's BUNDLE: the exact files, besides the document itself, that
// its token may serve. A shared page that shows screenshots needs them on the
// internet too, but the public tier must never become "anything under the
// private root": the allowlist is computed once, at share time, written into
// the share's manifest as `assets`, and the files are COPIED into the token
// directory - a snapshot, like the document. The public server serves a name
// only when the manifest lists it.
//
// What goes in, from the document's own markup:
//   - every same-directory file it EMBEDS: src=, srcset=, poster=, CSS url(),
//     <link href> (stylesheets, icons)
//   - every same-directory NON-HTML file it links with <a href> (a full-size
//     screenshot, a PDF)
//   - linked HTML pages ONLY when named in `include` - another page is a
//     separate document someone chose to share or not. An included page brings
//     its own embedded files, one level; its links to further pages do not.
// "Same-directory" means a bare name or ./name: no slash, no scheme, no "..",
// no dotfile. Each candidate must be a regular file (never a symlink) in the
// private root, and an `include` naming anything else is refused outright.
import { lstatSync, readFileSync, copyFileSync, writeFileSync, readdirSync, existsSync, appendFileSync, mkdirSync } from 'node:fs';
import { join, extname } from 'node:path';

export const TOKEN_RE = /^[a-f0-9]{16,48}$/;
// every page-like type: a page goes only when named, whatever the extension
const HTML = new Set(['.html', '.htm', '.xhtml', '.shtml', '.mhtml', '.mht']);
const isPage = (n) => HTML.has(extname(n).toLowerCase());

// a reference -> a flat name in the same directory, or null
export const localName = (ref) => {
  let r = String(ref || '').trim().replace(/[?#].*$/, '');
  if (!r || /^[a-z][a-z0-9+.-]*:/i.test(r) || r.startsWith('//')) return null;
  r = r.replace(/^\.\//, '');
  try { r = decodeURIComponent(r); } catch { return null; }
  if (!r || r.includes('/') || r.includes('\\') || r.startsWith('.') || r.includes('\0')) return null;
  return r;
};

export const safeName = (n) => localName(n) === n;

const attr = (html, re) => [...html.matchAll(re)].map((m) => m[2] ?? m[3] ?? m[4]);
// what a page embeds, and what it links
export const references = (html) => {
  const q = `(?:"([^"]*)"|'([^']*)'|([^\\s>]+))`;
  const emb = [
    ...attr(html, new RegExp(`\\s(src|poster)\\s*=\\s*${q}`, 'gi')),
    ...attr(html, new RegExp(`\\s(srcset)\\s*=\\s*${q}`, 'gi')).flatMap((s) => String(s).split(',').map((p) => p.trim().split(/\s+/)[0])),
    ...[...html.matchAll(/url\(\s*(['"]?)([^'")]+)\1\s*\)/gi)].map((m) => m[2]),
    ...[...html.matchAll(/<link\b[^>]*>/gi)].flatMap((m) => attr(m[0], new RegExp(`\\s(href)\\s*=\\s*${q}`, 'gi'))),
  ];
  const links = [...html.matchAll(/<a\b[^>]*>/gi)].flatMap((m) => attr(m[0], new RegExp(`\\s(href)\\s*=\\s*${q}`, 'gi')));
  return { embeds: emb.map(localName).filter(Boolean), links: links.map(localName).filter(Boolean) };
};

const regular = (root, n) => { try { return lstatSync(join(root, n)).isFile(); } catch { return false; } };

// -> {assets:[...], missing:[...]}; throws on a bad include. `docFile` is the
// copy of the page to read references from (a live share's snapshot), when it
// is not root/doc.
export const bundleFor = (root, doc, include = [], docFile = null) => {
  const inc = [...new Set(include)];
  for (const n of inc) {
    if (!safeName(n) || !isPage(n)) throw new Error(`include '${n}' is not a page in the same directory`);
    if (!regular(root, n)) throw new Error(`include '${n}' is not a published page`);
  }
  const out = new Set(); const missing = new Set();
  const take = (n) => { if (n === doc) return; if (regular(root, n)) out.add(n); else missing.add(n); };
  // embedded or linked, a PAGE goes only when named; any other file goes
  const walk = (page, followPages, file) => {
    let html = '';
    try { html = readFileSync(file || join(root, page), 'utf8'); } catch { return; }
    const { embeds, links } = references(html);
    for (const l of [...embeds, ...links]) {
      if (!isPage(l)) take(l);
      else if (followPages && inc.includes(l) && !out.has(l)) { take(l); walk(l, false); }
    }
  };
  if (isPage(doc)) walk(doc, true, docFile);
  // an include the page does not link is still the owner's explicit choice
  for (const n of inc) if (!out.has(n) && n !== doc) { out.add(n); walk(n, false); }
  return { assets: [...out].sort(), missing: [...missing].sort() };
};

// copy a bundle into a token directory; refuses to follow or overwrite a symlink
export const copyBundle = (root, dir, assets) => {
  for (const n of assets) {
    const dst = join(dir, n);
    try { if (lstatSync(dst).isSymbolicLink()) throw new Error(`${n} in the share is a symlink`); } catch (e) { if (e.code !== 'ENOENT') throw e; }
    copyFileSync(join(root, n), dst);
  }
};

const audit = (root, entry) => {
  mkdirSync(join(root, '.meta'), { recursive: true });
  appendFileSync(join(root, '.meta', 'promotions.log'), JSON.stringify({ ts: new Date().toISOString(), ...entry }) + '\n');
};

// CLI:
//   node bundle.mjs plan  <root> <doc> [include...]          -> JSON {assets, missing}
//   node bundle.mjs copy  <root> <dir> <doc> [include...]    -> writes files + manifest.assets
//   node bundle.mjs extend <root> <pubroot> <doc> [include...]
//       the LIVE share of <doc> keeps its token, created and expires; its
//       bundle is (re)computed from the current private files and copied in.
if (import.meta.url === `file://${process.argv[1]}`) {
  const [cmd, a, b, c, ...rest] = process.argv.slice(2);
  try {
    if (cmd === 'plan') {
      console.log(JSON.stringify(bundleFor(a, b, [c, ...rest].filter(Boolean))));
    } else if (cmd === 'copy') {
      const { assets, missing } = bundleFor(a, c, rest);
      copyBundle(a, b, assets);
      const mf = join(b, '.share.json');
      const m = JSON.parse(readFileSync(mf, 'utf8'));
      writeFileSync(mf, JSON.stringify({ ...m, assets }));
      console.log(JSON.stringify({ assets, missing }));
    } else if (cmd === 'extend') {
      const [root, pub, doc] = [a, b, c];
      if (!safeName(doc)) throw new Error('bad document name');
      const live = existsSync(pub) ? readdirSync(pub).filter((t) => TOKEN_RE.test(t)).filter((t) => {
        try {
          const m = JSON.parse(readFileSync(join(pub, t, '.share.json'), 'utf8'));
          return m.doc === doc && !(m.expires && Date.now() > new Date(m.expires).getTime());
        } catch { return false; }
      }) : [];
      if (live.length !== 1) throw new Error(live.length ? `${doc} has ${live.length} live shares` : `${doc} has no live share`);
      const dir = join(pub, live[0]);
      // the references come from what the share SERVES - its snapshot of the
      // page - not from a later revision of the private copy
      const { assets, missing } = bundleFor(root, doc, rest, join(dir, doc));
      const mf = join(dir, '.share.json');
      const m = JSON.parse(readFileSync(mf, 'utf8'));
      // copied files are unservable until the manifest lists them; audited
      // before that, so nothing becomes public unrecorded
      copyBundle(root, dir, assets);
      audit(root, { doc, action: 'bundle', token: live[0], assets });
      writeFileSync(mf, JSON.stringify({ ...m, assets }));
      console.log(JSON.stringify({ token: live[0], expires: m.expires, assets, missing }));
    } else {
      throw new Error('usage: bundle.mjs plan|copy|extend ...');
    }
  } catch (e) { console.error(`cel pages: ${e.message}`); process.exit(1); }
}
