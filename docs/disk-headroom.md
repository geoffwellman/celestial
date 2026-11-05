# Recurring disk headroom controller

`tools/disk-headroom/controller.py` runs the existing owner-approved handlers in order: producer release drain, ordinary manifest drain, preservation retirement, then the safe Docker-only sweep. It does not implement deletion or infer new cleanup grants. The target is **20 GiB available to this user on `/`**, measured with `statvfs.f_bavail * f_frsize`, not root-reserved free blocks.

This is a maintenance controller, not a promise of capacity. A pass stops before the next handler once available space reaches 20 GiB. If approved cleanup cannot reach it, `status.json` records the exact remaining byte deficit. No sessions, media, evidence, databases, unpublished gate runs, tracing files, image rollback prerequisites or new classes become eligible merely because the disk is low.

## Bounds and serialization

- One nonblocking `flock` at `~/.local/state/cel-disk-headroom/lock` spans the entire pass, including diagnostics and confirmed message enqueue. A competing invocation exits **75**, not success. Handler subprocesses inherit the lock descriptor; the parent closes rather than explicitly unlocking it.
- Each handler gets at most 650 seconds and all commands share a 2,400-second monotonic pass deadline. A timed-out process group is killed; at most five further seconds are allowed to reap it. Installed service `TimeoutStartSec=2460` and `KillMode=control-group` provide an independent outer bound. The service environment retains Herdr/Rex/mise discovery paths.
- `cel-disk-monitor.service` becomes the controller entry point through a supported drop-in. Its existing timer remains the recurring scheduler; no extra competing timer is created. Existing release/ordinary/retire service entry points go through the same controller lock and threshold guard. The standalone scripts and their timers are retained, not deleted or disabled.
- Direct invocation of a standalone script bypasses this controller lock (the old release handler also has its own lock). During controlled deployment, the parent must quiesce the lane's manual invocations as well. After migration, invoke the existing services or `cel-disk-headroom handler NAME`, not the old binaries directly.
- This controller does not replace the Docker adapter's separate image-publication lock or authorize global prune.

## Explicit adapter gates

The owner-controlled regular file `~/.config/cel/disk-headroom.json` has schema version 1. Group/world-writable or unknown configuration versions/keys are refused. The supported installer creates it from explicitly supplied review pins:

```json
{
  "version": 1,
  "cel": "/home/geoff/celestial-plane/bin/cel",
  "handler_sha256": {
    "release-drain": "<reviewed SHA256>",
    "ordinary-drain": "<reviewed SHA256>",
    "preservation-retire": "<reviewed SHA256>"
  },
  "retire_notification_version": 1,
  "docker_opt_in": false
}
```

The three existing handlers are fixed at `~/.local/bin/cel-disk-{release-drain,drain,retire}`. A missing executable, missing pin, changed pin or unknown handler is a real failed status, never a no-op success. Their eligibility checks and manifests remain authoritative. Pins are deliberately **not** inferred from whatever binary happens to be installed.

Retirement additionally requires explicit notification protocol version 1: the reviewed handler must honor `CEL_RETIRE_NOTIFY_RECIPIENT=celestial-disk-cleanup`, including confirmed enqueue/debt handling. The previously installed retirement script always sends root and therefore must remain gated until its owner deploys that support. Setting the config flag is an operator attestation to the pinned version, not a feature-detection guess. Preservation budget/observer/age guards must not be relaxed to meet the floor; in particular its own 20 GiB post-copy reserve can keep candidates while the disk is low.

Docker requires **both** `docker_opt_in=true` and a successful live `cel box docker-safety` JSON capability with `version=1`, `keep_label=cel.keep=true`, and a nonempty `lock_file`. Only then is `cel box sweep-docker` invoked. The Docker safety change must be deployed first, with producer rollback/base retention configured and reviewed. An older `cel`, malformed capability or absent gate is a blocker. No fallback to `cel box sweep`, image/container/volume prune or an internal library function exists.

## Durable observability and routing

`~/.local/state/cel-disk-headroom/status.json` is atomically replaced with fsync, and `receipts.jsonl` is append-only with fsync. A handler's running intent is saved before dispatch. Every attempted handler records available bytes immediately before/after, its bounded output tail, exit/status, blocker age and next retry. Deltas are **observed filesystem-window changes**, not exclusive reclaimed bytes: concurrent producers, hardlinks, handler receipts and controller state writes also change availability. A handler may return zero while preserving all candidates; this does not imply successful recovery.

Below target, daemon-provided `docker system df --format '{{json .}}'` and `docker ps -a --size --format '{{json .}}'` capture image/cache totals and container writable-layer facts. Each command is bounded to 15 seconds and its retained output to 64 KiB. There is no `du` traversal. Docker daemon failures are recorded explicitly, not estimated as zero.

Producer statuses include:

| Producer/class | Known interface and limits |
| --- | --- |
| Gate runs | Release queue version/issuer/count/held count and timestamp, plus release-drain result. Published dependency targets only; not blanket whole-run closure. Missing/invalid queue is explicit. |
| Ordinary runs | Existing manifest handler; no expansion to run-owned roots. |
| Stale worktrees/previews | Existing preservation-retire result; eligibility and minimum-free guards stay authoritative. |
| Follow-main/executor images | Explicit missing producer release/status adapter, even when safe generic Docker sweep is available. Retention is not inferred from age or tag disappearance. |
| Miniflare tracing | Explicit missing exact closed-set adapter; no inferred deletion. |

Routine maintenance/failures go to `celestial-disk-cleanup`, with a 30-minute confirmed-enqueue dedupe and retries on debt. Root gets only a **capacity/grant/class decision required** after approved configured attempts cannot close the measurable gap, not routine monitor level warnings or no-change reports. One normal capacity decision is acknowledged/deduplicated per below-target episode; a subsequent emergency below 1 GiB creates a distinct clear decision escalation, reminded at most daily. Recovery to 20 GiB clears the episode. Enqueue success requires exit zero **and** `queued for RECIPIENT in plane`; failed or ambiguous sends retain durable debt and retry on the next controller pass. This acknowledgment means confirmed mailbox enqueue, not that the owner answered or granted anything.

Exit codes: 0 target reached (or successful serialized single-handler trigger), 1 handler/deadline/config failure, 2 measurable capacity deficit after successful handlers, 3 notification debt, 75 lock contention. These intentionally remain nonzero in systemd when the maintenance goal was not achieved.

## Parent-controlled migration

No live scripts, units, timer state or cleanup are changed by building/testing this code. The installer defaults to a plan; `--apply` is required. Deployment is the parent's responsibility:

1. Coordinate with the cleanup lane: no direct standalone invocations during migration. Obtain exact reviewed handler hashes. Deploy the Docker safety version/producer retention first. Deploy the retirement notification protocol first, or leave that gate off and record the blocker.
2. Stop (do not disable/delete) the four existing `cel-disk-{monitor,release-drain,drain,retire}.timer` units. Let their finite services complete. This temporarily quiesces the old non-locking units before new entry points are installed. The installer refuses any active or unknown service/timer, rather than racing it.
3. From the deployed tracked checkout, first view the plan, then install with explicit reviewed values. For example, with shell variables already holding reviewed hashes:

   ```sh
   python3 tools/disk-headroom/install.py --cel /home/geoff/celestial-plane/bin/cel
   python3 tools/disk-headroom/install.py --apply \
     --cel /home/geoff/celestial-plane/bin/cel \
     --handler-sha256 "release-drain=$REVIEWED_RELEASE_SHA" \
     --handler-sha256 "ordinary-drain=$REVIEWED_DRAIN_SHA" \
     --handler-sha256 "preservation-retire=$REVIEWED_RETIRE_SHA" \
     --retire-notification-v1 --enable-safe-docker
   ```

   Omit the two opt-ins until their prerequisites are satisfied. Missing gates remain visible failures/blockers, not permission to substitute another cleanup mechanism. The installer copies the tracked controller independently of the source worktree and installs `cel-disk-headroom`; existing standalone monitor/drain/retire scripts and state are unchanged. Existing conflicting managed drop-ins are refused.
4. The parent starts `cel-disk-monitor.service` and supervises the real pass, checks before/after available bytes and producer statuses, then restarts the four existing timers. The monitor service now calls the controller, so its former routine root warning/diagnostic behavior is not executed. No timers are enabled, disabled, stopped or started by the installer.
5. Rollback requires the parent to stop the four timers, wait for services, remove only `50-headroom.conf` in the four `cel-disk-*.service.d` directories, daemon-reload and restart the existing timers. The original standalone monitor is still present, so rollback restores its old alert-only/root-warning behavior. Preserve controller status/receipts for evidence; rollback does not restore deleted dependencies or grant any new class.

## Isolated verification

Run `python3 tools/disk-headroom/test_controller.py` (also wired into `bash tests/run.sh disk_headroom`). The harness uses private fake HOME, fake free-byte observations and real bounded child executables; host disk handlers are never called. It covers threshold crossing between phases, already-healthy unit triggers, partial-failure deltas, timeout, whole-pass budget, common flock, idempotent handlers, missing/changed adapters, Docker capability/opt-in, root enqueue debt/false ACK/retry/dedupe/emergency transition, producer gaps and quiescent installer behavior. It proves orchestration, not production reclaimability or safe behavior of an unreviewed pinned handler. The parent must supervise the first real pass after deployment.
