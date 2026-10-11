"""Read-only Semaphore state record (SH-FR-53, SH-AC-20) and its comparison.

Endpoints are the ones verified in docs/spikes/A-09-A-31-A-32-semaphore-image.md:
counts are per project, the newest task id is the maximum over every project's
``/tasks`` (``/api/tasks`` only lists the running queue), schedules are per
project. The only non-GET request is the login POST.
"""

from __future__ import annotations

import json
import os
import socket
import urllib.error
import urllib.request
from dataclasses import dataclass
from http.cookiejar import CookieJar
from pathlib import Path
from typing import Any

SCHEMA_VERSION = 1
# kind -> (scope, path); "project" paths are formatted with the project id.
COUNT_ENDPOINTS: dict[str, str] = {
    "keys": "/api/project/{id}/keys",
    "repositories": "/api/project/{id}/repositories",
    "inventories": "/api/project/{id}/inventory",
    "environments": "/api/project/{id}/environment",
    "templates": "/api/project/{id}/templates",
    "schedules": "/api/project/{id}/schedules",
}
USER_ENV = "SEMAPHORE_USER"
PASSWORD_ENV = "SEMAPHORE_PASSWORD"  # noqa: S105  (name of an env var, not a secret)
TIMEOUT_ENV = "SEMAPHORE_TIMEOUT"
LOGIN_TIMEOUT_ENV = "SEMAPHORE_LOGIN_TIMEOUT"
# The login hashes the password (bcrypt) and is by far the slowest call under load.
DEFAULT_TIMEOUT = 30.0
DEFAULT_LOGIN_TIMEOUT = 60.0


class SemaphoreError(Exception):
    """Base class for tool errors (exit code 2)."""


class ApiError(SemaphoreError):
    """The Semaphore API answered unexpectedly or could not be reached."""


class ApiTimeout(ApiError):
    """A request ran into its timeout (the only error the login retries)."""


class CredentialsError(SemaphoreError):
    """Login credentials are missing from the environment."""


class RecordError(SemaphoreError):
    """A record file is unreadable or has the wrong shape."""


def credentials_from_env(env: dict[str, str] | None = None) -> tuple[str, str]:
    env = os.environ if env is None else env
    user, password = env.get(USER_ENV, ""), env.get(PASSWORD_ENV, "")
    if not user or not password:
        raise CredentialsError(f"set {USER_ENV} and {PASSWORD_ENV} in the environment")
    return user, password


def _seconds(name: str, default: float, env: dict[str, str] | None = None) -> float:
    env = os.environ if env is None else env
    raw = env.get(name, "")
    if not raw:
        return default
    try:
        value = float(raw)
    except ValueError:
        raise ApiError(f"{name} must be a number of seconds, got {raw!r}") from None
    if value <= 0:
        raise ApiError(f"{name} must be positive, got {raw!r}")
    return value


class SemaphoreClient:
    """Minimal session client. Never logs request bodies or responses.

    Timeouts: ``timeout`` for GETs, ``login_timeout`` for the login POST; unset values
    come from ``SEMAPHORE_TIMEOUT`` / ``SEMAPHORE_LOGIN_TIMEOUT`` (seconds), then the
    defaults. A login that times out is retried once (a loaded server, not a bad answer).
    """

    def __init__(
        self,
        base_url: str,
        *,
        timeout: float | None = None,
        login_timeout: float | None = None,
    ) -> None:
        if not base_url.startswith(("http://", "https://")):
            raise ApiError(f"base url must start with http:// or https://: {base_url!r}")
        self._base = base_url.rstrip("/")
        self._timeout = _seconds(TIMEOUT_ENV, DEFAULT_TIMEOUT) if timeout is None else timeout
        self._login_timeout = (
            _seconds(LOGIN_TIMEOUT_ENV, DEFAULT_LOGIN_TIMEOUT)
            if login_timeout is None
            else login_timeout
        )
        self._opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(CookieJar()))

    def _open(self, req: urllib.request.Request, timeout: float) -> tuple[int, bytes]:
        what = f"{req.get_method()} {req.selector}"
        try:
            with self._opener.open(req, timeout=timeout) as resp:
                return resp.status, resp.read()
        except urllib.error.HTTPError as err:
            raise ApiError(f"{what}: HTTP {err.code}") from err
        except (urllib.error.URLError, OSError) as err:
            # socket.timeout is no TimeoutError before 3.10; URLError wraps connect timeouts.
            reason = err.reason if isinstance(err, urllib.error.URLError) else err
            if isinstance(reason, (TimeoutError, socket.timeout)):
                raise ApiTimeout(f"{what}: timed out after {timeout:g}s") from err
            raise ApiError(f"{what}: {err}") from err

    def login(self, user: str, password: str) -> None:
        body = json.dumps({"auth": user, "password": password}).encode()
        req = urllib.request.Request(  # noqa: S310  (scheme checked in __init__)
            self._base + "/api/auth/login",
            data=body,
            method="POST",
            headers={"Content-Type": "application/json"},
        )
        try:
            status, _ = self._open(req, self._login_timeout)
        except ApiTimeout:
            status, _ = self._open(req, self._login_timeout)  # one bounded retry, login only
        if status not in (200, 204):
            raise ApiError(f"login: unexpected HTTP {status}")

    def get(self, path: str) -> Any:
        req = urllib.request.Request(  # noqa: S310
            self._base + path, method="GET", headers={"Accept": "application/json"}
        )
        status, raw = self._open(req, self._timeout)
        if status != 200:
            raise ApiError(f"GET {path}: unexpected HTTP {status}")
        try:
            return json.loads(raw)
        except json.JSONDecodeError as err:
            raise ApiError(f"GET {path}: response is not JSON") from err


def _as_list(value: Any, path: str) -> list[dict[str, Any]]:
    # Semaphore answers `null` for an empty list on some endpoints.
    if value is None:
        return []
    if not isinstance(value, list):
        raise ApiError(f"GET {path}: expected a JSON list")
    return value


def build_record(client: SemaphoreClient) -> dict[str, Any]:
    """Collect counts, newest task id and active schedules (read-only GETs)."""
    projects = _as_list(client.get("/api/projects"), "/api/projects")
    users = _as_list(client.get("/api/users"), "/api/users")
    counts: dict[str, int] = {"projects": len(projects), "users": len(users)}
    counts.update(dict.fromkeys(COUNT_ENDPOINTS, 0))
    newest: int | None = None
    active: list[dict[str, Any]] = []
    for project in projects:
        pid = project["id"]
        for kind, template in COUNT_ENDPOINTS.items():
            path = template.format(id=pid)
            items = _as_list(client.get(path), path)
            counts[kind] += len(items)
            if kind == "schedules":
                active.extend(
                    {
                        "project_id": pid,
                        "id": s["id"],
                        "name": s.get("name", ""),
                        "template": s.get("tpl_name", ""),
                        "cron": s.get("cron_format", ""),
                    }
                    for s in items
                    if s.get("active")
                )
        tasks_path = f"/api/project/{pid}/tasks"
        for task in _as_list(client.get(tasks_path), tasks_path):
            newest = task["id"] if newest is None else max(newest, task["id"])
    info = client.get("/api/info")
    return {
        "schema": SCHEMA_VERSION,
        "semaphore_version": info.get("version", "") if isinstance(info, dict) else "",
        "counts": dict(sorted(counts.items())),
        "newest_task_id": newest,
        "active_schedules": active,
    }


@dataclass(frozen=True)
class Difference:
    kind: str
    recorded: object
    current: object

    def __str__(self) -> str:
        return f"DIFF {self.kind}: record={self.recorded} vm={self.current}"


def load_record(path: str) -> dict[str, Any]:
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as err:
        raise RecordError(f"cannot read record {path}: {err}") from err
    if (
        not isinstance(data, dict)
        or not isinstance(data.get("counts"), dict)
        or "newest_task_id" not in data
    ):
        raise RecordError(f"{path}: not a step-4 record (need 'counts' and 'newest_task_id')")
    return data


def compare_records(recorded: dict[str, Any], current: dict[str, Any]) -> list[Difference]:
    """Differences in counts, newest task id (PA-2) and VM schedules still active (FR-54)."""
    diffs: list[Difference] = []
    rc, cc = recorded["counts"], current["counts"]
    for kind in sorted(set(rc) | set(cc)):
        if rc.get(kind) != cc.get(kind):
            diffs.append(Difference(f"counts.{kind}", rc.get(kind), cc.get(kind)))
    if recorded["newest_task_id"] != current["newest_task_id"]:
        diffs.append(
            Difference("newest_task_id", recorded["newest_task_id"], current["newest_task_id"])
        )
    diffs.extend(
        Difference(
            f"active_schedule project={s['project_id']} id={s['id']} name={s['name']!r}",
            "inactive expected",
            "active",
        )
        for s in current["active_schedules"]
    )
    return diffs
