# Recurring disk headroom controller

`tools/disk-headroom/controller.py` runs existing owner-approved handlers in order: producer release drain, ordinary manifest drain, preservation retirement, then the safe Docker-only sweep. It orchestrates existing deletion handlers; it does not infer new cleanup grants. The target is **20 GiB available to this user on `/`**, measured with `statvfs.f_bavail * f_frsize`, not root-reserved free blocks.

The controller is not a capacity promise. It stops before the next handler once available space reaches 20 GiB. If the target cannot be reached, durable status reports the remaining byte deficit. Sessions, media, evidence, databases, unpublished gate runs, tracing files and rollback prerequisites never become eligible merely because the disk is low.

## Bounds and serialization

- A nonblocking `flock` at `~/.local/state/cel-disk-headroom/lock` spans each pass, including diagnostics and confirmed message enqueue. Competing invocations exit **75**, not threshold success. Handler subprocesses inherit the descriptor; the parent closes rather than explicitly unlocking it.
- A pass has a 2,400-second monotonic command deadline. **The last 120 seconds are reserved before every handler child dispatch**, including Docker capability lookup and mutation. Individual handlers receive at most 650 seconds, capped by that earlier work deadline. Timed-out process groups are killed; reaping gets at most five additional seconds, inside the control-plane reserve. Diagnostics need at most two 15-second commands; each notification has a 30-second bound. Installed `TimeoutStartSec=2460` and `KillMode=control-group` provide an independent outer service bound.
- Work that cannot be dispatched before the work deadline gets an explicit `skipped` producer status and next retry. A timeout is incomplete work, not proof that approved reclaim was exhausted. The remaining control-plane time stays available for diagnostics, lane messages and emergency escalation.
- `cel-disk-monitor.service` becomes the controller entry point through a drop-in. Its existing timer remains the recurring scheduler; no new timer is created. Existing release/ordinary/retire service entry points use the same controller lock and threshold guard. Standalone scripts and timers remain intact.
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

The existing handlers are fixed at `~/.local/bin/cel-disk-{release-drain,drain,retire}`. Missing or changed pins/executables are real failed statuses, never no-op success. Standalone smoke hooks, including a lowered retirement free-space reserve or after-copy shell command, are stripped from production adapter environments. Handler eligibility, observer, manifest and preservation guards remain authoritative. Exceptions such as a missing `cel` configuration finish the phase as failed instead of leaving durable `running` intent behind.

Retirement additionally requires notification protocol version 1. The pinned handler must honor `CEL_RETIRE_NOTIFY_RECIPIENT=celestial-disk-cleanup`, preserve original-recipient delivery debt, and confirm enqueue. Setting the flag attests to the reviewed pinned capability, not guessed feature support. Its minimum post-copy 20 GiB reserve remains unchanged and can keep candidates while space is low.

Docker requires both explicit `docker_opt_in=true` and live `cel box docker-safety` capability JSON with integer `version=1`, `keep_label=cel.keep=true`, and an absolute `lock_file`. The **callee** acquires that lock; the controller validates the declared protocol but does not double-acquire it. Only `cel box sweep-docker` follows; there is no fallback to general box sweep, image/container/volume prune or a sourced internal function.

With `docker_opt_in=false`, the Docker phase is deliberately blocked/unattempted: the pass exits 1 and reports routine work to the lane. Consequently **normal root capacity escalation is deferred while available space is at least 1 GiB but below 20 GiB**, because not every configured handler completed. Emergency escalation below 1 GiB remains independent. Parent deployment enables Docker only after verifying safety-v1 and its reviewed runtime pin.

Snapshot capability and mutation calls explicitly set `CEL_ROOT` to the copied runtime root; notification calls set it to the validated CLI deployment root. An inherited `CEL_ROOT` cannot redirect either call to another source tree.

To prevent an installed CLI update between capability lookup and deletion from silently substituting code, the Docker runtime digest binds `bin/cel` and the complete sorted `lib/*.sh` set, including each relative path, byte length and content. The controller checks that digest and executable pin, independently copies those verified bytes into a private disposable runtime, and runs **both capability and mutation from that same snapshot**. Source checkout changes after snapshot creation cannot change the consumer. The copied scripts are read-only; the temporary runtime contains only copied code and is removed after the phase. Missing runtime dependencies fail closed. Any deployed CLI/library change requires a newly reviewed runtime pin. This does not replace producer locking during Docker build/tag/import or retention-file publication.

## Durable observability and notifications

`~/.local/state/cel-disk-headroom/status.json` is atomically replaced with fsync; `receipts.jsonl` is append-only with fsync. Running intent precedes dispatch. Each attempted handler records available bytes immediately before/after, bounded output, exit/status, blocker age and next retry. Deltas are **observed filesystem-window changes**, not exclusive reclaimed bytes: concurrent writers, hardlinks and receipt/state writes also affect availability. Exit zero while preserving every candidate does not imply recovery.

Below target, bounded `docker system df --format '{{json .}}'` and `docker ps -a --size --format '{{json .}}'` record daemon totals and container writable layers. Each gets at most 15 seconds and retains 64 KiB output. No `du` traversal is performed. Docker failures are recorded, not estimated as zero.

| Producer/class | Interface and limit |
| --- | --- |
| Gate runs | Queue issuer/version/timestamp/age, entry and held counts plus release-drain result. Only published dependency targets, not whole-run closure. Missing/invalid/stale queues remain explicit blockers. |
| Ordinary runs | Existing manifest handler; no expansion to run-owned roots. |
| Stale worktrees/previews | Preservation-retire handler result; age, observer, independent-copy and minimum-free guards remain authoritative. |
| Follow-main/executor images | Missing machine-consumable producer release/retention-status adapter is explicit. Existing source live/rollback protections are not denied, but are not inferred to authorize cleanup; a success-branch-only/force-removal script is not adopted. |
| Miniflare tracing | Missing opt-in exact closed-set adapter is explicit. Off-by-default tracing and a small current footprint do not authorize deletion. |

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

   Omit opt-ins until prerequisites are met; missing gates remain visible blockers. CLI executable review pin and explicit reviewed release-queue issuer are required for apply; runtime pin is required when Docker is enabled.
4. Before mutation, installer checks manager-loaded and local service drop-ins. A later-sorting `ExecStart` override is refused, as is a conflicting managed destination. It saves independent, fsynced preimages and original modes of controller, wrapper, config and drop-ins under `~/.local/state/cel-disk-headroom/install-backups/transaction-*`, with a durable manifest. It then atomically replaces each file and daemon-reloads. Any caught write/reload/interrupt failure restores all changed preimages (removes only newly created installation files) and reloads again. Rollback failures are explicit and keep the backup path; parent must keep timers stopped. A hard process kill cannot promise an automatic multi-file rollback: use the durable manifest/preimages for operator recovery. Backup evidence is retained, not auto-pruned.
5. Parent starts `cel-disk-monitor.service`, supervises the real pass and reads byte measurements/statuses, then restarts the existing timers. The installer never toggles timers, starts cleanup, or changes standalone scripts/state. Monitor service now invokes maintenance, not the old duplicate routine root-warning behavior.
6. Operator rollback: stop the four timers, wait for services, remove only the four `50-headroom.conf` drop-ins, daemon-reload, then restart existing timers. Original standalone scripts remain available. This restores old alert-only/root-warning monitor behavior; it does not restore deleted dependencies or grant a new class. Preserve controller receipts and transaction backups.

## Isolated verification

Run `python3 -B tools/disk-headroom/test_controller.py` (also wired into `bash tests/run.sh disk_headroom`). Private fake HOME/free-byte observations and real fixture children exercise thresholds, partial failures, per-handler and whole-pass bounds, last-phase notification reserve, skipped-phase root deferral, emergency routing, lock overlap, idempotence, exact retry boundaries, missing/changed adapters, frozen CLI execution, sourced-library drift, later drop-in refusal and transactional write/reload rollback. Host cleanup is never invoked. These tests prove orchestration, not production reclaimability or safety of an unreviewed handler. Parent must supervise the first deployed real pass.
