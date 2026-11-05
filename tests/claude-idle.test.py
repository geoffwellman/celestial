import importlib.util
import json
import os
from pathlib import Path
import socket
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("claude_idle", ROOT / "tools/hooks/claude-idle-mail.py")
idle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(idle)


class IdleMailTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.path = Path(self.directory.name)
        self.record = self.path / "lane.json"
        self.state_path = self.path / "state.json"
        self.native = "6b90062c-f7b9-4cf4-859c-6bba6e90df1d"
        self.target = {"pid": os.getpid(), "pid_start": idle.proc_identity(os.getpid())[1],
                       "session": self.native, "name": "lane", "workspace": "demo",
                       "workspace_path": str(self.path), "cwd": str(self.path),
                       "socket": str(self.path / "native.sock"),
                       "transcript": str(self.path / (self.native + ".jsonl"))}
        self.row = {"agent": "claude", "backend": "rex", "pid": self.target["pid"],
                    "pid_start": self.target["pid_start"], "name": "lane",
                    "workspace": str(self.path), "cwd": str(self.path),
                    "agent_session": {"value": self.native}, "agent_status": "idle"}
        self.record.write_text(json.dumps(self.row))
        self.state = {"target": self.target, "attempts": 0}

    def tick(self, fingerprint, now):
        with patch.object(idle, "unread", return_value=fingerprint):
            idle.tick(str(ROOT), str(self.record), self.state_path, self.target, self.state, now)

    def test_wake_is_not_delivery_and_retry_is_bounded_across_watcher_restart(self):
        cursor = self.path / "demo.lane.cursor"
        cursor.write_text("unconsumed")
        with patch.object(idle, "send_wake") as send:
            self.tick("mail-one", 1000)
            self.tick("mail-one", 1005)
            self.assertEqual(send.call_count, 1)
            self.state = json.loads(self.state_path.read_text())
            self.tick("mail-one", 1030)
            self.tick("mail-one", 1150)
            self.tick("mail-one", 9999)
            self.assertEqual(send.call_count, 3)
            self.assertEqual(len({call.args[1] for call in send.call_args_list}), 1)
            self.assertEqual(self.state["status"], "waiting_for_delivery")
        self.assertEqual(cursor.read_text(), "unconsumed")

    def test_later_mail_and_native_drain_rearm_notifications(self):
        with patch.object(idle, "send_wake") as send:
            self.tick("one", 1000)
            self.tick("two-same-count-new-id", 1005)
            self.assertEqual(send.call_count, 2)
            self.assertNotEqual(send.call_args_list[0].args[1], send.call_args_list[1].args[1])
            self.tick(None, 1010)
            self.assertEqual(self.state["status"], "idle")
            self.tick("three", 1015)
            self.assertEqual(send.call_count, 3)

    def test_busy_session_defers_without_consuming_or_sending(self):
        self.row["agent_status"] = "working"
        self.record.write_text(json.dumps(self.row))
        with patch.object(idle, "send_wake") as send:
            self.tick("one", 1000)
            send.assert_not_called()
        self.assertEqual(self.state["attempts"], 0)

    def test_identity_mismatch_refuses_before_mail_observation(self):
        for key, value in [("pid_start", "reused-pid"), ("session", "wrong-session"),
                           ("name", "other-lane"), ("workspace_path", "/foreign"), ("cwd", "/foreign")]:
            with self.subTest(key=key), patch.object(idle, "unread") as unread:
                target = dict(self.target, **{key: value})
                with self.assertRaises(ValueError):
                    idle.tick(str(ROOT), str(self.record), self.state_path, target, self.state, 1000)
                unread.assert_not_called()

    def test_socket_peer_identity_is_checked_not_just_path_or_uid(self):
        listener = socket.socket(socket.AF_UNIX)
        self.addCleanup(listener.close)
        listener.bind(self.target["socket"])
        listener.listen()
        target = dict(self.target, pid=os.getppid())
        with self.assertRaisesRegex(ValueError, "different process"):
            idle.send_wake(target, self.native)

    def test_unavailable_socket_retains_debt_and_never_marks_delivered(self):
        with patch.object(idle, "send_wake", side_effect=FileNotFoundError("native socket absent")):
            self.tick("one", 1000)
        self.assertEqual(self.state["status"], "waiting_for_delivery")
        self.assertEqual(self.state["fingerprint"], "one")
        self.assertEqual(self.state["attempts"], 1)

    def test_selector_uses_real_canonical_unread_and_does_not_advance_cursor(self):
        inbox = self.path / "inbox"
        inbox.mkdir()
        message = {"id": "00000000000000000001", "to": "lane", "from": "sender",
                   "kind": "status", "message": "retained native mail", "ts": "2026-11-06T00:00:00Z"}
        (inbox / "demo.jsonl").write_text(json.dumps(message) + "\n")
        with patch.dict(os.environ, {"CEL_INBOX_DIR": str(inbox), "CEL_INBOX_ME": "lane"}):
            first = idle.unread(str(ROOT), self.target)
            self.assertIsNotNone(first)
            self.assertEqual(idle.unread(str(ROOT), self.target), first)
            self.assertFalse((inbox / "demo.lane.cursor").exists())
            (inbox / "demo.lane.cursor").write_text(message["id"])
            self.assertIsNone(idle.unread(str(ROOT), self.target))

    def test_native_queue_receipt_suppresses_retry_after_native_dedup_expiry(self):
        with patch.object(idle, "send_wake") as send:
            self.tick("one", 1000)
            row = {"type": "queue-operation", "operation": "enqueue", "sessionId": self.native,
                   "content": idle.wake_content(self.target, self.state["message_id"])}
            Path(self.target["transcript"]).write_text(json.dumps(row) + "\n")
            self.state = json.loads(self.state_path.read_text())
            self.tick("one", 1000000)
            self.assertEqual(send.call_count, 1)
            self.assertEqual(self.state["status"], "native_received_mail_unread")
            self.assertEqual(self.state["attempts"], 1)

    def test_receipt_reader_ignores_nested_request_copies_and_foreign_sessions(self):
        with patch.object(idle, "send_wake") as send:
            self.tick("one", 1000)
            copied = {"type": "api-request-blob", "sessionId": self.native,
                      "message": {"uuid": self.state["message_id"], "type": "user", "origin": {"kind": "peer"}}}
            foreign = {"type": "user", "sessionId": "foreign", "uuid": self.state["message_id"], "origin": {"kind": "peer"}}
            Path(self.target["transcript"]).write_text(json.dumps(copied) + "\n" + json.dumps(foreign) + "\n")
            self.tick("one", 1030)
            self.assertEqual(send.call_count, 2)

    def test_receipt_partial_error_freezes_cursor_then_recovers_without_retry(self):
        with patch.object(idle, "send_wake") as send:
            self.tick("one", 1000)
            transcript = Path(self.target["transcript"])
            transcript.write_text(json.dumps({"type": "mode", "sessionId": self.native}) + "\n")
            self.tick("one", 1005)
            cursor = dict(self.state["receipt_cursor"])
            row = {"type": "user", "sessionId": self.native, "uuid": self.state["message_id"], "origin": {"kind": "peer"}}
            encoded = json.dumps(row)
            with transcript.open("a") as stream:
                stream.write(encoded[:20])
            self.tick("one", 1030)
            self.assertEqual(self.state["receipt_cursor"], cursor)
            self.assertEqual(self.state["status"], "receipt_unknown_mail_unread")
            with transcript.open("a") as stream:
                stream.write(encoded[20:] + "\n")
            self.tick("one", 1000000)
            self.assertEqual(send.call_count, 1)
            self.assertEqual(self.state["native_receipt"], "user")

    def test_attach_requires_canonical_reader_record_and_native_transcript_binding(self):
        transcript = Path(self.target["transcript"])
        transcript.write_text(json.dumps({"type": "user", "sessionId": self.native, "cwd": str(self.path)}) + "\n")
        with patch.dict(os.environ, {"CEL_REX_STATE": str(self.path)}), patch.object(idle, "connect_peer") as connect:
            idle.validate_attach(str(self.record), self.target)
            connect.assert_called_once_with(self.target)
            connect.reset_mock()
            with self.assertRaisesRegex(ValueError, "canonical"):
                idle.validate_attach(str(self.record), dict(self.target, name="other-reader"))
            connect.assert_not_called()
            transcript.write_text(json.dumps({"type": "user", "sessionId": "foreign", "cwd": str(self.path)}) + "\n")
            with self.assertRaisesRegex(ValueError, "does not prove"):
                idle.validate_attach(str(self.record), self.target)
            connect.assert_not_called()




if __name__ == "__main__":
    unittest.main()
