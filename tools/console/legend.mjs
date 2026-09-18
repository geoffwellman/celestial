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
    ['Enter / double-click', 'the unit view - orchestrator, workers, mail'],
    ['Ctrl+T', 'switch panel (fleet → waiting → inbox)'],
    ['Ctrl+F', 'focus the selected unit\u2019s orchestrator'],
    ['Ctrl+O', 'open the workspace dashboard'],
    ['T / Ctrl+Y', 'the TIMELINE - mail, delegations and merges in one column'],
    ['click / double-click', 'select / open the unit view'],
    ['wheel', 'scroll the panel'],
  ],
  waiting: [
    ['↑/↓', 'select up / down'],
    ['Enter on a selection', 'open the detail view'],
    ['Ctrl+D', 'open the detail view'],
    ['click / double-click', 'select / open the detail view'],
  ],
  // EVERY LIST IS A PLACE YOU CAN ENTER. The inbox tail was the one panel with
  // no selection at all - "I can't click on stuff in the inbox" - so a line
  // that told you something was happening was a line you could not follow.
  inbox: [
    ['↑/↓', 'select up / down (Ctrl+T cycles fleet → waiting → inbox)'],
    ['Enter / double-click', 'open the message detail'],
  ],
  board: [
    ['↑/↓', 'select a ticket'],
    ['Enter', 'the ticket detail - description, last comments, the worker on it'],
    ['s start', 'ask the orchestrator to pick this one up next, proposed'],
    ['m move', 'move it to another state, with the team\u2019s states offered'],
    ['o open', 'open the ticket in a browser'],
  ],
  prs: [
    ['↑/↓', 'select a pull request'],
    ['Enter', 'the PR detail - checks by name, review state, the worker'],
    ['l land', 'cel-fanout land, when it is approved and the checks are green'],
    ['v review', 'cel run reviewer on this PR, proposed'],
    ['o open', 'open the PR in a browser'],
  ],
  page: [
    ['Esc', 'back to the unit view'],
  ],
  timeline: [
    ['↑/↓', 'select an event'],
    ['Enter', 'the detail behind it - the message, the worker, the PR'],
    ['Esc', 'back to the fleet'],
  ],
  unit: [
    ['↑/↓', 'select a worker'],
    ['Ctrl+T', 'cycle the focus: workers → board → PRs → waiting → mail'],
    ['n nudge', 'herdr agent prompt the selected worker, on the command line'],
    ['R restart', 'start the orchestrator again, when it is not live'],
    ['a answer', 'reply to the selected waiting item and close it'],
    ['Enter', 'the worker view - the answer to \u201cwhy\u201d'],
    ['f focus', 'focus the orchestrator pane'],
    ['m message', 'cel inbox send to the orchestrator, on the command line'],
    ['s mem', 'sort the workers by memory, biggest first (again for the default order)'],
    ['Esc', 'back to the fleet'],
  ],
  worker: [
    ['p prompt', 'herdr agent prompt, on the command line'],
    ['f focus', 'focus the worker pane'],
    ['c collect', 'cel-fanout collect, proposed - Enter runs it'],
    ['x release', 'cel-fanout release, proposed - Enter runs it'],
    ['t try', 'cel-fanout try, where the repo has a preview'],
    ['w why', 're-run cel-fanout why'],
    ['Esc', 'back to the unit view'],
  ],
  detail: [
    ['r', 'resolve'],
    ['p', 'reply (puts cel inbox send on the command line)'],
    ['g', 'go to the sender'],
    ['u', 'the unit view, when the sender is an orchestrator'],
    ['k', 'the worker view, when the sender is a worker'],
    ['Esc', 'back'],
    ['', 'bare letters act here: the detail view has no command line'],
  ],
  output: [
    ['PageUp / PageDown', 'scroll'],
    ['Ctrl+L', 'collapse or expand the panel'],
    ['r', 'raw - the text exactly as the command printed it'],
    ['wheel', 'scroll'],
  ],
  quota: [
    ['q / Esc', 'close the quota view'],
    ['', 'one row per account and window, with the API balances beneath'],
  ],
  everywhere: [
    ['F1', 'this help'],
    ['q', 'the QUOTA view - the Claude and Codex windows, and when they reset'],
    ['Ctrl+C', 'quit'],
  ],
};

// The one line under the status: short, and about the panel that has focus,
// because a legend listing every binding on the box is a legend nobody reads.
export const legend = (pane) => {
  switch (pane) {
    case 'quota':
      return 'the subscription windows · Esc back · ? help';
    case 'detail':
      return 'r resolve · p reply · g go to · u unit · k worker · Esc back · ? help';
    case 'unit':
      return '↑/↓ worker · Enter why · ^T panel · f focus · n nudge · c/C collect · x/X release · R restart · s mem · Esc back · ? help';
    case 'services':
      return '↑/↓ select · o open · S start/stop · r restart · L logs · x stop preview · Esc back · ? help';
    case 'board':
      return '↑/↓ ticket · Enter detail · s start · m move · o open · ^T panel · Esc back · ? help';
    case 'prs':
      return '↑/↓ PR · Enter detail · l land · v review · o open · ^T panel · Esc back · ? help';
    case 'timeline':
      return '↑/↓ event · Enter detail · Esc back · ? help';
    case 'page':
      return 'Esc back · ? help';
    case 'worker':
      return 'p prompt · f focus · c collect · x release · t try · w why · Esc back · ? help';
    case 'inbox':
      return '↑/↓ select · Enter detail · ^T panel · ^L output · ? help';
    case 'waiting':
      return '↑/↓ select · Enter detail · ^T panel · ^L output · ^P/^N history · ? help';
    case 'output':
      return 'PgUp/PgDn scroll · ^L collapse · ^T panel · r raw · ? help';
    default:
      return '↑/↓ select · Enter unit · S services · ^T panel · ^F focus · ^O dashboard · q quota · T timeline · ^P/^N history · ? help';
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
