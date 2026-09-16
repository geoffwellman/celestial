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
// is not exactly one command is treated as a failure to translate, because a
// model apologising in prose must not become a command nobody read.
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

const SYSTEM = (vocab) => `You turn one sentence from a human operator into exactly ONE shell
command from the celestial console's vocabulary. You never explain, never
apologise and never emit more than one line.

Vocabulary - these are the only commands you may produce:
${vocab}

Rules:
- Answer with the command alone, on one line, with no backticks and no prose.
- Use the workspace, product and agent names from the state below; never
  invent one. An orchestrator is named <product>-orch.
- Questions about state ("how is …", "what's blocked", "what's running") are
  \`cel fleet\` - plain, never --json, a human reads it.
- "What is waiting on me" with no workspace named is
  \`cel inbox open --for root --all-workspaces\`; with one named, that workspace.
- "Take me to <x>" is \`herdr agent focus <x>-orch\` when <x> is a product.
- If the sentence does not map onto exactly one of those commands, answer with
  a single question mark: ?

Examples:
what's blocked -> cel fleet
how is vhs going -> cel fleet
what is waiting on me -> cel inbox open --for root --all-workspaces
anything for me on sandbox -> cel inbox open --for root --workspace sandbox
take me to standout -> herdr agent focus standout-orch
tell standout-orch to pick up W-49 next -> cel inbox send standout-orch "pick up W-49 next" --workspace vhs
resolve 1789208557174615054 -> cel inbox resolve 1789208557174615054
what is in flight on plane -> cel-fanout status --workspace plane
why did the last build fail -> ?`;

// What a command looks like. The console's allowlist is the real gate (the
// guard in lib/guard.sh decides what runs), but a model that returns a
// paragraph must not have its first eleven words placed on the command line as
// though they were a command.
const COMMAND = /^(cel|cel-fanout|cel-linear|gh|herdr)(\s|$)/;

export const parseReply = (text) => {
  const line = String(text || '').trim().replace(/^```[a-z]*\s*|\s*```$/g, '').trim();
  if (!line || line === '?') return null;
  if (line.includes('\n')) return null;
  if (!COMMAND.test(line)) return null;
  return line;
};

export class NoTranslator extends Error {}

// One request, one answer, 15 seconds. No streaming: there is nothing to
// stream - the reply is one short line - and a stream would mean partial
// commands appearing on an operator's command line as they arrive.
export const translate = async ({ sentence, state = '', root = CEL_ROOT, configPath }) => {
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

  const model = cfg.console.model || table.default_model || '';
  const anthropic = provider === 'anthropic';
  const url = /\/(messages|chat\/completions)$/.test(base)
    ? base
    : base.replace(/\/$/, '') + (anthropic ? '/v1/messages' : '/v1/chat/completions');
  const system = SYSTEM(vocabulary(root));
  const user = `Current state:\n${state}\n\nSentence: ${sentence}`;

  const headers = { 'content-type': 'application/json' };
  let body;
  if (anthropic) {
    headers['x-api-key'] = key;
    headers['anthropic-version'] = '2023-06-01';
    body = { model, max_tokens: 200, system, messages: [{ role: 'user', content: user }] };
  } else {
    headers.authorization = `Bearer ${key}`;
    body = {
      model,
      max_tokens: 200,
      messages: [{ role: 'system', content: system }, { role: 'user', content: user }],
    };
  }

  const res = await fetch(url, {
    method: 'POST',
    headers,
    body: JSON.stringify(body),
    signal: AbortSignal.timeout(15000),
  });
  if (!res.ok) throw new Error(`model: ${provider} answered HTTP ${res.status}`);
  const doc = await res.json();
  const text = anthropic
    ? (doc.content || []).map((c) => c.text || '').join('')
    : doc.choices?.[0]?.message?.content;
  // Both halves come back: the command (or null) and what the model actually
  // said, so a refusal can show the operator WHY instead of a bare "no".
  return { cmd: parseReply(text), raw: String(text || '').trim() };
};

export const translatorLabel = (configPath) => {
  const cfg = readConfig(configPath);
  if (!cfg.console.provider) return 'no model';
  return `${cfg.console.provider}/${cfg.console.model || '?'}`;
};
