// Read the exact installed Pi package's published Codex model metadata.
// No provider initialization, credentials, auth refresh, or network requests.
import { readFileSync, realpathSync } from 'node:fs';
import path from 'node:path';
import { createRequire } from 'node:module';

const cli = realpathSync(process.argv[2]);
let dir = path.dirname(cli), root;
while (dir !== path.dirname(dir)) {
  try {
    const pkg = JSON.parse(readFileSync(path.join(dir, 'package.json'), 'utf8'));
    if (pkg.name === '@earendil-works/pi-coding-agent') { root = dir; break; }
  } catch { /* not the package root */ }
  dir = path.dirname(dir);
}
if (!root) throw new Error('Cannot locate the installed @earendil-works/pi-coding-agent package');
const require = createRequire(path.join(root, 'package.json'));
const ai = path.dirname(require.resolve('@earendil-works/pi-ai'));
const data = JSON.parse(readFileSync(path.join(ai, 'providers/data/openai-codex.json'), 'utf8'));
const fields = ['id', 'name', 'contextWindow', 'maxTokens', 'reasoning', 'thinkingLevelMap', 'input', 'inputLimits', 'compat'];
const models = Object.values(data).flatMap((group) => Object.values(group))
  .filter((model) => model.type === 'chat' && typeof model.id === 'string')
  .map((model) => Object.fromEntries(fields.filter((key) => key in model).map((key) => [key, model[key]])));
process.stdout.write(JSON.stringify(models) + '\n');
