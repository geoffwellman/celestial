#!/usr/bin/env python3
"""A synthetic Anthropic /v1/messages upstream for tests/live (CEL-136).

Usage: fake_anthropic.py PORT NAME MODE LOG
  MODE=ok        -> a minimal reply, as SSE when the request asks to stream
  MODE=exhausted -> 429 with unified rate-limit headers (5h window spent)
Every request appends one JSON line to LOG naming which upstream was hit and
what the gateway forwarded (model, thinking, effort) - never a header value.
No real provider is contacted.
"""
import json, os, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT, NAME, MODE, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def _send(self, code, payload, ctype="application/json", extra=None):
        data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("content-length", str(len(data)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        n = int(self.headers.get("content-length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        if not self.path.startswith("/v1/messages"):
            self._send(404, {"type": "error", "error": {"type": "not_found_error", "message": self.path}})
            return
        with open(LOG, "a") as f:
            f.write(json.dumps({
                "upstream": NAME, "mode": MODE, "path": self.path.split("?")[0],
                "model": body.get("model"), "stream": bool(body.get("stream")),
                "thinking": (body.get("thinking") or {}).get("type"),
                "effort": (body.get("output_config") or {}).get("effort"),
                # the session header's value is a test fixture, never a secret
                "session": self.headers.get("x-session-id"),
                "key_ok": os.environ.get("FAKE_EXPECT_KEY", "\0") in (
                    self.headers.get("x-api-key") or "",
                    (self.headers.get("authorization") or "").removeprefix("Bearer ")),
            }) + "\n")
        if MODE == "exhausted":
            reset = str(int(time.time()) + 3600)
            self._send(429, {"type": "error", "error": {"type": "rate_limit_error",
                       "message": "This request would exceed your account's rate limit."}},
                       extra={"retry-after": "3600",
                              "anthropic-ratelimit-unified-status": "rejected",
                              "anthropic-ratelimit-unified-reset": reset,
                              "anthropic-ratelimit-unified-5h-status": "rejected",
                              "anthropic-ratelimit-unified-5h-utilization": "1.0",
                              "anthropic-ratelimit-unified-5h-reset": reset,
                              "anthropic-ratelimit-unified-representative-claim": "five_hour"})
            return
        model, text = body.get("model", "x"), f"pong from {NAME}"
        msg = {"id": "msg_fake", "type": "message", "role": "assistant", "model": model,
               "content": [], "stop_reason": None, "stop_sequence": None,
               "usage": {"input_tokens": 1, "output_tokens": 1}}
        if not body.get("stream"):
            msg.update(content=[{"type": "text", "text": text}], stop_reason="end_turn")
            self._send(200, msg)
            return
        ev = [("message_start", {"type": "message_start", "message": msg}),
              ("content_block_start", {"type": "content_block_start", "index": 0,
                                       "content_block": {"type": "text", "text": ""}}),
              ("content_block_delta", {"type": "content_block_delta", "index": 0,
                                       "delta": {"type": "text_delta", "text": text}}),
              ("content_block_stop", {"type": "content_block_stop", "index": 0}),
              ("message_delta", {"type": "message_delta",
                                 "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                 "usage": {"output_tokens": 3}}),
              ("message_stop", {"type": "message_stop"})]
        sse = "".join(f"event: {e}\ndata: {json.dumps(d)}\n\n" for e, d in ev).encode()
        self._send(200, sse, ctype="text/event-stream")

    do_GET = do_POST


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
