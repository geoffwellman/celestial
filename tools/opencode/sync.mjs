// Opt-in publication for an existing registered workspace/agent scope only.
// The gateway entrypoint resolves the registry; this module never reads auth.
import path from 'node:path';
import { constants } from 'node:fs';
import { open, lstat, rename, unlink } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { isDeepStrictEqual } from 'node:util';
import { buildConfig, scopedConfigInput, validateConfig } from './config.mjs';
import { selectionAllowed } from './model-contract.mjs';

const MAX_BYTES = 8 * 1024 * 1024;
const privateMode = stat => stat.uid === process.geteuid() && !(stat.mode & 0o077);
const requireValue = value => { if (!value) throw new Error('unsafe_scope'); };

async function noLinks(file) {
  const parsed = path.parse(file);
  let current = parsed.root;
  for (const part of file.slice(parsed.root.length).split(path.sep)) {
    current = path.join(current, part);
    requireValue(!(await lstat(current)).isSymbolicLink());
  }
}

async function privateRead(file) {
  const handle = await open(file, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
  try {
    const stat = await handle.stat();
    requireValue(stat.isFile() && privateMode(stat) && stat.size <= MAX_BYTES);
    return await handle.readFile('utf8');
  } finally { await handle.close(); }
}

export async function readScopedConfig({ workspaceDir, agent, pluginFile, baseURL }) {
  requireValue(path.isAbsolute(workspaceDir ?? '') && path.normalize(workspaceDir) === workspaceDir
    && /^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$/.test(agent ?? ''));
  const namespace = path.join(workspaceDir, '.cel', 'opencode', agent);
  const configFile = path.join(namespace, 'role-orchestrator.opencode.json');
  const roleFile = path.join(namespace, 'role-orchestrator.md');
  await noLinks(configFile);
  await noLinks(roleFile);
  requireValue((await lstat(workspaceDir)).uid === process.geteuid());
  for (const directory of [path.join(workspaceDir, '.cel', 'opencode'), namespace]) {
    const stat = await lstat(directory);
    requireValue(stat.isDirectory() && stat.uid === process.geteuid() && !(stat.mode & 0o022));
  }
  await privateRead(roleFile);
  const text = await privateRead(configFile);
  const config = JSON.parse(text);
  const scope = { agent: 'cel-orchestrator', roleFile, pluginFile, baseURL };
  validateConfig(config, scope);
  return { config, text, configFile, scope };
}

export async function validateScopedSelection(options, selection) {
  const { config } = await readScopedConfig(options);
  const catalog = config.plugins[0].options.catalog;
  return selectionAllowed(catalog, selection);
}

async function publishPrivate(file, text) {
  const temporary = `${file}.tmp-${randomUUID()}`;
  let handle;
  try {
    handle = await open(temporary, constants.O_WRONLY | constants.O_CREAT | constants.O_EXCL | constants.O_NOFOLLOW, 0o600);
    await handle.writeFile(text);
    await handle.sync();
    await handle.close(); handle = undefined;
    await rename(temporary, file);
    const directory = await open(path.dirname(file), constants.O_RDONLY | constants.O_DIRECTORY);
    try { await directory.sync(); } finally { await directory.close(); }
  } finally {
    if (handle) await handle.close();
    await unlink(temporary).catch(error => { if (error.code !== 'ENOENT') throw error; });
  }
}

// Caller holds the sibling config .lock for every read/validate/backup/replace.
async function synchronize(options, catalog, dryRun) {
  const old = await readScopedConfig(options);
  const config = buildConfig(scopedConfigInput({ ...old.scope, catalog }));
  const changed = !isDeepStrictEqual(old.config, config);
  if (!dryRun && changed) {
    await publishPrivate(`${old.configFile}.bak-${randomUUID()}`, old.text);
    await publishPrivate(old.configFile, `${JSON.stringify(config, null, 2)}\n`);
  }
  // Never print the provider block, references, routes, paths, or resolved env.
  return { dryRun, changed, activationRequired: true,
    activation: 'requires coordinated same-SID activation; no reload or restart performed',
    schemaVersion: catalog.schemaVersion,
    models: catalog.models.map(({ id, providerID, api, contextWindow, maxTokens, input, output, tools, reasoning, thinking }) =>
      ({ id, providerID, api, contextWindow, maxTokens, input, output, tools, reasoning, thinking })),
    excluded: catalog.excluded.map(({ id, reason }) => ({ id, reason })) };
}

async function inputJSON() {
  const chunks = []; let size = 0;
  for await (const chunk of process.stdin) {
    size += chunk.length;
    requireValue(size <= MAX_BYTES); chunks.push(chunk);
  }
  return JSON.parse(Buffer.concat(chunks).toString('utf8'));
}

async function main() {
  const args = process.argv.slice(2);
  const dryRun = args.includes('--dry-run');
  const locked = args.includes('--locked');
  const selectionMode = args.includes('--validate-selection');
  const values = new Map();
  for (let i = 0; i < args.length; i++) {
    if (['--dry-run', '--locked', '--validate-selection'].includes(args[i])) continue;
    requireValue(['--workspace-dir', '--agent', '--plugin-file', '--base-url'].includes(args[i])
      && !values.has(args[i]) && i + 1 < args.length);
    const key = args[i++]; values.set(key, args[i]);
  }
  requireValue(values.size === 4);
  const options = { workspaceDir: values.get('--workspace-dir'), agent: values.get('--agent'),
    pluginFile: values.get('--plugin-file'), baseURL: values.get('--base-url') };
  const input = await inputJSON();
  if (selectionMode) {
    requireValue(!dryRun && !locked && await validateScopedSelection(options, input));
    return;
  }
  if (dryRun || locked) {
    process.stdout.write(`${JSON.stringify(await synchronize(options, input, dryRun))}\n`);
    return;
  }
  const { configFile } = await readScopedConfig(options);
  const lock = await open(`${configFile}.lock`, constants.O_WRONLY | constants.O_CREAT | constants.O_NOFOLLOW | constants.O_NONBLOCK, 0o600);
  try {
    const stat = await lock.stat();
    requireValue(stat.isFile() && privateMode(stat));
    const child = spawn('bash', ['-c', 'flock --exclusive --timeout 10 3 && exec "$@"', 'cel-opencode-sync', process.execPath,
      process.argv[1], ...args, '--locked'], { stdio: ['pipe', 'inherit', 'inherit', lock.fd] });
    child.stdin.on('error', () => {});
    child.stdin.end(JSON.stringify(input));
    const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
    requireValue(code === 0);
  } finally { await lock.close(); }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main().catch(() => {
    console.error('OpenCode catalog sync refused: scope/config/catalog unavailable, unsafe, or non-canonical');
    process.exitCode = 1;
  });
}
