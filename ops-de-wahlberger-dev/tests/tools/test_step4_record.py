"""step4-record.py: counts per kind, newest task id, active schedules (SH-AC-18/20 input)."""

from __future__ import annotations

import json
import threading
import time
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
from conftest import SeedClient, run_tool
from semaphore_record import (
    DEFAULT_LOGIN_TIMEOUT,
    DEFAULT_TIMEOUT,
    ApiError,
    ApiTimeout,
    CredentialsError,
    SemaphoreClient,
    build_record,
    credentials_from_env,
)

CREDS = {"SEMAPHORE_USER": "u", "SEMAPHORE_PASSWORD": "p"}


def two_project_routes() -> dict:
    sched_a = [
        {"id": 1, "name": "a", "tpl_name": "t", "cron_format": "* * * * *", "active": True},
        {"id": 2, "name": "b", "tpl_name": "t", "cron_format": "0 1 * * *", "active": False},
    ]
    return {
        "/api/projects": [{"id": 10}, {"id": 20}],
        "/api/users": [{"id": 1}, {"id": 2}, {"id": 3}],
        "/api/info": {"version": "v2.19.16-test"},
        "/api/project/10/keys": [{"id": 1}, {"id": 2}],
        "/api/project/10/repositories": [{"id": 1}],
        "/api/project/10/inventory": [{"id": 1}, {"id": 2}, {"id": 3}],
        "/api/project/10/environment": [],
        "/api/project/10/templates": [{"id": 1}],
        "/api/project/10/schedules": sched_a,
        "/api/project/10/tasks": [{"id": 7}, {"id": 5}],
        "/api/project/20/keys": [{"id": 9}],
        "/api/project/20/repositories": None,  # Semaphore answers null for empty lists
        "/api/project/20/inventory": [{"id": 4}],
        "/api/project/20/environment": [{"id": 1}],
        "/api/project/20/templates": [{"id": 2}, {"id": 3}],
        "/api/project/20/schedules": [
            {"id": 3, "name": "c", "tpl_name": "u", "cron_format": "5 5 * * 5", "active": True}
        ],
        "/api/project/20/tasks": [{"id": 12}, {"id": 3}],
        "/api/tasks": [],  # must NOT be used: queue only
    }


def test_record_sums_counts_over_all_projects_and_takes_max_task_id(fake_semaphore):
    fake = fake_semaphore(two_project_routes())
    client = SemaphoreClient(fake.base_url)
    client.login("u", "p")

    record = build_record(client)

    assert record["counts"] == {
        "environments": 1,
        "inventories": 4,
        "keys": 3,
        "projects": 2,
        "repositories": 1,
        "schedules": 3,
        "templates": 3,
        "users": 3,
    }
    assert record["newest_task_id"] == 12  # max over projects, not the first/last list entry
    assert record["semaphore_version"] == "v2.19.16-test"
    assert record["active_schedules"] == [
        {"project_id": 10, "id": 1, "name": "a", "template": "t", "cron": "* * * * *"},
        {"project_id": 20, "id": 3, "name": "c", "template": "u", "cron": "5 5 * * 5"},
    ]


def test_record_without_projects_has_zero_counts_and_no_task_id(fake_semaphore):
    fake = fake_semaphore({"/api/projects": [], "/api/users": [{"id": 1}], "/api/info": {}})
    client = SemaphoreClient(fake.base_url)
    client.login("u", "p")

    record = build_record(client)

    assert record["counts"]["projects"] == 0
    assert record["counts"]["keys"] == 0
    assert record["counts"]["users"] == 1
    assert record["newest_task_id"] is None
    assert record["active_schedules"] == []


def test_record_issues_only_gets_after_the_login_post(fake_semaphore):
    fake = fake_semaphore(two_project_routes())
    client = SemaphoreClient(fake.base_url)
    client.login("u", "p")
    build_record(client)

    methods = [m for m, _ in fake.requests]
    assert methods[0] == "POST"
    assert fake.requests[0] == ("POST", "/api/auth/login")
    assert set(methods[1:]) == {"GET"}
    assert ("GET", "/api/tasks") not in fake.requests


def test_cli_prints_json_and_never_the_password(fake_semaphore):
    fake = fake_semaphore(two_project_routes())

    proc = run_tool("step4-record.py", fake.base_url, env=CREDS)

    assert proc.returncode == 0, proc.stderr
    assert json.loads(proc.stdout)["newest_task_id"] == 12
    assert "SEMAPHORE_PASSWORD" not in proc.stdout + proc.stderr
    assert '"p"' not in proc.stdout


def test_cli_wrong_password_exits_2_naming_http_401(fake_semaphore):
    fake = fake_semaphore(two_project_routes())

    proc = run_tool(
        "step4-record.py",
        fake.base_url,
        env={"SEMAPHORE_USER": "u", "SEMAPHORE_PASSWORD": "wrong-secret"},
    )

    assert proc.returncode == 2
    assert "HTTP 401" in proc.stderr
    assert "wrong-secret" not in proc.stdout + proc.stderr


def test_cli_missing_credentials_exits_2_naming_the_variables(fake_semaphore):
    fake = fake_semaphore(two_project_routes())

    proc = run_tool("step4-record.py", fake.base_url)

    assert proc.returncode == 2
    assert "SEMAPHORE_USER" in proc.stderr
    assert "SEMAPHORE_PASSWORD" in proc.stderr
    assert fake.requests == []  # no request before credentials are known


@pytest.mark.parametrize("args", [[], ["a", "b"]])
def test_cli_wrong_argument_count_exits_2(args):
    assert run_tool("step4-record.py", *args, env=CREDS).returncode == 2


def test_cli_unreachable_server_exits_2():
    proc = run_tool("step4-record.py", "http://127.0.0.1:9", env=CREDS)

    assert proc.returncode == 2
    assert "step4-record:" in proc.stderr


def test_client_rejects_non_http_base_url():
    with pytest.raises(ApiError, match="http"):
        SemaphoreClient("file:///etc/passwd")


def test_non_list_endpoint_response_is_an_api_error(fake_semaphore):
    routes = two_project_routes() | {"/api/project/10/keys": {"oops": 1}}
    fake = fake_semaphore(routes)
    client = SemaphoreClient(fake.base_url)
    client.login("u", "p")

    with pytest.raises(ApiError, match=r"/api/project/10/keys.*list"):
        build_record(client)


def test_credentials_from_env_requires_both():
    assert credentials_from_env({"SEMAPHORE_USER": "a", "SEMAPHORE_PASSWORD": "b"}) == ("a", "b")
    with pytest.raises(CredentialsError):
        credentials_from_env({"SEMAPHORE_USER": "a"})
    with pytest.raises(CredentialsError):
        credentials_from_env({"SEMAPHORE_USER": "", "SEMAPHORE_PASSWORD": "b"})


# ------------------------------------------------ timeouts and the login retry
class SlowLogin:
    """Login endpoint whose first ``slow_posts`` answers take ``delay`` seconds."""

    def __init__(self, slow_posts: int, delay: float = 0.8, status: int = 204) -> None:
        self.slow_posts, self.delay, self.status = slow_posts, delay, status
        self.posts = 0
        owner = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_: object) -> None:
                pass

            def do_POST(self) -> None:
                owner.posts += 1
                self.rfile.read(int(self.headers.get("Content-Length", 0)))
                if owner.posts <= owner.slow_posts:
                    time.sleep(owner.delay)
                try:
                    self.send_response(owner.status)
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                except OSError:  # the client already gave up
                    pass

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"


@pytest.fixture
def slow_login() -> Iterator[type[SlowLogin]]:
    made: list[SlowLogin] = []

    def make(*args: object, **kwargs: object) -> SlowLogin:
        made.append(SlowLogin(*args, **kwargs))  # type: ignore[arg-type]
        return made[-1]

    yield make  # type: ignore[misc]
    for srv in made:
        srv.server.shutdown()
        srv.server.server_close()


def test_login_that_times_out_once_is_retried_and_succeeds(slow_login):
    srv = slow_login(slow_posts=1)

    SemaphoreClient(srv.url, login_timeout=0.3).login("u", "p")

    assert srv.posts == 2


def test_login_that_keeps_timing_out_is_retried_exactly_once_then_fails(slow_login):
    srv = slow_login(slow_posts=5)

    with pytest.raises(ApiTimeout, match=r"POST /api/auth/login: timed out after 0\.3s"):
        SemaphoreClient(srv.url, login_timeout=0.3).login("u", "p")

    assert srv.posts == 2


def test_login_http_error_is_not_retried(slow_login):
    srv = slow_login(slow_posts=0, status=401)

    with pytest.raises(ApiError, match="HTTP 401"):
        SemaphoreClient(srv.url, login_timeout=0.3).login("u", "p")

    assert srv.posts == 1


def test_get_timeout_is_not_retried_and_uses_the_get_timeout(fake_semaphore):
    fake = fake_semaphore({"/api/x": {}})
    client = SemaphoreClient(fake.base_url, timeout=0.2, login_timeout=5)
    client.login("u", "p")

    assert client.get("/api/x") == {}
    assert client._timeout == 0.2
    assert client._login_timeout == 5


def test_timeouts_default_to_30s_get_and_60s_login(monkeypatch):
    monkeypatch.delenv("SEMAPHORE_TIMEOUT", raising=False)
    monkeypatch.delenv("SEMAPHORE_LOGIN_TIMEOUT", raising=False)

    client = SemaphoreClient("http://127.0.0.1:1")

    assert (DEFAULT_TIMEOUT, DEFAULT_LOGIN_TIMEOUT) == (30.0, 60.0)
    assert (client._timeout, client._login_timeout) == (30.0, 60.0)


def test_timeouts_are_configurable_from_the_environment(monkeypatch):
    monkeypatch.setenv("SEMAPHORE_TIMEOUT", "7.5")
    monkeypatch.setenv("SEMAPHORE_LOGIN_TIMEOUT", "90")

    client = SemaphoreClient("http://127.0.0.1:1")

    assert (client._timeout, client._login_timeout) == (7.5, 90.0)


@pytest.mark.parametrize("value", ["abc", "0", "-3"])
def test_invalid_timeout_environment_is_an_api_error(monkeypatch, value):
    monkeypatch.setenv("SEMAPHORE_LOGIN_TIMEOUT", value)

    with pytest.raises(ApiError, match="SEMAPHORE_LOGIN_TIMEOUT must be"):
        SemaphoreClient("http://127.0.0.1:1")


# ------------------------------------------------ against the real v2.19.16 image
def test_record_against_local_container_reflects_seeded_objects(semaphore_container, tool_env):
    before = json.loads(run_tool("step4-record.py", semaphore_container, env=tool_env).stdout)
    seeded = SeedClient(semaphore_container).seed_project("rec-test", schedule_active=True)
    task_id = SeedClient(semaphore_container).run_task(seeded["project"], seeded["template"])

    proc = run_tool("step4-record.py", semaphore_container, env=tool_env)

    assert proc.returncode == 0, proc.stderr
    after = json.loads(proc.stdout)
    delta = {k: after["counts"][k] - before["counts"][k] for k in after["counts"]}
    assert delta == {
        "environments": 1,
        "inventories": 1,
        # k-ssh + k-login + the auto-created key named "None" (spike A-31)
        "keys": 3,
        "projects": 1,
        "repositories": 1,
        "schedules": 1,
        "templates": 1,
        "users": 0,
    }
    assert after["newest_task_id"] == task_id
    assert after["semaphore_version"].startswith("v2.19.16")
    assert {
        "project_id": seeded["project"],
        "id": seeded["schedule"],
        "name": "nightly",
        "template": "t1",
        "cron": "0 3 * * *",
    } in after["active_schedules"]
