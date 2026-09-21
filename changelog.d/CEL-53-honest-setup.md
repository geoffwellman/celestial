### Fixed
- **`cel ws` no longer refuses in silence.** `cel ws sync <name>` for a
  workspace that was never registered exited 1 with nothing printed at all -
  the refusal died inside a command substitution. Every name-taking verb
  (`sync`, `push`, `env`, `up`, `down`, `reset`, `status`) now checks the name
  in the caller's own process and says, on stderr, that the workspace is not
  registered and that `cel ws add <git-url>` is what registers it. A path that
  is registered but gone reads differently again.
- **`cel doctor` reads a workspace before judging it.** Each workspace's
  `setup:` checks now run with that workspace's own env loaded
  (`ws_env_exports` in a subshell, so nothing leaks between workspaces), so a
  check for a key that is correctly sitting in `env.local` passes instead of
  printing red at a box that is set up properly. A value that is missing and
  an env that could not be read are two distinct findings.

### Changed
- **One place a secret lives: the workspace's gitignored `env.local`.** The
  setup skill, `cel help`, `cel setup`'s closing hints and the doctor checker
  now all name and read exactly that one location; `~/.zshenv` is documented
  only for a box-wide credential no workspace owns, and says why.
- **`cel doctor` now evaluates each registered workspace's `env.local`** - it
  is sourced, i.e. executed, in a subshell, to judge that workspace's `setup:`
  checks. Previously only `cel ws env` / `cel shellenv` did that, so a
  diagnostic command now runs user-authored shell from every workspace on the
  box. The subshell contains it and nothing leaks back into doctor or into the
  next workspace.
