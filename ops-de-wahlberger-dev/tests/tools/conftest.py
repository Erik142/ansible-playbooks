"""Shared fixtures: tools on sys.path, a fake Semaphore HTTP server, a throwaway
Semaphore container (skipped with an explicit reason when Docker or the image is absent)."""

from __future__ import annotations

import base64
import http.cookiejar
import json
import os
import shutil
import socket
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
import uuid
from collections.abc import Callable, Iterator
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import pytest

TOOLS = Path(__file__).resolve().parents[2] / "tools"
sys.path.insert(0, str(TOOLS))

IMAGE = "semaphoreui/semaphore:v2.19.16"
ADMIN = "admin"
CONTAINER_NAMES: dict[str, str] = {}  # base url -> container name (for docker cp)
ADMIN_PASSWORD = "throwaway-pw-for-tests"


BASE_PATH = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"


def find_ansible_vault() -> Path | None:
    """A working ansible-vault binary: $ANSIBLE_VAULT_BIN, PATH, or any pyenv virtualenv."""
    candidates = [os.environ.get("ANSIBLE_VAULT_BIN"), shutil.which("ansible-vault")]
    versions = Path.home() / ".pyenv/versions"
    candidates += sorted(str(p) for p in versions.glob("*/envs/*/bin/ansible-vault"))
    candidates += sorted(str(p) for p in versions.glob("*/bin/ansible-vault"))
    for cand in filter(None, candidates):
        probe = subprocess.run([cand, "--version"], capture_output=True, check=False, timeout=60)
        if probe.returncode == 0:
            return Path(cand)
    return None


def run_tool(
    name: str, *args: str, env: dict[str, str] | None = None, cwd: Path | None = None
) -> subprocess.CompletedProcess[str]:
    base_env = {"PATH": BASE_PATH, "HOME": str(Path.home())}
    return subprocess.run(
        [str(TOOLS / name), *args],
        capture_output=True,
        text=True,
        check=False,
        timeout=180,
        env={**base_env, **(env or {})},
        cwd=cwd,
    )


# ---------------------------------------------------------------- fake server
@dataclass
class FakeSemaphore:
    base_url: str
    requests: list[tuple[str, str]] = field(default_factory=list)


@pytest.fixture
def fake_semaphore() -> Iterator[Callable[[dict[str, Any]], FakeSemaphore]]:
    """Factory: ``fake(routes)`` serves GET routes (path -> JSON) after a cookie login."""
    servers: list[ThreadingHTTPServer] = []

    def start(routes: dict[str, Any]) -> FakeSemaphore:
        state = FakeSemaphore(base_url="")

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:  # silence
                pass

            def _send(self, code: int, body: bytes = b"", headers: dict[str, str] | None = None):
                self.send_response(code)
                for k, v in (headers or {}).items():
                    self.send_header(k, v)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_POST(self) -> None:
                state.requests.append(("POST", self.path))
                length = int(self.headers.get("Content-Length", 0))
                creds = json.loads(self.rfile.read(length))
                if self.path == "/api/auth/login" and creds == {
                    "auth": "u",
                    "password": "p",
                }:
                    self._send(204, headers={"Set-Cookie": "semaphore=abc; Path=/"})
                else:
                    self._send(401)

            def do_GET(self) -> None:
                state.requests.append(("GET", self.path))
                if "semaphore=abc" not in self.headers.get("Cookie", ""):
                    self._send(401)
                elif self.path in routes:
                    self._send(200, json.dumps(routes[self.path]).encode())
                else:
                    self._send(404)

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        servers.append(server)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        state.base_url = f"http://127.0.0.1:{server.server_address[1]}"
        return state

    yield start
    for server in servers:
        server.shutdown()
        server.server_close()


# ------------------------------------------------------------- docker semaphore
class SeedClient:
    """Test-only writer for the throwaway container (the tools themselves only GET)."""

    def __init__(self, base_url: str) -> None:
        self.base = base_url
        self._opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        self.call("POST", "/api/auth/login", {"auth": ADMIN, "password": ADMIN_PASSWORD})

    def call(self, method: str, path: str, body: Any = None) -> Any:
        data = None if body is None else json.dumps(body).encode()
        req = urllib.request.Request(  # noqa: S310
            self.base + path, method=method, data=data, headers={"Content-Type": "application/json"}
        )
        with self._opener.open(req, timeout=20) as resp:
            raw = resp.read()
        return json.loads(raw) if raw else None

    def seed_project(self, name: str, *, schedule_active: bool) -> dict[str, int]:
        """One project with one of each kind; returns the created ids."""
        pid = self.call("POST", "/api/projects", {"name": name})["id"]
        key = self.call(
            "POST",
            f"/api/project/{pid}/keys",
            {
                "name": "k-ssh",
                "type": "ssh",
                "project_id": pid,
                "ssh": {"login": "u", "private_key": "x"},
            },
        )
        self.call(
            "POST",
            f"/api/project/{pid}/keys",
            {
                "name": "k-login",
                "type": "login_password",
                "project_id": pid,
                "login_password": {"login": "u", "password": "pw"},
            },
        )
        none_key = next(
            k for k in self.call("GET", f"/api/project/{pid}/keys") if k["type"] == "none"
        )
        repo = self.call(
            "POST",
            f"/api/project/{pid}/repositories",
            {
                "name": "r1",
                "project_id": pid,
                "git_url": "/nonexistent",
                "git_branch": "main",
                "ssh_key_id": none_key["id"],
            },
        )
        inv = self.call(
            "POST",
            f"/api/project/{pid}/inventory",
            {
                "name": "i1",
                "project_id": pid,
                "inventory": "localhost",
                "type": "static",
                "ssh_key_id": none_key["id"],
            },
        )
        env = self.call(
            "POST",
            f"/api/project/{pid}/environment",
            {"name": "e1", "project_id": pid, "json": "{}", "env": "{}"},
        )
        tpl = self.call(
            "POST",
            f"/api/project/{pid}/templates",
            {
                "name": "t1",
                "project_id": pid,
                "inventory_id": inv["id"],
                "repository_id": repo["id"],
                "environment_id": env["id"],
                "playbook": "x.yml",
                "app": "ansible",
                "type": "",
            },
        )
        sched = self.add_schedule(pid, tpl["id"], active=schedule_active)
        return {"project": pid, "template": tpl["id"], "schedule": sched, "key": key["id"]}

    def add_schedule(self, pid: int, template_id: int, *, active: bool) -> int:
        created = self.call(
            "POST",
            f"/api/project/{pid}/schedules",
            {
                "name": "nightly",
                "project_id": pid,
                "template_id": template_id,
                "cron_format": "0 3 * * *",
                "active": active,
            },
        )
        return created["id"]

    def run_task(self, pid: int, template_id: int) -> int:
        return self.call("POST", f"/api/project/{pid}/tasks", {"template_id": template_id})["id"]


def _free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


@pytest.fixture(scope="module")
def semaphore_container() -> Iterator[str]:
    """Base URL of a throwaway ``v2.19.16`` container (admin/ADMIN_PASSWORD, SQLite)."""
    if shutil.which("docker") is None:
        pytest.skip("docker not installed: cannot start the local Semaphore container")
    inspect = subprocess.run(
        ["docker", "image", "inspect", IMAGE], capture_output=True, check=False, timeout=60
    )
    if inspect.returncode != 0:
        pytest.skip(f"image {IMAGE} not present locally (docker pull it first)")
    name = f"t13b-sem-{uuid.uuid4().hex[:8]}"
    port = _free_port()
    secret = base64.b64encode(os.urandom(32)).decode()
    subprocess.run(
        [
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            name,
            "-p",
            f"127.0.0.1:{port}:3000",
            "-e",
            "SEMAPHORE_DB_DIALECT=sqlite",
            "-e",
            "SEMAPHORE_DB_HOST=/var/lib/semaphore/database.sqlite",
            "-e",
            f"SEMAPHORE_ADMIN={ADMIN}",
            "-e",
            f"SEMAPHORE_ADMIN_PASSWORD={ADMIN_PASSWORD}",
            "-e",
            "SEMAPHORE_ADMIN_NAME=Admin",
            "-e",
            "SEMAPHORE_ADMIN_EMAIL=admin@example.invalid",
            "-e",
            f"SEMAPHORE_COOKIE_HASH={secret}",
            "-e",
            f"SEMAPHORE_COOKIE_ENCRYPTION={secret}",
            "-e",
            f"SEMAPHORE_ACCESS_KEY_ENCRYPTION={secret}",
            IMAGE,
        ],
        check=True,
        capture_output=True,
        timeout=120,
    )
    base = f"http://127.0.0.1:{port}"
    CONTAINER_NAMES[base] = name
    try:
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            try:
                with urllib.request.urlopen(base + "/api/ping", timeout=2) as resp:  # noqa: S310
                    if resp.read().strip() == b"pong":
                        break
            except (urllib.error.URLError, OSError):
                time.sleep(1)
        else:
            raise RuntimeError("throwaway Semaphore did not answer /api/ping in 90 s")
        yield base
    finally:
        subprocess.run(["docker", "rm", "-f", name], capture_output=True, check=False, timeout=60)


@pytest.fixture
def tool_env() -> dict[str, str]:
    return {"SEMAPHORE_USER": ADMIN, "SEMAPHORE_PASSWORD": ADMIN_PASSWORD}
