"""Stub of the GitHub REST endpoints the Renovate gate reads (monitor-only).

Serves fixed PR data and records every request. GET only: any other method is refused
with 405 and recorded, so the test can show that nothing was written.
GET /_requests returns the recorded requests.
"""
import json
import re
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

REPO = "/repos/Erik142/ansible-playbooks"
RECORDED = []

PULLS = [
    {"number": 7, "title": "chore(deps): update node to v20.1.0", "body": "| node | minor | 20.0.0 -> 20.1.0 |",
     "head": {"ref": "renovate/node-minor", "sha": "aaa111"}},
    {"number": 8, "title": "chore(deps): update node to v26", "body": "| node | major | 22 -> 26 |",
     "head": {"ref": "renovate/node-major", "sha": "bbb222"}},
    {"number": 9, "title": "feat: something by a human", "body": "",
     "head": {"ref": "feature/human", "sha": "ccc333"}},
    {"number": 10, "title": "chore(deps): update geerlingguy.security to v3.1.1", "body": "| security | minor |",
     "head": {"ref": "renovate/security", "sha": "ddd444"}},
    {"number": 11, "title": "chore(deps): update forgejo image", "body": "| forgejo | minor |",
     "head": {"ref": "renovate/pending", "sha": "eee555"}},
]
FILES = {
    7: [{"filename": "nas-de-int-wahlberger-dev/roles/n8n/defaults/main.yml", "additions": 1, "deletions": 1,
         "patch": "@@ -1 +1 @@\n-n8n_image: docker.io/n8nio/n8n:2.48.7\n+n8n_image: docker.io/n8nio/n8n:2.48.8"}],
    8: [{"filename": "roles/n8n/defaults/main.yml", "additions": 1, "deletions": 1, "patch": "major"}],
    10: [{"filename": "nas-de-int-wahlberger-dev/roles/security/tasks/main.yml", "additions": 2, "deletions": 2, "patch": "x"}],
    11: [{"filename": "nas-de-int-wahlberger-dev/roles/forgejo/defaults/main.yml", "additions": 1, "deletions": 1, "patch": "x"}],
}
CHECKS = {
    "aaa111": [{"name": "validate", "status": "completed", "conclusion": "success"},
               {"name": "n8n-hook", "status": "completed", "conclusion": "success"}],
    "bbb222": [{"name": "validate", "status": "completed", "conclusion": "success"}],
    "ddd444": [{"name": "validate", "status": "completed", "conclusion": "success"}],
    "eee555": [{"name": "validate", "status": "in_progress", "conclusion": None}],
}


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, payload):
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _record(self, method):
        RECORDED.append({"method": method, "path": self.path, "authorization": self.headers.get("Authorization")})

    def do_GET(self):
        path = self.path.split("?")[0]
        if path != "/_requests":  # the test's own query is not a workflow request
            self._record("GET")
        if path == REPO + "/pulls":
            return self._send(200, PULLS)
        m = re.fullmatch(REPO + r"/pulls/(\d+)/files", path)
        if m:
            return self._send(200, FILES.get(int(m.group(1)), []))
        if path == REPO + "/actions/runs":
            sha = self.path.split("head_sha=")[1].split("&")[0] if "head_sha=" in self.path else ""
            return self._send(200, {"workflow_runs": CHECKS.get(sha, [])})
        if path == "/_requests":
            return self._send(200, RECORDED)
        return self._send(404, {"message": "Not Found"})

    def _refuse(self):
        self._record(self.command)
        self._send(405, {"message": "monitor-only: writes are not allowed"})

    do_POST = do_PATCH = do_PUT = do_DELETE = _refuse

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    HTTPServer(("0.0.0.0", int(sys.argv[1]) if len(sys.argv) > 1 else 8080), Handler).serve_forever()
