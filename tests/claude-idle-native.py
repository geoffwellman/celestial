#!/usr/bin/env python3
"""Opt-in integration: real installed Claude, isolated HOME, loopback fake provider.

Requires python3-pexpect and Claude Code with native Unix peer messaging. No real
credentials, inference, Rex input, or live lane restart. A missing native facility
fails with its exact prerequisite; it is not reported as a passing wake test.
"""
import http.server
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import signal
import stat
import sys
import tempfile
import threading
import time
import uuid

import pexpect

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("claude_idle", ROOT / "tools/hooks/claude-idle-mail.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)
MODEL = "claude-sonnet-4-6"


def fixture_hook():
    """Run production bootstrap/watch as a native child with fixture-only timing."""
    payload = json.load(sys.stdin)
    subprocess.run(["bash", str(ROOT / "tools/hooks/claude-session.sh")],
                   input=json.dumps(payload), text=True, check=True)
    record = idle.read_record(os.environ["CEL_REX_RECORD"])
    # Accelerate only backoff/poll timing in this isolated fixture process.
    # Identity, kernel transport, receipts, cursor and native delivery are real.
    idle.RETRY_SECONDS = (0, 1, 5)
    idle.POLL_SECONDS = 0.05
    idle.start(payload["session_id"], record["pid"], payload["transcript_path"])


def main():
    if not shutil.which("claude"):
        raise RuntimeError("Prerequisite: installed native Claude Code with Unix peer messaging")
    if os.geteuid() == 0:
        raise RuntimeError("Prerequisite: non-root account so Unix socket permission denial exercises real failed writes")
    directory = Path(tempfile.mkdtemp(prefix="cel-claude-idle-native-"))
    print(f"Native fixture evidence: {directory}", flush=True)
    for child in ("home", "config", "cwd", "inbox", "rex"):
        (directory / child).mkdir(mode=0o700)
    cwd = directory / "cwd"
    (cwd / "workspace.yaml").write_text("name: native-fixture\nkind: personal\n")
    key = "fixture-not-a-real-credential"
    (directory / "config/.claude.json").write_text(json.dumps({
        "hasCompletedOnboarding": True, "theme": "dark",
        "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
        "projects": {str(cwd): {"hasTrustDialogAccepted": True}}}))
    native = str(uuid.uuid4())
    record_path = directory / "rex/native-fixture-lane.json"
    state_path = Path(str(record_path) + ".inbox/state.json")
    requests = []
    provider_release = threading.Event()

    class Provider(http.server.BaseHTTPRequestHandler):
        def do_POST(self):
            body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            if self.path.endswith("/count_tokens"):
                response = json.dumps({"input_tokens": 1}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(response)
                return
            requests.append(body)
            (directory / "provider-requests.json").write_text(json.dumps(requests, indent=2))
            if len(requests) == 1:
                # Keep the real native peer turn active past its retry deadline;
                # the watcher must reconcile its persisted native receipt.
                provider_release.wait(60)
            text = "Deterministic native fixture response. No provider inference."
            events = [
                ("message_start", {"type": "message_start", "message": {
                    "id": "msg_fixture", "type": "message", "role": "assistant", "model": MODEL,
                    "content": [], "stop_reason": None, "stop_sequence": None,
                    "usage": {"input_tokens": 1, "output_tokens": 0}}}),
                ("content_block_start", {"type": "content_block_start", "index": 0,
                                         "content_block": {"type": "text", "text": ""}}),
                ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                         "delta": {"type": "text_delta", "text": text}}),
                ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                ("message_delta", {"type": "message_delta", "delta": {
                    "stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
                ("message_stop", {"type": "message_stop"}),
            ]
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for event, value in events:
                self.wfile.write(f"event: {event}\ndata: {json.dumps(value)}\n\n".encode())
            self.wfile.flush()

        def log_message(self, *args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = {"PATH": os.environ["PATH"], "HOME": str(directory / "home"),
           "CLAUDE_CONFIG_DIR": str(directory / "config"), "TERM": "xterm-256color",
           "ANTHROPIC_API_KEY": key, "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{server.server_port}",
           "DISABLE_AUTOUPDATER": "1", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1",
           "HTTP_PROXY": "http://127.0.0.1:1", "HTTPS_PROXY": "http://127.0.0.1:1",
           "ALL_PROXY": "http://127.0.0.1:1", "NO_PROXY": "127.0.0.1,localhost",
           "GIT_SSH_COMMAND": "/bin/false", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "CEL_ROOT": str(ROOT), "CEL_REX_RECORD": str(record_path),
           "CEL_REX_STATE": str(directory / "rex"), "CEL_AGENT_NAME": "native-fixture-lane",
           "CEL_INBOX_ME": "native-fixture-lane", "CEL_INBOX_WS": "native-fixture",
           "CEL_INBOX_DIR": str(directory / "inbox"), "CEL_ORCH_SESSIONS": str(directory / "sessions.json")}
    settings = {"skipDangerousModePermissionPrompt": True, "hooks": {
        "SessionStart": [{"hooks": [{"type": "command", "command": sys.executable,
                                    "args": [str(Path(__file__).resolve()), "--hook"], "async": True}]}],
        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": sys.executable,
                                        "args": [str(Path(__file__).resolve()), "--hook"], "async": True}]}],
        "Stop": [{"hooks": [{"type": "command", "command": f"bash {ROOT}/tools/hooks/inbox-stop.sh", "timeout": 10}]}]}}
    screen = (directory / "screen.log").open("w")
    child = pexpect.spawn("claude", ["--setting-sources", "user", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                                     "--settings", json.dumps(settings), "--debug-file", str(directory / "debug.log"),
                                     "--session-id", native, "--model", MODEL, "--dangerously-skip-permissions"],
                          cwd=str(cwd), env=env, encoding="utf8", dimensions=(30, 120), timeout=1)
    child.logfile_read = screen
    record = {"name": "native-fixture-lane", "agent": "claude", "backend": "rex", "role": "solo",
              "cwd": str(cwd), "workspace": str(cwd), "pid": child.pid,
              "pid_start": idle.proc_identity(child.pid)[1], "agent_status": "idle",
              "agent_session": {"value": native}}
    record_path.write_text(json.dumps(record))

    def pump():
        try:
            child.read_nonblocking(100000, timeout=0.1)
        except pexpect.TIMEOUT:
            pass

    def until(predicate, description, seconds=25):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            pump()
            if predicate():
                return
            if state_path.exists() and json.loads(state_path.read_text()).get("status") == "unavailable":
                raise RuntimeError("Native prerequisite: " + state_path.read_text())
        raise AssertionError(f"Native fixture did not {description}; inspect {directory}")

    def state():
        return json.loads(state_path.read_text()) if state_path.exists() else {}

    def send_mail(text):
        subprocess.run([str(ROOT / "bin/cel"), "inbox", "send", "native-fixture-lane", text,
                        "--from", "fixture-sender", "--workspace", "native-fixture"],
                       cwd=cwd, env=env, check=True, capture_output=True, timeout=10)

    def has_request(text):
        return any(text in json.dumps(request.get("messages", [])) for request in requests)

    blocked_socket, socket_mode = None, None
    try:
        until(lambda: state().get("status") == "idle", "start its receipt-bound native watcher")
        assert not requests, "Idle startup must not call any model endpoint"
        target = state()["target"]
        assert target["pid"] == child.pid and target["session"] == native
        # Native socket rejects a foreign conversation even when the process
        # and Unix socket are real. There is no terminal-input fallback.
        with socket.socket(socket.AF_UNIX) as peer:
            peer.connect(target["socket"])
            peer.sendall((json.dumps({"type": "user", "session_id": str(uuid.uuid4()),
                                     "message": {"role": "user", "content": "FOREIGN_SESSION_MUST_NOT_DELIVER"}}) + "\n").encode())
        for _ in range(10):
            pump()
        assert not requests, "Wrong-session socket event caused a turn"
        draft = "OWNER_UNSUBMITTED_DRAFT_NATIVE_FIXTURE"
        child.send(draft)  # This fixture owns this isolated PTY; never a Rex/live pane.
        for _ in range(5):
            pump()
        blocked_socket = Path(target["socket"])
        socket_mode = stat.S_IMODE(blocked_socket.stat().st_mode)
        blocked_socket.chmod(0)  # deny this fixture's real native socket, not a transport mock
        send_mail("ACTUAL_NATIVE_INBOX_MAIL_ONE")
        until(lambda: state().get("attempts") == 3 and state().get("status") == "retry_backoff", "retain retry debt after three real socket write failures")
        failed = state()
        assert "Permission denied" in failed["error"] and not requests
        assert not (directory / "inbox/native-fixture.native-fixture-lane.cursor").exists()
        failed_message_id, failed_fingerprint = failed["message_id"], failed["fingerprint"]
        blocked_socket.chmod(socket_mode)
        until(lambda: has_request("This is only a wake notification"), "receive a real native idle peer event")
        until(lambda: state().get("status") == "native_received_mail_unread", "reconcile the actual native transcript receipt")
        assert state()["message_id"] == failed_message_id and state()["fingerprint"] == failed_fingerprint
        assert state()["attempts"] == 4, "Same unread mail did not recover after the third failed write"
        retry_deadline = state()["last_attempt"] + 36
        while time.time() < retry_deadline:
            pump()
        assert state()["attempts"] == 4, "Native receipt did not suppress an expired-window retry"
        assert not (directory / "inbox/native-fixture.native-fixture-lane.cursor").exists(), "Wake consumed the mailbox before native hook delivery"
        provider_release.set()
        until(lambda: has_request("ACTUAL_NATIVE_INBOX_MAIL_ONE"), "deliver actual mail through the native Stop continuation")
        until(lambda: state().get("status") == "idle", "observe the hook's canonical inbox drain")
        assert not has_request(draft), "Native wake submitted the owner's draft"
        assert not has_request("FOREIGN_SESSION_MUST_NOT_DELIVER")
        assert has_request("This is only a wake notification"), "No native idle peer event reached the model boundary"
        receipt = state()
        assert idle.receipt_status(target, receipt) == "present", "No authoritative native transcript receipt"
        assert receipt["native_receipt"] in ("user", "queue-operation")
        # Restart only our fixture watcher. A normal native submit hook must
        # recover it as an own-child; no external attach or policy change.
        old_watcher = state()["watcher"]
        with os.fdopen(os.pidfd_open(old_watcher["pid"]), "rb") as watcher_fd:
            assert idle.proc_identity(old_watcher["pid"])[1] == old_watcher["pid_start"]
            signal.pidfd_send_signal(watcher_fd.fileno(), signal.SIGTERM)
        # A later explicit owner Enter must still submit exactly the retained
        # draft, separately from the earlier peer event.
        child.send("\r")
        until(lambda: has_request(draft), "preserve the draft until explicit owner submission")
        until(lambda: json.loads(record_path.read_text())["agent_status"] == "idle", "finish the owner fixture turn")
        until(lambda: state().get("watcher", {}).get("pid") != old_watcher["pid"], "recover its native own-child watcher at the submit boundary")
        send_mail("ACTUAL_NATIVE_INBOX_MAIL_TWO")
        until(lambda: has_request("ACTUAL_NATIVE_INBOX_MAIL_TWO"), "wake again for later mail")
        until(lambda: state().get("status") == "idle", "drain the second message")
        assert all(request["model"] == MODEL for request in requests), "Wake changed the selected model"
        assert json.loads(record_path.read_text())["agent_session"]["value"] == native
        debug = (directory / "debug.log").read_text()
        assert "session_id mismatch" in debug
        assert "Routed user message to queue" in debug
        rows = [json.loads(line) for line in Path(target["transcript"]).read_text().splitlines()]
        native_users = [row for row in rows if row.get("type") == "user" and row.get("sessionId") == native]
        wakes = [row for row in native_users if row.get("origin", {}).get("kind") == "peer"]
        assert len(wakes) == 2, "Native retry or watcher recovery duplicated an idle wake"
        for marker in ("ACTUAL_NATIVE_INBOX_MAIL_ONE", "ACTUAL_NATIVE_INBOX_MAIL_TWO"):
            delivered = [row for row in native_users if marker in str(row.get("message", {}).get("content", ""))]
            assert len(delivered) == 1, "Native hook delivered a mailbox item more than once"
        print("PASS three real socket failures -> same-mail recovery -> exactly-once native Stop delivery; capped-backoff receipt suppression; draft/model/session unchanged", flush=True)
        (directory / "result.json").write_text(json.dumps({"passed": True, "native_session": native,
            "model": MODEL, "request_count": len(requests), "retry_failures": 3,
            "fixture_retry_seconds": [0, 1, 5], "native_policy_unchanged": True, "state": state()}, indent=2))
    finally:
        provider_release.set()
        if blocked_socket is not None and blocked_socket.exists():
            blocked_socket.chmod(socket_mode)
        child.terminate(force=True)
        screen.close()
        server.shutdown()
        # The watcher is target-lifetime-bound. Wait for its lock to be released
        # rather than killing a PID that might already have been reused.
        deadline = time.monotonic() + 12
        lock_path = state_path.parent / "watch.lock"
        if lock_path.exists():
            import fcntl
            with lock_path.open("a") as lock:
                while time.monotonic() < deadline:
                    try:
                        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                        break
                    except BlockingIOError:
                        time.sleep(0.1)
                else:
                    raise AssertionError("Fixture native watcher outlived its target")


if __name__ == "__main__":
    if sys.argv[1:] == ["--hook"]:
        fixture_hook()
    else:
        main()
