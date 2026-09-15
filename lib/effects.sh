# shellcheck shell=bash
# cel effects - optional Canvas UI page effects for the dashboard.
#
# Canvas UI (canvasui.dev) is MIT + Commons Clause: using it is fine,
# REDISTRIBUTING it is not, and this repo is public. So nothing of theirs is
# committed here. `cel effects install` fetches the components onto THIS BOX
# (~/.local/share/cel/vendor/canvasui), transpiles them with bun, and the
# dashboard serves them from there - the same shape externals.yaml uses for
# herdr plugins: the repo carries the recipe, each box installs its own copy.
#
# Two caveats, both by their design, not ours:
#   - the components paint your live DOM through the EXPERIMENTAL
#     HTML-in-Canvas API (ctx.drawElementImage / canvas.requestPaint), so they
#     render in Chrome with that enabled and no-op everywhere else. The
#     dashboard therefore treats them as PROGRESSIVE: absent or unsupported
#     falls back to the built-in canvas sky, which works in every browser.
#   - the registry does not ship the `../rect-cache` module every component
#     imports; tools/dash/effects/rect-cache.ts is ours, written to their
#     call sites.
[ -n "${_CEL_EFFECTS:-}" ] && return 0
_CEL_EFFECTS=1
# shellcheck source=lib/common.sh
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_fx_dir()      { printf '%s' "${CEL_EFFECTS_DIR:-$HOME/.local/share/cel/vendor/canvasui}"; }
_fx_registry() { printf '%s' "${CEL_EFFECTS_REGISTRY:-https://canvasui.dev/r}"; }

# The celestial picks, and why each one:
#   clouds  - drifting nebula over the ground; the dashboard is a night sky
#   glass   - refracts the page behind the cards, like an instrument cover
#   ripple  - pointer wake, so the surface answers when you touch it
_FX_DEFAULT="clouds glass ripple"

_fx_components() { printf '%s' "${CEL_EFFECTS_COMPONENTS:-$_FX_DEFAULT}"; }

cmd_effects() {
  local sub="${1:-status}"; shift 2>/dev/null || true
  case "$sub" in
    install) _fx_install "$@";;
    status)  _fx_status "$@";;
    remove)  rm -rf "$(_fx_dir)" && c_ok "removed $(_fx_dir)";;
    help|--help|-h) cat <<'EOS'
cel effects - optional Canvas UI dashboard effects (installed per box, never vendored)

  cel effects install [name...]   fetch + transpile components (default: clouds glass ripple)
  cel effects status              what is installed
  cel effects remove              delete the local copy

Chrome-only: the components need the experimental HTML-in-Canvas API, which
sits behind its own flag - chrome://flags/#canvas-draw-element, set to Enabled,
then relaunch. NOT the generic "experimental web platform features" flag, which
does not turn this one on. If the flag is missing, the build predates it: use
Chrome Canary. Without it the dashboard falls back to its built-in canvas sky.
EOS
      ;;
    *) die "cel effects: unknown subcommand '$sub'";;
  esac
}

_fx_status() {
  local d; d="$(_fx_dir)"
  if [ ! -d "$d" ]; then
    c_warn "no effects installed - cel effects install"
    return 0
  fi
  local f n=0
  for f in "$d"/*.js; do
    [ -f "$f" ] || continue
    c_ok "$(basename "$f" .js) ($(du -h "$f" | cut -f1 | tr -d ' '))"
    n=$((n+1))
  done
  [ "$n" -gt 0 ] || c_warn "$d is empty - cel effects install"
}

# One bundle per component: fetch the registry item, drop its single .ts file
# next to our rect-cache, and let bun resolve the import and emit browser ESM.
# bun is already a base tool, so this adds no new dependency.
_fx_install() {
  have bun  || die "cel effects: bun is required to transpile the components (it is a base tool - cel setup installs it)"
  have curl || die "cel effects: curl is required"
  have jq   || die "cel effects: jq is required"
  local names="$*"; [ -n "$names" ] || names="$(_fx_components)"
  # Their components live at components/canvasui/X.ts and import
  # "../rect-cache", i.e. components/rect-cache - so the tree has to mirror
  # that or bun cannot resolve the one module they do not ship.
  local d src n item file content entry ok=0
  d="$(_fx_dir)"; src="$d/src/canvasui"
  mkdir -p "$src"
  cp "$CEL_ROOT/tools/dash/effects/rect-cache.ts" "$d/src/rect-cache.ts"

  for n in $names; do
    item="${n}-vanilla"
    if ! content="$(curl -sf -m 30 "$(_fx_registry)/${item}.json")"; then
      c_err "$n: $(_fx_registry)/${item}.json not reachable"
      continue
    fi
    file="$(printf '%s' "$content" | jq -r '.files[0].path // empty' | xargs -r basename)"
    [ -n "$file" ] || { c_err "$n: registry item has no file"; continue; }
    printf '%s' "$content" | jq -r '.files[0].content' > "$src/$file"
    entry="$src/$file"
    if bun build "$entry" --outfile "$d/$n.js" --target browser --format esm >/dev/null 2>&1; then
      c_ok "$n -> $d/$n.js"
      ok=$((ok+1))
    else
      c_err "$n: bun could not transpile $file"
    fi
  done
  [ "$ok" -gt 0 ] || die "cel effects: nothing installed"
  c_warn "Chrome-only: enable chrome://flags/#canvas-draw-element and relaunch (that exact flag - the generic experimental-web-platform-features one does not cover it); other browsers fall back to the built-in sky"
}
