"""Tests for the per-source keys of roles/btrbk (`mount_path`, `snapshot_dir`).

GS-FR-75, GS-FR-76, GS-FR-90 to GS-FR-92, GS-AC-21, GS-AC-53, GS-BR-04.

The role runs on localhost with fake `findmnt` and `btrfs` executables first on
PATH. Every case below fails inside the guard, before btrbk is installed, so no
test reaches a task that changes the host; each one also checks that the btrbk
configuration was not written and that the source path was not created. The
passing path (same mount, existing subvolume) needs the real tools: VM (T-18).
"""

from __future__ import annotations

import json
import os
import shutil
import stat
import subprocess
import sys
import textwrap
from pathlib import Path

import pytest

NAS = Path(__file__).resolve().parents[2]
VENV_BIN = Path.home() / ".pyenv/versions/ansible-bind9-venv/bin"
ANSIBLE = shutil.which("ansible-playbook") or (
    str(VENV_BIN / "ansible-playbook") if (VENV_BIN / "ansible-playbook").exists() else None
)
pytestmark = pytest.mark.skipif(ANSIBLE is None, reason="ansible-playbook not available")

DEFAULTS = [
    {"name": "data", "path": "/mnt/data"},
    {"name": "containers", "path": "/mnt/containers"},
]
META = {
    "name": "garage-meta",
    "path": "/mnt/containers/garage/meta",
    "mount_path": "/mnt/containers",
    "snapshot_dir": "/mnt/containers/.btrbk-garage-meta",
}
GARAGE = {
    "name": "garage",
    "path": "/mnt/data/garage",
    "mount_path": "/mnt/data",
    "snapshot_dir": "/mnt/data/.btrbk-garage",
}

FAKE_FINDMNT = f"""#!{sys.executable}
import json, os, sys
a = sys.argv[1:]
mounts = json.loads(os.environ["FAKE_MOUNTS"])
if "--mountpoint" in a:
    p = a[a.index("--mountpoint") + 1]
    if p in mounts:
        print("uuid /")
        sys.exit(0)
    sys.exit(1)
if "--target" in a:
    p = a[a.index("--target") + 1]
    best = max((m for m in mounts if p == m or p.startswith(m.rstrip("/") + "/")), key=len, default=None)
    if best:
        print(best)
        sys.exit(0)
sys.exit(1)
"""

FAKE_BTRFS = f"""#!{sys.executable}
import json, os, sys
a = sys.argv[1:]
if a[:2] == ["subvolume", "show"] and a[2] in json.loads(os.environ["FAKE_SUBVOLS"]):
    print(a[2])
    sys.exit(0)
sys.stderr.write("ERROR: not a subvolume: " + " ".join(a) + "\\n")
sys.exit(1)
"""


def run_role(tmp_path: Path, sources: list[dict], subvols=(), extra_mounts=(), check=False):
    bindir = tmp_path / "bin"
    bindir.mkdir()
    for name, body in (("findmnt", FAKE_FINDMNT), ("btrfs", FAKE_BTRFS)):
        exe = bindir / name
        exe.write_text(body)
        exe.chmod(exe.stat().st_mode | stat.S_IXUSR)
    conf = tmp_path / "etc-btrbk" / "btrbk.conf"
    (tmp_path / "ansible.cfg").write_text("[defaults]\nlocalhost_warning = false\nretry_files_enabled = false\n")
    (tmp_path / "play.yml").write_text(
        textwrap.dedent(
            """\
            - hosts: localhost
              connection: local
              gather_facts: false
              roles: [btrbk]
            """
        )
    )
    (tmp_path / "vars.json").write_text(json.dumps({"btrbk_sources": sources, "btrbk_conf_path": str(conf)}))
    env = {
        "PATH": f"{bindir}:{VENV_BIN}:{os.environ['PATH']}",
        "HOME": os.environ["HOME"],  # keeps ~/.ansible/collections visible
        "ANSIBLE_LOCAL_TEMP": str(tmp_path / "tmp"),
        "ANSIBLE_CONFIG": str(tmp_path / "ansible.cfg"),
        "ANSIBLE_ROLES_PATH": str(NAS / "roles"),
        "ANSIBLE_NOCOLOR": "1",
        "FAKE_MOUNTS": json.dumps(["/mnt/backup/btrbk", "/mnt/data", "/mnt/containers", *extra_mounts]),
        "FAKE_SUBVOLS": json.dumps(list(subvols)),
    }
    proc = subprocess.run(
        [ANSIBLE, *(["--check"] if check else []), "-i", "localhost,", "-e", f"@{tmp_path / 'vars.json'}", str(tmp_path / "play.yml")],
        env=env,
        capture_output=True,
        text=True,
        cwd=tmp_path,
        timeout=120,
    )
    assert not conf.exists(), "btrbk.conf must not be written when the guard fails"
    return proc, proc.stdout + proc.stderr


def entry(base: dict, **kw) -> dict:
    return {**base, **kw}


@pytest.mark.parametrize(
    "value",
    [
        ".btrbk-garage",
        "/mnt/data/samba/Delat/.btrbk-garage",
        "/mnt/data/garage/.snap",
        "/mnt/data/garage",
        "/mnt/data/../samba/x",
    ],
)
def test_invalid_snapshot_dir_string_level(tmp_path, value):
    """GS-AC-53, first three rows (+ source itself, '..'): fail naming source and value."""
    proc, out = run_role(tmp_path, [*DEFAULTS, META, entry(GARAGE, snapshot_dir=value)], subvols=[META["path"], GARAGE["path"]])
    assert proc.returncode != 0
    assert "'garage'" in out and value in out
    assert "GS-FR-92" in out


def test_snapshot_dir_on_other_mount(tmp_path):
    """GS-AC-53, fourth row: /mnt/containers/.btrbk-garage for garage (path on /mnt/data)."""
    sources = [*DEFAULTS, META, entry(GARAGE, snapshot_dir="/mnt/containers/.btrbk-garage")]
    proc, out = run_role(tmp_path, sources, subvols=[META["path"], GARAGE["path"]])
    assert proc.returncode != 0
    assert "'garage'" in out and "/mnt/containers/.btrbk-garage" in out and "same mount" in out


@pytest.mark.parametrize("src", [META, GARAGE], ids=["garage-meta", "garage"])
def test_absent_or_non_subvolume_path_fails_before_any_change(tmp_path, src):
    """GS-AC-21 / GS-BR-04: the fake `btrfs subvolume show` knows no subvolume."""
    proc, out = run_role(tmp_path, [*DEFAULTS, src], subvols=[])
    assert proc.returncode != 0
    assert src["path"] in out and "btrfs subvolume" in out
    assert "never creates" in out
    assert not Path(src["path"]).exists()
    # Failed in the guard: nothing after it ran.
    assert "Install gpg" not in out and "Create the btrbk configuration directory" not in out


def test_path_not_below_mount_path(tmp_path):
    """GS-FR-76: path outside mount_path."""
    bad = entry(GARAGE, path="/mnt/containers/garage")
    proc, out = run_role(tmp_path, [*DEFAULTS, bad], subvols=[bad["path"]])
    assert proc.returncode != 0
    assert "/mnt/containers/garage" in out and "strictly below" in out


def test_mount_path_equal_to_path_is_refused(tmp_path):
    bad = {k: v for k, v in GARAGE.items() if k != "snapshot_dir"} | {"path": "/mnt/data"}
    proc, out = run_role(tmp_path, [*DEFAULTS, bad], subvols=["/mnt/data"])
    assert proc.returncode != 0 and "strictly below" in out


@pytest.mark.parametrize("check", [False, True], ids=["real-run", "check-mode"])
def test_missing_source_real_run_fails_check_mode_skips(tmp_path, check):
    """Real run: a missing source fails naming its path (GS-FR-76, GS-BR-04).
    Check mode on a fresh host: the not-yet-created source is skipped, the guard passes."""
    src = entry(GARAGE, path=str(tmp_path / "missing"), mount_path=str(tmp_path))
    src["snapshot_dir"] = str(tmp_path / ".snap")
    proc, out = run_role(tmp_path, [*DEFAULTS, src], subvols=[], extra_mounts=[str(tmp_path)], check=check)
    if not check:
        assert proc.returncode != 0
        assert src["path"] in out and "never creates" in out
    else:
        for guard in ("does not exist or is not", "never creates", "must be on the same mount"):
            assert guard not in out
        assert "skipping" in out
