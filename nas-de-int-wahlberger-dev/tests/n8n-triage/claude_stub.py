"""Stub of the Anthropic Messages API for tests/n8n-triage/run.sh.

POST /v1/messages   -> returns a fixed text reply and records the request body.
GET  /_requests     -> the recorded request bodies (JSON list), for assertions.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

RECORDED = []
REVIEW = '{"verdict": "safe", "reasons": ["patch-level container bump"], "patch_summary": ""}'
REPLY = ("Likely cause: caddy restarted after a config change.\n"
         "Next check: journalctl -u caddy --since -1h.\n"
         "PROPOSED_ACTION: restart caddy.service")


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length).decode()
        try:
            RECORDED.append({"path": self.path, "headers": dict(self.headers), "body": json.loads(raw)})
        except json.JSONDecodeError:
            RECORDED.append({"path": self.path, "headers": dict(self.headers), "raw": raw})
        prompt = json.dumps(RECORDED[-1].get("body", {}))
        text = REVIEW if "merge safety" in prompt else REPLY
        self._send(200, {"id": "msg_stub", "type": "message", "role": "assistant",
                         "content": [{"type": "text", "text": text}]})

    def do_GET(self):
        if self.path == "/_requests":
            self._send(200, RECORDED)
        else:
            self._send(404, {"error": "not found"})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8080), Handler).serve_forever()
