// The console's dark palette, taken from the dashboard's CSS variables
// (tools/dash/server.mjs) so the two surfaces read as one tool rather than two
// programs that happen to ship together. Truecolor hex: ink passes it to
// chalk, which downgrades on terminals that cannot do it.
export const C = {
  ink: '#eceae4',     // body text        (--ink)
  dim: '#8b93a1',     // secondary text   (--dim)
  line: '#252a33',    // borders          (--line)
  accent: '#e3b34c',  // gold             (--accent)
  ok: '#54c07f',      // live / healthy   (--ok)
  warn: '#d9a03f',    // stalled / idle   (--warn)
  bad: '#e2604e',     // blocked / failed (--bad)
};

// State is a COLOUR before it is a word: the operator scanning this panel is
// looking for the one row that is not green, and reading six status strings to
// find it is exactly the bookkeeping the console exists to remove.
export const orchColour = (orch) => {
  switch (String(orch)) {
    case 'LIVE': return C.ok;
    case 'blocked': return C.bad;
    case '-': return C.dim;
    default: return C.warn;
  }
};

export const kindColour = (kind) => (kind === 'blocked' ? C.bad : kind === 'decision' ? C.accent : C.dim);
