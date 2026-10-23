"""Backup gate of roles/garage (GS-FR-67, GS-E-20, GS-AC-43 local half).

Runs the preflight stage of the role against localhost with a private ansible.cfg (no vault, no
inventory). The gate is the first task of the role, so a failure means no
other task ran.
"""

from __future__ import annotations

import copy
import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

NAS_DIR = Path(__file__).resolve().parents[2]

pytestmark = pytest.mark.skipif(
    shutil.which("ansible-playbook") is None, reason="ansible-playbook not on PATH"
)

PLAY = """---
- name: Garage preflight
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Run only the preflight stage
      ansible.builtin.include_role:
        name: garage
        tasks_from: preflight
"""


VALID: dict[str, object] = {
    "vault_garage_rpc_secret": "a1" * 32,
    "vault_garage_admin_token": "tok" * 15,
}
SECRETS = ("a1" * 32, "tok" * 15)


def mutated(**changes: object) -> dict[str, object]:
    return copy.deepcopy({**VALID, **changes})


def run_role(tmp_path: Path, **extra: object) -> subprocess.CompletedProcess[str]:
    (tmp_path / "ansible.cfg").write_text(
        f"[defaults]\ninventory = /dev/null\nroles_path = {NAS_DIR}/roles\n"
        "retry_files_enabled = false\nlocalhost_warning = false\nstdout_callback = default\n"
    )
    (tmp_path / "play.yml").write_text(PLAY)
    variables = {
        "garage_enabled": True,
        "garage_s3_domain": "s3.example.test",
        "cloudflare_dns_zone": "example.test",
        "backup_disk_enabled": True,
        **VALID,
        **extra,
    }
    args = ["ansible-playbook", str(tmp_path / "play.yml")]
    (tmp_path / "vars.json").write_text(json.dumps(variables))
    args += ["-e", f"@{tmp_path / 'vars.json'}"]
    env = {**os.environ, "ANSIBLE_CONFIG": str(tmp_path / "ansible.cfg")}
    return subprocess.run(args, capture_output=True, text=True, env=env, cwd=tmp_path, check=False)


def test_enabled_without_backup_disk_fails_naming_both_flags(tmp_path: Path) -> None:
    result = run_role(tmp_path, backup_disk_enabled=False)
    out = result.stdout + result.stderr
    assert result.returncode != 0
    assert "garage_enabled" in out and "backup_disk_enabled" in out
    assert re.search(r"changed=0\s", out)


def test_enabled_with_undefined_backup_flag_fails(tmp_path: Path) -> None:
    result = run_role(tmp_path, backup_disk_enabled=None)
    assert result.returncode != 0
    assert "backup_disk_enabled" in result.stdout + result.stderr


def test_enabled_with_backup_disk_passes_the_gate(tmp_path: Path) -> None:
    result = run_role(tmp_path, backup_disk_enabled=True)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.search(r"changed=0\s", result.stdout)


# GS-AC-25 rows: (named input, overrides).
CASES = {
    "empty_rpc": ("garage_rpc_secret", {"vault_garage_rpc_secret": ""}),
    "rpc_63_hex": ("garage_rpc_secret", {"vault_garage_rpc_secret": "a" * 63}),
    "short_admin_token": ("garage_admin_token", {"vault_garage_admin_token": "x" * 31}),
    "domain_outside_zone": ("garage_s3_domain", {"garage_s3_domain": "s3.example.org"}),
    "domain_empty": ("garage_s3_domain", {"garage_s3_domain": ""}),
    "meta_path": ("garage_meta_path", {"garage_meta_path": "/mnt/data/garage-meta"}),
}


def test_valid_inputs_pass_with_nothing_changed(tmp_path: Path) -> None:
    result = run_role(tmp_path)
    assert result.returncode == 0, result.stdout + result.stderr
    assert re.search(r"changed=0\s", result.stdout)


@pytest.mark.parametrize("case", sorted(CASES))
def test_invalid_input_fails_naming_input_without_secrets(tmp_path: Path, case: str) -> None:
    named, overrides = CASES[case]
    result = run_role(tmp_path, **mutated(**overrides))
    out = result.stdout + result.stderr
    assert result.returncode != 0
    assert named in out
    assert re.search(r"changed=0\s", out)
    for secret in SECRETS:
        assert secret not in out
