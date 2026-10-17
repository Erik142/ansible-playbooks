"""check-from-list.sh on synthetic nas/cloud/vm vars files (SH-AC-23, SH-FR-126, PA-3)."""

from __future__ import annotations

from pathlib import Path

import pytest
from check_from_list import CheckError, check, list_entries
from conftest import run_tool

PUBLIC, ZT, SUBNET = "203.0.113.9", "10.147.17.5", "172.29.30.0/24"
KEY = "AAAAC3NzaC1lZDI1NTE5AAAAIPUBLICKEYMATERIALONLY0123456789abcdefgh"
COMMENT = "semaphore-automation@ops.de.wahlberger.dev"
OLD = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMixf1vPbDUankXYuMO0bJFXjQ+Cmh3QsrwC6TzGPkda "
    "semaphore-automation@pi.de.int.wahlberger.dev"
)
DIRS = ("nas-de-int-wahlberger-dev", "cloud-wahlberger-dev", "ops-de-wahlberger-dev")


def new_line(from_list: str = f"{PUBLIC},{ZT},{SUBNET}", key: str = KEY) -> str:
    return f'from="{from_list}" ssh-ed25519 {key} {COMMENT}'


def vars_text(line: str | None, *, vm: bool = False, revoked: str | None = None) -> str:
    entries = [f'  - "{OLD}"']
    if line is not None:
        entries.append('  - "' + line.replace('"', '\\"') + '"')
    text = "ssh_authorized_keys_list:\n" + "\n".join(entries) + "\n"
    text += "ssh_authorized_keys_revoked:\n" + (f'  - "{revoked}"\n' if revoked else "  []\n")
    if vm:
        text += f'vm_zt_ip: "{ZT}"\nsemaphore_network_subnet: {SUBNET}\n'
    return text


def make_repo(root: Path, lines: dict[str, str | None] | None = None, **kw) -> Path:
    lines = lines or {}
    for d in DIRS:
        path = root / d / "inventories/production/group_vars/all/vars.yml"
        path.parent.mkdir(parents=True)
        path.write_text(vars_text(lines.get(d, new_line()), vm=d.startswith("ops"), **kw))
    return root


def cli(repo: Path, *extra: str):
    return run_tool("check-from-list.sh", str(repo), "--vm-public-ip", PUBLIC, *extra)


# ------------------------------------------------------------------- happy path
def test_identical_lines_with_the_exact_from_list_pass(tmp_path):
    repo = make_repo(tmp_path)

    proc = cli(repo)

    assert proc.returncode == 0, proc.stdout
    assert proc.stdout.startswith("OK")


def test_from_order_does_not_matter(tmp_path):
    line = new_line(f"{SUBNET},{PUBLIC},{ZT}")
    repo = make_repo(tmp_path, dict.fromkeys(DIRS, line))

    assert cli(repo).returncode == 0


def test_extra_address_from_fr_191_must_be_in_all_three_and_declared(tmp_path):
    line = new_line(f"{PUBLIC},{ZT},{SUBNET},192.168.1.1")
    repo = make_repo(tmp_path, dict.fromkeys(DIRS, line))

    assert cli(repo, "--extra", "192.168.1.1").returncode == 0
    undeclared = cli(repo)
    assert undeclared.returncode == 1
    assert "192.168.1.1" in undeclared.stdout


def test_zt_ip_and_subnet_default_to_the_vm_vars_but_can_be_overridden(tmp_path):
    repo = make_repo(tmp_path)

    assert cli(repo).returncode == 0
    wrong = cli(repo, "--vm-zt-ip", "10.0.0.1")
    assert wrong.returncode == 1
    assert "10.0.0.1" in wrong.stdout


def test_revoked_list_may_hold_the_same_comment_without_counting_as_a_duplicate(tmp_path):
    repo = make_repo(tmp_path, revoked=new_line())

    assert cli(repo).returncode == 0


def test_commented_out_line_is_ignored(tmp_path):
    repo = make_repo(tmp_path)
    nas = repo / DIRS[0] / "inventories/production/group_vars/all/vars.yml"
    stale = new_line(key=KEY[:-4] + "XXXX").replace('"', '\\"')
    nas.write_text(
        nas.read_text().replace(
            "ssh_authorized_keys_revoked", f'  # - "{stale}"\nssh_authorized_keys_revoked'
        )
    )
    assert stale in nas.read_text()

    assert cli(repo).returncode == 0


# ------------------------------------------------------------------- failures
@pytest.mark.parametrize("broken_dir", DIRS)
def test_differing_key_material_in_one_file_fails_and_names_all_three(tmp_path, broken_dir):
    repo = make_repo(tmp_path, {broken_dir: new_line(key=KEY[:-4] + "XXXX")})

    proc = cli(repo)

    assert proc.returncode == 1
    assert "the new key line differs between" in proc.stdout
    for d in DIRS:
        assert d in proc.stdout


@pytest.mark.parametrize(
    ("from_list", "needle"),
    [
        (f"{ZT},{SUBNET}", PUBLIC),  # public ip missing
        (f"{PUBLIC},{SUBNET}", ZT),  # zt ip missing
        (f"{PUBLIC},{ZT}", SUBNET),  # subnet missing
        (f"{PUBLIC},{ZT},{SUBNET},8.8.8.8", "8.8.8.8"),  # unexpected extra
        (f"{PUBLIC},{PUBLIC},{ZT},{SUBNET}", PUBLIC),  # duplicate entry
    ],
)
def test_wrong_from_list_fails_in_every_file_naming_the_expectation(tmp_path, from_list, needle):
    repo = make_repo(tmp_path, {d: new_line(from_list) for d in DIRS})

    proc = cli(repo)

    assert proc.returncode == 1
    assert proc.stdout.count("from= lists") == 3
    assert needle in proc.stdout


def test_line_without_a_from_option_fails(tmp_path):
    bare = f"ssh-ed25519 {KEY} {COMMENT}"
    repo = make_repo(tmp_path, dict.fromkeys(DIRS, bare))

    proc = cli(repo)

    assert proc.returncode == 1
    assert proc.stdout.count('does not start with from="..."') == 3


def test_wrong_key_type_fails(tmp_path):
    line = f'from="{PUBLIC},{ZT},{SUBNET}" ssh-rsa {KEY} {COMMENT}'
    repo = make_repo(tmp_path, dict.fromkeys(DIRS, line))

    proc = cli(repo)

    assert proc.returncode == 1
    assert "key type is not ssh-ed25519" in proc.stdout


@pytest.mark.parametrize("missing_dir", DIRS)
def test_new_key_missing_in_one_file_fails_naming_it(tmp_path, missing_dir):
    repo = make_repo(tmp_path, {missing_dir: None})

    proc = cli(repo)

    assert proc.returncode == 1
    assert f"{missing_dir}: expected exactly one new-key line, found 0" in proc.stdout


def test_duplicated_new_key_line_in_a_file_fails(tmp_path):
    repo = make_repo(tmp_path)
    cloud = repo / DIRS[1] / "inventories/production/group_vars/all/vars.yml"
    text = cloud.read_text().replace(
        "ssh_authorized_keys_revoked",
        '  - "' + new_line().replace('"', '\\"') + '"\nssh_authorized_keys_revoked',
    )
    cloud.write_text(text)

    proc = cli(repo)

    assert proc.returncode == 1
    assert f"{DIRS[1]}: expected exactly one new-key line, found 2" in proc.stdout


# ------------------------------------------------------------- input problems
def test_missing_vars_file_exits_2(tmp_path):
    repo = make_repo(tmp_path)
    (repo / DIRS[1] / "inventories/production/group_vars/all/vars.yml").unlink()

    proc = cli(repo)

    assert proc.returncode == 2
    assert "cannot read" in proc.stderr


def test_empty_vm_zt_ip_without_override_exits_2(tmp_path):
    repo = make_repo(tmp_path)
    vm = repo / DIRS[2] / "inventories/production/group_vars/all/vars.yml"
    vm.write_text(vm.read_text().replace(f'vm_zt_ip: "{ZT}"', 'vm_zt_ip: ""'))

    proc = cli(repo)

    assert proc.returncode == 2
    assert "pass them explicitly" in proc.stderr
    assert cli(repo, "--vm-zt-ip", ZT).returncode == 0


def test_public_ip_is_required(tmp_path):
    repo = make_repo(tmp_path)

    proc = run_tool("check-from-list.sh", str(repo))

    assert proc.returncode == 2
    assert "--vm-public-ip" in proc.stderr


def test_public_ip_can_come_from_the_environment(tmp_path):
    repo = make_repo(tmp_path)

    proc = run_tool("check-from-list.sh", str(repo), env={"VM_PUBLIC_IP": PUBLIC})

    assert proc.returncode == 0, proc.stdout


# ------------------------------------------------------------------ unit level
def test_list_entries_unescapes_double_quoted_yaml_and_stops_at_next_key():
    text = (
        'ssh_authorized_keys_list:\n  - "from=\\"1.2.3.4\\" ssh-ed25519 K c"\n'
        "  - 'plain ssh-ed25519 K2 d'\nother:\n  - 'not ours'\n"
    )

    assert list_entries(text) == ['from="1.2.3.4" ssh-ed25519 K c', "plain ssh-ed25519 K2 d"]


def test_check_returns_per_directory_lines(tmp_path):
    repo = make_repo(tmp_path)

    result = check(repo, PUBLIC)

    assert result.ok
    assert set(result.lines) == set(DIRS)
    assert set(result.lines.values()) == {new_line()}


def test_check_raises_on_unreadable_input(tmp_path):
    with pytest.raises(CheckError, match="cannot read"):
        check(tmp_path, PUBLIC)


def test_list_entries_joins_a_folded_quoted_entry():
    text = (
        "ssh_authorized_keys_list:\n"
        '  - "ssh-ed25519 AAAA personal"\n'
        "  - 'from=\"1.2.3.4\"\n"
        "    ssh-ed25519 BBBB semaphore-automation@ops.de.wahlberger.dev'\n"
        "other: 1\n"
    )
    assert list_entries(text) == [
        "ssh-ed25519 AAAA personal",
        'from="1.2.3.4" ssh-ed25519 BBBB semaphore-automation@ops.de.wahlberger.dev',
    ]
