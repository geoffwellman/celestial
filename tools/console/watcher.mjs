// The watcher the console arms, and the single place that takes it away again.
//
// `cel inbox watch` is the DELIVERY PATH, not a nicety: it is what raises the
// desktop notification for a decision or a blocker while the operator is
// looking at another tab. It is also, as of a walk of the box on 2026-09-19,
// the most-littered process on it: thirteen `cel inbox watch --for root
// --all-workspaces` trees reparented to init, four of them days old, one per
// console that had ever exited. Two reasons, both fixed here.
//
// FIRST, `child.kill()` ON A REACT CLEANUP IS NOT AN EXIT PATH. It runs on a
// clean unmount and on nothing else - not Ctrl-C, not the SIGTERM a closing
// pane sends, not an uncaught throw - which is exactly the discipline term.mjs
// already owns for the screen modes. So the lifetime lives here, with the same
// shape and the same injectability, and every path goes through one `stop`.
//
// SECOND, KILLING THE CHILD IS NOT KILLING THE WATCH. The watcher is a bash
// process running `tail -F | jq` per workspace; signalling the bash alone
// leaves the pipeline holding the mailbox. So it is spawned DETACHED - its own
// process group - and the group is what gets the signal.
const WATCH_ARGS = ['inbox', 'watch', '--for', 'root', '--all-workspaces'];

export const startWatcher = ({
  bin,
  spawn,
  proc = process,
  kill = (pid, sig) => process.kill(pid, sig),
  onLine = () => {},
  onError = () => {},
} = {}) => {
  // And the watcher is told which console owns it, so it can leave on its own
  // if this process dies in a way that runs no handler at all (SIGKILL, a
  // pty host that vanishes). Belt and braces: four of the thirteen were days
  // old, which is how long a missed kill lasts without it.
  const child = spawn(bin, [...WATCH_ARGS, '--parent', String(proc.pid)],
    { stdio: ['ignore', 'pipe', 'ignore'], detached: true });

  let stopped = false;
  const stop = () => {
    if (stopped) return;
    stopped = true;
    try {
      if (child.pid) kill(-child.pid, 'SIGTERM');
      else child.kill();
    } catch { /* already gone: the only outcome this wanted anyway */ }
  };

  let buf = '';
  child.stdout?.on('data', (chunk) => {
    buf += chunk;
    const parts = buf.split('\n');
    buf = parts.pop() || '';
    for (const line of parts) if (line.trim()) onLine(line);
  });
  child.on?.('error', (e) => onError(e));

  const onExit = () => stop();
  const onSignal = () => stop();
  const onUncaught = () => stop();
  proc.on('exit', onExit);
  proc.on('SIGTERM', onSignal);
  proc.on('SIGINT', onSignal);
  proc.on('SIGHUP', onSignal);
  proc.on('uncaughtException', onUncaught);

  return () => {
    stop();
    proc.off('exit', onExit);
    proc.off('SIGTERM', onSignal);
    proc.off('SIGINT', onSignal);
    proc.off('SIGHUP', onSignal);
    proc.off('uncaughtException', onUncaught);
  };
};
