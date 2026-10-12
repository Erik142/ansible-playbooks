"""Rendered maintenance unit and env file for several repositories (SH-CC-01, T-21).

The role validation is exercised by running the real `restic_server` role with
ansible-playbook against localhost: every case must fail in the first tasks,
before anything can report `changed`. Skipped when ansible-playbook is absent.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import jinja2
import pytest

NAS = Path(__file__).resolve().parents[2]
ROLE = NAS / "roles/restic_server"
GOLDEN = Path(__file__).parent / "fixtures/maintenance-service-before-sh-cc-01.golden"

DEFAULTS = {
    "restic_server_mount_path": "/mnt/data",
    "restic_server_user": "restic-server",
    "restic_server_maintenance_env_file": "/etc/restic-server-maintenance.env",
    "restic_server_maintenance_timeout_start_sec": "4h",
    "restic_server_data_dir": "/mnt/data/restic-repos",
    "restic_server_maintenance_script_path": "/usr/local/bin/restic-maintenance.py",
    "restic_server_maintenance_keep_daily": 7,
    "restic_server_maintenance_keep_weekly": 4,
    "restic_server_maintenance_keep_monthly": 6,
    "restic_server_maintenance_check_read_data_subset": "10%",
    "restic_server_maintenance_retry_lock": "30m",
    "restic_server_maintenance_max_time_skew_hours": 6,
}
CLOUD = {"repo": "cloud", "password": "cloud-pw-not-a-secret"}
OPS = {"repo": "ops", "password": "ops-pw-not-a-secret"}


def render(template: str, repos: list[dict]) -> str:
    # Ansible's template module defaults: trim_blocks on, keep the trailing newline.
    env = jinja2.Environment(trim_blocks=True, keep_trailing_newline=True, undefined=jinja2.StrictUndefined)
    try:
        from ansible.plugins.filter.core import regex_replace
    except ImportError:  # pragma: no cover
        pytest.skip("ansible filters not importable")
    env.filters["regex_replace"] = regex_replace
    source = (ROLE / "templates" / template).read_text()
    return env.from_string(source).render(**DEFAULTS, restic_server_maintenance_repos=repos)


def exec_starts(unit: str) -> list[str]:
    """Each ExecStart= with its continuation lines."""
    return re.findall(r"^ExecStart=.*?(?<!\\)\n", unit, flags=re.M | re.S)


def test_one_entry_renders_the_old_cloud_unit_byte_for_byte():
    # SH-FR-86: golden = the unit rendered from the template at HEAD before SH-CC-01.
    assert render("restic-server-maintenance.service.j2", [CLOUD]) == GOLDEN.read_text()


def test_two_entries_render_one_complete_execstart_each_cloud_first():
    unit = render("restic-server-maintenance.service.j2", [CLOUD, OPS])
    blocks = exec_starts(unit)
    old = exec_starts(GOLDEN.read_text())

    assert len(blocks) == 2
    assert blocks[0] == old[0]
    assert blocks[1] == old[0].replace("--repo cloud", "--repo ops")
    assert "--keep-daily 7" in blocks[1] and "--keep-weekly 4" in blocks[1] and "--keep-monthly 6" in blocks[1]
    assert unit.index(blocks[0]) < unit.index(blocks[1])
    # Everything outside the ExecStart= blocks is unchanged.
    assert unit.replace(blocks[1], "") == GOLDEN.read_text()


def test_no_password_in_the_unit():
    unit = render("restic-server-maintenance.service.j2", [CLOUD, OPS])
    assert CLOUD["password"] not in unit and OPS["password"] not in unit


def test_env_file_has_one_variable_per_repository():
    env_file = render("restic-maintenance.env.j2", [CLOUD, OPS])
    lines = [line for line in env_file.splitlines() if not line.startswith("#")]
    assert lines == ['RESTIC_PASSWORD_CLOUD="cloud-pw-not-a-secret"', 'RESTIC_PASSWORD_OPS="ops-pw-not-a-secret"']


def test_env_file_escapes_and_maps_repo_names():
    env_file = render("restic-maintenance.env.j2", [{"repo": "my-repo.v2", "password": 'a"b\\c'}])
    assert 'RESTIC_PASSWORD_MY_REPO_V2="a\\"b\\\\c"' in env_file


def run_role(tmp_path: Path, extra_vars: dict) -> subprocess.CompletedProcess[str]:
    ansible = shutil.which("ansible-playbook")
    if ansible is None:
        pytest.skip("ansible-playbook not on PATH")
    play = tmp_path / "play.yml"
    play.write_text(
        "- hosts: localhost\n  connection: local\n  gather_facts: false\n  roles:\n    - role: restic_server\n"
    )
    cfg = tmp_path / "ansible.cfg"
    cfg.write_text(f"[defaults]\nroles_path = {NAS / 'roles'}\ninventory = /dev/null\nlocalhost_warning = false\n")
    base = {
        "restic_server_allowed_sources": ["10.0.0.0/8"],
        "restic_server_clients": [{"username": "cloud", "password": "htpasswd-not-a-secret"}],
        "storage_mounts": [{"path": "/mnt/data"}],
        "restic_server_data_dir": str(tmp_path / "data"),
    }
    env = {**os.environ, "ANSIBLE_CONFIG": str(cfg)}
    return subprocess.run(
        [ansible, str(play), "-e", json.dumps({**base, **extra_vars})],
        env=env, capture_output=True, text=True, check=False, cwd=tmp_path,
    )  # fmt: skip


@pytest.mark.parametrize(
    ("extra", "needle"),
    [
        ({"restic_server_maintenance_repos": []}, "non-empty list"),
        ({"restic_server_maintenance_repos": "cloud"}, "restic_server_maintenance_repos"),
        ({"restic_server_maintenance_repos": [CLOUD, {"repo": "ops", "password": ""}]}, "ops"),
        ({"restic_server_maintenance_repos": [{"repo": "cloud"}]}, "password"),
        ({"restic_server_maintenance_repos": [{"repo": "../x", "password": "p"}]}, "../x"),
        ({"restic_server_maintenance_repos": [CLOUD, {"repo": "CLOUD", "password": "p"}]}, "same"),
        ({"restic_server_maintenance_repos": [{"repo": "a-b", "password": "p"}, {"repo": "a_b", "password": "p"}]}, "same"),
        ({"restic_server_maintenance_repos": [CLOUD], "restic_server_maintenance_repo_password": "x"}, "replaced by"),
        ({"restic_server_maintenance_repos": [CLOUD], "restic_server_maintenance_repo": "cloud"}, "replaced by"),
    ],
)
def test_invalid_maintenance_list_fails_before_any_change(tmp_path, extra, needle):
    result = run_role(tmp_path, extra)
    out = result.stdout + result.stderr

    assert result.returncode != 0, out
    assert needle in out
    # Failed in the validation block: no task of the deploy part ran, nothing changed.
    assert "Read the live mount table" not in out
    assert not re.search(r"^changed:", out, flags=re.M)
    assert not (tmp_path / "data").exists()
    for secret in (CLOUD["password"], OPS["password"]):
        assert secret not in out


def test_empty_password_message_names_the_repository_and_secret(tmp_path):
    result = run_role(tmp_path, {"restic_server_maintenance_repos": [CLOUD, {"repo": "ops", "password": ""}]})
    out = result.stdout + result.stderr
    assert "vault_restic_server_ops_repo_password" in out
