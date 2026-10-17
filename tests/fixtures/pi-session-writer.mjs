// A live Pi writer, then another harness starting in its own root, then Pi
// writing again. Exits 0 only when Pi's second append reached the SAME file.
// Isolated use only: HOME, the agent roots and cwd are all fixtures.
//   node pi-session-writer.mjs <pi-package-dir> <cwd> <other-start-shell-line>
import { spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";
const [pkg, cwd, other] = process.argv.slice(2);
const { SessionManager } = await import(`${pkg}/dist/index.js`);
const msg = (t) => ({ role: "user", content: [{ type: "text", text: t }], timestamp: Date.now() });
const sm = SessionManager.create(cwd);
sm.appendMessage(msg("first"));
const file = sm.getSessionFile();
const id = sm.getSessionId();
const before = readFileSync(file);
const r = spawnSync("bash", ["-c", other], { cwd: `${cwd}-other`, encoding: "utf8", timeout: 60000 });
let err = "";
try { sm.appendMessage(msg("second")); } catch (e) { err = `${e.code} ${e.path}`; }
const text = (() => { try { return readFileSync(file, "utf8"); } catch { return ""; } })();
let prefixKept = false;
try { prefixKept = createHash("sha256").update(readFileSync(file).subarray(0, before.length)).digest("hex") === createHash("sha256").update(before).digest("hex"); } catch {}
console.log(JSON.stringify({ file, id, prefixKept, other: r.status, err, first: text.includes("first"), second: text.includes("second") }));
process.exit(err ? 1 : 0);
