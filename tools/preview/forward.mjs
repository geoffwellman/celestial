// cel preview's localhost forward: node forward.mjs <port> <host>
// The preview listens on the box's tailnet address; a remote client that
// reaches the box over ssh (Moshi forwards the box's localhost) needs the same
// port on 127.0.0.1. Byte-for-byte TCP, one upstream connection per client.
// It waits until the app answers on <host>:<port> before taking 127.0.0.1:
// grabbing it first would make an app that binds every interface fail with
// EADDRINUSE. When 127.0.0.1:<port> is then taken - the app bound every
// interface - there is nothing to forward, and this exits quietly.
import net from 'node:net';

const [port, host] = [Number(process.argv[2]), process.argv[3]];
if (!port || !host) { console.error('usage: forward.mjs <port> <host>'); process.exit(2); }

const answers = () => new Promise((ok) => {
  const s = net.connect(port, host);
  s.once('connect', () => { s.destroy(); ok(true); });
  s.once('error', () => ok(false));
});
for (let i = 0; i < 1800 && !(await answers()); i++) await new Promise((r) => setTimeout(r, 1000));

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
