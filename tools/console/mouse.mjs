// The mouse: two pure functions and nothing else.
//
// A click is only ever "the right row" by accident unless the hit map is built
// from what was actually rendered, and a hit map that can only be checked by
// hand in a terminal is a hit map that goes one row out the first time a panel
// grows a border. So the sequence parser and the lookup are separated from ink
// entirely: ui.mjs measures the rendered panels and hands the numbers here.
//
// SGR mouse reporting (\x1b[?1006h) is used rather than the original X10
// encoding because X10 packs the coordinates into single bytes and silently
// stops working past column 223 - which on the owner's screen is a real
// column.

// \x1b[<b;x;yM  = press (or motion/wheel), \x1b[<b;x;ym = release.
// Coordinates arrive 1-based; they are kept that way, because every number the
// terminal gives us and every row ink reports is 1-based too, and converting
// in one place and not the other is how a hit map ends up off by one.
const SGR = /\x1b\[<(\d+);(\d+);(\d+)([Mm])/;

export const parseMouse = (seq) => {
  const m = SGR.exec(String(seq || ''));
  if (!m) return null;
  const b = Number(m[1]);
  const x = Number(m[2]);
  const y = Number(m[3]);
  const press = m[4] === 'M';
  // Bit 6 (64) marks the wheel. The wheel has no release event, so a wheel
  // "press" is the whole gesture.
  const wheel = b & 64 ? ((b & 1) ? 'down' : 'up') : null;
  const button = wheel ? -1 : (b & 3);
  return { button, x, y, press, wheel };
};

// A terminal delivers a whole read, not one sequence: a fast scroll arrives as
// four reports in one chunk. Dropping the tail of that chunk makes the wheel
// feel like it misses every second notch.
export const parseMouseAll = (chunk) => {
  const out = [];
  const re = new RegExp(SGR.source, 'g');
  let m;
  while ((m = re.exec(String(chunk || '')))) {
    const ev = parseMouse(m[0]);
    if (ev) out.push(ev);
  }
  return out;
};

export const hasMouse = (chunk) => SGR.test(String(chunk || ''));

// The map is a list of rendered panels:
//   { panel: 'fleet', top: 3, bottom: 9, rows: [4, 5, 6] }
// `rows[i]` is the screen row item i was drawn on, so a panel whose header,
// border or scroll indicator moves cannot shift the mapping: the rows are
// measured, never computed from an assumed offset.
export const hitTest = (map, x, y) => {
  for (const p of map || []) {
    if (y < p.top || y > p.bottom) continue;
    if (x != null && p.left != null && p.right != null && (x < p.left || x > p.right)) continue;
    const index = (p.rows || []).indexOf(y);
    return { panel: p.panel, index };
  }
  return null;
};

// Turning mouse tracking on is cheap; leaving it on is not. A terminal left in
// mouse mode will not let the owner select text with the mouse at all, and the
// only way out is a reset they have to know about - so every exit path,
// including a crash and a SIGTERM, goes through disableMouse().
export const MOUSE_ON = '\x1b[?1000h\x1b[?1006h';
export const MOUSE_OFF = '\x1b[?1006l\x1b[?1000l';
