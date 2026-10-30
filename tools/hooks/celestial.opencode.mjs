// Native server plugin entrypoint for OpenCode 1.19.5. Loaded ONLY by the
// product/agent OPENCODE_CONFIG_CONTENT overlay; never installed globally.
import { createHooks } from '../opencode/runtime.mjs';
export default async function celestialOpenCode(input, options) {
  return createHooks(input, options);
}
