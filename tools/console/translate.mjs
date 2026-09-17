// The console's translator: one sentence in, ONE command line out.
//
// Deliberately a bare `fetch` and nothing else. An SDK would pull a provider's
// whole client surface - retries, streaming, telemetry, a version to keep - in
// exchange for a single POST, and would tie the console to one vendor while the
// plane's entire point is that any provider will do. Endpoints and key
// environment variables come from agents.yaml, which is already the box's
// answer to "how do I reach <provider>"; duplicating them here is how the two
// lists start disagreeing.
//
// The model NEVER executes anything. It returns text; the TUI puts that text on
// the command line as a proposal and the operator presses Enter. Anything that
// is not made of commands is treated as a failure to translate, because a model
// apologising in prose must not become a command nobody read.
//
// Two things changed on 2026-09-17, both because a person expected them. A
// sentence can need a SEQUENCE ("clean the blockers on sandbox" is a read and
// then a resolve), so the first ask may return up to five command lines and the
// TUI proposes them as one chain. And a MISS is not a dead end: the second ask
// runs in options mode, where the model returns up to three candidates each
// with a one-line reason, and the operator picks. Neither path runs anything;
// both end on the command line waiting for Enter.
import { readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

export const CEL_ROOT = process.env.CEL_ROOT
  || join(homedir(), 'celestial');

const CONFIG_PATH = () => process.env.CEL_CONSOLE_CONFIG
  || join(homedir(), '.local/share/cel/config.yaml');

// A two-level YAML reader for ONE known shape (`console:` and its scalar
// keys). Not a YAML parser and not pretending to be: the plane has no node
// dependencies outside the console's own UI, and a config file of five string
// keys does not justify one. Anything it cannot read is simply absent, which
// lands on the "no translator configured" path rather than a crash.
export const readConfig = (path = CONFIG_PATH()) => {
  let text;
  try { text = readFileSync(path, 'utf8'); } catch { return { console: {}, warnings: [] }; }
  const warnings = [];
  try {
    // A config file holding `key:` is a credential file. The quiet version of
    // getting this wrong is an API key readable by every process on a box that
    // has other people's agents on it.
    const mode = statSync(path).mode & 0o077;
    if (mode) warnings.push(`${path} is readable by others - chmod 600 it`);
  } catch { /* unreadable mode is not worth failing a translation over */ }

  const out = {};
  let section = null;
  for (const raw of text.split('\n')) {
    const line = raw.replace(/\s+$/, '');
    if (!line || /^\s*#/.test(line)) continue;
    const top = /^([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (top) { section = top[1]; out[section] = out[section] || {}; continue; }
    const kv = /^\s+([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (kv && section) {
      out[section][kv[1]] = kv[2].replace(/^["']|["']$/g, '').replace(/\s+#.*$/, '').trim();
    }
  }
  return { console: out.console || {}, warnings };
};

// agents.yaml's `providers:` block is the source of truth for where a provider
// lives and which environment variable carries its key. Read as text, for the
// same reason as above: no yq at runtime, no YAML dependency, one known shape.
export const readProvider = (name, root = CEL_ROOT) => {
  let text;
  try { text = readFileSync(join(root, 'agents.yaml'), 'utf8'); } catch { return null; }
  const lines = text.split('\n');
  let i = lines.findIndex((l) => /^providers:\s*$/.test(l));
  if (i < 0) return null;
  const fields = {};
  let found = false;
  for (i += 1; i < lines.length; i += 1) {
    const line = lines[i];
    if (/^\S/.test(line)) break;                       // out of the block
    if (!line.trim() || /^\s*#/.test(line)) continue;
    const head = /^ {2}([A-Za-z0-9_.-]+):\s*(.*)$/.exec(line);
    if (head) {
      if (found) break;                                // next provider: done
      if (head[1] !== name) continue;
      found = true;
      for (const [, k, v] of head[2].matchAll(/([A-Za-z0-9_.-]+):\s*([^,}]+)/g)) {
        fields[k] = v.trim().replace(/^["']|["']$/g, '');
      }
      continue;
    }
    if (!found) continue;
    const kv = /^ {4}([A-Za-z0-9_.-]+):\s*(.+)$/.exec(line);
    if (kv) fields[kv[1]] = kv[2].trim().replace(/^["']|["']$/g, '');
  }
  return found ? fields : null;
};

// The table only. The file's leading HTML comment is addressed to whoever
// edits it, not to a model being billed per token for reading it.
export const vocabulary = (root = CEL_ROOT) => {
  try {
    const text = readFileSync(join(root, 'tools/console/vocabulary.md'), 'utf8');
    return text.replace(/<!--[\s\S]*?-->\s*/g, '').trim();
  } catch { return ''; }
};

const SYSTEM = (vocab) => `You turn one sentence from a human operator into celestial console
commands. You never explain, never apologise and never emit prose.

Vocabulary - these are the only commands you may produce:
${vocab}

Rules:
- Answer with commands alone, one per line, with no backticks, no numbering
  and no prose. Usually ONE line.
- When the sentence genuinely needs a SEQUENCE, answer with up to FIVE lines
  in the order they should run. Never pad: if one command answers it, send one.
- Use the workspace, product and agent names from the state below; never
  invent one. An orchestrator is named <product>-orch.
- Questions about the WHOLE BOX ("what's blocked", "what's running") are
  \`cel fleet\` - plain, never --json, a human reads it.
- Questions about ONE product or workspace ("how is widget going", "what is
  happening with widget") are a chain of three: \`cel fleet\`, then
  \`cel-fanout status --workspace <w>\`, then \`cel inbox open --for root
  --workspace <w>\` - <w> is the workspace that owns the product in the state.
- "What is waiting on me" with no workspace named is
  \`cel inbox open --for root --all-workspaces\`; with one named, that workspace.
- "Take me to <x>" is \`herdr agent focus <x>-orch\` when <x> is a product.
- If the sentence does not map onto the vocabulary, answer with a single
  question mark: ?

Examples:
what's blocked -> cel fleet
how is widget going ->
cel fleet
cel-fanout status --workspace alpha
cel inbox open --for root --workspace alpha
what is happening with gadget ->
cel fleet
cel-fanout status --workspace alpha
cel inbox open --for root --workspace alpha
what is waiting on me -> cel inbox open --for root --all-workspaces
anything for me on sandbox -> cel inbox open --for root --workspace sandbox
take me to gadget -> herdr agent focus gadget-orch
tell gadget-orch to pick up ABC-49 next -> cel inbox send gadget-orch "pick up ABC-49 next" --workspace alpha
resolve 1789208557174615054 -> cel inbox resolve 1789208557174615054
what is in flight on alpha -> cel-fanout status --workspace alpha
clean the steward's blockers on sandbox ->
cel inbox open --for root --workspace sandbox
cel inbox resolve --all --from steward --workspace sandbox
why did the last build fail -> ?`;

// Options mode: the SECOND ask, after a miss. The operator has already been
// told "no command for that" once and it taught them nothing; what a person
// expects of something that failed to understand them is an interpretation and
// a choice, not a shrug.
const OPTIONS_SYSTEM = (vocab) => `A human operator typed a sentence at the celestial console and it
could not be turned into a command. Offer up to THREE candidate command lines
they might have meant, best first.

Vocabulary - these are the only commands you may produce:
${vocab}

Rules:
- One candidate per line, in the form: <command> -- <one-line reason>
- At most three lines. No numbering, no backticks, no prose around them.
- The reason is short and says what the command would show or do.
- Use the workspace, product and agent names from the state below; never
  invent one.
- If the sentence is not about anything in the vocabulary at all, answer with
  a single question mark: ?

Example:
sort out sandbox ->
cel inbox open --for root --workspace sandbox -- see what is waiting there first
cel fleet -- the whole box at a glance
cel-fanout status --workspace sandbox -- what is in flight`;

// What a command looks like. The console's allowlist is the real gate (the
// guard in lib/guard.sh decides what runs), but a model that returns a
// paragraph must not have its first eleven words placed on the command line as
// though they were a command.
const COMMAND = /^(cel|cel-fanout|cel-linear|gh|herdr)(\s|$)/;

// The most commands a chain may carry. Five is not a round number: it is the
// point past which an operator stops reading the proposal before pressing
// Enter, and a chain nobody read is the model executing things.
export const CHAIN_MAX = 5;
export const OPTIONS_MAX = 3;

const clean = (text) => String(text || '')
  .trim()
  .replace(/^```[a-z]*\s*/i, '')
  .replace(/\s*```$/, '')
  .trim();

// EVERY line must be a command, or none of them are. A reply of one good
// command and one line of apology is a reply that would put an apology on the
// command line as the second step of a chain.
export const parseReply = (text) => {
  const raw = clean(text);
  const lines = raw.split('\n').map((l) => l.trim()).filter(Boolean);
  if (!lines.length || raw === '?') return { cmds: [], raw };
  if (lines.length > CHAIN_MAX) return { cmds: [], raw };
  // ` -- ` is the reason separator of options mode. A model that answered the
  // first ask in that shape has offered candidates, not a chain, and running
  // them in order would run three alternatives one after another.
  for (const line of lines) if (!COMMAND.test(line) || line.includes(' -- ')) return { cmds: [], raw };
  return { cmds: lines, raw };
};

// `<command> -- <reason>`. The separator is ` -- ` with spaces so a command
// carrying `--workspace` cannot be cut in half by it.
export const parseOptions = (text) => {
  const raw = clean(text);
  const options = [];
  for (const line of raw.split('\n')) {
    const l = line.trim().replace(/^\d+[.)]?\s+/, '');
    if (!l || !COMMAND.test(l)) continue;
    const i = l.indexOf(' -- ');
    const cmd = (i < 0 ? l : l.slice(0, i)).trim();
    const reason = i < 0 ? '' : l.slice(i + 4).trim();
    if (!COMMAND.test(cmd)) continue;
    options.push({ cmd, reason });
    if (options.length === OPTIONS_MAX) break;
  }
  return { options, raw };
};

export class NoTranslator extends Error {}

// One request, one answer, 15 seconds. No streaming: there is nothing to
// stream - the reply is one short line - and a stream would mean partial
// commands appearing on an operator's command line as they arrive.
// One request, one reply, no streaming: the reply is a few short lines and a
// stream would mean partial text appearing while the operator reads.
const _chat = async ({ cfg, table, key, base, system, user, timeout, maxTokens = 400 }) => {
  const provider = cfg.console.provider;
  const model = cfg.console.model || table.default_model || '';
  const anthropic = provider === 'anthropic';
  const url = /\/(messages|chat\/completions)$/.test(base)
    ? base
    : base.replace(/\/$/, '') + (anthropic ? '/v1/messages' : '/v1/chat/completions');
  const headers = { 'content-type': 'application/json' };
  let body;
  if (anthropic) {
    headers['x-api-key'] = key;
    headers['anthropic-version'] = '2023-06-01';
    body = { model, max_tokens: maxTokens, system, messages: [{ role: 'user', content: user }] };
  } else {
    headers.authorization = `Bearer ${key}`;
    body = { model, max_tokens: maxTokens, messages: [{ role: 'system', content: system }, { role: 'user', content: user }] };
  }
  const res = await fetch(url, { method: 'POST', headers, body: JSON.stringify(body), signal: AbortSignal.timeout(timeout) });
  if (!res.ok) throw new Error(`model: ${provider} answered HTTP ${res.status}`);
  const doc = await res.json();
  return anthropic
    ? (doc.content || []).map((c) => c.text || '').join('')
    : doc.choices?.[0]?.message?.content;
};

// Provider, key and endpoint for this box, or a NoTranslator saying what is
// missing. Shared by every model call so the three error messages exist once.
const _connection = (configPath, root) => {
  const cfg = readConfig(configPath);
  for (const w of cfg.warnings) process.stderr.write(`  ! ${w}\n`);
  const provider = cfg.console.provider;
  if (!provider) throw new NoTranslator('no model configured: add console.provider to ~/.local/share/cel/config.yaml');
  const table = readProvider(provider, root) || {};
  const keyEnv = cfg.console.key_env || table.key_env;
  const key = (keyEnv && process.env[keyEnv]) || cfg.console.key || '';
  const base = process.env.CEL_CONSOLE_PROVIDER_URL || table.api;
  if (!base) throw new NoTranslator(`no model configured: provider '${provider}' has no api: in agents.yaml`);
  if (!key) throw new NoTranslator(`no model configured: ${keyEnv || 'the provider key'} is unset and console.key is absent`);
  return { cfg, table, key, base };
};

const ANSWER_SYSTEM = `You are the celestial console answering its operator. They asked a question;
the console ran commands for it and their output follows. Answer the question
in at most six short plain-text lines, from the output ONLY - never from
memory, never invented. Name products, tickets, agents and workspaces exactly
as the output prints them. If the output does not answer the question, say so
in one line and name the command that would. No markdown, no headings, no
apologies.`;

// After a sentence's commands have run: what do they say? Off with
// console.answer: off in the config. Returns null when off or on any failure -
// the raw output is still on screen, the answer is a courtesy on top of it.
export const answer = async ({ sentence, transcript, root = CEL_ROOT, configPath }) => {
  const { cfg, table, key, base } = _connection(configPath, root);
  if (String(cfg.console.answer || '').toLowerCase() === 'off') return null;
  const clipped = String(transcript || '').slice(-8000);
  const user = `Question: ${sentence}\n\nWhat ran, and what it printed:\n${clipped}`;
  const text = await _chat({ cfg, table, key, base, system: ANSWER_SYSTEM, user, timeout: 30000, maxTokens: 300 });
  const out = String(text || '').trim();
  return out || null;
};

export const translate = async ({ sentence, state = '', root = CEL_ROOT, configPath, mode = 'command' }) => {
  const cfg = readConfig(configPath);
  for (const w of cfg.warnings) process.stderr.write(`  ! ${w}\n`);

  const provider = cfg.console.provider;
  if (!provider) {
    throw new NoTranslator(
      'no model configured: add console.provider to ~/.local/share/cel/config.yaml',
    );
  }
  const table = readProvider(provider, root) || {};
  const keyEnv = cfg.console.key_env || table.key_env;
  // The ENVIRONMENT wins over the file, always: a key exported for this session
  // is the one the operator is deliberately using, and a stale key left in a
  // config file silently overriding it is an authentication failure nobody can
  // see from the outside.
  const key = (keyEnv && process.env[keyEnv]) || cfg.console.key || '';
  const base = process.env.CEL_CONSOLE_PROVIDER_URL || table.api;
  if (!base) {
    throw new NoTranslator(
      `no model configured: provider '${provider}' has no api: in agents.yaml`,
    );
  }
  if (!key) {
    throw new NoTranslator(
      `no model configured: ${keyEnv || 'the provider key'} is unset and console.key is absent`,
    );
  }

  const options = mode === 'options';
  const system = options ? OPTIONS_SYSTEM(vocabulary(root)) : SYSTEM(vocabulary(root));
  const user = `Current state:\n${state}\n\nSentence: ${sentence}`;
  // The SECOND ask gets longer: the operator has already been told the first
  // one missed, they are waiting on purpose, and a 15-second cut-off turned a
  // menu of three good options into "no command for that" on this box.
  const text = await _chat({ cfg, table, root, key, base, system, user, timeout: options ? 30000 : 15000 });
  if (options) return parseOptions(text);
  const { cmds, raw } = parseReply(text);
  return { cmds, cmd: cmds[0] || null, raw };
};

export const translatorLabel = (configPath) => {
  const cfg = readConfig(configPath);
  if (!cfg.console.provider) return 'no model';
  return `${cfg.console.provider}/${cfg.console.model || '?'}`;
};
