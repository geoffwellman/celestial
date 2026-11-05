#!/usr/bin/env python3
"""Wake a receipt-bound Claude through its native peer socket, never a terminal.

The socket is a notification transport, NOT a delivery acknowledgement. Only
Claude's normal inbox read/Stop hook consumes mail. This process never does.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import sys
import time
import uuid

POLL_SECONDS = 5
RETRY_SECONDS = (0, 30, 120)

def proc_identity(pid):
    fields = Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()
    return int(fields[1]), fields[19]


def read_record(path):
    record = json.loads(Path(path).read_text())
    if record.get("agent") != "claude" or record.get("backend") != "rex":
        raise ValueError("not a managed native Claude receipt")
    pid = record["pid"]
    if type(pid) is not int or pid <= 1:
        raise ValueError("invalid process identity")
    if proc_identity(pid)[1] != record["pid_start"]:
        raise ValueError("runtime process was replaced")
    return record


def validate_target(path, target):
    record = read_record(path)
    expected = {"pid": record["pid"], "pid_start": record["pid_start"],
                "session": record.get("agent_session", {}).get("value"),
                "name": record["name"], "cwd": record["cwd"]}
    if any(target.get(key) != value for key, value in expected.items()):
        raise ValueError("native session or receipt changed")
    if not isinstance(target["session"], str) or str(uuid.UUID(target["session"])) != target["session"].lower():
        raise ValueError("invalid native conversation identity")
    if record["workspace"] != target["workspace_path"]:
        raise ValueError("workspace receipt changed")
    return record


def atomic_state(path, state):
    serialized = json.dumps(state, sort_keys=True)
    try:
        if path.read_text() == serialized:
            return
    except FileNotFoundError:
        pass
    temporary = path.with_suffix(".tmp")
    with temporary.open("w") as stream:
        os.chmod(temporary, 0o600)
        stream.write(serialized)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)
    directory_fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(directory_fd)
    finally:
        os.close(directory_fd)


def unread(root, target):
    # Use the canonical hole-aware/migration-aware selector. This function is
    # deliberately NOT `cel inbox read`, including on retry and error paths.
    result = subprocess.run(
        ["bash", "-c", 'source "$1/lib/inbox.sh"; inbox_unread_json "$2" "$3"',
         "cel-claude-inbox", root, target["workspace"], target["name"]],
        capture_output=True, timeout=10, check=True)
    rows = [json.loads(line) for line in result.stdout.splitlines()]
    if not rows:
        return None
    canonical = json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()
    return hashlib.sha256(canonical).hexdigest()


def send_wake(target, message_id):
    path = Path(target["socket"])
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("native inbox path is not an owned Unix socket")
    with socket.socket(socket.AF_UNIX) as peer:
        peer.settimeout(2)
        peer.connect(str(path))
        pid, uid, _ = struct.unpack("3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if pid != target["pid"] or uid != os.getuid() or proc_identity(pid)[1] != target["pid_start"]:
            raise ValueError("native socket belongs to a different process")
        frames = []
        token = os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN")
        if token:
            frames.append({"type": "auth", "token": token})
        frames.append({"type": "user", "session_id": target["session"],
                       "uuid": message_id, "msg_id": message_id, "priority": "next",
                       "message": {"role": "user", "content":
                           "New celestial inbox mail is waiting for this session. "
                           "Read your own mailbox with `cel inbox read --for " + target["name"] +
                           " --workspace " + target["workspace"] + "` and act on it. "
                           "This is only a wake notification, not the mail itself. "
                           "Do not type into any terminal composer. "
                           "Mail notification id: " + message_id}})
        peer.sendall(b"".join(json.dumps(frame).encode() + b"\n" for frame in frames))


def tick(root, record_path, state_path, target, state, now):
    record = validate_target(record_path, target)
    fingerprint = unread(root, target)
    if fingerprint is None:
        state.update(fingerprint=None, attempts=0, status="idle")
        atomic_state(state_path, state)
        return
    if state.get("fingerprint") != fingerprint:
        state.update(fingerprint=fingerprint, attempts=0,
                     message_id=str(uuid.uuid4()), status="pending")
    attempts = state.get("attempts", 0)
    # Native peer turns need not fire UserPromptSubmit. Bound duplicate wake
    # traffic even if the receipt still says idle while Claude processes one.
    if record.get("agent_status") != "idle" or attempts >= len(RETRY_SECONDS):
        state["status"] = "waiting_for_delivery"
    elif now - state.get("last_attempt", 0) >= RETRY_SECONDS[attempts]:
        # Record the attempt before transport: an interrupted send is unknown,
        # not permission to consume mail or start an unbounded retry loop.
        state.update(attempts=attempts + 1, last_attempt=now, status="pending")
        atomic_state(state_path, state)
        try:
            send_wake(target, state["message_id"])
            state["status"] = "notified_not_delivered"
            state.pop("error", None)
        except (OSError, ValueError) as error:
            state.update(status="waiting_for_delivery", error=str(error))
    atomic_state(state_path, state)


def watch(root, record_path, state_path, target, lock_fd):
    # Holding this inherited lock is the only watcher ownership proof. A stale
    # PID file or a new hook invocation cannot start a second watcher.
    os.fstat(lock_fd)
    try:
        state = json.loads(state_path.read_text())
    except FileNotFoundError:
        state = {}
    if state.get("target") != target:
        state = {"target": target, "attempts": 0}
    state["watcher"] = {"pid": os.getpid(), "pid_start": proc_identity(os.getpid())[1]}
    while True:
        try:
            tick(root, record_path, state_path, target, state, time.time())
        except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
            # Receipt replacement ends this owner. Selector outages leave
            # canonical inbox debt untouched and can recover on a later poll.
            try:
                validate_target(record_path, target)
            except (OSError, ValueError, KeyError):
                return
            state.update(status="waiting_for_delivery", error=str(error))
            atomic_state(state_path, state)
        time.sleep(POLL_SECONDS)


def start(native, pid):
    record_path = os.environ["CEL_REX_RECORD"]
    record = read_record(record_path)
    if record["pid"] != pid:
        raise ValueError("reporter and receipt process differ")
    ancestor = os.getpid()
    while ancestor > 1 and ancestor != pid:
        ancestor = proc_identity(ancestor)[0]
    if ancestor != pid:
        raise ValueError("watcher launch is not a child of its target")
    name, workspace = os.environ["CEL_INBOX_ME"], os.environ["CEL_INBOX_WS"]
    # Native lane aliases, not cwd guesses or a foreign reader's cursor.
    if name != record["name"] or not all(c.isalnum() or c in "-_" for c in name + workspace):
        raise ValueError("ambiguous inbox identity")
    root = os.environ["CEL_ROOT"]
    resolved = subprocess.run(
        ["bash", "-c", 'source "$1/lib/workspace.sh"; ws_name "$2"',
         "cel-claude-workspace", root, record["workspace"]],
        capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    if not workspace or resolved != workspace:
        raise ValueError("inbox workspace does not match launch receipt")
    target = {"pid": pid, "pid_start": record["pid_start"], "session": native,
              "name": name, "workspace": workspace, "workspace_path": record["workspace"],
              "cwd": record["cwd"], "socket": os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET", "")}
    validate_target(record_path, target)
    directory = Path(record_path + ".inbox")
    directory.mkdir(mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    state_path = directory / "state.json"
    with (directory / "watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return
        if not target["socket"]:
            atomic_state(state_path, {"target": target, "status": "unavailable",
                         "error": "Claude did not publish CLAUDE_CODE_MESSAGING_SOCKET; native peer messaging is required. Inbox remains unread."})
            return
        subprocess.Popen([sys.executable, __file__, "watch", root, record_path,
                          str(state_path), json.dumps(target), str(lock.fileno())],
                         pass_fds=(lock.fileno(),), start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "start":
            start(sys.argv[2], int(sys.argv[3]))
        elif sys.argv[1] == "watch":
            watch(sys.argv[2], sys.argv[3], Path(sys.argv[4]), json.loads(sys.argv[5]), int(sys.argv[6]))
        else:
            raise ValueError("unknown idle mail operation")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Hooks must never block an owner turn because the optional native
        # facility is absent. Nothing has read or acknowledged their inbox.
        print(f"cel Claude idle mail unavailable: {error}", file=sys.stderr)
        sys.exit(1)
