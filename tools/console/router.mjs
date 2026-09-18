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
  ['other', 'none of the above, or the sentence is not about the fleet at all'],
];

export const INTENT_NAMES = INTENTS.map(([n]) => n);

// --- what the router is told ----------------------------------------------

// The state, reduced. The chat model gets the whole fleet JSON because it has
// to write names; the classifier only has to recognise them, and a 12 KB
// state on a question with ten answers is money spent on tokens nobody reads.
export const facts = (doc, items = []) => {
  const workspaces = [];
  const products = [];
  const workers = [];
  const tickets = [];
  for (const ws of (doc && doc.workspaces) || []) {
    workspaces.push(ws.name);
    for (const u of ws.units || []) {
      products.push({ name: u.name, workspace: ws.name });
      for (const w of u.workers_list || []) {
        workers.push({ id: w.id, ticket: w.ticket || '', workspace: ws.name, product: u.name });
        if (w.ticket && !tickets.includes(w.ticket)) tickets.push(w.ticket);
      }
    }
  }
  // The open items travel as id → workspace only: `resolve 17892…` has to
  // know which mailbox that id is in, and the console already knows.
  const mailboxes = {};
  for (const it of items) if (it && it.id) mailboxes[it.id] = it.ws;
  return { workspaces, products, workers, tickets_seen: tickets, open_items: items.length, mailboxes };
};

const state = (sentence, f) => ({
  sentence,
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

// Who a sentence is addressed to: a worker, an orchestrator named outright,
// or a product - which means its orchestrator.
const addresseeIn = (sentence, f) => {
  const w = f.workers.find((x) => names(sentence, x.id));
  if (w) return { who: w.id, workspace: w.workspace, at: sentence.toLowerCase().indexOf(w.id.toLowerCase()) };
  for (const p of f.products) {
    const orch = `${p.name}-orch`;
    if (names(sentence, orch)) {
      return { who: orch, workspace: p.workspace, at: sentence.toLowerCase().indexOf(orch.toLowerCase()) };
    }
  }
  const p = f.products.find((x) => names(sentence, x.name));
  if (p) {
    return { who: `${p.name}-orch`, workspace: p.workspace, at: sentence.toLowerCase().indexOf(p.name.toLowerCase()) };
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
      if (!hit) return null;
      const text = messageText(s, hit);
      if (!text) return null;
      return [`cel inbox send ${hit.who} ${shellQuote(text)} --workspace ${hit.workspace}`];
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

    case 'try': {
      const w = workerIn(s, f);
      if (!w) return null;
      return [`cel-fanout try ${w.id} --workspace ${w.workspace}`];
    }

    default:
      return null;   // `other`, and anything a future model invents
  }
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
export const route = async ({ sentence, doc, items = [], configPath, root = CEL_ROOT, selected = null }) => {
  const cfg = routerConfig(configPath, root);
  if (!cfg) throw new NoRouter('no router configured');
  if (!cfg.url) throw new NoRouter(`router: provider '${cfg.provider}' has no api: in agents.yaml`);
  if (!cfg.key) throw new NoRouter('router: no key for the router provider');
  const f = facts(doc, items);
  const started = Date.now();
  const { intent, confidence, probabilities } = await askDecision(cfg, sentence, f);
  const ms = Date.now() - started;
  const cmds = plan(intent, sentence, f, { selected });
  // Confident and fillable is a proposal. Confident and UNFILLABLE is a miss
  // for that intent - the model was sure it was a `why`, and there is no such
  // worker on the box - so the chat model gets it rather than the console
  // inventing an id.
  if (confidence >= cfg.minConfidence && cmds) {
    return { intent, confidence, probabilities, ms, cmds, options: [] };
  }
  return {
    intent,
    confidence,
    probabilities,
    ms,
    cmds: null,
    options: options(probabilities, sentence, f, { selected }).filter((o) => o.intent !== 'other'),
  };
};
