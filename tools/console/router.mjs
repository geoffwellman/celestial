// The console's ROUTER: one sentence in, one intent out, and the console
// fills the slots.
//
// The sentence path used to be a chat model writing a command line, and on
// 2026-09-18 that cost 6.5 s for "what's blocked" and 16 s for a miss (the
// miss pays for a second ask). Routing is not writing: it is choosing one
// label out of ten, which is a classification problem, and a decision model
// answers typed questions about a state instead of generating text. The same
// six sentences measured through the decisions endpoint on this box came back
// in 0.3-0.8 s with a probability distribution attached.
//
// The rule that makes this safe is that the MODEL NEVER WRITES A COMMAND. It
// returns `product_status` and a confidence; every character that reaches the
// operator's command line is produced by `plan()` below, from the sentence and
// the fleet state the console already holds. A slot that cannot be filled -
// no product named, no such ticket - is a MISS, and a miss falls through to
// the chat model rather than guessing: a guessed `--workspace` is someone
// else's mailbox.
//
// The chat model keeps the two jobs that need prose: the answer written from
// a transcript, and sentences the router cannot place.
import { readConfig, readProvider, CEL_ROOT } from './translate.mjs';

// The ten intents and the one-line rubric each carries into the question. A
// rubric is what the classifier reads instead of examples, so it says what the
// operator WANTS, not what the command is.
export const INTENTS = [
  ['fleet', 'the state of the whole box - what is running, what is blocked, everything at once'],
  ['product_status', 'how one named product or workspace is going right now'],
  ['waiting', 'what is waiting on the operator - decisions and mail addressed to them'],
  ['why_worker', 'why one named worker or ticket is stuck, quiet, stalled or failing'],
  ['focus', 'take me to a pane - a product, an orchestrator or a worker'],
  ['message', 'send a message to an agent - tell it, ask it, remind it to do something'],
  ['resolve', 'close one waiting decision or message'],
  ['clean_inbox', 'clear out the mailbox - sweep what has piled up in a workspace'],
  ['try', 'run or preview one worker\u2019s work so it can be looked at'],
  ['quota', 'how much of the Claude or Codex subscription is left, and when a window resets'],
  // CEL-25: the seven verbs. Each is an ACT on the box rather than a read of
  // it, and the rubric says what the operator wants rather than what the
  // command is - a classifier reads rubrics, not examples.
  ['start_ticket', 'get work started on a named ticket - pick it up, begin it, put someone on it'],
  ['answer', 'reply to a decision or question waiting on the operator, and close it'],
  ['land', 'land, merge or ship a finished pull request or ticket'],
  ['nudge', 'prompt a worker or an orchestrator directly, right now - poke it, remind it, tell it to push'],
  // CEL-36: the one place the console relays a conversation. `message` is
  // mail with a tap on the shoulder; `talk` is the operator's command line
  // wired to a pane until they press Esc.
  ['talk', 'open a back-and-forth with an orchestrator - talk to it, speak to it, have a word'],
  ['restart_orchestrator', 'start a product\u2019s orchestrator again after it has stopped'],
  ['move_ticket', 'move a ticket to another state on the board'],
  ['review', 'get a reviewer onto a pull request'],
  ['gateway', 'which accounts or subscriptions are signed in and usable behind the box\u2019s gateway'],
  ['open_service', 'open or look at one named service or preview - give me its URL'],
  ['service_ctl', 'start, stop or restart one named service'],
  ['service_logs', 'what one named service is printing - its log or output'],
  ['other', 'none of the above, or the sentence is not about the fleet at all'],
];

export const INTENT_NAMES = INTENTS.map(([n]) => n);

// --- what the router is told ----------------------------------------------

// The state, reduced. The chat model gets the whole fleet JSON because it has
// to write names; the classifier only has to recognise them, and a 12 KB
// state on a question with ten answers is money spent on tokens nobody reads.
export const facts = (doc, items = [], services = [], roster = []) => {
  const workspaces = [];
  const products = [];
  // CEL-36: the orchestrators as addressees in their own right - the alias to
  // write to, the workspace its mailbox is in, the repos it owns (so "tell the
  // platform to ..." reaches the product that holds `platform`) and whether
  // its pane is live, which is the difference between mail read in an hour and
  // a prompt that lands now.
  const orchs = [];
  const workers = [];
  const tickets = [];
  for (const ws of (doc && doc.workspaces) || []) {
    workspaces.push(ws.name);
    for (const u of ws.units || []) {
      products.push({ name: u.name, workspace: ws.name });
      orchs.push({
        who: `${u.name}-orch`,
        product: u.name,
        workspace: ws.name,
        repos: u.repos || [],
        live: LIVE_PANE.test(String(u.orch || '')),
      });
      for (const w of u.workers_list || []) {
        // The alias, the repo and the PR number ride along for CEL-25's
        // verbs: `nudge` addresses a herdr pane and `land`/`review` need the
        // repo a PR is in, and both are in the fleet document the console
        // already holds. Looking them up a second time from a command would
        // be the console asking the box what it was just told.
        const prNum = (/\/pull\/(\d+)/.exec(String(w.pr || '')) || [])[1] || '';
        workers.push({
          id: w.id,
          ticket: w.ticket || '',
          workspace: ws.name,
          product: u.name,
          alias: w.alias || w.id,
          repo: w.repo || '',
          pr: prNum ? Number(prNum) : 0,
        });
        if (w.ticket && !tickets.includes(w.ticket)) tickets.push(w.ticket);
      }
    }
  }
  // The open items travel as id → workspace only: `resolve 17892…` has to
  // know which mailbox that id is in, and the console already knows.
  const mailboxes = {};
  for (const it of items) if (it && it.id) mailboxes[it.id] = it.ws;
  // The open items whole (id, sender, workspace) as well as the id → mailbox
  // map: `answer` has to find the item a sentence is replying to, and "reply
  // to bundle-orch" names the sender, not the id.
  const open = items.map((it) => ({ id: it.id, ws: it.ws, from: it.from || '' }));
  // Services travel by NAME and workspace only. "open the builder" has to
  // resolve to one row and one mailbox; everything else about it - the port,
  // the reach URL - is `cel services`' answer, not the router's to invent.
  const svcs = (services || []).map((s) => ({ name: s.name, workspace: s.ws || s.workspace || '', ticket: s.ticket || '' }));
  return {
    workspaces, products, workers, tickets_seen: tickets, open_items: items.length, mailboxes, open,
    services: svcs, orchs,
    // The names `herdr agent list` carries. A pane outlives the product name
    // it was started under - a rename leaves `oldname-orch` on the roster and
    // nowhere in the fleet document - and a name the operator can see is a
    // name they will address.
    roster: (roster || []).filter(Boolean),
  };
};

const state = (sentence, f) => ({
  sentence,
  services: (f.services || []).map((s) => s.name),
  workspaces: f.workspaces,
  products: f.products,
  tickets_seen: f.tickets_seen,
  open_items: f.open_items,
});

// --- slot filling ---------------------------------------------------------

// Case-insensitive substring on a word boundary. Plain `includes` matched
// `beta` inside `alphabetal` on the first draft of this; a name that appears
// inside another word is not the operator naming it.
const names = (sentence, name) => {
  if (!name) return false;
  const esc = String(name).replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  return new RegExp(`(^|[^A-Za-z0-9_-])${esc}([^A-Za-z0-9_-]|$)`, 'i').test(` ${sentence} `);
};

const TICKET = /\b[A-Z][A-Z0-9]+-\d+\b/;

// A pane is LIVE when herdr says it is idle, done or working - the three
// states in which a prompt reaches somebody. `cel fleet` writes LIVE for the
// same thing, and both spellings arrive here depending on which read filled
// the document.
const LIVE_PANE = /^(live|idle|done|working)$/i;

const workspaceIn = (sentence, f) => f.workspaces.find((w) => names(sentence, w)) || null;

// A product first, then a workspace: "how is widget going" is about a product
// even on a box where a workspace shares the name.
const productIn = (sentence, f) => f.products.find((p) => names(sentence, p.name)) || null;

// The worker an id or a ticket points at. An id wins over a ticket because
// two workers can carry the same ticket on different repos, and the id is
// what `cel-fanout why` takes.
const workerIn = (sentence, f) => {
  const byId = f.workers.find((w) => names(sentence, w.id));
  if (byId) return byId;
  const m = TICKET.exec(sentence.toUpperCase());
  if (!m) return null;
  return f.workers.find((w) => String(w.ticket).toUpperCase() === m[0]) || null;
};

// The delegation behind a PR the sentence names - by its number (`land #12`)
// or through its ticket (`merge ABC-49`). A worker with no PR is not a `land`
// and not a `review`: both verbs are about a pull request that exists.
const PR_NUMBER = /#(\d{1,6})\b/;
const prWorkerIn = (sentence, f) => {
  const m = PR_NUMBER.exec(sentence);
  if (m) return f.workers.find((w) => w.pr === Number(m[1])) || null;
  const w = workerIn(sentence, f);
  return w && w.pr ? w : null;
};

// WHO A SENTENCE IS ADDRESSED TO, in one ladder, most specific first: a
// worker id, `<product>-orch`, the product itself, a workspace that holds
// exactly one product, a repo inside a product, and finally a name only the
// roster knows.
//
// The order is the safety property. Each rung is narrower than the one under
// it, so a sentence that names a worker can never resolve to the orchestrator
// above it - and a workspace with two products resolves to NOTHING, returning
// the question instead. Guessing there is mail, and now a pane prompt, in
// somebody else's session.
export const addresseeIn = (sentence, f) => {
  const s = String(sentence || '');
  const at = (name) => s.toLowerCase().indexOf(String(name).toLowerCase());
  const orchs = f.orchs || [];
  const hit = (o, where) => ({ who: o.who, workspace: o.workspace, at: where, orch: true, live: !!o.live });

  const w = f.workers.find((x) => names(s, x.id));
  if (w) return { who: w.id, workspace: w.workspace, at: at(w.id), orch: false, live: false, alias: w.alias || w.id };

  const named = orchs.find((o) => names(s, o.who));
  if (named) return hit(named, at(named.who));

  const byProduct = orchs.find((o) => names(s, o.product));
  if (byProduct) return hit(byProduct, at(byProduct.product));

  const ws = (f.workspaces || []).find((x) => names(s, x));
  if (ws) {
    const mine = orchs.filter((o) => o.workspace === ws);
    if (mine.length === 1) return hit(mine[0], at(ws));
    if (mine.length > 1) {
      return { ask: `${ws} has ${mine.length} products - say ${mine.map((o) => o.who).join(' or ')}` };
    }
  }

  for (const o of orchs) {
    for (const r of o.repos || []) if (names(s, r)) return hit(o, at(r));
  }

  const alias = (f.roster || []).find((a) => names(s, a));
  if (alias) {
    const known = orchs.find((o) => o.who === alias);
    if (known) return hit(known, at(alias));
    // A roster name with no unit behind it has no mailbox the console can be
    // sure of. On a one-workspace box there is only one it could be; on any
    // other the send misses rather than picking one.
    return {
      who: alias,
      workspace: (f.workspaces || []).length === 1 ? f.workspaces[0] : '',
      at: at(alias),
      orch: /-orch$/.test(alias),
      live: false,
    };
  }
  return null;
};

// The message itself: whatever is in quotes, or everything after the
// addressee with the joining word stripped. "tell bundle-orch to pick up
// ABC-49" is not a message that starts with "to".
//
// Only double quotes (and the smart pair) delimit: an apostrophe is a
// character people write - "tell bundle-orch don't bother" - and treating it
// as a delimiter truncated the message at "don".
const messageText = (sentence, hit) => {
  const quoted = /"([^"]{2,})"|“([^”]{2,})”/.exec(sentence);
  if (quoted) return (quoted[1] || quoted[2]).trim();
  if (hit.at < 0) return '';
  const rest = sentence.slice(hit.at).replace(/^\S+\s*/, '');
  return rest.replace(/^(to|that|:|,)\s*/i, '').replace(/^[:,]\s*/, '').trim();
};

// An inbox id is a long number the console printed; anything shorter is a
// word that happens to be digits.
const INBOX_ID = /\b\d{6,}\b/;

// The service a sentence names: by its own name, or - for a preview - by the
// ticket it is running, because "open the preview of ABC-49" is how anyone
// actually says it.
const serviceIn = (sentence, f) => {
  const list = f.services || [];
  const byName = list.find((x) => names(sentence, x.name));
  if (byName) return byName;
  const m = TICKET.exec(String(sentence).toUpperCase());
  if (!m) return null;
  return list.find((x) => String(x.ticket).toUpperCase() === m[0]) || null;
};

// SINGLE QUOTES, ALWAYS, for anything a person typed.
//
// The message text is the only place an operator's own words reach the
// command line, and that line is handed to `bash -c`. The first version of
// this wrapped it in DOUBLE quotes and escaped the double quote, which is no
// protection at all: inside double quotes bash still expands `$(...)`,
// backticks and `$VAR`, so `tell bundle-orch "hi $(rm -rf ~)"` proposed a
// line that deleted a home directory when the operator pressed Enter. Nothing
// downstream catches it - the guard's console branch allows every `cel ...`
// line without reading it for metacharacters, and it should not have to.
//
// Inside SINGLE quotes bash expands nothing at all; the only character that
// matters is the single quote itself, which cannot be escaped and is instead
// closed, emitted as a literal, and reopened. Newlines and carriage returns
// become spaces first: a proposal that spans two lines is a second command
// line the operator never read.
export const shellQuote = (text) => `'${String(text).replace(/[\r\n\t]+/g, ' ').replace(/'/g, "'\\''")}'`;

// One intent, one sentence, the facts: the command lines, or null for a miss.
// `selected` is the waiting item the operator has highlighted, which is what
// "resolve that one" means in front of a screen.
export const plan = (intent, sentence, f, { selected = null } = {}) => {
  const s = String(sentence || '');
  switch (intent) {
    case 'fleet':
      return ['cel fleet'];

    case 'product_status': {
      const p = productIn(s, f);
      const ws = p ? p.workspace : workspaceIn(s, f);
      if (!ws) return null;
      return [
        'cel fleet',
        `cel-fanout status --workspace ${ws}`,
        `cel inbox open --for root --workspace ${ws}`,
      ];
    }

    case 'waiting': {
      const ws = workspaceIn(s, f);
      return [ws
        ? `cel inbox open --for root --workspace ${ws}`
        : 'cel inbox open --for root --all-workspaces'];
    }

    case 'why_worker': {
      const w = workerIn(s, f);
      if (!w) return null;
      return [`cel-fanout why ${w.id} --workspace ${w.workspace}`];
    }

    case 'focus': {
      const w = f.workers.find((x) => names(s, x.id));
      if (w) return [`herdr agent focus ${w.id}`];
      const orch = f.products.find((p) => names(s, `${p.name}-orch`));
      if (orch) return [`herdr agent focus ${orch.name}-orch`];
      const p = productIn(s, f);
      if (!p) return null;
      return [`herdr agent focus ${p.name}-orch`];
    }

    case 'message': {
      const hit = addresseeIn(s, f);
      if (!hit || hit.ask || !hit.workspace) return null;
      const text = messageText(s, hit);
      if (!text) return null;
      const cmds = [`cel inbox send ${hit.who} ${shellQuote(text)} --workspace ${hit.workspace}`];
      // TWO STEPS WHEN THERE IS A PANE TO TAP. Mail is the record and is read
      // when the agent next looks - minutes to hours - which from the
      // operator's seat looked exactly like nothing happening (owner,
      // 2026-09-19: "so we can't actually steer the orchestrators from the
      // TUI?"). The prompt is the tap on the shoulder, and it says to go and
      // READ the mail rather than repeating it: the mailbox stays the record,
      // and the pane never gets two versions of one instruction.
      if (hit.orch && hit.live) {
        cmds.push(`herdr agent prompt ${hit.who} ${shellQuote(`inbox: ${text.slice(0, 80)} - run cel inbox read`)}`);
      }
      return cmds;
    }

    // `talk to bundle-orch`. Not a command the guard runs: it is the console's
    // own relay mode, and this line is what the command line carries into it.
    // Every line typed once it is open becomes `herdr agent prompt`.
    case 'talk': {
      const hit = addresseeIn(s, f);
      if (!hit || hit.ask || !hit.orch) return null;
      return [`talk ${hit.who}`];
    }

    case 'resolve': {
      const m = INBOX_ID.exec(s);
      const id = m ? m[0] : (selected && selected.id) || '';
      if (!id) return null;
      const ws = (f.mailboxes || {})[id]
        || (selected && selected.ws)
        || workspaceIn(s, f)
        || (f.workspaces.length === 1 ? f.workspaces[0] : '');
      if (!ws) return null;
      return [`cel inbox resolve ${id} --workspace ${ws}`];
    }

    case 'clean_inbox': {
      // A sweep on the wrong mailbox is not recoverable: `resolve --all` on a
      // workspace the operator did not name closes decisions they never read.
      const ws = workspaceIn(s, f) || (f.workspaces.length === 1 ? f.workspaces[0] : '');
      if (!ws) return null;
      return [
        `cel inbox open --for root --workspace ${ws}`,
        `cel inbox resolve --all --from steward --workspace ${ws}`,
      ];
    }

    case 'quota':
      // NO SLOTS AT ALL. "how much Claude do I have left" and "when does codex
      // reset" are one question about the box's two subscriptions, and there
      // is no workspace or product that could narrow it - the accounts are the
      // box's, not a workspace's.
      return ['cel quota'];

    // Same box-level shape, one door further out: the gateway holds the
    // accounts `cel quota` cannot see, because they are not signed in to a
    // runtime at all.
    case 'gateway':
      return ['cel gateway status'];

    case 'try': {
      const w = workerIn(s, f);
      if (!w) return null;
      return [`cel-fanout try ${w.id} --workspace ${w.workspace}`];
    }

    // --- CEL-25: the verbs ------------------------------------------------

    case 'start_ticket': {
      const m = TICKET.exec(s.toUpperCase());
      if (!m) return null;
      // A ticket with no product named goes to the only product on the box,
      // and nowhere at all when there are two: "start ABC-49" on a box with
      // three orchestrators is a sentence with a missing word, and guessing
      // which one fills it is guessing whose queue grows.
      const p = productIn(s, f) || (f.products.length === 1 ? f.products[0] : null);
      if (!p) return null;
      return [`cel inbox send ${p.name}-orch ${shellQuote(`pick up ${m[0]} next`)} --workspace ${p.workspace}`];
    }

    case 'answer': {
      const quoted = /"([^"]{2,})"|\u201c([^\u201d]{2,})\u201d/.exec(s);
      const text = quoted ? (quoted[1] || quoted[2]).trim() : '';
      if (!text) return null;
      const byId = INBOX_ID.exec(s);
      const open = f.open || [];
      // The item by its id, then by its sender, then whatever the operator
      // has highlighted. NO MATCHING OPEN ITEM IS A MISS: a reply to a
      // question nobody asked is mail into a mailbox, and the resolve that
      // follows it would close something else.
      let item = byId ? open.find((o) => o.id === byId[0]) : null;
      if (!item) item = open.find((o) => o.from && names(s, o.from));
      if (!item && selected && selected.id) item = { id: selected.id, ws: selected.ws, from: selected.from };
      if (!item || !item.from) return null;
      return [
        `cel inbox send ${item.from} ${shellQuote(text)} --workspace ${item.ws}`,
        `cel inbox resolve ${item.id} --workspace ${item.ws}`,
      ];
    }

    case 'land': {
      const w = prWorkerIn(s, f);
      if (!w) return null;
      // `cel-fanout land`, on the DELEGATION. Merging the PR by hand leaves a
      // worker holding a branch nobody will collect and a ledger row that
      // never closes; land folds the verdict, the worktree and the row
      // together, which is why the id and not the number is the argument.
      return [`cel-fanout land ${w.id} --workspace ${w.workspace}`];
    }

    case 'nudge': {
      const quoted = /"([^"]{2,})"|\u201c([^\u201d]{2,})\u201d/.exec(s);
      if (!quoted) return null;
      // AN ORCHESTRATOR IS A PANE TOO (CEL-36). This was `workerIn` only, so
      // the one agent an operator most often wants right now - the one handing
      // out the work - had no immediate path at all.
      const w = workerIn(s, f);
      let who = w ? (w.alias || w.id) : '';
      if (!who) {
        const hit = addresseeIn(s, f);
        who = hit && hit.orch && !hit.ask ? hit.who : '';
      }
      if (!who) return null;
      return [`herdr agent prompt ${who} ${shellQuote((quoted[1] || quoted[2]).trim())}`];
    }

    case 'restart_orchestrator': {
      // No fall-back to the only product here, unlike `start_ticket`: a
      // restart with no product named is "restart it", and "it" on a console
      // showing six panels is not a product.
      const p = productIn(s, f);
      if (!p) return null;
      return [`cel run orchestrator --product ${p.name} --workspace ${p.workspace}`];
    }

    case 'move_ticket': {
      const m = TICKET.exec(s.toUpperCase());
      const quoted = /"([^"]{2,})"|\u201c([^\u201d]{2,})\u201d/.exec(s);
      if (!m || !quoted) return null;
      // Double quotes, because a Linear state is a name the operator read off
      // the board rather than words they wrote: nothing here came from a
      // keyboard freely, and `cel-linear state` is documented with them.
      return [`cel-linear state ${m[0]} "${(quoted[1] || quoted[2]).trim().replace(/"/g, '')}"`];
    }

    case 'review': {
      const w = prWorkerIn(s, f);
      if (!w || !w.repo) return null;
      return [`cel run reviewer --repo ${w.repo} --pr ${w.pr} --workspace ${w.workspace}`];
    }

    case 'open_service': {
      const svc = serviceIn(s, f);
      if (!svc) return null;
      return [`cel services open ${shellQuote(svc.name)}${svc.workspace ? ` --workspace ${svc.workspace}` : ''}`];
    }

    case 'service_ctl': {
      const svc = serviceIn(s, f);
      if (!svc) return null;
      // The VERB is read from the sentence, never defaulted: "the builder" on
      // its own is not an instruction to stop anything.
      const verb = /\brestart|reboot|bounce\b/i.test(s) ? 'restart'
        : /\bstop|kill|shut\b/i.test(s) ? 'stop'
          : /\bstart|run|bring up\b/i.test(s) ? 'start' : '';
      if (!verb) return null;
      return [`cel services ${verb} ${shellQuote(svc.name)}${svc.workspace ? ` --workspace ${svc.workspace}` : ''}`];
    }

    case 'service_logs': {
      const svc = serviceIn(s, f);
      if (!svc) return null;
      return [`cel services logs ${shellQuote(svc.name)}${svc.workspace ? ` --workspace ${svc.workspace}` : ''}`];
    }

    default:
      return null;   // `other`, and anything a future model invents
  }
};

// WHAT THE CONSOLE SAYS AFTER IT SENDS, and whether it then watches for an
// answer. It lives beside the plan because the fact that decides the second
// command - is the pane live - is the same fact that decides both, and two
// places reading it is two answers to one question.
export const steerFor = (intent, sentence, f) => {
  const hit = addresseeIn(String(sentence || ''), f);
  if (!hit) return null;
  if (hit.ask) return { ask: hit.ask };
  if (intent === 'talk') return hit.orch ? { who: hit.who, workspace: hit.workspace, mode: 'talk' } : null;
  if (intent !== 'message') return null;
  return {
    who: hit.who,
    workspace: hit.workspace,
    orch: !!hit.orch,
    live: !!(hit.orch && hit.live),
    say: hit.orch && hit.live
      ? `sent to ${hit.who} (pane live, prompted)`
      : hit.orch
        ? `sent to ${hit.who} (no live pane - it reads this when it next starts; run "start ${hit.who}" to wake it)`
        : `sent to ${hit.who}`,
  };
};

export const OPTIONS_MAX = 3;

// Below the confidence floor the router is guessing, and a guess belongs in
// the options UI where a person picks. The three most likely intents, each
// already expanded where its slots allow, with the probability as the reason:
// "0.42" tells the operator exactly how sure the thing was, which is more
// honest than a sentence written to sound sure.
export const options = (probabilities, sentence, f, opts = {}) => Object
  .entries(probabilities || {})
  .sort((a, b) => b[1] - a[1])
  .slice(0, OPTIONS_MAX)
  .map(([intent, p]) => {
    const cmds = plan(intent, sentence, f, opts) || [];
    return { intent, cmd: cmds.join(' ; '), cmds, reason: p.toFixed(2), p };
  });

// --- the request ----------------------------------------------------------

// Where the decisions live. OpenRouter hangs them off the same host as chat,
// so the URL is derived from the one already in agents.yaml rather than
// written down twice - two copies of an endpoint is how the two start
// disagreeing. TypeSafe's own API is a single URL and is used as-is.
export const decisionsUrl = (provider, api) => {
  if (!api) return '';
  if (provider === 'typesafe') return api;
  return api.replace(/\/v1\/chat\/completions\/?$/, '/alpha/decisions');
};

// The router's own config block, or null when there is none - which is
// today's chat-only path, unchanged. `enabled: false` is the same answer with
// the config left in place.
export const routerConfig = (configPath, root = CEL_ROOT) => {
  const cfg = readConfig(configPath);
  const r = cfg.console.router;
  if (!r || typeof r !== 'object') return null;
  if (String(r.enabled || '').toLowerCase() === 'false') return null;
  const provider = r.provider || 'openrouter';
  const table = readProvider(provider, root) || {};
  const keyEnv = r.key_env || cfg.console.key_env || table.key_env;
  const key = (keyEnv && process.env[keyEnv]) || cfg.console.key || '';
  const api = process.env.CEL_CONSOLE_ROUTER_URL || table.api;
  const url = decisionsUrl(provider, api);
  const floor = Number(r.min_confidence);
  return {
    provider,
    model: r.model || table.default_model || '',
    key,
    url,
    minConfidence: Number.isFinite(floor) ? floor : 0.6,
  };
};

export const routerLabel = (configPath, root = CEL_ROOT) => {
  const c = routerConfig(configPath, root);
  return c ? `${c.provider}/${c.model || '?'}` : null;
};

export class NoRouter extends Error {}

// One request per sentence, ten seconds, NO RETRIES. A router that retries is
// a router that costs more than the chat model it replaced on exactly the
// days the provider is unwell; the fall-through is already a working path.
export const ROUTER_TIMEOUT = 10000;

const askDecision = async (cfg, sentence, f) => {
  const body = {
    model: cfg.model,
    state: state(sentence, f),
    questions: {
      intent: {
        type: 'choice',
        instructions: 'What does the operator want the console to do?',
        // `criteria`, not `options`: the endpoint's own name for the set, one
        // rubric per choice. Verified against the live API on 2026-09-18 -
        // sending `options:` is a 400 naming this field.
        criteria: Object.fromEntries(INTENTS),
      },
    },
  };
  const res = await fetch(cfg.url, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${cfg.key}` },
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(ROUTER_TIMEOUT),
  });
  if (!res.ok) throw new Error(`router: ${cfg.provider} answered HTTP ${res.status}`);
  const doc = await res.json();
  const a = doc?.answers?.intent;
  const value = typeof a === 'string' ? a : a?.value || a?.choice || a?.answer || '';
  if (!INTENT_NAMES.includes(value)) throw new Error(`router: unknown intent '${value}'`);
  const confidence = Number(typeof a === 'object' ? a.confidence : NaN);
  return {
    intent: value,
    confidence: Number.isFinite(confidence) ? confidence : 1,
    probabilities: (typeof a === 'object' && a.probabilities) || { [value]: Number.isFinite(confidence) ? confidence : 1 },
  };
};

// The whole router: ask, then fill the slots here. Throws NoRouter when there
// is nothing configured and a plain Error on any failure - both mean the same
// thing to the caller, which is "ask the chat model", and the caller is the
// only place that knows how to say that to a person.
export const route = async ({ sentence, doc, items = [], services = [], roster = [], configPath, root = CEL_ROOT, selected = null }) => {
  const cfg = routerConfig(configPath, root);
  if (!cfg) throw new NoRouter('no router configured');
  if (!cfg.url) throw new NoRouter(`router: provider '${cfg.provider}' has no api: in agents.yaml`);
  if (!cfg.key) throw new NoRouter('router: no key for the router provider');
  const f = facts(doc, items, services, roster);
  const started = Date.now();
  const { intent, confidence, probabilities } = await askDecision(cfg, sentence, f);
  const ms = Date.now() - started;
  const cmds = plan(intent, sentence, f, { selected });
  // Confident and fillable is a proposal. Confident and UNFILLABLE is a miss
  // for that intent - the model was sure it was a `why`, and there is no such
  // worker on the box - so the chat model gets it rather than the console
  // inventing an id.
  if (confidence >= cfg.minConfidence && cmds) {
    return { intent, confidence, probabilities, ms, cmds, options: [], steer: steerFor(intent, sentence, f) };
  }
  return {
    intent,
    confidence,
    probabilities,
    ms,
    cmds: null,
    steer: steerFor(intent, sentence, f),
    options: options(probabilities, sentence, f, { selected }).filter((o) => o.intent !== 'other'),
  };
};
