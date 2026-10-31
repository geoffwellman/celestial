// OpenCode 2.2.5 native configuration. No auth files or global config writes.
import path from 'node:path';
import { pathToFileURL } from 'node:url';
import { readFile } from 'node:fs/promises';
import { statSync } from 'node:fs';
import { isDeepStrictEqual } from 'node:util';

const SOL_LIMIT = Object.freeze({ context: 500000, output: 128000 });

export function scopedConfigInput({ agent, roleFile, pluginFile, baseURL }) {
  return { agent, roleFile, pluginFile, baseURL, modelID: 'gpt-6.1-sol', transport: 'gateway', route: '{env:CEL_SESSION_ID}', limit: { ...SOL_LIMIT } };
}

export function buildConfig(input) {
  const { agent, roleFile, pluginFile, modelID, limit, transport } = input;
  if (!/^[a-zA-Z0-9_-]+$/.test(agent ?? '')) throw new Error('OpenCode requires an explicit scoped agent name');
  if (!path.isAbsolute(roleFile ?? '') || !path.isAbsolute(pluginFile ?? '')) throw new Error('OpenCode role/plugin paths must be absolute');
  // ConfigPluginSource.scan removes configured files before module loading;
  // pluginFile retains the public input key but names a native package directory.
  if (!statSync(pluginFile).isDirectory()) throw new Error('OpenCode configured plugin must be a directory package');
  if (modelID !== 'gpt-6.1-sol') throw new Error('This migration retains gpt-6.1-sol; model substitution is not allowed');
  if (!isDeepStrictEqual(limit, SOL_LIMIT)) {
    throw new Error('Supply evidenced Sol6.1 context/output limits: 500000/128000');
  }
  if (transport !== 'gateway') throw new Error('This migration uses the evidenced gateway account route; native auth is not a fallback');
  const providerID = 'ompgw-codex';
  const model = { providerID, model: modelID, variant: 'medium' };
  const options = { agent, providerID, modelID, transport };
  const provider = { package: '@opencode/ai/providers/openai/responses', models: {
    [modelID]: { modelID, name: 'Sol 6.1',
      capabilities: { tools: true, input: ['text', 'image'], output: ['text'], reasoning: { supported: true, effort: ['medium'] } },
      limit, settings: { reasoningEffort: 'medium' }, variants: [{ id: 'medium', settings: { reasoningEffort: 'medium' } }] },
  } };
  const url = new URL(input.baseURL);
  if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password || url.search || url.hash) throw new Error('Gateway URL must be an HTTP(S) base URL without credentials');
  if (!input.route || /[\r\n]/.test(input.route)) throw new Error('Gateway requires the existing explicit x-session-id route');
  options.route = input.route;
  provider.settings = { baseURL: url.href.replace(/\/$/, ''), apiKey: '{env:OMP_GATEWAY_TOKEN}' };
  provider.headers = { 'x-session-id': input.route };
  provider.env = ['OMP_GATEWAY_TOKEN'];
  return {
    $schema: 'https://opencode.ai/config.json',
    model, default_agent: agent,
    providers: { [providerID]: provider },
    agents: { [agent]: { description: 'Celestial scoped role', mode: 'primary', model, system: `{file:${roleFile}}` } },
    plugins: [{ package: pluginFile, options }],
    policies: [
      { action: 'provider.use', resource: '*', effect: 'deny' },
      { action: 'provider.use', resource: providerID, effect: 'allow' },
    ],
  };
}

export function validateConfig(config, scope) {
  // Compare against the writer itself, including all keys/arrays and the exact
  // plugin path/options. Extra providers/plugins cannot extend this scoped grant.
  if (!isDeepStrictEqual(config, buildConfig(scopedConfigInput(scope)))) {
    throw new Error('OpenCode scoped config differs from the canonical role/provider/transport contract');
  }
  return true;
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  try {
    if (process.argv[2] === '--validate') {
      const [, , , file, agent, roleFile, pluginFile, baseURL] = process.argv;
      if (process.argv.length !== 8 || !path.isAbsolute(file ?? '')) throw new Error('Invalid validation arguments');
      validateConfig(JSON.parse(await readFile(file, 'utf8')), { agent, roleFile, pluginFile, baseURL });
    } else {
      let text = '';
      for await (const chunk of process.stdin) text += chunk;
      process.stdout.write(JSON.stringify(buildConfig(JSON.parse(text)), null, 2) + '\n');
    }
  } catch {
    // A malformed file might contain a literal credential. Never echo parser
    // excerpts or a deep-equality dump of untrusted configuration values.
    console.error('OpenCode scoped configuration is unreadable, malformed, or non-canonical');
    process.exitCode = 1;
  }
}
