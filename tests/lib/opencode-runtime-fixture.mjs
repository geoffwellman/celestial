import { createServer } from 'node:http';
import { appendFileSync, existsSync, readFileSync, statSync, writeFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import path from 'node:path';

// No provider/model implementation: this fixture exercises only the launch
// admission protocol and the real wrapper's child-process ownership.
export async function runFixture(args = process.argv.slice(2), env = process.env) {
  const record = (event, details = {}) => {
    if (env.CEL_FIXTURE_EVENTS) appendFileSync(env.CEL_FIXTURE_EVENTS, JSON.stringify({ event, pid: process.pid, ...details }) + '\n');
  };
  const config = JSON.parse(env.OPENCODE_CONFIG_CONTENT);
  const directory = process.cwd();
  const native = 'ses_SavedNative';
  if (args[0] === 'serve') {
    if (args.join(' ') !== 'serve --stdio --hostname 127.0.0.1 --port 0') process.exit(2);
    record('serve', { admission: existsSync(env.CEL_OPENCODE_ADMISSION_FILE) });
    const plugin = { id: 'celestial', source: { type: 'local', path: config.plugins[0].package }, features: { server: true }, state: { status: 'active' } };
    let inventories = 0;
    const server = createServer((req, res) => {
      if (req.headers.authorization !== `Basic ${Buffer.from(`opencode:${env.OPENCODE_PASSWORD}`).toString('base64')}`) { res.writeHead(401).end(); return; }
      const url = new URL(req.url, 'http://fixture');
      const scoped = () => url.searchParams.get('location[directory]') === directory;
      record(url.pathname);
      res.setHeader('content-type', 'application/json');
      const json = value => res.end(JSON.stringify(value));
      if (url.pathname === '/api/info') return json({ version: '2.2.5', pid: process.pid });
      if (url.pathname === '/api/plugin') {
        if (!scoped()) { res.writeHead(400).end(); return; }
        inventories++;
        let data = [plugin];
        if (env.CEL_FIXTURE_PLUGIN === 'failed') data = [{ ...plugin, state: { status: 'failed', error: 'fixture-secret-do-not-echo' } }];
        if (env.CEL_FIXTURE_PLUGIN === 'wrong-source') data = [{ ...plugin, source: { type: 'local', path: '/wrong' } }];
        if (env.CEL_FIXTURE_PLUGIN === 'duplicate') data = [plugin, plugin];
        if (inventories === 1 && env.CEL_FIXTURE_PLUGIN === 'delayed') data = [];
        return json({ location: { directory }, data });
      }
      if (url.pathname === '/api/experimental/migration/v1') return json({ status: env.CEL_FIXTURE_MIGRATION ?? 'completed' });
      if (url.pathname === `/api/session/${native}` && env.CEL_FIXTURE_SESSION !== 'missing') return json({ data: { id: native, agent: config.default_agent, location: { directory }, model: { providerID: 'ompgw-codex', id: 'gpt-6.1-sol', variant: env.CEL_FIXTURE_SESSION === 'wrong-medium' ? 'high' : 'medium' } } });
      if (url.pathname === '/api/model') {
        if (!scoped()) { res.writeHead(400).end(); return; }
        const handoff = existsSync(env.CEL_OPENCODE_ADMISSION_FILE) ? JSON.parse(readFileSync(env.CEL_OPENCODE_ADMISSION_FILE, 'utf8')) : undefined;
        const admitted = handoff?.directory === directory && handoff.agent === config.default_agent && handoff.model?.variant === 'medium';
        return json({ location: { directory }, data: admitted ? [{ providerID: 'ompgw-codex', id: 'gpt-6.1-sol', enabled: true, settings: { reasoningEffort: 'medium' }, variants: [{ id: 'medium', settings: { reasoningEffort: 'medium' } }] }] : [] });
      }
      res.writeHead(404).end('{}');
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    console.log(JSON.stringify({ url: `http://127.0.0.1:${server.address().port}` }));
    process.stdin.resume();
    process.stdin.on('end', () => server.close());
    server.once('close', () => record('server-stop'));
    process.on('SIGTERM', () => { record('server-signal'); server.close(); process.stdin.destroy(); });
    return;
  }
  if (args.includes('--standalone') || args.some(arg => ['--agent', '--model', '--thinking', '--extension'].includes(arg)) || !args.includes('--server')) process.exit(2);
  const handoff = JSON.parse(readFileSync(env.CEL_OPENCODE_ADMISSION_FILE, 'utf8'));
  if (handoff.directory !== directory || handoff.agent !== config.default_agent || handoff.model?.variant !== 'medium') process.exit(3);
  record('tui', { args, handoff, mode: statSync(env.CEL_OPENCODE_ADMISSION_FILE).mode & 0o777, directoryMode: statSync(path.dirname(env.CEL_OPENCODE_ADMISSION_FILE)).mode & 0o777 });
  if (env.CEL_REX_STATE) {
    const i = args.indexOf('--session');
    const id = i === -1 ? 'ses_HolderFixture' : args[i + 1];
    // The real native plugin reports for the receipt's proven ancestor, not
    // its server/TUI subprocess. The shared command validates ancestry and
    // the receipt's live PID birth time before accepting this report.
    const receipt = JSON.parse(readFileSync(env.CEL_REX_RECORD, 'utf8'));
    const noted = spawnSync(path.join(env.CEL_ROOT, 'bin/cel'), ['sessions', 'note', String(receipt.pid), 'working', id], { env, stdio: 'ignore' });
    if (noted.status !== 0) process.exit(4);
    writeFileSync(path.join(env.CEL_REX_STATE, 'received-reporter'), JSON.stringify({ holderPID: receipt.pid, childPID: process.pid }));
    writeFileSync(path.join(env.CEL_REX_STATE, 'received-argv'), args.join('\n') + '\n');
    writeFileSync(path.join(env.CEL_REX_STATE, 'received-affinity'), env.CEL_SESSION_ID);
  }
  if (env.CEL_FIXTURE_TUI_EXIT === '1') return;
  const timer = setInterval(() => {}, 1000);
  process.on('SIGTERM', () => { record('tui-stop'); clearInterval(timer); });
}
