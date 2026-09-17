// The terminal modes the console turns on, and - the whole point of this file -
// the single place that turns them off again.
//
// Two modes, one lifetime. The alternate screen (\x1b[?1049h) is what makes the
// console fill the terminal like htop or vim: nothing it draws lands in the
// scrollback, and quitting hands the operator back the screen they had.
// SGR mouse reporting is what makes rows clickable. Both are terminal STATE,
// not output: a process that sets them and dies without clearing them leaves
// the operator in a terminal that will not let them select text and shows them
// a screen they cannot scroll back from, with no clue that the cure is
// `printf '\e[?1049l\e[?1000l'`.
//
// So every exit path goes through one `leave`: a clean exit, Ctrl+C, SIGTERM
// from the pane being closed, a SIGHUP, and an uncaught throw. It is injectable
// (write, proc, exit) for exactly one reason - so a unit test can prove the
// pairs are emitted in order on each of those paths without needing a terminal
// or a signal the test runner would then have to survive.
import { MOUSE_ON, MOUSE_OFF } from './mouse.mjs';

export const ALT_ON = '\x1b[?1049h';
export const ALT_OFF = '\x1b[?1049l';

// Order matters in both directions: switch screens first so the mouse is
// enabled on the screen that will use it, and give the mouse back before
// switching away, so the mode is cleared while the terminal still has our
// screen selected.
export const ENTER = `${ALT_ON}${MOUSE_ON}`;
export const LEAVE = `${MOUSE_OFF}${ALT_OFF}`;

export const enterTerminal = ({
  write,
  proc = process,
  exit = (code) => proc.exit(code),
  onError = () => {},
} = {}) => {
  let left = false;
  write(ENTER);

  // Idempotent: the exit handler and the explicit restore on unmount both fire
  // on a normal quit, and writing LEAVE twice would clear a mode the operator's
  // NEXT program had just set.
  const leave = () => {
    if (left) return;
    left = true;
    try { write(LEAVE); } catch { /* the pipe is gone; nothing left to restore */ }
  };

  const bye = (code) => { leave(); exit(code); };
  const onExit = () => leave();
  const onTerm = () => bye(143);
  const onInt = () => bye(130);
  const onHup = () => bye(129);
  const onUncaught = (err) => { leave(); onError(err); exit(1); };

  proc.on('exit', onExit);
  proc.on('SIGTERM', onTerm);
  proc.on('SIGINT', onInt);
  proc.on('SIGHUP', onHup);
  proc.on('uncaughtException', onUncaught);

  return () => {
    leave();
    proc.off('exit', onExit);
    proc.off('SIGTERM', onTerm);
    proc.off('SIGINT', onInt);
    proc.off('SIGHUP', onHup);
    proc.off('uncaughtException', onUncaught);
  };
};
