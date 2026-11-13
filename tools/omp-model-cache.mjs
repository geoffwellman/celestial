// The OMP model_cache (~/.omp/agent/models.db) schema versions whose per-model
// capability fields the Pi and OpenCode catalog readers understand. ONE list:
// tools/pi/codex-catalog.mjs, tools/opencode/catalog.mjs and
// tools/opencode/model-contract.mjs all import it.
//
// OMP 18.x writes 13 or 14 depending on which binary refreshed the cache last;
// 18.16 writes 15. The fields read here keep their meaning in all three: id,
// name, provider, api, reasoning, input, contextWindow, maxTokens, thinking
// {mode, efforts, supportsDisplay, prefixBinding} and identity.family. Version
// 15 marks a non-chat model with `kind` (e.g. "image") where older rows used
// `type`, so readers treat either as the model's kind.
//
// Any other version is refused, loudly: before adding a number, compare a row
// of that version against these fields.
export const OMP_MODEL_CACHE_VERSIONS = Object.freeze([13, 14, 15]);

// A model_cache version for a refusal message: an integer, never raw cache data.
export const cacheVersionLabel = version => Number.isSafeInteger(version) ? String(version) : 'non-integer';
