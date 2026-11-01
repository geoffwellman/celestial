// Runs only inside the catalog test's private network namespace. Keeping both
// the real curl client and mock server here excludes host port scanners without
// filtering any request from the assertion's evidence.
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import path from 'node:path';

if (process.env.CEL_CATALOG_HTTP_ISOLATED !== '1') throw new Error('private_network_namespace_required');
const [gateway, dir, db] = process.argv.slice(2);
let input = '';
for await (const chunk of process.stdin) input += chunk;
const { status, body } = JSON.parse(input);
const requests = [];
const server = createServer((req, res) => {
  requests.push({ url: req.url, auth: req.headers.authorization });
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(body ?? JSON.stringify({ data: [{ id: 'exact-chat' }, { id: 'unknown' }, { id: 'omp/exact-chat' }] }));
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
try {
  const shell = '. "$1"; _gateway_api_key() { echo FORBIDDEN_AUTH_REPAIR >&2; return 99; }; gateway_url() { printf "http://127.0.0.1:%s" "$PORT"; }; cmd_gateway opencode-models';
  const child = spawn('bash', ['-c', shell, 'fixture', gateway], {
    cwd: dir,
    env: { PATH: `${path.dirname(process.execPath)}:${process.env.PATH}`, HOME: dir, CEL_GATEWAY_STATE: `${dir}/state`, CEL_OMP_AGENT_DIR: db.slice(0, db.lastIndexOf('/')), PORT: String(server.address().port) },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let stdout = '', stderr = '';
  child.stdout.setEncoding('utf8'); child.stderr.setEncoding('utf8');
  child.stdout.on('data', text => { stdout += text; });
  child.stderr.on('data', text => { stderr += text; });
  const code = await new Promise((resolve, reject) => { child.once('error', reject); child.once('close', resolve); });
  process.stdout.write(JSON.stringify({ code, stdout, stderr, requests }));
} finally {
  await new Promise(resolve => server.close(resolve));
}
