// CEL-36: the half of steering that happens AFTER the console sends.
//
// The complaint this file answers is not that mail did not arrive - it did -
// but that the operator saw nothing afterwards: no acknowledgement, no reply,
// no sign the orchestrator existed ("it doesn't really feel like I can steer
// anything from there", owner). A console that sends into silence is a
// console people stop sending from.
//
// Two things live here, and both are deliberately pure or file-only so they
// can be proved without a terminal: WHICH message counts as the reply, and
// WHICH command a relayed line becomes. The ink around them is in ui.mjs and
// decides nothing.
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir } from 'node:os';

import { shellQuote } from './router.mjs';
import { readConfig } from './translate.mjs';

const INBOX_DIR = () => process.env.CEL_INBOX_DIR || join(homedir(), '.local/share/cel/inbox');

// NINETY SECONDS, and not a minute more by default. The watch holds nothing
// open and blocks nothing - it is a poll in the render loop - but a status
// line that claims to be waiting long after the operator has moved on is a
// lie about what the console is doing. When it expires the inbox tail takes
// over, which is where the reply lands anyway (CEL-7/CEL-20).
export const REPLY_WAIT_DEFAULT = 90;
export const REPLY_POLL_MS = 2000;

export const replyWaitSecs = (configPath) => {
  const cfg = readConfig(configPath);
  const n = Number(cfg.console.reply_wait);
  return Number.isFinite(n) && n > 0 ? n : REPLY_WAIT_DEFAULT;
};

// The addressee's next message to the operator, after the send. Read from the
// mailbox file rather than through `cel inbox read`, exactly as the tail panel
// does (state.mjs): the file is what the command prints, and a poll every two
// seconds should not be two processes every two seconds.
//
// THREE WAYS TO MATCH THE WRONG THING, all of them seen while writing this: an
// older message from the right agent (the one that was already there),
// anything from another agent, and a message the agent addressed to one of its
// workers. Each is excluded below, and each has a test.
export const replyFrom = ({ ws, who, since, dir }) => {
  if (!ws || !who) return null;
  let text;
  try { text = readFileSync(join(dir || INBOX_DIR(), `${ws}.jsonl`), 'utf8'); } catch { return null; }
  const after = Date.parse(since) || 0;
  for (const raw of text.split('\n')) {
    if (!raw.trim()) continue;
    let m;
    try { m = JSON.parse(raw); } catch { continue; }
    if (m.from !== who) continue;
    if (m.to !== 'root' && m.to !== 'console' && m.to !== 'all') continue;
    if ((Date.parse(m.ts) || 0) <= after) continue;
    return { ws, ...m };
  }
  return null;
};

// ONE LINE IN THE STATUS, the whole thing in the detail view. A reply is
// usually a paragraph, and a status line that wraps is a status line that ate
// the legend under it - which is the bug CEL-17 was written to fix.
export const replyLine = (who, msg) =>
  `${who}: ${String((msg && msg.message) || '').split('\n')[0].trim()}`;

export const noReplyLine = (who) => `${who} is working; its reply will land in the inbox`;

// --- the relay --------------------------------------------------------------
//
// `talk <orch>`: the command line becomes a wire to one pane. It is the ONE
// place the console relays a conversation, and the surface it needs is exactly
// two verbs wide - both already on the console's allowlist, so nothing about
// the guard changes for it. A long design discussion still belongs in the pane
// itself; the vocabulary says so and `focus` is how you get there.
export const TALK_LINES = 40;
export const TALK_REFRESH_MS = 2000;

// Single quotes, for the same reason as every other place an operator's own
// words reach a command line (router.mjs): inside double quotes bash still
// expands `$(...)`, and this line is handed to `bash -c`.
export const talkPrompt = (who, text) => `herdr agent prompt ${who} ${shellQuote(text)}`;

// `recent-unwrapped` rather than the wrapped form: the console draws its own
// panel with its own width, and text already wrapped to somebody else's
// columns arrives ragged inside it.
export const talkRead = (who) => `herdr agent read ${who} --source recent-unwrapped`;

// The blank rows a pane ends with are the terminal's, not the agent's, and
// drawing them pushes the last thing it actually said off the top of a short
// panel. Trailing blanks go; the ones between paragraphs stay.
export const paneLines = (text, n = TALK_LINES) => {
  const rows = String(text || '').split('\n').map((l) => l.replace(/\s+$/, ''));
  while (rows.length && rows[rows.length - 1] === '') rows.pop();
  while (rows.length && rows[0] === '') rows.shift();
  return rows.slice(-n);
};

export const talkLegend = (who) => `talking to ${who} - Esc to stop`;
