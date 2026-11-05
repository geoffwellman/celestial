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
import tempfile
import threading
import time
import uuid

import pexpect

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("claude_idle", ROOT / "tools/hooks/claude-idle-mail.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)
MODEL = "claude-sonnet-4-6"


def main():
    if not shutil.which("claude"):
        raise RuntimeError("Prerequisite: installed native Claude Code with Unix peer messaging")
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
    record_path = directory / "rex/lane.json"
    state_path = Path(str(record_path) + ".inbox/state.json")
    requests = []

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
           "CEL_ROOT": str(ROOT), "CEL_REX_RECORD": str(record_path),
           "CEL_REX_STATE": str(directory / "rex"), "CEL_AGENT_NAME": "native-fixture-lane",
           "CEL_INBOX_ME": "native-fixture-lane", "CEL_INBOX_WS": "native-fixture",
           "CEL_INBOX_DIR": str(directory / "inbox"), "CEL_ORCH_SESSIONS": str(directory / "sessions.json")}
    settings = {"hooks": {
        "SessionStart": [{"hooks": [{"type": "command", "command": f"bash {ROOT}/tools/hooks/claude-session.sh", "timeout": 10}]}],
        "UserPromptSubmit": [{"hooks": [{"type": "command", "command": f"bash {ROOT}/tools/hooks/claude-session.sh", "timeout": 10}]}],
        "Stop": [{"hooks": [{"type": "command", "command": f"bash {ROOT}/tools/hooks/inbox-stop.sh", "timeout": 10}]}]}}
    screen = (directory / "screen.log").open("w")
    child = pexpect.spawn("claude", ["--setting-sources", "", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}',
                                     "--settings", json.dumps(settings), "--debug-file", str(directory / "debug.log"),
                                     "--session-id", native, "--model", MODEL],
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
        send_mail("ACTUAL_NATIVE_INBOX_MAIL_ONE")
        until(lambda: has_request("ACTUAL_NATIVE_INBOX_MAIL_ONE"), "deliver actual mail through the native Stop continuation")
        until(lambda: state().get("status") == "idle", "observe the hook's canonical inbox drain")
        assert not has_request(draft), "Native wake submitted the owner's draft"
        assert not has_request("FOREIGN_SESSION_MUST_NOT_DELIVER")
        assert has_request("This is only a wake notification"), "No native idle peer event reached the model boundary"
        before_retry = len(requests)
        idle.send_wake(target, state()["message_id"])
        for _ in range(10):
            pump()
        assert len(requests) == before_retry, "Native retry duplicated an already delivered peer event"
        # Restart only our fixture watcher, not Claude. The next native hook
        # must reacquire its lock and recover the same durable state.
        old_watcher = state()["watcher"]
        with os.fdopen(os.pidfd_open(old_watcher["pid"]), "rb") as watcher_fd:
            assert idle.proc_identity(old_watcher["pid"])[1] == old_watcher["pid_start"]
            signal.pidfd_send_signal(watcher_fd.fileno(), signal.SIGTERM)
        # A later explicit owner Enter must still submit exactly the retained
        # draft, separately from the earlier peer event.
        child.send("\r")
        until(lambda: has_request(draft), "preserve the draft until explicit owner submission")
        until(lambda: json.loads(record_path.read_text())["agent_status"] == "idle", "finish the owner fixture turn")
        until(lambda: state().get("watcher", {}).get("pid") != old_watcher["pid"], "recover its fixture watcher after a hook boundary")
        send_mail("ACTUAL_NATIVE_INBOX_MAIL_TWO")
        until(lambda: has_request("ACTUAL_NATIVE_INBOX_MAIL_TWO"), "wake again for later mail")
        until(lambda: state().get("status") == "idle", "drain the second message")
        assert all(request["model"] == MODEL for request in requests), "Wake changed the selected model"
        assert json.loads(record_path.read_text())["agent_session"]["value"] == native
        debug = (directory / "debug.log").read_text()
        assert "session_id mismatch" in debug
        assert "Routed user message to queue" in debug
        assert "Dropped peer message from unknown: duplicate" in debug
        print("PASS real native idle peer event -> Stop-hook inbox delivery; later mail rearmed; foreign session refused; draft retained; model/session unchanged", flush=True)
        (directory / "result.json").write_text(json.dumps({"passed": True, "native_session": native,
            "model": MODEL, "request_count": len(requests), "state": state()}, indent=2))
    finally:
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
    main()
