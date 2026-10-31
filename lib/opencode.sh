# shellcheck shell=bash
# OpenCode compatibility is launch-scoped. The caller chooses an evidenced
# account route and writes a product/agent config; global OpenCode state stays put.
[ -n "${_CEL_OPENCODE:-}" ] && return 0
_CEL_OPENCODE=1

opencode_validate_config() { # tag rolefile configfile [expected-baseURL]; read-only
  local tag="$1" rolefile="$2" configfile="$3" base="${4:-}"
  [[ "$tag" =~ ^[a-zA-Z0-9_-]+$ && "$rolefile" = /* && "$configfile" = /* ]] || { printf 'OpenCode requires an explicit tag and absolute scoped paths\n' >&2; return 1; }
  if [ -z "$base" ]; then
    declare -F gateway_url >/dev/null || { printf 'OpenCode validation requires the canonical gateway URL\n' >&2; return 1; }
    base="$(gateway_url)/v1" || return 1
  fi
  node "$CEL_ROOT/tools/opencode/config.mjs" --validate "$configfile" "cel-$tag" "$rolefile" "$CEL_ROOT/tools/opencode/plugin" "$base"
}

opencode_validate_session() { # native-id cwd scoped-agent [wsdir]; never start a server or migrate storage
  # Pinned native contracts: v2.2.5 cli/src/database-path.ts,
  # core/src/session/sql.ts and core/src/database/v1-migration.bun.ts.
  local session="$1" cwd="$2" agent="$3" wsdir="${4:-}"
  [[ "$session" =~ ^ses_[A-Za-z0-9]+$ && "$cwd" = /* && "$agent" =~ ^cel-[a-zA-Z0-9_-]+$ ]] || return 1
  (
    # Rex loads this same overlay before launching the child. Resolve storage
    # against it, not against a stale controller environment or another HOME.
    if [ -n "$wsdir" ] && [ -f "$wsdir/workspace.yaml" ]; then
      local exports
      exports="$(ws_env_exports "$wsdir")" || exit 1
      eval "$exports" >/dev/null 2>&1 || exit 1
    fi
    cd -- "$cwd" || exit 1
    python3 - "$session" "$cwd" "$agent" <<'PY'
import json, os, pathlib, sqlite3, sys

try:
    session, cwd, agent = sys.argv[1:]
    directory = str(pathlib.Path(cwd).resolve(strict=True))
    if os.path.abspath(cwd) != directory:
        raise ValueError("native location alias mismatch")
    data = pathlib.Path(os.environ.get("XDG_DATA_HOME") or pathlib.Path.home() / ".local/share") / "opencode"
    # Verified official 2.2.5 asset: isolated `debug paths` reports this data
    # directory and opencode.db with neither OPENCODE_DB nor the channel-DB
    # override set. Do not infer an embedded channel from the package name.
    filename = os.environ.get("OPENCODE_DB", "opencode.db")
    if filename == ":memory:":
        raise ValueError("ephemeral native store")
    database = (data / filename).resolve(strict=True)
    # Python's read-only SQLite URI preserves the native WAL-backed view; do
    # not use immutable=1, which can silently ignore uncheckpointed sessions.
    with sqlite3.connect(database.as_uri() + "?mode=ro", uri=True, timeout=2) as db:
        db.execute("PRAGMA query_only = ON")
        db.execute("BEGIN")
        tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
        if "session_v2" not in tables or "kv" not in tables:
            raise ValueError("native schema unavailable")
        state = db.execute("SELECT value FROM kv WHERE key = ?", ("migration.v1-v2",)).fetchone()
        state = json.loads(state[0]) if state else None
        if state is not None and (not isinstance(state, dict) or state.get("phase") != "completed"):
            raise ValueError("native migration pending")
        # V1Migration.status requires completion whenever the legacy table
        # exists, even if it happens to be empty. Never trigger that migration.
        if "session" in tables and (state is None or state.get("phase") != "completed"):
            raise ValueError("legacy migration required")
        row = db.execute("SELECT parent_id, directory, workspace_id, agent, model FROM session_v2 WHERE id = ?", (session,)).fetchone()
        if row is None:
            raise ValueError("native session absent")
        parent, stored_directory, workspace, stored_agent, stored_model = row
        model = json.loads(stored_model)
        if parent is not None or workspace is not None or stored_agent != agent:
            raise ValueError("native root identity mismatch")
        if stored_directory != directory:
            raise ValueError("native location mismatch")
        if model != {"providerID": "ompgw-codex", "id": "gpt-6.1-sol", "variant": "medium"}:
            raise ValueError("native model mismatch")
except Exception:
    # Database/parser exceptions can embed stored content. Emit no excerpts.
    print("OpenCode existing native v2 root is unavailable, mismatched, or requires migration", file=sys.stderr)
    sys.exit(1)
PY
  )
}

opencode_agent_args() { # tag body dry rolefile configfile [expected-baseURL] -> AGENT_ARGS, AGENT_ROLE_FILE
  local tag="$1" body="$2" dry="$3" rolefile="$4" configfile="$5"
  [[ "$tag" =~ ^[a-zA-Z0-9_-]+$ ]] || { printf 'invalid OpenCode role tag\n' >&2; return 1; }
  [[ "$rolefile" = /* && "$configfile" = /* ]] || { printf 'OpenCode requires scoped absolute role/config paths\n' >&2; return 1; }
  if [ "$dry" -eq 0 ]; then
    # Config generation is the parent's product-scoped operation, not a side
    # effect of launch. Refuse before changing a role if it was not prepared.
    opencode_validate_config "$tag" "$rolefile" "$configfile" "${6:-}" || return 1
    mkdir -p "$(dirname "$rolefile")" || return 1
    (umask 077; printf '%s\n' "$body" > "$rolefile") || return 1
  fi
  # v2 selects both agent and model from the scoped configuration.
  AGENT_ARGS=()
  AGENT_ROLE_FILE="$rolefile"
  CEL_OPENCODE_CONFIG_FILE="$configfile"
  CEL_OPENCODE_AGENT="cel-$tag"
}

opencode_launch_guard() { # configfile -> guard before the shared env prefix
  local file="$1" quoted
  [[ "$file" = /* ]] || return 1
  printf -v quoted '%q' "$file"
  printf '_cel_opencode_config="$(cat -- %s)" && [ -n "$_cel_opencode_config" ] && ' "$quoted"
}

opencode_launch_env() { # append to the shared env prefix, after its guard
  # CONTENT merges after global/project configuration; CONFIG alone does not.
  # The private config contains env references, not credential values.
  printf 'OPENCODE_CONFIG_CONTENT="$_cel_opencode_config" '
  printf 'CEL_OPENCODE_AGENT=%q ' "${CEL_OPENCODE_AGENT:-}"
}

opencode_launch_command() { # append after env assignments, before native executable
  printf 'node %q -- ' "$CEL_ROOT/tools/opencode/launch.mjs"
}

opencode_write_config() { # destination; reads buildConfig input JSON on stdin
  local file="$1" tmp
  [[ "$file" = /* ]] || return 1
  mkdir -p "$(dirname "$file")" || return 1
  tmp="$(mktemp "$(dirname "$file")/.opencode-config.XXXXXX")" || return 1
  if ! node "$CEL_ROOT/tools/opencode/config.mjs" > "$tmp"; then rm -f "$tmp"; return 1; fi
  chmod 600 "$tmp" && mv "$tmp" "$file"
}
