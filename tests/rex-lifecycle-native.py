#!/usr/bin/env python3
"""Opt-in Rex lifecycle proof; --claude also uses real Claude and a loopback provider.

Every CLI call targets a private socket with autostart disabled. No live server,
credentials, configuration, inbox, session destruction, or provider inference.
"""
import argparse
import http.server
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
MODEL = "claude-sonnet-5-5"


def until(predicate, description):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError(description)


def identity(pid):
    try:
        return Path(f"/proc/{pid}/stat").read_text().rsplit(") ", 1)[1].split()[19]
    except FileNotFoundError:
        return None


class Fixture:
    def __init__(self):
        self.directory = Path(tempfile.mkdtemp(prefix="cel-rex-lifecycle-"))
        self.directory.chmod(0o700)
        print(f"Isolated fixture: {self.directory}", flush=True)
        for name in ("home", "config", "state", "data", "runtime", "bin", "ws", "receipts"):
            (self.directory / name).mkdir(mode=0o700)
        self.socket = self.directory / "runtime/rex.sock"
        self.rex = shutil.which("rex")
        if not self.rex:
            raise RuntimeError("Prerequisite: native Rex CLI and server")
        self.env = {"PATH": os.environ["PATH"], "HOME": str(self.directory / "home"),
                    "TERM": "xterm-256color", "LANG": "C.UTF-8",
                    "SHELL": shutil.which("zsh") or "/bin/sh"}
        for name in ("CONFIG", "STATE", "DATA", "RUNTIME"):
            self.env[f"XDG_{name}_HOME" if name != "RUNTIME" else "XDG_RUNTIME_DIR"] = str(self.directory / name.lower())
        (self.directory / "empty.lua").write_text("")
        self.log = (self.directory / "server.log").open("wb")
        self.server_command = [self.rex, "server", "run", "--listen", f"unix://{self.socket}",
            "--state-dir", str(self.directory / "server-state"), "--restore=true", "--config",
            str(self.directory / "empty.lua")]
        self.server = subprocess.Popen(self.server_command, env=self.env, stdout=self.log, stderr=subprocess.STDOUT)
        self.server_start = identity(self.server.pid)
        self.owned_blocks = []
        self.owned_processes = []
        self.provider = None
        self.requests = []
        until(lambda: self.socket.exists() or self.server.poll() is not None, "Private Rex did not start")
        assert self.server.poll() is None, "Private Rex server failed; inspect server.log"
        wrapper = self.directory / "bin/rex"
        wrapper.write_text(f"#!/bin/bash\nexec {shlex.quote(self.rex)} --autostart=false -S {shlex.quote('unix://' + str(self.socket))} \"$@\"\n")
        wrapper.chmod(0o700)
        stub = self.directory / "bin/native-stub"
        stub.write_text("#!/usr/bin/python3\nimport json,os,sys\nfrom pathlib import Path\n"
            "Path(os.environ['CEL_REX_STATE'],os.environ['CEL_AGENT_NAME']+'.observed').write_text("
            "json.dumps({'pid':os.getpid(),'args':sys.argv[1:]}))\n"
            "print('FIXTURE_READY',flush=True)\n"
            "for line in sys.stdin:\n    if line.strip()=='/exit': break\n")
        stub.chmod(0o700)
        manifest = self.directory / "agents.yaml"
        manifest.write_text("agents:\n" + "".join(f"  {rt}:\n    bin: {stub}\n" for rt in ("claude", "omp", "pi")))
        (self.directory / "ws/workspace.yaml").write_text("name: fixture\nrepos: []\n")
        self.launch_env = dict(self.env, CEL_ROOT=str(ROOT), CEL_REX_BIN=str(wrapper),
            CEL_REX_STATE=str(self.directory / "receipts"), CEL_MANIFEST=str(manifest),
            CEL_MANIFEST_CACHE=str(self.directory / "manifest-cache"))

    def cli(self, *args, check=True):
        assert self.socket.parent == self.directory / "runtime" and self.directory.stat().st_uid == os.getuid()
        result = subprocess.run([self.rex, "--autostart=false", "-S", f"unix://{self.socket}", *args],
            env=self.env, text=True, capture_output=True, timeout=10)
        if check and result.returncode:
            raise AssertionError(f"Private Rex {args}: {result.stderr}")
        return result

    def shell(self, code, *args):
        result = subprocess.run(["/bin/bash", "-c",
            'source "$CEL_ROOT/lib/common.sh"; source "$CEL_ROOT/lib/run.sh"; '
            'wsdir="$HOME/../ws"; env_role=solo; ' + code, "fixture", *args],
            env=self.launch_env, text=True, capture_output=True, timeout=20)
        assert result.returncode == 0, result.stdout + result.stderr
        return result.stdout

    def launch(self, rt, name, args, pane=None):
        code = 'rt="$1"; name="$2"; pane="$3"; shift 3; prefix="$(_run_launch_env solo "$wsdir" "" "$name" "$rt")"; '
        if pane:
            code += 'AGENT_ARGS=("$@"); _run_restart_in_place solo "$pane" fixture "$prefix" "$prefix" 0 0 "$name" "$rt" "$wsdir"'
        else:
            code += '_rex_launch "$name" "$rt" "$wsdir" fixture "$prefix" "$@"'
        self.shell(code, rt, name, pane or "", *args)
        record = json.loads((self.directory / f"receipts/{name}.json").read_text())
        self.owned_blocks.append((record["rex_session"], record["rex_block"]))
        self.owned_processes.append((record["pid"], record["pid_start"]))
        return record

    def blocks(self, session):
        return json.loads(self.cli("api", "call", "-s", session, "session.list_blocks").stdout)["blocks"]

    def process(self, record):
        return json.loads(self.cli("block", "call", "-s", record["rex_session"], "-b", record["rex_block"], "process").stdout)

    def owned_pid(self, record):
        until(lambda: self.process(record).get("child", {}).get("pid") == record["pid"], "Receipt PID differs from actual terminal child")
        assert self.process(record)["foreground"]["pid"] == record["pid"]

    def send(self, record, text):
        self.cli("send", "-s", record["rex_session"], "-b", record["rex_block"], text)
        self.cli("send-key", "-s", record["rex_session"], "-b", record["rex_block"], "enter")

    def exited(self, record):
        until(lambda: identity(record["pid"]) != record["pid_start"], "Native process survived its exit")
        until(lambda: all(b["block_id"] != record["rex_block"] for b in self.blocks(record["rex_session"])),
              "Exited native process left its old shell-flavored Rex block")

    def test_stub_lifecycle(self, rt):
        native = str(uuid.uuid4())
        args = ["--resume", native, "--model", MODEL]
        name = f"fixture-{rt}"
        first = self.launch(rt, name, args)
        self.owned_pid(first)
        observed = self.directory / f"receipts/{name}.observed"
        until(observed.exists, "Native stub did not execute")
        assert json.loads(observed.read_text()) == {"pid": first["pid"], "args": args}
        if rt == "claude":
            self.send(first, "/exit")
            self.exited(first)
        second = self.launch(rt, name, args, first["pane_id"])
        self.exited(first)
        self.owned_pid(second)
        extra = json.loads(self.cli("window", "new", "-s", second["rex_session"], "owner-window",
            "--cwd", str(self.directory / "ws"), "--json").stdout)
        user = dict(second, rex_block=extra["block_ids"][0])
        self.owned_blocks.append((user["rex_session"], user["rex_block"]))
        user_pid = self.process(user)["child"]["pid"]
        user_start = identity(user_pid)
        self.owned_processes.append((user_pid, user_start))
        third = self.launch(rt, name, args, second["pane_id"])
        self.exited(second)
        assert identity(user_pid) == user_start, "Restart stopped an extra user window"
        assert self.process(user)["child"]["pid"] == user_pid
        assert [b["block_id"] for b in self.blocks(second["rex_session"])] == [user["rex_block"]]
        if rt == "claude":
            self.send(third, "/exit")
            self.exited(third)
        self.shell('rex_agent_stop "$1"', third["pane_id"])
        self.exited(third)
        print(f"PASS test_{rt}_native_restart_pid_args_and_extra_user_window", flush=True)

    def test_server_restore(self):
        original = self.launch("claude", "fixture-restore", ["--resume", str(uuid.uuid4()), "--model", MODEL])
        self.owned_pid(original)
        assert identity(self.server.pid) == self.server_start
        self.server.terminate()
        self.server.wait(timeout=10)
        until(lambda: identity(original["pid"]) != original["pid_start"], "Original runtime survived server stop")
        self.server = subprocess.Popen(self.server_command, env=self.env, stdout=self.log, stderr=subprocess.STDOUT)
        self.server_start = identity(self.server.pid)
        until(self.socket.exists, "Owned server did not restore")
        blocks = self.blocks(original["rex_session"])
        assert len(blocks) == 1, "Server did not restore its original terminal"
        restored = dict(original, rex_block=blocks[0]["block_id"])
        self.owned_blocks.append((restored["rex_session"], restored["rex_block"]))
        process = self.process(restored)["child"]
        pid = process["pid"]
        start = identity(pid)
        self.owned_processes.append((pid, start))
        assert pid != original["pid"] and process["path"] == os.path.realpath(self.env["SHELL"])
        # This is NOT the receipt's process. A dead native receipt must never
        # authorize closing the replacement shell, even with the same block ID.
        self.shell('rex_agent_stop "$1"', original["pane_id"])
        assert identity(pid) == start and self.process(restored)["child"]["pid"] == pid
        self.cli("block", "close", "-s", restored["rex_session"], restored["rex_block"])
        until(lambda: identity(pid) != start, "Exact fixture restored shell survived cleanup")
        print("PASS test_server_restore_replacement_shell_is_not_original_native_process", flush=True)
        print("LIMIT Rex restores command terminals as new default shells; no per-block restore policy in revision 10", flush=True)

    def test_claude_lifecycle(self):
        binary = shutil.which("claude")
        if not binary:
            raise RuntimeError("Prerequisite: installed native Claude Code")
        print(subprocess.check_output([binary, "--version"], text=True).strip(), flush=True)
        fixture = self

        class Provider(http.server.BaseHTTPRequestHandler):
            def do_POST(self):
                body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
                if self.path.endswith("/count_tokens"):
                    self.send_response(200); self.end_headers(); self.wfile.write(b'{"input_tokens":1}'); return
                fixture.requests.append(body)
                events = [
                    ("message_start", {"type": "message_start", "message": {"id": "msg_fixture", "type": "message", "role": "assistant", "model": MODEL, "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 1, "output_tokens": 0}}}),
                    ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                    ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": "Local fixture response. No provider inference."}}),
                    ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                    ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 1}}),
                    ("message_stop", {"type": "message_stop"})]
                self.send_response(200); self.send_header("Content-Type", "text/event-stream"); self.end_headers()
                for event, value in events:
                    self.wfile.write(f"event: {event}\ndata: {json.dumps(value)}\n\n".encode())
                self.wfile.flush()

            def log_message(self, *args):
                pass

        self.provider = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Provider)
        threading.Thread(target=self.provider.serve_forever, daemon=True).start()
        key = "fixture-not-a-real-credential"
        (self.directory / "config/.claude.json").write_text(json.dumps({"hasCompletedOnboarding": True,
            "theme": "dark", "customApiKeyResponses": {"approved": [key[-20:]], "rejected": []},
            "projects": {str(self.directory / "ws"): {"hasTrustDialogAccepted": True}}}))
        settings = {"CLAUDE_CONFIG_DIR": str(self.directory / "config"), "ANTHROPIC_API_KEY": key,
            "ANTHROPIC_BASE_URL": f"http://127.0.0.1:{self.provider.server_port}", "DISABLE_AUTOUPDATER": "1",
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "HTTP_PROXY": "http://127.0.0.1:1",
            "HTTPS_PROXY": "http://127.0.0.1:1", "ALL_PROXY": "http://127.0.0.1:1", "NO_PROXY": "127.0.0.1,localhost",
            "GIT_SSH_COMMAND": "/bin/false", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1"}
        (self.directory / "ws/env.local").write_text("".join(f"{k}={shlex.quote(v)}\n" for k, v in settings.items()))
        manifest = self.directory / "native-agents.yaml"
        manifest.write_text(f"agents:\n  claude:\n    bin: {binary}\n")
        self.launch_env["CEL_MANIFEST"] = str(manifest)
        native = str(uuid.uuid4())
        args = ["--model", MODEL, "--setting-sources", "user", "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--settings", '{"hooks":{}}']
        # Exact historical delta: this fixture-only CLI wrapper adds the
        # already-published --keep-open flag, without editing production code.
        canonical_cli = self.launch_env["CEL_REX_BIN"]
        legacy_cli = self.directory / "bin/rex-keep-open"
        legacy_cli.write_text('#!/bin/bash\nif [ "$1" = new ]; then shift; set -- new --keep-open "$@"; fi\n'
            + f'exec {shlex.quote(canonical_cli)} "$@"\n')
        legacy_cli.chmod(0o700)
        self.launch_env["CEL_REX_BIN"] = str(legacy_cli)
        first = self.launch("claude", "fixture-native", ["--session-id", native, *args])
        self.owned_pid(first)
        until(lambda: "Claude Code" in self.cli("capture", "-s", first["rex_session"], "-b", first["rex_block"], "--trim").stdout, "Real Claude did not become ready")
        self.send(first, "Return the deterministic fixture response.")
        until(lambda: self.requests, "Real Claude did not reach loopback provider")
        until(lambda: "Local fixture response." in self.cli("capture", "-s", first["rex_session"], "-b", first["rex_block"], "--trim").stdout, "Local turn did not finish")
        self.send(first, "/exit")
        until(lambda: identity(first["pid"]) != first["pid_start"], "Native Claude did not exit")
        assert self.process(first)["last_exit"]["exit_code"] == 0 and not self.process(first).get("child")
        assert len(self.blocks(first["rex_session"])) == 1
        print("BEFORE --keep-open: native exit_code=0 child=null old_blocks=1", flush=True)
        self.launch_env["CEL_REX_BIN"] = canonical_cli
        resumed = self.launch("claude", "fixture-native", ["--resume", native, *args], first["pane_id"])
        assert len(self.blocks(first["rex_session"])) == 1, "Dead PID unexpectedly authorized terminal deletion"
        self.cli("block", "close", "-s", first["rex_session"], first["rex_block"])
        self.owned_pid(resumed)
        assert resumed["agent_session"]["value"] == native
        cmdline = Path(f'/proc/{resumed["pid"]}/cmdline').read_bytes().split(b"\0")
        assert b"--resume" in cmdline and native.encode() in cmdline and MODEL.encode() in cmdline
        until(lambda: "Claude Code" in self.cli("capture", "-s", resumed["rex_session"], "-b", resumed["rex_block"], "--trim").stdout, "Native UUID was not resumed")
        self.send(resumed, "/exit")
        self.exited(resumed)
        view = json.loads(self.cli("api", "call", "-s", resumed["rex_session"], "session.view").stdout)
        print(f'AFTER omitted: old_blocks={len(self.blocks(resumed["rex_session"]))} windows={len(view.get("windows") or [])} session_present=true', flush=True)
        self.shell('rex_agent_stop "$1"', resumed["pane_id"])
        assert all(request["model"] == MODEL for request in self.requests)
        print("PASS test_real_claude_native_exit_restart_preserves_uuid_model_and_no_old_block", flush=True)
        print(f"Loopback requests: {len(self.requests)}; paid inference: none", flush=True)

    def close(self):
        if self.provider:
            self.provider.shutdown()
            self.provider.server_close()
        # No session.destroy, conditional or otherwise. Only returned fixture
        # block IDs at this private socket, then the exact foreground server PID.
        if self.server.poll() is None and identity(self.server.pid) == self.server_start:
            for session, block in self.owned_blocks:
                self.cli("block", "close", "-s", session, block, check=False)
            self.server.terminate()
            self.server.wait(timeout=10)
        self.log.close()
        until(lambda: all(identity(pid) != start for pid, start in self.owned_processes), "Owned fixture process survived cleanup")
        assert self.server.poll() is not None, "Owned Rex server survived cleanup"
        assert not self.socket.exists(), "Owned Rex socket survived cleanup"
        shutil.rmtree(self.directory)
        print("PASS test_exact_owned_fixture_process_and_socket_cleanup", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--claude", action="store_true", help="Also exercise installed Claude against a loopback fake provider")
    args = parser.parse_args()
    fixture = Fixture()
    try:
        print(subprocess.check_output([fixture.rex, "version"], text=True).strip(), flush=True)
        fixture.test_server_restore()
        for rt in ("claude", "omp", "pi"):
            fixture.test_stub_lifecycle(rt)
        if args.claude:
            fixture.test_claude_lifecycle()
    finally:
        fixture.close()


if __name__ == "__main__":
    main()
