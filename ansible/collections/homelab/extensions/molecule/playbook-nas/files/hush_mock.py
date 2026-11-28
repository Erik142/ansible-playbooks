#!/usr/bin/env python3
"""Stand-in for the Hush API in the nas molecule scenario.

Records every request (method, path, body) to LOG and answers like Hush does for
maintenance windows: 201 for POST, 200 for DELETE. Nothing else is simulated.
"""

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = "/var/log/hush-mock.log"


class Handler(BaseHTTPRequestHandler):
    def _handle(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length).decode() if length else ""
        with open(LOG, "a") as log:
            log.write(f"{self.command} {self.path} {body}\n")
        self.send_response(201 if self.command == "POST" else 200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b"{}")

    do_GET = do_POST = do_DELETE = _handle

    def log_message(self, *args):
        pass


ThreadingHTTPServer(("127.0.0.1", 8099), Handler).serve_forever()
