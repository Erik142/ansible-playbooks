"""Run-time guard of roles/garage/tasks/secrets.yml (GS-FR-134, GS-E-32, GS-AC-68 local half).

Runs the secrets stage against localhost with stub findmnt/btrfs/snapper binaries on PATH. The
guard must fail before any change when a btrbk source or snapper config shares the btrfs root ID
of garage_secrets_dir, and must not fail otherwise. Later tasks (chown to the garage account) are
not exercised here; they need root and run on the VM.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
from pathlib import Path

import pytest

NAS_DIR = Path(__file__).resolve().parents[2]
SECRETS_TASKS = NAS_DIR / "roles/garage/tasks/secrets.yml"

pytestmark = pytest.mark.skipif(
    shutil.which("ansible-playbook") is None, reason="ansible-playbook not on PATH"
)

PLAY = """---
- name: Garage secrets guard
  hosts: localhost
  connection: local
  gather_facts: false
  tasks:
    - name: Run only the secrets stage
      ansible.builtin.include_role:
        name: garage
        tasks_from: secrets
"""

SECRETS = ("a1" * 32, "tok" * 15)

# rootid by the last path component; /var is 256, sources get their own IDs.
BTRFS_STUB = """#!/bin/bash
case "$(basename "$3")" in
  src_covering) echo 256 ;;
  snap_covering) echo 256 ;;
  src_other) echo 300 ;;
  *) echo 256 ;;
esac
"""


def run_stage(tmp_path: Path, sources: list[str], snapper: str) -> subprocess.CompletedProcess[str]:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    for name, body in {
        "findmnt": "#!/bin/bash\necho btrfs\n",
        "btrfs": BTRFS_STUB,
        "snapper": f"#!/bin/bash\ncat <<'EOT'\n{snapper}\nEOT\n",
    }.items():
        (bin_dir / name).write_text(body)
        (bin_dir / name).chmod(0o755)
    secrets_dir = tmp_path / "var" / "secrets"
    (tmp_path / "var").mkdir()
    for path in sources:
        (tmp_path / path).mkdir(exist_ok=True)
    (tmp_path / "ansible.cfg").write_text(
        f"[defaults]\ninventory = /dev/null\nroles_path = {NAS_DIR}/roles\n"
        "retry_files_enabled = false\nlocalhost_warning = false\n"
    )
    (tmp_path / "play.yml").write_text(PLAY)
    variables = {
        "garage_secrets_dir": str(secrets_dir),
        "btrbk_sources": [{"path": str(tmp_path / p)} for p in sources],
        "vault_garage_rpc_secret": SECRETS[0],
        "vault_garage_admin_token": SECRETS[1],
    }
    (tmp_path / "vars.json").write_text(json.dumps(variables))
    env = {**os.environ, "ANSIBLE_CONFIG": str(tmp_path / "ansible.cfg"), "PATH": f"{bin_dir}:{os.environ['PATH']}"}
    return subprocess.run(
        ["ansible-playbook", str(tmp_path / "play.yml"), "-e", f"@{tmp_path / 'vars.json'}"],
        capture_output=True, text=True, env=env, cwd=tmp_path, check=False,
    )


SNAPPER_EMPTY = "Config | Subvolume\n-------+----------"


def test_btrbk_source_with_same_root_id_fails_before_any_change(tmp_path: Path) -> None:
    result = run_stage(tmp_path, ["src_covering"], SNAPPER_EMPTY)
    out = result.stdout + result.stderr
    assert result.returncode != 0
    assert "btrbk source" in out and str(tmp_path / "var" / "secrets") in out
    assert "Stat the parent" not in out
    assert not (tmp_path / "var" / "secrets").exists()
    for secret in SECRETS:
        assert secret not in out


def test_snapper_config_with_same_root_id_fails_before_any_change(tmp_path: Path) -> None:
    snapper = f"Config | Subvolume\n-------+----------\nroot   | {tmp_path}/snap_covering"
    (tmp_path / "snap_covering").mkdir()
    result = run_stage(tmp_path, ["src_other"], snapper)
    out = result.stdout + result.stderr
    assert result.returncode != 0
    assert "snapper config root" in out
    assert not (tmp_path / "var" / "secrets").exists()


def test_guard_passes_when_nothing_covers_the_path(tmp_path: Path) -> None:
    result = run_stage(tmp_path, ["src_other"], SNAPPER_EMPTY)
    out = result.stdout + result.stderr
    assert "covered by" not in out
    assert re.search(r"Stat the parent of the secrets directory", out)
    for secret in SECRETS:
        assert secret not in out


def test_every_secret_task_sets_no_log() -> None:
    text = SECRETS_TASKS.read_text()
    for task in text.split("\n- name: ")[1:]:
        if "garage_rpc_secret" in task.split("\n", 1)[1] or "garage_admin_token" in task.split("\n", 1)[1]:
            assert "no_log: true" in task, task.splitlines()[0]
