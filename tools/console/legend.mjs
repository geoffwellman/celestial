// The key legend and the help text, in one place because they are one thing.
//
// The v1 console printed its bindings into the same line it printed responses
// into, so the moment anything happened the operator lost the bindings and had
// no way to get them back. Now the legend is permanent, the status is
// transient, and F1 shows the whole table - all three read from here, so a new
// binding cannot be documented in one of them and not the others.
export const BINDINGS = {
  'command line': [
    ['←/→ Home/End', 'move the cursor (Ctrl+A / Ctrl+E jump)'],
    ['Ctrl+W / Ctrl+K / Ctrl+U', 'kill the word / to end of line / the line'],
    ['Ctrl+P / Ctrl+N', 'history previous / next - filtered by what is already typed'],
    ['Ctrl+R', 'history picker (type to filter, Enter takes it, Esc closes)'],
    ['Tab', 'complete'],
    ['Enter', 'run it, or ask the model to translate it'],
    ['1/2/3 + Enter', 'take an offered option after a miss'],
    ['Esc', 'discard a proposal'],
  ],
  fleet: [
    ['↑/↓', 'select up / down'],
    ['Ctrl+T', 'switch panel'],
    ['Ctrl+F', 'focus the selected unit\u2019s orchestrator'],
    ['Ctrl+O', 'open the workspace dashboard'],
    ['click / double-click', 'select / focus the orchestrator'],
    ['wheel', 'scroll the panel'],
  ],
  waiting: [
    ['↑/↓', 'select up / down'],
    ['Enter on a selection', 'open the detail view'],
    ['Ctrl+D', 'open the detail view'],
    ['click / double-click', 'select / open the detail view'],
  ],
  detail: [
    ['r', 'resolve'],
    ['p', 'reply (puts cel inbox send on the command line)'],
    ['g', 'go to the sender'],
    ['Esc', 'back'],
    ['', 'bare letters act here: the detail view has no command line'],
  ],
  output: [
    ['PageUp / PageDown', 'scroll'],
    ['Ctrl+L', 'collapse or expand the panel'],
    ['wheel', 'scroll'],
  ],
  everywhere: [
    ['F1', 'this help'],
    ['Ctrl+C', 'quit'],
  ],
};

// The one line under the status: short, and about the panel that has focus,
// because a legend listing every binding on the box is a legend nobody reads.
export const legend = (pane) => {
  switch (pane) {
    case 'detail':
      return 'r resolve · p reply · g go to · Esc back · ? help';
    case 'waiting':
      return '↑/↓ select · Enter detail · ^T panel · ^L output · ^P/^N history · ? help';
    case 'output':
      return 'PgUp/PgDn scroll · ^L collapse · ^T panel · ? help';
    default:
      return '↑/↓ select · ^T panel · ^F focus · ^O dashboard · ^L output · ^P/^N history · ? help';
  }
};

export const helpLines = () => {
  const out = [];
  for (const [section, rows] of Object.entries(BINDINGS)) {
    out.push(section.toUpperCase());
    for (const [k, what] of rows) out.push(`  ${String(k).padEnd(26)} ${what}`);
    out.push('');
  }
  out.push('Esc closes this.');
  return out;
};
