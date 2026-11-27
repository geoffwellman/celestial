# Gateway — several subscriptions behind one door

One Codex or Claude subscription maxes out. `cel gateway` puts **all of them**
behind one loopback door and spreads agents across them, and shows what each
one has left.

```bash
cel gateway install          # CLIProxyAPI as one box service, loopback only (--no-start)
cel gateway status           # one row per account: provider, id, plan, email
cel gateway login claude     # sign another subscription in (--no-browser: device flow)
cel gateway logout <provider> <id>
cel gateway panel            # the loopback management panel's URL and an ssh -L tunnel
cel gateway refresh          # re-apply config, service and pi/omp model registrations (cel update runs it)
cel gateway rotate-key       # a client-key rotation: accepted keys, old-key holders, restart plan
```

Under it is **one** process, `cli-proxy-api`: it is both the credential vault —
one OAuth JSON per account in a `0700` auth-dir under the box state directory,
never inside a repo — and an OpenAI/Anthropic-shaped surface on `127.0.0.1`
that mints the OAuth itself and picks an account **by session key**. It
replaced omp's broker + gateway pair, under which every agent queued on one
account, so one hitting its five-hour limit stalled the rest while another
account sat at 16%. omp is still installed — it is an agent runtime — but
nothing under `cel gateway` calls it.

`cel gateway install` writes the proxy's `config.yaml` with settings that are
not negotiable: `host: 127.0.0.1`, because one api-key unlocks every
subscription in the vault; `routing.session-affinity: true` (TTL 1h), because
it defaults to **false** and false means an agent switches account
mid-conversation; a management API with `allow-remote: false` and its own
secret in `<state>/management-key` (0600), so the web panel answers on
loopback only; and an auth-dir in the box state dir. Health is
`GET /healthz`, unauthenticated.

**Every request carrying a gateway secret goes direct.** curl honours
`http_proxy`/`HTTPS_PROXY`/`ALL_PROXY` even for `127.0.0.1` unless told
otherwise, which would hand a proxy the api-key or the management key. So
every such curl - model listings, rotate-key probes, management reads,
loopback service health checks with a bearer - runs with the proxy variables
unset, `--noproxy '*'`, and `--disable` as its first argument so a
`~/.curlrc` cannot add a proxy or a header. The bearer rides curl's stdin,
never its argv.

A profile reaches it with one field:

```yaml
worker_profiles:
  gw: { runtime: pi, model: gpt-6.1-sol, via: gateway }
```

For Pi profiles, `cel run <role> --profile gw` writes the gateway's providers
into pi's own agent dir, `~/.pi/agent/models.json` by default (merged — the
owner's other providers are untouched, and the model list comes from the
gateway's own `/v1/models`, with plain ids: Claude models go through pi's
`anthropic-messages` surface, Codex-family models (`gpt-`, `codex-`, `o<n>`)
through `openai-responses`, and other ids are not registered; the provider
sends `x-session-id` from `CEL_SESSION_ID`). Every gateway launch passes `OMP_GATEWAY_TOKEN`
and `CEL_SESSION_ID` as `env K=V` words on the launch line, scoped to the
launched process - nothing is exported into the pane's shell, so a later command
in that pane never inherits one agent's session key. Pi resolves its key there
and the generated provider stores only the variable name. Each agent uses its
own alias as the session affinity key.

**Pi and OMP never share an agent root.** Both read `PI_CODING_AGENT_DIR`, and
OMP's startup renames every Pi-style `--home-...--` session directory under its
root, with no check that a Pi process is live; Pi never re-creates a vanished
directory, so its later session writes fail (this lost the unsaved tail of two
live agents on 2026-10-17). Every launch therefore *pins* the launched
runtime's own resolved root - Pi `~/.pi/agent`, OMP `~/.omp/agent` - and an
inherited `PI_CODING_AGENT_DIR` is ignored, never forwarded. Pi gets it as
`PI_CODING_AGENT_DIR`. OMP's own default root is not exported at all (an
inherited value is removed with `env -u`): anything in OMP's environment is in
every child it runs, and a `pi` or `rea setup --client pi` from core's shell
used to take OMP's root for Pi's. Deliberate custom roots are explicit:
`CEL_PI_AGENT_DIR` (Pi) and `CEL_OMP_AGENT_DIR` (OMP; OMP takes a custom root
only from the variable, so its children inherit that one). The same resolution feeds
the models writers, the child's environment and `cel doctor`. If the two roots
overlap - equal, aliased by symlink, or one inside the other - the launch is
refused (and `cel doctor` fails) with the roots named; nothing is moved.
This is prevention only: it does not repair a session already relocated, and a
running process keeps its old environment. Never start OMP against a root that
holds a live Pi's sessions; recovery of an already-affected agent belongs to the
retained-runtime lifecycle (explicit session file selection), not to a launch fix.

Three things are worth knowing before you rely on it:

- **Affinity defaults off upstream.** The config this writes turns it on; a
  hand-edited config that loses the line gives every agent a different account
  from turn to turn, which is worse than one account.
- **The proxy reports no usage; Celestial reads it.** CLIProxyAPI keeps no
  usage accounting, so `cel quota` reads each vault account's windows from
  the provider with that account's stored access token, never refreshing it.
  An expired one reads `token stale` or `needs login`, never 0%.
- **One api-key grants every subscription in the vault** to anything that can
  reach the port. The service binds loopback only, the config is `0600`, and
  nothing prints the key.

**Rotating the client key (owner only).** A running agent keeps the key it
was launched with, so the key is replaced in stages, with no downtime:

```bash
cel gateway rotate-key --stage    # mint a new key; the gateway accepts old + new; new launches get the new key
cel gateway rotate-key --status   # who still holds the old key (name, pid) and the exact restart for each
cel gateway rotate-key --finish   # refused while anyone holds the old key (--force cuts them off); old -> 401
cel gateway rotate-key --abort    # before --finish: the old key becomes the only key again
```

`--stage` checks that both keys get HTTP 200 from `/v1/models` before
`api-key` changes. The old key waits in `api-key.previous` until `--finish`,
which confirms the old key now gets 401 and the new one 200. Restart the
holders in the order `--status` prints, with root and core last. Reviewers
finish their round on their own. Holders are matched by the sha256 of the
key in their `/proc` environment, and no key value is ever printed. Staging,
finishing and aborting are refused to agents. Run them from your own shell.
Any agent may read `--status`.

**The pinned release has a floor: 8.0.22.** `agents.yaml` pins CLIProxyAPI
8.0.29. Releases before 8.0.22 can bench a Claude account until the monthly
billing reset after a single 429 that carries an overage claim (upstream
#6465), so on a box with several accounts the pool shrinks for weeks. A
scratch run confirmed it: 7.3.14 never went back to the account inside 60s,
while 8.0.29 went back after the 3s Retry-After plus jitter. The config this
writes is unchanged. v8 reads the legacy layout as it is and does not rewrite
it on load, and the account files keep their names. Bumping the pin does
**not** upgrade a box that already has the gateway: setup keeps any base tool
already on `PATH`. Moving a box over is a deliberate step:

```bash
CEL_ROOT=<checkout> bash -c '. "$CEL_ROOT/lib/common.sh"; . "$CEL_ROOT/lib/install.sh"; install_pinned_binary base_tools cli-proxy-api'
cel services restart cel-auth-gateway
```

To roll back, copy the 7.3.14 binary back over `~/.local/bin/cli-proxy-api`
and restart the service. Restore the vault only if it is damaged, because
OAuth refresh tokens rotate and an old copy of a file holds tokens that are
already retired.

Its accounts land in the same places the signed-in
[subscriptions](profiles.md#subscriptions) do: the
QUOTA view's `via gateway` section, the dashboard's Subscriptions card, and
`cel gateway status --json` - one row per account, carrying `source: gateway`.
