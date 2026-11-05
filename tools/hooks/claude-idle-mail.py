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


def wake_content(target, message_id):
    return ("New celestial inbox mail is waiting for this session. "
            "Read your own mailbox with `cel inbox read --for " + target["name"] +
            " --workspace " + target["workspace"] + "` and act on it. "
            "This is only a wake notification, not the mail itself. "
            "Do not type into any terminal composer. Mail notification id: " + message_id)


def receipt_start(target):
    try:
        info = Path(target["transcript"]).lstat()
    except FileNotFoundError:
        return {"offset": 0, "file": None}
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("native transcript is not an owned regular file")
    return {"offset": info.st_size, "file": [info.st_dev, info.st_ino]}


def receipt_status(target, state):
    # Native body dedup expires (30 seconds on observed 2.1.318). A stable ID
    # alone is NOT a durable receipt. Read only complete, structurally matched
    # native queue/user rows after our pre-send offset; never API-request blobs.
    if state.get("native_receipt"):
        return "present"
    cursor = state["receipt_cursor"]
    try:
        fd = os.open(target["transcript"], os.O_RDONLY | os.O_NOFOLLOW)
    except FileNotFoundError:
        return "absent" if cursor["file"] is None else "unknown"
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        identity = [info.st_dev, info.st_ino]
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or cursor["file"] not in (None, identity) or info.st_size < cursor["offset"]):
            return "unknown"
        stream.seek(cursor["offset"])
        budget = 1024 * 1024
        while budget > 0:
            line = stream.readline(budget)
            if not line:
                state["receipt_cursor"] = {"offset": stream.tell(), "file": identity}
                return "absent"
            if not line.endswith(b"\n"):
                return "unknown"  # partial/oversized row: freeze, never infer absence
            budget -= len(line)
            item = json.loads(line)
            if item.get("sessionId") == target["session"] and (
                    (item.get("type") == "user" and item.get("uuid") == state["message_id"]
                     and item.get("origin", {}).get("kind") == "peer" and not item.get("isSidechain"))
                    or (item.get("type") == "queue-operation" and item.get("operation") == "enqueue"
                        and item.get("content") == wake_content(target, state["message_id"]))):
                state["native_receipt"] = item["type"]
                state["receipt_cursor"] = {"offset": stream.tell(), "file": identity}
                return "present"
        state["receipt_cursor"] = {"offset": stream.tell(), "file": identity}
        return "unknown"  # bounded catch-up continues before any retry


def connect_peer(target):
    path = Path(target["socket"])
    info = path.lstat()
    if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
        raise ValueError("native inbox path is not an owned Unix socket")
    peer = socket.socket(socket.AF_UNIX)
    try:
        peer.settimeout(2)
        peer.connect(str(path))
        pid, uid, _ = struct.unpack("3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12))
        if pid != target["pid"] or uid != os.getuid() or proc_identity(pid)[1] != target["pid_start"]:
            raise ValueError("native socket belongs to a different process")
        return peer
    except BaseException:
        peer.close()
        raise


def send_wake(target, message_id):
    with connect_peer(target) as peer:
        frames = []
        token = os.environ.get("CLAUDE_CODE_MESSAGING_TOKEN")
        if token:
            frames.append({"type": "auth", "token": token})
        frames.append({"type": "user", "session_id": target["session"],
                       "uuid": message_id, "msg_id": message_id, "priority": "next",
                       "message": {"role": "user", "content": wake_content(target, message_id)}})
        peer.sendall(b"".join(json.dumps(frame).encode() + b"\n" for frame in frames))


def tick(root, record_path, state_path, target, state, now):
    record = validate_target(record_path, target)
    fingerprint = unread(root, target)
    if fingerprint is None:
        state.update(fingerprint=None, attempts=0, status="idle")
        state.pop("error", None)
        atomic_state(state_path, state)
        return
    if state.get("fingerprint") != fingerprint:
        state.update(fingerprint=fingerprint, attempts=0,
                     message_id=str(uuid.uuid4()), status="pending",
                     receipt_cursor=receipt_start(target))
        state.pop("native_receipt", None)
    attempts = state.get("attempts", 0)
    receipt = receipt_status(target, state) if attempts else "absent"
    if receipt != "absent":
        state["status"] = "native_received_mail_unread" if receipt == "present" else "receipt_unknown_mail_unread"
    elif record.get("agent_status") != "idle" or attempts >= len(RETRY_SECONDS):
        state["status"] = "waiting_for_delivery"
    elif now - state.get("last_attempt", 0) >= RETRY_SECONDS[attempts]:
        # Persist the attempt and transcript boundary before transport. After
        # a crash, the next watcher reconciles the actual native queue receipt.
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


def validate_attach(record_path, target):
    state_root = Path(os.environ.get("CEL_REX_STATE", str(
        Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "cel/rex")))
    if Path(record_path).resolve() != (state_root / (target["name"] + ".json")).resolve():
        raise ValueError("attach requires the canonical named Rex receipt")
    receipt_start(target)  # owned regular transcript, not a symlink
    with Path(target["transcript"]).open("rb") as stream:
        budget = 1024 * 1024
        while budget > 0:
            line = stream.readline(budget)
            if not line or not line.endswith(b"\n"):
                break
            budget -= len(line)
            row = json.loads(line)
            if (row.get("sessionId") == target["session"] and row.get("cwd") == target["cwd"]
                    and row.get("type") in ("user", "assistant", "attachment") and not row.get("isSidechain")):
                with connect_peer(target):
                    return  # kernel peer validation only; sends no input/event
    raise ValueError("native transcript does not prove this receipt's UUID and working directory")


def validate_native_consent(target, consent_path):
    if not consent_path:
        raise ValueError("existing-session attach is disabled: owner-approved native crossSessionInbound=accept is required; no policy is changed automatically")
    environment = dict(field.split(b"=", 1) for field in
                       Path(f'/proc/{target["pid"]}/environ').read_bytes().split(b"\0") if b"=" in field)
    home = environment.get(b"HOME")
    config = environment.get(b"CLAUDE_CONFIG_DIR")
    if not home and not config:
        raise ValueError("cannot resolve this native process's actual user settings")
    expected = Path(os.fsdecode(config)) if config else Path(os.fsdecode(home)) / ".claude"
    expected = expected / "settings.json"
    path = Path(consent_path)
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
            or path.resolve() != expected.resolve()
            or json.loads(path.read_text()).get("crossSessionInbound") != "accept"):
        raise ValueError("owner consent must be crossSessionInbound=accept in this native process's actual user settings")
    arguments = Path(f'/proc/{target["pid"]}/cmdline').read_bytes().split(b"\0")
    for index, argument in enumerate(arguments):
        if argument == b"--setting-sources" and b"user" not in arguments[index + 1].split(b","):
            raise ValueError("the native process does not load user settings; attach remains disabled")


def start(native, pid, transcript, attached=False, consent_path=None):
    record_path = os.environ["CEL_REX_RECORD"]
    record = read_record(record_path)
    if record["pid"] != pid:
        raise ValueError("reporter and receipt process differ")
    if not attached:
        ancestor = os.getpid()
        while ancestor > 1 and ancestor != pid:
            ancestor = proc_identity(ancestor)[0]
        if ancestor != pid:
            raise ValueError("watcher launch is not a child of its target")
    root = os.environ["CEL_ROOT"]
    resolved = subprocess.run(
        ["bash", "-c", 'source "$1/lib/workspace.sh"; ws_name "$2"',
         "cel-claude-workspace", root, record["workspace"]],
        capture_output=True, text=True, timeout=10, check=True).stdout.strip()
    name, workspace = ((record["name"], resolved) if attached else
                       (os.environ["CEL_INBOX_ME"], os.environ["CEL_INBOX_WS"]))
    if name != record["name"] or not name or not workspace or not all(c.isalnum() or c in "-_" for c in name + workspace):
        raise ValueError("ambiguous inbox identity")
    if resolved != workspace:
        raise ValueError("inbox workspace does not match launch receipt")
    target = {"pid": pid, "pid_start": record["pid_start"], "session": native,
              "name": name, "workspace": workspace, "workspace_path": record["workspace"],
              "cwd": record["cwd"], "socket": os.environ.get("CLAUDE_CODE_MESSAGING_SOCKET", ""),
              "transcript": transcript}
    validate_target(record_path, target)
    if not Path(transcript).is_absolute() or Path(transcript).name != native + ".jsonl":
        raise ValueError("exact native hook transcript path is required for retry reconciliation")
    if attached:
        validate_attach(record_path, target)
        validate_native_consent(target, consent_path)
        # Never reuse the attaching agent's child token for another session.
        # Linux's same-UID native peer transport authenticates by credentials.
        os.environ.pop("CLAUDE_CODE_MESSAGING_TOKEN", None)
        os.environ["CEL_INBOX_ME"], os.environ["CEL_INBOX_WS"] = name, workspace
    directory = Path(record_path + ".inbox")
    directory.mkdir(mode=0o700, exist_ok=True)
    os.chmod(directory, 0o700)
    state_path = directory / "state.json"
    with (directory / "watch.lock").open("a") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            # A new native process/session must not lose its only async hook
            # merely because the old watcher is finishing its bounded poll.
            if not state_path.exists() or json.loads(state_path.read_text()).get("target") == target:
                return
            deadline = time.monotonic() + POLL_SECONDS + 11
            while time.monotonic() < deadline:
                validate_target(record_path, target)
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    time.sleep(0.1)
            else:
                raise ValueError("previous native watcher did not release its lease; unread mail is retained")
        if not target["socket"]:
            atomic_state(state_path, {"target": target, "status": "unavailable",
                         "error": "Claude did not publish CLAUDE_CODE_MESSAGING_SOCKET; native peer messaging is required. Inbox remains unread."})
            return
        if not attached:
            # The async native hook owns this process for its whole lifetime.
            # Detaching/reparenting would erase the proof that lets bypass-mode
            # Claude accept its own child without weakening inbound policy.
            watch(root, record_path, state_path, target, lock.fileno())
            return
        subprocess.Popen([sys.executable, __file__, "watch", root, record_path,
                          str(state_path), json.dumps(target), str(lock.fileno())],
                         pass_fds=(lock.fileno(),), start_new_session=True,
                         stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                         stderr=subprocess.DEVNULL)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "run":
            start(sys.argv[2], int(sys.argv[3]), sys.argv[4])
        elif sys.argv[1] == "watch":
            watch(sys.argv[2], sys.argv[3], Path(sys.argv[4]), json.loads(sys.argv[5]), int(sys.argv[6]))
        elif sys.argv[1] == "attach":
            if len(sys.argv) not in (5, 7) or (len(sys.argv) == 7 and sys.argv[5] != "--native-consent-settings"):
                raise ValueError("usage: claude-idle-mail.py attach <canonical-receipt> <native-socket> <native-transcript> [--native-consent-settings <native-user-settings>]")
            os.environ["CEL_ROOT"] = str(Path(__file__).resolve().parents[2])
            os.environ["CEL_REX_RECORD"] = sys.argv[2]
            os.environ["CLAUDE_CODE_MESSAGING_SOCKET"] = sys.argv[3]
            record = read_record(sys.argv[2])
            native = record.get("agent_session", {}).get("value")
            start(native, record["pid"], sys.argv[4], attached=True,
                  consent_path=sys.argv[6] if len(sys.argv) == 7 else None)
            print(json.dumps({"status": "watcher_ensured_not_delivery", "recipient": record["name"],
                              "session": native, "state_file": sys.argv[2] + ".inbox/state.json"}))
        else:
            raise ValueError("unknown idle mail operation")
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        # Hooks must never block an owner turn because the optional native
        # facility is absent. Nothing has read or acknowledged their inbox.
        print(f"cel Claude idle mail unavailable: {error}", file=sys.stderr)
        sys.exit(1)
