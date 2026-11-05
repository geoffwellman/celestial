# Recurring disk headroom controller

`tools/disk-headroom/controller.py` runs existing owner-approved handlers in order: producer release drain, ordinary manifest drain, preservation retirement, then the safe Docker-only sweep. It orchestrates existing deletion handlers; it does not infer new cleanup grants. The target is **20 GiB available to this user on `/`**, measured with `statvfs.f_bavail * f_frsize`, not root-reserved free blocks.

The controller is not a capacity promise. A full recovery/monitor pass stops before the next handler once available space reaches 20 GiB. If the target cannot be reached, durable status reports the remaining byte deficit. The explicit daily preservation-retirement trigger is preventive maintenance: it may run while the floor is already met so the helper has room to archive safely. Sessions, media, evidence, databases, unpublished gate runs, tracing files and rollback prerequisites never become eligible merely because the disk is low.

## Bounds and serialization

- A nonblocking `flock` at `~/.local/state/cel-disk-headroom/lock` spans each pass, including diagnostics and confirmed message enqueue. Competing invocations exit **75**, not threshold success. Handler subprocesses inherit the descriptor; the parent closes rather than explicitly unlocking it.
- A pass has a 2,400-second monotonic command deadline. **The last 120 seconds are reserved before every handler child dispatch**, including Docker capability lookup and mutation. Individual handlers receive at most 650 seconds, capped by that earlier work deadline. Timed-out process groups are killed; reaping gets at most five additional seconds, inside the control-plane reserve. Diagnostics need at most two 15-second commands; each notification has a 30-second bound. Installed `TimeoutStartSec=2460` and `KillMode=control-group` provide an independent outer service bound.
- Work that cannot be dispatched before the work deadline gets an explicit `skipped` producer status and next retry. A timeout is incomplete work, not proof that approved reclaim was exhausted. The remaining control-plane time stays available for diagnostics, lane messages and emergency escalation.
- `cel-disk-monitor.service` becomes the controller entry point through a drop-in. Its existing timer remains the recurring scheduler; no new timer is created. Existing release/ordinary/retire service entry points use the same controller lock. Release, ordinary and Docker single-handler triggers skip dispatch when already at the floor. The explicit `handler preservation-retire` daily trigger still dispatches above the floor through the same reviewed adapter, timeout and helper guards. Healthy full monitor passes never dispatch reclaim. Standalone scripts and timers remain intact.
- Managed services set `SuccessExitStatus=75`: expected overlap does not mark systemd failed, but the controller still prints the contention reason and returns 75. This means **another pass owns the lock**, not that the floor was reached. Read `status.json` for the owning pass's actual result. Other failure/deficit exit codes remain non-successful.
- Direct standalone-script invocation bypasses the controller lock. Parent deployment must quiesce manual lane invocations too. After migration, use services or `cel-disk-headroom handler NAME`, not the original binaries directly.
- Serialization is not global: the six-hour steward Docker sweep and this controller's Docker-only consumer share the separate Docker image lock; steward cache/“ours” sweeps remain independent. Deltas therefore remain observed windows, not exclusive reclaim attribution.

## Explicit reviewed adapter gates

The owner-controlled regular file `~/.config/cel/disk-headroom.json` has schema version 1. Group/world-writable files and unknown configuration keys/versions are refused. The installer records explicitly supplied review pins; it never treats current installed bytes as automatic approval.

```json
{
  "version": 1,
  "cel": "<absolute runtime-resolved cel executable>",
  "cel_sha256": "<reviewed executable SHA256>",
  "docker_runtime_sha256": "<reviewed Docker CLI runtime digest>",
  "release_queue_issuer": "<exact reviewed producer identity>",
  "follow_main_issuer": "<optional exact reviewed follow-main identity>",
  "handler_sha256": {
    "release-drain": "<reviewed SHA256>",
    "ordinary-drain": "<reviewed SHA256>",
    "preservation-retire": "<reviewed SHA256>"
  },
  "retire_notification_version": 1,
  "docker_opt_in": false
}
```

`release_queue_issuer` is required, nonempty operator configuration. Parent supplies the exact existing producer identity privately through `--release-queue-issuer`; no producer name is embedded in public source or fixtures, and the identity is never inferred from the queue itself. Missing configuration is a real failure. A queue whose issuer differs from the configured string (including case differences) is rejected, preserving exact issuer acceptance rather than widening it.

`follow_main_issuer` is optional and independent of the release queue identity. Without it, old version-1 configurations continue working and follow-main remains `missing-adapter`. Parent may supply the reviewed private identity through `--follow-main-issuer "$REVIEWED_FOLLOW_MAIN_ISSUER"`; no private identity is embedded in source or fixtures, and the manifest cannot select its own trust identity. A present null, empty, whitespace-only, non-string, control-character-containing or over-256-character value fails configuration loading before handlers dispatch. Omit the option when not configured; the installer never infers it from a previous config or the producer.

The follow-main observer reads only `~/.cache/slot-builder-iso/follow-main-manifest.json` (at most 64 KiB), through owner-owned nonsymlink directories and a nonsymlink regular file. Foreign-owned directories and foreign-owned or group/world-writable regular metadata files are refused; ordinary owner-owned group-writable source directories remain compatible. It accepts integer schema version 1, the exact configured issuer, and an explicit UTC ISO timestamp no older than 600 seconds (at most 60 seconds of future clock skew). Duplicate JSON keys, unknown/missing fields, duplicate retained refs/candidates and malformed/stale facts are `blocked`, never successful observations. A configured but absent manifest is also `blocked`; omission of the configuration remains `missing-adapter`.

Live and optional rollback refs pair a direct `~/code/slot-studio-wt/local-<12-or-40-lowercase-hex>` worktree with its matching `slot-studio-local/media-executor:<hex>` image. Base retention requires `slot-studio-media-executor-base:local` and `cel.keep=true`. Up to 256 unique candidate entries must carry matching full 40-character lowercase hexadecimal HEADs. Each candidate's small `.git` pointer must name linked-worktree metadata directly beneath `~/code/slot-studio/.git/worktrees`; its detached `HEAD` must match. These bounded file reads never invoke Git or repair/acquire its metadata locks. Missing, symbolic, mismatched or unsafe metadata blocks the observation; it is not interpreted as producer closure. The optional legacy `retired_this_pass` field is accepted only as an empty list.

Successful status records `live`, `rollback`, `base`, `candidate_count`, `generated_at` and `publication_age_seconds`, explicitly with `authorization=none` and `source_controlled_deletion_disabled=true`. The latter describes this read-only integration of the nondeleting producer, not an independently verified producer-code capability or a deletion instruction. Candidate paths never become a drain manifest, retention override or cleanup grant. This observer does not replace the producer, private handler, existing Docker pins/protections or a preservation eligibility check.

An optional `tracing_policy` object has exactly `mode`, `uncapped_opt_in` and `source_sha`. Accepted modes are `disabled`, `enabled`, `unknown`; opt-in values are `rejected`, `allowed`, `unknown`; the source revision must be 40 lowercase hexadecimal characters and match a fresh bounded read of the detached Git HEAD of `live.worktree` (including its hexadecimal worktree/image suffix). Missing, mismatched or unsafe live metadata blocks the publication. Only `{"mode":"disabled","uncapped_opt_in":"rejected","source_sha":"<actual live detached HEAD>"}` produces Miniflare status `disabled-by-source-policy`. The producer must publish that assertion only after proving the rejection guard on its running source revision, not merely because a PR merged. Default-off tracing that still allows an uncapped opt-in must not claim `rejected`. The controller verifies revision identity and reports the issuer's policy assertion; it does not inspect running processes, probe the kernel or execute producer code to independently prove runtime prevention.

Absent policy remains `missing-adapter`. Enabled/unknown tracing, allowed/unknown uncapped opt-in, or an untrusted/stale publication is `blocked`, never capped or bounded-enabled. Malformed policy metadata invalidates the follow-main publication. Trusted tracing status includes the exact policy, revision, publication time/age and observation timestamp, with `authorization=none`, `database_deletion_authorized=false` and `bounded_enabled_tracing=false`. Source-disabled tracing is prevention, **not** an enabled mode with bounded storage and **not** permission to delete any existing database or tracing file. No stale policy survives a later missing/invalid publication.

The existing handlers are fixed at `~/.local/bin/cel-disk-{release-drain,drain,retire}`. Missing or changed pins/executables are real failed statuses, never no-op success. Standalone smoke hooks, including a lowered retirement free-space reserve or after-copy shell command, are stripped from production adapter environments. Handler eligibility, observer, manifest and preservation guards remain authoritative. Exceptions such as a missing `cel` configuration finish the phase as failed instead of leaving durable `running` intent behind.

Retirement additionally requires notification protocol version 1. The pinned handler must honor `CEL_RETIRE_NOTIFY_RECIPIENT=celestial-disk-cleanup`, preserve original-recipient delivery debt, and confirm enqueue. Setting the flag attests to the reviewed pinned capability, not guessed feature support. Its minimum post-copy 20 GiB reserve remains unchanged and can keep candidates while space is low. The daily single-handler preservation trigger therefore runs proactively even when the floor is met; this permits independent-copy/archive work only when the helper's reserve and other eligibility guards allow it. It does not lower that reserve, widen eligibility, bypass reviewed pins or enable root notifications. As with other single-handler triggers, no Docker/producer diagnostic probes are duplicated.

Docker requires both explicit `docker_opt_in=true` and live `cel box docker-safety` capability JSON with integer `version=1`, `keep_label=cel.keep=true`, and an absolute `lock_file`. The **callee** acquires that lock; the controller validates the declared protocol but does not double-acquire it. Only `cel box sweep-docker` follows; there is no fallback to general box sweep, image/container/volume prune or a sourced internal function.

With `docker_opt_in=false`, the Docker phase is deliberately blocked/unattempted: the pass exits 1 and reports routine work to the lane. Consequently **normal root capacity escalation is deferred while available space is at least 1 GiB but below 20 GiB**, because not every configured handler completed. Emergency escalation below 1 GiB remains independent. Parent deployment enables Docker only after verifying safety-v1 and its reviewed runtime pin.

Snapshot capability and mutation calls explicitly set `CEL_ROOT` to the copied runtime root; notification calls set it to the validated CLI deployment root. An inherited `CEL_ROOT` cannot redirect either call to another source tree.

To prevent an installed CLI update between capability lookup and deletion from silently substituting code, the Docker runtime digest binds `bin/cel` and the complete sorted `lib/*.sh` set, including each relative path, byte length and content. The controller checks that digest and executable pin, independently copies those verified bytes into a private disposable runtime, and runs **both capability and mutation from that same snapshot**. Source checkout changes after snapshot creation cannot change the consumer. The copied scripts are read-only; the temporary runtime contains only copied code and is removed after the phase. Missing runtime dependencies fail closed. Any deployed CLI/library change requires a newly reviewed runtime pin. This does not replace producer locking during Docker build/tag/import or retention-file publication.

## Durable observability and notifications

`~/.local/state/cel-disk-headroom/status.json` is atomically replaced with fsync; `receipts.jsonl` is append-only with fsync. Running intent precedes dispatch. Each attempted handler records available bytes immediately before/after, bounded output, exit/status, blocker age and next retry. Deltas are **observed filesystem-window changes**, not exclusive reclaimed bytes: concurrent writers, hardlinks and receipt/state writes also affect availability. Exit zero while preserving every candidate does not imply recovery.

Every full monitor pass refreshes known producer facts and bounded `docker system df --format '{{json .}}'` / `docker ps -a --size --format '{{json .}}'` observations once, including already-healthy and recovered passes. Observation runs after handler dispatches, inside the reserved control-plane budget and before any deficit notifications. Each Docker command gets at most 15 seconds and retains 64 KiB output. Single-handler timer triggers do not duplicate these probes. No `du` traversal is performed. Missing/blocked producer adapters and failed/timed-out Docker commands remain explicit, timestamped observations, not estimated zero totals or successful telemetry. A healthy pass sends no notifications; observation failures do not change measured headroom or imply cleanup failure/success.

| Producer/class | Interface and limit |
| --- | --- |
| Gate runs | Queue issuer/version/timestamp/age, entry and held counts plus release-drain result. Only published dependency targets, not whole-run closure. Missing/invalid/stale queues remain explicit blockers. |
| Ordinary runs | Existing manifest handler; no expansion to run-owned roots. |
| Stale worktrees/previews | Preservation-retire handler result; age, observer, independent-copy and minimum-free guards remain authoritative. |
| Follow-main/executor images | Optional exact-issuer, owned, bounded, fresh version-1 manifest observation with live/rollback/base retention refs and metadata-checked candidate count. Status only; source-controlled deletion disabled, no candidate grants. Missing configuration or invalid publications remain explicit blockers. |
| Miniflare tracing | Optional fresh issuer-bound source policy can report `disabled-by-source-policy` only for disabled tracing with uncapped opt-in rejected at the named running source revision. Missing policy remains missing; enabled/unknown/untrusted policy is blocked. Metadata only, never bounded-enabled tracing or a database deletion grant. |

Routine maintenance and failures go to `celestial-disk-cleanup`, with a 30-minute confirmed-enqueue dedupe. Failed/ambiguous enqueue creates durable debt with `next_retry`; **no resend occurs before that time**, even if another timer invokes a pass sooner. At or after the due boundary, a later controller pass retries. Exit zero plus `queued for RECIPIENT in plane` is required. Enqueue acknowledgment is not an owner answer or a new cleanup grant.

Normal root capacity decisions are emitted only after all configured approved handlers complete successfully and the floor remains unmet. Failed, blocked, deadline-skipped or timed-out work is reported to the lane and deferred, never presented to root as exhausted reclaim; `root_capacity_decision_deferred` makes this explicit. One normal decision is acknowledged/deduplicated per below-target episode. An emergency below 1 GiB is an independent explicit decision even during an incomplete pass; its message says maintenance is incomplete, rather than claiming exhaustion, and is reminded at most daily. Recovery clears the episode. Routine disk-level warnings and no-change reports are not duplicated to root.

Exit codes: 0 target reached or successful serialized single-handler trigger; 1 handler/deadline/config failure; 2 measurable deficit after completed handlers; 3 notification debt; 75 contention. The systemd overlap exception above does not change these controller meanings.

## Parent-controlled transactional migration

Building and testing this code does not change live scripts, units, timers or cleanup. The installer defaults to a plan; `--apply` is explicit. Parent deployment:

1. Coordinate no direct lane invocations. Obtain reviewed handler hashes and retirement notification capability. Deploy Docker safety and producer retention first, before opting in.
2. Stop (do not disable/delete) the four existing `cel-disk-{monitor,release-drain,drain,retire}.timer` units and let finite services finish. The installer also takes the controller lock and refuses active or unknown units.
3. Resolve the actual installed CLI rather than assuming a checkout folder. Display candidate CLI/runtime digests for review; this read-only command does not approve them. Supply reviewed values when applying:

   ```sh
   CEL_BIN="$(readlink -f "$(command -v cel)")"
   python3 tools/disk-headroom/install.py --cel "$CEL_BIN" --describe-cel
   python3 tools/disk-headroom/install.py --cel "$CEL_BIN"
   python3 tools/disk-headroom/install.py --apply --cel "$CEL_BIN" \
     --cel-sha256 "$REVIEWED_CEL_SHA" \
     --docker-runtime-sha256 "$REVIEWED_DOCKER_RUNTIME_SHA" \
     --release-queue-issuer "$REVIEWED_RELEASE_QUEUE_ISSUER" \
     --handler-sha256 "release-drain=$REVIEWED_RELEASE_SHA" \
     --handler-sha256 "ordinary-drain=$REVIEWED_DRAIN_SHA" \
     --handler-sha256 "preservation-retire=$REVIEWED_RETIRE_SHA" \
     --retire-notification-v1 --enable-safe-docker
   ```

   Omit opt-ins until prerequisites are met; missing gates remain visible blockers. CLI executable review pin and explicit reviewed release-queue issuer are required for apply; runtime pin is required when Docker is enabled. Add `--follow-main-issuer "$REVIEWED_FOLLOW_MAIN_ISSUER"` only when parent has reviewed that producer identity; it enables observation, never deletion. The existing transaction backs up/restores this optional config field together with all other config bytes.
4. Before mutation, installer checks manager-loaded and local service drop-ins. A later-sorting `ExecStart` override is refused, as is a conflicting managed destination. It saves independent, fsynced preimages and original modes of controller, wrapper, config and drop-ins under `~/.local/state/cel-disk-headroom/install-backups/transaction-*`, with a durable manifest. It then atomically replaces each file and daemon-reloads. Any caught write/reload/interrupt failure restores all changed preimages (removes only newly created installation files) and reloads again. Rollback failures are explicit and keep the backup path; parent must keep timers stopped. A hard process kill cannot promise an automatic multi-file rollback: use the durable manifest/preimages for operator recovery. Backup evidence is retained, not auto-pruned.
5. Parent starts `cel-disk-monitor.service`, supervises the real pass and reads byte measurements/statuses, then restarts the existing timers. The installer never toggles timers, starts cleanup, or changes standalone scripts/state. Monitor service now invokes maintenance, not the old duplicate routine root-warning behavior.
6. Operator rollback: stop the four timers, wait for services, remove only the four `50-headroom.conf` drop-ins, daemon-reload, then restart existing timers. Original standalone scripts remain available. This restores old alert-only/root-warning monitor behavior; it does not restore deleted dependencies or grant a new class. Preserve controller receipts and transaction backups.

## Isolated verification

Run `python3 -B tools/disk-headroom/test_controller.py` (also wired into `bash tests/run.sh disk_headroom`). Private fake HOME/free-byte observations and real fixture children exercise thresholds, partial failures, per-handler and whole-pass bounds, last-phase notification reserve, skipped-phase root deferral, emergency routing, lock overlap, idempotence, exact retry boundaries, missing/changed adapters, frozen CLI execution, sourced-library drift, later drop-in refusal and transactional write/reload rollback. Follow-main coverage includes exact issuer and freshness boundaries, malformed/duplicate/unknown fields, ownership/mode/symlink/FIFO/size guards, detached HEAD mismatches and optional installer config rollback. Tracing-policy cases cover all enabled/disabled/unknown and allowed/rejected/unknown combinations, missing/stale/untrusted policies and live source revision mismatches. A native Python observer subprocess reads a manifest backed by real disposable detached candidate and live Git worktrees; file bytes, modes and mtimes remain unchanged, with only the existing Docker diagnostic fixture commands executed. It proves matching-revision source-policy reporting, not runtime guard enforcement, bounded-enabled tracing or database deletion authority. Host cleanup is never invoked. These tests prove orchestration and observation, not production reclaimability or safety of an unreviewed handler. Parent must supervise the first deployed real pass.
