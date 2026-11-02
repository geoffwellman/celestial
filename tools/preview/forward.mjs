// cel preview's localhost forward: node forward.mjs <port> <host>
// The preview listens on the box's tailnet address; a remote client that
// reaches the box over ssh (Moshi forwards the box's localhost) needs the same
// port on 127.0.0.1. Byte-for-byte TCP, one upstream connection per client.
// It waits up to ~30 min for the app to answer on <host>:<port> before taking
// 127.0.0.1 - grabbing it first would make an app that binds every interface
// fail with EADDRINUSE. An app that never answers gets no forward: this says
// so on stderr (the unit's journal) and exits 1 rather than accept clients
// it can only drop. CEL_PREVIEW_FORWARD_TRIES / _DELAY_MS shorten the wait.
// When 127.0.0.1:<port> is taken - the app bound every interface - there is
// nothing to forward, and this exits quietly.
import net from 'node:net';

const [port, host] = [Number(process.argv[2]), process.argv[3]];
if (!port || !host) { console.error('usage: forward.mjs <port> <host>'); process.exit(2); }

const tries = Number(process.env.CEL_PREVIEW_FORWARD_TRIES) || 1800;
const delay = Number(process.env.CEL_PREVIEW_FORWARD_DELAY_MS) || 1000;
// one attempt is bounded too: a tailnet address that drops SYNs never errors
const answers = () => new Promise((ok) => {
  const s = net.connect(port, host);
  s.setTimeout(delay, () => { s.destroy(); ok(false); });
  s.once('connect', () => { s.destroy(); ok(true); });
  s.once('error', () => ok(false));
});
let ready = false;
for (let i = 0; i < tries && !(ready = await answers()); i++) await new Promise((r) => setTimeout(r, delay));
if (!ready) {
  console.error(`cel preview forward: ${host}:${port} never answered in ${Math.round((tries * delay) / 1000)}s - not forwarding 127.0.0.1:${port}`);
  process.exit(1);
}

const server = net.createServer((client) => {
  const up = net.connect(port, host);
  client.pipe(up); up.pipe(client);
  const end = () => { client.destroy(); up.destroy(); };
  client.on('error', end); up.on('error', end);
  client.on('close', end); up.on('close', end);
});
server.on('error', (e) => {
  if (e.code === 'EADDRINUSE') process.exit(0);
  console.error(`cel preview forward: ${e.message}`); process.exit(1);
});
server.listen(port, '127.0.0.1');
