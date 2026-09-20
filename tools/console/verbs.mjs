// THE VERBS: every act the console offers, as one pure function.
//
// Before this the console could show an operator everything and change
// nothing: "it doesn't really feel like I can steer anything from there"
// (owner, 2026-09-18). The seven verbs below are what steering actually is -
// start this, answer that, land it, nudge him, restart her, move the ticket,
// get it reviewed - and each used to exist only as a command line typed from
// memory in another window.
//
// EVERY VERB IS A PROPOSAL, never an execution. The key puts a command on the
// command line with the cursor where the words go, and Enter runs it; Esc
// discards. That is the same contract the router has, and for the same reason:
// the console's one safety property is that nothing changes the box without a
// person having read the exact line first.
//
// Pure, and tested as such. The TUI calls this and puts what comes back on the
// command line - nothing here touches a terminal, a process or the network, so
// "n on a worker row proposes the wrong workspace" is a test failure rather
// than a message in a stranger's mailbox.
import { shellQuote } from './router.mjs';
import { ciState } from './views.mjs';

// Where the cursor belongs: just inside the quotes the operator has to fill.
// A proposal that lands with the cursor at the end of the line is a proposal
// they navigate into, and an operator who has to navigate retypes instead.
const inQuotes = (cmd) => {
  const q = cmd.lastIndexOf("''");
  if (q >= 0) return q + 1;
  const d = cmd.lastIndexOf('""');
  return d >= 0 ? d + 1 : cmd.length;
};

const proposal = (cmds, extra = {}) => {
  const cursor = extra.cursor === undefined ? inQuotes(cmds[cmds.length - 1] || '') : extra.cursor;
  return { cmds, cursor, say: '', options: [], ...extra };
};
// A refusal is not silence. `l` on a PR whose checks are red must say which of
// the two conditions failed, or the operator presses it again harder.
const refuse = (say) => ({ cmds: [], cursor: 0, say, options: [] });

// name · the panel it belongs to · the key · one line for the legend.
export const VERBS = [
  { name: 'start', panel: 'board', key: 's', what: 'ask the orchestrator to pick this ticket up next' },
  { name: 'move', panel: 'board', key: 'm', what: 'move the ticket to another state' },
  { name: 'land', panel: 'prs', key: 'l', what: 'land the delegation behind an approved, green PR' },
  { name: 'review', panel: 'prs', key: 'v', what: 'start a reviewer on this PR' },
  { name: 'answer', panel: 'waiting', key: 'a', what: 'reply to the sender and close the item' },
  { name: 'nudge', panel: 'workers', key: 'n', what: 'prompt this worker' },
  { name: 'restart', panel: 'orch', key: 'R', what: 'start the orchestrator again when it is not live' },
  // CEL-36. Not a proposal the guard runs: `talk <who>` is the console's own
  // word for "wire my command line to that pane", and submitValue takes it
  // before the allowlist is ever asked. It is here rather than hard-coded in
  // the key map so the legend and the help table list it with the rest.
  // CEL-44. `u` reconciles the whole workspace this unit lives in - the panes
  // it declares, the orchestrators it wants, and the rename of any live agent
  // herdr has lost the name of. The reset key is SHIFTED because it stops
  // things first; `R` stays the single-orchestrator restart it has always
  // been, which is the finer instrument of the two.
  { name: 'up', panel: 'orch', key: 'u', what: 'put this workspace back to its declared shape (idempotent)' },
  { name: 'reset', panel: 'orch', key: 'U', what: 'close this workspace down and open it again - stops agents' },
  { name: 'talk', panel: 'orch', key: 't', what: 'relay the command line to this orchestrator\u2019s pane until Esc' },
];

export const verbsFor = (panel) => VERBS.filter((v) => v.panel === panel);
export const legendFor = (panel) => verbsFor(panel).map((v) => `${v.key} ${v.name}`).join(' · ');

// One key, on one panel, over one selection. `null` means the key is not a
// verb here and the caller should carry on handling it - a key map that
// swallowed everything would be a console where `s` stopped sorting.
export const verbFor = (panel, key, sel) => {
  const verb = VERBS.find((v) => v.panel === panel && v.key === key);
  if (!verb || !sel) return null;
  switch (verb.name) {
    case 'start':
      if (!sel.ticket || !sel.product || !sel.ws) return refuse('no product for that ticket');
      // THROUGH THE ORCHESTRATOR, never straight to a worker. Delegation is
      // the orchestrator's job and its ledger; a console that delegated behind
      // its back would give the box two things deciding what is in flight.
      return proposal([
        `cel inbox send ${sel.product}-orch ${shellQuote(`pick up ${sel.ticket} next`)} --workspace ${sel.ws}`,
      ], { cursor: -1 });

    case 'move': {
      if (!sel.ticket) return refuse('no ticket selected');
      // The states come from the team, offered as a numbered list: a state
      // name typed from memory is a state name that does not exist, and
      // `cel-linear state` can only tell you so after the round trip.
      return proposal([`cel-linear state ${sel.ticket} ""`], { options: sel.states || [] });
    }

    case 'land': {
      if (String(sel.reviewDecision || '').toUpperCase() !== 'APPROVED') {
        return refuse(`#${sel.number} is not approved yet - land wants a review first`);
      }
      const ci = sel.ci || ciState(sel);
      if (ci !== 'pass') return refuse(`#${sel.number} has checks that are not green (${ci})`);
      // THE DELEGATION, NOT THE PR. `cel-fanout land` folds the verdict, the
      // worktree and the ledger row together; merging the PR by hand leaves a
      // worker holding a branch nobody will ever collect. A PR opened outside
      // the fleet has no delegation and the console says so rather than
      // guessing an id.
      if (!sel.id) return refuse(`no delegation for that branch (${sel.branch || '?'}) - land it where it was made`);
      return proposal([`cel-fanout land ${sel.id} --workspace ${sel.ws}`], { cursor: -1 });
    }

    case 'review':
      if (!sel.number || !sel.repo) return refuse('no PR selected');
      return proposal([`cel run reviewer --repo ${sel.repo} --pr ${sel.number} --workspace ${sel.ws}`], { cursor: -1 });

    case 'answer':
      if (!sel.id || !sel.from) return refuse('nothing selected to answer');
      // A CHAIN, because answering is two acts and doing one of them is the
      // failure mode: a reply with the item left open is a decision that keeps
      // being asked, and a resolve with no reply is a question dropped.
      return proposal([
        `cel inbox send ${sel.from} '' --workspace ${sel.ws}`,
        `cel inbox resolve ${sel.id} --workspace ${sel.ws}`,
      ], { cursor: inQuotes(`cel inbox send ${sel.from} '' --workspace ${sel.ws}`) });

    case 'nudge': {
      const who = sel.alias || sel.id;
      if (!who) return refuse('no worker selected');
      // `herdr agent prompt`, not inbox mail: a nudge is meant to reach the
      // agent NOW, and mail is read when the agent next looks.
      return proposal([`herdr agent prompt ${who} ''`]);
    }

    case 'restart':
      if (!sel.product || !sel.ws) return refuse('no product here');
      if (String(sel.orch || '').toUpperCase() === 'LIVE') {
        return refuse(`${sel.product}-orch is already live - focus it instead`);
      }
      return proposal([`cel run orchestrator --product ${sel.product} --workspace ${sel.ws}`], { cursor: -1 });

    case 'up':
      if (!sel.ws) return refuse('no workspace here');
      return proposal([`cel ws up ${sel.ws}`], { cursor: -1 });

    case 'reset':
      if (!sel.ws) return refuse('no workspace here');
      return proposal([`cel ws reset ${sel.ws}`], { cursor: -1 });

    case 'talk':
      if (!sel.product) return refuse('no orchestrator here to talk to');
      return proposal([`talk ${sel.product}-orch`], { cursor: -1 });

    default:
      return null;
  }
};
